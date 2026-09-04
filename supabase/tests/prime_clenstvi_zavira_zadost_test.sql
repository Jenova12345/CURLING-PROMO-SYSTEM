-- =============================================================================
-- TESTY: přímé přidání do klubu uzavírá čekající žádost (Jakubův nález 4. 9. 2026)
-- =============================================================================
-- Spuštění (replika produkce, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/prime_clenstvi_zavira_zadost_test.sql
--
-- CO SE TU HLÍDÁ NEJVÍC:
--
-- 1) ŽE TO PLATÍ POD REÁLNÝMI PRÁVY. Vkládá se pod rolí `authenticated` jako
--    admin, ne jako `postgres`. Jako `postgres` by se `UPDATE` uvnitř triggeru
--    povedl i BEZ `SECURITY DEFINER` (superuser obchází RLS), takže by test
--    tvrdil zavřeno o dveřích, vedle kterých je otevřené okno — a přesně tenhle
--    vzorec už v tomhle repu dvakrát propustil blokér (CLAUDE.md, bod 3).
--    `subject_requests` nemá ANI JEDNU zápisovou politiku, takže bez defineru
--    `UPDATE` tiše změní nula řádků a brána vypadá nasazená.
--
-- 2) ŽE SE NEZAVŘELO TAKY VŠECHNO OSTATNÍ. Scénář 2: žádost o JINÝ klub musí
--    zůstat čekat. Bez toho by šlo „opravit" bug tím, že členství kdekoli
--    smete celou frontu.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Pojistka: tenhle soubor ZAPISUJE.
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

-- ---- FIXTURY --------------------------------------------------------------
-- Reálná data z produkce: dva lidé s čekající žádostí o Mladé Kameny, kteří
-- členy nejsou nikde.
--   DANIEL  f76424ad  žádá o KLUB_A
--   JAKUB_B 9585a60d  žádá o KLUB_A
--   KLUB_A  a75e5dc0  Mladé Kameny
--   KLUB_B  f6cf7af1  Curling Ostrava
--   ADMIN   ad69770f
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_requests
      WHERE user_id IN ('f76424ad-3a05-43d3-8c34-5310187f59fd',
                        '9585a60d-f120-4759-9653-c441c31fea8d')
        AND status='ceka') = 2,
    'FIXTURA: oba žadatelé mají čekající žádost');
END $$;

-- ---- 1) TÁŽ DVOJICE: členství žádost uzavře -------------------------------
DO $$
DECLARE _stav text;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5","role":"authenticated"}', true);

  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES ('a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          'f76424ad-3a05-43d3-8c34-5310187f59fd', 'member',
          'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5');

  PERFORM set_config('role','none',true);
  SELECT status::text INTO _stav FROM public.subject_requests
   WHERE user_id='f76424ad-3a05-43d3-8c34-5310187f59fd';
  PERFORM pg_temp.tvrd(_stav='schvalena',
    '1) přímé členství uzavřelo žádost o tentýž klub (stav='||_stav||')');
END $$;

-- Podpis nese ten, kdo členství založil.
SELECT pg_temp.tvrd(
  (SELECT decided_by::text FROM public.subject_requests
    WHERE user_id='f76424ad-3a05-43d3-8c34-5310187f59fd')
  = 'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5',
  '1b) uzavření je podepsané tomu, kdo členství přidal');

-- Žádný vymyšlený důvod: trigger vystřelí i uvnitř `approve_subject_request`
-- a text „přidal správce přímo" by tam byl nepravdivý.
SELECT pg_temp.tvrd(
  (SELECT decision_reason FROM public.subject_requests
    WHERE user_id='f76424ad-3a05-43d3-8c34-5310187f59fd') IS NULL,
  '1c) trigger nedopisuje decision_reason');

