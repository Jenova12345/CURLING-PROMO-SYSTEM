-- =============================================================================
-- Rezervace 2. kolo — schéma podle feedbacku klienta (Jakub)
-- =============================================================================
-- Co tahle migrace řeší:
--   • audit „kdo zrušil / kdo potvrdil" u rezervací i směn,
--   • schvalování rezervace člena zástupcem klubu (approved_at/approved_by),
--   • rezervaci na obě dráhy najednou (1 akce ↔ víc rezervací),
--   • jen celé hodiny + otevírací doba 7:00–22:00 (nastavitelná) — vynuceno v DB,
--   • sazby podle typu akce (trénink / turnaj / komerční),
--   • prioritu při kolizi (komerční > turnaj > trénink) jako funkci pro RPC vrstvu,
--   • notifikace v aplikaci + frontu e-mailů (odesílání zatím VYPNUTÉ),
--   • ochranu proti duplicitnímu IČO (ARES).
--
-- Forward-only, nic nemaže. Ověřeno lokálně (supabase db reset). Na produkci se
-- neaplikuje bez zálohy a souhlasu PM.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) REZERVACE — audit storna, schvalování, série
-- -----------------------------------------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN cancelled_at   timestamptz,
  ADD COLUMN cancelled_by   uuid REFERENCES public.profiles(user_id),
  ADD COLUMN cancel_reason  text,
  ADD COLUMN approved_at    timestamptz,   -- NULL = čeká na potvrzení zástupcem klubu
  ADD COLUMN approved_by    uuid REFERENCES public.profiles(user_id),
  ADD COLUMN series_id      uuid;          -- společný klíč opakovaných tréninků

COMMENT ON COLUMN public.reservations.approved_at IS
  'NULL = rezervaci založil člen klubu a čeká na potvrzení zástupcem. Slot je držený i tak (jinak by vznikly dvojité rezervace).';
COMMENT ON COLUMN public.reservations.series_id IS
  'Společný identifikátor série opakovaných rezervací (pravidelné tréninky).';

CREATE INDEX idx_reservations_series ON public.reservations (series_id) WHERE series_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 1a) GUARD — co smí ne-admin sám od sebe (obrana i pro přímé volání PostgREST)
-- -----------------------------------------------------------------------------
-- Proti minulé verzi navíc: (a) propouští migrace/seed (bez přihlášeného uživatele),
-- (b) propouští důvěryhodnou RPC vrstvu, která si práva ověřuje sama,
-- (c) řeší schvalování zástupcem a nepodvrhnutelného autora storna.
CREATE OR REPLACE FUNCTION public.guard_reservation_rep_changes()
 RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  -- Co smí ne-admin přímým zápisem vůbec změnit. Whitelist schválně: při blacklistu
  -- by každý nově přidaný sloupec byl automaticky povolený (a přesně tak se sem
  -- třikrát po sobě vloudilo falšování auditu).
  _allowed CONSTANT text[] := ARRAY[
    'note', 'status',
    'approved_at', 'approved_by',
    'cancelled_at', 'cancelled_by', 'cancel_reason',
    'updated_at', 'updated_by'          -- doplňuje pozdější trigger, klientská hodnota se přepíše
  ];
  _changed text[];
  _forbidden text;
