#!/usr/bin/env bash
# =============================================================================
# Chování MIGRACE dorovnání štábu na existujících akcích
#
# `dorovnani_stabu_test.sql` testuje funkci a trigger. Tenhle skript testuje
# DATOVOU ČÁST migrace (kapitola 5) — tedy to, co se s existujícími akcemi stane
# jednou, při nasazení. Na lokálním seedu se nestane nic, protože tam štáb sedí;
# právě proto se ta situace musí vyrobit schválně.
#
# TŘI TVRZENÍ:
#
# 1) MIGRACE JEN DOPLŇUJE, NIKDY NERUŠÍ — a to i na akci se SMÍŠENÝM rozpisem,
#    kde jedna role chybí a jiná přebývá. Dřív se to spoléhalo na výběrový filtr,
#    jenže ten počítá SOUČTY za akci, kdežto dorovnání pracuje PO ROLÍCH: akce
#    `{"instructor": 4}` s jedním instruktorem a dvěma bary má součet 3 < 4,
#    takže filtrem projde jako „chybí lidi" — a bary by zrušila.
#
# 2) PŘEBYTEK SE NAHLÁSÍ. „Nic nerušíme" bez výpisu znamená jen to, že se
#    o rozporu nikdo nedozví a provoz s ním začne, aniž o něm ví.
#
# 3) MIGRACE SE ZASTAVÍ A ŘEKNE PROČ, když najde akci se zkaženým rozpisem.
#    Bez předkontroly by spadla na `invalid input syntax for type integer` bez
#    jediného ID.
#
# Skript si schéma sám vrátí do stavu „před migrací", takže musí běžet proti
# LOKÁLNÍMU Dockeru. Nikdy proti cloudu.
# =============================================================================
set -uo pipefail

KONTEJNER="${KONTEJNER:-supabase_db_ltrazktulfxvzlvkxdsb}"
MIGRACE="supabase/migrations/20260827100000_dorovnani_stabu.sql"
PRIPOJENI=(docker exec -i "$KONTEJNER" psql -U postgres -X -q)
SMISENA='MIGRACE štáb — smíšený rozpis'
ZKAZENA='MIGRACE štáb — zkažený rozpis'

psql_()  { "${PRIPOJENI[@]}" "$@"; }
psql_t() { "${PRIPOJENI[@]}" -tAc "$1"; }

selhani() { echo "TEST SELHAL: $1" >&2; exit 1; }

uklid() {
  psql_ -c "DELETE FROM public.shifts WHERE event_id IN
              (SELECT id FROM public.events WHERE title IN ('$SMISENA', '$ZKAZENA'));
            DELETE FROM public.events WHERE title IN ('$SMISENA', '$ZKAZENA');" >/dev/null 2>&1
}
trap uklid EXIT

