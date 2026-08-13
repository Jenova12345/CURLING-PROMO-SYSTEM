-- =============================================================================
-- B1+B2 — Základ dokladu: číselná řada, faktury, položky, immutabilita
-- =============================================================================
-- ROZSAH JE ZÁMĚRNĚ ÚZKÝ (rozhodnutí PM 13. 8. 2026): jedna svislá funkční věc
-- na demo — ruční „faktura na klik" v režimu NEPLÁTCE DPH. Bez DPH, bez dobropisů,
-- bez automatiky, bez evidence plateb. Co se odkládá, se odkládá vědomě a je to
-- vypsané v docs/etapa2-fakturace-plan.md.
--
-- Co se ale NEODKLÁDÁ, protože by se to nad ostrými doklady migrovalo draho:
--   • snapshot dodavatele i odběratele na faktuře (změna nastavení nesmí přepsat
--     historii — riziko 5 v plánu),
--   • `reservations.invoice_id` jako zámek proti dvojí fakturaci (rozhodnutí R1),
--   • immutabilita vystaveného dokladu (rozhodnutí R8),
--   • sloupce pro DPH jako prázdné místo (rozhodnutí R2). Nevyplňují se, ale
--     přidávat je později do tabulky s ostrými fakturami je přesně ten druh
--     migrace, které se chceme vyhnout.
--
-- VRATNOST:
--   ALTER TABLE public.reservations DROP COLUMN invoice_id, DROP COLUMN invoiced_at;
--   DROP TABLE public.invoice_items;
--   DROP TABLE public.invoices;
--   DROP TABLE public.invoice_counter;
--   DROP FUNCTION public.next_invoice_number(text, int);
--   DROP FUNCTION public.set_invoice_counter(text, int, int);
--   DROP FUNCTION public.guard_invoice_immutable();
--   DROP FUNCTION public.guard_invoice_item_immutable();
--   DROP FUNCTION public.recalc_invoice_totals();
--   DROP TYPE public.invoice_status; DROP TYPE public.invoice_kind;
-- POZOR: revert `DROP COLUMN invoice_id` ZTRATÍ zámky „už vyfakturováno“.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Enumy
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'invoice_status'
                  AND typnamespace = 'public'::regnamespace) THEN
    -- `stornovano` tu je od začátku, i když storno samo přijde později:
    -- přidat hodnotu do enumu jde, ale měnit stav u vystavených dokladů ne.
    CREATE TYPE public.invoice_status AS ENUM ('koncept', 'vystaveno', 'zaplaceno', 'stornovano');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'invoice_kind'
                  AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.invoice_kind AS ENUM ('klub', 'komercni');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2) Číselná řada
--
-- POČÍTADLO, NE SEKVENCE (rozhodnutí R5). `nextval` je netransakční: když se
-- transakce odrolluje, číslo se nevrátí a v řadě vznikne díra — a souvislou řadu
-- bez děr vyžaduje spec. Počítadlo v tabulce se s transakcí vrátí taky.
--
-- `set_invoice_counter` je tu pro navázání na doklady vystavené mimo systém
-- (papírově, v jiném nástroji) — bez něj by řada začala od jedničky a kolidovala.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoice_counter (
  rada      text    NOT NULL,
  rok       integer NOT NULL,
  posledni  integer NOT NULL DEFAULT 0,
  PRIMARY KEY (rada, rok),
  CONSTRAINT invoice_counter_posledni_nezaporne CHECK (posledni >= 0),
  CONSTRAINT invoice_counter_rok CHECK (rok BETWEEN 2000 AND 2999)
);

COMMENT ON TABLE public.invoice_counter IS
  'Počítadlo čísel faktur. Ne sekvence — ta je netransakční a při rollbacku by v řadě vznikla díra.';

/**
 * Přidělí další číslo v řadě. ATOMICKY: `INSERT … ON CONFLICT DO UPDATE … RETURNING`
 * je jediný příkaz, takže dva souběžné běhy nemůžou dostat totéž číslo — druhý
 * počká na zámek řádku.
 *
 * Vrací hotové číslo ve tvaru RRRRNNNN (např. 20260001).
 */
