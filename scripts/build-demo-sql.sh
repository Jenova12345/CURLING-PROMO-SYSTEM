#!/usr/bin/env bash
# =============================================================================
# Vygeneruje demo_setup.sql = všechny migrace v pořadí + demo seed.
# =============================================================================
# Soubor se pouští RUČNĚ v SQL editoru DEMO projektu (ltrazktulfxvzlvkxdsb).
# NIKDY na produkci (fareavttiwkamrukpfqk).
#
# Použití:  ./scripts/build-demo-sql.sh
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
# Za touhle migrací musí skončit transakce (nová hodnota enumu)
ENUM_MIGRATION="20260731100000_event_type_tournament.sql"

{
  cat <<'HEADER'
-- ==============================================================================
-- demo_setup.sql — JEDNORÁZOVÉ NASAZENÍ DEMO (Supabase SQL Editor, běží jako postgres)
-- Konkatenace všech migrací + demo seed.
-- Spustit VÝHRADNĚ na DEMO projektu ltrazktulfxvzlvkxdsb. NE na produkci!
-- Vygenerováno skriptem scripts/build-demo-sql.sh — needitovat ručně,
-- uprav zdrojové migrace/seed a skript pusť znovu.
-- ==============================================================================

BEGIN;
HEADER

  for file in "$MIGRATIONS_DIR"/*.sql; do
    name="$(basename "$file")"
    printf '\n-- ##########################################################################\n'
    printf -- '-- ## %s\n' "$name"
    printf -- '-- ##########################################################################\n\n'
    cat "$file"
    if [ "$name" = "$ENUM_MIGRATION" ]; then
      printf '\n-- Nová hodnota enumu musí být potvrzená dřív, než ji začne kdokoli používat.\nCOMMIT;\nBEGIN;\n'
    fi
  done

  printf '\n-- ##########################################################################\n'
  printf -- '-- ## seed.sql (fiktivní demo data)\n'
  printf -- '-- ##########################################################################\n\n'
  cat "$SEED"

  printf '\nCOMMIT;\n'
} > "$OUT"

echo "Hotovo: $OUT ($(wc -l < "$OUT" | tr -d ' ') řádků)"
echo "Spustit ručně v SQL editoru DEMO projektu (ltrazktulfxvzlvkxdsb) — NE na produkci."
