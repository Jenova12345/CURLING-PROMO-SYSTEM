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
#   ./scripts/build-upgrade-sql.sh                        # → upgrade.sql
#   ./scripts/build-upgrade-sql.sh --backfill <verze>     # jednorázově, pro existující DB
#
# Mez u `--backfill` je povinná: říká, co na cílové databázi UŽ je. Označit za
# proběhlou migraci, která neproběhla, je tichá chyba (upgrade ji přeskočí);
# opačný omyl je hlučný (migrace spadne na obrazovku). Proto se neuhaduje.
#
# POŘADÍ NA NOVÉM PROSTŘEDÍ
#   1) supabase/demo/01_migrace_log.sql   (jednorázově; zapíše, co už proběhlo)
#   2) upgrade.sql                        (a pak už jen tohle, při každém nasazení)
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

# --- režim --backfill: zapiš do 01_migrace_log.sql, co se má brát jako proběhlé -
if [[ "${1:-}" == "--backfill" ]]; then
  # Mez je POVINNÁ a je to bezpečnostní prvek, ne pohodlí.
  #
  # Zapsat jako „proběhlou" migraci, která na cílové databázi neproběhla, je
  # tichá chyba: upgrade ji přeskočí a schéma se rozejde, aniž by se kdokoli
  # dozvěděl. Opačný omyl (zapomenutá mez → migrace se zkusí pustit znovu)
  # je hlučný: buď projde, nebo spadne na obrazovku. Proto se mez neuhaduje.
  MEZ="${2:-}"
  if [[ -z "$MEZ" ]]; then
    echo "Použití: $0 --backfill <verze-poslední-migrace-na-cílové-DB>" >&2
    echo "" >&2
    echo "Dostupné verze:" >&2
    for m in "${MIGRACE[@]}"; do echo "  $(verze "$m")" >&2; done
    echo "" >&2
    echo "Zjistíš ji na cílové databázi, ne odhadem — např. podle toho, co tam" >&2
    echo "existuje (poslední nasazení), nebo z historie nasazení." >&2
    exit 1
  fi
  if [[ ! -f "supabase/migrations/${MEZ}.sql" ]]; then
    echo "CHYBA: migrace '$MEZ' v repu není." >&2
    exit 1
  fi

  RADKY=""
  for m in "${MIGRACE[@]}"; do
    v="$(verze "$m")"
    # Lexikografické porovnání stačí: názvy začínají časovým razítkem RRRRMMDDhhmmss.
    [[ "$v" > "$MEZ" ]] && continue
    RADKY+="INSERT INTO public.migrace_log (version, sha256) VALUES ('$v', '$(soucet "$m")')"$'\n'
    RADKY+="  ON CONFLICT (version) DO NOTHING;"$'\n'
  done
  python3 - "$LOG_SQL" <<PY
import sys, io
cesta = sys.argv[1]
s = io.open(cesta, encoding='utf-8').read()
zac = s.index('-- BACKFILL-ZACATEK')
kon = s.index('-- BACKFILL-KONEC')
novy = s[:zac] + '-- BACKFILL-ZACATEK (generované — needituj ručně)\n' + """$RADKY""" + s[kon:]
io.open(cesta, 'w', encoding='utf-8').write(novy)
PY
  echo "Backfill doplněn do $LOG_SQL — jako proběhlé označeny migrace až po $MEZ (včetně)."
  exit 0
fi

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
