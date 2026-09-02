-- =============================================================================
-- TEST: sazbu a odpracované hodiny na směně mění jen správce haly (nález F1)
-- Migrace 20260902260000_smena_sazbu_meni_jen_admin.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/smena_sazba_jen_admin_test.sql
--
-- ⚠️ VŠECHNO, CO MĚŘÍ PRÁVA, BĚŽÍ POD `SET LOCAL ROLE authenticated`.
-- Jako `postgres` projde všechno (obchází granty i RLS) — a tenhle konkrétní
-- nález se přes granty právě dostal ven: `hourly_rate` je pro `authenticated`
-- v tabulkovém UPDATE grantu. Test běžící jako `postgres` by tvrdil, že jsou
-- dveře zavřené, a nevšiml si otevřeného okna.
--
-- MUTAČNÍ ZKOUŠKA (dělej ji, když na guardu saháš):
--   Vypni v `validate_shift_claim()` blok „SAZBU A HODINY MĚNÍ JEN SPRÁVCE
--   HALY" a pusť tenhle soubor znovu. MUSÍ zčervenat na scénářích 1 a 2.
--   Když projde i bez guardu, nehlídá nic.
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
-- Scénáře běží pod `authenticated`, takže si na pomocnou tabulku musí sáhnout.
GRANT SELECT ON _s TO authenticated;

-- ---------------------------------------------------------------------------
-- PŘÍPRAVA (jako postgres): akce a dvě volné směny vypsané adminem na 200 Kč/h
-- ---------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _s1 uuid; _s2 uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST sazba směny','commercial','2028-05-05 17:00+02','2028-05-05 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.shifts (event_id, required_role, status, hourly_rate)
  VALUES (_ev,'part_time_staff','open',200) RETURNING id INTO _s1;
  INSERT INTO public.shifts (event_id, required_role, status, hourly_rate)
  VALUES (_ev,'bar_staff','open',200) RETURNING id INTO _s2;
  INSERT INTO _s VALUES ('ev',_ev::text),('s1',_s1::text),('s2',_s2::text);
END $$;

-- ---------------------------------------------------------------------------
-- 1) JÁDRO NÁLEZU — brigádník si při zabrání nastaví sazbu i hodiny
--    Přesně ten příkaz, kterým to bylo naměřeno na produkci.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

DO $$
DECLARE _s1 uuid;
BEGIN
  SELECT hodnota::uuid INTO _s1 FROM _s WHERE klic='s1';

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET status='pending',
                 claimed_by='33333333-3333-3333-3333-333333333333',
                 hours_worked=24, hourly_rate=10000 WHERE id=%L$q$, _s1),
    'Sazbu, hodiny, vazbu na výplatu ani poznámku',
    'brigádník si při ZABRÁNÍ nenastaví sazbu ani hodiny (jádro F1)');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET hourly_rate=9999 WHERE id=%L$q$, _s1),
    'Sazbu, hodiny, vazbu na výplatu ani poznámku',
    '… ani samostatně u VOLNÉ směny (9 999 je „v rozsahu", a přesto ne)');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET hours_worked=24 WHERE id=%L$q$, _s1),
    'Sazbu, hodiny, vazbu na výplatu ani poznámku',
    '… ani samotné odpracované hodiny');
END $$;

-- ---------------------------------------------------------------------------
-- 2) DVOUKROKOVÁ VARIANTA — nadhodnotit dopředu a teprve pak si vzít
--    (kdyby brána hlídala jen přechod open→pending, tudy by to prošlo)
-- ---------------------------------------------------------------------------
DO $$
DECLARE _s2 uuid;
BEGIN
  SELECT hodnota::uuid INTO _s2 FROM _s WHERE klic='s2';
  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET hourly_rate=10000 WHERE id=%L$q$, _s2),
    'Sazbu, hodiny, vazbu na výplatu ani poznámku',
    'nadhodnocení sazby PŘED zabráním neprojde (dvoukroková varianta)');
END $$;