BEGIN
  -- Migrace, seed a servisní zásahy pod databázovou rolí. `session_user` schválně:
  -- uvnitř SECURITY DEFINER je current_user vždy vlastník funkce, takže by tahle
  -- podmínka nerozlišila vůbec nic. PostgREST se připojuje jako `authenticator`,
  -- takže nepřihlášený klient sem nespadne.
  -- Serverové skripty pod service_role ať používají RPC funkce, ne přímý zápis.
  IF auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  -- Zápis z důvěryhodných RPC funkcí (public.create_booking a spol.), které samy ověřují
  -- práva, kolize a priority. GUC je transakčně lokální; přes PostgREST ho klient nenastaví
  -- a RPC funkce ho po svých zápisech samy vypínají, aby zvýšené oprávnění neplatilo
  -- pro zbytek transakce.
  IF current_setting('app.trusted_booking', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF has_role(auth.uid(), 'admin') THEN
    RETURN NEW;  -- admin: bez omezení
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Zástupce i člen zakládají jen čistě klubovou rezervaci; nic nepodvrhnou.
    NEW.created_by        := auth.uid();
    NEW.status            := 'confirmed';
    NEW.deleted_at        := NULL;
    NEW.event_id          := NULL;
    NEW.rate_per_hour     := NULL;   -- sazbu dopočítá pricing z ceníku
    NEW.corrected_hours   := NULL;
    NEW.corrected_amount  := NULL;
    NEW.correction_reason := NULL;
    NEW.cancelled_at      := NULL;
    NEW.cancelled_by      := NULL;
    NEW.cancel_reason     := NULL;
    NEW.series_id         := NULL;   -- sérii zakládá jen create_booking_series (hlídá si subjekt)
    -- Zástupce klubu rezervuje rovnou platně, člen čeká na potvrzení zástupcem.
    IF public.is_subject_rep(NEW.subject_id) THEN
      NEW.approved_at := now();
      NEW.approved_by := auth.uid();
    ELSE
      NEW.approved_at := NULL;
      NEW.approved_by := NULL;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE: přístup k řádku hlídá RLS (rep = celý klub, člen = jen created_by = self).
  IF NOT public.is_subject_member(OLD.subject_id) THEN
    RAISE EXCEPTION 'Nemáte právo měnit tuto rezervaci';
  END IF;

  -- Které sloupce se vlastně mění
  SELECT array_agg(n.key) INTO _changed
    FROM jsonb_each(to_jsonb(NEW)) n
    JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
   WHERE n.value IS DISTINCT FROM o.value;
  _changed := COALESCE(_changed, '{}');

  -- Čas a dráha jdou měnit VÝHRADNĚ přes public.move_booking. Přímý zápis by minul
  -- kontrolu kolizí, pravidlo „akce na dvou drahách se posouvá celá" i srovnání času
  -- navázané akce — a směny brigádníků by pak ukazovaly na jiný den.
  IF _changed && ARRAY['sheet_id', 'start_at', 'end_at'] THEN
    RAISE EXCEPTION 'Čas a dráhu měňte přesunem rezervace, ne přímým zápisem';
  END IF;

  -- Cokoli mimo whitelist (sazba, subjekt, autor, korekce, vazby, soft-delete…)
  SELECT c INTO _forbidden FROM unnest(_changed) c WHERE c <> ALL (_allowed) LIMIT 1;
  IF _forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'Pole „%" smí měnit jen správce', _forbidden;
  END IF;

  -- --- potvrzení rezervace ---------------------------------------------------
  IF (_changed && ARRAY['approved_at', 'approved_by'])
     AND NOT public.is_subject_rep(OLD.subject_id) THEN
    RAISE EXCEPTION 'Rezervaci může potvrdit jen zástupce klubu';
  END IF;
  IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
     AND NEW.approved_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Autora potvrzení nelze podvrhnout';   -- ani jménem někoho jiného
  END IF;
  IF NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    IF NEW.approved_at IS NULL THEN
      RAISE EXCEPTION 'Potvrzení může odebrat jen správce';  -- vynulováním by zmizela stopa
    END IF;
    NEW.approved_at := now();                                -- a nelze ho zpětně datovat
  END IF;

  -- --- storno ----------------------------------------------------------------
  IF NEW.cancelled_by IS DISTINCT FROM OLD.cancelled_by
     AND NEW.cancelled_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Autora storna nelze podvrhnout';
  END IF;
  IF NEW.cancelled_at IS DISTINCT FROM OLD.cancelled_at THEN
    IF NEW.cancelled_at IS NULL THEN
      RAISE EXCEPTION 'Razítko storna nelze smazat';
    END IF;
    NEW.cancelled_at := now();
  END IF;
  -- Důvod storna patří tomu, kdo rušil — jinak by si klub přepsal „přebito komerční akcí"
  -- na vlastní verzi příběhu.
  IF NEW.cancel_reason IS DISTINCT FROM OLD.cancel_reason
     AND OLD.cancelled_by IS NOT NULL
     AND OLD.cancelled_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Důvod storna smí měnit jen ten, kdo rezervaci zrušil';
  END IF;
  -- Storno je jednosměrné: „od-stornovat" (a nechat u toho staré razítko, kdo rušil)
  -- smí jen správce. Ne-admin ať založí novou rezervaci.
  IF OLD.status = 'cancelled' AND NEW.status = 'confirmed' THEN
    RAISE EXCEPTION 'Stornovanou rezervaci může obnovit jen správce — založte novou.';
  END IF;

  RETURN NEW;
END;
$$;

-- Stávající (historické) rezervace ber jako potvrzené — vznikly před zavedením schvalování.
-- Trigger set_updated_fields při migraci vypínáme: bez přihlášeného uživatele by
-- přepsal updated_by na NULL a všem řádkům posunul updated_at (ztráta stopy v auditu).
ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_updated;
UPDATE public.reservations SET approved_at = created_at WHERE approved_at IS NULL;
ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_updated;

-- -----------------------------------------------------------------------------
-- 2) SMĚNY — audit zrušení
-- -----------------------------------------------------------------------------
ALTER TABLE public.shifts
  ADD COLUMN cancelled_at timestamptz,
  ADD COLUMN cancelled_by uuid REFERENCES public.profiles(user_id);

