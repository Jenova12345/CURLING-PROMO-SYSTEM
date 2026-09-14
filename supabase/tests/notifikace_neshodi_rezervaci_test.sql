-- =============================================================================
-- TESTY: chyba notifikace nesmí shodit rezervaci (migrace 20260914180000)
-- =============================================================================
-- Spuštění (replika produkce, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/notifikace_neshodi_rezervaci_test.sql
--
-- PROČ TENHLE SOUBOR VZNIKL. `notify_user` visí na triggeru v živé cestě
-- `create_booking` a neměla jediný EXCEPTION handler, takže jakákoli chyba
-- notifikace shodila zakládání rezervace — a uživateli ukázala nepravdivé
-- „zadané údaje neprošly kontrolou databáze".
--
-- JAK SE TU VYRÁBÍ CHYBA: přidáním `CHECK (false) NOT VALID` na tabulku, do
-- které `notify_user` zapisuje. Schválně se NESAHÁ na kód funkcí — mutace, která
-- přepíše to, co měří, snadno začne měřit sama sebe. Takhle je vstup vnější
-- a poznatelný, a `NOT VALID` navíc znamená, že se existující řádky nekontrolují,
-- takže constraint jde přidat i na plnou tabulku.
--
-- CO SE HLÍDÁ:
--   1) rozbitá NOTIFIKACE   → rezervace stejně vznikne
--   2) rozbitý E-MAIL       → rezervace vznikne A notifikace v appce ZŮSTANE
--   3) obojí se ZALOGUJE, se správnou fází
--   4) i rozbité LOGOVÁNÍ samo o sobě nikoho neshodí
--   5) `notifikace_chyby` čte jen admin (reálným tokenem, ne jako postgres)
--   6) PROTIPÓL: bez EXCEPTION handleru rezervace SPADNE — tedy nástroj, kterým
--      se chyba vyrábí, opravdu kousne (co hlídá samotnou opravu, viz níž)
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

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE '  OK  %', _popis;
END $$;

-- Účty a klub se odvozují dotazem, ne natvrdo: konkrétní UUID by po jiném dumpu
-- repliky udělalo z testu falešnou zeleň (táž třída chyby jako jinde v repu).
-- Potřebujeme ČLENA klubu (ne zástupce, ne admina) — jen jeho rezervace vzniká
-- nepotvrzená, a právě ta spouští `notify_reservation_approval` → `notify_user`.
CREATE OR REPLACE FUNCTION pg_temp.clen() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT sr.user_id FROM public.subject_reps sr
   WHERE sr.level = 'member' AND NOT public.has_role(sr.user_id, 'admin')
     AND EXISTS (SELECT 1 FROM public.subject_reps x
                  WHERE x.subject_id = sr.subject_id AND x.level = 'rep')
   ORDER BY sr.user_id LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION pg_temp.klub() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT sr.subject_id FROM public.subject_reps sr
   WHERE sr.user_id = pg_temp.clen() AND sr.level = 'member'
     AND EXISTS (SELECT 1 FROM public.subject_reps x
                  WHERE x.subject_id = sr.subject_id AND x.level = 'rep')
   ORDER BY sr.subject_id LIMIT 1;
$$;

-- Založí rezervaci jako ten člen a vrátí, jestli to prošlo.
CREATE OR REPLACE FUNCTION pg_temp.zaloz(_hodina int) RETURNS boolean
 LANGUAGE plpgsql AS $$
DECLARE _sheet uuid := (SELECT s.id FROM public.sheets s ORDER BY s.name LIMIT 1);
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', pg_temp.clen(), 'role', 'authenticated')::text, true);
  PERFORM public.create_booking(
    ARRAY[_sheet], 'training', 'Test notifikací',
    ('2029-04-01 ' || _hodina || ':00+02')::timestamptz,
    ('2029-04-01 ' || (_hodina + 1) || ':00+02')::timestamptz,
    pg_temp.klub(), NULL, NULL, NULL, false, NULL, NULL);
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END $$;

SELECT pg_temp.tvrd(pg_temp.clen() IS NOT NULL AND pg_temp.klub() IS NOT NULL,
  'FIXTURA: našel se člen klubu, jehož rezervace spouští notifikaci');

-- ⚠️ VŠECHNA TVRZENÍ O LOGU MĚŘÍ PŘÍRŮSTEK, NE ABSOLUTNÍ POČET.
-- Napoprvé tu stálo `count(*) = 0` a `NOT EXISTS (… faze = 'notifikace')`.
-- Bylo to zelené jen proto, že tabulka byla čerstvá a prázdná; code-review brána
-- to doložila tím, že do ní vložila jeden realistický provozní řádek a scénář 0b
-- zčervenal. Nad replikou produkce, kde už nějaké řádky budou, by tenhle soubor
-- vyráběl FALEŠNOU ČERVEŇ — tedy bránu, která hlásí poruchu tam, kde není.
-- Snímek toho, co v logu bylo PŘED testem. Týž vzor jako v
-- `pridani_do_klubu_test.sql`: tvrdí se o rozdílu proti snímku, ne o absolutním
-- počtu, takže je jedno, co v tabulce leželo předtím.
CREATE TEMP TABLE t_log_pred AS SELECT id FROM public.notifikace_chyby;

