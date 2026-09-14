-- =============================================================================
-- TESTY: adresa portálu v e-mailech se bere z nastavení, ne z kódu
-- =============================================================================
-- Spuštění (replika produkce v lokálním Postgresu, viz scripts/testovaci-replika.sh):
--   psql -p 5433 -U postgres -d curling_test -X -q -v ON_ERROR_STOP=1 \
--     -f supabase/tests/adresa_portalu_test.sql
--
-- CO TENHLE TEST HLÍDÁ NEJVÍC:
--
-- 1) ŽE SE ADRESA OPRAVDU ČTE, NE JEN PŘEPSALA. Scénář 2 změní `web_base_url`
--    na jinou hodnotu a čeká, že se promítne do e-mailu. Bez něj by test prošel
--    i tehdy, kdyby někdo v těle funkce nechal novou adresu zase jako konstantu —
--    a celý smysl změny (měnit adresu bez migrace) by tiše zmizel.
--
-- 2) ŽE SE ODKAZ NEROZBIJE, KDYŽ NASTAVENÍ CHYBÍ. Scénář 3. `_web` NULL by
--    udělal NULL z celého těla e-mailu, a protože `email_outbox.body` je
--    NOT NULL, letěla by výjimka Z TRIGGERU — tedy by neshodila e-mail, ale
--    celé `create_booking`. Rezervace by se nedala založit kvůli e-mailu.
--
-- 3) ŽE CHECK NEPUSTÍ ADRESU, KTERÁ BY VYROBILA ROZBITÝ ODKAZ. Scénář 4.
--    Tělo skládá odkaz jako `_web || _cil`, takže koncové lomítko, cesta
--    nebo `http://` se propíšou do e-mailu z naší ověřené domény.
--
-- 4) ŽE SE NIC NEOTEVŘELO. Scénář 5: `email_sablona` dál není grantovaná
--    `authenticated`. Funkce nově ČTE `settings`, na které `authenticated`
--    nemá ani SELECT — kdyby jí EXECUTE někdo přidal, byla by to cesta ke
--    čtení nastavení mimo `settings_public`.
--
-- 5) ŽE FUNKCE NENÍ IMMUTABLE. Scénář 6. Po přidání čtení z tabulky by to byla
--    lež plánovači: směl by si výsledek předpočítat a držet napříč transakcemi,
--    takže by změněná adresa nemusela být vidět. Chytit se to dá jen takhle —
--    chování se projeví až za dlouho a nahodile.
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

-- Vrátí true, když UPDATE neprošel kvůli NAŠEMU CHECKu — ne kvůli čemukoli.
-- „Spadlo to" samo o sobě není důkaz: chybějící právo nebo překlep v SQL
-- vypadá stejně a udělalo by z negativních scénářů falešnou zeleň.
CREATE OR REPLACE FUNCTION pg_temp.check_odmitl(_adresa text) RETURNS boolean
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    UPDATE public.settings SET web_base_url = _adresa WHERE singleton;
    RETURN false;
  EXCEPTION WHEN check_violation THEN
    RETURN true;
  END;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Výchozí stav: v nastavení je nová adresa a e-mail ji používá
-- ---------------------------------------------------------------------------
SELECT pg_temp.tvrd(
  (SELECT web_base_url FROM public.settings WHERE singleton)
    = 'https://portal.curlingpromoostrava.cz',
  '1a) v nastavení je nová adresa portálu');

SELECT pg_temp.tvrd(
  (SELECT body FROM public.email_sablona('reservation_approved','x','y','/calendar'))
    LIKE '%https://portal.curlingpromoostrava.cz/calendar%',
  '1b) odkaz v e-mailu vede na novou adresu');

SELECT pg_temp.tvrd(
  (SELECT body FROM public.email_sablona('reservation_approved','x','y','/calendar'))
    NOT LIKE '%netlify.app%',
  '1c) stará netlify adresa se v e-mailu už neobjeví');

