-- =============================================================================
-- TESTY: admin přidá člověka do klubu — i do DALŠÍHO klubu — a uloží se to
-- =============================================================================
-- Spuštění (replika produkce v lokálním Postgresu, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/pridani_do_klubu_test.sql
--
-- PROČ TENHLE SOUBOR VZNIKL: hlášení znělo „v sekci Subjekty nejde přidat
-- člověka do jiného klubu ani po kliknutí na Uložit". Bylo potřeba rozhodnout,
-- jestli to blokuje databáze (RLS, constraint, trigger), nebo frontend.
-- Tenhle test měří DATABÁZOVOU polovinu, a měří ji POD REÁLNÝM TOKENEM —
-- jako `postgres` by prošlo všechno, protože obchází granty i RLS (CLAUDE.md,
-- bod 3), a test by tvrdil zavřeno o dveřích, vedle kterých je otevřené okno.
--
-- VÝSLEDEK, KTERÝ TÍM BYL ZMĚŘEN: databáze to NEBLOKUJE. Příčina byla
-- v UI — tlačítko „Uložit" ukládalo jen název, sazbu a barvu, ale hlásilo
-- „Uloženo", zatímco člověka přidávalo bezejmenné ikonové tlačítko vedle
-- rozbalovátka, které po úspěchu nehlásilo nic. Tenhle test je proto REGRESNÍ
-- POJISTKA: kdyby někdo příště zúžil RLS nebo přidal constraint, který
-- členství ve dvou klubech zakáže, spadne to tady, a ne až u klienta.
--
-- ⚠️ KDYŽ TEST ZČERVENÁ, NEUKLIDÍ PO SOBĚ. Je to jeho jediná vážná vada a nejde
-- obejít: aby se dalo dokázat, že zápis PŘEŽIJE COMMIT, musí se doopravdy
-- commitovat — a `ON_ERROR_STOP` běh u prvního `RAISE` ukončí dřív, než se
-- dojde k úklidu. Zůstanou pak commitnuté řádky v `subject_reps`, a není to
-- inertní smetí: fixtura si „volné" kluby vybírá dotazem, takže PŘÍŠTÍ BĚH
-- tiše měří jinou dvojici. (Nález brány pro migrace; na replice se přesně tohle
-- už jednou stalo — zůstaly tam dva řádky z červeného běhu.)
--
-- PO ČERVENÉM BĚHU TEDY UKLIĎ RUČNĚ. Řádky, které test vyrobil, poznáš podle
-- toho, že je založil testovací admin pro testovaného člověka:
--     DELETE FROM public.subject_reps r
--      WHERE r.created_by = (SELECT ur.user_id FROM public.user_roles ur
--                             WHERE ur.role = 'admin' ORDER BY ur.user_id LIMIT 1)
--        AND r.user_id    = (SELECT ur.user_id FROM public.user_roles ur
--                             GROUP BY ur.user_id HAVING bool_and(ur.role <> 'admin')
--                             ORDER BY ur.user_id LIMIT 1)
--        AND r.created_at > now() - interval '1 hour';
-- Nebo prostě repliku postav znovu (`scripts/testovaci-replika.sh`) — je na
-- jedno použití a je to spolehlivější.
--
-- CO SE HLÍDÁ:
--   1) admin přidá člověka do klubu a řádek tam po COMMITU opravdu je
--   2) TÝŽ člověk jde přidat i do DALŠÍHO klubu (jádro hlášení)
--   3) obě úrovně — „Člen" i „Správce klubu"
--   4) `created_by` se vyplní samo z tokenu (auditní stopa)
--   5) řadový člen to NESMÍ (RLS drží)
--   6) dvakrát TÝŽ člověk do TÉHOŽ klubu neprojde (na tom stojí hláška v UI)
-- =============================================================================

\set ON_ERROR_STOP on

-- Pojistka: tenhle soubor ZAPISUJE A COMMITUJE. Na produkci nesmí nikdy.
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

