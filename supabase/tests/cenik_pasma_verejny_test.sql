-- =============================================================================
-- TESTY: `cenik_pasma_public` — standardní ceník všem, cizí ceny nikomu
-- =============================================================================
-- Spuštění (replika produkce v lokálním Postgresu, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/cenik_pasma_verejny_test.sql
--
-- CO TENHLE TEST HLÍDÁ NEJVÍC:
--
-- 1) ŽE SE OTEVŘEL JEN CENÍK, NE CELÁ TABULKA. Scénář 2: řadový člen přes
--    pohled ceník VIDÍ, ale přímo z `cenik_pasma` dostane NULA řádků a zapsat
--    do ní nesmí. Bez toho by šlo „splnit zadání" uvolněním RLS na tabulce
--    a nikdo by nepoznal rozdíl — dokud by někdo ceník nepřepsal.
--
-- 2) ŽE SE NEPROPUSTILO NIC Z A2b. Scénář 4: komerční sazba, klubová výchozí
--    sazba, `training_rate`, `tournament_rate` a `subjects.default_rate`
--    musí řadovému členovi dál chodit jako NULL (nebo nedostupné). Tohle je ta
--    hranice, kterou rozhodnutí ze 14. 9. 2026 VÝSLOVNĚ nechalo zavřenou —
--    kdyby ji někdo příště posunul, má to spadnout tady.
--
-- 3) ŽE SE NEVYDÁVÁ HISTORIE. Scénář 3: smazaná pásma (`deleted_at`) se
--    v pohledu neobjeví. Na produkci k 14. 9. 2026 jsou čtyři a nesou STARÉ
--    ceny (800 / 1000 / 1200) — kdyby prosákly, členovi by se ceník zdvojil
--    a nepoznal by, která cena platí.
--
-- 4) ŽE SE NEOTEVŘELO NEPŘIHLÁŠENÝM ani neaktivním účtům (scénáře 1c, 5).
--
-- Testy práv běží pod rolí `authenticated`. Jako `postgres` projde všechno —
-- obchází granty i RLS (CLAUDE.md, bod 3).
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Pojistka: tenhle soubor ZAPISUJE. Na produkci nesmí nikdy.
DO $$
BEGIN
  IF current_database() <> 'curling_test' THEN
    RAISE EXCEPTION 'ODMÍTNUTO: test patří jen do repliky curling_test, běží nad "%".',
      current_database();
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE '  OK  %', _popis;
END $$;

-- Spustí SELECT pod daným uživatelem v roli `authenticated` a vrátí počet řádků.
CREATE OR REPLACE FUNCTION pg_temp.pocet_jako(_sql text, _uziv uuid) RETURNS integer
 LANGUAGE plpgsql AS $$
DECLARE _n integer;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
  EXECUTE 'SELECT count(*) FROM (' || _sql || ') t' INTO _n;
  PERFORM set_config('role', 'none', true);
  RETURN _n;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('role', 'none', true);
  RAISE EXCEPTION 'Dotaz pod authenticated selhal: %', SQLERRM;
END $$;

-- Vrátí true, když příkaz pod daným uživatelem NEPROŠEL.
--
-- Uznává se jen očekávaný důvod. „Spadlo to = brána drží" by prohlásilo za
-- funkční i chybějící grant nebo překlep v SQL — a negativní testy by byly
-- zeleně rozbité.
CREATE OR REPLACE FUNCTION pg_temp.odmitnuto(_sql text, _uziv uuid) RETURNS boolean
 LANGUAGE plpgsql AS $$
DECLARE _n integer;
BEGIN
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
    EXECUTE _sql;
    GET DIAGNOSTICS _n = ROW_COUNT;
    PERFORM set_config('role', 'none', true);
    RETURN _n = 0;          -- RLS umí odmítnout i TIŠE (porušené USING)
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('role', 'none', true);
    IF SQLERRM LIKE '%violates row-level security policy%'
       OR SQLERRM LIKE '%porušuje zásadu zabezpečení na úrovni řádků%'
       OR SQLERRM LIKE '%permission denied%'
       OR SQLERRM LIKE '%právo bylo odepřeno%' THEN
      RETURN true;
    END IF;
    RAISE EXCEPTION 'Příkaz selhal z JINÉHO důvodu než kvůli bráně: %', SQLERRM;
  END;
END $$;

-- ---------------------------------------------------------------------------
-- FIXTURY
-- ---------------------------------------------------------------------------
-- Jedno smazané pásmo navíc, ať scénář 3 měří i na replice bez historie.
INSERT INTO public.cenik_pasma (id, den_typ, od_hodina, do_hodina, sazba, popis, deleted_at)
VALUES ('00000000-0000-0000-0000-00000000c0f1', 'vsedni', 22, 23, 4242, 'TEST smazane pasmo', now());

