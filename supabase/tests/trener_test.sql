-- =============================================================================
-- TESTY: trenér k tréninku (blok C, varianta D)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/trener_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Přiřazením trenéra vzniká PLACENÁ směna (600 Kč/h). Nejcennější tvrzení jsou
-- proto tři: že směna vznikne až přiřazením (ne založením tréninku), že vznikne
-- rovnou OBSAZENÁ (jinak by ji dorovnání štábu zrušilo jako přebytek), a že se
-- nedá odebrat, když je uzavřená — to už jsou peníze.
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

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- Příprava: TRÉNINK klubu + dva lidé s rolí trenéra + jeden bez ní
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _klub uuid; _draha uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  SELECT id INTO _draha FROM public.sheets WHERE active ORDER BY name LIMIT 1;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST trénink A-tým', 'training',
          '2027-05-12 17:00+02','2027-05-12 19:00+02',
          '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _ev;

  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES (_draha, _klub, _ev, '2027-05-12 17:00+02','2027-05-12 19:00+02');

  -- Dva trenéři (instruktor a clen2 dostanou roli), clen zůstane bez ní.
  INSERT INTO public.user_roles (user_id, role) VALUES
    ('22222222-2222-2222-2222-222222222222','trainer'),
    ('55555555-5555-5555-5555-555555555555','trainer')
  ON CONFLICT (user_id, role) DO NOTHING;

  INSERT INTO _s VALUES ('ev', _ev::text), ('klub', _klub::text);

  PERFORM pg_temp.tvrd((SELECT event_type FROM public.events WHERE id = _ev) = 'training',
    'příprava: máme trénink s jednou rezervací');
END $$;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO P1: trénink SÁM O SOBĚ nic nestojí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts WHERE event_id = _ev) = 0,
    'trénink bez trenéra NEGENERUJE žádnou směnu (rozhodnutí P1)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) C1: přání je nezávazné a nic nespouští
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  UPDATE public.reservations
     SET preferovany_trener = '22222222-2222-2222-2222-222222222222'
   WHERE event_id = _ev;

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE event_id = _ev AND preferovany_trener IS NOT NULL) = 1,
    'přání trenéra se uloží na rezervaci');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts WHERE event_id = _ev) = 0,
    '… a NEVZNIKNE z něj žádná směna (je to přání, ne přiřazení)');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO C2: přiřazením vzniká PLACENÁ a rovnou OBSAZENÁ směna
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _v jsonb; _sh record;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  _v := public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');

  SELECT * INTO _sh FROM public.shifts WHERE event_id = _ev AND status <> 'cancelled';

  PERFORM pg_temp.tvrd(_sh.required_role = 'trainer', 'přiřazením vznikla trenérská směna');
  PERFORM pg_temp.tvrd(_sh.hourly_rate = 600,
    '… se sazbou 600 Kč/h z ceníku rolí (ne z konstanty v kódu)');
  PERFORM pg_temp.tvrd(_sh.claimed_by = '22222222-2222-2222-2222-222222222222',
    '… přiřazená konkrétnímu trenérovi');
  PERFORM pg_temp.tvrd(_sh.status = 'claimed',
    '… a rovnou OBSAZENÁ, ne „open" (jinak by ji sebral kdokoli jiný)');
  PERFORM pg_temp.tvrd((_v ->> 'sazba')::numeric = 600, 'RPC vrací i sazbu');
END $$;