-- ---------------------------------------------------------------------------
-- 2) JÁDRO: adresa se ČTE z nastavení, není zadrátovaná
-- ---------------------------------------------------------------------------
-- Tohle je celý smysl změny. Kdyby někdo v těle funkce nechal novou adresu jako
-- konstantu, scénáře 1a–1c by prošly a jenom tenhle zčervená.
--
-- ZKUŠEBNÍ ADRESA MUSÍ BÝT POD NAŠÍ DOMÉNOU. Do 14. 9. 2026 tu stálo
-- `https://jiny-portal.example.cz` a tvrdilo se „a NENÍ tam curlingpromoostrava".
-- Od zavedení allowlistu v CHECKu cizí doména neprojde, takže se mění jen
-- SUBDOMÉNA a protipól je jiný: v e-mailu nesmí být VÝCHOZÍ host
-- `//portal.curlingpromoostrava.cz`. Důkaz „čte se to z tabulky" tím neslábne —
-- kdyby byla adresa zadrátovaná, vyšel by z funkce pořád výchozí host.
DO $$
DECLARE _telo text;
BEGIN
  UPDATE public.settings SET web_base_url = 'https://jiny-portal.curlingpromoostrava.cz' WHERE singleton;
  SELECT body INTO _telo FROM public.email_sablona('reservation_approved','x','y','/calendar');
  PERFORM pg_temp.tvrd(
    _telo LIKE '%https://jiny-portal.curlingpromoostrava.cz/calendar%'
    AND _telo NOT LIKE '%//portal.curlingpromoostrava.cz%',
    '2) JÁDRO: změna adresy v nastavení se PROMÍTNE do e-mailu (bez migrace)');
  UPDATE public.settings SET web_base_url = 'https://portal.curlingpromoostrava.cz' WHERE singleton;
END $$;

-- ---------------------------------------------------------------------------
-- 3) Chybějící nastavení odkaz nerozbije (a hlavně neshodí rezervaci)
-- ---------------------------------------------------------------------------
-- `singleton` je UNIQUE a CHECK (singleton = true), takže řádek nejde „vypnout".
-- Stav „nastavení není" se proto vyrábí jeho smazáním — v transakci, která se
-- stejně vrací zpátky.
DO $$
DECLARE _telo text;
BEGIN
  DELETE FROM public.settings WHERE singleton;
  SELECT body INTO _telo FROM public.email_sablona('reservation_approved','x','y','/calendar');
  PERFORM pg_temp.tvrd(
    _telo IS NOT NULL AND _telo LIKE '%https://portal.curlingpromoostrava.cz/calendar%',
    '3) bez řádku v nastavení tělo e-mailu NENÍ NULL a spadne na výchozí adresu');
EXCEPTION WHEN foreign_key_violation THEN
  -- Kdyby na `settings` někdy něco viselo cizím klíčem, scénář se nedá postavit
  -- a je poctivější to říct, než ho tiše přeskočit.
  RAISE EXCEPTION 'Scénář 3 nejde postavit: na settings visí cizí klíč. Přepiš ho.';
END $$;
ROLLBACK;

-- Smazání výš je nevratné jen v rámci té transakce; dál se pokračuje načisto.
BEGIN;
CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE '  OK  %', _popis;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.check_odmitl(_adresa text) RETURNS boolean
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    UPDATE public.settings SET web_base_url = _adresa WHERE singleton;
    RETURN false;
  EXCEPTION WHEN check_violation THEN
    RETURN true;
  END;
END $$;

-- ÚČTY PRO SCÉNÁŘ 5d SE ODVOZUJÍ DOTAZEM, NE NATVRDO.
-- Do 14. 9. 2026 tu byla dvě konkrétní produkční UUID. Nález bezpečnostní brány:
-- smazala tomu uživateli všechny role a scénář 5d ZŮSTAL ZELENÝ — protože
-- „neznámé UUID nesmí zapsat" platí triviálně. Jiný dump repliky (přeházená nebo
-- chybějící UUID) by tedy z 5d udělal falešnou zeleň, což je přesně ta třída
-- chyby, kterou tenhle soubor jinde opravuje. Účty se proto berou z `user_roles`,
-- takže z definice existují a mají roli — a fixtura to ještě jednou tvrdí nahlas.
CREATE OR REPLACE FUNCTION pg_temp.nejaky_admin() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT ur.user_id FROM public.user_roles ur
   WHERE ur.role = 'admin' ORDER BY ur.user_id LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION pg_temp.nejaky_neadmin() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT ur.user_id FROM public.user_roles ur
   GROUP BY ur.user_id
  HAVING bool_and(ur.role <> 'admin')
   ORDER BY ur.user_id LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- FIXTURA 0: granty `settings` musí mít PRODUKČNÍ TVAR, jinak scénář 5 lže