-- Řádky, které přibyly od začátku testu. `_faze IS NULL` = všechny fáze.
CREATE OR REPLACE FUNCTION pg_temp.log_nove(_faze text DEFAULT NULL) RETURNS bigint
 LANGUAGE sql STABLE AS $$
  SELECT count(*) FROM public.notifikace_chyby n
   WHERE NOT EXISTS (SELECT 1 FROM t_log_pred x WHERE x.id = n.id)
     AND (_faze IS NULL OR n.faze = _faze);
$$;

-- SQLSTATE posledního přibylého řádku dané fáze. `ORDER BY created_at DESC`
-- tu není ozdoba: bez něj vybere `LIMIT 1` libovolný řádek, klidně cizí.
CREATE OR REPLACE FUNCTION pg_temp.log_posledni_stav(_faze text) RETURNS text
 LANGUAGE sql STABLE AS $$
  SELECT n.sqlstate FROM public.notifikace_chyby n
   WHERE NOT EXISTS (SELECT 1 FROM t_log_pred x WHERE x.id = n.id)
     AND n.faze = _faze
   ORDER BY n.created_at DESC, n.id DESC LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- 0) PROTIPÓL: na nerozbité databázi to prochází
-- ---------------------------------------------------------------------------
-- Bez tohohle by scénáře 1–2 mohly být zelené proto, že `create_booking` prostě
-- funguje vždycky, a nikdo by nepoznal, že se chyba vůbec nevyrobila.
SAVEPOINT s0;
SELECT pg_temp.tvrd(pg_temp.zaloz(8),
  '0) PROTIPÓL: bez rozbité notifikace se rezervace založí');
SELECT pg_temp.tvrd(pg_temp.log_nove() = 0,
  '0b) PROTIPÓL: a nic NOVÉHO se přitom nezaloguje (bez poruchy se log neplní)');
ROLLBACK TO SAVEPOINT s0;

-- ---------------------------------------------------------------------------
-- 1) JÁDRO: rozbitá notifikace rezervaci NESHODÍ
-- ---------------------------------------------------------------------------
SAVEPOINT s1;
ALTER TABLE public.notifications ADD CONSTRAINT t_spadne CHECK (false) NOT VALID;
SELECT pg_temp.tvrd(pg_temp.zaloz(9),
  '1) JÁDRO: rezervace vznikne, i když zápis notifikace selže');
SELECT pg_temp.tvrd(pg_temp.log_nove('notifikace') > 0,
  '1b) a spolknutá chyba je ZALOGOVANÁ ve fázi „notifikace"');
SELECT pg_temp.tvrd(pg_temp.log_posledni_stav('notifikace') = '23514',
  '1c) log nese SQLSTATE skutečné chyby (23514 = porušený CHECK), ne vymyšlený');
ROLLBACK TO SAVEPOINT s1;

-- ---------------------------------------------------------------------------
-- 2) Rozbitý e-mail nesmí vzít s sebou notifikaci v aplikaci
-- ---------------------------------------------------------------------------
-- Tohle měří, PROČ jsou bloky dva. EXCEPTION blok je subtransakce: jeden
-- společný blok kolem celé funkce by při selhání e-mailu vrátil i zápis do
-- `notifications` a uživatel by přišel o zprávu kvůli nedoručenému e-mailu.
SAVEPOINT s2;
ALTER TABLE public.email_outbox ADD CONSTRAINT t_spadne CHECK (false) NOT VALID;
-- Počet notifikací PŘED zápisem, aby scénář 2b měl s čím porovnávat.
CREATE TEMP TABLE t_pocet AS SELECT count(*) AS n FROM public.notifications;
SELECT pg_temp.tvrd(pg_temp.zaloz(10),
  '2) rezervace vznikne, i když selže zápis do e-mailové fronty');
SELECT pg_temp.tvrd(
  (SELECT count(*) FROM public.notifications) > (SELECT n FROM t_pocet),
  '2b) JÁDRO DVOU BLOKŮ: notifikace v aplikaci ZŮSTALA, e-mail ji nevzal s sebou');
SELECT pg_temp.tvrd(
  pg_temp.log_nove('email') > 0 AND pg_temp.log_nove('notifikace') = 0,
  '2c) zaloguje se fáze „email", a NE „notifikace" (fáze se nepletou)');
DROP TABLE t_pocet;
ROLLBACK TO SAVEPOINT s2;

