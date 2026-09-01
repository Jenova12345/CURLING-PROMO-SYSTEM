-- =============================================================================
-- TESTY: placené směny nejdou zdvojit (nálezy 9 a 10)
-- Migrace 20260901160000_smeny_nejdou_zdvojit.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/smeny_zdvojeni_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ — A CO NE.
--
-- `prirad_trenera` i `validate_shift_claim` se ptají `SELECT … EXISTS/LIMIT 1`
-- a podle výsledku zapisují. Dva souběžné běhy pod READ COMMITTED oba uvidí
-- „nic tam není" a oba zapíšou — u směn to znamená výplatu dvakrát. Zavírají
-- to UNIKÁTNÍ INDEXY, protože kontrola v kódu se v souběhu z principu mine.
--
-- ⚠️ TENHLE TEST NEREPRODUKUJE SOUBĚH. Naplánovat ze skriptu, aby se dvě
-- volání RPC prokousala přesně mezi svým čtením a zápisem, spolehlivě nejde —
-- `docker exec` má vlastní latenci a první běh stihne commitnout dřív, než
-- druhý začne. Napsal jsem na to shellovou verzi a byla FALEŠNĚ ZELENÁ: bez
-- indexů vyšly stejné počty jako s nimi, protože se ta volání nikdy nepřekryla.
--
-- Testuje se proto to, co index doopravdy slibuje a co je v souběhu jediné
-- rozhodující: DRUHÝ ZÁPIS TÉHOŽ KLÍČE NEPROJDE. Že se dva běhy do takové
-- situace dostat MŮŽOU, plyne z tvaru kódu (čtení a zápis bez zámku); že z ní
-- nevyváznou dvě směny, hlídá tenhle soubor.
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
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

DO $$
DECLARE _ev uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST zdvojení směn','training','2028-04-05 17:00+02','2028-04-05 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO _s VALUES ('ev', _ev::text);
END $$;

-- -----------------------------------------------------------------------------
-- 1) NÁLEZ 9 — druhá živá trenérská směna na téže akci neprojde
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';

  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_ev,'trainer','claimed','22222222-2222-2222-2222-222222222222', now());
  PERFORM pg_temp.tvrd(true, 'první trenérská směna projde');

  PERFORM pg_temp.ocekavej_chybu(
    format($q$INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
              VALUES (%L,'trainer','claimed','55555555-5555-5555-5555-555555555555', now())$q$, _ev),
    'shifts_jeden_trener_na_akci',
    'DRUHÁ trenérská směna na téže akci NEPROJDE (jádro nálezu 9)');

  -- Zrušená se nepočítá — jinak by po výměně trenéra nešlo přiřadit nového.
  UPDATE public.shifts SET status='cancelled', cancelled_at=now()
   WHERE event_id=_ev AND required_role='trainer';
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_ev,'trainer','claimed','55555555-5555-5555-5555-555555555555', now());
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id=_ev AND required_role='trainer' AND status <> 'cancelled') = 1,
    '… ale po ZRUŠENÍ té první jde přiřadit nového trenéra (výměna funguje)');
END $$;

-- A že tudy projde i skutečné RPC, ne jen ruční INSERT.
DO $$
DECLARE _ev uuid; _v jsonb;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';
  UPDATE public.shifts SET status='cancelled' WHERE event_id=_ev AND required_role='trainer';
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name='CK Ostravské kameny'), _ev,
          '2028-04-05 17:00+02','2028-04-05 19:00+02');
  INSERT INTO public.user_roles (user_id, role)
  VALUES ('22222222-2222-2222-2222-222222222222','trainer') ON CONFLICT DO NOTHING;

  _v := public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');
  PERFORM pg_temp.tvrd((_v->>'zmena')::boolean, 'prirad_trenera() přes index projde (nezablokoval legitimní cestu)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) NÁLEZ 10 — cizí zabranou směnu nikdo nepřevezme
--
-- Původní podezření („jeden člověk nesmí mít dvě směny na akci") byl FALEŠNÝ
-- POPLACH: dvě různé role na jedné akci jsou legitimní a platí se za obě.
-- Skutečná díra je užší a nepotřebuje ani souběh.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _s1 uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';
  INSERT INTO public.shifts (event_id, required_role, status) VALUES (_ev,'bar_staff','open')
  RETURNING id INTO _s1;

  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  UPDATE public.shifts SET status='pending', claimed_by='33333333-3333-3333-3333-333333333333',
                           claimed_at=now() WHERE id=_s1;
  PERFORM pg_temp.tvrd(
    (SELECT claimed_by FROM public.shifts WHERE id=_s1) = '33333333-3333-3333-3333-333333333333',
    'brigádník si volnou směnu vezme');

  -- Někdo jiný ze štábu si ji zkusí přepsat na sebe. Bez guardu to projde
  -- a původní držitel o ni tiše přijde — i BEZ souběhu.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true);
  PERFORM pg_temp.ocekavej_chybu(
    format($q$UPDATE public.shifts SET claimed_by='55555555-5555-5555-5555-555555555555'
              WHERE id=%L$q$, _s1),
    'už má někdo jiný', 'CIZÍ ZABRANOU SMĚNU NIKDO NEPŘEVEZME (jádro nálezu 10)');

  PERFORM pg_temp.tvrd(
    (SELECT claimed_by FROM public.shifts WHERE id=_s1) = '33333333-3333-3333-3333-333333333333',
    '… a směna zůstala původnímu držiteli');

  -- Admin přeobsadit smí — nemoc, výměna.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  UPDATE public.shifts SET claimed_by='55555555-5555-5555-5555-555555555555' WHERE id=_s1;
  PERFORM pg_temp.tvrd(
    (SELECT claimed_by FROM public.shifts WHERE id=_s1) = '55555555-5555-5555-5555-555555555555',
    '… ale správce haly směnu přeobsadit MŮŽE');
END $$;

-- A dvě RŮZNÉ role jednoho člověka na téže akci musí projít (Jakub, 1. 9.).
DO $$
DECLARE _ev uuid; _a uuid; _b uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_ev,'bar_staff','claimed','33333333-3333-3333-3333-333333333333', now()) RETURNING id INTO _a;
  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_ev,'instructor','claimed','33333333-3333-3333-3333-333333333333', now()) RETURNING id INTO _b;
  PERFORM pg_temp.tvrd(_a IS NOT NULL AND _b IS NOT NULL,
    'jeden člověk MŮŽE mít na akci dvě různé role (za obě se platí)');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Indexy existují a mají predikát shodný s kódem
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='shifts_jeden_trener_na_akci'),
    'index na jednoho trenéra existuje');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname='shifts_jedna_smena_na_cloveka_a_akci'),
    'index na (akce, člověk) tu SCHVÁLNĚ NENÍ — blokoval by dvě role jednoho člověka');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