-- -----------------------------------------------------------------------------
-- 3) REZERVACE NA OBĚ DRÁHY — 1 akce může mít víc rezervací (po jedné na dráhu)
-- -----------------------------------------------------------------------------
-- Původní unikátní index (1 akce ↔ max 1 živá rezervace) to zakazoval.
DROP INDEX IF EXISTS public.idx_reservations_event;
CREATE INDEX idx_reservations_event ON public.reservations (event_id)
  WHERE event_id IS NOT NULL AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 4) NASTAVENÍ — sazby podle typu akce, otevírací doba, přepínač e-mailů
-- -----------------------------------------------------------------------------
ALTER TABLE public.settings
  ADD COLUMN training_rate   numeric(10,2),   -- Kč/h za trénink klubu
  ADD COLUMN tournament_rate numeric(10,2),   -- Kč/h za turnaj
  ADD COLUMN email_notifications_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.settings.training_rate IS
  'Sazba za trénink. NULL = použije se club_default_rate. Čísla vyplňuje admin — migrace je záměrně nechává prázdné, aby se neúčtovalo podle vymyšlených hodnot.';
COMMENT ON COLUMN public.settings.email_notifications_enabled IS
  'Dokud je false, notifikace se ukládají jen do aplikace a fronta e-mailů se needituje (nic se neodešle zpětně po zapnutí).';

-- Otevírací doba: klient chce led 7:00–22:00. Měníme jen dny, které mají ještě
-- původní výchozí 08:00 — ručně upravené hodnoty zůstanou.
-- (Stejně jako u rezervací: bez vypnutého triggeru by migrace přepsala updated_by na NULL.)
ALTER TABLE public.settings DISABLE TRIGGER trg_settings_updated;
UPDATE public.settings
   SET opening_hours = (
     SELECT jsonb_object_agg(
              d.key,
              CASE WHEN d.value->>'open' = '08:00'
                   THEN jsonb_set(d.value, '{open}', '"07:00"')
                   ELSE d.value END)
       FROM jsonb_each(public.settings.opening_hours) AS d
   )
 WHERE opening_hours IS NOT NULL;
ALTER TABLE public.settings ENABLE TRIGGER trg_settings_updated;

-- -----------------------------------------------------------------------------
-- 5) SUBJEKTY — jedno IČO = jeden subjekt (ARES nesmí zakládat duplicity)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _dups text;
BEGIN
  SELECT string_agg(ico, ', ') INTO _dups
    FROM (SELECT ico FROM public.subjects
           WHERE ico IS NOT NULL AND deleted_at IS NULL
           GROUP BY ico HAVING count(*) > 1) d;
  IF _dups IS NOT NULL THEN
    RAISE EXCEPTION 'V tabulce subjects jsou duplicitní IČO (%). Před nasazením je slučte nebo soft-smažte (deleted_at), teprve pak jde vynutit unikátnost.', _dups;
  END IF;
END $$;

CREATE UNIQUE INDEX idx_subjects_ico_unique ON public.subjects (ico)
  WHERE ico IS NOT NULL AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 6) PRIORITA AKCÍ (kolize) — komerční > turnaj > trénink
