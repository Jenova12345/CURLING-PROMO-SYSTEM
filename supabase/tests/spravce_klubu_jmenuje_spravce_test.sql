-- =============================================================================
-- TESTY: správce klubu jmenuje správce — ve svém klubu, a nikde jinde
-- =============================================================================
-- Spuštění (replika produkce, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/spravce_klubu_jmenuje_spravce_test.sql
--
-- CO SE HLÍDÁ NEJVÍC: že se povolením NEROZŠÍŘILO nic dalšího. Nové právo je
-- úzké („smím jmenovat správce ve SVÉM klubu"), a testy proto měří hlavně to,
-- co má dál padat: cizí klub, řadový člen, uzavřený účet, degradace.
--
-- Běží pod rolí `authenticated`. Jako `postgres` projde všechno (obchází granty
-- i RLS) a test by netvrdil nic — CLAUDE.md, bod 3.
--
-- Lidé z produkce:
--   30e86078 Daniel Basista   level='rep'    u Mladých Kamenů (a75e5dc0), NENÍ admin
--   494ca54e Petr Jiran       level='rep'    u Mladých Kamenů, NENÍ admin
--   e87fdf16 Jana Jiranová    level='member' u Mladých Kamenů, NENÍ admin
--   8d94ecb6 Markéta Halfarová level='member' u Mladých Kamenů, NENÍ admin
--   59d5de4c Český svaz Curlingu — klub, kde Daniel zástupce NENÍ
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

CREATE OR REPLACE FUNCTION pg_temp.jako(_kdo uuid) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub',_kdo,'role','authenticated')::text, true);
END $$;

-- ---- 1) Správce klubu schválí nového člověka rovnou jako SPRÁVCE -----------
DO $$
DECLARE _m text; _zid uuid; _uroven text;
BEGIN
  SELECT id INTO _zid FROM public.subject_requests
   WHERE user_id='f76424ad-3a05-43d3-8c34-5310187f59fd' AND status='ceka';
  PERFORM pg_temp.jako('30e86078-5435-445b-9a87-5f0c691c388f');
  _m := pg_temp.chyba_z(format('SELECT public.approve_subject_request(%L,%L)', _zid, 'rep'));
  PERFORM set_config('role','none',true);

  PERFORM pg_temp.tvrd(_m IS NULL,
    '1) správce klubu schválil nového SPRÁVCE svého klubu (dostal jsem: '||coalesce(_m,'bez chyby')||')');
  SELECT level::text INTO _uroven FROM public.subject_reps
   WHERE subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
     AND user_id='f76424ad-3a05-43d3-8c34-5310187f59fd';
  PERFORM pg_temp.tvrd(_uroven='rep', '1b) a opravdu má úroveň rep (mám '||coalesce(_uroven,'nic')||')');
END $$;

-- ---- 2) Do CIZÍHO klubu ne -------------------------------------------------
DO $$
DECLARE _m text; _zid uuid;
BEGIN
  UPDATE public.subject_requests SET subject_id='59d5de4c-4249-4449-b736-fbc2e3064058'
   WHERE user_id='9585a60d-f120-4759-9653-c441c31fea8d' AND status='ceka'
   RETURNING id INTO _zid;
  PERFORM pg_temp.jako('30e86078-5435-445b-9a87-5f0c691c388f');
  _m := pg_temp.chyba_z(format('SELECT public.approve_subject_request(%L,%L)', _zid, 'rep'));
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m LIKE '%jen jako jeho zástupce nebo správce haly%',
    '2) do cizího klubu správce nejmenuje (dostal jsem: '||coalesce(_m,'PROŠLO — DÍRA!')||')');
END $$;

-- ---- 3) Řadový člen nejmenuje nikoho ---------------------------------------
DO $$
DECLARE _m text; _zid uuid;
BEGIN
  UPDATE public.subject_requests SET subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
   WHERE user_id='9585a60d-f120-4759-9653-c441c31fea8d' AND status='ceka'
   RETURNING id INTO _zid;
  PERFORM pg_temp.jako('e87fdf16-289e-4e24-9e53-4b05fb97e330');   -- level='member'
  _m := pg_temp.chyba_z(format('SELECT public.approve_subject_request(%L,%L)', _zid, 'rep'));
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m LIKE '%vyřizuje správce haly nebo zástupce klubu%',
    '3) řadový člen žádosti nevyřizuje (dostal jsem: '||coalesce(_m,'PROŠLO — DÍRA!')||')');
END $$;