-- ---------------------------------------------------------------------------
-- `scripts/testovaci-replika.sh` granty `settings` NEPŘENÁŠÍ VĚRNĚ: produkční
-- TABULKOVÝ grant `authenticated=awm` rozpustí do per-sloupcových. Rozdíl je
-- vidět jen na sloupci, který na produkci ještě nebyl — `web_base_url` tam
-- UPDATE dědí z tabulky, kdežto na čerstvé replice nedědí nic. Scénář 5d by
-- proto byl FALEŠNĚ ZELENÝ (a napoprvé byl).
--
-- Tahle fixtura rozdíl NEOPRAVUJE potichu, jen ho HLÁSÍ i s příkazem. Kdyby
-- granty srovnávala sama, přebila by mutace, které mají scénář 5 shazovat.
--
-- MĚŘÍ SE TŘI VĚCI, ne dvě. Napoprvé tu byly jen dva tabulkové bity a hláška
-- přitom slibovala „produkční tvar grantů". Nález migrační brány to doložil:
-- po `REVOKE SELECT (email_max_za_hodinu, updated_by)` zůstal test zelený
-- a fixtura dál hlásila produkční tvar. Proto se porovnává i SEZNAM čitelných
-- sloupců proti sedmiprvkovému literálu — ten je z produkce (14. 9. 2026).
DO $$
DECLARE _ctene text[];
BEGIN
  SELECT array_agg(a.attname::text ORDER BY a.attname) INTO _ctene
    FROM pg_attribute a
   WHERE a.attrelid = 'public.settings'::regclass AND a.attnum > 0
     AND NOT a.attisdropped
     AND has_column_privilege('authenticated', 'public.settings', a.attname, 'SELECT');

  IF NOT has_table_privilege('authenticated', 'public.settings', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.settings', 'SELECT')
     OR _ctene IS DISTINCT FROM ARRAY[
          'email_max_za_hodinu', 'email_notifications_enabled', 'id',
          'opening_hours', 'singleton', 'updated_at', 'updated_by']::text[] THEN
    RAISE EXCEPTION E'FIXTURA 0 SELHALA: granty `settings` na téhle databázi '
      'NEODPOVÍDAJÍ produkci, takže by scénář 5 měřil něco jiného, než co běží '
      'u klienta.\nProdukce (změřeno 14. 9. 2026): tabulkově INSERT+UPDATE+MAINTAIN, '
      'SELECT jen sloupcově na sedmi sloupcích.\nSrovnat lze takto:\n'
      '  REVOKE ALL ON public.settings FROM authenticated;\n'
      '  REVOKE ALL (id, singleton, club_default_rate, commercial_default_rate,\n'
      '    opening_hours, updated_by, updated_at, training_rate, tournament_rate,\n'
      '    email_notifications_enabled, ledar_jmeno, email_max_za_hodinu,\n'
      '    web_base_url) ON public.settings FROM authenticated;\n'
      '  GRANT INSERT, UPDATE, MAINTAIN ON public.settings TO authenticated;\n'
      '  GRANT SELECT (id, singleton, opening_hours, updated_by, updated_at,\n'
      '    email_notifications_enabled, email_max_za_hodinu)\n'
      '    ON public.settings TO authenticated;\n'
      'Čitelné sloupce teď: %', COALESCE(array_to_string(_ctene, ', '), '(žádné)');
  END IF;
  RAISE NOTICE '  OK  FIXTURA 0) granty settings mají produkční tvar (tabulkové UPDATE, žádný tabulkový SELECT, a čitelných je právě těch 7 sloupců)';
END $$;

-- ---------------------------------------------------------------------------
-- 4) CHECK nepustí adresu, která by vyrobila rozbitý NEBO CIZÍ odkaz
-- ---------------------------------------------------------------------------
-- CHECK hlídá dvě různé věci a obě se tu měří zvlášť:
--   TVAR     (4a–4e) — žádné http://, žádná cesta, lomítko, mezera, port
--   IDENTITA (4g–4k) — hostname musí končit na `curlingpromoostrava.cz`
-- Druhá půlka přibyla 14. 9. 2026 jako allowlist (nález bezpečnostní brány):
-- admin na `web_base_url` UPDATE reálně má, takže bez ní by si mohl odkazy
-- ve všech notifikačních e-mailech přesměrovat na phishing z naší ověřené
-- domény — a protože sloupec číst nesmí, nikdo by tu změnu v aplikaci neviděl.
-- Nejdřív vlastnosti samotného sloupce. Brána pro migrace je shodila obě
-- a suita zůstala zelená, takže je nehlídalo nic. `NOT NULL` kryje fallback
-- ve funkci (NULL by ho obešel a tělo e-mailu by vyšlo NULL, což shodí
-- `create_booking`), `DEFAULT` se projeví u budoucího INSERTu do `settings`.
SELECT pg_temp.tvrd(
  (SELECT a.attnotnull FROM pg_attribute a
    WHERE a.attrelid = 'public.settings'::regclass AND a.attname = 'web_base_url'),
  '4p) web_base_url je NOT NULL (NULL by obešel fallback a shodil create_booking)');