-- Vrátí DŮVOD, proč zápis neprošel: 'rls', 'unique', nebo 'PROSEL'. „Spadlo to"
-- samo o sobě není důkaz — chybějící grant nebo překlep v SQL vypadá stejně
-- a udělal by z negativních scénářů falešnou zeleň.
--
-- PROČ DVA ROZLIŠENÉ DŮVODY A NE JEDNO „odmítnuto": scénář 5 vkládá dvojici
-- (klub_a, admin_id) a čeká, že ji zastaví RLS. Kdyby helper bral jako úspěch
-- i `duplicate key`, prošel by scénář 5 i tehdy, když je testovací admin
-- v klubu A náhodou už zapsaný — a RLS by se vůbec neměřilo. Tvrzení by pak
-- bylo zelené z jiného důvodu, než jaký hlídá. (Nález code-review brány.)
CREATE OR REPLACE FUNCTION pg_temp.duvod_odmitnuti(_sql text, _uziv uuid) RETURNS text
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
    -- RLS umí odmítnout i TIŠE (porušené USING u UPDATE/DELETE), proto ROW_COUNT
    RETURN CASE WHEN _n = 0 THEN 'rls' ELSE 'PROSEL' END;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('role', 'none', true);
    IF SQLERRM LIKE '%violates row-level security policy%'
       OR SQLERRM LIKE '%porušuje zásadu zabezpečení na úrovni řádků%' THEN
      RETURN 'rls';
    END IF;
    IF SQLERRM LIKE '%duplicate key value%'
       OR SQLERRM LIKE '%duplicitní hodnota klíče%' THEN
      RETURN 'unique';
    END IF;
    RAISE EXCEPTION 'Zápis selhal z JINÉHO důvodu než kvůli bráně: %', SQLERRM;
  END;
END $$;

-- ---------------------------------------------------------------------------
-- FIXTURY: dva různé kluby, do kterých testovaný člověk zatím nepatří
-- ---------------------------------------------------------------------------
-- Parametry drží TEMP tabulka, ale musí se ZPŘÍSTUPNIT roli `authenticated`
-- (viz GRANT pár řádků níž): scénáře běží pod `SET LOCAL ROLE authenticated`
-- a ta role na dočasné schéma sama o sobě práva nemá — napoprvé to celý test
-- shodilo na „permission denied for table t_param". Je to jen testovací
-- nádoba s UUID, nic z produkčních dat se tím neotevírá.
-- ÚČTY SE ODVOZUJÍ DOTAZEM, NE NATVRDO. Dřív tu byla dvě konkrétní produkční
-- UUID: až by ten člověk dostal roli admina nebo by mu účet zanikl, zčervenala
-- by fixtura z důvodu, který s testovanou věcí nesouvisí — a další čtenář by to
-- hledal v RLS. (Nález code-review brány.)
--
-- KLUBY MUSÍ BÝT VOLNÉ PRO OBA. `klub_a` se dřív vybíral jen podle toho, že tam
-- není `clovek_id`. Scénář 5 do něj ale vkládá `admin_id` a čeká, že ho zastaví
-- RLS — kdyby tam admin náhodou už byl, spadlo by to na UNIQUE a tvrzení by bylo
-- zelené, aniž by RLS změřilo.
--
-- A NESMÍ MÍT ČEKAJÍCÍ ŽÁDOST. Vložení do `subject_reps` spouští
-- `trg_subject_reps_zavri_zadost` (20260904120000), který čekající
-- `subject_requests` pro tutéž dvojici NEVRATNĚ překlopí na `schvalena` —
-- původní stav se nikam neukládá, takže by ho úklid na konci nevrátil. Vybíráme
-- proto jen kluby, kde ta dvojice žádnou čekající žádost nemá, a nic se tím
-- nerozbije. (Nález code-review brány.)
--
-- `WHERE current_database() = 'curling_test'` NENÍ ZDVOJENÁ POJISTKA NAVÍC, je
-- to ta jediná, která drží sama o sobě. Kontrola v DO bloku výš spoléhá na to,
-- že běh po chybě skončí — `\set ON_ERROR_STOP` je ale psql meta-příkaz, takže
-- kdyby soubor někdo pustil jiným kanálem, `RAISE` shodí jen svůj příkaz a
-- pojede se dál. Tenhle soubor přitom COMMITUJE. S touhle podmínkou vyjde
-- `t_param` mimo repliku PRÁZDNÁ, `INSERT … SELECT FROM t_param` vloží nula
-- řádků a fixtura zčervená dřív, než se cokoli zapíše. (Nález code-review brány.)
CREATE TEMP TABLE t_param AS
WITH adm AS (
  SELECT ur.user_id AS admin_id FROM public.user_roles ur
   WHERE ur.role = 'admin' ORDER BY ur.user_id LIMIT 1
), clv AS (
  SELECT ur.user_id AS clovek_id FROM public.user_roles ur
   GROUP BY ur.user_id HAVING bool_and(ur.role <> 'admin')
   ORDER BY ur.user_id LIMIT 1
), volne AS (
  SELECT s.id, row_number() OVER (ORDER BY s.name) AS poradi
    FROM public.subjects s, adm, clv
   WHERE s.deleted_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.subject_reps x
                      WHERE x.subject_id = s.id AND x.user_id = clv.clovek_id)
     AND NOT EXISTS (SELECT 1 FROM public.subject_reps x
                      WHERE x.subject_id = s.id AND x.user_id = adm.admin_id)
     AND NOT EXISTS (SELECT 1 FROM public.subject_requests q
                      WHERE q.subject_id = s.id AND q.status = 'ceka'
                        AND q.user_id IN (clv.clovek_id, adm.admin_id))
)
SELECT adm.admin_id, clv.clovek_id,
       (SELECT id FROM volne WHERE poradi = 1) AS klub_a,
       (SELECT id FROM volne WHERE poradi = 2) AS klub_b
  FROM adm, clv
 WHERE current_database() = 'curling_test';

