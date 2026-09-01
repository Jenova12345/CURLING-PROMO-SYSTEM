#!/usr/bin/env bash
# =============================================================================
# ZÁVOD: přecenění akce × zabrání rezervací pro doklad
#
# `over_neni_vyfakturovano()` je brána, která má zastavit úpravu akce, jejíž
# rezervace už jsou na dokladu. Byl to ale neuzamčený `SELECT count(*)`, kdežto
# `fakturoid_zkus_zabrat()` je INSERT do vazební tabulky — pod READ COMMITTED
# se míjejí. Brána nevidí nezakomitovaný claim, claim nevidí chystané přecenění,
# obojí commitne a rezervace skončí na jiné částce, než na kterou zní doklad.
# Nikomu se přitom nic nezobrazí.
#
# ⚠️ Jedním spojením se to zahrát NEDÁ — proto shell, ne `*_test.sql`. Scénář:
#   A: BEGIN; fakturoid_zkus_zabrat(...)      …drží transakci otevřenou…
#   B: BEGIN; uprav_sazbu_akce(...)           → MUSÍ se zablokovat na zámku
#   A: COMMIT  →  B se probudí, uvidí zabranou rezervaci a MUSÍ selhat
#
# Před opravou (20260901140000) B neblokovalo, prošlo a rozdíl byl 6 000 Kč.
#
# Pouští se proti LOKÁLNÍMU Dockeru, nikdy proti cloudu.
# =============================================================================
set -uo pipefail

KONTEJNER="${KONTEJNER:-supabase_db_ltrazktulfxvzlvkxdsb}"
NAZEV='ZÁVOD přecenění'
psql_() { docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

uklid() {
  psql_ -c "DELETE FROM public.fakturoid_invoice_reservations WHERE reservation_id IN
              (SELECT id FROM public.reservations WHERE note = '$NAZEV');
            DELETE FROM public.fakturoid_invoices WHERE idempotency_key LIKE 'zavod-%';
            DELETE FROM public.reservations WHERE note = '$NAZEV';
            DELETE FROM public.events WHERE title = '$NAZEV';" >/dev/null 2>&1
}
trap uklid EXIT
uklid

# --- příprava: komerční akce na 2 h, 1 dráha ---------------------------------
psql_ -v ON_ERROR_STOP=1 <<SQL >/dev/null
BEGIN;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
WITH e AS (
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('$NAZEV','commercial','2028-03-01 16:00+01','2028-03-01 18:00+01',
          '11111111-1111-1111-1111-111111111111') RETURNING id)
INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note, approved_at, approved_by)
SELECT (SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
       (SELECT id FROM public.subjects WHERE name='Demo Firma s.r.o.'),
       e.id, '2028-03-01 16:00+01','2028-03-01 18:00+01','$NAZEV', now(),
       '11111111-1111-1111-1111-111111111111'
  FROM e;
COMMIT;
SQL

EV=$(psql_ -A -t -c "SELECT id FROM public.events WHERE title='$NAZEV';")
REZ=$(psql_ -A -t -c "SELECT id FROM public.reservations WHERE note='$NAZEV';")
PRED=$(psql_ -A -t -c "SELECT amount FROM public.reservations WHERE note='$NAZEV';")
echo "  příprava: akce $EV, rezervace za $PRED Kč"

# --- A: zabere rezervaci pro doklad a DRŽÍ transakci otevřenou ---------------
#
# Transakci drží `pg_sleep` uvnitř téhož spojení, ne roura zvenčí. Roura se
# ukázala jako nespolehlivá — COMMIT se do psql nedostal včas, transakce se
# rozpadla a test pak měřil vlastní chybu místo závodu (claim nezakomitovaný,
# B legitimně prošlo). Tohle je deterministické: A drží zámek přesně 4 s
# a zakomituje se vždycky.
( docker exec -i "$KONTEJNER" psql -U postgres -X -q -A -t >/dev/null 2>&1 <<SQL
BEGIN;
SELECT public.fakturoid_zkus_zabrat('zavod-$EV','commercial_event',
  (SELECT id FROM public.subjects WHERE name='Demo Firma s.r.o.'),
  '$EV'::uuid, NULL, NULL, 2000, 1, 'koncept', ARRAY['$REZ']::uuid[]);
SELECT pg_sleep(4);
COMMIT;
SQL
) &
APID=$!
sleep 1   # ať A stihne zabrat a držet

# --- B: zkusí přecenit; musí se zaseknout na zámku a po commitu A selhat -----
VYSTUP_B="$(mktemp)"; CAS_B="$(mktemp)"
(
  Z=$(date +%s%N)
  docker exec -i "$KONTEJNER" psql -U postgres -X -q -A -t <<SQL >"$VYSTUP_B" 2>&1
BEGIN;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
SELECT public.uprav_sazbu_akce('$EV'::uuid, 4000);
COMMIT;
SQL
  echo $(( ($(date +%s%N) - Z) / 1000000 )) > "$CAS_B"
) &
BPID=$!
wait $APID 2>/dev/null
wait $BPID 2>/dev/null
CEKAL=$(cat "$CAS_B"); rm -f "$CAS_B"

PO=$(psql_ -A -t -c "SELECT amount FROM public.reservations WHERE note='$NAZEV';")
DOKLAD=$(psql_ -A -t -c "SELECT COALESCE(max(nas_soucet)::text,'—') FROM public.fakturoid_invoices WHERE idempotency_key='zavod-$EV';")
VAZEB=$(psql_ -A -t -c "SELECT count(*) FROM public.fakturoid_invoice_reservations WHERE reservation_id='$REZ';")

echo "  B čekalo na zámku: ${CEKAL} ms"
echo "  částka na rezervaci: $PRED → $PO   |   doklad: $DOKLAD   |   vazeb na doklad: $VAZEB"
echo "  odpověď B: $(tr -d '\n' < "$VYSTUP_B" | head -c 170)"

# 1) A se MUSEL zakomitovat, jinak test netestuje závod, ale vlastní chybu.
if [ "$VAZEB" != "1" ]; then
  echo "TEST NEPLATNÝ: claim se nezakomitoval (vazeb $VAZEB) — B se nemělo o co přetahovat."
  exit 2
fi
# 2) B muselo na zámku čekat; kdyby proletělo, zámek nefunguje.
if [ "$CEKAL" -lt 1500 ]; then
  echo "TEST SELHAL: B nečekalo na zámku (${CEKAL} ms, A držel zámek ~3 s) — cesty se míjejí jako před opravou."
  exit 1
fi
# 3) A částka se nesmí hnout.
if ! grep -qi "vystaveném dokladu" "$VYSTUP_B" 2>/dev/null && [ "$PRED" = "$PO" ]; then
  echo "POZOR: částka se nezměnila, ale B neselhalo na bráně — zkontroluj odpověď výš."
  exit 1
fi
if [ "$PRED" = "$PO" ]; then
  echo "OK  závod NEPROŠEL — B čekalo ${CEKAL} ms, pak bylo odmítnuto; doklad a rezervace sedí"
  exit 0
else
  echo "TEST SELHAL: rezervace přeceněna na $PO, ale doklad zní na $DOKLAD — tichý rozdíl"
  exit 1
fi
