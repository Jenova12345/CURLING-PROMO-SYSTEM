-- =============================================================================
-- E-mailové notifikace: šablony, allowlist typů a pojistka proti dvojímu odeslání
-- =============================================================================
-- KROK 0 (11. 9. 2026, čteno z živé produkce fcwubbytqxubgptftnru) zjistil:
--
--   * `notify_user` UŽ e-mail do fronty plní, ale jen když je zapnuté
--     `settings.email_notifications_enabled` (dnes `false`, fronta má 0 řádků).
--   * Edge funkce `send-emails` UŽ na Resend volá a UŽ má retry (5 pokusů).
--     Nechyběl tedy „provider", chyběly tři věci níž.
--   * Živé typy upozornění: reservation_needs_approval, reservation_approved,
--     reservation_cancelled, reservation_changed, subject_request_approved.
--     `reservation_overridden` vzniká v `create_booking`.
--   * Upozornění posílají živě čtyři funkce: `create_booking`,
--     `approve_subject_request`, `notify_reservation_approval`,
--     `notify_reservation_changed`.
--
-- CO SE TEDY DĚLÁ TADY (a nic víc):
--
-- 1) ALLOWLIST. Dokud se e-maily zapnou, šla by ven KAŽDÁ notifikace, tedy
--    i `subject_request_approved` a cokoli budoucího. Zadání zní „přesně tahle
--    matice, žádný spam", takže o tom, co smí do pošty, rozhoduje jediné místo:
--    `email_sablona()`. Typ, na který nemá šablonu, e-mail nedostane.
--
-- 2) ŠABLONY. Fronta dosud brala předmět = titulek upozornění a tělo = text
--    upozornění. V aplikaci to stačí (uživatel vidí kontext kolem), v poště ne:
--    chybí oslovení, odkaz i podpis. Šablona je v SQL schválně, aby fronta byla
--    použitelná i pro odesílač, který by nebyl ten náš.
--
-- 3) ZAKLADATELI CHYBĚLA ZPRÁVA „čeká na potvrzení". Dnešní
--    `notify_reservation_approval` větev (a) upozorní jen zástupce klubu.
--    Člen klubu tedy zadal rezervaci a nedostal nic, ačkoli jeho akce do
--    potvrzení neplatí. Přibývá typ `reservation_pending`.
--
-- 4) POJISTKA PROTI DVOJÍMU ODESLÁNÍ. Drží ji TŘI RŮZNÉ VRSTVY a je poctivé
--    říct, která co umí, protože se to dá snadno popsat líp, než to je:
--
--    (a) JEDNA ZPRÁVA NA AKCI. Že rezervace přes dvě dráhy nebo série tréninků
--        nevyrobí dvě upozornění, hlídá dedup v triggerech. Existoval UŽ DŘÍV,
--        tahle migrace ho nepřidává. Je to ta vrstva, která doopravdy brání
--        dvojímu e-mailu o téže události.
--
--    (b) TÝŽ ŘÁDEK SI NEVEZMOU DVA BĚHY. `email_outbox_prevzit()` si dávku
--        zamkne (`FOR UPDATE SKIP LOCKED`) a hned ji překlopí na `sending`.
--        Tohle je nové. Dřív oba běhy četly `status='pending'` a poslaly
--        každý svůj e-mail. Ověřeno třemi souběžnými běhy edge funkce,
--        viz `supabase/tests/emaily_fronta_zavod.sh`.
--
--    (c) ČÁSTEČNÝ UNIQUE INDEX na `notification_id`. Pozor, tenhle NEDĚLÁ to,
--        co by se od jeho jména čekalo: `notify_user` pokaždé zakládá NOVÉ
--        upozornění, takže se o něj nikdy nezavadí. Je to obrana do hloubky
--        proti PŘÍMÉMU zápisu do fronty (migrace, servisní skript, budoucí
--        kód), ne pojistka na cestě, kterou systém chodí dnes.
--
-- 5) NEPLATNÝ E-MAIL SE TIŠE PŘESKOČÍ. Dosud se hlídalo jen NULL a prázdno;
--    adresa bez zavináče došla až k Resendu, ten ji odmítl, a řádek pak pětkrát
--    marně opakoval a skončil jako `failed`, tedy jako by šlo o poruchu.
--
-- NENASAZUJE SE. Migrace je napsaná a ověřená lokálně; na produkci nejde.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Platnost e-mailové adresy
-- -----------------------------------------------------------------------------
-- Vědomě hrubá kontrola: chceme vyloučit zjevný nesmysl („", „neuvedeno",
-- „jan.novak"), ne suplovat RFC 5322. Co projde sem a odmítne to Resend,
-- zachytí edge funkce a označí `skipped`, ne `failed`.
CREATE OR REPLACE FUNCTION public.email_je_platny(_email text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $$
  SELECT _email IS NOT NULL
     AND length(_email) BETWEEN 6 AND 254
     AND _email ~ '^[^@[:space:]]+@[^@[:space:].]+(\.[^@[:space:].]+)+$';
$$;

-- Z klienta ji nevolá nic; v repu je zvykem API plochu nenechávat otevřenou
-- jen proto, že zrovna nic nevydává.
REVOKE ALL ON FUNCTION public.email_je_platny(text) FROM public, anon, authenticated;

COMMENT ON FUNCTION public.email_je_platny(text) IS
  'Hrubá kontrola adresy před zařazením do fronty. Neplatná adresa se tiše přeskočí, není to chyba.';

-- -----------------------------------------------------------------------------
-- 2) Šablony e-mailů = zároveň allowlist typů
-- -----------------------------------------------------------------------------
-- Vrací prázdno pro typ, který do pošty nepatří. Tím je seznam povolených typů
-- na jednom místě a `notify_user` nemusí vědět nic o marketingu ani o spamu.
--
-- Fakta (klub, dráha, čas, kdo zasáhl, důvod storna) už složil ten, kdo
-- upozornění zakládal, a jsou v `_body`. Šablona je schválně NEskládá podruhé:
-- dvě nezávislé formulace téhož by si časem přestaly odpovídat.
CREATE OR REPLACE FUNCTION public.email_sablona(
  _type  text,
  _title text,
  _body  text,
  _link  text
) RETURNS TABLE (subject text, body text)
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $$
DECLARE
  -- Portál klienta. Kdyby se adresa měnila, mění se na jediném místě.
  _web    constant text := 'https://curling-ostrava-system.netlify.app';
  _odkaz  text;
  _cil    text;
  _uvod   text;
  _zaver  text;
BEGIN
  -- Odkaz musí být cesta na našem webu, ne cokoli. Bez požadavku na úvodní
  -- `/` (a na to, že další znak není další lomítko) by `_link` tvaru
  -- '.zly-web.cz/x' vyrobil „https://curling-ostrava-system.netlify.app.zly-web.cz/x",
  -- tedy podvrženou doménu v e-mailu z naší adresy. Dnes všech dvanáct
  -- volajících předává literál '/calendar', takže je to obrana do hloubky.
  _cil := COALESCE(NULLIF(btrim(COALESCE(_link, '')), ''), '/calendar');
  IF _cil !~ '^/[^/]' THEN
    _cil := '/calendar';
  END IF;
  _odkaz := _web || _cil;

  subject := CASE _type
    WHEN 'reservation_pending'         THEN 'Rezervace čeká na potvrzení správce klubu'
    WHEN 'reservation_needs_approval'  THEN 'Máte rezervaci k potvrzení'
    WHEN 'reservation_approved'        THEN 'Rezervace je potvrzena'
    WHEN 'reservation_cancelled'       THEN 'Rezervace byla zrušena'
    WHEN 'reservation_changed'         THEN 'Rezervace byla upravena'
    WHEN 'reservation_overridden'      THEN 'Rezervace byla zrušena kvůli jiné akci'
    ELSE NULL
  END;

  -- Typ bez šablony e-mail nedostane. Upozornění v aplikaci vzniká tak jako tak.
  IF subject IS NULL THEN
    RETURN;
  END IF;

  _zaver := CASE _type
    WHEN 'reservation_pending'        THEN 'Rezervace zatím neplatí. Platit začne, jakmile ji správce klubu potvrdí.'
    WHEN 'reservation_needs_approval' THEN 'Potvrdit nebo zrušit ji můžete v kalendáři.'
    WHEN 'reservation_approved'       THEN 'Termín je tím závazně obsazený.'
    WHEN 'reservation_cancelled'      THEN 'Termín je znovu volný. Náhradní si můžete vybrat v kalendáři.'
    WHEN 'reservation_changed'        THEN 'Nový termín si prosím zkontrolujte v kalendáři.'
    WHEN 'reservation_overridden'     THEN 'Omlouváme se. Náhradní termín si můžete vybrat v kalendáři.'
  END;

  -- ⚠️ Do `_body` vstupuje `profiles.full_name` autora rezervace a název
  -- klubu, tedy text, který si KAŽDÝ PŘIHLÁŠENÝ nastavuje sám a bez omezení.
  -- Beze změny by si člen klubu mohl do jména dát prázdný řádek a vlastní
  -- odstavec, a ten by zástupcům klubu dorazil z ověřené domény haly, se
  -- správným SPF/DKIM a pod naším podpisem. Proto se ven pouští jednořádkový
  -- text s pevným stropem: řídicí znaky (tedy i konce řádků) padnou.
  --
  -- `_title` na konci COALESCE je až za tím, aby tělo nikdy nevyšlo NULL:
  -- `email_outbox.body` je NOT NULL a výjimka by letěla z TRIGGERU, takže by
  -- neshodila e-mail, ale celé `create_booking` nebo `approve_reservation`.
  _uvod := left(
    regexp_replace(
      COALESCE(NULLIF(btrim(COALESCE(_body, '')), ''), _title, ''),
      '[[:cntrl:]]+', ' ', 'g'),
    500);

  body :=
    'Dobrý den,' || E'\n\n' ||
    _uvod || E'\n\n' ||
    _zaver || E'\n\n' ||
    'Kalendář haly: ' || _odkaz || E'\n\n' ||
    'Curling Promo Ostrava' || E'\n' ||
    'Tato zpráva je automatická, neodpovídejte na ni.';

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.email_sablona(text, text, text, text) FROM public, anon, authenticated;

COMMENT ON FUNCTION public.email_sablona(text, text, text, text) IS
  'Předmět a tělo e-mailu pro daný typ upozornění. Typ bez šablony e-mail nedostane, tím je to zároveň allowlist (žádný spam).';

-- -----------------------------------------------------------------------------
-- 3) Fronta: stav `sending`, razítko převzetí, jedno upozornění = jeden e-mail
-- -----------------------------------------------------------------------------
-- `ALTER TABLE` bere ACCESS EXCLUSIVE. Kdyby nad frontou visela cizí otevřená
-- transakce, čekal by donekonečna a zablokoval zbytek migrace. Stejný vzor
-- jako v 20260902280000_upozorneni_whitelist.sql.
SET lock_timeout = '3s';

