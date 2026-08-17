-- =============================================================================
-- TESTY OPAKOVANÝCH TRÉNINKŮ — kolize přeskočit, zbytek dojet
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/serie_kolize_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Zadání zní „bez tichého selhání". Série proto musí umět dvě věci, které se
-- snadno pletou dohromady:
--
--   • důvod PRO TERMÍN (obsazená dráha, mimo otevírací dobu) → přeskoč a jeď dál
--   • důvod PRO CELÉ ZADÁNÍ (chybí oprávnění, sazba nad stropem) → zastav se
--
-- Původní verze chytala `WHEN OTHERS`, takže druhá skupina vycházela ven jako
-- dvacet „přeskočených termínů" a uživatel se nedozvěděl, co má opravit. To je
-- tiché selhání v převleku za vstřícnost, a právě proti němu je tenhle soubor.
--
-- POUČENÍ Z A2b: tvrzení o právech se testují pod SKUTEČNOU rolí `authenticated`.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale prošla', _popis;
END $$;

-- Pomocník: založí sérii pondělních tréninků a vrátí souhrn.
CREATE OR REPLACE FUNCTION pg_temp.serie(_od timestamptz, _do timestamptz, _until date, _dny int[] DEFAULT ARRAY[1])
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE _sheet uuid; _subjekt uuid;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _subjekt FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1;
  RETURN public.create_booking_series(
    ARRAY[_sheet], 'training', 'Pravidelný trénink', _od, _do, _dny, _until, _subjekt);
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- Testy potřebují VOLNÝ kalendář v roce 2032 — staví si vlastní kolize a měří,
-- kolik termínů vzniklo. Cizí rezervace v tom období by z toho udělala hádanku
-- („proč vzniklo 17 místo 18?"), takže se předpoklad ověří rovnou a nahlas.
DO $$
DECLARE _cizi int;
BEGIN
  SELECT count(*) INTO _cizi FROM public.reservations
   WHERE start_at >= TIMESTAMPTZ '2032-01-01' AND start_at < TIMESTAMPTZ '2033-01-01';
  PERFORM pg_temp.tvrd(_cizi = 0,
    format('rok 2032 je v kalendáři volný (našel jsem %s cizích rezervací)', _cizi));
END $$;

-- -----------------------------------------------------------------------------
-- 1) Série bez kolizí založí všechno a řekne kolik z kolika
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb;
BEGIN
  _r := pg_temp.serie(
    (TIMESTAMP '2032-03-01 10:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-03-01 11:00' AT TIME ZONE 'Europe/Prague'),
    DATE '2032-03-31');

  PERFORM pg_temp.tvrd((_r ->> 'celkem')::int = 5, format('pět pondělků v období (%s)', _r ->> 'celkem'));
  PERFORM pg_temp.tvrd((_r ->> 'created')::int = 5, 'všech pět se založilo');
  PERFORM pg_temp.tvrd(jsonb_array_length(_r -> 'skipped') = 0, 'nic se nepřeskočilo');
  PERFORM pg_temp.tvrd((_r ->> 'series_id') IS NOT NULL, 'série má vlastní id');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE series_id = (_r ->> 'series_id')::uuid AND status = 'confirmed') = 5,
    'a v databázi je opravdu pět rezervací');
END $$;

