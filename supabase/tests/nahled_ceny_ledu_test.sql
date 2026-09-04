-- =============================================================================
-- TESTY: cena ledu je vidět před potvrzením a je to TÁŽ cena, jaká se zapíše
-- =============================================================================
-- Spuštění (replika produkce, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/nahled_ceny_ledu_test.sql
--
-- CO SE HLÍDÁ NEJVÍC:
--
-- 1) JEDNA PRAVDA O CENĚ (scénář 4). Náhled se porovnává s tím, co doopravdy
--    zapíše `set_reservation_pricing` při INSERTu. Test, který jen ověří, že
--    náhled vrátí „nějaké číslo", by prošel i s rozejitou cenou — a rozdíl mezi
--    zobrazenou a fakturovanou částkou je to nejhorší, co peněžní vrstva umí.
--
-- 2) ŽE CENA NENÍ VEŘEJNÁ (scénář 3). `subjects.default_rate` je individuálně
--    dohodnutá cena. Běží pod rolí `authenticated`, ne jako `postgres`.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF current_database() <> 'curling_test' THEN
    RAISE EXCEPTION 'ODMÍTNUTO: test patří jen do repliky curling_test, běží nad "%".',
      current_database();
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_p boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_p,false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE '  OK   %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chyba_z(_sql text) RETURNS text
 LANGUAGE plpgsql AS $$
BEGIN EXECUTE _sql; RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $$;

-- Fixní termín: středa 3. 3. 2027, 16–18 h pražského času.
-- Pásma (dnešní ceník): všední 14–17 = 1000, 17–22 = 1200 → 2 200 Kč za dráhu.
DO $$
DECLARE _dow int;
BEGIN
  SELECT extract(isodow FROM timestamp '2027-03-03 16:00') INTO _dow;
  PERFORM pg_temp.tvrd(_dow < 6, 'FIXTURA: 3. 3. 2027 je všední den (isodow='||_dow||')');
END $$;

