-- =============================================================================
-- B5 (subset) — RPC pro ruční „fakturu na klik"
-- =============================================================================
-- Rozsah je úzký schválně (rozhodnutí PM 13. 8. 2026): založit koncept, vystavit,
-- zahodit koncept. Bez dobropisů, bez storna, bez evidence plateb, bez automatiky —
-- ty přijdou vlastními PR a mají svoje otevřené otázky.
--
-- ČTYŘI VĚCI, KTERÉ TADY NEJSOU NÁHODOU:
--
-- 1) **Do vystavené faktury nejde vložit položku** — guard z B1+B2 to blokuje.
--    Cesta proto musí být: založ KONCEPT → naplň položky → jedním UPDATE nastav
--    stav, číslo a datum. Ten poslední UPDATE projde jen proto, že `OLD.status`
--    je ještě `koncept`. Kdo to zkusí obráceně (nejdřív vystavit, pak plnit),
--    narazí na zeď, která vypadá jako chyba v guardu, ale je to jeho smysl.
--
-- 2) **Zápis do `reservations.invoice_id` guard odmítne i adminovi.** Fakturační
--    RPC si proto musí nastavit `app.trusted_booking`, přesně jako to dělají
--    rezervační funkce — a zase ho vypnout, ať zvýšené oprávnění neplatí pro
--    zbytek transakce.
--
--    Co když funkce selže MEZI zapnutím a vypnutím? Nic: `set_config(…, true)` je
--    transakčně lokální a EXCEPTION blok v plpgsql je subtransakce, takže se
--    hodnota při chybě vrátí sama. Spoléhat se na to smíme jen proto, že se GUC
--    nastavuje UVNITŘ funkce s tím blokem — kdyby ho někdo zapnul nad ní, platil
--    by dál.
--
-- 3) **Zabrání rezervací je atomické** (rozhodnutí R1): `UPDATE … WHERE
--    invoice_id IS NULL RETURNING` v jednom příkazu. Souběžný běh čeká na zámek
--    řádku a po jeho uvolnění už podmínku nesplní, takže tutéž rezervaci
--    nevyfakturuje podruhé. Položky se skládají VÝHRADNĚ z toho, co se podařilo
--    zabrat — ne z původního výběru.
--
-- 4) **Ceny se berou ze snapshotu na rezervaci**, nikdy se nepočítají znovu
--    z ceníku (`rate_per_hour`, `corrected_amount ?? amount`). Ceník se mění,
--    doklad ne.
--
-- ČTE SE ZE ZÁKLADNÍCH TABULEK, NE Z `reservations_billing` (nález N4): ten
-- pohled končí `AND has_role(auth.uid(), 'admin')`, takže pod cronem nebo
-- servisním klíčem vrátí nula řádků. Tady to zatím nevadí (RPC volá admin), ale
-- fáze D bude tytéž dotazy volat bez uživatele — a je levnější je mít správně
-- rovnou, než hledat, proč běh „úspěšně" nevystavil nic.
--
-- VRATNOST:
--   DROP VIEW IF EXISTS public.invoices_list;
--   DROP FUNCTION IF EXISTS public.create_invoice_draft_club(uuid, date, date);
--   DROP FUNCTION IF EXISTS public.create_invoice_draft_commercial(uuid);
--   DROP FUNCTION IF EXISTS public.nevyfakturovane_akce(uuid, date, date);
--   DROP FUNCTION IF EXISTS public.issue_invoice(uuid);
--   DROP FUNCTION IF EXISTS public.delete_invoice_draft(uuid);
--   DROP FUNCTION IF EXISTS public.fakturovatelne_rezervace(uuid, timestamptz, timestamptz);
--   DROP FUNCTION IF EXISTS public.obdobi_hranice(date, date);
-- POZOR NA POŘADÍ: `obdobi_hranice` volá i `billing_reconcile` z B6, takže B6 se
-- musí revertovat DŘÍV než tahle migrace — jinak zůstane kontrolní součet bez ní.
-- Data se nemění, takže revert nic neztrácí — kromě konceptů, které mezitím
-- vznikly (ty ale drží zámky na rezervacích, viz `delete_invoice_draft`).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Co je vůbec k fakturaci
--
-- Jedna definice pro obě RPC i pro kontrolní součet (B6). Kdyby si každá cesta
-- filtr opisovala vlastní, kontrolní součet by porovnával dvě různá čísla a
-- vypadalo by to jako chyba ve fakturaci.
--
-- `invoice_only_approved` je rozhodnutí PM k otázce Q4 (fakturují se JEN
-- schválené rezervace) a bydlí v `billing_settings`, ne v kódu — změna je UPDATE.
--
-- POZOR: funkce je SECURITY DEFINER, takže vidí na všechny rezervace bez ohledu
-- na RLS. Volat ji smí JEN jiná SECURITY DEFINER funkce — proto je EXECUTE
-- odebrané úplně všem, `authenticated` včetně, a práva si ověřuje každá RPC
-- zvlášť na svém začátku. (V `types.ts` se objeví jako volatelné RPC; není.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturovatelne_rezervace(
  _subject_id uuid,
  _od         timestamptz,
  _do         timestamptz          -- horní mez VÝLUČNĚ (půlotevřený interval)
)
RETURNS TABLE (
  id            uuid,
  start_at      timestamptz,
  end_at        timestamptz,
  sheet_name    text,
  event_title   text,
  hodiny        numeric,
  sazba         numeric,
  castka        numeric,
  invoice_id    uuid,
  approved_at   timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT r.id,
         r.start_at,
         r.end_at,
         sh.name,
         e.title,
         COALESCE(r.corrected_hours, r.hours)   AS hodiny,
         r.rate_per_hour                        AS sazba,
         COALESCE(r.corrected_amount, r.amount) AS castka,
         r.invoice_id,
         r.approved_at
    FROM public.reservations r
    JOIN public.sheets sh ON sh.id = r.sheet_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.status = 'confirmed'
     AND r.deleted_at IS NULL
     -- Bez subjektu není komu fakturovat: interní tréninky a údržba ledu.
     AND r.subject_id IS NOT NULL
     AND (_subject_id IS NULL OR r.subject_id = _subject_id)
     AND r.start_at >= _od
     AND r.start_at <  _do
     AND (r.approved_at IS NOT NULL
          OR NOT COALESCE((SELECT bs.invoice_only_approved FROM public.billing_settings bs LIMIT 1), true))
   ORDER BY r.start_at, r.id;
$$;

REVOKE ALL ON FUNCTION public.fakturovatelne_rezervace(uuid, timestamptz, timestamptz)
  FROM anon, authenticated, public, service_role;

COMMENT ON FUNCTION public.fakturovatelne_rezervace(uuid, timestamptz, timestamptz) IS
  'Jediná definice „co je k fakturaci". Čte základní tabulky, ne pohled reservations_billing (nález N4 — ten pod cronem vrátí nula řádků). Nezahrnuje filtr na invoice_id: volající si vybere, jestli chce ještě nezabrané, nebo všechno.';

-- -----------------------------------------------------------------------------
-- 2) Období v pražském čase
--
-- Rezervace jsou `timestamptz`, období na faktuře je `date`. Převod se musí dít
-- na JEDNOM místě, jinak se „srpen" pro fakturu a „srpen" pro kontrolní součet
-- rozejdou o dvě hodiny — a rozdíl se projeví jen u rezervací kolem půlnoci
-- na přelomu měsíce, tedy přesně tam, kde si toho nikdo nevšimne.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obdobi_hranice(_od date, _do date)
RETURNS TABLE (zacatek timestamptz, konec timestamptz)
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT (_od::timestamp            AT TIME ZONE 'Europe/Prague'),
         ((_do + 1)::timestamp      AT TIME ZONE 'Europe/Prague');
$$;

-- Neuniká přes ni nic (čistá datová aritmetika, není SECURITY DEFINER), ale
-- zůstat jako jediná funkce PR s EXECUTE pro `anon` a `service_role` nemá důvod.
REVOKE ALL ON FUNCTION public.obdobi_hranice(date, date) FROM anon, authenticated, public, service_role;

COMMENT ON FUNCTION public.obdobi_hranice(date, date) IS
  'Období faktury (obě data VČETNĚ) na půlotevřený interval [zacatek, konec) v pražském čase.';

-- -----------------------------------------------------------------------------
-- 3) Koncept souhrnné faktury klubu (spec 2B: řádek = jedna rezervace)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_invoice_draft_club(
  _subject_id uuid,
  _obdobi_od  date,
  _obdobi_do  date
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid      uuid := auth.uid();
  _invoice  uuid;
  _od       timestamptz;
  _do       timestamptz;
  _pocet    integer;
  _bez_ceny integer;
  _ukazky   text;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;
  IF _obdobi_od IS NULL OR _obdobi_do IS NULL OR _obdobi_do < _obdobi_od THEN
    RAISE EXCEPTION 'Neplatné období faktury (od % do %).', _obdobi_od, _obdobi_do;
  END IF;
  -- `deleted_at` schválně: fakturovat za skrytý subjekt je skoro jistě omyl.
  -- (Doklad na už vystavené faktuře zůstane čitelný — snapshot odběratele je na ní.)
  IF NOT EXISTS (SELECT 1 FROM public.subjects WHERE id = _subject_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Subjekt neexistuje nebo je skrytý.';
  END IF;

  SELECT zacatek, konec INTO _od, _do FROM public.obdobi_hranice(_obdobi_od, _obdobi_do);

  -- Rezervace bez sazby by se do dokladu nedostala (`sazba` je NOT NULL) a tiše
  -- by z faktury vypadla — což je přesně ten rozdíl, který má kontrolní součet
  -- odhalit. Radši nevystavit nic než vystavit neúplné.
  -- Kontroluje se i NULA, ne jen NULL: A2 pouští `corrected_hours = 0` a odepsat
  -- klubu hodinu na nulu („nedorazili, neúčtujeme") je přirozený postup. Položka
  -- by pak narazila na `invoice_items_hodiny_kladne` a celá měsíční faktura by
  -- spadla na neutrální hlášku z EXCEPTION bloku — admin by neměl jak zjistit,
  -- KTERÁ rezervace za to může. Hláška proto rovnou jmenuje termíny.
  SELECT count(*), string_agg(to_char(f.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI'), ', '
                              ORDER BY f.start_at)
    INTO _bez_ceny, _ukazky
    FROM public.fakturovatelne_rezervace(_subject_id, _od, _do) f
   WHERE f.invoice_id IS NULL
     AND (f.sazba IS NULL OR f.hodiny IS NULL OR f.hodiny <= 0);
  IF _bez_ceny > 0 THEN
    RAISE EXCEPTION 'Období obsahuje % rezervací bez sazby nebo s nulovými hodinami (%).', _bez_ceny, _ukazky
      USING HINT = 'Nulovou korekci zruš, nebo rezervaci stornuj — na doklad nulový řádek nepatří.';
  END IF;

  INSERT INTO public.invoices (kind, status, subject_id, obdobi_od, obdobi_do, created_by, updated_by)
  VALUES ('klub', 'koncept', _subject_id, _obdobi_od, _obdobi_do, _uid, _uid)
  RETURNING id INTO _invoice;

  -- Zabrání rezervací a naplnění položek v JEDNOM příkazu: co se nepodařilo
  -- zabrat (mezitím je zabral jiný běh), se do položek vůbec nedostane.
  PERFORM set_config('app.trusted_booking', 'on', true);

  WITH zabrane AS (
    UPDATE public.reservations r
       SET invoice_id  = _invoice,
           invoiced_at = now()
     -- `ORDER BY id FOR UPDATE` v poddotazu: obě fakturační RPC musí zamykat řádky
     -- ve STEJNÉM pořadí. Bez toho jely každá po jiném plánu (klub přes function
     -- scan, komerce přes index na `event_id`) a při souběhu o tytéž rezervace
     -- vznikl deadlock — reprodukovatelně. Data se nerozbila, ale poražený dostal
     -- holou postgresovou hlášku; ve fázi D (běh vedle ručního kliknutí) by to
     -- trefovalo pravidelně.
     WHERE r.id IN (
       SELECT r2.id FROM public.reservations r2
        WHERE r2.id IN (SELECT f.id FROM public.fakturovatelne_rezervace(_subject_id, _od, _do) f
                         WHERE f.invoice_id IS NULL)
        ORDER BY r2.id
        FOR UPDATE
     )
       -- NOSNÁ PODMÍNKA, NE DUPLICITA. V READ COMMITTED se po čekání na zámek
       -- přehodnocuje jen kvalifikace nad NOVOU verzí cílového řádku; podmínka
       -- schovaná uvnitř funkce se vyhodnocuje proti PŮVODNÍMU snapshotu příkazu,
       -- tedy proti stavu před cizím COMMITem. Kdo tenhle řádek uklidí jako
       -- nadbytečný, otevře dvojí fakturaci.
       AND r.invoice_id IS NULL          -- ← vlastní atomický claim (R1)
    RETURNING r.id, r.start_at, r.end_at, r.sheet_id, r.event_id,
              COALESCE(r.corrected_hours, r.hours)   AS hodiny,
              r.rate_per_hour                        AS sazba,
              COALESCE(r.corrected_amount, r.amount) AS castka
  )
  INSERT INTO public.invoice_items
    (invoice_id, reservation_id, popis, datum, cas_od, cas_do, hodiny, sazba, line_total, poradi)
  SELECT _invoice,
         z.id,
         concat_ws(' — ',
           'Pronájem ledové plochy',
           sh.name,
           nullif(e.title, '')),
         (z.start_at AT TIME ZONE 'Europe/Prague')::date,
         z.start_at,
         z.end_at,
         z.hodiny,
         z.sazba,
         z.castka,
         row_number() OVER (ORDER BY z.start_at, z.id)
    FROM zabrane z
    JOIN public.sheets sh ON sh.id = z.sheet_id
    LEFT JOIN public.events e ON e.id = z.event_id;

  GET DIAGNOSTICS _pocet = ROW_COUNT;
  PERFORM set_config('app.trusted_booking', 'off', true);

  IF _pocet = 0 THEN
    -- Prázdná faktura se nevystavuje (spec, okrajové případy).
    --
    -- Koncept se schválně NEMAŽE ručně: `RAISE` má SQLSTATE P0001, takže ho
    -- vlastní EXCEPTION blok téhle funkce (chytá jen porušení constraintů)
    -- nezachytí — propadne ven, subtransakce se odrolluje a INSERT hlavičky
    -- zmizí s ní. `DELETE` navíc by byl kód, který nikdy nic neudělá.
    RAISE EXCEPTION 'Za zvolené období není co fakturovat.'
      USING HINT = 'Buď v období nejsou zpoplatněné rezervace, nebo už jsou všechny vyfakturované, nebo čekají na schválení zástupcem klubu.';
  END IF;

  RETURN _invoice;

EXCEPTION
  -- Deadlock je dostupnostní věc, ne účetní: data zůstanou v pořádku, ale
  -- poražený by jinak dostal holou postgresovou hlášku. Ať aspoň ví, co má udělat.
  WHEN deadlock_detected THEN
    RAISE EXCEPTION 'Fakturu právě zakládá někdo jiný — zkus to prosím znovu.'
      USING ERRCODE = '40P01';
  -- Uvnitř SECURITY DEFINER neplatí RLS, takže Postgres do chyby doplní
  -- „Failing row contains (…)" s celým řádkem — a PostgREST ho u RPC pošle
  -- klientovi. U faktury je v tom řádku snapshot dodavatele i s IBANem
  -- (rozhodnutí R11, nález 8b). Chyba se proto překládá na neutrální hlášku.
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Fakturu se nepodařilo sestavit — data rezervací neodpovídají pravidlům dokladu.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj hodiny, sazbu a částky rezervací v období.';
END;
$$;

REVOKE ALL ON FUNCTION public.create_invoice_draft_club(uuid, date, date)
  FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_invoice_draft_club(uuid, date, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4) Koncept faktury za komerční akci (spec 2A: 1 doklad = 1 akce)
--
-- Období se nezadává — vychází z akce samotné. Odběratele bere z rezervací akce,
-- ne z parametru: `create_booking` u komerční akce subjekt vyžaduje, takže je
-- vždycky právě jeden, a hádat ho zvenčí by šlo splést.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_invoice_draft_commercial(_event_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid        uuid := auth.uid();
  _invoice    uuid;
  _subject_id uuid;
  _subjektu   integer;
  _od         date;
  _do         date;
  _pocet      integer;
  _bez_ceny   integer;
  _jen_schvalene boolean;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = _event_id) THEN
    RAISE EXCEPTION 'Akce neexistuje.';
  END IF;

  -- `min()` na uuid v Postgresu není, proto `array_agg(DISTINCT …)[1]`. Prvek se
  -- bere až po kontrole, že je subjekt právě jeden, takže na pořadí nezáleží.
  SELECT count(DISTINCT r.subject_id),
         (array_agg(DISTINCT r.subject_id))[1],
         min((r.start_at AT TIME ZONE 'Europe/Prague')::date),
         max((r.start_at AT TIME ZONE 'Europe/Prague')::date)
    INTO _subjektu, _subject_id, _od, _do
    FROM public.reservations r
   WHERE r.event_id = _event_id
     AND r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL;

  IF COALESCE(_subjektu, 0) = 0 THEN
    RAISE EXCEPTION 'K akci nejsou žádné zpoplatněné rezervace.'
      USING HINT = 'Buď je akce bez zákazníka, nebo jsou její rezervace stornované.';
  END IF;
  IF _subjektu > 1 THEN
    -- Nikdy by nemělo nastat (create_booking drží jeden subjekt na akci), ale
    -- hádat, komu se má doklad vystavit, je horší než se zeptat.
    RAISE EXCEPTION 'Akce má rezervace pro víc odběratelů — fakturu vystav ručně po subjektech.';
  END IF;

  SELECT COALESCE(bs.invoice_only_approved, true) INTO _jen_schvalene
    FROM public.billing_settings bs LIMIT 1;
  _jen_schvalene := COALESCE(_jen_schvalene, true);

  SELECT count(*) INTO _bez_ceny
    FROM public.reservations r
   WHERE r.event_id = _event_id AND r.status = 'confirmed' AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL AND r.invoice_id IS NULL
     AND (NOT _jen_schvalene OR r.approved_at IS NOT NULL)
     AND (r.rate_per_hour IS NULL OR COALESCE(r.corrected_hours, r.hours) IS NULL);
  IF _bez_ceny > 0 THEN
    RAISE EXCEPTION 'Akce obsahuje % rezervací bez sazby nebo bez hodin — doklad by byl neúplný.', _bez_ceny
      USING HINT = 'Doplň sazbu u rezervace (nebo ceník) a založ fakturu znovu.';
  END IF;

  INSERT INTO public.invoices (kind, status, subject_id, event_id, obdobi_od, obdobi_do, created_by, updated_by)
  VALUES ('komercni', 'koncept', _subject_id, _event_id, _od, _do, _uid, _uid)
  RETURNING id INTO _invoice;

  PERFORM set_config('app.trusted_booking', 'on', true);

  WITH zabrane AS (
    UPDATE public.reservations r
       SET invoice_id  = _invoice,
           invoiced_at = now()
     -- Totéž pořadí zámků jako u klubové cesty, ze stejného důvodu (deadlock).
     WHERE r.id IN (
       SELECT r2.id FROM public.reservations r2
        WHERE r2.event_id = _event_id
          AND r2.status = 'confirmed'
          AND r2.deleted_at IS NULL
          AND r2.subject_id IS NOT NULL
          AND r2.invoice_id IS NULL
          -- Rozhodnutí PM k Q4 platí na OBOU cestách. Dřív ho ctila jen klubová,
          -- takže by komerční akce vyfakturovala i neschválenou rezervaci — a rozdíl
          -- by se objevil až v kontrolním součtu jako nevysvětlitelný.
          AND (NOT _jen_schvalene OR r2.approved_at IS NOT NULL)
        ORDER BY r2.id
        FOR UPDATE
     )
       AND r.invoice_id IS NULL          -- ← nosná podmínka, viz klubová cesta
    RETURNING r.id, r.start_at, r.end_at, r.sheet_id,
              COALESCE(r.corrected_hours, r.hours)   AS hodiny,
              r.rate_per_hour                        AS sazba,
              COALESCE(r.corrected_amount, r.amount) AS castka
  )
  INSERT INTO public.invoice_items
    (invoice_id, reservation_id, popis, datum, cas_od, cas_do, hodiny, sazba, line_total, poradi)
  SELECT _invoice,
         z.id,
         concat_ws(' — ', 'Pronájem ledové plochy', sh.name,
                   nullif((SELECT e.title FROM public.events e WHERE e.id = _event_id), '')),
         (z.start_at AT TIME ZONE 'Europe/Prague')::date,
         z.start_at,
         z.end_at,
         z.hodiny,
         z.sazba,
         z.castka,
         row_number() OVER (ORDER BY z.start_at, z.id)
    FROM zabrane z
    JOIN public.sheets sh ON sh.id = z.sheet_id;

  GET DIAGNOSTICS _pocet = ROW_COUNT;
  PERFORM set_config('app.trusted_booking', 'off', true);

  IF _pocet = 0 THEN
    -- Hlavičku netřeba mazat, viz tentýž případ v `create_invoice_draft_club`.
    RAISE EXCEPTION 'Akce je už celá vyfakturovaná.';
  END IF;

  RETURN _invoice;

EXCEPTION
  WHEN deadlock_detected THEN
    RAISE EXCEPTION 'Fakturu právě zakládá někdo jiný — zkus to prosím znovu.'
      USING ERRCODE = '40P01';
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Fakturu se nepodařilo sestavit — data rezervací neodpovídají pravidlům dokladu.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj hodiny, sazbu a částky rezervací akce.';
END;
$$;

REVOKE ALL ON FUNCTION public.create_invoice_draft_commercial(uuid) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_invoice_draft_commercial(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4b) Co ještě čeká na fakturu u komerčního odběratele
--
-- Bez tohohle by druhý typ dokladu (spec 2A: 1 doklad = 1 akce) neměl v UI jak
-- vzniknout: „Kdo dluží" ukazuje součty po subjektech, ne po akcích, a `event_id`
-- ve svém pohledu vůbec nemá. Vracet rovnou seznam akcí je levnější než rozšiřovat
-- pohled z Etapy 1, do kterého tenhle PR sahat nemá.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nevyfakturovane_akce(
  _subject_id uuid,
  _obdobi_od  date,
  _obdobi_do  date
)
RETURNS TABLE (event_id uuid, nazev text, den date, rezervaci bigint, castka numeric)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _od timestamptz; _do timestamptz; _jen_schvalene boolean;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Podklady k fakturaci vidí jen správce haly.';
  END IF;
  SELECT zacatek, konec INTO _od, _do FROM public.obdobi_hranice(_obdobi_od, _obdobi_do);
  SELECT COALESCE(bs.invoice_only_approved, true) INTO _jen_schvalene
    FROM public.billing_settings bs LIMIT 1;
  _jen_schvalene := COALESCE(_jen_schvalene, true);

  -- OBDOBÍ VYBÍRÁ AKCE, ALE NEOŘEZÁVÁ ČÁSTKU.
  --
  -- `create_invoice_draft_commercial` fakturuje CELOU akci (spec 2A: 1 doklad =
  -- 1 akce) a datum v ní nefiguruje. Kdyby náhled sčítal jen rezervace spadlé do
  -- zobrazeného období, akce přes přelom měsíce by v dialogu ukázala „1 rezervace,
  -- 3 400 Kč" a vystavila by doklad na dvě položky a 6 800 Kč — admin by odklikl
  -- číslo, které nikdy neviděl. Podmnožinu `WHERE` proto mají obě funkce
  -- TOTOŽNOU; období se uplatní jen na výběr akcí přes `EXISTS`.
  RETURN QUERY
  SELECT e.id,
         e.title,
         min((r.start_at AT TIME ZONE 'Europe/Prague')::date),
         count(*),
         sum(COALESCE(r.corrected_amount, r.amount))
    FROM public.reservations r
    JOIN public.events e ON e.id = r.event_id
   WHERE r.subject_id = _subject_id
     AND r.invoice_id IS NULL
     AND r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND (NOT _jen_schvalene OR r.approved_at IS NOT NULL)
     AND EXISTS (
       SELECT 1 FROM public.reservations r2
        WHERE r2.event_id = e.id
          AND r2.invoice_id IS NULL
          AND r2.status = 'confirmed'
          AND r2.deleted_at IS NULL
          AND r2.start_at >= _od
          AND r2.start_at <  _do
     )
   GROUP BY e.id, e.title

  UNION ALL

  -- REZERVACE BEZ AKCE. Bez tohohle řádku byly nevyfakturovatelné vůbec:
  -- UI posílá každý nekulubový subjekt do dialogu akcí a ten je (přes INNER JOIN
  -- na `events`) neviděl. Peníze pak zůstaly v `k_fakturaci` navždy a `rozdil`
  -- byl přitom nula — přesně ta třída tichého rozdílu, kvůli které kontrolní
  -- součet existuje. `event_id IS NULL` říká volajícímu „na tohle použij
  -- souhrnnou fakturu za období", ne „za akci".
  SELECT NULL::uuid,
         'Rezervace bez akce',
         min((r.start_at AT TIME ZONE 'Europe/Prague')::date),
         count(*),
         sum(COALESCE(r.corrected_amount, r.amount))
    FROM public.reservations r
   WHERE r.subject_id = _subject_id
     AND r.event_id IS NULL
     AND r.invoice_id IS NULL
     AND r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND (NOT _jen_schvalene OR r.approved_at IS NOT NULL)
     AND r.start_at >= _od
     AND r.start_at <  _do
  HAVING count(*) > 0

   ORDER BY 3, 2;

EXCEPTION
  -- Tentýž důvod jako u `delete_invoice_draft`: čte se přes `reservations`, ale
  -- funkce je SECURITY DEFINER a R11 platí plošně, ne jen tam, kde je dnes vidět
  -- konkrétní cesta.
  WHEN check_violation OR not_null_violation THEN
    RAISE EXCEPTION 'Podklady k fakturaci se nepodařilo sestavit.'
      USING ERRCODE = '22023';
END;
$$;

REVOKE ALL ON FUNCTION public.nevyfakturovane_akce(uuid, date, date) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.nevyfakturovane_akce(uuid, date, date) TO authenticated;

-- -----------------------------------------------------------------------------
-- 5) Vystavení dokladu
--
-- POŘADÍ OPERACÍ (rozhodnutí R5): číslo se přiděluje atomicky v transakci a
-- doklad je od té chvíle vystavený. PDF se řeší až potom a smí selhat — faktura
-- bez PDF je platný doklad se štítkem „PDF se generuje", kdežto díra v číselné
-- řadě je vada, kterou spec zakazuje.
--
-- SNAPSHOT SE DĚLÁ AŽ TADY, ne u konceptu: doklad má být obrazem stavu v okamžiku
-- VYSTAVENÍ. Kdyby se snapshot bral při založení konceptu, změna fakturačních
-- údajů mezi konceptem a vystavením by se do dokladu nedostala — a to je vada,
-- protože platí ta v okamžiku vystavení.
--
-- JEDEN UPDATE, ne dva: guard z B1+B2 pustí zápis jen dokud je `OLD.status`
-- rovno `koncept`. Druhý UPDATE už by narazil na immutabilitu.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.issue_invoice(_invoice_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid      uuid := auth.uid();
  _f        record;
  _bs       record;
  _sub      record;
  _cislo    text;
  _rada     text;
  _rok      integer;
  _dnes     date;
  _chybi    text[] := ARRAY[]::text[];
  _splatnost date;
  _zrusenych integer;
  _ukazky    text;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;

  -- Zámek řádku: dvě souběžná kliknutí na „Vystavit" jinak vyrobí dvě čísla,
  -- z nichž jedno spadne na immutabilitě — a v řadě zůstane díra.
  SELECT * INTO _f FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Faktura neexistuje.';
  END IF;
  IF _f.status <> 'koncept' THEN
    RAISE EXCEPTION 'Vystavit lze jen koncept (tenhle doklad je ve stavu %).', _f.status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.invoice_items WHERE invoice_id = _invoice_id) THEN
    RAISE EXCEPTION 'Prázdná faktura se nevystavuje.';
  END IF;

  SELECT * INTO _bs FROM public.billing_settings LIMIT 1;
  SELECT * INTO _sub FROM public.subjects WHERE id = _f.subject_id;

  -- ÚPLNOST ÚDAJŮ. Spec (okrajové případy) to žádá výslovně: neúplné údaje →
  -- fakturu nevystavit a upozornit admina. Hláška proto vyjmenuje, CO chybí —
  -- „nelze vystavit" bez důvodu je pro admina slepá ulička.
  IF _bs IS NULL OR nullif(btrim(coalesce(_bs.supplier_name, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'název dodavatele');
  END IF;
  IF _bs IS NULL OR nullif(btrim(coalesce(_bs.supplier_address, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'sídlo dodavatele');
  END IF;
  IF _bs IS NULL OR nullif(btrim(coalesce(_bs.supplier_ico, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'IČO dodavatele');
  END IF;
  IF _bs IS NULL OR (nullif(btrim(coalesce(_bs.bank_account, '')), '') IS NULL
                     AND nullif(btrim(coalesce(_bs.bank_iban, '')), '') IS NULL) THEN
    _chybi := array_append(_chybi, 'bankovní účet dodavatele');
  END IF;
  IF nullif(btrim(coalesce(_sub.name, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'název odběratele');
  END IF;
  -- IČO odběratele se vyžaduje u FIRMY, ne u klubu. Spolky ho v systému běžně
  -- vyplněné nemají a zablokovat jim fakturu by znamenalo nevyfakturovat led —
  -- kdežto u komerční akce je odběratelem firma a IČO je náležitost dokladu.
  IF _sub.type = 'commercial' AND nullif(btrim(coalesce(_sub.ico, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'IČO odběratele (firmy)');
  END IF;
  -- Sídlo odběratele je náležitost dokladu (spec, bod 3) u klubu i u firmy.
  IF nullif(btrim(coalesce(_sub.address, '')), '') IS NULL THEN
    _chybi := array_append(_chybi, 'sídlo odběratele');
  END IF;

  -- REŽIM DPH: doklad umí zatím jen neplátce. Sloupce `vat_*` na položkách jsou
  -- prázdné místo (čekají na otázku Q7 od účetní), takže v plátcovském režimu by
  -- doklad vyšel bez vyčíslené daně A ZÁROVEŇ bez doložky — vypadal by jako
  -- neplátcovský, aniž by to řekl. Radši nevystavit než vystavit doklad, který
  -- o svém daňovém režimu mlčí.
  IF COALESCE(_bs.vat_mode, 'neplatce') <> 'neplatce' THEN
    RAISE EXCEPTION 'Doklad umí zatím jen režim neplátce DPH (nastaveno: %).', _bs.vat_mode
      USING HINT = 'Plátcovský režim potřebuje dopočet DPH na položkách — čeká na rozhodnutí účetní (otázka Q7).';
  END IF;

  IF array_length(_chybi, 1) > 0 THEN
    RAISE EXCEPTION 'Fakturu nelze vystavit — chybí: %.', array_to_string(_chybi, ', ')
      USING HINT = 'Doplň údaje v Nastavení → Fakturace, případně u odběratele (načtením z ARESu).';
  END IF;

  -- ZRUŠENÁ REZERVACE NA KONCEPTU. Klub odvolá termín, který zrovna visí na
  -- konceptu — běžná posloupnost, ne exotika. Bez téhle kontroly se doklad
  -- vystaví, stane se neměnným, a `billing_health.vyfakturovane_zrusene` se ozve
  -- AŽ POTOM: hlásí přesně ve chvíli, kdy se s tím už nedá nic dělat, protože
  -- storno ani dobropis v tomhle rozsahu nejsou. Detekce po činu je u nevratného
  -- kroku k ničemu — tady musí stát prevence.
  SELECT count(*), string_agg(to_char(r.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI'), ', '
                              ORDER BY r.start_at)
    INTO _zrusenych, _ukazky
    FROM public.invoice_items it
    JOIN public.reservations r ON r.id = it.reservation_id
   WHERE it.invoice_id = _invoice_id
     AND (r.deleted_at IS NOT NULL OR r.status <> 'confirmed');

  IF _zrusenych > 0 THEN
    RAISE EXCEPTION 'Na konceptu je % zrušených rezervací (%) — doklad by účtoval led, který se nekonal.',
      _zrusenych, _ukazky
      USING HINT = 'Zahoď koncept a založ ho znovu; zrušené rezervace už do něj nespadnou.';
  END IF;

  -- Číslo až tady, ne u konceptu: smazaný koncept by jinak udělal v řadě díru.
  --
  -- POZOR NA `current_date`: databáze běží v UTC, takže 1. ledna v 00:30 pražského
  -- času je `current_date` pořád 31. prosince. Doklad by dostal LOŇSKÝ rok v čísle
  -- a včerejší datum vystavení — chyba, která se stane jednou za rok, projeví se
  -- na číselné řadě a odhalí se v únoru. Zbytek modulu počítá pražsky
  -- (`obdobi_hranice`), tak ať i tohle.
  _dnes := (now() AT TIME ZONE 'Europe/Prague')::date;
  _rok  := EXTRACT(year FROM _dnes)::integer;

  -- ODDĚLENÉ ŘADY NEJSOU IMPLEMENTOVANÉ a tenhle blok to říká nahlas, místo aby
  -- je předstíral. Přepínač `separate_series` sám o sobě dělá jen to, že se
  -- pořadí bere z jiného řádku počítadla — jenže `next_invoice_number` počítá
  -- nejvyšší použité pořadí přes VŠECHNY faktury roku a vydává vždycky tvar
  -- `RRRRNNNN`. Zapnutá volba by tedy vyrobila jednu prokládanou řadu ve formátu,
  -- který CHECK `billing_settings_series_format` pro tenhle režim ani nepovoluje
  -- (žádá `RRRRSNNN`). Rozhodnutí PM (Q6) zní „jedna společná řada", takže
  -- správná reakce je zastavit se, ne vystavit doklad se špatným číslem.
  IF COALESCE(_bs.separate_series, false) THEN
    RAISE EXCEPTION 'Oddělené číselné řady zatím nejsou implementované.'
      USING HINT = 'V Nastavení → Fakturace nech „jedna společná řada" (rozhodnutí PM k otázce Q6).';
  END IF;
  _rada := 'spolecna';
  _cislo := public.next_invoice_number(_rada, _rok);
  _splatnost := _dnes + COALESCE(_bs.due_days, 14);

  UPDATE public.invoices SET
      status            = 'vystaveno',
      cislo             = _cislo,
      -- Variabilní symbol = číslo bez nečíselných znaků (spec, bod 4).
      variabilni_symbol = regexp_replace(_cislo, '\D', '', 'g'),
      datum_vystaveni   = _dnes,
      datum_splatnosti  = _splatnost,
      issued_at         = now(),
      issued_by         = _uid,
      -- ---- snapshot dodavatele ----
      dodavatel_nazev    = _bs.supplier_name,
      dodavatel_adresa   = _bs.supplier_address,
      dodavatel_ico      = _bs.supplier_ico,
      dodavatel_dic      = _bs.supplier_dic,
      dodavatel_rejstrik = _bs.supplier_registry,
      dodavatel_ucet     = _bs.bank_account,
      dodavatel_iban     = _bs.bank_iban,
      dodavatel_zprava   = _bs.payment_message,
      vat_mode           = COALESCE(_bs.vat_mode, 'neplatce'),
      -- ---- snapshot odběratele ----
      odberatel_nazev  = _sub.name,
      odberatel_adresa = _sub.address,
      odberatel_ico    = _sub.ico,
      odberatel_dic    = _sub.dic
   WHERE id = _invoice_id;

  RETURN jsonb_build_object(
    'id', _invoice_id,
    'cislo', _cislo,
    'variabilni_symbol', regexp_replace(_cislo, '\D', '', 'g'),
    'datum_splatnosti', _splatnost,
    'total', (SELECT total FROM public.invoices WHERE id = _invoice_id),
    'total_rounded', (SELECT total_rounded FROM public.invoices WHERE id = _invoice_id)
  );

EXCEPTION
  -- R11 doslova: tahle funkce sahá na `billing_settings` uvnitř SECURITY DEFINER,
  -- takže při porušení constraintu by PostgREST poslal klientovi celý řádek
  -- i s IBANem a číslem účtu.
  WHEN check_violation OR unique_violation OR not_null_violation
       OR numeric_value_out_of_range OR foreign_key_violation THEN
    RAISE EXCEPTION 'Doklad se nepodařilo vystavit — údaje neodpovídají pravidlům dokladu.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj fakturační nastavení a údaje odběratele.';
END;
$$;

REVOKE ALL ON FUNCTION public.issue_invoice(uuid) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.issue_invoice(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 6) Zahození konceptu
--
-- Není to úklid, ale ODEMKNUTÍ: koncept drží `reservations.invoice_id`, takže
-- dokud existuje, jsou jeho rezervace pro fakturaci neviditelné. Bez téhle
-- funkce by omylem založený koncept navždy schoval led z „Kdo dluží".
--
-- Vystavený doklad se nemaže (rozhodnutí R8) — to řeší až storno a dobropis.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_invoice_draft(_invoice_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _stav public.invoice_status; _uvolneno integer;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'S fakturami pracuje jen správce haly.';
  END IF;

  SELECT status INTO _stav FROM public.invoices WHERE id = _invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Faktura neexistuje.';
  END IF;
  IF _stav <> 'koncept' THEN
    RAISE EXCEPTION 'Zahodit lze jen koncept — vystavený doklad se řeší opravným dokladem.';
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);
  UPDATE public.reservations
     SET invoice_id = NULL, invoiced_at = NULL
   WHERE invoice_id = _invoice_id;
  GET DIAGNOSTICS _uvolneno = ROW_COUNT;
  PERFORM set_config('app.trusted_booking', 'off', true);

  -- Položky odejdou přes ON DELETE CASCADE; guard je pustí, protože faktura je koncept.
  DELETE FROM public.invoices WHERE id = _invoice_id;

  RETURN _uvolneno;

EXCEPTION
  -- Dnes tady spouštěč nevidím, ale R11 je pravidlo, ne výjimka: funkce sahá na
  -- `invoices`, tedy na řádek se snapshotem dodavatele včetně IBANu, a uvnitř
  -- SECURITY DEFINER neplatí RLS — Postgres by ho při porušení constraintu vysypal
  -- do DETAILu a PostgREST poslal klientovi.
  WHEN check_violation OR unique_violation OR not_null_violation
       OR foreign_key_violation THEN
    RAISE EXCEPTION 'Koncept se nepodařilo zahodit.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj, jestli na něm nevisí něco, co se nedá uvolnit.';
END;
$$;

REVOKE ALL ON FUNCTION public.delete_invoice_draft(uuid) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_invoice_draft(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7) Pohled pro seznam faktur
--
-- `security_invoker = on` schválně: pohled má vidět přesně to, co uživatel —
-- tedy RLS politiku `invoices_select_admin`. Kdyby byl `off`, obcházel by ji
-- (přesně tak tekly údaje přes `profiles_public`, viz drift 8f).
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.invoices_list;
CREATE VIEW public.invoices_list WITH (security_invoker = on) AS
  SELECT i.id,
         i.cislo,
         i.variabilni_symbol,
         i.kind,
         i.status,
         i.subject_id,
         COALESCE(i.odberatel_nazev, s.name) AS odberatel,
         i.obdobi_od,
         i.obdobi_do,
         i.datum_vystaveni,
         i.datum_splatnosti,
         i.subtotal,
         i.total,
         i.total_rounded,
         i.pdf_path,
         (SELECT count(*) FROM public.invoice_items it WHERE it.invoice_id = i.id) AS polozek,
         -- „Po splatnosti" je odvozený stav (spec, bod 9), ne sloupec — jinak by
         -- ho někdo musel v databázi denně přepisovat.
         -- Pražský den, ne `current_date`: databáze běží v UTC, takže by se doklad
         -- na hraně splatnosti tvářil po splatnosti o dvě hodiny dřív.
         (i.status = 'vystaveno'
          AND i.datum_splatnosti < (now() AT TIME ZONE 'Europe/Prague')::date) AS po_splatnosti,
         i.created_at,
         i.issued_at
    FROM public.invoices i
    LEFT JOIN public.subjects s ON s.id = i.subject_id;

-- `authenticated` MUSÍ být v REVOKE, i když se mu hned nato dává SELECT: výchozí
-- práva Supabase dávají na každý nový objekt v `public` plné `arwdDxtm`, takže
-- bez toho by pohledu zůstal INSERT/UPDATE/DELETE. Že `invoices_list` kvůli JOINu
-- a poddotazu stejně zapisovatelný není, je náhoda plynoucí z jeho tvaru — ne
-- záruka. Hlídá to `supabase/tests/security_hardening_test.sql` (drift 8d).
REVOKE ALL ON public.invoices_list FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.invoices_list TO authenticated;

-- -----------------------------------------------------------------------------
-- 8) Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _chybi text;
BEGIN
  SELECT string_agg(f, ', ') INTO _chybi
    FROM unnest(ARRAY['create_invoice_draft_club', 'create_invoice_draft_commercial',
                      'issue_invoice', 'delete_invoice_draft']) f
   WHERE NOT EXISTS (SELECT 1 FROM pg_proc p
                      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f);
  IF _chybi IS NOT NULL THEN
    RAISE EXCEPTION 'B5 selhala: chybí funkce %.', _chybi;
  END IF;

  -- Fakturační RPC nesmí být dosažitelné pro `anon` ani pro servisní klíč:
  -- service_role obchází RLS, takže by přes ně šlo vystavit doklad bez admina.
  IF EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('create_invoice_draft_club', 'create_invoice_draft_commercial',
                         'issue_invoice', 'delete_invoice_draft', 'fakturovatelne_rezervace')
       AND (has_function_privilege('anon', p.oid, 'EXECUTE')
            OR has_function_privilege('service_role', p.oid, 'EXECUTE'))
  ) THEN
    RAISE EXCEPTION 'B5 selhala: fakturační RPC jsou dosažitelná pro anon nebo service_role.';
  END IF;

  RAISE NOTICE 'B5: RPC pro ruční fakturu hotové (koncept klub/komerce, vystavení, zahození konceptu).';
END $$;