-- -----------------------------------------------------------------------------
-- Údržba ledu je nejvýš: zadává ji vědomě admin a bez ní se nehraje.
-- Klubová rezervace bez akce má prioritu tréninku.
CREATE OR REPLACE FUNCTION public.booking_priority(_type public.event_type)
 RETURNS int
 LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE _type
           WHEN 'maintenance' THEN 40
           WHEN 'commercial'  THEN 30
           WHEN 'recruitment' THEN 30
           WHEN 'tournament'  THEN 20
           WHEN 'training'    THEN 10
           ELSE 10
         END;
$$;

COMMENT ON FUNCTION public.booking_priority(public.event_type) IS
  'Priorita při kolizi na dráze. Vyšší číslo smí (jen admin a jen explicitně) přebít nižší.';

-- -----------------------------------------------------------------------------
-- 7) VALIDACE SLOTU — celé hodiny, otevírací doba, nepřekročit půlnoc
-- -----------------------------------------------------------------------------
-- Řešeno triggerem, ne CHECK constraintem: práce s časovým pásmem (Europe/Prague)
-- není IMMUTABLE, takže do CHECK nepatří. Trigger navíc umí českou hlášku.
-- Validuje se jen při vzniku a při změně času → starší data (půlhodiny) nic neblokuje.
CREATE OR REPLACE FUNCTION public.validate_reservation_slot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE
  _oh          jsonb;
  _dow         text;
  _open        time;
  _close       time;
  _local_start timestamp;
  _local_end   timestamp;
BEGIN
  IF NEW.status = 'cancelled' OR NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;  -- storno/smazání čas neřeší
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.start_at = OLD.start_at AND NEW.end_at = OLD.end_at THEN
    RETURN NEW;  -- čas se nemění → nic nevaliduj (nezablokuje úpravy starých rezervací)
  END IF;

  _local_start := NEW.start_at AT TIME ZONE 'Europe/Prague';
  _local_end   := NEW.end_at   AT TIME ZONE 'Europe/Prague';

  IF _local_start <> date_trunc('hour', _local_start)
     OR _local_end <> date_trunc('hour', _local_end) THEN
    RAISE EXCEPTION 'Rezervovat jde jen na celé hodiny (např. 17:00–19:00).';
  END IF;

  IF _local_end::date <> _local_start::date THEN
    RAISE EXCEPTION 'Rezervace nesmí přesáhnout půlnoc — rozděl ji na dva dny.';
  END IF;

  SELECT opening_hours INTO _oh FROM public.settings LIMIT 1;
  _dow   := extract(isodow FROM _local_start)::int::text;   -- 1 = pondělí … 7 = neděle
  _open  := (_oh -> _dow ->> 'open')::time;
  _close := (_oh -> _dow ->> 'close')::time;

  IF _open IS NULL OR _close IS NULL THEN
    RAISE EXCEPTION 'Pro tento den není nastavená otevírací doba — doplňte ji v Nastavení.';
  END IF;

  IF _local_start::time < _open OR _local_end::time > _close THEN
    RAISE EXCEPTION 'Mimo otevírací dobu (%–%). Vyberte čas uvnitř provozní doby.',
      to_char(_open, 'HH24:MI'), to_char(_close, 'HH24:MI');
  END IF;

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 8) RAZÍTKO STORNA — „kdo a kdy zrušil" se doplní vždy, ať ruší kdokoli
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stamp_reservation_cancel()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND ((OLD.status = 'confirmed' AND NEW.status = 'cancelled')
          OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)) THEN
    NEW.cancelled_at := COALESCE(NEW.cancelled_at, now());
    NEW.cancelled_by := COALESCE(NEW.cancelled_by, auth.uid());
  END IF;
  RETURN NEW;
END;
$$;

-- Pořadí BEFORE triggerů je abecední: a_guard → b_validate → c_stamp → pricing → updated
CREATE TRIGGER trg_reservations_b_validate BEFORE INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.validate_reservation_slot();
CREATE TRIGGER trg_reservations_c_stamp BEFORE UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.stamp_reservation_cancel();