-- ---- 1) Člen klubu vidí pásmovou cenu -------------------------------------
DO $$
DECLARE _v jsonb;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"30e86078-5435-445b-9a87-5f0c691c388f","role":"authenticated"}', true);
  SELECT public.nahled_ceny_ledu(
    'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11', 'training',
    timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
    timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague', 1) INTO _v;
  PERFORM set_config('role','none',true);

  PERFORM pg_temp.tvrd(_v->>'zdroj' = 'pasma', '1) cena tréninku jde z pásem (zdroj='||(_v->>'zdroj')||')');
  PERFORM pg_temp.tvrd((_v->>'celkem')::numeric = 2200,
    '1b) 16–18 h ve všední den = 1000 + 1200 = 2200 Kč (mám '||(_v->>'celkem')||')');
  -- Klubový pásmový ceník je vedený VČETNĚ DPH — kdyby se to obrátilo, člověk
  -- by čekal fakturu o 21 % vyšší.
  PERFORM pg_temp.tvrd((_v->>'bez_dph')::boolean = false, '1c) pásmová cena je včetně DPH');
  PERFORM pg_temp.tvrd(_v->'rozpis' IS NOT NULL AND _v->>'rozpis' <> 'null',
    '1d) náhled nese i rozpis po sazbách');
END $$;

-- ---- 2) Dvě dráhy stojí dvakrát tolik --------------------------------------
DO $$
DECLARE _v jsonb;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"30e86078-5435-445b-9a87-5f0c691c388f","role":"authenticated"}', true);
  SELECT public.nahled_ceny_ledu(
    'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11', 'training',
    timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
    timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague', 2) INTO _v;
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd((_v->>'za_drahu')::numeric = 2200 AND (_v->>'celkem')::numeric = 4400,
    '2) dvě dráhy = 2× cena (za dráhu '||(_v->>'za_drahu')||', celkem '||(_v->>'celkem')||')');
END $$;

-- ---- 3) Cizí člověk cenu klubu nevidí --------------------------------------
DO $$
DECLARE _msg text;
BEGIN
  PERFORM set_config('role','authenticated',true);
  -- f76424ad není člen ani zástupce žádného klubu a není admin
  PERFORM set_config('request.jwt.claims',
    '{"sub":"f76424ad-3a05-43d3-8c34-5310187f59fd","role":"authenticated"}', true);
  _msg := pg_temp.chyba_z($q$
    SELECT public.nahled_ceny_ledu(
      'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11', 'training',
      timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
      timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague', 1)$q$);
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_msg LIKE '%vidí jen jeho členové%',
    '3) cizímu člověku se cena klubu neukáže (dostal jsem: '||coalesce(_msg,'PROŠLO!')||')');
END $$;

-- ---- 4) JEDNA PRAVDA: náhled == to, co se opravdu zapíše -------------------
DO $$
DECLARE _nahled numeric; _zapsano numeric; _id uuid;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"30e86078-5435-445b-9a87-5f0c691c388f","role":"authenticated"}', true);
  SELECT (public.nahled_ceny_ledu(
    'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11', 'training',
    timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
    timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague', 1)->>'za_drahu')::numeric
    INTO _nahled;
  PERFORM set_config('role','none',true);

  INSERT INTO public.reservations (sheet_id, start_at, end_at, subject_id, created_by)
  VALUES ('f0de2f0b-8086-465d-82bc-8bdcba15fb01',
          timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
          timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague',
          'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          '30e86078-5435-445b-9a87-5f0c691c388f')
  RETURNING id INTO _id;

  SELECT amount INTO _zapsano FROM public.reservations WHERE id = _id;
  PERFORM pg_temp.tvrd(_nahled = _zapsano,
    '4) náhled ('||_nahled||') se rovná zapsané ceně ('||_zapsano||') — jedna pravda');
END $$;

-- ---- 5) Komerční zákazník: jedna sazba, a BEZ DPH --------------------------
DO $$
DECLARE _v jsonb;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5","role":"authenticated"}', true);  -- admin
  SELECT public.nahled_ceny_ledu(
    '557631da-0f2c-4ed3-a1f1-df842b6f2129', 'commercial',
    timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
    timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague', 1) INTO _v;
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd((_v->>'sazba')::numeric = 5000,
    '5) komerční sazba 5000 Kč/h (mám '||(_v->>'sazba')||')');
  PERFORM pg_temp.tvrd((_v->>'celkem')::numeric = 10000, '5b) 2 h = 10 000 Kč');
  -- Komerční sazba je vedená BEZ DPH — kdyby se to obrátilo, na dokladu by
  -- chybělo 21 %.
  PERFORM pg_temp.tvrd((_v->>'bez_dph')::boolean = true, '5c) komerční cena je BEZ DPH');
END $$;

-- ---- 6) Komerční ceník je jen pro admina (nález brány T1) -------------------
-- `authenticated` nemá SELECT na `settings.commercial_default_rate` ani na
-- `subjects.default_rate`. Bez brány by si ho člen vytáhl přes náhled na
-- VLASTNÍ klub s typem akce `commercial` — pásma se přeskočí a vrátí se
-- komerční sazba. Změřeno, proto tenhle test.
DO $$
DECLARE _m text;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"30e86078-5435-445b-9a87-5f0c691c388f","role":"authenticated"}', true);  -- člen/rep klubu, NENÍ admin
  _m := pg_temp.chyba_z($q$
    SELECT public.nahled_ceny_ledu(
      'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11', 'commercial',
      timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
      timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague', 1)$q$);
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m LIKE '%komerční akce spočítá jen správce haly%',
    '6) člen si komerční sazbu přes typ akce nevytáhne (dostal jsem: '
    ||coalesce(_m,'PROŠLO — ÚNIK!')||')');
END $$;

-- A druhá cesta k témuž číslu: komerční SUBJEKT.
DO $$
DECLARE _m text;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"30e86078-5435-445b-9a87-5f0c691c388f","role":"authenticated"}', true);
  _m := pg_temp.chyba_z($q$
    SELECT public.nahled_ceny_ledu(
      '557631da-0f2c-4ed3-a1f1-df842b6f2129', 'training',
      timestamp '2027-03-03 16:00' AT TIME ZONE 'Europe/Prague',
      timestamp '2027-03-03 18:00' AT TIME ZONE 'Europe/Prague', 1)$q$);
  PERFORM set_config('role','none',true);
  -- Na komerční subjekt navíc nedosáhne ani členstvím — obě brány drží.
  PERFORM pg_temp.tvrd(_m IS NOT NULL,
    '6b) ani přes komerční subjekt (dostal jsem: '||coalesce(_m,'PROŠLO — ÚNIK!')||')');
END $$;

-- ---- 7) JEDNA PRAVDA i na větvi, kde DPH visí na TYPU AKCE (nález T2) -------
-- Scénář 4 zakládá rezervaci bez `event_id`, takže větev, kde `cena_je_bez_dph`
-- rozhoduje podle typu akce, jím neprojde. Tady se rezervace věší na skutečnou
-- komerční akci a porovnává se náhled se zapsanou částkou i s daňovým významem.
DO $$
DECLARE _nahled jsonb; _amount numeric; _bezdph boolean; _ev uuid; _rid uuid;
BEGIN
  INSERT INTO public.events (event_type, title, start_time, end_time)
  VALUES ('commercial', 'Test ceny',
          timestamp '2027-03-04 16:00' AT TIME ZONE 'Europe/Prague',
          timestamp '2027-03-04 18:00' AT TIME ZONE 'Europe/Prague')
  RETURNING id INTO _ev;

  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5","role":"authenticated"}', true);
  SELECT public.nahled_ceny_ledu(
    '557631da-0f2c-4ed3-a1f1-df842b6f2129', 'commercial',
    timestamp '2027-03-04 16:00' AT TIME ZONE 'Europe/Prague',
    timestamp '2027-03-04 18:00' AT TIME ZONE 'Europe/Prague', 1) INTO _nahled;
  PERFORM set_config('role','none',true);

  INSERT INTO public.reservations (sheet_id, start_at, end_at, subject_id, event_id, created_by)
  VALUES ('f0de2f0b-8086-465d-82bc-8bdcba15fb01',
          timestamp '2027-03-04 16:00' AT TIME ZONE 'Europe/Prague',
          timestamp '2027-03-04 18:00' AT TIME ZONE 'Europe/Prague',
          '557631da-0f2c-4ed3-a1f1-df842b6f2129', _ev,
          'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5')
  RETURNING id INTO _rid;

  SELECT amount, cena_bez_dph INTO _amount, _bezdph
    FROM public.reservations WHERE id = _rid;
  PERFORM pg_temp.tvrd((_nahled->>'za_drahu')::numeric = _amount,
    '7) i u komerční akce se náhled ('||(_nahled->>'za_drahu')||') rovná zapsané ceně ('||_amount||')');
  PERFORM pg_temp.tvrd((_nahled->>'bez_dph')::boolean = _bezdph,
    '7b) a shoduje se i daňový význam (náhled '||(_nahled->>'bez_dph')||', zápis '||_bezdph||')');
END $$;

DO $$ BEGIN RAISE NOTICE 'VŠECHNY TESTY PROŠLY'; END $$;
ROLLBACK;