-- -----------------------------------------------------------------------------
-- 4) DOROVNÁNÍ ŠTÁBU JI NESMÍ ZRUŠIT
--
-- Tohle je ten důvod, proč se zakládá `claimed`. `dorovnej_stab` nemá pro
-- tréninky předčasný návrat a trenérská směna z něj vyjde jako přebytek —
-- ruší ale jen `open`.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _pred int; _po int;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  SELECT count(*) INTO _pred FROM public.shifts WHERE event_id = _ev AND status <> 'cancelled';

  PERFORM public.dorovnej_stab(_ev, false);

  SELECT count(*) INTO _po FROM public.shifts WHERE event_id = _ev AND status <> 'cancelled';
  PERFORM pg_temp.tvrd(_pred = 1 AND _po = 1,
    'dorovnání štábu obsazenou trenérskou směnu NEZRUŠÍ');

  -- A pro kontrast: kdyby byla „open", zrušilo by ji. Ověřujeme to, aby bylo
  -- doložené, že ten návrh není opatrnost navíc, ale nutnost.
  UPDATE public.shifts SET status = 'open', claimed_by = NULL
   WHERE event_id = _ev AND required_role = 'trainer';
  PERFORM public.dorovnej_stab(_ev, false);
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE event_id = _ev AND required_role='trainer') = 'cancelled',
    '… ale „open" směnu by zrušilo — proto se zakládá obsazená');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Zábradlí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _komercni uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prirad_trenera(%L, %L)', _ev, '44444444-4444-4444-4444-444444444444'),
    'není vedený jako trenér',
    'člověka bez role trenéra přiřadit nejde (roli uděluje jen admin, P2)');

  SELECT id INTO _komercni FROM public.events WHERE event_type = 'commercial' LIMIT 1;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prirad_trenera(%L, %L)', _komercni, '22222222-2222-2222-2222-222222222222'),
    'jen k tréninku',
    'ke komerční akci se trenér nepřiřazuje (tam je štáb přes role_reqs)');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prirad_trenera(%L, %L)', gen_random_uuid(), '22222222-2222-2222-2222-222222222222'),
    'nenalezena', 'neexistující akce skončí chybou');
END $$;

-- -----------------------------------------------------------------------------
-- 6) Výměna trenéra a odebrání
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _v jsonb;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';

  PERFORM public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');
  _v := public.prirad_trenera(_ev, '55555555-5555-5555-5555-555555555555');

  PERFORM pg_temp.tvrd((_v ->> 'zmena')::boolean, 'výměna trenéra proběhla');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts WHERE event_id = _ev AND status <> 'cancelled') = 1,
    '… a zůstala jediná živá směna (jeden trenér na trénink)');
  PERFORM pg_temp.tvrd(
    (SELECT claimed_by FROM public.shifts WHERE event_id = _ev AND status <> 'cancelled')
      = '55555555-5555-5555-5555-555555555555',
    '… patřící novému trenérovi');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _ev AND status = 'cancelled' AND cancelled_at IS NOT NULL) >= 1,
    '… a ta stará je zrušená SOFT, s razítkem (nic se nemaže)');

  -- Opakované přiřazení téhož člověka je bez efektu.
  _v := public.prirad_trenera(_ev, '55555555-5555-5555-5555-555555555555');
  PERFORM pg_temp.tvrd(NOT (_v ->> 'zmena')::boolean,
    'přiřazení téhož trenéra podruhé nic nemění (idempotence)');

  -- Odebrání.
  _v := public.odeber_trenera(_ev);
  PERFORM pg_temp.tvrd((_v ->> 'zmena')::boolean, 'odebrání trenéra proběhlo');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts WHERE event_id = _ev AND status <> 'cancelled') = 0,
    '… a trénink zase nikoho nestojí');
END $$;

-- -----------------------------------------------------------------------------
-- 7) UZAVŘENOU směnu nejde odebrat — jsou to peníze
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  PERFORM public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');
  UPDATE public.shifts SET status = 'completed', hours_worked = 2
   WHERE event_id = _ev AND status = 'claimed';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.odeber_trenera(%L)', _ev),
    'uzavřenou', 'uzavřenou směnu odebrat nejde (podklad pro výplatu)');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prirad_trenera(%L, %L)', _ev, '55555555-5555-5555-5555-555555555555'),
    'uzavřenou', '… ani vyměnit trenéra');
END $$;

-- -----------------------------------------------------------------------------
-- 8) Práva pod skutečnou rolí (pravidlo 8)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'kontrola práv běží jako authenticated, ne jako postgres');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prirad_trenera(%L, %L)', _ev, '22222222-2222-2222-2222-222222222222'),
    'správce haly nebo zástupce klubu',
    'brigádník trenéra nepřiřadí');

  EXECUTE 'RESET ROLE';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