-- -----------------------------------------------------------------------------
-- 9) CENÍK PODLE TYPU AKCE
-- -----------------------------------------------------------------------------
-- Pořadí: vlastní sazba subjektu → sazba podle typu akce → sazba podle typu subjektu.
-- Interní rezervace bez fakturačního subjektu se neúčtuje (beze změny).
CREATE OR REPLACE FUNCTION public.set_reservation_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE
  _rate         numeric;
  _subject_rate numeric;
  _subject_type public.subject_type;
  _event_type   public.event_type;
  _st           public.settings%ROWTYPE;
BEGIN
  IF NEW.subject_id IS NULL THEN
    NEW.rate_per_hour    := NULL;
    NEW.amount           := NULL;
    NEW.corrected_amount := NULL;
    NEW.hours := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    RETURN NEW;
  END IF;

  -- Snapshot sazby jen při vzniku; pozdější změna ceníku nepřepočítává minulé rezervace.
  IF TG_OP = 'INSERT' AND NEW.rate_per_hour IS NULL THEN
    SELECT s.default_rate, s.type INTO _subject_rate, _subject_type
      FROM public.subjects s WHERE s.id = NEW.subject_id;
    SELECT * INTO _st FROM public.settings LIMIT 1;

    IF NEW.event_id IS NOT NULL THEN
      SELECT e.event_type INTO _event_type FROM public.events e WHERE e.id = NEW.event_id;
    END IF;

    -- Komerční zákazník se účtuje komerční sazbou i u turnaje/tréninku — jinak by
    -- firma jezdila za klubovou cenu jen proto, že se akce jmenuje „turnaj".
    _rate := COALESCE(
      _subject_rate,
      CASE
        WHEN _subject_type = 'commercial' THEN _st.commercial_default_rate
        WHEN _event_type = 'commercial'   THEN _st.commercial_default_rate
        WHEN _event_type = 'recruitment'  THEN _st.commercial_default_rate
        WHEN _event_type = 'tournament'   THEN COALESCE(_st.tournament_rate, _st.club_default_rate)
        WHEN _event_type = 'training'     THEN COALESCE(_st.training_rate, _st.club_default_rate)
        ELSE _st.club_default_rate
      END,
      -- akce bez vlastní sazby (např. údržba s fakturačním subjektem) → podle typu subjektu
      CASE _subject_type WHEN 'commercial' THEN _st.commercial_default_rate
                         ELSE _st.club_default_rate END
    );

    IF _rate IS NULL THEN
      RAISE EXCEPTION 'Sazba není nastavena — admin musí nejdřív vyplnit ceník (Nastavení) nebo sazbu subjektu';
    END IF;
    NEW.rate_per_hour := _rate;
  END IF;

  IF NEW.rate_per_hour IS NULL THEN
    RAISE EXCEPTION 'Sazba (rate_per_hour) nesmí zůstat prázdná';
  END IF;

  NEW.hours  := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
  NEW.amount := round(NEW.hours * NEW.rate_per_hour, 2);
  NEW.corrected_amount := CASE
    WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
    ELSE NULL END;

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10) STORNO REZERVACE → směny akce ruš, až když akci nedrží žádná další rezervace
-- -----------------------------------------------------------------------------
-- (S rezervací na obě dráhy má jedna akce dvě rezervace; storno jedné dráhy nesmí
-- sebrat štáb celé akci.)
CREATE OR REPLACE FUNCTION public.cancel_open_shifts_on_reservation_cancel()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.event_id IS NOT NULL
     AND (
       (OLD.status = 'confirmed' AND NEW.status = 'cancelled')
       OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.reservations r
        WHERE r.event_id = NEW.event_id
          AND r.id <> NEW.id
          AND r.status = 'confirmed'
          AND r.deleted_at IS NULL
     ) THEN
    UPDATE public.shifts
       SET status = 'cancelled',
           cancelled_at = now(),
           cancelled_by = auth.uid()
     WHERE event_id = NEW.event_id
       AND status IN ('open', 'pending');
    -- claimed/completed směny záměrně ZŮSTÁVAJÍ (historie výplat); admin je řeší ručně.
  END IF;
  RETURN NULL;
END;
$$;