ALTER TABLE public.email_outbox ADD COLUMN IF NOT EXISTS claimed_at timestamptz;

COMMENT ON COLUMN public.email_outbox.claimed_at IS
  'Kdy si řádek vzal odesílač. Slouží k uvolnění řádků po spadlém běhu.';

ALTER TABLE public.email_outbox DROP CONSTRAINT IF EXISTS email_outbox_status_check;
ALTER TABLE public.email_outbox ADD CONSTRAINT email_outbox_status_check
  CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'skipped'));

-- Jedno upozornění = nejvýš jeden řádek fronty.
--
-- ⚠️ Cestou, kterou systém chodí dnes, se o tenhle index NEZAVADÍ:
-- `notify_user` pokaždé zakládá nové upozornění, takže `notification_id` je
-- vždy čerstvé UUID. Je to obrana do hloubky proti přímému zápisu do fronty
-- (migrace, servisní skript, budoucí kód), ne pojistka na dnešní cestě.
-- Tu drží dedup v triggerech a zamykání při převzetí, viz hlavička.
--
-- Částečný index: `notification_id` je ON DELETE SET NULL, takže NULL musí
-- zůstat povolený vícekrát.
CREATE UNIQUE INDEX IF NOT EXISTS uq_email_outbox_notification
  ON public.email_outbox (notification_id) WHERE notification_id IS NOT NULL;

