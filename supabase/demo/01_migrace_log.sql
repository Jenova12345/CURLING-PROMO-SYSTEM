-- =============================================================================
-- EVIDENCE PROBĚHLÝCH MIGRACÍ
-- =============================================================================
-- Bez tohohle se nedá nasazovat inkrementálně. Devět z migrací v repu NENÍ
-- znovuspustitelných (`CREATE TYPE`, `ADD COLUMN` bez `IF NOT EXISTS`, změna
-- návratového typu funkce…), takže „pusť všechno znovu" skončí chybou a
-- v půlce. Jediná bezpečná cesta je pouštět jen to, co ještě neproběhlo — a to
-- vyžaduje vědět, co proběhlo.
--
-- PROČ VLASTNÍ TABULKA A NE `supabase_migrations.schema_migrations`:
-- tu plní Supabase CLI při `db push`. Na demo se ale SQL pouští ručně přes
-- dashboard, takže by tam nic nebylo a evidence by lhala. Tahle tabulka
-- odpovídá tomu, jak se sem doopravdy nasazuje.
--
-- KDY TO SPUSTIT
--   * jednorázově na demu, které vzniklo resetem (tehdy proběhly VŠECHNY
--     migrace v repu — proto se rovnou všechny zapíšou jako proběhlé)
--   * dál už se plní samo, z upgrade skriptu
--
-- Spouští se pod databázovou rolí (dashboard běží jako `postgres`).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.migrace_log (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now(),
  applied_by text        NOT NULL DEFAULT current_user,
  sha256     text
);

COMMENT ON TABLE public.migrace_log IS
  'Které migrace už na téhle databázi proběhly. Řídí se tím inkrementální nasazení (scripts/build-upgrade-sql.sh) — bez toho by se na živá data pouštěly migrace, které nejsou znovuspustitelné.';

-- Čte ji jen nasazovací skript pod databázovou rolí; aplikace do ní nemá co mluvit.
ALTER TABLE public.migrace_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.migrace_log FROM anon, authenticated, public;

-- -----------------------------------------------------------------------------
-- Seznam proběhlých migrací se sem NEPÍŠE ručně
--
-- Doplňuje ho `build-demo-sql.sh` hned za tenhle soubor, a to přesně o ty
-- migrace, které `demo_setup.sql` právě nasadil. Je to pravdivé z definice:
-- co reset pustil, to proběhlo.
--
-- Dřív tu byl ruční backfill s mezí („ber jako proběhlé všechno po verzi X").
-- Je pryč schválně: uvést mez o jednu moc znamená označit za proběhlou migraci,
-- která neproběhla — a upgrade ji pak TIŠE přeskočí. Odvozený seznam se splést
-- nemůže.
-- -----------------------------------------------------------------------------