if [[ ! -f "$MIGRACE" ]]; then selhani "spouštěj z kořene repa, nenašel jsem $MIGRACE"; fi
if [[ "$(psql_t "SELECT count(*) FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111'")" != "1" ]]; then
  selhani "tohle není lokální seed databáze"
fi

uklid

# --- Stav „před migrací" ------------------------------------------------------
# Trigger i CHECK pryč, ať se dají vyrobit přesně ty akce, které na produkci
# čekají — tedy takové, jaké dnešní kód založit neumí.
psql_ -v ON_ERROR_STOP=1 <<'SQL' >/dev/null || selhani "nepodařilo se vrátit schéma před migraci"
DROP TRIGGER IF EXISTS trg_events_dorovnani ON public.events;
ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_role_reqs_platny;
SQL

# Smíšená akce: rozpis chce 4 instruktory, ve skutečnosti je 1 instruktor
# a 2 volné bary. Součet 3 < 4 → výběrový filtr ji vezme.
SMES=$(psql_t "INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs)
               VALUES ('$SMISENA', 'commercial', '2026-10-05 10:00+02', '2026-10-05 12:00+02', 4,
                       '{\"instructor\": 4}'::jsonb)
               RETURNING id")
psql_ -c "INSERT INTO public.shifts (event_id, status, required_role) VALUES
            ('$SMES', 'open', 'instructor'),
            ('$SMES', 'open', 'bar_staff'),
            ('$SMES', 'open', 'bar_staff');" >/dev/null

# --- 1) Zkažený rozpis migraci zastaví a hláška řekne kterou akci -------------
ZKAZ=$(psql_t "INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs)
               VALUES ('$ZKAZENA', 'commercial', '2026-10-06 10:00+02', '2026-10-06 12:00+02', 1,
                       '{\"instructor\": \"dva\"}'::jsonb)
               RETURNING id")

VYSTUP=$(docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1 < "$MIGRACE" 2>&1)
if [[ $? -eq 0 ]]; then
  selhani "migrace prošla, přestože akce má rozpis {\"instructor\": \"dva\"}"
fi
if ! grep -q "Migrace zastavena" <<<"$VYSTUP"; then
  selhani "migrace spadla, ale ne vlastní hláškou. Výstup:
$VYSTUP"
fi
if ! grep -q "$ZKAZ" <<<"$VYSTUP"; then
  selhani "hláška neobsahuje ID vadné akce — s takovou se nedá nic opravit. Výstup:
$VYSTUP"
fi
echo "OK  zkažený rozpis migraci zastavil a hláška uvedla ID akce"

# --- 2) Po opravě dat migrace projde -----------------------------------------
psql_ -c "UPDATE public.events SET role_reqs = '{\"instructor\": 1}'::jsonb WHERE id = '$ZKAZ';" >/dev/null

VYSTUP=$(docker exec -i "$KONTEJNER" psql -U postgres -X -q -v ON_ERROR_STOP=1 < "$MIGRACE" 2>&1)
if [[ $? -ne 0 ]]; then
  selhani "migrace neprošla ani po opravě rozpisu. Výstup:
$VYSTUP"
fi
echo "OK  migrace po opravě rozpisu prošla"

# --- 3) JEN DOPLNILA. Bary musí být pořád tam. -------------------------------
INSTR=$(psql_t "SELECT count(*) FROM public.shifts
                 WHERE event_id = '$SMES' AND required_role = 'instructor' AND status <> 'cancelled'")
BARY=$(psql_t "SELECT count(*) FROM public.shifts
                WHERE event_id = '$SMES' AND required_role = 'bar_staff' AND status <> 'cancelled'")
ZRUSENO=$(psql_t "SELECT count(*) FROM public.shifts
                   WHERE event_id = '$SMES' AND status = 'cancelled'")

if [[ "$INSTR" != "4" ]]; then
  selhani "instruktoři se nedoplnili na 4 (je $INSTR) — migrace měla chybějící směny doplnit"
fi
echo "OK  chybějící instruktoři se doplnili (1 → 4)"

if [[ "$BARY" != "2" ]]; then
  selhani "bary se ztratily (zbylo $BARY ze 2). Migrace zrušila směny, přestože slibuje,
             ze jen doplnuje - presne ten smiseny pripad, na ktery souctovy filtr nestaci."
fi
if [[ "$ZRUSENO" != "0" ]]; then
  selhani "migrace zrušila $ZRUSENO směn, přestože měla jen doplňovat"
fi
echo "OK  migrace NEZRUŠILA ani jednu směnu baru (rozpis je nežádá)"

# --- 4) A přebytek nahlásila --------------------------------------------------
if ! grep -q "POZOR" <<<"$VYSTUP" || ! grep -q "$SMISENA" <<<"$VYSTUP"; then
  selhani "migrace o přebytku mlčela. Slib, ze se nic nerusi, bez vypisu znamena
             jen to, ze se o rozporu nikdo nedozvi a provoz s nim zacne. Výstup:
$VYSTUP"
fi
echo "OK  migrace přebytek nahlásila jménem akce"

# --- 5) A od teď je zkažený rozpis nemožný ------------------------------------
CHYBA=$(psql_ -v ON_ERROR_STOP=1 -c "UPDATE public.events SET role_reqs = '{\"instructor\": \"dva\"}'::jsonb WHERE id = '$ZKAZ';" 2>&1)
if ! grep -q "events_role_reqs_platny" <<<"$CHYBA"; then
  selhani "po migraci šlo uložit zkažený rozpis — CHECK nedrží. Výstup:
$CHYBA"
fi
echo "OK  po migraci už zkažený rozpis do databáze neprojde"

echo "OK  všechna tvrzení o průběhu migrace dorovnání prošla"
