-- =============================================================================
-- TESTY: zrušená akce uvolní i obsazené směny (bug #6)
-- Migrace 20260902120000_zruseni_uvolni_smeny.sql
-- =============================================================================
-- CO TENHLE SOUBOR HLÍDÁ:
-- Trenérská směna vzniká rovnou jako `claimed` (rozhodnutí P1), takže úklid
-- po zrušené akci, který sahal jen na `open`/`pending`, se jí míjel VŽDYCKY.
-- Na zrušeném tréninku pak zůstala potvrzená směna za 600 Kč/h.
--
-- Nejcennější tvrzení: po zrušení nezůstane ani jedna živá směna — kromě
-- `completed`, kde se práce odvedla a je to podklad pro výplatu.
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

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);

-- Trénink s trenérem (claimed), instruktorem (claimed), volnou a odpracovanou.
DO $$
DECLARE _ev uuid; _rez uuid;
BEGIN
  INSERT INTO public.user_roles (user_id, role)
  VALUES ('22222222-2222-2222-2222-222222222222','trainer') ON CONFLICT DO NOTHING;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST zrušení směn','training','2028-12-06 17:00+01','2028-12-06 19:00+01',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name='CK Ostravské kameny'), _ev,
          '2028-12-06 17:00+01','2028-12-06 19:00+01','TEST zrušení směn')
  RETURNING id INTO _rez;

  PERFORM public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_ev,'instructor','claimed','33333333-3333-3333-3333-333333333333', now());
  INSERT INTO public.shifts (event_id, required_role, status) VALUES (_ev,'bar_staff','open');
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at, hours_worked)
  VALUES (_ev,'manager','completed','55555555-5555-5555-5555-555555555555', now(), 2);

  INSERT INTO _s VALUES ('ev',_ev::text), ('rez',_rez::text);

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts WHERE event_id=_ev AND status='claimed') = 2,
    'příprava: trenér i instruktor jsou obsazení (claimed)');
END $$;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: zrušení akce uvolní obsazené směny
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _rez uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  SELECT hodnota::uuid INTO _rez FROM _s WHERE klic='rez';

  UPDATE public.reservations SET status='cancelled' WHERE id=_rez;

  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE event_id=_ev AND required_role='trainer') = 'cancelled',
    'TRENÉRSKÁ SMĚNA SE ZRUŠILA (jádro bugu #6 — hala ji jinak platí)');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE event_id=_ev AND required_role='instructor') = 'cancelled',
    '… instruktorská taky');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE event_id=_ev AND required_role='bar_staff') = 'cancelled',
    '… volná směna jako dřív');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE event_id=_ev AND required_role='manager') = 'completed',
    'ODPRACOVANÁ směna ZŮSTÁVÁ (podklad pro výplatu)');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id=_ev AND status NOT IN ('cancelled','completed')) = 0,
    '… a na zrušené akci nezůstala ani jedna živá směna');

  -- Soft, ne smazané.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts WHERE event_id=_ev) = 4,
    'nic se nesmazalo — čtyři řádky tam pořád jsou (zásada 2)');
  PERFORM pg_temp.tvrd(
    (SELECT cancelled_at FROM public.shifts WHERE event_id=_ev AND required_role='trainer') IS NOT NULL,
    '… a zrušené mají razítko kdy');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Akce s víc drahami: dokud žije aspoň jedna rezervace, směny zůstávají
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _d2 uuid; _r2 uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST dve drahy','training','2028-12-13 17:00+01','2028-12-13 19:00+01',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  SELECT id INTO _d2 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note)
  VALUES (_d2, (SELECT id FROM public.subjects WHERE name='CK Ostravské kameny'), _ev,
          '2028-12-13 17:00+01','2028-12-13 19:00+01','TEST dve drahy A')
  RETURNING id INTO _r2;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note)
  VALUES ((SELECT id FROM public.sheets WHERE active AND id <> _d2 ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name='CK Ostravské kameny'), _ev,
          '2028-12-13 17:00+01','2028-12-13 19:00+01','TEST dve drahy B');
  PERFORM public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');

  UPDATE public.reservations SET status='cancelled' WHERE id=_r2;
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE event_id=_ev AND required_role='trainer') = 'claimed',
    'zrušení JEDNÉ dráhy z dvoudráhové akce trenéra NEUVOLNÍ (akce se pořád koná)');

  UPDATE public.reservations SET status='cancelled' WHERE event_id=_ev AND status='confirmed';
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE event_id=_ev AND required_role='trainer') = 'cancelled',
    '… až zrušení POSLEDNÍ dráhy ho uvolní');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