-- -----------------------------------------------------------------------------
-- 1b) A totéž POD SKUTEČNOU ROLÍ, ne jako superuživatel
--
-- Sekce nad tímhle běží jako `postgres`, a je to tam správně: tvrdí něco
-- o chování (kolik termínů vzniklo), ne o právech, a čtou `public.reservations`,
-- kam `authenticated` po A2b přímo nevidí. Kdyby ale VŠECHNO běželo pod
-- superuživatelem, netvrdil by tenhle soubor nic o tom, že sérii vůbec smí
-- zavolat běžný admin — a kdyby zmizel GRANT, testy by svítily zeleně nad
-- funkcí, která je pro appku mrtvá. Pravidlo 8 z CLAUDE.md.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _r jsonb;
BEGIN
  PERFORM pg_temp.tvrd(
    has_function_privilege('authenticated',
      'public.create_booking_series(uuid[], text, text, timestamptz, timestamptz, int[], date, uuid, text, jsonb, numeric)',
      'EXECUTE'),
    'admin jako authenticated má na sérii právo ji zavolat');

  _r := pg_temp.serie(
    (TIMESTAMP '2032-05-03 10:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-05-03 11:00' AT TIME ZONE 'Europe/Prague'),
    DATE '2032-05-31');
  PERFORM pg_temp.tvrd((_r ->> 'created')::int = 5,
    format('a celá cesta mu projde end-to-end (%s z %s)', _r ->> 'created', _r ->> 'celkem'));
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO ZADÁNÍ: kolize termín přeskočí, zbytek série dojede
--
-- Do prostředka série se postaví komerční akce. Trénink ji přebít nesmí (priorita
-- komerční > trénink) — ten termín tedy vypadne a ostatní musí vzniknout.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sheet uuid; _firma uuid; _r jsonb; _preskocene text;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _firma FROM public.subjects WHERE type = 'commercial' AND deleted_at IS NULL ORDER BY name LIMIT 1;

  -- Překážka: komerční akce na druhém a čtvrtém pondělí.
  PERFORM public.create_booking(
    ARRAY[_sheet], 'commercial', 'Firemní akce',
    (TIMESTAMP '2032-04-12 10:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-04-12 11:00' AT TIME ZONE 'Europe/Prague'),
    _firma, NULL, '{"instructor": 1}'::jsonb);
  PERFORM public.create_booking(
    ARRAY[_sheet], 'commercial', 'Firemní akce',
    (TIMESTAMP '2032-04-26 10:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-04-26 11:00' AT TIME ZONE 'Europe/Prague'),
    _firma, NULL, '{"instructor": 1}'::jsonb);

  _r := pg_temp.serie(
    (TIMESTAMP '2032-04-05 10:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-04-05 11:00' AT TIME ZONE 'Europe/Prague'),
    DATE '2032-04-26');

  PERFORM pg_temp.tvrd((_r ->> 'celkem')::int = 4, 'čtyři pondělky v dubnu');
  PERFORM pg_temp.tvrd((_r ->> 'created')::int = 2,
    format('založily se dva termíny, ne nula a ne čtyři (%s)', _r ->> 'created'));
  PERFORM pg_temp.tvrd(jsonb_array_length(_r -> 'skipped') = 2, 'dva termíny se přeskočily');

  -- Souhrn musí jmenovat KTERÉ dny — „přeskočeno 2" se nedá vyřešit.
  SELECT string_agg(x ->> 'date', ', ' ORDER BY x ->> 'date') INTO _preskocene
    FROM jsonb_array_elements(_r -> 'skipped') x;
  PERFORM pg_temp.tvrd(_preskocene LIKE '%12.04.2032%' AND _preskocene LIKE '%26.04.2032%',
    format('a souhrn je vyjmenuje (%s)', _preskocene));

  PERFORM pg_temp.tvrd(
    (SELECT bool_and(x ->> 'duvod' = 'kolize') FROM jsonb_array_elements(_r -> 'skipped') x),
    'důvod je označený jako kolize, ne jen text hlášky');

  -- A hlavně: zbytek série v databázi opravdu je.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE series_id = (_r ->> 'series_id')::uuid AND status = 'confirmed') = 2,
    'kolize nezastavila zakládání dalších termínů');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Priorita zůstává: trénink komerční akci nepřebije ani v sérii
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sheet uuid; _r jsonb;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r
       JOIN public.events e ON e.id = r.event_id
      WHERE e.event_type = 'commercial' AND r.sheet_id = _sheet
        AND r.start_at = (TIMESTAMP '2032-04-12 10:00' AT TIME ZONE 'Europe/Prague')
        AND r.status = 'confirmed') = 1,
    'komerční akce v kolizním termínu zůstala nedotčená');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Mimo otevírací dobu je JINÝ důvod než kolize