-- -----------------------------------------------------------------------------
-- 11) NOTIFIKACE V APLIKACI + FRONTA E-MAILŮ
-- -----------------------------------------------------------------------------
CREATE TABLE public.notifications (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
  type           text NOT NULL,          -- reservation_overridden | reservation_needs_approval | reservation_approved | reservation_cancelled
  title          text NOT NULL,
  body           text,
  link           text,                   -- kam v aplikaci odkázat (např. /calendar)
  reservation_id uuid REFERENCES public.reservations(id) ON DELETE SET NULL,
  subject_id     uuid REFERENCES public.subjects(id) ON DELETE SET NULL,
  read_at        timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid REFERENCES public.profiles(user_id)
);

CREATE INDEX idx_notifications_user        ON public.notifications (user_id, created_at DESC);
CREATE INDEX idx_notifications_user_unread ON public.notifications (user_id) WHERE read_at IS NULL;
-- kvůli FK ON DELETE SET NULL (bez indexu by mazání rezervace skenovalo celou tabulku)
CREATE INDEX idx_notifications_reservation ON public.notifications (reservation_id) WHERE reservation_id IS NOT NULL;

-- Fronta e-mailů. Odesílá ji až edge funkce `send-emails` (servisním klíčem) — dokud
-- není nastavený poskytovatel, zůstává vypnutá a fronta se ani neplní (viz settings).
CREATE TABLE public.email_outbox (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id uuid REFERENCES public.notifications(id) ON DELETE SET NULL,
  user_id         uuid REFERENCES public.profiles(user_id) ON DELETE SET NULL,
  email           text NOT NULL,
  subject         text NOT NULL,
  body            text NOT NULL,
  status          text NOT NULL DEFAULT 'pending',
  attempts        int  NOT NULL DEFAULT 0,
  last_error      text,
  sent_at         timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT email_outbox_status_check CHECK (status IN ('pending', 'sent', 'failed', 'skipped'))
);

CREATE INDEX idx_email_outbox_pending ON public.email_outbox (created_at) WHERE status = 'pending';

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.email_outbox  ENABLE ROW LEVEL SECURITY;

-- Supabase dává nové tabulce práva i roli anon (nepřihlášený). RLS ji sice bez politik
-- nikam nepustí, ale ta práva tam nemají co dělat — bereme je pryč (obrana do hloubky).
REVOKE ALL ON public.notifications FROM anon;
REVOKE ALL ON public.email_outbox  FROM anon;

-- Notifikace: každý vidí jen své (admin i cizí kvůli podpoře); zapisuje jen SECURITY DEFINER funkce.
CREATE POLICY "notifications_select_own" ON public.notifications
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR has_role(auth.uid(), 'admin'));
CREATE POLICY "notifications_update_own" ON public.notifications
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
-- (žádné INSERT/DELETE pro authenticated — notifikace zakládá jen server)

-- Fronta e-mailů obsahuje adresy → jen admin ke čtení, zápis jen server/servisní klíč.
CREATE POLICY "email_outbox_select_admin" ON public.email_outbox
  FOR SELECT TO authenticated USING (has_role(auth.uid(), 'admin'));

-- Uživatel smí na své notifikaci změnit jen „přečteno" — ne obsah.
CREATE OR REPLACE FUNCTION public.guard_notification_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id
     OR NEW.type  IS DISTINCT FROM OLD.type
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.body  IS DISTINCT FROM OLD.body
     OR NEW.link  IS DISTINCT FROM OLD.link
     OR NEW.reservation_id IS DISTINCT FROM OLD.reservation_id
     OR NEW.subject_id     IS DISTINCT FROM OLD.subject_id
     OR NEW.created_at     IS DISTINCT FROM OLD.created_at
     OR NEW.created_by     IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'U notifikace lze měnit jen příznak přečtení';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_notifications_guard BEFORE UPDATE ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.guard_notification_update();

-- Založení notifikace (+ volitelně e-mail do fronty). Volají ji RPC funkce rezervací.
CREATE OR REPLACE FUNCTION public.notify_user(
  _user           uuid,
  _type           text,
  _title          text,
  _body           text,
  _link           text    DEFAULT '/calendar',
  _reservation_id uuid    DEFAULT NULL,
  _subject_id     uuid    DEFAULT NULL
) RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _id      uuid;
  _email   text;
  _enabled boolean;
