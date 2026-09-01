-- =============================================================================
-- TESTY: deaktivovaný účet nemá práva; chat a dráhy vidí až vpuštěný účet
-- Migrace 20260901120000_deaktivovany_ucet_nema_prava.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/deaktivovany_ucet_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- `has_role()` nese `AND ucet_aktivni()`, ale 17 politik si roli četlo napřímo
-- přes `EXISTS (… user_roles …)`. Deaktivovaný admin tak pořád zapisoval —
-- a prvním, co si zapsal, byla nová role `admin` pro nastrčený účet.
--
-- Nejcennější tvrzení je proto první: účet se `stav='deaktivovan'` a ponechanou
-- rolí `admin` NESMÍ vložit řádek do `user_roles`. Zbytek jsou jeho sourozenci
-- na `events`, `payouts`, `shifts` a `chat_groups`.
--
-- Všechno běží pod `SET LOCAL ROLE authenticated` (pravidlo 8). Jako postgres
-- projde zápis vždycky — vlastník tabulky obchází granty i RLS.
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

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_p boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_p, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): mělo to skončit chybou, ale prošlo', _popis;
END $$;

-- Admin, kterému hala vypnula účet, ale roli mu nechala.
DO $$
BEGIN
  UPDATE public.profiles SET stav = 'deaktivovan'
   WHERE user_id = '11111111-1111-1111-1111-111111111111';
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.user_roles
             WHERE user_id = '11111111-1111-1111-1111-111111111111' AND role = 'admin'),
    'příprava: roli admin si ponechal');
  PERFORM pg_temp.tvrd(NOT public.ucet_aktivni('11111111-1111-1111-1111-111111111111'),
    'příprava: ucet_aktivni() ho nepouští');
  PERFORM pg_temp.tvrd(NOT public.has_role('11111111-1111-1111-1111-111111111111','admin'),
    'příprava: has_role() ho taky ne');
END $$;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: zavřený admin si nevyrobí nového
-- -----------------------------------------------------------------------------
DO $$
DECLARE _dotceno int;
BEGIN
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'test práv běží jako authenticated, ne jako postgres');

  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.user_roles (user_id, role)
       VALUES ('44444444-4444-4444-4444-444444444444','admin')$q$,
    'row-level security',
    'DEAKTIVOVANÝ ADMIN NEVYROBÍ NOVÉHO ADMINA (jádro nálezu)');

  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.events (title, event_type, start_time, end_time)
       VALUES ('TEST zavřený admin','training','2028-01-05 17:00+01','2028-01-05 19:00+01')$q$,
    'row-level security', '… ani nezaloží akci');

  -- U výplat narazí dřív než na RLS na trigger `validate_payout`, který se ptá
  -- `has_role()` — tam tedy brána na stav účtu držela i PŘED touhle migrací.
  -- Tvrzení je proto „neprojde", ne „neprojde konkrétně přes RLS": obojí je
  -- správně a přišpendlovat se k jedné z těch dvou vrstev by test jen zkřehčilo.
  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.payouts (user_id, amount)
       VALUES ('33333333-3333-3333-3333-333333333333', 1)$q$,
    'admin', '… ani výplatu (peníze) — tam drží trigger validate_payout');

  -- Nefiltrovaný UPDATE je v SQL legální a chybou neskončí — RLS mu jen
  -- nepustí ani jeden řádek. (Přes PostgREST by ho navíc odmítl už samotný
  -- klient hláškou „UPDATE requires a WHERE clause", ale to je vlastnost
  -- PostgRESTu, ne databáze, a testovat ji tady by bylo tvrzení o cizím
  -- programu.) Měří se proto POČET dotčených řádků.
  UPDATE public.chat_groups SET whatsapp_url = 'https://evil.example/join';
  GET DIAGNOSTICS _dotceno = ROW_COUNT;
  PERFORM pg_temp.tvrd(_dotceno = 0,
    format('… a plošný přepis chatu nepotká ani řádek (dotčeno %s)', _dotceno));

  EXECUTE 'RESET ROLE';
END $$;

-- Filtrovaný přepis chatu — TA cesta, která dřív tekla i s filtrem.
DO $$
DECLARE _url text; _id uuid;
BEGIN
  SELECT id, whatsapp_url INTO _id, _url FROM public.chat_groups LIMIT 1;
  IF _id IS NULL THEN
    RAISE NOTICE 'PŘESKOČENO: seed nemá žádnou chat skupinu';
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE format('UPDATE public.chat_groups SET whatsapp_url = %L WHERE id = %L',
                 'https://evil.example/join', _id);
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd(
    (SELECT whatsapp_url FROM public.chat_groups WHERE id = _id) IS NOT DISTINCT FROM _url,
    'zavřený admin NEPŘEPÍŠE pozvánku do klubového chatu (UPDATE 0 řádků)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) NESCHVÁLENÝ ÚČET: chat, dráhy, role adminů
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid := '55555555-5555-5555-5555-555555555555'; _n bigint;
BEGIN
  UPDATE public.profiles SET stav = 'ceka' WHERE user_id = _novy;

  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  SELECT count(*) INTO _n FROM public.chat_groups;
  PERFORM pg_temp.tvrd(_n = 0, 'čekající účet NEVIDÍ klubový chat ani pozvánkový odkaz');

  SELECT count(*) INTO _n FROM public.sheets;
  PERFORM pg_temp.tvrd(_n = 0, '… ani seznam drah (a tím jejich UUID do rezervačních RPC)');

  PERFORM pg_temp.ocekavej_chybu(
    $q$SELECT public.get_user_role('11111111-1111-1111-1111-111111111111')$q$,
    'permission denied', '… a nevyjede si, kdo je admin');

  EXECUTE 'RESET ROLE';
  UPDATE public.profiles SET stav = 'aktivni' WHERE user_id = _novy;
END $$;

-- -----------------------------------------------------------------------------
-- 3) REGRESE: aktivnímu uživateli se nesmí nic ubrat
-- -----------------------------------------------------------------------------
DO $$
DECLARE _n bigint;
BEGIN
  UPDATE public.profiles SET stav = 'aktivni'
   WHERE user_id = '11111111-1111-1111-1111-111111111111';

  -- Admin: zpátky ve své roli, včetně zápisu.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO public.events (title, event_type, start_time, end_time)
  VALUES ('TEST aktivni admin','training','2028-01-12 17:00+01','2028-01-12 19:00+01');
  SELECT count(*) INTO _n FROM public.sheets;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n > 0, 'AKTIVNÍ admin akci založí a dráhy vidí (žádná regrese)');

  -- Člen klubu: dráhy potřebuje na kalendář.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n FROM public.sheets;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n > 0, 'aktivní člen klubu dráhy vidí dál');

  -- Brigádník: směny jsou jeho chleba.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n FROM public.shifts;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n > 0, 'aktivní brigádník směny vidí dál');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Vlastní řádek zůstává i zavřenému účtu (aby viděl, co mu hala dluží)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _n bigint;
BEGIN
  UPDATE public.profiles SET stav = 'deaktivovan'
   WHERE user_id = '33333333-3333-3333-3333-333333333333';
  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n FROM public.payouts WHERE user_id <> '33333333-3333-3333-3333-333333333333';
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n = 0, 'zavřený účet nevidí CIZÍ výplaty');
  UPDATE public.profiles SET stav = 'aktivni'
   WHERE user_id = '33333333-3333-3333-3333-333333333333';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