-- Výběr v `email_outbox_prevzit` jede přes `pending OR sending`, což stávající
-- `idx_email_outbox_pending` (částečný jen na 'pending') neobslouží. Dnes je
-- fronta prázdná a je to jedno; až se v ní nahromadí odeslané řádky, byl by
-- z toho seqscan při každém tiknutí cronu.
CREATE INDEX IF NOT EXISTS idx_email_outbox_k_odeslani
  ON public.email_outbox (created_at) WHERE status IN ('pending', 'sending');

-- `authenticated` měl na frontě INSERT/UPDATE/DELETE. Dosud to nikam nevedlo
-- jen díky RLS (tabulka má jedinou politiku, SELECT pro admina), ale ta práva
-- tam nemají co dělat: fronta se plní jen ze SECURITY DEFINER funkce a vyprazdňuje
-- servisním klíčem. Táž úvaha, jakou v booking_core vedla k odebrání práv roli anon.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES ON public.email_outbox FROM authenticated;

RESET lock_timeout;

-- -----------------------------------------------------------------------------
-- 4) Převzetí dávky odesílačem
-- -----------------------------------------------------------------------------
-- Proč RPC a ne `select ... where status='pending'` v edge funkci: dva souběžné
-- běhy (naplánovaný + ruční, nebo dva podle pomalého cronu) přečtou touž dávku
-- a každý ji pošle. Tady si řádky zamkneme a hned přepíšeme na `sending`,
-- takže druhý běh je se `SKIP LOCKED` vůbec neuvidí.
CREATE OR REPLACE FUNCTION public.email_outbox_prevzit(_limit int DEFAULT 50)
 RETURNS TABLE (id uuid, email text, subject text, body text, attempts int)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
