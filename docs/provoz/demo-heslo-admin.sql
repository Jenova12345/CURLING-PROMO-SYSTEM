-- =============================================================================
-- DEMO: přenastavení hesla admina  (projekt ltrazktulfxvzlvkxdsb — curling-demo)
-- =============================================================================
-- Vlož celé do SQL editoru Supabase na DEMO projektu a spusť.
-- NE na produkci (fareavttiwkamrukpfqk).
--
-- Čisté SQL, žádné psql příkazy (`\set` apod.) — dashboard je neumí.
--
-- PROČ: všech pět demo účtů má heslo `Heslo1234` a to heslo je v repu
-- (supabase/seed.sql, řádek 26). E-maily jdou uhodnout — vedle `clen@test.local`
-- sedí `admin@test.local` — takže admin je otevřený komukoli, kdo tipne nebo se
-- podívá do repa. Admin vidí ceny a fakturaci.
--
-- CO SE STANE
--   1. admin dostane nové heslo
--   2. zruší se jeho běžící přihlášení — bez toho by kdokoli, kdo je zrovna
--      přihlášený jako admin, zůstal uvnitř i po změně hesla
--
-- ČEHO SE TO NEDOTKNE: účtů `clen@` a `clen2@`. Kluby se jimi dnes přihlašovaly
-- a změna hesla by je vyhodila uprostřed testování.
--
-- HESLO NÍŽ SI ZMĚŇ. Prošlo chatem, takže je v logu session.
-- =============================================================================

BEGIN;

-- Pojistka proti spuštění na ostré databázi.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'clen2@test.local') THEN
    RAISE EXCEPTION 'Tohle nevypadá na demo (chybí testovací účty) — zastavuji.';
  END IF;
END $$;

UPDATE auth.users
   SET encrypted_password = extensions.crypt('strela-metar-sweep-hog-24',
                                             extensions.gen_salt('bf', 10)),
       updated_at = now()
 WHERE email = 'admin@test.local';

-- Zrušení běžících přihlášení. Samotná změna hesla existující relaci neukončí:
-- kdo je uvnitř, zůstane uvnitř, dokud mu nevyprší token.
DELETE FROM auth.refresh_tokens
 WHERE user_id IN (SELECT id::text FROM auth.users WHERE email = 'admin@test.local');
DELETE FROM auth.sessions
 WHERE user_id IN (SELECT id FROM auth.users WHERE email = 'admin@test.local');

-- KONTROLA. Musí vyjít: nove_sedi = true, stare_jeste_funguje = false, zbyva_relaci = 0
SELECT u.email,
       u.encrypted_password = extensions.crypt('strela-metar-sweep-hog-24', u.encrypted_password) AS nove_sedi,
       u.encrypted_password = extensions.crypt('Heslo1234', u.encrypted_password)                 AS stare_jeste_funguje,
       (SELECT count(*) FROM auth.sessions s WHERE s.user_id = u.id)                              AS zbyva_relaci
  FROM auth.users u
 WHERE u.email = 'admin@test.local';

-- Sedí to? Spusť   COMMIT;
-- Nesedí?          ROLLBACK;