CREATE OR REPLACE FUNCTION public.next_invoice_number(_rada text, _rok integer)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _poradi integer;
  _uz_pouzite integer;
BEGIN
  -- Counter se umí dostat POD skutečně použitá čísla: papírový doklad, obnova ze
  -- zálohy, seed. Pak by první vystavení narazilo na UNIQUE, transakce se odrolluje
  -- — a s ní i counter, takže další pokus dostane totéž číslo. NAVŽDY.
  --
  -- Proto se bere maximum z counteru a z už vydaných čísel. Souběh to nerozbije:
  -- `ON CONFLICT DO UPDATE` zamkne řádek, takže druhá session počítá GREATEST
  -- už nad hodnotou, kterou zapsala první.
  SELECT COALESCE(max(right(cislo, 4)::integer), 0) INTO _uz_pouzite
    FROM public.invoices
   WHERE cislo IS NOT NULL AND cislo ~ ('^' || _rok::text || '\d{4}$');

  INSERT INTO public.invoice_counter (rada, rok, posledni)
  VALUES (_rada, _rok, GREATEST(1, _uz_pouzite + 1))
  ON CONFLICT (rada, rok) DO UPDATE
    SET posledni = GREATEST(public.invoice_counter.posledni, _uz_pouzite) + 1
  RETURNING posledni INTO _poradi;

  IF _poradi > 9999 THEN
    RAISE EXCEPTION 'Číselná řada % pro rok % je vyčerpaná (9999 dokladů).', _rada, _rok
      USING HINT = 'Formát RRRRNNNN má čtyřmístné pořadí. Další doklady potřebují jiný formát čísla.';
  END IF;

  RETURN _rok::text || lpad(_poradi::text, 4, '0');
END;
$$;

-- Včetně `service_role`: ta obchází RLS i granty, a přes počítadlo jde „spálit"
-- čísla nebo ho nastavit zpátky a vyrobit kolizi v řadě. Servisní zásahy mají jít
-- přes RPC, ne přes mechaniku řady.
REVOKE ALL ON FUNCTION public.next_invoice_number(text, integer)
  FROM anon, authenticated, public, service_role;

/**
 * Ruční nastavení počítadla — pro navázání na doklady vystavené mimo systém
 * (papírově, v jiném nástroji). Bez ní by řada začala od jedničky a kolidovala.
 *
 * Snížit počítadlo pod už vydaná čísla nejde: to je přesně ta cesta, jak vyrobit
 * duplicitní číslo faktury.
 */