-- SNÍMEK PŘED ZÁPISY. Úklid na konci z něj bere ROZDÍL, místo aby mazal předem
-- známé dvojice — tak se uklidí i řádek, který vznikl jinde, než se čekalo.
CREATE TEMP TABLE t_pred AS SELECT id FROM public.subject_reps;

-- `authenticated` na dočasné schéma práva nemá; scénáře z něj ale čtou.
DO $$
BEGIN
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO authenticated', nspname)
    FROM pg_namespace WHERE oid = pg_my_temp_schema();
END $$;
GRANT SELECT ON t_param TO authenticated;

-- Pozor: když je `t_param` PRÁZDNÁ (běh mimo repliku, viz podmínka
-- `current_database()` výš), vrátí tenhle poddotaz NULL a `tvrd` ho bere jako
-- nepravdu — test tedy skončí dřív, než cokoli zapíše. To je záměr.
SELECT pg_temp.tvrd(
  (SELECT klub_a IS NOT NULL AND klub_b IS NOT NULL AND klub_a <> klub_b FROM t_param),
  'FIXTURA: našly se DVA různé kluby, ve kterých testovaný člověk ještě není');
SELECT pg_temp.tvrd(
  NOT EXISTS (SELECT 1 FROM public.subject_reps r, t_param p
               WHERE r.user_id = p.admin_id AND r.subject_id IN (p.klub_a, p.klub_b)),
  'FIXTURA: ani ADMIN v těch klubech není (scénář 5 tak měří RLS, ne UNIQUE)');
SELECT pg_temp.tvrd(
  NOT EXISTS (SELECT 1 FROM public.subject_requests q, t_param p
               WHERE q.status = 'ceka' AND q.subject_id IN (p.klub_a, p.klub_b)
                 AND q.user_id IN (p.clovek_id, p.admin_id)),
  'FIXTURA: k těm dvojicím není ČEKAJÍCÍ žádost (INSERT by ji nevratně schválil)');
SELECT pg_temp.tvrd(
  public.has_role((SELECT admin_id FROM t_param), 'admin'),
  'FIXTURA: testovací admin je opravdu admin');
SELECT pg_temp.tvrd(
  NOT public.has_role((SELECT clovek_id FROM t_param), 'admin'),
  'FIXTURA: přidávaný člověk admin NENÍ (jinak by scénář 5 nic neměřil)');

-- ---------------------------------------------------------------------------
-- 1) Admin přidá člověka do klubu A — a po COMMITU tam řádek zůstane
-- ---------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT admin_id FROM t_param), 'role', 'authenticated')::text, true);
INSERT INTO public.subject_reps (subject_id, user_id, level)
SELECT klub_a, clovek_id, 'member' FROM t_param;
COMMIT;

SELECT pg_temp.tvrd(
  EXISTS (SELECT 1 FROM public.subject_reps r, t_param p
           WHERE r.subject_id = p.klub_a AND r.user_id = p.clovek_id AND r.level = 'member'),
  '1) admin přidal člověka do klubu A a po COMMITU je řádek v databázi');