-- `RETURNS TABLE` zakládá OUT parametry jménem id/email/subject/body/attempts,
-- takže nekvalifikovaný odkaz na stejnojmenný sloupec by funkci runtime rozbil
-- hláškou o nejednoznačnosti. Tohle říká, že v případě střetu vyhrává SLOUPEC,
-- aby to nedrželo jen na kázni při kvalifikování.
#variable_conflict use_column
BEGIN
  -- ⚠️ ROZPOČET POKUSŮ JE 5 A ŽIJE NA TŘECH MÍSTECH, která si musí odpovídat:
  -- `attempts >= 5` v úklidu níž, `attempts < 5` ve výběru níž a `MAX_POKUSU`
  -- v `supabase/functions/send-emails/index.ts`. Změna na jednom místě rozhodí
  -- ostatní: TS=3 proti SQL=5 znamená, že se běžná chyba vzdá po třech
  -- pokusech, ale uvíznutý řádek dostane pět.
  IF _limit IS NULL OR _limit < 1 OR _limit > 200 THEN
    _limit := 50;
  END IF;

  -- Řádek, který zůstal v `sending` po spadlém běhu a vyčerpal pokusy, se
  -- nesmí vracet donekonečna. Deset minut je s přehledem nad délkou dávky.
  --
  -- `COALESCE(claimed_at, created_at)`: řádek se `sending` a PRÁZDNÝM razítkem
  -- by se jinak nevrátil do fronty ani neoznačil `failed` NIKDY, protože
  -- `NULL < cokoli` není pravda. Takový řádek dnes `prevzit` nevyrobí, ale
  -- vyrobí ho jakýkoli ruční zásah, a tiše by z fronty zmizel.
  --
  -- `SKIP LOCKED` i tady: bez něj se můžou dva souběžné běhy, které zaseklé
  -- řádky zamknou v opačném pořadí, zaklesnout.
  WITH k_zavreni AS (
    SELECT o.id
      FROM public.email_outbox o
     WHERE o.status = 'sending'
       AND o.attempts >= 5
       AND COALESCE(o.claimed_at, o.created_at) < now() - interval '10 minutes'
     FOR UPDATE SKIP LOCKED
  )
  UPDATE public.email_outbox o
     SET status = 'failed',
         last_error = COALESCE(o.last_error, 'Odesílání se nedokončilo a vyčerpalo pokusy.')
    FROM k_zavreni z
   WHERE o.id = z.id;

  RETURN QUERY
  WITH vybrane AS (
    SELECT o.id
      FROM public.email_outbox o
     WHERE o.attempts < 5
       AND (o.status = 'pending'
            OR (o.status = 'sending'
                AND COALESCE(o.claimed_at, o.created_at) < now() - interval '10 minutes'))
     ORDER BY o.created_at
     FOR UPDATE SKIP LOCKED
     LIMIT _limit
  )
  UPDATE public.email_outbox o
     SET status     = 'sending',
         claimed_at = now(),
         attempts   = o.attempts + 1
    FROM vybrane v
   WHERE o.id = v.id
  RETURNING o.id, o.email, o.subject, o.body, o.attempts;
END;
$$;

COMMENT ON FUNCTION public.email_outbox_prevzit(int) IS
  'Vezme dávku e-mailů k odeslání a rovnou je označí jako rozpracované (FOR UPDATE SKIP LOCKED). Jen pro servisní klíč.';

