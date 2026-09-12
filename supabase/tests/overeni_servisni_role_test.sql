-- =============================================================================
-- TESTY: `moje_role()` (migrace 20260912140000_overeni_servisni_role.sql)
-- =============================================================================
-- Edge funkce jí ověřují, že volá SERVER, místo aby porovnávaly tvar klíče.
-- Nejcennější tvrzení je to, že ADMIN tudy neprojde: admin je mocný uživatel,
-- ale pořád jen uživatel, a fronta e-mailů obsahuje adresy všech.
--
-- Všechno se měří POD ROLÍ (CLAUDE.md pravidlo 9). Jako `postgres` by vyšlo
-- 'postgres' a test by netvrdil nic o tom, co uvidí API.
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

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: funkce vrací roli VOLAJÍCÍHO
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r text;
BEGIN
  SET LOCAL ROLE service_role;
  SELECT public.moje_role() INTO _r;
  RESET ROLE;
  PERFORM pg_temp.tvrd(_r = 'service_role',
    'JÁDRO: servisní role se pozná jako `service_role`');

  SET LOCAL ROLE authenticated;
  SELECT public.moje_role() INTO _r;
  RESET ROLE;
  PERFORM pg_temp.tvrd(_r = 'authenticated',
    'JÁDRO: přihlášený uživatel dostane `authenticated`, ne `service_role`');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: uživatel, který se VYDÁVÁ za server, neprojde
-- -----------------------------------------------------------------------------
-- Tohle je tvrzení, kvůli kterému ten soubor existuje, a první verze ho
-- neměřila: nastavovala claim na `authenticated`, tedy shodně s už nastavenou
-- rolí, takže `_r <> 'service_role'` byla tautologie a prošla by i tehdy,
-- kdyby funkce claim četla.
--
-- Poctivý scénář je opačný: claim LŽE, že volající je servisní role.
-- Chytá to mutaci, která přežila všechno ostatní:
--     SELECT coalesce(nullif(current_setting('request.jwt.claims', true)::json->>'role',''), current_user::text)
-- Taková funkce by přestala vracet, KÝM volající je, a začala vracet,
-- ZA KOHO SE PROHLAŠUJE. A `request.jwt.claims` je zapisovatelný GUC.
DO $$
DECLARE _r text;
BEGIN
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"service_role"}';
  SELECT public.moje_role() INTO _r;
  RESET ROLE;

  PERFORM pg_temp.tvrd(_r = 'authenticated',
    'JÁDRO: podvržený claim role=service_role funkci neobelstí');
END $$;

-- Totéž pro admina. Admin smí v systému skoro všechno a frontu e-mailů i vidí,
-- ale vyprazdňovat ji nesmí: je to adresář všech uživatelů a servisní klíč
-- obchází RLS. Kontrola předpokladu běží ZÁMĚRNĚ mimo SET ROLE (ptá se na seed).
DO $$
DECLARE _r text;
BEGIN
  PERFORM pg_temp.tvrd(
    public.has_role('11111111-1111-1111-1111-111111111111', 'admin'),
    'kontrola předpokladu: 11111111 opravdu JE admin');

  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
  SELECT public.moje_role() INTO _r;
  RESET ROLE;
  RESET request.jwt.claims;      -- ať neprotéká do dalších scénářů

  PERFORM pg_temp.tvrd(_r = 'authenticated',
    'JÁDRO: ADMIN dostane `authenticated`, ne `service_role`');
END $$;

-- Funkce nesmí JWT claim číst vůbec. Tvrzení je zvlášť, aby bylo vidět,
-- že je to vlastnost, ne vedlejší efekt.
DO $$
DECLARE _r text;
BEGIN
  SET LOCAL ROLE service_role;
  SET LOCAL request.jwt.claims = '{"role":"anon"}';   -- claim lže opačným směrem
  SELECT public.moje_role() INTO _r;
  RESET ROLE;
  RESET request.jwt.claims;

  PERFORM pg_temp.tvrd(_r = 'service_role',
    'JÁDRO: funkce claim ignoruje i když lže v neprospěch volajícího');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO: `anon` na funkci vůbec nedosáhne
-- -----------------------------------------------------------------------------
DO $$
DECLARE _pusteno boolean := false;
BEGIN
  SET LOCAL ROLE anon;
  BEGIN
    PERFORM public.moje_role();
    _pusteno := true;
  EXCEPTION WHEN insufficient_privilege OR sqlstate '42501' THEN
    _pusteno := false;
  END;
  RESET ROLE;
  PERFORM pg_temp.tvrd(NOT _pusteno, 'JÁDRO: `anon` na moje_role() nedosáhne');
END $$;

DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.moje_role()', 'EXECUTE'),
    'grant pro `anon` neexistuje');
  PERFORM pg_temp.tvrd(
    has_function_privilege('service_role', 'public.moje_role()', 'EXECUTE'),
    'servisní role na funkci dosáhne (jinak by odesílání nešlo)');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