SELECT pg_temp.tvrd(
  NOT public.has_role('30e86078-5435-445b-9a87-5f0c691c388f', 'admin')
  AND public.ucet_aktivni('30e86078-5435-445b-9a87-5f0c691c388f'),
  'FIXTURA: testovací účet je aktivní a NENÍ admin');
SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.cenik_pasma WHERE deleted_at IS NULL) > 0,
  'FIXTURA: v ceníku je aspoň jedno platné pásmo');

-- ---------------------------------------------------------------------------
-- 1) Ceník vidí řadový člen
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.cenik_pasma_public
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f')
  = (SELECT count(*)::int FROM public.cenik_pasma WHERE deleted_at IS NULL),
  '1a) řadový člen vidí VŠECHNA platná pásma (tolik, kolik jich je)');

SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.cenik_pasma_public WHERE sazba IS NULL
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '1b) sazby nechodí maskované na NULL — ceník bez cen by byl k ničemu');

SELECT pg_temp.tvrd(
  NOT has_table_privilege('anon', 'public.cenik_pasma_public', 'SELECT'),
  '1c) anon (nepřihlášený) na pohled NEMÁ právo');

-- ---------------------------------------------------------------------------
-- 2) Otevřel se POHLED, ne tabulka
-- ---------------------------------------------------------------------------
-- Tohle je jádro změny: zveřejňuje se ceník ke čtení, ne správa ceníku.
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.cenik_pasma
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '2a) přímo z tabulky cenik_pasma řadový člen dostane NULA řádků (RLS drží)');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  INSERT INTO public.cenik_pasma (den_typ, od_hodina, do_hodina, sazba, popis)
  VALUES ('vsedni', 3, 4, 1, 'UTOK')
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '2b) řadový člen do ceníku ZAPSAT nesmí');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  UPDATE public.cenik_pasma SET sazba = 1 WHERE deleted_at IS NULL
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '2c) řadový člen ceník PŘEPSAT nesmí');

-- ---------------------------------------------------------------------------
-- 3) Smazaná pásma se nevydávají (jinak by se ceník zdvojil starými cenami)
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.cenik_pasma_public WHERE id = '00000000-0000-0000-0000-00000000c0f1'
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '3) smazané pásmo se v pohledu NEOBJEVÍ');

-- ---------------------------------------------------------------------------
-- 4) A2b DRŽÍ — cizí a individuální ceny zůstávají adminovi
-- ---------------------------------------------------------------------------
-- Rozhodnutí ze 14. 9. 2026 zveřejnilo VÝHRADNĚ pásmový ceník. Kdyby někdo
-- příště tuhle hranici posunul, má to spadnout tady, ne až u klienta.
SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.settings_public
   WHERE commercial_default_rate IS NOT NULL
      OR club_default_rate IS NOT NULL
      OR training_rate IS NOT NULL
      OR tournament_rate IS NOT NULL
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '4a) komerční ani klubová výchozí sazba se řadovému členovi NEVYDÁVÁ');

SELECT pg_temp.tvrd(pg_temp.pocet_jako($sql$
  SELECT 1 FROM public.settings_public WHERE can_see_rates
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f') = 0,
  '4b) can_see_rates zůstává pro řadového člena false');

SELECT pg_temp.tvrd(pg_temp.odmitnuto($sql$
  SELECT default_rate FROM public.subjects
$sql$, '30e86078-5435-445b-9a87-5f0c691c388f'),
  '4c) individuální sazba klubu (subjects.default_rate) zůstává nedostupná');

-- ---------------------------------------------------------------------------
-- 5) Účet, který ještě nikdo nepustil dovnitř, ceník nedostane
-- ---------------------------------------------------------------------------
-- Default-deny z bloku C. Měří se přes `ucet_aktivni()` vypnutý pro testovací
-- účet, ne odhadem — kdyby pohled na aktivitu účtu nekoukal, projde to tady.
DO $$
DECLARE _puvodni text;
BEGIN
  SELECT stav::text INTO _puvodni FROM public.profiles
   WHERE user_id = '30e86078-5435-445b-9a87-5f0c691c388f';
  UPDATE public.profiles SET stav = 'ceka'
   WHERE user_id = '30e86078-5435-445b-9a87-5f0c691c388f';

  IF pg_temp.pocet_jako($sql$SELECT 1 FROM public.cenik_pasma_public$sql$,
                        '30e86078-5435-445b-9a87-5f0c691c388f') <> 0 THEN
    RAISE EXCEPTION 'TEST SELHAL: 5) neaktivní účet ceník DOSTAL';
  END IF;
  RAISE NOTICE '  OK  5) neaktivní (neschválený) účet ceník NEDOSTANE';

  EXECUTE format('UPDATE public.profiles SET stav = %L WHERE user_id = %L',
                 _puvodni, '30e86078-5435-445b-9a87-5f0c691c388f');
END $$;

ROLLBACK;