CREATE OR REPLACE FUNCTION public.set_invoice_counter(_rada text, _rok integer, _hodnota integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _uz_pouzite integer;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Číselnou řadu nastavuje jen správce.';
  END IF;
  IF _hodnota < 0 OR _hodnota > 9999 THEN
    RAISE EXCEPTION 'Pořadí musí být mezi 0 a 9999 (dostal jsem %).', _hodnota;
  END IF;

  SELECT COALESCE(max(right(cislo, 4)::integer), 0) INTO _uz_pouzite
    FROM public.invoices
   WHERE cislo IS NOT NULL AND cislo ~ ('^' || _rok::text || '\d{4}$');

  IF _hodnota < _uz_pouzite THEN
    RAISE EXCEPTION 'Počítadlo nelze snížit pod už vydané číslo (nejvyšší vydané pořadí je %).', _uz_pouzite
      USING HINT = 'Snížení by vyrobilo duplicitní číslo faktury.';
  END IF;

  INSERT INTO public.invoice_counter (rada, rok, posledni) VALUES (_rada, _rok, _hodnota)
  ON CONFLICT (rada, rok) DO UPDATE SET posledni = _hodnota;

  RETURN _hodnota;
END;
$$;

REVOKE ALL ON FUNCTION public.set_invoice_counter(text, integer, integer) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_invoice_counter(text, integer, integer) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3) Faktury
--
-- SNAPSHOT OBOU STRAN je tu schválně. Kdyby se dodavatel i odběratel jen
-- odkazovali do `billing_settings` a `subjects`, změna nastavení by přepsala
-- i doklady vystavené před rokem — a doklad má být obrazem stavu v okamžiku
-- vystavení, ne pohledem na dnešek.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoices (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Číslo se přiděluje AŽ PŘI VYSTAVENÍ, koncept ho nemá. Kdyby ho dostal
  -- napřed, smazaný koncept by v řadě udělal díru.
  cislo        text UNIQUE,
  variabilni_symbol text,

  kind         public.invoice_kind   NOT NULL,
  status       public.invoice_status NOT NULL DEFAULT 'koncept',

  subject_id   uuid NOT NULL REFERENCES public.subjects(id),
  event_id     uuid REFERENCES public.events(id),   -- u komerční akce

  -- Období, za které se fakturuje (u klubu měsíc, u akce její den).
  obdobi_od    date NOT NULL,
  obdobi_do    date NOT NULL,

  datum_vystaveni  date,
  datum_splatnosti date,

  -- ---- Částky (rozhodnutí R3: stupňovitá kvantizace) -----------------------
  -- `total` je veličina pro KONTROLNÍ SOUČET, `total_rounded` je to, co platí
  -- zákazník. Sčítat se smí jen `total` — jinak se po deseti fakturách nasčítá
  -- per-fakturové zaokrouhlení.
  subtotal        numeric(12,2) NOT NULL DEFAULT 0,
  total           numeric(12,2) NOT NULL DEFAULT 0,
  total_rounded   numeric(12,2) NOT NULL DEFAULT 0,
  rounding_amount numeric(12,2) NOT NULL DEFAULT 0,

  -- ---- Snapshot dodavatele -------------------------------------------------
  dodavatel_nazev     text,
  dodavatel_adresa    text,
  dodavatel_ico       text,
  dodavatel_dic       text,
  dodavatel_rejstrik  text,
  dodavatel_ucet      text,
  dodavatel_iban      text,
  dodavatel_zprava    text,
  -- Režim DPH v době vystavení. Dnes vždy 'neplatce'; až hala přejde na plátce,
  -- staré doklady musí zůstat tím, čím byly.
  vat_mode            public.vat_mode NOT NULL DEFAULT 'neplatce',

  -- ---- Snapshot odběratele -------------------------------------------------
  odberatel_nazev   text,
  odberatel_adresa  text,
  odberatel_ico     text,
  odberatel_dic     text,

  -- ---- PDF (fáze C) --------------------------------------------------------
  pdf_path    text,
  pdf_sha256  text,

  -- ---- Audit ---------------------------------------------------------------
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES public.profiles(user_id),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES public.profiles(user_id),
  issued_at   timestamptz,
  issued_by   uuid REFERENCES public.profiles(user_id),

  CONSTRAINT invoices_obdobi CHECK (obdobi_do >= obdobi_od),
  -- Vystavený doklad MUSÍ mít číslo, koncept ho mít NESMÍ. Tohle je ta invarianta,
  -- která drží řadu souvislou.
  -- Vystavený doklad musí mít nejen číslo, ale i to, co z něj dělá doklad.
  -- Guard ho pak zmrazí navždy, takže prázdný snapshot by se už nedal doplnit.
  CONSTRAINT invoices_cislo_dle_stavu CHECK (
    (status = 'koncept' AND cislo IS NULL AND datum_vystaveni IS NULL)
    OR (status <> 'koncept'
        AND cislo IS NOT NULL AND datum_vystaveni IS NOT NULL
        AND datum_splatnosti IS NOT NULL
        AND dodavatel_nazev IS NOT NULL
        AND odberatel_nazev IS NOT NULL)
  ),
  -- Variabilní symbol = číslo bez nečíselných znaků, nejvýš 10 číslic.
  CONSTRAINT invoices_vs CHECK (variabilni_symbol IS NULL OR variabilni_symbol ~ '^\d{1,10}$'),
  CONSTRAINT invoices_castky_nezaporne CHECK (subtotal >= 0 AND total >= 0 AND total_rounded >= 0),
  -- Zaokrouhlení nesmí být „oprava" částky: nejvýš půl koruny.
  CONSTRAINT invoices_zaokrouhleni CHECK (abs(rounding_amount) <= 0.5),
  -- Zaokrouhlení musí být DOPOČET, ne samostatná hodnota. Bez tohohle prošlo
  -- total=1250,40 / total_rounded=1200 / rounding_amount=0,00 přes všechny CHECKy.
  CONSTRAINT invoices_zaokrouhleni_sedi CHECK (rounding_amount = total_rounded - total),
  CONSTRAINT invoices_total_sedi CHECK (total_rounded = round(round(total, 2), 0)),
  CONSTRAINT invoices_komercni_ma_akci CHECK (kind <> 'komercni' OR event_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_invoices_subject ON public.invoices (subject_id, obdobi_od);
CREATE INDEX IF NOT EXISTS idx_invoices_status  ON public.invoices (status);
CREATE INDEX IF NOT EXISTS idx_invoices_cislo   ON public.invoices (cislo) WHERE cislo IS NOT NULL;

COMMENT ON COLUMN public.invoices.total IS
  'Přesný součet bez zaokrouhlení na koruny. TOHLE se porovnává v kontrolním součtu, ne total_rounded.';

-- -----------------------------------------------------------------------------
-- 4) Položky faktury
--
-- `reservation_id` je PRAVDA A HISTORIE (rozhodnutí R1) — účetní invariant se
-- počítá odsud. `reservations.invoice_id` níž je jen zámek proti souběhu.
--
-- Řádek nese PLNÝ SNAPSHOT: hodiny, sazbu i částku. Bez toho by posun rezervace
-- přes `move_booking` tiše změnil částku na už vystavené faktuře (nález N1).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoice_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id  uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  -- Nullable schválně: slevový nebo storno řádek rezervaci mít nemusí.
  reservation_id uuid REFERENCES public.reservations(id),

  popis       text NOT NULL,
  datum       date,
  cas_od      timestamptz,
  cas_do      timestamptz,

  hodiny      numeric(6,2)  NOT NULL,
  sazba       numeric(10,2) NOT NULL,
  line_total  numeric(12,2) NOT NULL,

  -- ---- Prázdné místo pro DPH (rozhodnutí R2) -------------------------------
  -- V režimu neplátce zůstávají NULL. Vyplní se, až padne otázka Q7 (agregace
  -- po řádcích vs. z mezisoučtu za sazbu) — ta patří účetní klienta, ne nám.
  vat_rate    numeric(5,2),
  vat_base    numeric(12,2),
  vat_amount  numeric(12,2),

  poradi      integer NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT invoice_items_hodiny_kladne CHECK (hodiny > 0),
  CONSTRAINT invoice_items_sazba_nezaporna CHECK (sazba >= 0),
  -- Řádek musí sedět sám se sebou. Tohle je invariant z R3 zapsaný do schématu:
  -- vytištěná sazba × vytištěné hodiny == vytištěná částka.
  CONSTRAINT invoice_items_radek_sedi CHECK (line_total = round(hodiny * sazba, 2)),
  -- DPH sloupce mají v režimu neplátce zůstat NULL. Constraint je tu proto, že
  -- záporné `vat_amount` by stáhlo `total` pod nulu a shodilo CHECK na `invoices` —
  -- a ta chyba by vznikla uvnitř SECURITY DEFINER funkce, kde neplatí RLS, takže
  -- by Postgres do DETAILu vysypal celý řádek faktury i s IBANem.
  CONSTRAINT invoice_items_dph_nezaporne CHECK (
    (vat_rate   IS NULL OR vat_rate   >= 0) AND
    (vat_base   IS NULL OR vat_base   >= 0) AND
    (vat_amount IS NULL OR vat_amount >= 0)
  )
);

CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice ON public.invoice_items (invoice_id, poradi);
CREATE INDEX IF NOT EXISTS idx_invoice_items_reservation ON public.invoice_items (reservation_id)
  WHERE reservation_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 5) Zámek na rezervaci (rozhodnutí R1)
--
-- `invoice_items.reservation_id` je pravda, ale neumí zabránit souběhu: dva běhy
-- můžou přečíst „nevyfakturováno" zároveň. `reservations.invoice_id` to řeší
-- atomickým claimem `UPDATE … WHERE invoice_id IS NULL RETURNING`.
-- -----------------------------------------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS invoice_id  uuid REFERENCES public.invoices(id),
  ADD COLUMN IF NOT EXISTS invoiced_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_reservations_invoice ON public.reservations (invoice_id)
  WHERE invoice_id IS NOT NULL;
-- Index pro fakturační běh: co ještě není vyfakturované.
CREATE INDEX IF NOT EXISTS idx_reservations_nevyfakturovane
  ON public.reservations (subject_id, start_at)
  WHERE invoice_id IS NULL AND deleted_at IS NULL;

COMMENT ON COLUMN public.reservations.invoice_id IS
  'Zámek proti dvojí fakturaci (R1). Autoritou pro „sedí to" je billing_reconcile, ne tenhle sloupec.';

