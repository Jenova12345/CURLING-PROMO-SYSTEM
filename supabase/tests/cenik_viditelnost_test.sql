-- =============================================================================
-- TESTY VIDITELNOSTI CENÍKU (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/cenik_viditelnost_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE (A2b):
-- Rozhodnutí klienta zní „obsazenost a název klubu vidí všichni přihlášení,
-- ČÁSTKU jen admin a autor". U `reservations` to platilo, u `public.settings` ne —
-- `GET /rest/v1/settings` vracel každému přihlášenému kompletní ceník a člen si
-- z něj částku své rezervace dopočítal. Tenhle test hlídá, aby se to nevrátilo.
--
-- Zúžení viditelnosti je snadné omylem zrušit: stačí, aby budoucí migrace udělala
-- `GRANT SELECT ON public.settings TO authenticated` (což je i text, který Postgres
-- sám nabízí v HINTu u chyby 42501). Proto se to testuje, ne jen komentuje.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Stejná pojistka jako v zaokrouhleni_test.sql: jen lokální seed databáze.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze. Test patří jen na lokální Docker Postgres.';
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

-- -----------------------------------------------------------------------------
-- 1) Práva: sazby nesmí být čitelné napřímo, neprice pole ano
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sazby int; _neprice int; _tabulkovy int;
BEGIN
  SELECT count(*) INTO _sazby
    FROM information_schema.column_privileges
   WHERE table_schema='public' AND table_name='settings' AND privilege_type='SELECT'
     AND grantee IN ('anon','authenticated','PUBLIC')
     AND column_name IN ('club_default_rate','commercial_default_rate','training_rate','tournament_rate');
  PERFORM pg_temp.tvrd(_sazby = 0,
    format('sazby v settings nejsou čitelné pro anon/authenticated (nalezeno grantů: %s)', _sazby));

  SELECT count(DISTINCT column_name) INTO _neprice
    FROM information_schema.column_privileges
   WHERE table_schema='public' AND table_name='settings' AND privilege_type='SELECT'
     AND grantee = 'authenticated'
     AND column_name IN ('opening_hours','singleton');
  PERFORM pg_temp.tvrd(_neprice = 2,
    'otevírací doba a singleton zůstávají čitelné (kalendář na nich stojí)');

  -- Tabulkový grant by sloupcové odebrání přebil — proto se hlídá zvlášť.
  SELECT count(*) INTO _tabulkovy
    FROM information_schema.role_table_grants
   WHERE table_schema='public' AND table_name='settings' AND privilege_type='SELECT'
     AND grantee IN ('anon','authenticated','PUBLIC');
  PERFORM pg_temp.tvrd(_tabulkovy = 0,
    format('na settings není TABULKOVÝ SELECT grant (ten by sloupcové odebrání zrušil) — nalezeno: %s', _tabulkovy));
END $$;

