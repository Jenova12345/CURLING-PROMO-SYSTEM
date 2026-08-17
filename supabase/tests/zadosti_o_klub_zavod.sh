#!/usr/bin/env bash
# =============================================================================
# Závod dvou soubězných žádostí o klub
#
# Kontrola „jedna žádost už čeká" uvnitř `request_subject_membership` je TOCTOU:
# mezi dotazem a INSERTem se vejde druhé odeslání formuláře. Poslední obranu
# proto drží partial unique index — a ten musí vyjít ven jako česká věta, ne
# jako „duplicate key value violates unique constraint …".
#
# Jedním spojením se to zahrát nedá (kontrola i index hlídají tutéž podmínku,
# takže sériově se na index nikdy nedojde). Scénář je tedy dvouspojkový:
#
#   A: BEGIN; INSERT čekající žádost; …drží otevřenou transakci…
#   B: zavolá RPC — jeho kontrola řádek z A NEVIDÍ (read committed), projde,
#      a zasekne se až na indexu, dokud A nekomitne
#   A: COMMIT  →  B dostane unique_violation  →  handler ho přeloží
#
# Pouští se proti LOKÁLNÍMU Dockeru, nikdy proti cloudu.
# =============================================================================
set -uo pipefail

KONTEJNER="${KONTEJNER:-supabase_db_ltrazktulfxvzlvkxdsb}"
UZIVATEL='33333333-3333-3333-3333-333333333333'
PRIPOJENI=(docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1)

psql_() { "${PRIPOJENI[@]}" "$@"; }

uklid() {
  psql_ -c "DELETE FROM public.subject_requests WHERE user_id = '$UZIVATEL';" >/dev/null 2>&1
  rm -f "$ROURA_A"
}

ROURA_A="$(mktemp -u)"; mkfifo "$ROURA_A"
trap uklid EXIT

KLUB=$(psql_ -tAc "SELECT id FROM public.clubs_public
                    WHERE id NOT IN (SELECT subject_id FROM public.subject_reps WHERE user_id = '$UZIVATEL')
                    ORDER BY name LIMIT 1")
if [[ -z "$KLUB" ]]; then
  echo "PŘESKOČENO: uživatel $UZIVATEL je členem všech klubů, závod nemá kde proběhnout" >&2
  exit 0
fi

psql_ -c "DELETE FROM public.subject_requests WHERE user_id = '$UZIVATEL';" >/dev/null

# --- Spojení A: založí čekající žádost a drží ji nezakomitovanou ---------------
psql_ -f - < "$ROURA_A" >/dev/null 2>&1 &
A_PID=$!
exec 3>"$ROURA_A"
cat >&3 <<SQL
BEGIN;
INSERT INTO public.subject_requests (user_id, subject_id, status)
VALUES ('$UZIVATEL', '$KLUB', 'ceka');
SELECT pg_sleep(0.3);
SQL

sleep 0.6   # ať A stihne řádek zapsat dřív, než se B zeptá

# --- Spojení B: projde kontrolou (řádek A ještě nevidí) a zasekne se na indexu -
VYSTUP_B=$(mktemp)
(
  "${PRIPOJENI[@]}" >"$VYSTUP_B" 2>&1 <<SQL
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"$UZIVATEL"}', false);
SELECT public.request_subject_membership('$KLUB');
SQL
) &
B_PID=$!

sleep 0.8   # B už musí viset na zámku indexu
echo "COMMIT;" >&3    # A dokomituje → B se probudí a spadne na indexu
exec 3>&-
wait "$A_PID" 2>/dev/null
wait "$B_PID" 2>/dev/null

HLASKA=$(cat "$VYSTUP_B"); rm -f "$VYSTUP_B"

if grep -q "Jedna žádost už čeká na vyřízení" <<<"$HLASKA"; then
  echo "OK  závod: druhý žadatel dostal českou hlášku"
elif grep -qi "duplicate key value\|idx_subject_requests_jedna_cekajici" <<<"$HLASKA"; then
  echo "TEST SELHAL: ven prosákla syrová hláška databáze místo české věty:" >&2
  echo "$HLASKA" >&2
  exit 1
else
  # Ani jedno — nejspíš se závod nezahrál (časování), a to je taky selhání:
  # test, který si mlčení vyloží jako úspěch, nehlídá nic.
  echo "TEST SELHAL: závod se nezahrál, čekal jsem chybu z indexu. Výstup B:" >&2
  echo "$HLASKA" >&2
  exit 1
fi