-- Guard musí nové sloupce ošetřit, jinak si je ne-admin nastaví sám při INSERTu.
--
-- Ověřeno útokem: `clen2` přes `POST /rest/v1/reservations` založil rezervaci
-- s `invoice_id` už vyplněným. Fakturační běh hledá `WHERE invoice_id IS NULL`,
-- takže by ji přeskočil NAVŽDY — led zdarma, a kontrolní součet by se rozešel
-- způsobem, který vypadá jako chyba systému, ne jako útok.
--
-- INSERT větev guardu je totiž výčet („co se od klienta přepisuje"), ne whitelist,
-- a komentář v booking_core.sql:89 to říká výslovně: kdo přidá sloupec, musí ho
-- do výčtu doplnit. Tahle migrace ty sloupce přidává, takže to je její práce.
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

  -- Servisní klíč (service_role) se sem dostane bez přihlášeného uživatele přes
  -- PostgREST. Zápis mu nepovolíme — obešel by kontrolu kolizí i schvalování —
  -- ale ať hláška rovnou řekne kudy, jinak to vypadá jako chyba oprávnění uživatele.
  IF auth.uid() IS NULL AND session_user = 'authenticator' THEN
    RAISE EXCEPTION 'Servisní zápis do rezervací jde jen přes RPC (create_booking, move_booking, cancel_booking, …)';
  END IF;

  -- Zápis z důvěryhodných RPC funkcí (public.create_booking a spol.), které samy ověřují
  -- práva, kolize a priority. GUC je transakčně lokální; přes PostgREST ho klient nenastaví
  -- a RPC funkce ho po svých zápisech samy vypínají, aby zvýšené oprávnění neplatilo
  -- pro zbytek transakce.
  IF current_setting('app.trusted_booking', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- ZÁMEK FAKTURACE stojí NAD adminskou výjimkou (doplněno v B1+B2).
  -- Admin má u rezervací jinak volnou ruku a je to správně. Tohle je ale účetní
  -- vazba: odpojit rezervaci od vystavené (a tím neměnné) faktury znamená, že se
  -- naúčtuje podruhé. Uvolnit ji smí jen storno nebo dobropis, tedy RPC — a ty si
  -- nastaví `app.trusted_booking`, takže sem vůbec nedojdou.
  IF TG_OP = 'UPDATE'
     AND (NEW.invoice_id IS DISTINCT FROM OLD.invoice_id
          OR NEW.invoiced_at IS DISTINCT FROM OLD.invoiced_at) THEN
    RAISE EXCEPTION 'Vazbu rezervace na fakturu mění jen fakturační funkce, ne přímý zápis.'
      USING HINT = 'Odpojit rezervaci od vystaveného dokladu lze jen stornem nebo dobropisem.';
  END IF;

  IF has_role(auth.uid(), 'admin') THEN
    RETURN NEW;  -- admin: bez omezení
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Zástupce i člen zakládají jen čistě klubovou rezervaci. Od klienta se přebírá
    -- pouze dráha, subjekt, čas a poznámka — všechno ostatní se tady přepisuje.
    -- (Kdo sem bude přidávat sloupec, musí ho v tomhle výčtu ošetřit; úpravy hlídá
    -- whitelist v UPDATE větvi níž.)
    NEW.created_at        := now();   -- rezervaci nelze zpětně datovat
    NEW.updated_at        := now();
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
    -- ← doplněno v B1+B2. Bez toho si ne-admin nastavil fakturační zámek sám
    --   a jeho rezervace navždy vypadla z fakturačního běhu.
    NEW.invoice_id        := NULL;
    NEW.invoiced_at       := NULL;
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

-- -----------------------------------------------------------------------------
-- 6) Immutabilita vystaveného dokladu (rozhodnutí R8)
--
-- POZOR: guard NESMÍ začínat `IF has_role(admin) THEN RETURN NEW` — u vystaveného
-- dokladu je neměnnost ZÁKONNÁ, ne provozní. To je rozdíl proti guardu na
-- rezervacích, kde je adminská výjimka správně.
--
-- Úniková cesta pro opravné migrace je jmenovitý GUC `app.invoice_repair`, aby
-- byla vidět v kódu i v auditu — ne tichá výjimka pro roli.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_invoice_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  _povolene text[] := ARRAY['status', 'pdf_path', 'pdf_sha256', 'updated_at', 'updated_by'];
  -- Sloupce, které dopočítává výhradně `recalc_invoice_totals` z položek.
  -- POZOR: až přijde evidence plateb (E2), musí se `_povolene` rozšířit ZÁROVEŇ
  -- s `ADD COLUMN` — jinak nepůjde zaplatit. Je to táž past, která právě spadla
  -- na `reservations` (guard tam nevynuloval nově přidané `invoice_id`).
  _dopocitane text[] := ARRAY['subtotal', 'total', 'total_rounded', 'rounding_amount'];
BEGIN
  -- GUC si smí nastavit jakákoli role, takže samotný přepínač by byl globální
  -- vypínač ZÁKONNÉ neměnnosti. Platí proto jen pod databázovou rolí — tedy
  -- z migrace nebo z psql, ne z klienta.
  IF current_setting('app.invoice_repair', true) = 'on'
     AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'koncept' THEN
      RETURN OLD;   -- koncept zahodit lze, ten ještě dokladem není
    END IF;
    -- `USING HINT` nedělá substituci `%`, takže se hodnoty skládají dopředu.
    RAISE EXCEPTION 'Vystavený doklad se nemaže. Řeší se opravným dokladem.'
      USING HINT = format('Faktura %s je ve stavu %s.', COALESCE(OLD.cislo, '(koncept)'), OLD.status);
  END IF;

  -- Součty se NIKDY nepíšou zvenčí, ani u konceptu. Dopočítává je `recalc_invoice_totals`
  -- z položek a ta si nastaví GUC. Bez téhle kontroly šlo u konceptu přepsat
  -- `subtotal` na cokoli a pak fakturu vystavit — a immutabilita by pak chránila
  -- to špatné číslo.
  IF current_setting('app.invoice_recalc', true) IS DISTINCT FROM 'on'
     AND EXISTS (
       SELECT 1
         FROM jsonb_each_text(to_jsonb(OLD)) o
         JOIN jsonb_each_text(to_jsonb(NEW)) n ON n.key = o.key
        WHERE o.value IS DISTINCT FROM n.value
          AND o.key = ANY (_dopocitane)
     ) THEN
    RAISE EXCEPTION 'Součty faktury se nezapisují ručně — dopočítávají se z položek.';
  END IF;

  -- Koncept je pracovní verze, ta se měnit smí.
  IF OLD.status = 'koncept' THEN
    RETURN NEW;
  END IF;

  -- U vystaveného dokladu smí měnit jen whitelist.
  IF EXISTS (
    SELECT 1
      FROM jsonb_each_text(to_jsonb(OLD)) o
      JOIN jsonb_each_text(to_jsonb(NEW)) n ON n.key = o.key
     WHERE o.value IS DISTINCT FROM n.value
       AND o.key <> ALL (_povolene)
  ) THEN
    RAISE EXCEPTION 'Vystavený doklad se needituje — měnit lze jen stav a PDF.'
      USING HINT = 'Oprava vystavené faktury se dělá opravným dokladem, ne přepsáním.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invoices_immutable ON public.invoices;
CREATE TRIGGER trg_invoices_immutable
  BEFORE UPDATE OR DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_immutable();

-- Položky vystaveného dokladu jsou neměnné úplně.
-- SECURITY DEFINER schválně: guard musí vidět VŠECHNY faktury, ne jen ty, na které
-- vidí volající. Jako INVOKER totiž RLS skryla cizí fakturu, `status` vyšel NULL
-- a guard to vyhodnotil jako „rodič mizí přes CASCADE" — tedy pustil zápis.
-- Ověřeno útokem: takhle šlo připsat řádek na CIZÍ VYSTAVENOU A ZAPLACENOU fakturu,
-- a se sazbou 0 se ani nezměnily součty, takže by si toho nikdo nevšiml.
CREATE OR REPLACE FUNCTION public.guard_invoice_item_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _stav public.invoice_status; _existuje boolean;
BEGIN
  IF current_setting('app.invoice_repair', true) = 'on'
     AND session_user IN ('postgres', 'supabase_admin') THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- OBĚ strany. `COALESCE(NEW.invoice_id, OLD.invoice_id)` je při UPDATE vždycky
  -- NEW, takže se kontrolovala jen CÍLOVÁ faktura — a řádek šlo z vystavené
  -- faktury ODSTĚHOVAT do konceptu. Ověřeno útokem: vystavený doklad zůstal
  -- s částkou v hlavičce a nulou řádků, peníze se přesunuly jinam.
  FOR _stav, _existuje IN
    SELECT i.status, true FROM public.invoices i
     WHERE i.id IN (COALESCE(NEW.invoice_id, OLD.invoice_id), COALESCE(OLD.invoice_id, NEW.invoice_id))
  LOOP
    IF _stav <> 'koncept' THEN
      RAISE EXCEPTION 'Položky vystaveného dokladu se nemění, ani se z něj nestěhují.'
        USING HINT = 'Oprava se dělá opravným dokladem.';
    END IF;
  END LOOP;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_invoice_items_immutable ON public.invoice_items;
CREATE TRIGGER trg_invoice_items_immutable
  BEFORE INSERT OR UPDATE OR DELETE ON public.invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_item_immutable();

-- -----------------------------------------------------------------------------
-- 7) Přepočet součtů (rozhodnutí R3)
--
-- Součty se NEPOČÍTAJÍ v aplikaci a neposílají do DB — dopočítává je databáze
-- z položek. Tím se nemůže stát, že hlavička říká něco jiného než řádky.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recalc_invoice_totals()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- OBĚ strany, ne `COALESCE(NEW, OLD)`: při UPDATE je to vždycky NEW, takže
  -- přesun řádku z jedné faktury na druhou by přepočítal jen cílovou a zdrojová
  -- by zůstala se starým součtem a bez řádků.
  _faktury uuid[] := ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[NEW.invoice_id, OLD.invoice_id]) x
                            WHERE x IS NOT NULL);
  _faktura  uuid;
  _subtotal numeric(12,2);
  _dph      numeric(12,2);
  _total    numeric(12,2);
