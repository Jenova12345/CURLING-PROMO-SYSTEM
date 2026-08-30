#!/usr/bin/env bash
# =============================================================================
# Závod dvou soubězných úprav téže akce
#
# `dorovnej_stab` si nebere zámek nad `shifts` — spočítá, kolik směn je, a podle
# toho doplňuje. Napsané naivně by to znamenalo, že dva adminové upravující touž
# akci naráz založí štáb DVAKRÁT: oba by v `existujici` viděli původní počet.
#
# Že se to nestane, drží ZÁMEK NA ŘÁDKU AKCE, ne nic uvnitř funkce. Oba
# `UPDATE public.events … WHERE id = <táž akce>` se serializují, takže AFTER
# trigger druhého běží až nad zakomitovaným stavem prvního a nemá co doplňovat.
#
# Je to tichý předpoklad — v kódu ho nic nevyslovuje a rozbil by ho kdokoli, kdo
# by dorovnání zavolal jinudy než přes `events` (proto je `dorovnej_stab` bez
# EXECUTE pro anon i authenticated). Proto se to testuje, ne komentuje.
#
# Jedním spojením se to zahrát nedá. Scénář:
#   A: BEGIN; UPDATE events (zvedne rozpis na 3); …drží transakci otevřenou…
#   B: tentýž UPDATE — zasekne se na zámku řádku akce
#   A: COMMIT  →  B se probudí, jeho trigger vidí 3 směny a NEDOPLNÍ nic
#
# Pouští se proti LOKÁLNÍMU Dockeru, nikdy proti cloudu.
# =============================================================================
set -uo pipefail

KONTEJNER="${KONTEJNER:-supabase_db_ltrazktulfxvzlvkxdsb}"
PRIPOJENI=(docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1)
NAZEV='ZÁVOD dorovnání štábu'

psql_() { "${PRIPOJENI[@]}" "$@"; }

uklid() {
  psql_ -c "DELETE FROM public.shifts WHERE event_id IN (SELECT id FROM public.events WHERE title = '$NAZEV');
            DELETE FROM public.events WHERE title = '$NAZEV';" >/dev/null 2>&1
  rm -f "$ROURA_A"
}

ROURA_A="$(mktemp -u)"; mkfifo "$ROURA_A"
trap uklid EXIT

# Pojistka: jen lokální seed databáze.
if ! psql_ -tAc "SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111'" | grep -q 1; then
  echo "ODMÍTNUTO: tohle není lokální seed databáze." >&2
  exit 1
fi

uklid 2>/dev/null
AKCE=$(psql_ -tAc "INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs)
                   VALUES ('$NAZEV', 'commercial', '2026-09-20 10:00+02', '2026-09-20 12:00+02', 1,
                           '{\"instructor\": 1}'::jsonb)
                   RETURNING id")

PRED=$(psql_ -tAc "SELECT count(*) FROM public.shifts WHERE event_id = '$AKCE' AND status <> 'cancelled'")
if [[ "$PRED" != "1" ]]; then
  echo "TEST SELHAL: akce měla vzniknout s 1 směnou, má $PRED" >&2
  exit 1
fi

# --- Spojení A: zvedne rozpis a drží transakci otevřenou ----------------------
psql_ -f - < "$ROURA_A" >/dev/null 2>&1 &
A_PID=$!
exec 3>"$ROURA_A"
cat >&3 <<SQL
BEGIN;
UPDATE public.events SET role_reqs = '{"instructor": 3}'::jsonb, required_staff = 3
 WHERE id = '$AKCE';
SELECT pg_sleep(0.3);
SQL

sleep 0.6   # ať A stihne UPDATE a zámek doopravdy drží

# --- Spojení B: tentýž UPDATE, musí se zaseknout na zámku řádku akce ----------
VYSTUP_B=$(mktemp)
ZACATEK=$(date +%s%N)
(
  "${PRIPOJENI[@]}" >"$VYSTUP_B" 2>&1 <<SQL
UPDATE public.events SET role_reqs = '{"instructor": 3}'::jsonb, required_staff = 3
 WHERE id = '$AKCE';
SQL
) &
B_PID=$!

sleep 1.0   # B už musí viset na zámku
echo "COMMIT;" >&3
exec 3>&-
wait "$A_PID" 2>/dev/null
wait "$B_PID" 2>/dev/null
KONEC=$(date +%s%N)
CEKAL_MS=$(( (KONEC - ZACATEK) / 1000000 ))

rm -f "$VYSTUP_B"

PO=$(psql_ -tAc "SELECT count(*) FROM public.shifts WHERE event_id = '$AKCE' AND status <> 'cancelled'")

# Nejdřív: ZAHRÁL SE ZÁVOD VŮBEC? Kdyby B proběhlo dřív, než A vzalo zámek,
# vyšlo by 3 taky — a test by mlčky tvrdil něco, co neověřil. Mlčení vyložené
# jako úspěch nehlídá nic (táž past jako v zadosti_o_klub_zavod.sh).
if (( CEKAL_MS < 500 )); then
  echo "TEST SELHAL: B nečekalo na zámek (${CEKAL_MS} ms) — závod se nezahrál, výsledek nic nedokazuje." >&2
  exit 1
fi

if [[ "$PO" == "3" ]]; then
  echo "OK  závod: souběžná úprava akce založila 3 směny, ne 6 (B čekalo ${CEKAL_MS} ms na zámku řádku akce)"
  exit 0
fi

echo "TEST SELHAL: po souběžné úpravě má akce $PO směn místo 3." >&2
echo "             Dorovnání se zřejmě přestalo opírat o zámek řádku akce —" >&2
echo "             pak potřebuje vlastní zámek (SELECT … FOR UPDATE nad events)." >&2
exit 1
