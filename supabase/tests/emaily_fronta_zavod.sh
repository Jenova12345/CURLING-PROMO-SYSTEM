#!/usr/bin/env bash
# =============================================================================
# ZÁVOD: dva odesílače e-mailů si nesmí vzít týž řádek fronty
#
# Než vzniklo `email_outbox_prevzit()`, četla edge funkce prostě
# `status = 'pending'` a hned posílala. Dva běhy (naplánovaný + ruční, nebo
# dva podle pomalého cronu) tedy přečetly touž dávku a KAŽDÝ ji poslal.
# Klub dostal dva stejné e-maily o jedné změně.
#
# ⚠️ Jedním spojením se to zahrát NEDÁ, a proto je tohle shell, ne `*_test.sql`.
# `supabase/tests/emaily_notifikaci_test.sql` běží v jedné transakci, takže
# `FOR UPDATE SKIP LOCKED` se tam nemá o co zaseknout — měří jen překlopení
# stavu. Druhá session by navíc nezakomitované řádky vůbec neviděla.
#
# Scénář:
#   A: BEGIN; email_outbox_prevzit(5)   …drží transakci otevřenou, řádky zamčené…
#   B: BEGIN; email_outbox_prevzit(5)   → MUSÍ dostat JINÝCH 5, ne tytéž
#   A: COMMIT
#   kontrola: žádný řádek nebyl převzatý dvakrát (attempts > 1)
#
# Bez `SKIP LOCKED` by B čekalo na zámek a po commitu A dostalo 0 (to je taky
# v pořádku), ale bez CELÉHO převzetí přes RPC (tedy při prostém
# `SELECT ... WHERE status='pending'`) dostane B tytéž řádky a test padne.
#
# Pouští se proti LOKÁLNÍMU Dockeru, nikdy proti cloudu.
# =============================================================================
set -uo pipefail

KONTEJNER="${KONTEJNER:-supabase_db_ltrazktulfxvzlvkxdsb}"
ZNACKA='ZÁVOD fronta e-mailů'
psql_() { docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

uklid() {
  psql_ -c "DELETE FROM public.email_outbox WHERE subject = '$ZNACKA';" >/dev/null 2>&1
}
trap uklid EXIT
uklid

# --- příprava: 10 čekajících e-mailů -----------------------------------------
psql_ <<SQL >/dev/null
INSERT INTO public.email_outbox (user_id, email, subject, body)
SELECT '55555555-5555-5555-5555-555555555555',
       'zavod'||g||'@test.local', '$ZNACKA', 'telo'
  FROM generate_series(1,10) g;
SQL

POTRUBI_A=$(mktemp -u); mkfifo "$POTRUBI_A"

# --- A: převezme 5 řádků a DRŽÍ transakci otevřenou ---------------------------
docker exec -i "$KONTEJNER" psql -U postgres -X -q -A -t <<SQL > /tmp/zavod_a.out &
BEGIN;
SELECT 'A:'||id FROM public.email_outbox_prevzit(5);
SELECT pg_sleep(3);
COMMIT;
SQL
A_PID=$!

sleep 1   # ať A stihne zamknout dřív, než se ptá B

# --- B: druhý běh ve stejnou chvíli ------------------------------------------
docker exec -i "$KONTEJNER" psql -U postgres -X -q -A -t <<SQL > /tmp/zavod_b.out
BEGIN;
SELECT 'B:'||id FROM public.email_outbox_prevzit(5);
COMMIT;
SQL

wait $A_PID
rm -f "$POTRUBI_A"

A_IDS=$(grep '^A:' /tmp/zavod_a.out | sed 's/^A://' | sort)
B_IDS=$(grep '^B:' /tmp/zavod_b.out | sed 's/^B://' | sort)
SPOLECNE=$(comm -12 <(echo "$A_IDS") <(echo "$B_IDS") | grep -c . || true)
DVAKRAT=$(psql_ -A -t -c "SELECT count(*) FROM public.email_outbox
                           WHERE subject = '$ZNACKA' AND attempts > 1;")

echo "A si vzalo: $(echo "$A_IDS" | grep -c .) řádků"
echo "B si vzalo: $(echo "$B_IDS" | grep -c .) řádků"
echo "společných řádků: $SPOLECNE   (musí být 0)"
echo "řádků převzatých víc než jednou: $DVAKRAT   (musí být 0)"

if [ "$SPOLECNE" -eq 0 ] && [ "$DVAKRAT" -eq 0 ] && [ "$(echo "$A_IDS" | grep -c .)" -gt 0 ]; then
  echo "=== ZÁVOD PROŠEL: žádný e-mail by neodešel dvakrát ==="
  exit 0
fi
echo "=== ZÁVOD SELHAL: týž řádek si vzaly oba běhy ==="
exit 1
