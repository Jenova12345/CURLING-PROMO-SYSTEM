#!/usr/bin/env bash
# =============================================================================
# build-upgrade-sql.sh — INKREMENTÁLNÍ nasazení, bez resetu schématu
# =============================================================================
# Vygeneruje `upgrade.sql`: všechny migrace z repu, každou obalenou tak, že se
# NEPUSTÍ, pokud už na cílové databázi proběhla (viz `public.migrace_log`).
#
# PROČ TOHLE EXISTUJE
# `build-demo-sql.sh` začíná resetem — smaže celé schéma `public` i účty. To bylo
# správně, dokud bylo demo prázdná ukázka. Jakmile mají kluby vlastní účty,
# registrace a rezervace, je reset ztráta dat: pojistka v `00_reset_demo.sql`
# hlídá jen to, jestli v databázi JE aspoň jeden testovací účet — a na betě
# testovací účty budou, takže by reset pustila a data klubů vzala s sebou.
#
# PROČ NESTAČÍ PUSTIT MIGRACE ZNOVU
# Devět z nich znovuspustitelných není (`CREATE TYPE`, `ADD COLUMN` bez
# `IF NOT EXISTS`, změna návratového typu funkce). Ověřeno spuštěním nad živými
# daty: 9 z 24 spadlo. Proto guard podle evidence, ne „ono to nějak projde".
#
# JAK JE UDĚLANÝ GUARD
# Každá migrace je vložená jako dollar-quoted literál a spuštěná přes
# `EXECUTE` uvnitř `DO` bloku, který se nejdřív podívá do `migrace_log`.
# Výsledek je JEDEN obyčejný SQL soubor bez psql meta-příkazů — projde
# i v dashboardu, kam se demo SQL pouští ručně.
#
# POUŽITÍ
#   ./scripts/build-upgrade-sql.sh    # → upgrade.sql
#
# PLÁN NASAZENÍ (rozhodnutí PM, 17. 8. 2026)
#   BETA:      jeden čistý `demo_setup.sql` — reset + všechny migrace + seed,
#              a ten SÁM ustaví migrační historii (`public.migrace_log`).
#   OD BETY:   už jen `upgrade.sql`. Žádný reset, takže reálné registrace klubů
#              a jejich rezervace nemá co smazat.
#
# Evidenci tedy nikdo neplní ručně a není kde udělat chybu v mezi: `demo_setup.sql`
# do ní zapíše přesně to, co sám nasadil.
# =============================================================================
set -euo pipefail

KOREN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KOREN"

MIGRACE=(supabase/migrations/*.sql)
VYSTUP="upgrade.sql"
LOG_SQL="supabase/demo/01_migrace_log.sql"

verze() { basename "$1" .sql; }

soucet() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

# --- generování upgrade.sql --------------------------------------------------
{
  cat <<'HLAVICKA'
-- =============================================================================
-- UPGRADE — inkrementální nasazení bez resetu schématu
-- =============================================================================
-- GENEROVANÝ SOUBOR. Needituj ho; uprav migraci a spusť scripts/build-upgrade-sql.sh.
--
-- Tenhle skript NIC NEMAŽE. Nepouští reset, nesahá na účty ani na data —
-- pustí jen ty migrace, které na téhle databázi ještě neproběhly, a zapíše si je.
-- Opakované spuštění je proto neškodné: podruhé nepustí nic.
--
-- PŘEDPOKLAD: `public.migrace_log` existuje (supabase/demo/01_migrace_log.sql).
-- Když chybí, skript se zastaví dřív, než cokoli udělá — protože bez evidence
-- by nepoznal, co už proběhlo, a pustil by i migrace, které se dvakrát pustit
-- nedají.
-- =============================================================================

DO $pojistka$
BEGIN
  IF to_regclass('public.migrace_log') IS NULL THEN
    RAISE EXCEPTION 'Chybí public.migrace_log — nejdřív pusť supabase/demo/01_migrace_log.sql.'
      USING HINT = 'Bez evidence proběhlých migrací nejde nasazovat inkrementálně.';
  END IF;
END $pojistka$;
HLAVICKA

  for m in "${MIGRACE[@]}"; do
    v="$(verze "$m")"
    znacka="telo_${v}"
    # Kolize značky by rozbila quotování a utnula migraci v půlce.
    if grep -q "\$${znacka}\$" "$m"; then
      echo "CHYBA: migrace $v obsahuje značku \$${znacka}\$ — zvol jinou." >&2
      exit 1
    fi
    cat <<HLAVA

-- -----------------------------------------------------------------------------
-- $v
-- -----------------------------------------------------------------------------
DO \$migrace_${v}\$
BEGIN
  IF EXISTS (SELECT 1 FROM public.migrace_log WHERE version = '$v') THEN
    RAISE NOTICE 'přeskakuji % (už proběhla)', '$v';
  ELSE
    EXECUTE \$${znacka}\$
HLAVA
    cat "$m"
    cat <<PATA
\$${znacka}\$;
    INSERT INTO public.migrace_log (version, sha256) VALUES ('$v', '$(soucet "$m")');
    RAISE NOTICE 'aplikováno %', '$v';
  END IF;
END \$migrace_${v}\$;
PATA
  done

  cat <<'PATICKA'

-- -----------------------------------------------------------------------------
-- Co je teď na databázi
-- -----------------------------------------------------------------------------
SELECT count(*) AS proběhlých_migrací, max(applied_at) AS naposledy FROM public.migrace_log;
PATICKA
} > "$VYSTUP"

echo "Vygenerováno: $VYSTUP ($(wc -l < "$VYSTUP") řádků, ${#MIGRACE[@]} migrací)"
echo "Reset se NEPOUŠTÍ — data zůstávají."