BEGIN
  PERFORM set_config('app.invoice_recalc', 'on', true);

  FOREACH _faktura IN ARRAY _faktury LOOP
    SELECT COALESCE(sum(line_total), 0), COALESCE(sum(vat_amount), 0)
      INTO _subtotal, _dph
      FROM public.invoice_items WHERE invoice_id = _faktura;

    _total := _subtotal + _dph;

    -- Stupňovitě: na koruny se zaokrouhluje z už dvoudesetinné hodnoty
    -- (round(round(v,2),0)), nikdy ze surové. Viz R3.
    UPDATE public.invoices
       SET subtotal        = _subtotal,
           total           = _total,
           total_rounded   = round(round(_total, 2), 0),
           rounding_amount = round(round(_total, 2), 0) - _total
     WHERE id = _faktura;
  END LOOP;

  PERFORM set_config('app.invoice_recalc', 'off', true);
  RETURN NULL;

EXCEPTION
  -- Tahle funkce je SECURITY DEFINER, takže uvnitř neplatí RLS a Postgres by do
  -- chyby doplnil „Failing row contains (…)" s CELÝM řádkem faktury — tedy
  -- i s IBANem, IČO a částkami. PostgREST to u RPC přeposílá klientovi.
  -- Je to táž třída jako nález 8b, kterou uzavřela A5; tady se nesmí otevřít znovu.
  WHEN check_violation OR not_null_violation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'Součet faktury se nepodařilo přepočítat — položka má neplatnou hodnotu.'
      USING HINT = 'Zkontroluj hodiny, sazbu a částku na řádku.';
