#!/usr/bin/env bash
# =============================================================================
# Chování MIGRACE ceníku na špinavých datech
#
# `sazby_roli_test.sql` testuje výsledek migrace. Tenhle skript testuje její
# PRŮBĚH — a to je jiná věc: datová část se pouští jednou, na produkci, nad daty,
# která na lokálním seedu neexistují. Právě tam se dá nejsnáz přepsat minulost.
#
# Dvě tvrzení, která to hlídá:
#
# 1) MIGRACE SE ZASTAVÍ A ŘEKNE PROČ, když najde sazbu mimo rozsah. Bez
#    předkontroly by `ADD CONSTRAINT` spadl na „is violated by some row" — bez
#    počtu a bez jediného ID, takže by nikdo nevěděl, který řádek opravit.
#
# 2) UZAVŘENÁ SMĚNA S PRÁZDNOU SAZBOU DOSTANE 150, NE CENÍKOVOU SAZBU.
#    Prázdná sazba dnes v aplikaci figuruje jako 150 (`hourly_rate || 150`
#    v useShifts.ts). Kdyby ji migrace dorovnala z ceníku, čtyřhodinová směna
#    trenéra by ze dne na den vyskočila ze 600 Kč na 2 400 Kč — a `payouts`
#    drží částku jako snapshot, takže výplata by pak říkala jiné číslo než
#    směny pod ní.
#
# Skript si schéma sám vrátí do stavu „před migrací", takže musí běžet proti
# LOKÁLNÍMU Dockeru. Nikdy proti cloudu.
# =============================================================================
set -uo pipefail

KONTEJNER="${KONTEJNER:-supabase_db_ltrazktulfxvzlvkxdsb}"
MIGRACE="supabase/migrations/20260827090000_sazby_roli.sql"
PRIPOJENI=(docker exec -i "$KONTEJNER" psql -U postgres -X -q)
NAZEV='MIGRACE ceník — testovací akce'

psql_()  { "${PRIPOJENI[@]}" "$@"; }
psql_t() { "${PRIPOJENI[@]}" -tAc "$1"; }

selhani() { echo "TEST SELHAL: $1" >&2; exit 1; }

uklid() {
  psql_ -c "DELETE FROM public.shifts WHERE event_id IN (SELECT id FROM public.events WHERE title = '$NAZEV');
            DELETE FROM public.events WHERE title = '$NAZEV';" >/dev/null 2>&1
}
trap uklid EXIT