SELECT pg_temp.tvrd(
  (SELECT pg_get_expr(d.adbin, d.adrelid) FROM pg_attrdef d
     JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE d.adrelid = 'public.settings'::regclass AND a.attname = 'web_base_url')
  = '''https://portal.curlingpromoostrava.cz''::text',
  '4q) DEFAULT je nová adresa portálu');

SELECT pg_temp.tvrd(pg_temp.check_odmitl('http://portal.curlingpromoostrava.cz'),
  '4a) http:// se ODMÍTNE (odkaz v e-mailu musí být šifrovaný)');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://portal.curlingpromoostrava.cz/'),
  '4b) koncové lomítko se ODMÍTNE (vyrobilo by //calendar)');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://portal.curlingpromoostrava.cz/app'),
  '4c) cesta v adrese se ODMÍTNE');
SELECT pg_temp.tvrd(pg_temp.check_odmitl(''),
  '4d) prázdná adresa se ODMÍTNE');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://portal.curlingpromoostrava.cz zly'),
  '4e) mezera v adrese se ODMÍTNE');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://portal.curlingpromoostrava.cz:8080'),
  '4f) port se ODMÍTNE');

-- ALLOWLIST — tohle je ta půlka, která brání phishingu:
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://curling-phishing.example.com'),
  '4g) úplně cizí doména se ODMÍTNE');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://portal.curlingpromoostrava.cz.zly.cz'),
  '4h) JÁDRO: naše doména jako PŘEDPONA cizí se ODMÍTNE (…cz.zly.cz)');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://zlycurlingpromoostrava.cz'),
  '4i) naše doména bez tečky nalepená na cizí předponu se ODMÍTNE');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://portal-curlingpromoostrava.cz'),
  '4j) pomlčka místo tečky se ODMÍTNE (jinak by prošel portal-curlingpromoostrava.cz)');
SELECT pg_temp.tvrd(pg_temp.check_odmitl('https://xn--curlingpromostrava-2nb.cz'),
  '4k) punycode homograf se ODMÍTNE');
-- Regex sám délku nehlídá: `'https://' || repeat('a-',50000) || 'a.curlingpromoostrava.cz'`
-- jím projde. Odkaz to nepřesměruje, ale nafouklo by to tělo každého e-mailu.
-- DNS dovolí na host 253 znaků, takže 200 je nad čímkoli reálným.
SELECT pg_temp.tvrd(
  pg_temp.check_odmitl('https://' || repeat('a-', 50000) || 'a.curlingpromoostrava.cz'),
  '4o) adresa přes 200 znaků se ODMÍTNE (strop délky, ne jen tvar)');

-- A protipóly, ať test neměří jen to, že CHECK odmítá všechno — adresa se pořád
-- musí dát změnit, jinak by allowlist tiše zabil celý smysl změny.
--
-- Pozn. k mutačnímu ověřování: když se allowlist zúží na jednu jedinou adresu
-- (`CHECK (web_base_url = '…')`), suita zčervená UŽ U SCÉNÁŘE 2, a to jako
-- neodchycená `check_violation`, ne jako „TEST SELHAL" — scénář 2 mění adresu
-- mimo `check_odmitl`, takže výjimku nikdo nechytá. Kdo mutace filtruje grepem
-- na „SELHAL", tenhle případ přehlédne a bude si myslet, že mutace nezabrala.
-- Grepuj i na „ERROR".
SELECT pg_temp.tvrd(NOT pg_temp.check_odmitl('https://curlingpromoostrava.cz'),
  '4l) PROTIPÓL: holá naše doména PROJDE');
SELECT pg_temp.tvrd(NOT pg_temp.check_odmitl('https://novy-portal.curlingpromoostrava.cz'),
  '4m) PROTIPÓL: JINÁ subdoména naší domény PROJDE (adresa dál žije v nastavení)');
SELECT pg_temp.tvrd(NOT pg_temp.check_odmitl('https://a.b.curlingpromoostrava.cz'),
  '4n) PROTIPÓL: víceúrovňová subdoména PROJDE');

-- ---------------------------------------------------------------------------
-- 5) Nic se neotevřelo: šablona dál není dosažitelná z API
-- ---------------------------------------------------------------------------
-- Funkce nově čte `settings.web_base_url`, na který `authenticated` právo nemá.
-- Kdyby jí někdo EXECUTE přidal, vznikla by cesta ke čtení nastavení mimo
-- `settings_public`.
--
-- ⚠️ GRANTY FUNKCÍ SE TADY MĚŘIT NEDAJÍ PŘÍMO, A NENÍ TO PŘEHLÉDNUTÍ.
-- (Nepřímo ale ano, viz „MĚŘÍ SE MECHANISMUS" na konci téhle poznámky.)
-- `scripts/testovaci-replika.sh` funkcím granty z produkce NEKOPÍRUJE — jen
-- každé z nich PŘIDÁ `GRANT EXECUTE … TO authenticated` a nikdy neodebere
-- výchozí `EXECUTE TO PUBLIC`, které `pg_dump --no-privileges` nechá. Na replice
-- proto vypadá KAŽDÁ funkce v `public` jako otevřená pro `authenticated` i `anon`.
-- Tvrzení „authenticated EXECUTE nemá" by tu bylo červené vždycky, bez ohledu
-- na stav produkce — a tvrzení opačné by bylo falešně zelené.
--
-- Ověřeno proto ČTENÍM PŘÍMO NA PRODUKCI (14. 9. 2026):
--     email_sablona   proacl = {postgres=X/postgres, service_role=X/postgres}
-- tedy ani `authenticated`, ani `anon`. Kontrolní dotaz pro příště:
--     SELECT proacl FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public' AND p.proname = 'email_sablona';
--
-- MĚŘÍ SE MECHANISMUS, ne jen jednorázový odečet (nález bezpečnostní brány).
-- Samotné čtení produkce je totiž fotka, ne důkaz o tom, co migrace UDĚLÁ.
-- Scénář 5f proto měří pravidlo, na kterém to celé stojí: že
-- `CREATE OR REPLACE FUNCTION` zachová `proacl` i `prosecdef` a sáhne jen na to,
-- co v příkazu opravdu je. Když tohle platí (a platí), pak z „na produkci dnes
-- EXECUTE nemá" plyne „po migraci ho mít nebude" — bez spoléhání na repliku,
-- která granty funkcí stejně nepřenáší.
--
-- Tabulkové granty replika taky nekopíruje věrně — viz FIXTURA 0 výš, která
-- na to test zastaví. Sloupcové SELECT granty ale přenáší přesně (ověřeno
-- diffem proti produkci 14. 9. 2026, 7 sloupců shodně), takže 5c měřit LZE.
--
-- ČTENÍ a ZÁPIS drží každý JINÁ vrstva. Není to symetrické a plete se to:
--
--   `settings` má tabulkový grant `authenticated=awm` (INSERT, UPDATE, MAINTAIN)
--   a SELECT jen SLOUPCOVĚ, na sedmi sloupcích:
--       SELECT+UPDATE  id, singleton, opening_hours, updated_by, updated_at,
--                      email_notifications_enabled, email_max_za_hodinu   (7)
--       jen UPDATE     club_default_rate, commercial_default_rate,
--                      training_rate, tournament_rate, ledar_jmeno        (5) ← A2b
--       jen UPDATE     web_base_url                                       (1) ← nový
--
--   ČTENÍ  `web_base_url` drží GRANT — sloupcový SELECT tam prostě není.
--   ZÁPIS  `web_base_url` grant NEDRŽÍ. Tabulkové UPDATE se dědí na KAŽDÝ
--          sloupec včetně nově přidaného, takže `authenticated` na něj UPDATE
--          má. Zápis drží až RLS: politika `settings_update_admin`
--          (USING i WITH CHECK `has_role(auth.uid(),'admin')`).
--
-- ⚠️ TOHLE SI NEJDE OVĚŘIT NA REPLICE INTROSPEKCÍ, protože
-- `scripts/testovaci-replika.sh` granty `settings` NEKOPÍRUJE VĚRNĚ: produkční
-- tabulkový `authenticated=awm` rozpustí do per-sloupcových grantů, takže nově
-- přidaný sloupec na replice žádné UPDATE nezdědí. Napoprvé tu proto stálo
-- tvrzení „authenticated web_base_url ani NEPŘEPÍŠE" a bylo FALEŠNĚ ZELENÉ —
-- na produkci by neplatilo. Změřeno po srovnání grantů repliky na produkční tvar:
--     has_column_privilege(UPDATE, settings.web_base_url)   → t   (!)
--     has_column_privilege(SELECT, settings.web_base_url)   → f
-- Zápis se proto NEMĚŘÍ grantem, ale REÁLNÝM TOKENEM ve scénáři 5d níž
-- (CLAUDE.md, bod 3). Čtení grantem měřit lze — sloupcové SELECT granty
-- replika přenáší a produkce i replika dávají shodných 7 sloupců.
SELECT pg_temp.tvrd(
  NOT has_column_privilege('authenticated', 'public.settings', 'web_base_url', 'SELECT'),
  '5c) authenticated NEČTE settings.web_base_url (adresa jde ven jen v e-mailu)');

-- 5f) MECHANISMUS: CREATE OR REPLACE nesmí sáhnout na granty ani na SECURITY.
-- Kdyby na ně sahal (nebo kdyby to Postgres jednou změnil), mohla by kterákoli
-- příští migrace téhle funkce mlčky otevřít `email_sablona` roli `authenticated`
-- — a s ní cestu ke čtení `settings` mimo `settings_public`. Měří se to na
-- vlastní pokusné funkci, ať se nesahá na tu ostrou.
DO $$
DECLARE _acl_pred text; _acl_po text; _secdef_pred boolean; _secdef_po boolean; _vol_po "char";
BEGIN
  EXECUTE 'CREATE OR REPLACE FUNCTION pg_temp.pokusna() RETURNS int LANGUAGE sql IMMUTABLE AS $f$ SELECT 1 $f$';
  EXECUTE 'REVOKE ALL ON FUNCTION pg_temp.pokusna() FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION pg_temp.pokusna() TO service_role';
  SELECT p.proacl::text, p.prosecdef INTO _acl_pred, _secdef_pred
    FROM pg_proc p WHERE p.oid = 'pg_temp.pokusna()'::regprocedure;

  -- Táž změna, jakou dělá migrace: jen volatilita, nic o právech.
  EXECUTE 'CREATE OR REPLACE FUNCTION pg_temp.pokusna() RETURNS int LANGUAGE sql STABLE AS $f$ SELECT 1 $f$';
  SELECT p.proacl::text, p.prosecdef, p.provolatile INTO _acl_po, _secdef_po, _vol_po
    FROM pg_proc p WHERE p.oid = 'pg_temp.pokusna()'::regprocedure;

  PERFORM pg_temp.tvrd(
    _acl_pred IS NOT DISTINCT FROM _acl_po
    AND _secdef_pred IS NOT DISTINCT FROM _secdef_po
    AND _vol_po = 's',
    '5f) MECHANISMUS: CREATE OR REPLACE zachová granty i SECURITY a změní jen volatilitu');
END $$;
-- Bez protipólu by 5c bylo zelené i tehdy, kdyby `authenticated` ztratil práva
-- na settings úplně — tedy zelené z nudného důvodu, ne proto, že hranice drží.
SELECT pg_temp.tvrd(
  has_column_privilege('authenticated', 'public.settings', 'opening_hours', 'SELECT'),
  '5c2) PROTIPÓL: sloupcová SELECT práva na settings existují, takže 5c měří polaritu, ne prázdno');

-- 5d) ZÁPIS ADRESY: neadmin ji přepsat NESMÍ, admin ANO. Kdyby adresu směl
-- změnit kdokoli, přesměroval by si odkazy ve VŠECH notifikačních e-mailech
-- (`_web || '/calendar'`) na cizí doménu — z e-mailu systému by se stal phishing.
-- Měří se pod `SET LOCAL ROLE authenticated` s reálným tokenem; jako `postgres`
-- projde všechno, protože obchází granty i RLS.
CREATE OR REPLACE FUNCTION pg_temp.zmeni_adresu(_uziv uuid, _adresa text)
 RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE _n integer;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _uziv, 'role', 'authenticated')::text, true);
  UPDATE public.settings SET web_base_url = _adresa WHERE singleton;
  GET DIAGNOSTICS _n = ROW_COUNT;
  PERFORM set_config('role', 'none', true);
  RETURN _n > 0;                      -- RLS umí odmítnout i TIŠE (porušené USING)
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('role', 'none', true);
  IF SQLERRM LIKE '%row-level security%' OR SQLERRM LIKE '%permission denied%'
     OR SQLERRM LIKE '%zabezpečení na úrovni řádků%' THEN
    RETURN false;
  END IF;
  RAISE EXCEPTION 'UPDATE selhal z JINÉHO důvodu než kvůli bráně: %', SQLERRM;
END $$;

-- SAVEPOINT, ne BEGIN: celý tenhle soubor UŽ běží v jedné transakci, kterou
-- ukončuje ROLLBACK na konci. Vnořený `BEGIN` by Postgres jen ignoroval
-- s hláškou, ale `ROLLBACK` by ukončil TU VNĚJŠÍ — a s ní i dočasné schéma,
-- takže by další scénář spadl na „schema pg_temp does not exist". (Stalo se.)
-- Fixtura k 5d: bez ní by scénář mohl měřit účet, který nic neznamená.
SELECT pg_temp.tvrd(
  pg_temp.nejaky_admin() IS NOT NULL AND public.has_role(pg_temp.nejaky_admin(), 'admin'),
  'FIXTURA 5d) testovací admin se našel a admin opravdu JE');
SELECT pg_temp.tvrd(
  pg_temp.nejaky_neadmin() IS NOT NULL
  AND NOT public.has_role(pg_temp.nejaky_neadmin(), 'admin')
  AND EXISTS (SELECT 1 FROM public.user_roles ur WHERE ur.user_id = pg_temp.nejaky_neadmin()),
  'FIXTURA 5d) testovací neadmin se našel, MÁ roli, a admin NENÍ');

SAVEPOINT pred_5d;
SELECT pg_temp.tvrd(
  NOT pg_temp.zmeni_adresu(pg_temp.nejaky_neadmin(),
                           'https://podvrzeny-portal.curlingpromoostrava.cz'),
  '5d) NEADMIN adresu portálu NEPŘEPÍŠE (drží RLS settings_update_admin, ne grant)');
-- 5d2 shodí jedině brána, která odepře i ADMINA (např. `ALTER POLICY
-- settings_update_admin USING (false)`). Odebraný tabulkový UPDATE ho neshodí —
-- ten chytne dřív FIXTURA 0, která běží výš. (Upřesnění migrační brány.)
SELECT pg_temp.tvrd(
  pg_temp.zmeni_adresu(pg_temp.nejaky_admin(),
                       'https://portal.curlingpromoostrava.cz'),
  '5d2) PROTIPÓL: ADMIN adresu přepsat SMÍ (jinak by 5d měřilo jen rozbitý UPDATE)');
ROLLBACK TO SAVEPOINT pred_5d;         -- scénář 5d nesmí nechat adresu změněnou

-- ---------------------------------------------------------------------------
-- 6) Funkce NESMÍ být IMMUTABLE, když čte tabulku
-- ---------------------------------------------------------------------------
-- IMMUTABLE by byla lež plánovači — směl by si výsledek předpočítat a držet
-- napříč transakcemi, takže by se změna adresy nemusela projevit. Projeví se to
-- až za dlouho a nahodile, takže jinak než takhle se to chytit nedá.
SELECT pg_temp.tvrd(
  (SELECT provolatile FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'email_sablona') = 's',
  '6) email_sablona je STABLE, ne IMMUTABLE (nově čte tabulku)');

-- 6b) A ZŮSTÁVÁ SECURITY INVOKER. Na tomhle stojí celá úvaha „selhává zavřeně":
-- funkce nově čte `settings`, na které `authenticated` sloupcový SELECT nemá,
-- takže volání z API skončí na 42501 a NIC neprozradí. Jako DEFINER by běžela
-- pod vlastníkem (`postgres`) a hodnotu by vydala — z `email_sablona` by se
-- stala čtečka nastavení mimo `settings_public`.
--
-- Scénář 5f měří MECHANISMUS (že `CREATE OR REPLACE` na práva nesahá), ale
-- hodnotu na TÉHLE funkci netvrdil nikdo. Brána pro migrace to doložila:
--     ALTER FUNCTION public.email_sablona(…) SECURITY DEFINER;
--     → celá suita zůstala zelená, a přitom už `authenticated` tělo e-mailu
--       přečetl. Fail-closed byl pryč a nikdo by se to nedozvěděl.
SELECT pg_temp.tvrd(
  (SELECT NOT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'email_sablona' AND p.prokind = 'f'),
  '6b) email_sablona je SECURITY INVOKER (jako DEFINER by vydala nastavení komukoli)');

-- ---------------------------------------------------------------------------
-- 7) Obrana proti podvrženému odkazu drží i po změně základu
-- ---------------------------------------------------------------------------
-- Kontrola `_link` uvnitř funkce hlídá CESTU, nový CHECK hlídá ZÁKLAD. Jsou to
-- dvě různé poloviny odkazu a obě jsou potřeba — tenhle scénář měří tu první,
-- ať se při přepisu těla nevytratí.
--
-- ⚠️ ADRESA SE TU MUSÍ NASTAVIT ZNOVU. Protipóly 4l–4n adresu doopravdy ZMĚNÍ
-- (jejich smysl je, že poctivá hodnota projde), takže bez tohohle řádku měří
-- scénář 7 `a.b.curlingpromoostrava.cz` a je červený z důvodu, který s ním
-- nesouvisí.
-- Napoprvé se to přesně takhle stalo. Stav mezi scénáři prosakuje vždycky, když
-- se scénář nepostará sám o svůj vstup.
UPDATE public.settings SET web_base_url = 'https://portal.curlingpromoostrava.cz' WHERE singleton;
SELECT pg_temp.tvrd(
  (SELECT body FROM public.email_sablona('reservation_approved','x','y','.zly-web.cz/x'))
    LIKE '%https://portal.curlingpromoostrava.cz/calendar%',
  '7a) podvržená cesta spadne zpět na /calendar na NAŠÍ doméně');
SELECT pg_temp.tvrd(
  (SELECT body FROM public.email_sablona('reservation_approved','x','y','.zly-web.cz/x'))
    NOT LIKE '%zly-web%',
  '7b) cizí doména se do e-mailu nedostane');

ROLLBACK;
