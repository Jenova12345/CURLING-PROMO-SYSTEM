#!/usr/bin/env bash
# =============================================================================
# Vygeneruje demo_setup.sql = reset demo DB + všechny migrace v pořadí + demo seed.
# =============================================================================
# Soubor se pouští RUČNĚ v SQL editoru DEMO projektu (ltrazktulfxvzlvkxdsb).
# NIKDY na produkci (fareavttiwkamrukpfqk) — začíná smazáním schématu public.
#
# Použití:  ./scripts/build-demo-sql.sh
#
# Skript je RE-RUNNABLE: začíná resetem (supabase/demo/00_reset_demo.sql), takže
# ho jde pouštět opakovaně i nad neprázdnou demo databází. Pojistka uvnitř resetu
# zastaví běh, pokud databáze vypadá jako ostrá (uživatelé bez testovacích účtů).
#
# Pozor na jednu zvláštnost: migrace 20260731100000_event_type_tournament.sql
# přidává hodnotu do enumu a Postgres ji nedovolí použít ve stejné transakci.
# Generátor za ni proto vloží explicitní COMMIT — bez toho by demo skript spadl
# na prvním použití typu 'tournament'.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="demo_setup.sql"
MIGRATIONS_DIR="supabase/migrations"
SEED="supabase/seed.sql"
RESET="supabase/demo/00_reset_demo.sql"
FINALIZE="supabase/demo/99_finalize_demo.sql"
# Za touhle migrací musí skončit transakce (nová hodnota enumu)
ENUM_MIGRATION="20260731100000_event_type_tournament.sql"

part() {
  printf '\n-- ##########################################################################\n'
  printf -- '-- ## %s\n' "$1"
  printf -- '-- ##########################################################################\n\n'
}

{
  cat <<'HEADER'
-- ==============================================================================
-- demo_setup.sql — NASAZENÍ DEMA (Supabase SQL Editor, běží jako postgres)
-- Reset demo databáze + všechny migrace + demo seed.
-- Spustit VÝHRADNĚ na DEMO projektu ltrazktulfxvzlvkxdsb. NE na produkci!
--
-- ⚠️ ZAČÍNÁ SMAZÁNÍM SCHÉMATU public — všechna data v demu se přepíšou načisto.
-- Skript jde díky tomu pouštět opakovaně. Pojistka na začátku zastaví běh, pokud
-- databáze vypadá jako ostrá (má uživatele, ale žádný testovací účet @test.local).
--
-- Vygenerováno skriptem scripts/build-demo-sql.sh — needitovat ručně,
-- uprav zdrojové soubory (supabase/demo, supabase/migrations, supabase/seed.sql)
-- a skript pusť znovu.
-- ==============================================================================

BEGIN;
HEADER

  part "$(basename "$RESET") — reset demo databáze"
  cat "$RESET"

  for file in "$MIGRATIONS_DIR"/*.sql; do
    name="$(basename "$file")"
    part "$name"
    cat "$file"
    if [ "$name" = "$ENUM_MIGRATION" ]; then
      printf '\n-- Nová hodnota enumu musí být potvrzená dřív, než ji začne kdokoli používat.\nCOMMIT;\nBEGIN;\n'
    fi
  done

  part "seed.sql (fiktivní demo data)"
  cat "$SEED"

  part "$(basename "$FINALIZE") — dokončení dema"
  cat "$FINALIZE"

  printf '\nCOMMIT;\n'
} > "$OUT"

echo "Hotovo: $OUT ($(wc -l < "$OUT" | tr -d ' ') řádků)"
echo "Spustit ručně v SQL editoru DEMO projektu (ltrazktulfxvzlvkxdsb) — NE na produkci."