--
-- Rozdíl není kosmetický: kolizi řeší jiný čas, zavřenou halu nastavení. Kdyby
-- se to slilo do jedné hlášky, admin by hledal na špatném místě.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _stara jsonb;
BEGIN
  SELECT opening_hours INTO _stara FROM public.settings;
  -- V pondělí zavřeno, jinak beze změny.
  UPDATE public.settings SET opening_hours = jsonb_set(_stara, '{1}', '{"open":"10:00","close":"10:00"}'::jsonb);

  _r := pg_temp.serie(
    (TIMESTAMP '2032-05-03 14:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-05-03 15:00' AT TIME ZONE 'Europe/Prague'),
    DATE '2032-05-31');

  PERFORM pg_temp.tvrd(false, 'sem se to nemá dostat — všechny termíny jsou mimo otevírací dobu');
EXCEPTION WHEN SQLSTATE 'U0001' OR raise_exception THEN
  -- Když neprojde ani jeden termín, série se ozve nahlas (a nezaloží nic).
  PERFORM pg_temp.tvrd(position('otevírací dobu' in SQLERRM) > 0,
    format('série s nulou použitelných termínů řekne důvod (%s)', left(SQLERRM, 60)));
  UPDATE public.settings SET opening_hours = _stara;
END $$;

DO $$
DECLARE _r jsonb; _stara jsonb;
BEGIN
  SELECT opening_hours INTO _stara FROM public.settings;
  UPDATE public.settings SET opening_hours = jsonb_set(_stara, '{1}', '{"open":"10:00","close":"10:00"}'::jsonb);

  -- Pondělky zavřené, úterky otevřené → část projde, část se přeskočí.
  _r := pg_temp.serie(
    (TIMESTAMP '2032-06-01 14:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-06-01 15:00' AT TIME ZONE 'Europe/Prague'),
    DATE '2032-06-29', ARRAY[1, 2]);

  PERFORM pg_temp.tvrd((_r ->> 'created')::int > 0, 'úterky se založily');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(x ->> 'duvod' = 'mimo_otviraci_dobu') FROM jsonb_array_elements(_r -> 'skipped') x),
    'pondělky mají důvod „mimo otevírací dobu", ne „kolize"');

  UPDATE public.settings SET opening_hours = _stara;
END $$;

-- -----------------------------------------------------------------------------
-- 4b) Kolize vzniklá AŽ MEZI kontrolou a zápisem sérii taky nesmí shodit
--
-- `check_booking_conflicts` se ptá PŘED INSERTem, takže mezi dotazem a zápisem
-- může slot někdo zabrat. Pak vystřelí exclusion constraint `reservations_no_overlap`.
--
-- TENHLE TEST MUSÍ MĚŘIT CHOVÁNÍ, NE ZDROJÁK. První verze hledala v těle funkce
-- řetězec „exclusion_violation" — a prošla i ve chvíli, kdy byla ta větev MRTVÁ,
-- protože `create_booking` kolizi přebalovalo holým `RAISE EXCEPTION` (P0001).
-- Tvrzení o textu zdrojáku je přesně ta prázdná kontrola, kterou tenhle projekt
-- za etapu potkal už potřetí.
--
-- Závod se simuluje tak, že se v transakci umlčí předkontrola: `check_booking_conflicts`
-- se dočasně přepíše na „nic nenašel". Rezervace v databázi ale je, takže zápis
-- zastaví až constraint — přesně jako při skutečném souběhu. ROLLBACK to vrátí.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sheet uuid; _subjekt uuid; _r jsonb; _sqlstate text;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _subjekt FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1;

  -- Překážka na druhém pondělí (přes běžnou cestu, ať je stav konzistentní).
  PERFORM public.create_booking(
    ARRAY[_sheet], 'training', 'Obsazeno předem',
    (TIMESTAMP '2032-10-11 10:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-10-11 11:00' AT TIME ZONE 'Europe/Prague'),
    _subjekt);

  -- Umlčení předkontroly = simulovaný závod.
  CREATE OR REPLACE FUNCTION public.check_booking_conflicts(
    p_sheet_ids uuid[], p_start timestamptz, p_end timestamptz, p_kind text DEFAULT NULL)
  RETURNS TABLE (reservation_id uuid, sheet_id uuid, sheet_name text, subject_name text,
                 event_title text, start_at timestamptz, end_at timestamptz,
                 event_type public.event_type, can_override boolean)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
  AS 'SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text,
             NULL::timestamptz, NULL::timestamptz, NULL::public.event_type, NULL::boolean
      WHERE false';

  -- Jednorázová rezervace teď musí spadnout až na constraintu — a se SQLSTATE
  -- kolize, ne s P0001. Na tom stojí celá schopnost série ji přeskočit.
  BEGIN
    PERFORM public.create_booking(
      ARRAY[_sheet], 'training', 'Závod',
      (TIMESTAMP '2032-10-11 10:00' AT TIME ZONE 'Europe/Prague'),
      (TIMESTAMP '2032-10-11 11:00' AT TIME ZONE 'Europe/Prague'),
      _subjekt);
    RAISE EXCEPTION 'TEST SELHAL: zápis přes obsazený slot prošel';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'TEST SELHAL%' THEN RAISE; END IF;
    _sqlstate := SQLSTATE;
  END;
  PERFORM pg_temp.tvrd(_sqlstate = 'U0001',
    format('kolize zjištěná až constraintem má SQLSTATE kolize, ne P0001 (dostal jsem %s)', _sqlstate));

  -- A teď to hlavní: série přes ten termín přejede a zbytek založí.
  _r := pg_temp.serie(
    (TIMESTAMP '2032-10-04 10:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-10-04 11:00' AT TIME ZONE 'Europe/Prague'),
    DATE '2032-10-25');

  PERFORM pg_temp.tvrd((_r ->> 'celkem')::int = 4, 'čtyři pondělky v období');
  PERFORM pg_temp.tvrd((_r ->> 'created')::int = 3,
    format('tři termíny vznikly navzdory závodu na jednom z nich (%s)', _r ->> 'created'));
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(x ->> 'duvod' = 'kolize') FROM jsonb_array_elements(_r -> 'skipped') x),
    'a přeskočený termín je označený jako kolize');
  PERFORM pg_temp.tvrd(
    (SELECT bool_and(x ->> 'reason' NOT LIKE '%constraint%') FROM jsonb_array_elements(_r -> 'skipped') x),
    'uživatel nedostane syrovou hlášku Postgresu o constraintu');