-- -----------------------------------------------------------------------------
-- 2) Pohled: co uvidí kdo
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r record;
BEGIN
  -- Admin
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text, true);
  SELECT * INTO _r FROM public.settings_public LIMIT 1;
  PERFORM pg_temp.tvrd(_r.can_see_rates, 'admin: can_see_rates je true');
  PERFORM pg_temp.tvrd(_r.club_default_rate IS NOT NULL, 'admin: vidí sazbu klubu');
  PERFORM pg_temp.tvrd(_r.commercial_default_rate IS NOT NULL, 'admin: vidí komerční sazbu');
  PERFORM pg_temp.tvrd(_r.opening_hours IS NOT NULL, 'admin: vidí otevírací dobu');

  -- Člen klubu (clen2@test.local, jen hobby_player)
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '55555555-5555-5555-5555-555555555555')::text, true);
  SELECT * INTO _r FROM public.settings_public LIMIT 1;
  PERFORM pg_temp.tvrd(NOT _r.can_see_rates, 'člen: can_see_rates je false');
  PERFORM pg_temp.tvrd(_r.club_default_rate IS NULL, 'člen: sazbu klubu NEvidí');
  PERFORM pg_temp.tvrd(_r.commercial_default_rate IS NULL, 'člen: komerční sazbu NEvidí');
  PERFORM pg_temp.tvrd(_r.training_rate IS NULL AND _r.tournament_rate IS NULL,
    'člen: sazby tréninku ani turnaje NEvidí');

  -- A to podstatné: neprice pole mu zůstala, jinak by se rozbil kalendář
  PERFORM pg_temp.tvrd(_r.opening_hours IS NOT NULL, 'člen: otevírací dobu vidí (kalendář funguje)');

  -- Instruktor: personál haly, ale NE admin. Snadno se splete za privilegovaného,
  -- proto se testuje zvlášť — ceny podle zadání vidí jen admin a autor.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '22222222-2222-2222-2222-222222222222')::text, true);
  SELECT * INTO _r FROM public.settings_public LIMIT 1;
  PERFORM pg_temp.tvrd(NOT _r.can_see_rates, 'instruktor: can_see_rates je false');
  PERFORM pg_temp.tvrd(_r.club_default_rate IS NULL AND _r.commercial_default_rate IS NULL,
    'instruktor: sazby NEvidí, i když je to personál haly');
  PERFORM pg_temp.tvrd(_r.opening_hours IS NOT NULL, 'instruktor: otevírací dobu vidí');

  -- Bez přihlášeného uživatele (pg_cron, nebo Edge funkce sahající na POHLED):
  -- žádné sazby. Pozor, `service_role` čtoucí TABULKU sazby vidí — tohle
  -- tvrzení je o pohledu, ne o servisním klíči.
  PERFORM set_config('request.jwt.claims', NULL, true);
  SELECT * INTO _r FROM public.settings_public LIMIT 1;
  PERFORM pg_temp.tvrd(NOT _r.can_see_rates, 'bez přihlášení: can_see_rates je false');
  PERFORM pg_temp.tvrd(_r.club_default_rate IS NULL, 'bez přihlášení: sazby nejsou vidět');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Granty na pohledu
-- -----------------------------------------------------------------------------
DO $$
DECLARE _anon int; _auth int;
BEGIN
  SELECT count(*) INTO _anon FROM information_schema.role_table_grants
   WHERE table_schema='public' AND table_name='settings_public' AND grantee='anon';
  PERFORM pg_temp.tvrd(_anon = 0, format('anon na settings_public nemá nic (nalezeno: %s)', _anon));

  SELECT count(*) INTO _auth FROM information_schema.role_table_grants
   WHERE table_schema='public' AND table_name='settings_public'
     AND grantee='authenticated' AND privilege_type='SELECT';
  PERFORM pg_temp.tvrd(_auth = 1, 'authenticated smí pohled číst');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Chování pod SKUTEČNOU rolí `authenticated`
--
-- POZOR, PROČ TO TAKHLE: předchozí verze téhle sekce běžela jako `postgres`,
-- který obchází granty i RLS — takže neověřovala nic. Prokázáno mutacemi:
-- test procházel i po `DROP POLICY settings_update_admin` a po `REVOKE UPDATE`.
-- A hlavně kvůli tomu propustil skutečný blokér: `set_reservation_pricing` byl
-- SECURITY INVOKER a po odebrání SELECTu na `settings` shodil zakládání
-- rezervací přímým zápisem.
--
-- `SET LOCAL ROLE authenticated` platí do konce transakce; `RESET ROLE` se vrací.
-- -----------------------------------------------------------------------------
DO $$ BEGIN RAISE NOTICE '--- pod rolí authenticated ---'; END $$;

-- 4a) Admin ceník uloží
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _puvodni numeric;
BEGIN
  SELECT club_default_rate INTO _puvodni FROM public.settings_public LIMIT 1;
  UPDATE public.settings SET club_default_rate = 777 WHERE singleton = true;
  PERFORM pg_temp.tvrd(
    (SELECT club_default_rate FROM public.settings_public LIMIT 1) = 777,
    'admin (role authenticated): ceník uloží i po odebrání SELECTu');
  UPDATE public.settings SET club_default_rate = _puvodni WHERE singleton = true;
  PERFORM pg_temp.tvrd(
    (SELECT club_default_rate FROM public.settings_public LIMIT 1) IS NOT DISTINCT FROM _puvodni,
    'admin (role authenticated): původní ceník obnoven');
