-- =============================================================================
-- TESTY: zrušená směna zruší i přihlášky, které na ní visí (bug #7)
-- Migrace 20260902160000_zrusena_smena_zrusi_prihlasky.sql
-- =============================================================================
-- Přihlášku na směnu, která se nekoná, vidí brigádník v přehledu jako
-- „čeká na vyřízení" a admin ve frontě jako položku ke schválení. Vyřídit ji
-- nešlo — směna už neexistovala. Nejcennější tvrzení je první.
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

-- Komerční akce, čtyři směny a na každé přihláška v jiném stavu.
DO $$
DECLARE _ev uuid; _rez uuid; _s1 uuid; _s2 uuid; _s3 uuid; _s4 uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST přihlášky','commercial','2029-06-06 17:00+02','2029-06-06 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE type='commercial' AND deleted_at IS NULL LIMIT 1),
          _ev,'2029-06-06 17:00+02','2029-06-06 19:00+02','TEST přihlášky')
  RETURNING id INTO _rez;

  INSERT INTO public.shifts (event_id, required_role, status) VALUES (_ev,'bar_staff','open')     RETURNING id INTO _s1;
  INSERT INTO public.shifts (event_id, required_role, status) VALUES (_ev,'instructor','open')    RETURNING id INTO _s2;
  INSERT INTO public.shifts (event_id, required_role, status) VALUES (_ev,'part_time_staff','open') RETURNING id INTO _s3;
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at, hours_worked)
  VALUES (_ev,'manager','completed','55555555-5555-5555-5555-555555555555', now(), 2) RETURNING id INTO _s4;

  INSERT INTO public.shift_applications (shift_id, user_id, status) VALUES
    (_s1,'33333333-3333-3333-3333-333333333333','pending'),
    (_s2,'33333333-3333-3333-3333-333333333333','approved'),
    (_s3,'33333333-3333-3333-3333-333333333333','rejected'),
    (_s4,'55555555-5555-5555-5555-555555555555','approved');

  INSERT INTO _s VALUES ('ev',_ev::text), ('rez',_rez::text),
                        ('s1',_s1::text), ('s2',_s2::text), ('s3',_s3::text), ('s4',_s4::text);
END $$;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: zrušení akce vezme přihlášky s sebou
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rez uuid; _s1 uuid; _s2 uuid; _s3 uuid; _s4 uuid;
BEGIN
  SELECT hodnota::uuid INTO _rez FROM _s WHERE klic='rez';
  SELECT hodnota::uuid INTO _s1 FROM _s WHERE klic='s1';
  SELECT hodnota::uuid INTO _s2 FROM _s WHERE klic='s2';
  SELECT hodnota::uuid INTO _s3 FROM _s WHERE klic='s3';
  SELECT hodnota::uuid INTO _s4 FROM _s WHERE klic='s4';

  UPDATE public.reservations SET status='cancelled' WHERE id=_rez;

  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications WHERE shift_id=_s1) = 'cancelled',
    'ČEKAJÍCÍ přihláška na zrušenou směnu se zrušila (jádro bugu #7)');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications WHERE shift_id=_s2) = 'cancelled',
    '… i schválená (brigádník by jinak čekal na směnu, která se nekoná)');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications WHERE shift_id=_s3) = 'rejected',
    'ZAMÍTNUTÁ zůstává zamítnutá — jak to dopadlo, se nepřepisuje');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications WHERE shift_id=_s4) = 'approved',
    'přihláška na ODPRACOVANOU směnu zůstává (ta se neruší, #6)');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shift_applications a JOIN public.shifts s ON s.id=a.shift_id
      WHERE s.event_id=(SELECT hodnota::uuid FROM _s WHERE klic='ev')
        AND s.status='cancelled' AND a.status IN ('pending','approved')) = 0,
    '… a na zrušených směnách nevisí ani jedna živá přihláška');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Trigger visí na SMĚNĚ, ne na rezervaci — platí i pro jiné cesty zrušení
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _sh uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST přihlášky 2','commercial','2029-06-13 17:00+02','2029-06-13 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.shifts (event_id, required_role, status) VALUES (_ev,'bar_staff','open')
  RETURNING id INTO _sh;
  INSERT INTO public.shift_applications (shift_id, user_id, status)
  VALUES (_sh,'33333333-3333-3333-3333-333333333333','pending');

  -- Zrušení SAMOTNÉ směny (admin ve Správě směn), bez rušení rezervace.
  UPDATE public.shifts SET status='cancelled', cancelled_at=now() WHERE id=_sh;

  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications WHERE shift_id=_sh) = 'cancelled',
    'ruší se i při zrušení samotné směny, ne jen celé akce');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