-- ---- 4) Povýšení stávajícího člena ve svém klubu ---------------------------
DO $$
DECLARE _m text; _uroven text;
BEGIN
  PERFORM pg_temp.jako('30e86078-5435-445b-9a87-5f0c691c388f');
  _m := pg_temp.chyba_z($q$SELECT public.jmenuj_spravce_klubu(
          'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          'e87fdf16-289e-4e24-9e53-4b05fb97e330')$q$);
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m IS NULL,
    '4) správce klubu povýšil člena na správce (dostal jsem: '||coalesce(_m,'bez chyby')||')');
  SELECT level::text INTO _uroven FROM public.subject_reps
   WHERE subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
     AND user_id='e87fdf16-289e-4e24-9e53-4b05fb97e330';
  PERFORM pg_temp.tvrd(_uroven='rep', '4b) a v tabulce je rep (mám '||coalesce(_uroven,'nic')||')');
END $$;

-- ---- 5) Povýšit v CIZÍM klubu ne -------------------------------------------
-- Cíl musí být v tom cizím klubu SKUTEČNÝ ČLEN, jinak by se test opřel
-- o hlášku „není členem klubu" a prošel by i s odstraněnou bránou — změřeno
-- mutací p2, která takhle zčervenala ze špatného důvodu.
DO $$
DECLARE _m text; _uroven text;
BEGIN
  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES ('59d5de4c-4249-4449-b736-fbc2e3064058',
          '8d94ecb6-5b87-4264-a773-27d1c2273037', 'member',
          'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5');

  -- Petr Jiran je rep Mladých Kamenů, u Českého svazu není nic.
  PERFORM pg_temp.jako('494ca54e-b9b5-444b-9d08-2a637c58eda3');
  _m := pg_temp.chyba_z($q$SELECT public.jmenuj_spravce_klubu(
          '59d5de4c-4249-4449-b736-fbc2e3064058',
          '8d94ecb6-5b87-4264-a773-27d1c2273037')$q$);
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m LIKE '%jen jeho stávající správce nebo správce haly%',
    '5) v cizím klubu nejmenuje, i když tam ten člověk členem JE (dostal jsem: '
    ||coalesce(_m,'PROŠLO — DÍRA!')||')');
  SELECT level::text INTO _uroven FROM public.subject_reps
   WHERE subject_id='59d5de4c-4249-4449-b736-fbc2e3064058'
     AND user_id='8d94ecb6-5b87-4264-a773-27d1c2273037';
  PERFORM pg_temp.tvrd(_uroven='member', '5b) a zůstal v cizím klubu řadovým členem');
END $$;