END $$;

-- 4b) Člen ceník NEuloží a sazby NEpřečte
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _pred numeric; _po numeric; _spadlo boolean := false;
BEGIN
  RESET ROLE;                                   -- na odečet potřebujeme vidět skutečnou hodnotu
  SELECT club_default_rate INTO _pred FROM public.settings LIMIT 1;
  SET LOCAL ROLE authenticated;

  UPDATE public.settings SET club_default_rate = 1 WHERE singleton = true;

  RESET ROLE;
  SELECT club_default_rate INTO _po FROM public.settings LIMIT 1;
  SET LOCAL ROLE authenticated;

  PERFORM pg_temp.tvrd(_po IS NOT DISTINCT FROM _pred,
    'člen (role authenticated): ceník přepsat nedokáže (RLS zahodí 0 řádků)');

  BEGIN
    PERFORM club_default_rate FROM public.settings LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN
    _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo,
    'člen (role authenticated): čtení sazby z tabulky skončí na permission denied');
END $$;

-- 4c) Nacenění: přímý INSERT musí projít i po odebrání SELECTu na settings
--     Tohle je test na blokér, kvůli kterému musel být pricing trigger
--     přepnutý na SECURITY DEFINER.
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _id uuid; _sazba numeric;
BEGIN
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, status)
  VALUES ((SELECT id FROM public.sheets ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1),
          (TIMESTAMP '2031-02-03 10:00' AT TIME ZONE 'Europe/Prague'),
          (TIMESTAMP '2031-02-03 11:00' AT TIME ZONE 'Europe/Prague'),
          'confirmed')
  RETURNING id INTO _id;

  RESET ROLE;
  SELECT rate_per_hour INTO _sazba FROM public.reservations WHERE id = _id;
  SET LOCAL ROLE authenticated;

  PERFORM pg_temp.tvrd(_id IS NOT NULL,
    'přímý INSERT rezervace projde i po odebrání SELECTu na settings');
  PERFORM pg_temp.tvrd(_sazba IS NOT NULL AND _sazba > 0,
    format('nacenění z ceníku funguje dál (sazba %s Kč/h)', _sazba));
END $$;

RESET ROLE;

-- -----------------------------------------------------------------------------
-- 5) Sazby subjektů — stejná díra jako ceník, stejná oprava
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sazba numeric; _radku int; _spadlo boolean := false;
BEGIN
  -- Admin sazby subjektů vidí
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text, true);
  SELECT count(*) INTO _radku FROM public.subjects_rates;
  PERFORM pg_temp.tvrd(_radku > 0, format('admin: subjects_rates vrací řádky (%s)', _radku));

  -- Instruktor (rep klubu, NE admin) je nesmí dostat ani přes pohled
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '22222222-2222-2222-2222-222222222222')::text, true);
  SELECT count(*) INTO _radku FROM public.subjects_rates;
  PERFORM pg_temp.tvrd(_radku = 0, format('instruktor: subjects_rates je prázdný (vrátil %s)', _radku));
END $$;

-- A napřímo z tabulky to nesmí jít vůbec — tohle byla ta živá cesta,
-- kterou instruktor u svého klubu četl 450 Kč/h.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
DO $$
DECLARE _spadlo boolean := false; _jmeno text;
BEGIN
  BEGIN
    PERFORM default_rate FROM public.subjects LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN
    _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo,
    'instruktor: čtení subjects.default_rate skončí na permission denied');

  -- Ostatní sloupce mu ale zůstaly, jinak by se rozbil výběr klubu v dialogu
  SELECT name INTO _jmeno FROM public.subjects WHERE deleted_at IS NULL LIMIT 1;
  PERFORM pg_temp.tvrd(_jmeno IS NOT NULL, 'instruktor: název subjektu vidí dál');
END $$;
RESET ROLE;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
