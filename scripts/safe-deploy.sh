#!/usr/bin/env bash
#
# safe-deploy.sh — čerstvá záloha produkce, pak teprve migrace.
#
# Proč skript a ne „udělej to ručně": ruční postup se dodrží, dokud někdo
# nespěchá. Tenhle skript nemá cestu, jak zálohu přeskočit — když dump selže
# nebo vyjde podezřele malý, `db push` se vůbec nespustí.
#
# Použití:
#   scripts/safe-deploy.sh <popisek>      # záloha + migrace
#   scripts/safe-deploy.sh <popisek> --jen-zaloha
#
#   <popisek> je krátký důvod, kvůli kterému zálohujeme — objeví se v názvu
#   složky (backups/prod-RRRR-MM-DD-<popisek>/), takže se v seznamu záloh dá
#   poznat, PŘED čím která vznikla.
#
# Heslo bere z `.env.local` (SUPABASE_DB_PASSWORD). Nikdy ho nevypisuje
# a nepředává na příkazové řádce — jen přes proměnnou prostředí PGPASSWORD.
set -euo pipefail

cd "$(dirname "$0")/.."

POPISEK="${1:-}"
if [ -z "$POPISEK" ]; then
  echo "Chybí popisek. Např.: scripts/safe-deploy.sh pred-fakturoidem" >&2
  exit 1
fi
JEN_ZALOHA="${2:-}"

# ---- 1) Kam to vlastně poletí -----------------------------------------------
# `db push` míří na NALINKOVANÝ projekt, ne na to, co je v config.toml.
# Link žije v supabase/.temp/ (gitignorováno), takže po čerstvém klonu tam nic
# není. Proto se na něj ptáme, ne hádáme — a vypíšeme ho, ať to člověk vidí,
# než odklepne.
LINK_FILE=supabase/.temp/linked-project.json
if [ ! -f "$LINK_FILE" ]; then
  echo "❌ Není nalinkovaný žádný projekt ($LINK_FILE chybí)." >&2
  echo "   Zastavuji — nasazovat naslepo se nebude." >&2
  exit 1
fi
REF=$(python3 -c "import json,sys; print(json.load(open('$LINK_FILE'))['ref'])")
NAZEV=$(python3 -c "import json,sys; print(json.load(open('$LINK_FILE'))['name'])")
echo "── CÍL ────────────────────────────────────────────────"
echo "   projekt: $NAZEV  ($REF)"
[ "$REF" = "fcwubbytqxubgptftnru" ] && echo "   ⚠ TOHLE JE OSTRÁ PRODUKCE — platí docs/PRODUKCE-PRAVIDLA.md"
echo

# ---- 2) Heslo ---------------------------------------------------------------
if [ ! -f .env.local ]; then
  echo "❌ Chybí .env.local (a v něm SUPABASE_DB_PASSWORD)." >&2; exit 1
fi
# `tr -d` sundá uvozovky, kdyby někdo heslo v .env.local zapsal jako "…" nebo '…'.
HESLO=$(grep -E '^SUPABASE_DB_PASSWORD=' .env.local | head -1 | cut -d= -f2- | tr -d "\"'")
if [ -z "$HESLO" ]; then
  echo "❌ SUPABASE_DB_PASSWORD není v .env.local vyplněné." >&2; exit 1
fi

# ---- 3) Čerstvý dump --------------------------------------------------------
DEN=$(date +%F); CAS=$(date +%H%M)
SLOZKA="backups/prod-${DEN}-${POPISEK}"
mkdir -p "$SLOZKA"
DUMP="${SLOZKA}/prod_full_${DEN}_${CAS}.sql"

echo "── ZÁLOHA ─────────────────────────────────────────────"
echo "   → $DUMP"
# Kde vzít pg_dump. Na téhle mašině není na PATH; verze SE MUSÍ SHODOVAT
# s produkcí (17.x), jinak pg_dump odmítne dumpovat novější server. Kontejner
# lokálního Supabase má přesně tu správnou — proto ta oklika.
DUMP_CMD=""
if command -v pg_dump >/dev/null 2>&1 && pg_dump --version | grep -qE ' 1[7-9]\.'; then
  DUMP_CMD="local"
else
  KONTEJNER=$(docker ps --filter "name=supabase_db_" --format '{{.Names}}' | head -1)
  if [ -n "$KONTEJNER" ]; then
    DUMP_CMD="docker"
    echo "   (pg_dump beru z kontejneru $KONTEJNER — na PATH není)"
  else
    echo "❌ Není odkud vzít pg_dump 17.x: není na PATH a neběží ani lokální" >&2
    echo "   Supabase (\`supabase start\`). Zastavuji, zálohu nemám čím udělat." >&2
    exit 1
  fi
fi

# Pooler, ne přímé spojení: přímý host produkce je jen přes IPv6.
if [ "$DUMP_CMD" = "local" ]; then
  PGPASSWORD="$HESLO" pg_dump \
    -h aws-1-eu-west-1.pooler.supabase.com -p 5432 \
    -U "postgres.${REF}" -d postgres \
    --no-owner --no-privileges > "$DUMP"
else
  # Heslo jde do kontejneru přes -e, ne v příkazové řádce (byla by v `ps`).
  docker exec -e PGPASSWORD="$HESLO" "$KONTEJNER" pg_dump \
    -h aws-1-eu-west-1.pooler.supabase.com -p 5432 \
    -U "postgres.${REF}" -d postgres \
    --no-owner --no-privileges > "$DUMP"
fi

# Dump, který spadl v půlce, končí bez závěrečné hlášky. Kontrolujeme velikost
# I ten konec — prázdný soubor pozná každý, ale useknutý v 90 % vypadá zdravě.
VELIKOST=$(wc -c < "$DUMP" | tr -d ' ')
echo "   velikost: $VELIKOST B"
if [ "$VELIKOST" -lt 100000 ]; then
  echo "❌ Dump je podezřele malý (< 100 kB). Zastavuji, migrace se nespustí." >&2
  exit 1
fi
if ! tail -5 "$DUMP" | grep -q "PostgreSQL database dump complete"; then
  echo "❌ Dump nekončí hláškou o dokončení — je useknutý. Zastavuji." >&2
  exit 1
fi
echo "   ✓ záloha vypadá celistvě"
echo

if [ "$JEN_ZALOHA" = "--jen-zaloha" ]; then
  echo "Hotovo (jen záloha, migrace se nepouštěla)."
  exit 0
fi

# ---- 4) Migrace -------------------------------------------------------------
# Dopředně, po jedné, bez resetu. `db reset --linked` se tu neobjeví nikdy —
# na ostré produkci by to smazalo klientova data.
echo "── MIGRACE ────────────────────────────────────────────"
SUPABASE_DB_PASSWORD="$HESLO" supabase db push

echo
echo "✓ Nasazeno. Záloha zůstává v $DUMP"
echo "  Nezapomeň ověřit: billing_reconcile = 0 a reálným tokenem, že aktivním"
echo "  účtům nic nezmizelo."