-- 4) Auditní stopa: `created_by` se vyplní z tokenu, nemusí ho posílat frontend
SELECT pg_temp.tvrd(
  (SELECT r.created_by FROM public.subject_reps r, t_param p
    WHERE r.subject_id = p.klub_a AND r.user_id = p.clovek_id)
  = (SELECT admin_id FROM t_param),
  '4) created_by se vyplnil sám z tokenu (auditní stopa „kdo koho přidal")');

-- ---------------------------------------------------------------------------
-- 2+3) JÁDRO HLÁŠENÍ: týž člověk jde přidat i do DALŠÍHO klubu, jako správce
-- ---------------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', (SELECT admin_id FROM t_param), 'role', 'authenticated')::text, true);
INSERT INTO public.subject_reps (subject_id, user_id, level)
SELECT klub_b, clovek_id, 'rep' FROM t_param;
COMMIT;

SELECT pg_temp.tvrd(
  EXISTS (SELECT 1 FROM public.subject_reps r, t_param p
           WHERE r.subject_id = p.klub_b AND r.user_id = p.clovek_id AND r.level = 'rep'),
  '2+3) JÁDRO: týž člověk je i v DRUHÉM klubu, a to jako Správce klubu');

SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.subject_reps r, t_param p
    WHERE r.user_id = p.clovek_id AND r.subject_id IN (p.klub_a, p.klub_b)) = 2,
  '2b) členství ve VÍC klubech zároveň databáze dovoluje (UNIQUE je na dvojici)');

-- ---------------------------------------------------------------------------
-- 5) Řadový člen to nesmí — RLS drží
-- ---------------------------------------------------------------------------
-- Bez tohohle by šlo „opravit" hlášení tím, že se přiřazování otevře komukoli.
SELECT pg_temp.tvrd(pg_temp.duvod_odmitnuti(
  format($f$INSERT INTO public.subject_reps (subject_id, user_id, level)
            VALUES (%L, %L, 'member')$f$,
         (SELECT klub_a FROM t_param), (SELECT admin_id FROM t_param)),
  (SELECT clovek_id FROM t_param)) = 'rls',
  '5) řadový člen člověka do klubu přiřadit NESMÍ — a zastaví ho RLS, ne UNIQUE');

-- ---------------------------------------------------------------------------
-- 6) Dvakrát týž člověk do TÉHOŽ klubu neprojde
-- ---------------------------------------------------------------------------
-- Na tomhle stojí hláška v UI („Tento uživatel už u subjektu je."), takže když
-- constraint zmizí, přestane platit i ta hláška.
SELECT pg_temp.tvrd(pg_temp.duvod_odmitnuti(
  format($f$INSERT INTO public.subject_reps (subject_id, user_id, level)
            VALUES (%L, %L, 'member')$f$,
         (SELECT klub_a FROM t_param), (SELECT clovek_id FROM t_param)),
  (SELECT admin_id FROM t_param)) = 'unique',
  '6) týž člověk dvakrát do TÉHOŽ klubu NEPROJDE — a zastaví ho UNIQUE, ne RLS');

-- ---------------------------------------------------------------------------
-- ÚKLID — test commituje, takže po sobě musí uklidit sám
-- ---------------------------------------------------------------------------
DELETE FROM public.subject_reps r
 WHERE NOT EXISTS (SELECT 1 FROM t_pred x WHERE x.id = r.id);

SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.subject_reps) = (SELECT count(*) FROM t_pred)
  AND NOT EXISTS (SELECT 1 FROM public.subject_reps r
                   WHERE NOT EXISTS (SELECT 1 FROM t_pred x WHERE x.id = r.id)),
  'ÚKLID: subject_reps je řádek po řádku ve stavu, v jakém test začal');

-- CO ÚKLID NEVRACÍ, a je to vědomé: `audit_log`. Vložení i smazání projde
-- `trg_subject_reps_audit` (20260716130000), takže po testu zůstanou v auditu
-- čtyři řádky. Je to append-only tabulka záměrně — mazat z ní by bylo horší než
-- ty čtyři řádky nechat. Druhá nevratná stopa, překlopení čekající
-- `subject_requests`, se NEVYRÁBÍ vůbec: fixtura výš takové dvojice z výběru
-- vyloučí. (Obojí nález code-review brány.)