-- ---------------------------------------------------------------------------
-- 3) Rozbité logování nesmí shodit to, co loguje
-- ---------------------------------------------------------------------------
-- Pojistka, která má vlastní způsob, jak spadnout, není pojistka. Rozbíjí se
-- OBOJÍ najednou: notifikace i tabulka, kam se ta chyba zapisuje.
SAVEPOINT s3;
ALTER TABLE public.notifications ADD CONSTRAINT t_spadne CHECK (false) NOT VALID;
ALTER TABLE public.notifikace_chyby ADD CONSTRAINT t_spadne CHECK (false) NOT VALID;
SELECT pg_temp.tvrd(pg_temp.zaloz(11),
  '3) rezervace vznikne, i když selže NOTIFIKACE I JEJÍ LOGOVÁNÍ zároveň');
ROLLBACK TO SAVEPOINT s3;

-- ---------------------------------------------------------------------------
-- 4) PROTIPÓL: bez EXCEPTION handleru to spadne
-- ---------------------------------------------------------------------------
-- ⚠️ ČTI, NEŽ SE NA TENHLE SCÉNÁŘ SPOLEHNEŠ: NEMĚŘÍ OPRAVU.
--
-- Dřívější znění tady slibovalo „tohle je ten test, kvůli kterému soubor
-- existuje" a „když zezelená, oprava přestala držet". Obojí bylo špatně, obojí
-- změřeno bránou migrací 14. 9. 2026:
--
--     stav                                    scénář 4
--     oprava platná                           ZELENÝ
--     oprava zmizela (produkční notify_user)  ZELENÝ   ← neuhlídá
--     notify_user rozbitá jinak               ZELENÝ   ← neuhlídá
--
-- Důvod: scénář si `notify_user` SÁM PŘEPÍŠE vlastním mutantem, takže měří
-- vlastnost toho mutanta, ne to, co je v databázi nasazené. A druhá věta měla
-- obrácenou polaritu — zelená je průchozí stav, ne poplach.
--
-- K čemu tedy JE: dokazuje, že `CHECK (false)`, kterým se chyba vyrábí,
-- opravdu shodí `create_booking`, když handler chybí. Bez toho by scénáře 1–3
-- mohly být zelené jen proto, že se chyba vůbec nevyrobila.
--
-- OPRAVU SAMOTNOU HLÍDÁ SCÉNÁŘ 1: pod produkční `notify_user` (tedy když by
-- oprava z nasazení zmizela) ZČERVENÁ. Ověřeno toutéž bránou, spolu s dalšími
-- pěti mutacemi — chycených 6 ze 7.
SAVEPOINT s4;
CREATE OR REPLACE FUNCTION public.notify_user(
  _user uuid, _type text, _title text, _body text,
  _link text DEFAULT '/calendar'::text, _reservation_id uuid DEFAULT NULL::uuid,
  _subject_id uuid DEFAULT NULL::uuid)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $mutace$
DECLARE _id uuid;
BEGIN
  IF _user IS NULL THEN RETURN NULL; END IF;
  -- Schválně BEZ EXCEPTION bloku — stav před migrací 20260914180000.
  INSERT INTO public.notifications (user_id, type, title, body, link, reservation_id, subject_id, created_by)
  VALUES (_user, _type, _title, _body, _link, _reservation_id, _subject_id, auth.uid())
  RETURNING id INTO _id;
  RETURN _id;
END;
$mutace$;
ALTER TABLE public.notifications ADD CONSTRAINT t_spadne CHECK (false) NOT VALID;
SELECT pg_temp.tvrd(NOT pg_temp.zaloz(12),
  '4) PROTIPÓL: bez EXCEPTION handleru rezervace SPADNE (chyba se tedy vyrábí)');
ROLLBACK TO SAVEPOINT s4;

-- ---------------------------------------------------------------------------
-- 5) Práva na `notifikace_chyby` — reálným tokenem, ne jako postgres
-- ---------------------------------------------------------------------------
-- Log nese `chyba` a `kontext`, tedy vnitřnosti databáze. Patří adminovi.
-- Jako `postgres` projde všechno (obchází granty i RLS), takže se to měří
-- pod `SET LOCAL ROLE authenticated` (CLAUDE.md, bod 3).
CREATE OR REPLACE FUNCTION pg_temp.pocet_jako(_uziv uuid) RETURNS integer
 LANGUAGE plpgsql AS $$
DECLARE _n integer;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO _n FROM public.notifikace_chyby;
  PERFORM set_config('role', 'none', true);
  RETURN _n;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('role', 'none', true);
  RETURN -1;   -- -1 = zamítnuto grantem (42501), 0 = pustilo, ale RLS nic nedalo
END $$;