-- Frontu obsluhuje jen server. Přihlášený uživatel ani nepřihlášený k tomu nemá důvod.
REVOKE ALL ON FUNCTION public.email_outbox_prevzit(int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.email_outbox_prevzit(int) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) notify_user: šablona, allowlist, kontrola adresy, ochrana proti duplicitě
-- -----------------------------------------------------------------------------
-- Celé tělo je vygenerované z `pg_get_functiondef` živé produkce a upravená je
-- jen ta část za `IF COALESCE(_enabled, false)`. Zbytek (vložení upozornění,
-- `created_by = auth.uid()`, návrat id) zůstává slovo od slova.
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
  _predmet text;
  _telo    text;
BEGIN
  IF _user IS NULL THEN RETURN NULL; END IF;

  INSERT INTO public.notifications (user_id, type, title, body, link, reservation_id, subject_id, created_by)
  VALUES (_user, _type, _title, _body, _link, _reservation_id, _subject_id, auth.uid())
  RETURNING id INTO _id;

  SELECT email_notifications_enabled INTO _enabled FROM public.settings LIMIT 1;
  IF COALESCE(_enabled, false) THEN
    -- Allowlist: typ bez šablony jde jen do aplikace, do pošty ne.
    SELECT s.subject, s.body INTO _predmet, _telo
      FROM public.email_sablona(_type, _title, _body, _link) s;

    IF _predmet IS NOT NULL THEN
      SELECT u.email INTO _email FROM auth.users u WHERE u.id = _user;

      -- Prázdná ani nesmyslná adresa není chyba, jen se nepošle.
      IF public.email_je_platny(_email) THEN
        INSERT INTO public.email_outbox (notification_id, user_id, email, subject, body)
        VALUES (_id, _user, _email, _predmet, _telo)
        ON CONFLICT (notification_id) WHERE notification_id IS NOT NULL DO NOTHING;
      END IF;
    END IF;
  END IF;

  RETURN _id;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_user(uuid, text, text, text, text, uuid, uuid) FROM public, anon, authenticated;

COMMENT ON FUNCTION public.notify_user(uuid, text, text, text, text, uuid, uuid) IS
  'Interní: zakládá upozornění v aplikaci a (jen při zapnutém odesílání a jen u typů se šablonou) e-mail do fronty. Volá se z RPC rezervací, ne z klienta.';

-- -----------------------------------------------------------------------------
-- 6) Zakladateli: „vaše akce čeká na potvrzení správce klubu"
-- -----------------------------------------------------------------------------
-- Tělo je vygenerované z `pg_get_functiondef` živé produkce (pozor: liší se od
-- původní migrace, větev (b) mezitím dostala dedup přes shodné razítko
-- `approved_at`). Měněná je jen větev (a), kam přibývá zpráva zakladateli.
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

    -- Zakladateli: jeho akce je zapsaná, ale do potvrzení správcem neplatí.
    -- Dosud se to nedozvěděl vůbec, viz hlavička migrace.
    PERFORM public.notify_user(
      NEW.created_by, 'reservation_pending',
      'Rezervace čeká na potvrzení',
      'Vaše rezervace za ' || COALESCE(_subject, 'klub') || ' (' || COALESCE(_sheet, 'dráha')
        || ', ' || _when || ') je zapsaná a čeká na potvrzení správce klubu.',
      '/calendar', NEW.id, NEW.subject_id);

    RETURN NULL;
  END IF;

  -- (b) zástupce potvrdil → dej vědět autorovi (u akce na obou drahách jen jednou)
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NULL AND NEW.approved_at IS NOT NULL
     AND NEW.created_by IS NOT NULL AND NEW.created_by <> COALESCE(NEW.approved_by, NEW.created_by) THEN
    -- Umlčet smí jen sourozenec potvrzený TOUŽ operací (stejné razítko — now() je
    -- v rámci příkazu konstantní). Jinak by zprávu spolkla dráha, která byla
    -- mezitím stornovaná nebo potvrzená dřív, a autor by se nedozvěděl nic.
    IF NEW.event_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.reservations r
       WHERE r.event_id = NEW.event_id AND r.id < NEW.id AND r.deleted_at IS NULL
         AND r.approved_at = NEW.approved_at
    ) THEN
      RETURN NULL;   -- zprávu pošle první rezervace ze stejného potvrzení
    END IF;

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

COMMENT ON COLUMN public.notifications.type IS
  'reservation_overridden | reservation_pending | reservation_needs_approval | reservation_approved | reservation_cancelled | reservation_changed | subject_request_approved';