if [[ ! -f "$MIGRACE" ]]; then selhani "spouštěj z kořene repa, nenašel jsem $MIGRACE"; fi
if [[ "$(psql_t "SELECT count(*) FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111'")" != "1" ]]; then
  selhani "tohle není lokální seed databáze"
fi

uklid

# --- Stav „před migrací": sloupec zpátky tak, jak vypadal v baseline -----------
# Trigger se vypíná jen na dobu přípravy dat: nezajímá nás tady jeho validace
# hodin, chceme dostat do tabulky přesně ty řádky, jaké čekají na produkci.
psql_ -v ON_ERROR_STOP=1 <<'SQL' >/dev/null || selhani "nepodařilo se vrátit schéma před migraci"
ALTER TABLE public.shifts DROP CONSTRAINT IF EXISTS shifts_hourly_rate_rozsah;
ALTER TABLE public.shifts ALTER COLUMN hourly_rate DROP NOT NULL;
ALTER TABLE public.shifts ALTER COLUMN hourly_rate SET DEFAULT 150.00;
DROP TRIGGER IF EXISTS trg_shifts_sazba ON public.shifts;
SQL

AKCE=$(psql_t "INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs)
                VALUES ('$NAZEV', 'commercial', '2026-10-01 10:00+02', '2026-10-01 14:00+02', 0, '{}'::jsonb)
                RETURNING id")

# Tři řádky, které na lokálním seedu nikdy nevzniknou, ale na produkci mohou:
#   1. uzavřená směna trenéra s PRÁZDNOU sazbou (dnes se počítá jako 150),
#   2. směna s hodinami mimo rozsah, který hlídá validate_shift_claim
#      (dorovnávací UPDATE přes ni jde — a bez vypnutého triggeru by shodila
#      migraci o sazbách hláškou o hodinách),
#   3. směna se sazbou mimo rozsah (kvůli tvrzení 1).
psql_ -v ON_ERROR_STOP=1 <<SQL >/dev/null || selhani "nepodařilo se připravit špinavá data"
ALTER TABLE public.shifts DISABLE TRIGGER validate_shift_before_update;
INSERT INTO public.shifts (id, event_id, status, required_role, hourly_rate, hours_worked, completed_at, claimed_by)
VALUES ('dddddddd-0000-0000-0000-000000000001', '$AKCE', 'completed', 'trainer', NULL, 4, now(),
        '22222222-2222-2222-2222-222222222222'),
       ('dddddddd-0000-0000-0000-000000000002', '$AKCE', 'completed', 'instructor', NULL, 30, now(),
        '22222222-2222-2222-2222-222222222222'),
       ('dddddddd-0000-0000-0000-000000000003', '$AKCE', 'open', 'instructor', 99999999, NULL, NULL, NULL);
ALTER TABLE public.shifts ENABLE TRIGGER validate_shift_before_update;
SQL

# --- 1) Migrace se MUSÍ zastavit a říct proč ---------------------------------
VYSTUP=$(docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1 < "$MIGRACE" 2>&1)
if [[ $? -eq 0 ]]; then
  selhani "migrace prošla, přestože v datech je sazba 99 999 999 Kč/h"
fi
if ! grep -q "Migrace zastavena" <<<"$VYSTUP"; then
  selhani "migrace spadla, ale ne vlastní hláškou. Výstup:
$VYSTUP"
fi
if ! grep -q "dddddddd-0000-0000-0000-000000000003" <<<"$VYSTUP"; then
  selhani "hláška neobsahuje ID vadného řádku — s takovou se nedá nic opravit. Výstup:
$VYSTUP"
fi
echo "OK  migrace se zastavila a vypsala ID vadného řádku"

# --- 2) Po opravě dat projde a NEPŘEPÍŠE minulost -----------------------------
psql_ -c "UPDATE public.shifts SET hourly_rate = 250 WHERE id = 'dddddddd-0000-0000-0000-000000000003';" >/dev/null

VYSTUP=$(docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1 < "$MIGRACE" 2>&1)
if [[ $? -ne 0 ]]; then
  selhani "migrace neprošla ani po opravě dat. Výstup:
$VYSTUP"
fi
echo "OK  migrace po opravě dat prošla"

if ! grep -q "Dorovnávám 2 směn" <<<"$VYSTUP"; then
  selhani "migrace nenapsala, kolik směn dorovnává — to má být vidět. Výstup:
$VYSTUP"
fi
echo "OK  migrace vypsala počet dorovnávaných směn"

# TOHLE JE TO PODSTATNÉ TVRZENÍ CELÉHO SKRIPTU.
# Porovnává se ČÍSELNĚ, ne textově: `shifts.hourly_rate` je `numeric` bez pevného
# měřítka, takže psql vrátí „150" u jedné směny a „150.00" u jiné podle toho, co
# do ní kdo zapsal. Textové porovnání by z toho udělalo falešně červený test.
SAZBA=$(psql_t "SELECT (hourly_rate = 150) FROM public.shifts WHERE id = 'dddddddd-0000-0000-0000-000000000001'")
SAZBA_TEXT=$(psql_t "SELECT hourly_rate::text FROM public.shifts WHERE id = 'dddddddd-0000-0000-0000-000000000001'")
if [[ "$SAZBA" != "t" ]]; then
  selhani "uzavřená směna trenéra dostala $SAZBA_TEXT Kč/h místo 150.
             Migrace přepsala minulost: čtyřhodinová směna přeskočila ze 600 Kč jinam,
             zatímco payouts.amount drží původní částku jako snapshot."
fi
echo "OK  uzavřená směna trenéra dostala 150 Kč/h (status quo), ne 600 z ceníku"

HODINY=$(psql_t "SELECT hours_worked FROM public.shifts WHERE id = 'dddddddd-0000-0000-0000-000000000002'")
if [[ "$HODINY" != "30" ]]; then
  selhani "migrace sáhla na hours_worked (je $HODINY, má být 30) — měla dorovnat jen sazbu"
fi
echo "OK  směna s 30 hodinami migraci neshodila a hodiny zůstaly beze změny"

# A nová směna už sazbu z ceníku dostane — kvůli tomu ta migrace je.
NOVA=$(psql_t "INSERT INTO public.shifts (event_id, status, required_role)
               VALUES ('$AKCE', 'open', 'trainer') RETURNING (hourly_rate = 600)::text")
if [[ "$NOVA" != "true" ]]; then
  selhani "nová směna trenéra nedostala 600 Kč/h z ceníku"
fi
echo "OK  směna založená PO migraci dostala 600 Kč/h z ceníku"

echo "OK  všechna tvrzení o průběhu migrace ceníku prošla"