-- ---------------------------------------------------------------------------
-- 3) LEGITIMNÍ ZABRÁNÍ MUSÍ DÁL PROJÍT — jinak jsme rozbili provoz
-- ---------------------------------------------------------------------------
DO $$
DECLARE _s1 uuid;
BEGIN
  SELECT hodnota::uuid INTO _s1 FROM _s WHERE klic='s1';
  UPDATE public.shifts
     SET status='pending', claimed_by='33333333-3333-3333-3333-333333333333', claimed_at=now()
   WHERE id=_s1;
  PERFORM pg_temp.tvrd(
    (SELECT status='pending' AND claimed_by='33333333-3333-3333-3333-333333333333'
            AND hourly_rate=200 AND hours_worked IS NULL FROM public.shifts WHERE id=_s1),
    'legitimní zabrání projde a sazba zůstane na 200 Kč, jak ji zadal admin');

  -- Odhlásit se sám musí jít taky (claimed_by zpátky na NULL).
  UPDATE public.shifts SET status='open', claimed_by=NULL, claimed_at=NULL WHERE id=_s1;
  PERFORM pg_temp.tvrd(
    (SELECT status='open' AND claimed_by IS NULL FROM public.shifts WHERE id=_s1),
    'odhlášení z vlastní směny projde');
END $$;

-- ---------------------------------------------------------------------------
-- 4) ADMIN SMÍ DÁL — dokončení směny je jediná legitimní cesta k těm sloupcům
-- ---------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

DO $$
DECLARE _s1 uuid;
BEGIN
  SELECT hodnota::uuid INTO _s1 FROM _s WHERE klic='s1';
  UPDATE public.shifts SET status='pending', claimed_by='33333333-3333-3333-3333-333333333333',
         claimed_at=now() WHERE id=_s1;
  UPDATE public.shifts SET status='claimed' WHERE id=_s1;
  UPDATE public.shifts SET status='completed', hours_worked=6, hourly_rate=250,
         completed_at=now() WHERE id=_s1;
  PERFORM pg_temp.tvrd(
    (SELECT status='completed' AND hours_worked=6 AND hourly_rate=250
       FROM public.shifts WHERE id=_s1),
    'admin sazbu i hodiny při dokončení nastaví (completeShift dál funguje)');
END $$;

-- ---------------------------------------------------------------------------
-- 5) DRUHÁ CESTA K TÝMŽ PENĚZŮM — znovuotevření cizí DOKONČENÉ směny
--    Útočník ta čísla nemění, on je zdědí. Kdyby chyběl guard proti
--    `completed → open`, byl by zbytek téhle migrace k ničemu.
-- ---------------------------------------------------------------------------
RESET ROLE;

DO $$
DECLARE _ev uuid; _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';
  -- kolegova dokončená trenérská směna: 8 h × 600 Kč
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at,
                             hours_worked, hourly_rate, completed_at)
  VALUES (_ev,'trainer','completed','22222222-2222-2222-2222-222222222222', now(), 8, 600, now())
  RETURNING id INTO _sm;
  INSERT INTO _s VALUES ('hotova', _sm::text);
END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

DO $$
DECLARE _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _sm FROM _s WHERE klic='hotova';

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET status='open', claimed_by=NULL, claimed_at=NULL,
                 completed_at=NULL WHERE id=%L$q$, _sm),
    'Uzavřenou směnu znovu otevírá',
    'brigádník znovu neotevře cizí DOKONČENOU směnu (jádro F5)');

  PERFORM pg_temp.tvrd(
    (SELECT status='completed' AND claimed_by='22222222-2222-2222-2222-222222222222'
       FROM public.shifts WHERE id=_sm),
    '… a kolegovi zůstal podklad k výplatě netknutý');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET payout_id=NULL, status='open' WHERE id=%L$q$, _sm),
    'Uzavřenou směnu znovu otevírá',
    '… ani oklikou přes payout_id');
END $$;

-- ---------------------------------------------------------------------------
-- 6) payout_id a notes jsou pro štáb taky zamčené
-- ---------------------------------------------------------------------------
DO $$
DECLARE _s1 uuid;
BEGIN
  SELECT hodnota::uuid INTO _s1 FROM _s WHERE klic='s2';
  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET notes='PŘIPSÁNO' WHERE id=%L$q$, _s1),
    'vazbu na výplatu ani poznámku',
    'brigádník nepřipíše poznámku ke směně');
END $$;

-- ---------------------------------------------------------------------------
-- 7) ADMIN uzavřenou směnu znovu otevřít SMÍ (výměna, oprava)
-- ---------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
DO $$
DECLARE _sm uuid;
BEGIN
  SELECT hodnota::uuid INTO _sm FROM _s WHERE klic='hotova';
  UPDATE public.shifts SET status='open', claimed_by=NULL, claimed_at=NULL, completed_at=NULL
   WHERE id=_sm;
  PERFORM pg_temp.tvrd((SELECT status='open' FROM public.shifts WHERE id=_sm),
    'admin uzavřenou směnu znovu otevřít smí');
END $$;

RESET ROLE;
ROLLBACK;
