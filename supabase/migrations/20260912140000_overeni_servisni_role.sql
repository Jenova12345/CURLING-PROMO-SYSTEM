-- =============================================================================
-- `moje_role()` — ověření volajícího podle ROLE, ne podle tvaru klíče
-- =============================================================================
-- KROK 0 (12. 9. 2026, čteno z živé produkce fcwubbytqxubgptftnru):
--
-- Edge funkce `send-emails` (a `invoice-pdf`, odkud je ten vzor převzatý)
-- ověřovala volajícího porovnáním ŘETĚZCŮ:
--
--     if (!auth.includes(Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'))) …
--
-- To vypadá jako kontrola role, ale je to kontrola jedné konkrétní hodnoty.
-- Produkce mezitím přešla na NOVOU GENERACI klíčů: ověřeno přes digesty
-- secrets, že `SUPABASE_ANON_KEY` vstřikovaný do funkcí je `sb_publishable_…`,
-- ne legacy JWT (digest je prostý sha256, potvrzeno na `SUPABASE_URL`).
-- Legacy `service_role` JWT tedy projde bránou platformy, ale tahle kontrola
-- ho odmítne — a naopak by kontrola mlčky přestala platit, kdyby se klíč
-- rotoval nebo kdyby Supabase přidal další generaci.
--
-- Prakticky: legitimní volání serveru bylo odmítnuté a nasazenou funkci
-- nešlo spustit ani z Dashboardu.
--
-- ŘEŠENÍ: nepočítat tvar klíče. Zeptat se databáze, KDO volá.
-- PostgREST už umí ověřit každou generaci klíčů, přeložit ji na databázovou
-- roli a odmítnout padělek. `moje_role()` jen vrátí, na koho se přepnul.
-- Edge funkce pak pustí dál jen `service_role`.
--
-- ⚠️ Proč to NENÍ díra: funkce vrací roli VOLAJÍCÍHO, tedy nic, co by volající
-- už nevěděl. Padělaný token se k PostgRESTu nedostane, takže `service_role`
-- z něj nikdy nevypadne. Přihlášený uživatel dostane 'authenticated',
-- i kdyby to byl admin — admin totiž NENÍ servisní role.
--
-- PROČ `current_user` A NE NĚCO JINÉHO (rozdíl, o který tu jde):
--   * `session_user` je pod PostgRESTem VŽDY `authenticator`, takže by všichni
--     volající vypadali stejně. Nepoužitelné.
--   * `auth.role()` čte `request.jwt.claims ->> 'role'`, tedy to, ZA KOHO SE
--     volající prohlašuje. A `request.jwt.claims` je zapisovatelný GUC:
--     podle bodu 8 CLAUDE.md mají `authenticated` i `anon` EXECUTE na
--     `set_config`. Bylo by to echo tvrzení, ne rozhodnutí Postgresu.
--   * `current_user` je role, na kterou PostgREST přepnul AŽ PO ověření
--     podpisu. To se z API podvrhnout nedá.
-- Test `overeni_servisni_role_test.sql` tenhle rozdíl měří přímo: podvrhne
-- claim `role=service_role` a tvrdí, že funkce pořád vrátí `authenticated`.
--
-- MUTAČNÍ ZKOUŠKA (ověřeno 12. 9. 2026, všechny mutace zčervenaly):
--   * tělo nahrazeno za `SELECT 'service_role'`      → test 1
--   * `session_user` místo `current_user`            → test 1
--   * `SECURITY DEFINER` místo `INVOKER`             → test 1 + sebekontrola
--   * čtení claimu místo `current_user`              → test 2 (podvržený claim)
--   * `GRANT ... TO anon`                            → test 3
--   * odebraný `GRANT` pro `service_role`            → test 3
--   * vrácené porovnání řetězce v edge funkci        → send_emails_auth_zavod.sh
--
-- VRATNOST: `DROP FUNCTION public.moje_role();` a vrácení předchozí verze
-- `send-emails`. Migrace nemění data ani schéma tabulek, jen přidává funkci.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.moje_role()
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY INVOKER          -- SCHVÁLNĚ invoker: ptáme se, pod kým dotaz běží
 SET search_path TO 'public'
AS $$
  SELECT current_user::text;
$$;

COMMENT ON FUNCTION public.moje_role() IS
  'Vrací databázovou roli volajícího (service_role / authenticated / anon). Edge funkce jí ověřují, že volá server, místo porovnávání tvaru klíče.';

-- `anon` grant nedostane. Ne proto, že by se k PostgRESTu nedostal (dostane
-- se úplně normálně), ale z nejmenších práv: nepotřebuje to.
--
-- DŮSLEDEK, KTERÝ MUSÍ EDGE FUNKCE ČEKAT: volání s publishable klíčem nevrátí
-- řetězec 'anon', ale CHYBU 42501. Ta se musí číst jako ODMÍTNUTÍ, ne jako
-- „nevím" — proto je v `send-emails` tvrdá podmínka `!error && data === ...`.
REVOKE ALL ON FUNCTION public.moje_role() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.moje_role() TO authenticated, service_role;

-- ---- Sebekontrola ----------------------------------------------------------
DO $$
DECLARE _r text;
BEGIN
  IF has_function_privilege('anon', 'public.moje_role()', 'EXECUTE') THEN
    RAISE EXCEPTION 'moje_role je dosažitelné pro anon.';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.moje_role()', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role na moje_role nedosáhne, odesílání by nešlo.';
  END IF;

  -- Pod rolí, ne jako postgres: jako postgres by vyšlo 'postgres' a test by
  -- netvrdil nic o tom, co uvidí API.
  SET LOCAL ROLE authenticated;
  SELECT public.moje_role() INTO _r;
  RESET ROLE;
  IF _r <> 'authenticated' THEN
    RAISE EXCEPTION 'moje_role nevrací roli volajícího (dostal jsem %).', _r;
  END IF;

  SET LOCAL ROLE service_role;
  SELECT public.moje_role() INTO _r;
  RESET ROLE;
  IF _r <> 'service_role' THEN
    RAISE EXCEPTION 'moje_role nepozná servisní roli (dostal jsem %).', _r;
  END IF;

  RAISE NOTICE 'moje_role(): ověření volajícího podle role je na místě.';
END $$;
