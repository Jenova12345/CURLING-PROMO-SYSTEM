-- =============================================================================
-- RESET DEMO DATABÁZE — spouští se jako první část demo_setup.sql
-- =============================================================================
-- ⚠️ TENHLE SKRIPT SMAŽE CELÉ SCHÉMA public (všechna data i strukturu) a testovací
-- účty v auth.users. Je určený VÝHRADNĚ pro DEMO projekt (ltrazktulfxvzlvkxdsb),
-- aby šel demo_setup.sql pouštět opakovaně nad neprázdnou databází.
--
-- NA PRODUKCI (fareavttiwkamrukpfqk) HO NIKDY NESPOUŠTĚJ.
--
-- Pojistka níž se o to pokouší i technicky: pokud databáze obsahuje uživatele,
-- ale ani jeden testovací účet @test.local, skript se zastaví dřív, než něco smaže.
-- Prázdná databáze (nový projekt) projde — není co ztratit.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) POJISTKA proti spuštění na ostré databázi
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _vsichni int;
  _testovaci int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE email LIKE '%@test.local')
    INTO _vsichni, _testovaci
    FROM auth.users;

  IF _vsichni > 0 AND _testovaci = 0 THEN
    RAISE EXCEPTION
      'POJISTKA: tohle nevypadá na demo databázi — je v ní % uživatelů a ani jeden testovací účet @test.local. Skript maže celé schéma public, takže se zastavuje. Na produkci ho nepouštěj.',
      _vsichni;
  END IF;

  RAISE NOTICE 'Pojistka OK: % uživatelů, z toho % testovacích — pokračuji resetem.', _vsichni, _testovaci;
END $$;

-- -----------------------------------------------------------------------------
-- 2) Testovací účty v auth.* (schéma public je smazané níž, tohle je mimo něj)
-- -----------------------------------------------------------------------------
-- Seed je zakládá s pevnými UUID, takže bez smazání by opakované spuštění spadlo
-- na duplicitním klíči. Ostatní účty (např. ty, co si v demu někdo založil sám)
-- zůstávají — profil se jim doplní na konci skriptu.
DELETE FROM auth.identities WHERE provider_id IN (
  SELECT id::text FROM auth.users WHERE email LIKE '%@test.local'
);
DELETE FROM auth.users WHERE email LIKE '%@test.local';

-- -----------------------------------------------------------------------------
-- 3) Celé schéma public načisto
-- -----------------------------------------------------------------------------
-- CASCADE smaže i trigger on_auth_user_created na auth.users (závisí na funkci
-- public.handle_new_user) — migrace 20260716120000 ho zase vytvoří.
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

-- Obnovit to, co k public v Supabase patří: vlastníka, práva rolí a výchozí práva
-- pro nově vzniklé objekty. Bez toho by web (role anon/authenticated) neviděl nic.
ALTER SCHEMA public OWNER TO pg_database_owner;
COMMENT ON SCHEMA public IS 'standard public schema';

GRANT USAGE  ON SCHEMA public TO public;
GRANT USAGE  ON SCHEMA public TO postgres, anon, authenticated, service_role;
GRANT CREATE ON SCHEMA public TO postgres;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;

-- Totéž pro objekty, které založí supabase_admin (interní úlohy Supabase).
-- Když na to postgres nemá právo, nevadí — necháme to plavat, ne spadnout.
DO $$
BEGIN
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
    GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public
    GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'Výchozí práva pro supabase_admin se nastavit nepodařilo (chybí oprávnění) — přeskakuji.';
END $$;
