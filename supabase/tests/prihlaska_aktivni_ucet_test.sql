-- =============================================================================
-- TEST: přihlásit se na směnu smí jen aktivní účet (nález F2)
-- Migrace 20260902262000_prihlaska_jen_aktivni_ucet.sql
-- =============================================================================
-- ⚠️ BĚŽÍ POD `SET LOCAL ROLE authenticated`. Jako `postgres` se RLS obchází
-- úplně, takže by tenhle soubor byl zelený i s původními politikami.
--
-- MUTAČNÍ ZKOUŠKA: vrať politikám tvar bez `ucet_aktivni()` (nebo tu funkci
-- z podmínek vyškrtni) a pusť to znovu — MUSÍ zčervenat na scénářích 1 a 2.
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

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);
GRANT SELECT ON _s TO authenticated;

-- PŘÍPRAVA: volná směna + brigádník, kterého budeme přepínat mezi stavy účtu.
DO $$
DECLARE _ev uuid; _sm uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST přihláška a stav účtu','commercial','2028-06-06 17:00+02','2028-06-06 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.shifts (event_id, required_role, status, hourly_rate)
  VALUES (_ev,'part_time_staff','open',200) RETURNING id INTO _sm;
  INSERT INTO _s VALUES ('sm',_sm::text);
END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 0) AKTIVNÍ ÚČET SE PŘIHLÁSIT MUSÍ — kontrola, že brána nezavřela provoz
-- ---------------------------------------------------------------------------
DO $$
DECLARE _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _sm FROM _s WHERE klic='sm';
  INSERT INTO public.shift_applications (shift_id, user_id) VALUES (_sm,'33333333-3333-3333-3333-333333333333');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shift_applications WHERE shift_id=_sm) = 1,
    'aktivní brigádník se na směnu přihlásí');

  -- Klient posílá `upsert(onConflict shift_id,user_id)` — opakované přihlášení
  -- po zamítnutí musí projít taky.
  UPDATE public.shift_applications SET status='rejected' WHERE shift_id=_sm;
  INSERT INTO public.shift_applications (shift_id, user_id, status) VALUES (_sm,'33333333-3333-3333-3333-333333333333','pending')
    ON CONFLICT (shift_id, user_id) DO UPDATE SET status='pending';
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications WHERE shift_id=_sm) = 'pending',
    'opakované přihlášení přes upsert projde (cesta z useShiftApplications.ts)');

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shift_applications WHERE shift_id=_sm) = 1,
    'aktivní brigádník svoji přihlášku vidí');
END $$;

RESET ROLE;
DELETE FROM public.shift_applications WHERE user_id='33333333-3333-3333-3333-333333333333';

-- ---------------------------------------------------------------------------
-- 1) ČEKAJÍCÍ ÚČET — jádro nálezu
-- ---------------------------------------------------------------------------
UPDATE public.profiles SET stav='ceka' WHERE user_id='33333333-3333-3333-3333-333333333333';
SET LOCAL ROLE authenticated;

DO $$
DECLARE _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _sm FROM _s WHERE klic='sm';
  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.shift_applications (shift_id, user_id)
              VALUES (%L,'33333333-3333-3333-3333-333333333333')$q$, _sm),
    'row-level security',
    'ČEKAJÍCÍ účet se na směnu nepřihlásí (jádro F2)');
END $$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 2) DEAKTIVOVANÝ ÚČET — týž zápis, druhý stav
-- ---------------------------------------------------------------------------
UPDATE public.profiles SET stav='deaktivovan' WHERE user_id='33333333-3333-3333-3333-333333333333';
SET LOCAL ROLE authenticated;

DO $$
DECLARE _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _sm FROM _s WHERE klic='sm';
  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.shift_applications (shift_id, user_id)
              VALUES (%L,'33333333-3333-3333-3333-333333333333')$q$, _sm),
    'row-level security',
    'DEAKTIVOVANÝ účet se na směnu nepřihlásí (jádro F2)');

  -- A ani upsertem, kterým chodí klient.
  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.shift_applications (shift_id, user_id, status)
              VALUES (%L,'33333333-3333-3333-3333-333333333333','pending')
              ON CONFLICT (shift_id, user_id) DO UPDATE SET status='pending'$q$, _sm),
    'row-level security',
    '… ani cestou upsertu');
END $$;

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 3) DEAKTIVOVANÝ NEVIDÍ ANI SVÉ STARÉ PŘIHLÁŠKY
-- ---------------------------------------------------------------------------
DO $$
DECLARE _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _sm FROM _s WHERE klic='sm';
  INSERT INTO public.shift_applications (shift_id, user_id) VALUES (_sm,'33333333-3333-3333-3333-333333333333');
END $$;

SET LOCAL ROLE authenticated;
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shift_applications) = 0,
    'deaktivovaný účet nevidí ani svoje dřívější přihlášky');
END $$;

-- ---------------------------------------------------------------------------
-- 4) ADMIN VIDÍ A VYŘIZUJE DÁL
-- ---------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shift_applications) >= 1,
    'admin přihlášky ve frontě vidí (i tu od zavřeného účtu, aby ji mohl uklidit)');
  UPDATE public.shift_applications SET status='rejected'
   WHERE user_id='33333333-3333-3333-3333-333333333333';
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications
      WHERE user_id='33333333-3333-3333-3333-333333333333') = 'rejected',
    'admin přihlášku vyřídí');
END $$;

-- ---------------------------------------------------------------------------
-- 5) NE-ADMIN SI VLASTNÍ PŘIHLÁŠKU NESCHVÁLÍ SÁM
-- ---------------------------------------------------------------------------
RESET ROLE;
UPDATE public.profiles SET stav='aktivni' WHERE user_id='33333333-3333-3333-3333-333333333333';
DELETE FROM public.shift_applications;
DO $$
DECLARE _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _sm FROM _s WHERE klic='sm';
  INSERT INTO public.shift_applications (shift_id, user_id, status)
  VALUES (_sm,'33333333-3333-3333-3333-333333333333','pending');
END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.shift_applications SET status='approved'
        WHERE user_id='33333333-3333-3333-3333-333333333333'$q$,
    'row-level security',
    'brigádník si vlastní přihlášku sám neschválí');

  -- Co smí dál: zrušit ji, a přihlásit se znovu.
  UPDATE public.shift_applications SET status='cancelled'
   WHERE user_id='33333333-3333-3333-3333-333333333333';
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications
      WHERE user_id='33333333-3333-3333-3333-333333333333') = 'cancelled',
    '… ale zrušit si ji smí');
END $$;

RESET ROLE;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  UPDATE public.shift_applications SET status='approved'
   WHERE user_id='33333333-3333-3333-3333-333333333333';
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shift_applications
      WHERE user_id='33333333-3333-3333-3333-333333333333') = 'approved',
    'admin přihlášku schválit smí (legitimní cesta zůstala)');
END $$;

RESET ROLE;
ROLLBACK;