SAVEPOINT s5;
ALTER TABLE public.notifications ADD CONSTRAINT t_spadne CHECK (false) NOT VALID;
SELECT pg_temp.zaloz(13);   -- vyrobit aspoň jeden řádek v logu
SELECT pg_temp.tvrd(pg_temp.log_nove() > 0,
  'FIXTURA 5) v logu přibyl aspoň jeden řádek (jinak by 5a/5b neměřily nic)');
SELECT pg_temp.tvrd(pg_temp.pocet_jako(pg_temp.clen()) = 0,
  '5a) NEADMIN v logu nevidí ani řádek (RLS drží)');
SELECT pg_temp.tvrd(
  pg_temp.pocet_jako((SELECT ur.user_id FROM public.user_roles ur
                       WHERE ur.role = 'admin' ORDER BY ur.user_id LIMIT 1)) > 0,
  '5b) PROTIPÓL: ADMIN log vidí (jinak by 5a bylo zelené z nudného důvodu)');
-- 5c) GRANTY SE MĚŘÍ TVAREM ACL, NE CHOVÁNÍM — a je to nutné, ne puntičkářství.
--
-- Napoprvé tu stálo `NOT has_table_privilege('anon', …)`. Bezpečnostní brána
-- doložila, že to tvrzení NEMŮŽE ZČERVENAT: založila tabulku bez řádku REVOKE
-- a test zůstal zelený. Důvod je v prostředí — replika nemá ANI JEDEN řádek
-- v `pg_default_acl` (produkce jich má 24), protože `scripts/testovaci-replika.sh`
-- dumpuje s `--no-privileges` a granty přehrává jen pro EXISTUJÍCÍ objekty.
-- Past, kterou tohle tvrzení hlídá — default privileges dávající `anon`
-- a `authenticated` ALL na každou NOVOU tabulku — na replice prostě neexistuje,
-- takže tam nikdo dveře neotevře a „zavřeno" platí zadarmo.
--
-- Je to táž past, která dneska otevřela zápis do ceníku komukoli přihlášenému
-- (hotfix 20260914150000), takže si zaslouží tvrzení, které platí i tam, kde ji
-- prostředí nevyrobí. Porovnává se proto přímo `relacl` a `proacl` s tvarem
-- naměřeným po migraci — ten je stejný na replice i na produkci a nezávisí na
-- tom, co v daném prostředí dělají default privileges.
SELECT pg_temp.tvrd(
  (SELECT array_agg(a::text ORDER BY a::text)
     FROM unnest(COALESCE((SELECT relacl FROM pg_class
                            WHERE oid = 'public.notifikace_chyby'::regclass),
                          '{}'::aclitem[])) a)
  = ARRAY['authenticated=r/postgres',
          'postgres=arwdDxtm/postgres',
          'service_role=arwdDxtm/postgres']::text[],
  '5c) relacl notifikace_chyby je PŘESNĚ {authenticated=r, postgres, service_role} '
  '— authenticated jen SELECT, anon nikde');

-- 5d) Táž kontrola pro zapisovací funkci. Bez ní by ji `CREATE OR REPLACE`
-- v příští migraci bez zopakovaného REVOKE otevřel TIŠE (`pg_default_acl`
-- pro funkce dává `authenticated=X` i `anon=X` znovu při každém vytvoření).
-- Kdo na ni dostane EXECUTE, může do logu, který admin čte jako důkaz,
-- podvrhnout cizí `user_id` i `reservation_id`, utopit skutečné selhání v šumu
-- nebo poslat libovolný text do logu Postgresu přes RAISE WARNING.
-- (Nález bezpečnostní brány — tahle funkce dosud neměla tvrzení žádné.)
SELECT pg_temp.tvrd(
  (SELECT array_agg(a::text ORDER BY a::text)
     FROM unnest(COALESCE((SELECT p.proacl FROM pg_proc p
                             JOIN pg_namespace n ON n.oid = p.pronamespace
                            WHERE n.nspname = 'public'
                              AND p.proname = 'zaloguj_chybu_notifikace'),
                          '{}'::aclitem[])) a)
  = ARRAY['postgres=X/postgres', 'service_role=X/postgres']::text[],
  '5d) zaloguj_chybu_notifikace NENÍ spustitelná z API (jen postgres a service_role)');

-- 5e) A protipól k obojímu: chování pod reálným tokenem. Tvar ACL říká, co je
-- napsané; tohle říká, co se doopravdy stane. Obojí je potřeba — kdyby nad
-- tabulkou přibylo něco, co granty obchází, tvar by pořád seděl.
SELECT pg_temp.tvrd(
  NOT has_table_privilege('authenticated', 'public.notifikace_chyby', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.notifikace_chyby', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.notifikace_chyby', 'DELETE'),
  '5e) authenticated do logu nesmí psát ani v něm mazat');
ROLLBACK TO SAVEPOINT s5;

ROLLBACK;
