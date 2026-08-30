-- =============================================================================
-- Guard režimu DPH i na ZAKLÁDÁNÍ konceptu, ne jen na vystavení
-- =============================================================================
-- CO BYLO ŠPATNĚ:
--
-- Migrace `20260830140000` přepnula halu na plátce a tím zavřela `issue_invoice`.
-- Jenže `create_invoice_draft_club` a `create_invoice_draft_commercial` guard
-- NEMĚLY — a tlačítko „Vygenerovat fakturu" v „Kdo dluží" (`Dues.tsx`) volá
-- právě je, ne `issue_invoice`.
--
-- Vznikla tím past: admin klikl, dostal „Koncept faktury založen", byl
-- přesměrovaný na /invoices — a teprve TAM narazil na odmítnutí. Mezitím
-- koncept ZAMKL rezervace (`invoice_id` + `invoiced_at`) na dokladu, který
-- nikdy nepůjde vystavit. Ověřeno pod rolí `authenticated` jako admin:
-- 6 zamčených rezervací.
--
-- PROČ TO NENÍ JEN KOSMETIKA: `k_fakturaci` u toho subjektu spadne na nulu,
-- protože rezervace visí na konceptu — zatímco fakturoidí cesta je vidí dál
-- (filtruje přes `fakturoid_invoice_reservations`, ne přes `invoice_id`)
-- a klidně je vyfakturuje. Pak zůstane ve `v_konceptu` částka, která je ve
-- skutečnosti vyfakturovaná jinde, a sama se nevyčistí.
--
-- Našla to databázová brána. Vratné to bylo (`delete_invoice_draft` zámek
-- pustí), ale past, kterou musí někdo najít, není zábrana.
--
-- CO SE MĚNÍ: tentýž guard jako v `issue_invoice`, hned za kontrolou admina
-- a PŘED zabráním rezervací — odmítnout se musí dřív, než se něco zamkne.
--
-- OBĚ TĚLA JSOU VYGENEROVANÁ Z `pg_get_functiondef` ŽIVÉHO SCHÉMATU (pravidlo 7
-- z CLAUDE.md) a diff proti nim je 18 PŘIDANÝCH řádků na funkci, nic ubraného.
-- Ověřeno programově, ne okem.
--
-- ⚠️ POZOR NA SOUHRU S `20260818130000_automatika.sql`. Ta do týchž dvou funkcí
-- propašovala RUNTIME PATCHEM výjimku pro plánovač
-- (`session_user IN ('postgres','supabase_admin')`) — nepřepisuje je celé, jen
-- do nich vloží blok, a to jen když tam ještě není
-- (`CONTINUE WHEN position('session_user' in _def) > 0`).
--
-- Na čerstvé databázi tedy běží NEJDŘÍV ona a pak tahle: patch se vloží
-- a vzápětí ho přepíše tenhle `CREATE OR REPLACE` — týmž textem, protože se
-- generoval ze schématu, které ten patch už mělo. Výsledek je stejný, ale je to
-- křehká souhra dvou migrací nad jedním tělem.
--
-- CO Z TOHO PLYNE PRO PŘÍŠTÍ ZÁSAH: tělo se musí generovat ze ŽIVÉHO schématu
-- po aplikaci VŠECH migrací, ne ze znění v `20260813140000_faktury_rpc.sql`.
-- Kdo vezme to původní, výjimku pro plánovač tiše smaže a rozbije automatiku.
--
-- VRATNOST — A POZOR, JAK. Napsat „zpátky do znění bez toho bloku" by bylo
-- pozvání k tomu, sáhnout po `20260813140000_faktury_rpc.sql` — tedy přesně po
-- tom, před čím varuje odstavec výš. Postup je:
--
--   1. `SELECT pg_get_functiondef('public.create_invoice_draft_club(uuid,date,date)'::regprocedure);`
--      (a totéž pro `…_commercial(uuid)`),
--   2. z výsledku SMAZAT těch 18 řádků guardu — nic jiného,
--   3. pustit jako `CREATE OR REPLACE`.
--
-- Data se nemění. A revert téhle migrace BEZ revertu `20260830140000` past jen
-- vrátí zpátky: koncepty půjdou zakládat, vystavit ne.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.create_invoice_draft_club(_subject_id uuid, _obdobi_od date, _obdobi_do date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid      uuid := auth.uid();
  _invoice  uuid;
  _od       timestamptz;
  _do       timestamptz;
  _pocet    integer;
  _bez_ceny integer;
  _ukazky   text;
BEGIN
  -- Výjimka pro plánovač: běh BEZ tokenu a pod databázovou rolí.
  -- Z webu nedosažitelná (PostgREST se připojuje jako `authenticator`).
  IF NOT (_uid IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;

  -- REŽIM DPH — TÁŽ ZÁBRANA JAKO V `issue_invoice`, jen o krok dřív.
  --
  -- Bez ní vznikla past: pod plátcem koncept normálně vznikl, ZAMKL rezervace
  -- (`invoice_id` + `invoiced_at`) a vystavit ho pak už nešlo. Admin v „Kdo
  -- dluží" klikl, dostal „Koncept faktury založen" a o obrazovku dál narazil —
  -- s rezervacemi visícími na dokladu, který nikdy nevznikne. `k_fakturaci`
  -- u toho subjektu přitom spadlo na nulu, zatímco fakturoidí strana měla
  -- pořád co fakturovat. Ověřeno: 6 zamčených rezervací.
  --
  -- Zábrana je ZÁMĚRNĚ PŘED zabráním rezervací: odmítnout se musí dřív, než se
  -- něco zamkne, jinak by po sobě musela uklízet.
  IF COALESCE((SELECT vat_mode FROM public.billing_settings WHERE singleton),
              'neplatce') <> 'neplatce' THEN
    -- RADA JE V `message`, NE JEN V `HINT`. Frontend (`useInvoices.ts`) propouští
    -- `error.message` a `hint` z PostgrestError zahazuje, takže by se admin
    -- dozvěděl, že to nejde, ale ne kudy jinudy. `HINT` zůstává pro psql a logy.
    RAISE EXCEPTION 'Doklad umí zatím jen režim neplátce DPH (nastaveno: %). Ostré doklady vystavuje Fakturoid, ne tenhle interní engine.',
      (SELECT vat_mode FROM public.billing_settings WHERE singleton)
      USING HINT = 'Hala je vedená jako plátce — ostré doklady vystavuje Fakturoid, ne interní engine.';
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
$function$;

CREATE OR REPLACE FUNCTION public.create_invoice_draft_commercial(_event_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- Výjimka pro plánovač: běh BEZ tokenu a pod databázovou rolí.
  -- Z webu nedosažitelná (PostgREST se připojuje jako `authenticator`).
  IF NOT (_uid IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Faktury vystavuje jen správce haly.';
  END IF;

  -- REŽIM DPH — TÁŽ ZÁBRANA JAKO V `issue_invoice`, jen o krok dřív.
  --
  -- Bez ní vznikla past: pod plátcem koncept normálně vznikl, ZAMKL rezervace
  -- (`invoice_id` + `invoiced_at`) a vystavit ho pak už nešlo. Admin v „Kdo
  -- dluží" klikl, dostal „Koncept faktury založen" a o obrazovku dál narazil —
  -- s rezervacemi visícími na dokladu, který nikdy nevznikne. `k_fakturaci`
  -- u toho subjektu přitom spadlo na nulu, zatímco fakturoidí strana měla
  -- pořád co fakturovat. Ověřeno: 6 zamčených rezervací.
  --
  -- Zábrana je ZÁMĚRNĚ PŘED zabráním rezervací: odmítnout se musí dřív, než se
  -- něco zamkne, jinak by po sobě musela uklízet.
  IF COALESCE((SELECT vat_mode FROM public.billing_settings WHERE singleton),
              'neplatce') <> 'neplatce' THEN
    -- RADA JE V `message`, NE JEN V `HINT`. Frontend (`useInvoices.ts`) propouští
    -- `error.message` a `hint` z PostgrestError zahazuje, takže by se admin
    -- dozvěděl, že to nejde, ale ne kudy jinudy. `HINT` zůstává pro psql a logy.
    RAISE EXCEPTION 'Doklad umí zatím jen režim neplátce DPH (nastaveno: %). Ostré doklady vystavuje Fakturoid, ne tenhle interní engine.',
      (SELECT vat_mode FROM public.billing_settings WHERE singleton)
      USING HINT = 'Hala je vedená jako plátce — ostré doklady vystavuje Fakturoid, ne interní engine.';
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
$function$;

-- -----------------------------------------------------------------------------
-- Kontrola, že guard opravdu drží
-- -----------------------------------------------------------------------------
DO $$
DECLARE _spadlo boolean; _fn text;
BEGIN
  FOREACH _fn IN ARRAY ARRAY['create_invoice_draft_club', 'create_invoice_draft_commercial'] LOOP
    IF (SELECT pg_get_functiondef(p.oid) FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = _fn) NOT LIKE '%jen režim neplátce DPH%' THEN
      RAISE EXCEPTION '% nemá guard režimu DPH.', _fn;
    END IF;
  END LOOP;
  RAISE NOTICE 'Obě funkce pro zakládání konceptu mají guard režimu DPH.';
END $$;