-- ---- 2) JINÝ KLUB: žádost musí zůstat čekat -------------------------------
DO $$
DECLARE _stav text;
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5","role":"authenticated"}', true);

  -- Žádá o Mladé Kameny, přidáváme ho do Curling Ostrava.
  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES ('f6cf7af1-6cee-468d-b0fb-2847597e4b89',
          '9585a60d-f120-4759-9653-c441c31fea8d', 'member',
          'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5');

  PERFORM set_config('role','none',true);
  SELECT status::text INTO _stav FROM public.subject_requests
   WHERE user_id='9585a60d-f120-4759-9653-c441c31fea8d';
  PERFORM pg_temp.tvrd(_stav='ceka',
    '2) žádost o JINÝ klub zůstala čekat (stav='||_stav||')');
END $$;

-- ---- 3) Vyřízená žádost se nepřerazítkuje ---------------------------------
-- POZOR NA `now()`: je to čas ZAČÁTKU TRANSAKCE, takže druhý zápis by v témže
-- testu vyrobil TOTOŽNÉ razítko jako první. Porovnávat `decided_at` před a po
-- proto NEMĚŘÍ NIC — změřeno mutací (odebrání filtru `status='ceka'` prošlo
-- zeleně). Razítko se tu proto nejdřív přepíše na zjevně cizí hodnotu a teprve
-- pak se kouká, jestli ho druhý průchod přepsal.
DO $$
DECLARE _kdy timestamptz; _kdo text;
BEGIN
  UPDATE public.subject_requests
     SET decided_at = '2020-01-01T00:00:00Z',
         decided_by = 'c68c9546-7430-4bad-b74c-d3ec3758acc5'
   WHERE user_id = 'f76424ad-3a05-43d3-8c34-5310187f59fd';

  -- Členství smaž a založ znovu → trigger vystřelí na už vyřízenou žádost.
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5","role":"authenticated"}', true);
  DELETE FROM public.subject_reps
   WHERE subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
     AND user_id='f76424ad-3a05-43d3-8c34-5310187f59fd';
  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES ('a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          'f76424ad-3a05-43d3-8c34-5310187f59fd', 'member',
          'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5');
  PERFORM set_config('role','none',true);

  SELECT decided_at, decided_by::text INTO _kdy, _kdo
    FROM public.subject_requests WHERE user_id='f76424ad-3a05-43d3-8c34-5310187f59fd';
  PERFORM pg_temp.tvrd(_kdy = '2020-01-01T00:00:00Z'::timestamptz,
    '3) už vyřízené žádosti se nepřepsalo datum rozhodnutí (mám '||_kdy::text||')');
  PERFORM pg_temp.tvrd(_kdo = 'c68c9546-7430-4bad-b74c-d3ec3758acc5',
    '3b) ani podpis toho, kdo o ní rozhodl');
END $$;

-- ---- 4) Řádná cesta přes RPC dál funguje ----------------------------------
-- `approve_subject_request` do `subject_reps` taky vkládá, takže trigger
-- vystřelí i tam. Nesmí se tím nic rozbít ani přepsat.
DO $$
DECLARE _msg text; _stav text; _duvod text;
BEGIN
  -- nová čekající žádost (Jakubova z KLUB_A pořád čeká — schválíme ji řádně)
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    '{"sub":"ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5","role":"authenticated"}', true);
  BEGIN
    PERFORM public.approve_subject_request(
      (SELECT id FROM public.subject_requests
        WHERE user_id='9585a60d-f120-4759-9653-c441c31fea8d' AND status='ceka'),
      'member');
    _msg := NULL;
  EXCEPTION WHEN OTHERS THEN _msg := SQLERRM;
  END;
  PERFORM set_config('role','none',true);

  SELECT status::text, decision_reason INTO _stav, _duvod
    FROM public.subject_requests WHERE user_id='9585a60d-f120-4759-9653-c441c31fea8d';
  PERFORM pg_temp.tvrd(_msg IS NULL,
    '4) approve_subject_request dál projde (dostal jsem: '||coalesce(_msg,'bez chyby')||')');
  PERFORM pg_temp.tvrd(_stav='schvalena', '4b) žádost je po schválení uzavřená');
  PERFORM pg_temp.tvrd(_duvod IS NULL, '4c) schválení nezůstalo s cizím důvodem');
END $$;

DO $$ BEGIN RAISE NOTICE 'VŠECHNY TESTY PROŠLY'; END $$;
ROLLBACK;
