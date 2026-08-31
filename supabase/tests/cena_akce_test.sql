-- =============================================================================
-- TESTY: komerční akce se oceňuje jako CELEK (BUG 1)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/cena_akce_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Komerční akce na dvou drahách jsou DVĚ rezervace pod jedním `event_id`.
-- Dokud se sazba měnila po rezervacích, mohla mít jedna akce dvě různé ceny za
-- touž hodinu ledu. Nejcennější tvrzení jsou proto ta o SOUČTU přes akci
-- a o tom, že se po přecenění nerozejde kontrolní součet.
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

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- Příprava: komerční akce na DVOU drahách, 4 hodiny
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _sub uuid; _d1 uuid; _d2 uuid;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name = 'Demo Firma s.r.o.';
  SELECT id INTO _d1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _d2 FROM public.sheets WHERE active AND id <> _d1 ORDER BY name LIMIT 1;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST akce na dvou drahách', 'commercial',
          '2027-04-07 16:00+02', '2027-04-07 20:00+02',
          '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _ev;

  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES (_d1, _sub, _ev, '2027-04-07 16:00+02', '2027-04-07 20:00+02'),
         (_d2, _sub, _ev, '2027-04-07 16:00+02', '2027-04-07 20:00+02');

  INSERT INTO _s VALUES ('ev', _ev::text);

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations WHERE event_id = _ev) = 2,
    'příprava: akce má dvě rezervace (dvě dráhy)');
  PERFORM pg_temp.tvrd(
    (SELECT count(DISTINCT hours) FROM public.reservations WHERE event_id = _ev) = 1
    AND (SELECT max(hours) FROM public.reservations WHERE event_id = _ev) = 4,
    '… obě na 4 hodiny');
END $$;

-- -----------------------------------------------------------------------------
-- 1) VÝCHOZÍ CENA = dráhy × hodiny × sazba
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _celkem numeric;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  SELECT sum(amount) INTO _celkem FROM public.reservations WHERE event_id = _ev;
  PERFORM pg_temp.tvrd(_celkem = 40000,
    'celková cena akce = 2 dráhy × 4 h × 5 000 = 40 000 Kč');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: přecenění platí na CELOU akci
--
-- Tohle je ten bug. Dřív se sazba změnila jen na jedné dráze.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';

  PERFORM public.uprav_sazbu_akce(_ev, 3750);

  SELECT count(DISTINCT rate_per_hour) AS ruznych, sum(amount) AS celkem
    INTO _r FROM public.reservations WHERE event_id = _ev;

  PERFORM pg_temp.tvrd(_r.ruznych = 1,
    'po přecenění mají VŠECHNY dráhy stejnou sazbu (jádro BUGu 1)');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations WHERE event_id = _ev AND rate_per_hour = 3750) = 2,
    '… konkrétně tu novou');
  PERFORM pg_temp.tvrd(_r.celkem = 30000,
    'celková cena akce je 2 × 4 × 3 750 = 30 000 Kč');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Návratová hodnota popisuje AKCI, ne rezervaci
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _v jsonb;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  _v := public.uprav_sazbu_akce(_ev, 5000);
  PERFORM pg_temp.tvrd((_v ->> 'rezervaci')::int = 2, 'RPC hlásí, kolik rezervací přecenilo');
  PERFORM pg_temp.tvrd((_v ->> 'drah')::int = 2,      '… kolik je drah');
  PERFORM pg_temp.tvrd((_v ->> 'hodin')::numeric = 4, '… kolik hodin');
  PERFORM pg_temp.tvrd((_v ->> 'celkem')::numeric = 40000, '… a celkovou cenu akce');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Zábradlí: celé koruny, strop, nesmysly
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';

  -- 10 000 Kč za 4 h na 2 dráhy by dalo 1 250 Kč/h — to vyjde.
  -- Ale 10 000 za 3 h na 1 dráhu by dalo 3 333,33 a to projít NESMÍ.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, 3333.33)', _ev),
    'celých korunách', 'sazba s haléři neprojde (drží invariant amount = hodiny × sazba)');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, 50001)', _ev),
    'nejvýš 50 000', 'sazba nad stropem neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, -100)', _ev),
    'nezáporné', 'záporná sazba neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, 1000)', gen_random_uuid()),
    'nenalezena', 'neexistující akce skončí chybou, ne tichým nic');
END $$;

-- -----------------------------------------------------------------------------
-- 5) KONTROLNÍ SOUČET se přecením nerozejde
--
-- Povinná kontrola u čehokoli kolem peněz (CLAUDE.md, Etapa 2).
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _rozdil numeric; _dluh numeric; _soucet numeric;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  PERFORM public.uprav_sazbu_akce(_ev, 4000);

  SELECT sum(COALESCE(corrected_amount, amount)) INTO _soucet
    FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL;
  SELECT sum(dluh) INTO _dluh
    FROM public.reservations_billing WHERE id IN
      (SELECT id FROM public.reservations WHERE event_id = _ev AND deleted_at IS NULL);

  PERFORM pg_temp.tvrd(_soucet = 32000, 'po přecenění na 4 000 je součet 2 × 4 × 4 000 = 32 000');

  -- Komerční subjekt je bez DPH v `amount`, `dluh` je s DPH — poměr musí sedět
  -- přesně, jinak se rozešel doklad s „Kdo kolik dluží".
  PERFORM pg_temp.tvrd(round(_soucet * 1.12, 2) = round(_dluh, 2),
    format('… a dluh je přesně o DPH vyšší (%s → %s)', _soucet, _dluh));

  SELECT sum(rozdil) INTO _rozdil FROM public.billing_reconcile('2027-04-01','2027-04-30');
  PERFORM pg_temp.tvrd(COALESCE(_rozdil, 0) = 0,
    'billing_reconcile hlásí rozdíl 0 (doklady vs. „Kdo kolik dluží")');
END $$;

-- -----------------------------------------------------------------------------
-- 6) Přecenit smí JEN ADMIN
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'kontrola práv běží jako authenticated, ne jako postgres');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, 1000)', _ev),
    'jen správce haly', 'zástupce klubu cenu komerční akce nepřecení');

  EXECUTE 'RESET ROLE';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