BEGIN
  IF _user IS NULL THEN RETURN NULL; END IF;

  INSERT INTO public.notifications (user_id, type, title, body, link, reservation_id, subject_id, created_by)
  VALUES (_user, _type, _title, _body, _link, _reservation_id, _subject_id, auth.uid())
  RETURNING id INTO _id;

  SELECT email_notifications_enabled INTO _enabled FROM public.settings LIMIT 1;
  IF COALESCE(_enabled, false) THEN
    SELECT u.email INTO _email FROM auth.users u WHERE u.id = _user;
    IF _email IS NOT NULL AND _email <> '' THEN
      INSERT INTO public.email_outbox (notification_id, user_id, email, subject, body)
      VALUES (_id, _user, _email, _title, COALESCE(_body, _title));
    END IF;
  END IF;

  RETURN _id;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_user(uuid, text, text, text, text, uuid, uuid) FROM public, anon, authenticated;

COMMENT ON FUNCTION public.notify_user(uuid, text, text, text, text, uuid, uuid) IS
  'Interní: zakládá notifikaci v aplikaci a (jen když je zapnuté odesílání) i e-mail do fronty. Volá se z RPC rezervací, ne z klienta.';

-- -----------------------------------------------------------------------------
-- 12) SCHVALOVÁNÍ: upozorni zástupce klubu / autora rezervace
-- -----------------------------------------------------------------------------
-- Trigger (ne RPC), aby upozornění vzniklo bez ohledu na to, kudy rezervace přišla.
CREATE OR REPLACE FUNCTION public.notify_reservation_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _rep         record;
  _subject     text;
  _author      text;
  _when        text;
  _sheet       text;
BEGIN
  IF NEW.subject_id IS NULL OR NEW.status <> 'confirmed' OR NEW.deleted_at IS NOT NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.name INTO _subject FROM public.subjects s WHERE s.id = NEW.subject_id;
  SELECT sh.name INTO _sheet   FROM public.sheets sh WHERE sh.id = NEW.sheet_id;
  _when := to_char(NEW.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
           || '–' || to_char(NEW.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI');

  -- (a) nová nepotvrzená rezervace člena → upozorni všechny zástupce klubu
  IF TG_OP = 'INSERT' AND NEW.approved_at IS NULL THEN
    -- Jedna zpráva na akci, ne na každý slot: rezervace na obě dráhy ani série
    -- opakovaných tréninků nesmí zástupci zaplavit schránku.
    IF EXISTS (
      SELECT 1 FROM public.reservations r
       WHERE r.id <> NEW.id
         AND ((NEW.event_id  IS NOT NULL AND r.event_id  = NEW.event_id)
           OR (NEW.series_id IS NOT NULL AND r.series_id = NEW.series_id))
    ) THEN
      RETURN NULL;
    END IF;

    SELECT p.full_name INTO _author FROM public.profiles p WHERE p.user_id = NEW.created_by;
    FOR _rep IN
      SELECT sr.user_id FROM public.subject_reps sr
       WHERE sr.subject_id = NEW.subject_id AND sr.level = 'rep' AND sr.user_id <> NEW.created_by
    LOOP
      PERFORM public.notify_user(
        _rep.user_id, 'reservation_needs_approval',
        'Rezervace čeká na potvrzení',
        COALESCE(_author, 'Člen klubu') || ' zadal(a) rezervaci za ' || COALESCE(_subject, 'klub')
          || ': ' || COALESCE(_sheet, 'dráha') || ', ' || _when || '. Potvrďte ji v kalendáři.',
        '/calendar', NEW.id, NEW.subject_id);
    END LOOP;
    RETURN NULL;
  END IF;

  -- (b) zástupce potvrdil → dej vědět autorovi
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NULL AND NEW.approved_at IS NOT NULL
     AND NEW.created_by IS NOT NULL AND NEW.created_by <> COALESCE(NEW.approved_by, NEW.created_by) THEN
    PERFORM public.notify_user(
      NEW.created_by, 'reservation_approved',
      'Rezervace potvrzena',
      'Vaši rezervaci za ' || COALESCE(_subject, 'klub') || ' (' || COALESCE(_sheet, 'dráha')
        || ', ' || _when || ') potvrdil zástupce klubu.',
      '/calendar', NEW.id, NEW.subject_id);
  END IF;

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_reservations_notify_approval
  AFTER INSERT OR UPDATE OF approved_at ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.notify_reservation_approval();