END;
$$;

DROP TRIGGER IF EXISTS trg_invoice_items_totals ON public.invoice_items;
CREATE TRIGGER trg_invoice_items_totals
  AFTER INSERT OR UPDATE OR DELETE ON public.invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.recalc_invoice_totals();

-- -----------------------------------------------------------------------------
-- 8) Audit a razítka
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_invoices_updated ON public.invoices;
CREATE TRIGGER trg_invoices_updated
  BEFORE UPDATE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_fields();

DROP TRIGGER IF EXISTS trg_invoices_audit ON public.invoices;
CREATE TRIGGER trg_invoices_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

DROP TRIGGER IF EXISTS trg_invoice_items_audit ON public.invoice_items;
CREATE TRIGGER trg_invoice_items_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- -----------------------------------------------------------------------------
-- 9) RLS a granty (rozhodnutí R8, druhá vrstva)
--
-- ŽÁDNÁ zápisová politika. Veškerý zápis jde přes SECURITY DEFINER RPC, takže
-- `PATCH /rest/v1/invoices` skončí na „permission denied" bez ohledu na roli —
-- a immutabilita se nedá obejít ani omylem.
-- -----------------------------------------------------------------------------
ALTER TABLE public.invoices        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_counter ENABLE ROW LEVEL SECURITY;