-- ---- 6) Řadový člen nepovyšuje ---------------------------------------------
DO $$
DECLARE _m text;
BEGIN
  PERFORM pg_temp.jako('8d94ecb6-5b87-4264-a773-27d1c2273037');   -- level='member'
  _m := pg_temp.chyba_z($q$SELECT public.jmenuj_spravce_klubu(
          'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          '8d94ecb6-5b87-4264-a773-27d1c2273037')$q$);
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m LIKE '%jen jeho stávající správce nebo správce haly%',
    '6) řadový člen se sám správcem neudělá (dostal jsem: '||coalesce(_m,'PROŠLO — DÍRA!')||')');
END $$;

-- ---- 7) Uzavřený účet se tím neotevře --------------------------------------
DO $$
DECLARE _m text; _uroven text;
BEGIN
  UPDATE public.profiles SET stav='deaktivovan'
   WHERE user_id='8d94ecb6-5b87-4264-a773-27d1c2273037';
  PERFORM pg_temp.jako('30e86078-5435-445b-9a87-5f0c691c388f');
  _m := pg_temp.chyba_z($q$SELECT public.jmenuj_spravce_klubu(
          'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          '8d94ecb6-5b87-4264-a773-27d1c2273037')$q$);
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m LIKE '%Účet je uzavřený%',
    '7) zavřený účet se správcem klubu nestane (dostal jsem: '||coalesce(_m,'PROŠLO — DÍRA!')||')');
  SELECT level::text INTO _uroven FROM public.subject_reps
   WHERE subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
     AND user_id='8d94ecb6-5b87-4264-a773-27d1c2273037';
  PERFORM pg_temp.tvrd(_uroven='member', '7b) a zůstal řadovým členem');
END $$;

-- ---- 8) Degradovat tím nejde -----------------------------------------------
-- `WHERE level='member'` znamená, že na správce funkce nesáhne. Kdyby ten filtr
-- zmizel, dala by se používat i na cizí správce — a „odeber správce" je nástroj,
-- kterým se dá klub převzít.
DO $$
DECLARE _m text; _uroven text;
BEGIN
  PERFORM pg_temp.jako('30e86078-5435-445b-9a87-5f0c691c388f');
  _m := pg_temp.chyba_z($q$SELECT public.jmenuj_spravce_klubu(
          'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          '494ca54e-b9b5-444b-9d08-2a637c58eda3')$q$);   -- Petr už je rep
  PERFORM set_config('role','none',true);
  PERFORM pg_temp.tvrd(_m LIKE '%není členem klubu%',
    '8) na stávajícího správce funkce nesáhne (dostal jsem: '||coalesce(_m,'PROŠLO')||')');
  SELECT level::text INTO _uroven FROM public.subject_reps
   WHERE subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
     AND user_id='494ca54e-b9b5-444b-9d08-2a637c58eda3';
  PERFORM pg_temp.tvrd(_uroven='rep', '8b) a zůstal správcem');
END $$;

-- ---- 10) Schválením se stávající správce nedegraduje ------------------------
-- `ON CONFLICT DO UPDATE SET level = EXCLUDED.level` uměl sundat správce, když
-- měl někde zaseklou žádost ve stavu `ceka`. Do migrace 20260904160000 to zvládl
-- jen admin; s ní by to zvládl každý správce klubu — a „sundej ostatní správce"
-- je nástroj na převzetí klubu. Nález bezpečnostní brány.
DO $$
DECLARE _m text; _uroven text; _zid uuid;
BEGIN
  -- Petr Jiran (494ca54e) je rep Mladých Kamenů. Vyrobíme mu zaseklou žádost.
  DELETE FROM public.subject_requests WHERE user_id='494ca54e-b9b5-444b-9d08-2a637c58eda3';
  INSERT INTO public.subject_requests (user_id, subject_id, status)
  VALUES ('494ca54e-b9b5-444b-9d08-2a637c58eda3',
          'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11', 'ceka')
  RETURNING id INTO _zid;

  PERFORM pg_temp.jako('30e86078-5435-445b-9a87-5f0c691c388f');   -- jiný správce téhož klubu
  _m := pg_temp.chyba_z(format('SELECT public.approve_subject_request(%L,%L)', _zid, 'member'));
  PERFORM set_config('role','none',true);

  SELECT level::text INTO _uroven FROM public.subject_reps
   WHERE subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
     AND user_id='494ca54e-b9b5-444b-9d08-2a637c58eda3';
  PERFORM pg_temp.tvrd(_uroven='rep',
    '10) schválení na "member" stávajícího správce NEDEGRADOVALO (mám '||coalesce(_uroven,'nic')||')');
END $$;

-- ---- 10b) …ale POVÝŠIT přes frontu pořád jde ---------------------------------
-- Druhá větev toho `CASE` v `ON CONFLICT`. Bez tohohle tvrzení by sada
-- nepoznala, kdyby se `CASE` napsal obráceně: test 1 měří INSERT bez konfliktu
-- a test 10 jen `rep` + `'member'`. Nález bezpečnostní brány.
DO $$
DECLARE _m text; _uroven text; _zid uuid;
BEGIN
  -- Fixtura: člověk, který v klubu UŽ JE členem, a má čekající žádost.
  DELETE FROM public.subject_requests WHERE user_id='9585a60d-f120-4759-9653-c441c31fea8d';
  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES ('a75e5dc0-e4e7-4bf7-9c88-75e25b808d11',
          '9585a60d-f120-4759-9653-c441c31fea8d', 'member',
          'ad69770f-c4e1-401c-bb11-e1ff3ca1c8c5')
  ON CONFLICT (subject_id, user_id) DO UPDATE SET level = 'member';
  INSERT INTO public.subject_requests (user_id, subject_id, status)
  VALUES ('9585a60d-f120-4759-9653-c441c31fea8d',
          'a75e5dc0-e4e7-4bf7-9c88-75e25b808d11', 'ceka')
  RETURNING id INTO _zid;

  PERFORM pg_temp.jako('30e86078-5435-445b-9a87-5f0c691c388f');
  _m := pg_temp.chyba_z(format('SELECT public.approve_subject_request(%L,%L)', _zid, 'rep'));
  PERFORM set_config('role','none',true);

  SELECT level::text INTO _uroven FROM public.subject_reps
   WHERE subject_id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11'
     AND user_id='9585a60d-f120-4759-9653-c441c31fea8d';
  PERFORM pg_temp.tvrd(_m IS NULL,
    '10b) schválení stávajícího ČLENA na "rep" prošlo (dostal jsem: '||coalesce(_m,'bez chyby')||')');
  PERFORM pg_temp.tvrd(_uroven='rep',
    '10c) a povýšení se opravdu propsalo (mám '||coalesce(_uroven,'nic')||')');
END $$;

-- ---- 9) Na peníze to nesahá -------------------------------------------------
-- POZOR: tohle je STRÁŽCE, ne měření. Sazba toho klubu je na produkci NULL
-- a nikdo ji nezapisuje, takže tvrzení projde i s rozbitou opravou. Smysl má
-- v den, kdy někdo do některé z cest přidá zápis do `subjects` — mezi měřená
-- tvrzení se ale počítat nemá. (Nález bezpečnostní brány.)
-- Nové právo je o lidech, ne o cenách. Kdyby některá z cest sáhla na sazbu
-- klubu, byl by z „jmenuj správce" nástroj na slevu.
SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.subjects
    WHERE id='a75e5dc0-e4e7-4bf7-9c88-75e25b808d11' AND default_rate IS NULL) = 1,
  '9) sazba klubu je po všech jmenováních pořád nedotčená');

DO $$ BEGIN RAISE NOTICE 'VŠECHNY TESTY PROŠLY'; END $$;
ROLLBACK;
