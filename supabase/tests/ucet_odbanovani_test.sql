-- =============================================================================
-- TESTY: zavřený účet se nesmí otevřít přes žádost o klub
-- Migrace 20260831230000_ucet_nelze_odbanovat.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/ucet_odbanovani_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- `ucet_aktivni()` je brána pod `has_role`, `is_subject_member` i `is_subject_rep`,
-- takže otevřít účet znamená otevřít všechno. Cesta, kterou to šlo udělat bez
-- admina, vedla přes frontu žádostí o klub — a schvaluje ji ZÁSTUPCE, který
-- o deaktivaci nic neví. Nejcennější tvrzení je proto to poslední: zástupce
-- deaktivovaný účet neotevře ani tehdy, když žádost ve frontě už leží.
--
-- Práva se testují pod `SET LOCAL ROLE authenticated` (pravidlo 8) — jako
-- postgres projde všechno a test by tvrdil zavřeno o dveřích, vedle kterých
-- je otevřené okno.
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
  IF NOT COALESCE(_podminka, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
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

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);

-- -----------------------------------------------------------------------------
-- Příprava: dva nové účty — jeden čeká, druhý je admin deaktivoval
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ceka uuid := '77777777-7777-7777-7777-777777777771';
        _zavr uuid := '77777777-7777-7777-7777-777777777772';
        _klub uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';

  INSERT INTO auth.users (id, email, instance_id, aud, role)
  VALUES (_ceka, 'ceka@test.local', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated'),
         (_zavr, 'zavreny@test.local', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');

  -- `handle_new_user` je trigger na auth.users, takže profily už existují.
  -- Ať test nestojí na tom, jestli se spustil: doplníme, co chybí.
  INSERT INTO public.profiles (user_id, full_name) VALUES (_ceka, 'Čekající')
    ON CONFLICT (user_id) DO NOTHING;
  INSERT INTO public.profiles (user_id, full_name) VALUES (_zavr, 'Zavřený')
    ON CONFLICT (user_id) DO NOTHING;

  UPDATE public.profiles SET stav = 'ceka'        WHERE user_id = _ceka;
  UPDATE public.profiles SET stav = 'deaktivovan' WHERE user_id = _zavr;

  INSERT INTO _s VALUES ('ceka', _ceka::text), ('zavr', _zavr::text), ('klub', _klub::text);

  PERFORM pg_temp.tvrd(NOT public.ucet_aktivni(_zavr), 'příprava: zavřený účet je pro ucet_aktivni() neaktivní');
END $$;

-- -----------------------------------------------------------------------------
-- 1) ZAVŘENÝ ÚČET SI ŽÁDOST NEPODÁ (první vrstva)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"77777777-7777-7777-7777-777777777772","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'test práv běží jako authenticated, ne jako postgres');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.request_subject_membership(%L, NULL)', _klub),
    'uzavřený', 'deaktivovaný účet si žádost o klub nepodá');

  EXECUTE 'RESET ROLE';
END $$;

-- Účet, který teprve ČEKÁ, si ji podat MUSÍ — je to jediná cesta dovnitř.
DO $$
DECLARE _klub uuid; _z uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"77777777-7777-7777-7777-777777777771","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  _z := public.request_subject_membership(_klub, 'Chci hrát');
  PERFORM pg_temp.tvrd(_z IS NOT NULL, 'čekající účet žádost podat SMÍ (jinak by se dovnitř nedostal nikdo)');

  EXECUTE 'RESET ROLE';
  INSERT INTO _s VALUES ('zadost_ceka', _z::text);
END $$;

-- -----------------------------------------------------------------------------
-- 2) SCHVÁLENÍ ČEKAJÍCÍHO ÚČTU HO OTEVŘE (regrese: nesmíme zavřít správnou cestu)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _z uuid; _ceka uuid;
BEGIN
  SELECT hodnota::uuid INTO _z    FROM _s WHERE klic = 'zadost_ceka';
  SELECT hodnota::uuid INTO _ceka FROM _s WHERE klic = 'ceka';

  -- Schvaluje ZÁSTUPCE klubu (44444444), ne admin — to je ta rizikovější cesta.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM public.approve_subject_request(_z, 'member');

  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(
    (SELECT stav FROM public.profiles WHERE user_id = _ceka) = 'aktivni',
    'zástupce schválením otevřel ČEKAJÍCÍ účet (to je správně)');
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _ceka AND role = 'hobby_player'),
    '… a přidělil mu roli');
END $$;

-- -----------------------------------------------------------------------------
-- 3) STARÁ ŽÁDOST VE FRONTĚ ZAVŘENÝ ÚČET NEOTEVŘE (druhá vrstva)
--
-- Tohle je jádro nálezu: žádost vznikla PŘED deaktivací, takže první vrstva
-- (zákaz podání) ji nezachytí. Zástupce ji ve frontě vidí a klikne v dobré víře.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _zavr uuid; _klub uuid; _z uuid;
BEGIN
  SELECT hodnota::uuid INTO _zavr FROM _s WHERE klic = 'zavr';
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';

  -- Žádost „z doby před deaktivací" — vkládá se přímo, protože RPC by ji dnes
  -- (správně) nepustila.
  INSERT INTO public.subject_requests (user_id, subject_id)
  VALUES (_zavr, _klub) RETURNING id INTO _z;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, %L)', _z, 'member'),
    'uzavřený', 'zástupce klubu NEOTEVŘE deaktivovaný účet schválením žádosti');

  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd(
    (SELECT stav FROM public.profiles WHERE user_id = _zavr) = 'deaktivovan',
    '… a účet zůstal zavřený');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _zavr),
    '… a role mu nepřibyla');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.subject_reps WHERE user_id = _zavr),
    '… ani členství v klubu');
END $$;

-- Ani ADMIN neotevře účet omylem přes frontu — obnovení je vědomý krok jinde.
DO $$
DECLARE _zavr uuid; _klub uuid; _z uuid;
BEGIN
  SELECT hodnota::uuid INTO _zavr FROM _s WHERE klic = 'zavr';
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _zavr AND status = 'ceka' LIMIT 1;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, %L)', _z, 'member'),
    'uzavřený', 'ani admin neotevře zavřený účet schválením ve frontě');

  EXECUTE 'RESET ROLE';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