-- Včetně `service_role`: obchází RLS i granty a TRUNCATE navíc obchází řádkové
-- triggery, tedy i immutabilitu.
REVOKE ALL ON public.invoices        FROM anon, authenticated, public, service_role;
REVOKE ALL ON public.invoice_items   FROM anon, authenticated, public, service_role;
REVOKE ALL ON public.invoice_counter FROM anon, authenticated, public, service_role;

GRANT SELECT ON public.invoices      TO authenticated;
GRANT SELECT ON public.invoice_items TO authenticated;
-- `invoice_counter` nečte nikdo kromě RPC. Je to interní mechanika řady.

-- Triggerové a přepočtové funkce nemá volat nikdo zvenčí.
REVOKE ALL ON FUNCTION public.recalc_invoice_totals()        FROM anon, authenticated, public;
REVOKE ALL ON FUNCTION public.guard_invoice_immutable()      FROM anon, authenticated, public;
REVOKE ALL ON FUNCTION public.guard_invoice_item_immutable() FROM anon, authenticated, public;

DROP POLICY IF EXISTS invoices_select_admin ON public.invoices;
CREATE POLICY invoices_select_admin ON public.invoices
  FOR SELECT TO authenticated USING (has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS invoice_items_select_admin ON public.invoice_items;
CREATE POLICY invoice_items_select_admin ON public.invoice_items
  FOR SELECT TO authenticated USING (has_role(auth.uid(), 'admin'));

-- -----------------------------------------------------------------------------
-- 10) Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _politiky text;
BEGIN
  SELECT string_agg(DISTINCT cmd, ', ') INTO _politiky
    FROM pg_policies WHERE schemaname = 'public'
     AND tablename IN ('invoices', 'invoice_items', 'invoice_counter');
  IF _politiky IS DISTINCT FROM 'SELECT' THEN
    RAISE EXCEPTION 'B1+B2 selhala: na fakturách existuje jiná politika než SELECT (%).', _politiky;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.role_table_grants
              WHERE table_schema = 'public'
                AND table_name IN ('invoices', 'invoice_items', 'invoice_counter')
                AND grantee IN ('anon', 'PUBLIC')) THEN
    RAISE EXCEPTION 'B1+B2 selhala: anon má práva na fakturační tabulky.';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.role_table_grants
              WHERE table_schema = 'public' AND table_name IN ('invoices', 'invoice_items')
                AND grantee = 'authenticated'
                AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')) THEN
    RAISE EXCEPTION 'B1+B2 selhala: authenticated může do faktur zapisovat napřímo.';
  END IF;

  RAISE NOTICE 'B1+B2: základ dokladu hotový (řada, faktury, položky, immutabilita).';
END $$;