END $$;

-- -----------------------------------------------------------------------------
-- 4c) Neexistující hodina při přechodu na letní čas termín přeskočí, ne sérii
--
-- Poslední březnovou neděli se ve 2:00 posunou hodiny na 3:00, takže 02:00–03:00
-- ten den neexistuje: `AT TIME ZONE` obojí přeloží na 03:00 a konec vyjde
-- před začátkem. `create_booking` by to odmítlo jako chybu zadání (P0001) a
-- shodilo by celou sérii, přestože jde o jeden termín.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _stara jsonb; _duvody text;
BEGIN
  SELECT opening_hours INTO _stara FROM public.settings;
  -- Neděle otevřená od jedné v noci, ať se na tu hodinu vůbec dá cílit.
  UPDATE public.settings SET opening_hours = jsonb_set(_stara, '{7}', '{"open":"01:00","close":"22:00"}'::jsonb);

  _r := pg_temp.serie(
    (TIMESTAMP '2032-03-14 02:00' AT TIME ZONE 'Europe/Prague'),
    (TIMESTAMP '2032-03-14 03:00' AT TIME ZONE 'Europe/Prague'),
    DATE '2032-04-04', ARRAY[7]);

  PERFORM pg_temp.tvrd((_r ->> 'created')::int > 0,
    format('ostatní neděle vznikly (%s z %s)', _r ->> 'created', _r ->> 'celkem'));

  SELECT string_agg(DISTINCT x ->> 'duvod', ',') INTO _duvody
    FROM jsonb_array_elements(_r -> 'skipped') x;
  PERFORM pg_temp.tvrd(_duvody = 'neexistujici_cas',
    format('a 28. 3. se přeskočilo s vlastním důvodem, ne jako kolize (%s)', COALESCE(_duvody, 'nic')));

  UPDATE public.settings SET opening_hours = _stara;
END $$;