-- -----------------------------------------------------------------------------
-- Sebekontrola
-- -----------------------------------------------------------------------------
DO $$
DECLARE _p text; _t text; _i record;
BEGIN
  -- Index se nekontroluje jen podle JMÉNA: `CREATE UNIQUE INDEX IF NOT EXISTS`
  -- porovnává taky jen jméno, takže index téhož jména s jinou definicí by
  -- migrace tiše nechala být a kontrola na jméno by to odkývala.
  SELECT x.indisunique AS unikatni, (x.indpred IS NOT NULL) AS castecny INTO _i
    FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
   WHERE c.relname = 'uq_email_outbox_notification';
  IF _i IS NULL OR NOT _i.unikatni OR NOT _i.castecny THEN
    RAISE EXCEPTION 'Index uq_email_outbox_notification chybí nebo nemá správný tvar.';
  END IF;

  -- Bez `sending` v CHECKu zemře fronta při prvním převzetí.
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conname = 'email_outbox_status_check') NOT LIKE '%sending%' THEN
    RAISE EXCEPTION 'CHECK na email_outbox nepouští stav sending.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'email_outbox'
                    AND column_name = 'claimed_at') THEN
    RAISE EXCEPTION 'Frontě chybí sloupec claimed_at.';
  END IF;

  -- Dosažitelnost RPC z API. `anon` tu byl původně opomenutý.
  IF has_function_privilege('authenticated', 'public.email_outbox_prevzit(int)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.email_outbox_prevzit(int)', 'EXECUTE') THEN
    RAISE EXCEPTION 'email_outbox_prevzit je dosažitelné z API.';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.email_outbox_prevzit(int)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Servisní role nemůže frontu převzít, odesílání by nešlo.';
  END IF;

  -- Tohle je ta bezpečnostní věta téhle migrace a dosud ji nekontrolovalo nic.
  IF has_table_privilege('authenticated', 'public.email_outbox', 'INSERT')
     OR has_table_privilege('authenticated', 'public.email_outbox', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.email_outbox', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated má pořád zápisová práva na frontu e-mailů.';
  END IF;
  -- Adminův přehled fronty naopak zůstat MUSÍ.
  IF NOT has_table_privilege('authenticated', 'public.email_outbox', 'SELECT') THEN
    RAISE EXCEPTION 'REVOKE ubral i SELECT, adminovi zmizí přehled fronty.';
  END IF;

  -- Že se `notify_user` opravdu přepsalo, a ne jen „migrace doběhla".
  IF (SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'notify_user') NOT LIKE '%email_sablona%' THEN
    RAISE EXCEPTION 'notify_user se nepřepsal, fronta by šla mimo šablony.';
  END IF;

  -- Allowlist: typ mimo matici nesmí mít šablonu.
  SELECT s.subject INTO _p FROM public.email_sablona('subject_request_approved', 'x', 'y', '/') s;
  IF _p IS NOT NULL THEN
    RAISE EXCEPTION 'Allowlist propouští typ mimo matici.';
  END IF;

  SELECT s.subject, s.body INTO _p, _t FROM public.email_sablona('reservation_approved', 'x', 'y', '/calendar') s;
  IF _p IS NULL OR _t NOT LIKE '%Curling Promo Ostrava%' THEN
    RAISE EXCEPTION 'Šablona potvrzené rezervace nedává tělo.';
  END IF;

  -- Uživatelem nastavený text nesmí do e-mailu propašovat vlastní odstavec.
  SELECT s.body INTO _t FROM public.email_sablona(
    'reservation_cancelled', 'x', E'Jan Novák\n\nUpozornění správce: potvrďte účet na zly-web.cz', '/calendar') s;
  IF _t LIKE E'%Novák\n\nUpozornění%' THEN
    RAISE EXCEPTION 'Šablona pouští do e-mailu cizí konce řádků.';
  END IF;

  -- Odkaz musí zůstat na našem webu.
  SELECT s.body INTO _t FROM public.email_sablona('reservation_approved', 'x', 'y', '.zly-web.cz/x') s;
  IF _t NOT LIKE '%netlify.app/calendar%' THEN
    RAISE EXCEPTION 'Šablona pustila do e-mailu cizí odkaz.';
  END IF;

  IF public.email_je_platny('jan.novak') OR public.email_je_platny('') OR NOT public.email_je_platny('a@b.cz') THEN
    RAISE EXCEPTION 'Kontrola adresy nefunguje.';
  END IF;

  RAISE NOTICE 'E-mailové notifikace: šablony, allowlist a pojistky jsou na místě.';
END $$;
