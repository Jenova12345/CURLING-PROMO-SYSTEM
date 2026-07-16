-- =============================================================================
-- Migrace: trigger handle_new_user na auth.users
-- =============================================================================
-- Funkce public.handle_new_user() je součástí baseline (20260715000000) — zakládá
-- profil + výchozí roli hobby_player. Trigger na auth.users ale v baseline NENÍ, protože
-- auth.users je mimo schéma public a v produkci trigger vznikl ručně (viz docs/SCHEMA_DRIFT.md).
--
-- Tato migrace ho doplňuje, aby čistá obnova (supabase db reset, lokál/staging) měla
-- funkční registraci i přihlášení. Je IDEMPOTENTNÍ (DROP IF EXISTS + CREATE), takže je
-- bezpečná i kdyby se kdy pouštěla proti produkci, kde trigger už existuje.
-- =============================================================================

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