-- -----------------------------------------------------------------------------
-- 5) CHYBA ZADÁNÍ SÉRII ZASTAVÍ — tohle je ta věc, co byla rozbitá
--
-- Sazba nad stropem platí pro všechny termíny. Dřív se nahlásilo dvacet
-- „přeskočeno" a uživatel hádal; teď se nezaloží nic a je vidět proč.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sheet uuid; _subjekt uuid; _pred int; _po int;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _subjekt FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1;
  SELECT count(*) INTO _pred FROM public.reservations;

  PERFORM pg_temp.ocekavej_chybu(format(
    'SELECT public.create_booking_series(ARRAY[%L]::uuid[], ''training'', ''Trénink'', '
    '(TIMESTAMP ''2032-07-05 10:00'' AT TIME ZONE ''Europe/Prague''), '
    '(TIMESTAMP ''2032-07-05 11:00'' AT TIME ZONE ''Europe/Prague''), '
    'ARRAY[1]::int[], DATE ''2032-07-26'', %L, NULL, ''{}''::jsonb, 99999999)', _sheet, _subjekt),
    'nejvýš 50 000', 'sazba nad stropem sérii ZASTAVÍ (a neohlásí ji jako kolizi)');

  SELECT count(*) INTO _po FROM public.reservations;
  PERFORM pg_temp.tvrd(_pred = _po, 'a nezaložila se ani jedna rezervace');
END $$;

-- Chybějící oprávnění je taky chyba zadání, ne kolize.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _sheet uuid; _firma uuid;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _firma FROM public.subjects WHERE type = 'commercial' AND deleted_at IS NULL ORDER BY name LIMIT 1;

  -- Člen nesmí zakládat komerční akce — musí to říct hned, ne dvacetkrát „přeskočeno".
  PERFORM pg_temp.ocekavej_chybu(format(
    'SELECT public.create_booking_series(ARRAY[%L]::uuid[], ''commercial'', ''Pokus'', '
    '(TIMESTAMP ''2032-08-02 10:00'' AT TIME ZONE ''Europe/Prague''), '
    '(TIMESTAMP ''2032-08-02 11:00'' AT TIME ZONE ''Europe/Prague''), '
    'ARRAY[1]::int[], DATE ''2032-08-30'', %L)', _sheet, _firma),
    'jen správce', 'chybějící oprávnění sérii zastaví hned');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 6) Meze zadání zůstávají
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _sheet uuid; _subjekt uuid;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _subjekt FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1;

  PERFORM pg_temp.ocekavej_chybu(format(
    'SELECT public.create_booking_series(ARRAY[%L]::uuid[], ''training'', ''T'', '
    '(TIMESTAMP ''2032-09-06 10:00'' AT TIME ZONE ''Europe/Prague''), '
    '(TIMESTAMP ''2032-09-06 11:00'' AT TIME ZONE ''Europe/Prague''), '
    'ARRAY[1]::int[], DATE ''2033-12-01'', %L)', _sheet, _subjekt),
    'nejvýš na rok', 'opakování dál než rok dopředu se odmítne');

  PERFORM pg_temp.ocekavej_chybu(format(
    'SELECT public.create_booking_series(ARRAY[%L]::uuid[], ''training'', ''T'', '
    '(TIMESTAMP ''2032-09-06 10:00'' AT TIME ZONE ''Europe/Prague''), '
    '(TIMESTAMP ''2032-09-06 11:00'' AT TIME ZONE ''Europe/Prague''), '
    'ARRAY[]::int[], DATE ''2032-09-27'', %L)', _sheet, _subjekt),
    'aspoň jeden den', 'série bez vybraného dne v týdnu se odmítne');

  -- Vybraný den, který do období nepadne: dřív z toho vypadlo „ani jeden z 0
  -- termínů", což je věta, ze které uživatel nepozná, co udělal špatně.
  PERFORM pg_temp.ocekavej_chybu(format(
    'SELECT public.create_booking_series(ARRAY[%L]::uuid[], ''training'', ''T'', '
    '(TIMESTAMP ''2032-09-06 10:00'' AT TIME ZONE ''Europe/Prague''), '
    '(TIMESTAMP ''2032-09-06 11:00'' AT TIME ZONE ''Europe/Prague''), '
    'ARRAY[2]::int[], DATE ''2032-09-06'', %L)', _sheet, _subjekt),
    'nevychází ani jeden z vybraných dnů', 'vybraný den mimo období řekne rovnou proč');
END $$;

ROLLBACK;
