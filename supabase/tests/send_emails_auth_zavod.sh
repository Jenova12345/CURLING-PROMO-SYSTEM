#!/usr/bin/env bash
# =============================================================================
# BRÁNA: send-emails si ověřuje volajícího podle ROLE, ne podle tvaru klíče
#
# PROČ SHELL A NE `*_test.sql`: to, co se tady měří, je rozhodnutí v EDGE
# FUNKCI, ne v databázi. SQL test umí ověřit jen `moje_role()`, a ta byla
# zelená i ve chvíli, kdy edge funkce `moje_role()` vůbec nevolala. Přesně
# tohle 12. 9. 2026 propustily dvě brány a chytila až třetí.
#
# ⚠️ ROZLIŠUJÍCÍ PŘÍPAD je scénář 5: token, který je PLATNÉ SERVISNÍ POVĚŘENÍ,
# ale NENÍ roven vstřikovanému `SUPABASE_SERVICE_ROLE_KEY`. Takový token
#   * starý kód (`auth.includes(servisniKlic)`) ODMÍTNE  → test zčervená
#   * nový kód (dotaz na roli)                  PŘIJME   → test projde
# Scénáře 1–4 tohle NEROZLIŠÍ: odmítne je obě verze stejně, takže samy o sobě
# netvrdí nic o tom, která verze běží.
#
# Pouští se proti LOKÁLNÍMU Supabase (`supabase start` + `functions serve`).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

URL="${URL:-http://127.0.0.1:55321}"
CHYB=0
ok()   { echo "✅ $1"; }
spatne() { echo "❌ $1"; CHYB=$((CHYB+1)); }

JSON=$(supabase status -o json 2>/dev/null) || { echo "Lokální Supabase neběží."; exit 1; }
ANON=$(echo "$JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['ANON_KEY'])")
SRK=$(echo  "$JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['SERVICE_ROLE_KEY'])")

vol() {  # $1 = token (prazdny = bez hlavicky)
  if [ -z "$1" ]; then
    curl -s -X POST "$URL/functions/v1/send-emails" -H "Content-Type: application/json" -d '{"dryRun":true}'
  else
    curl -s -X POST "$URL/functions/v1/send-emails" -H "Authorization: Bearer $1" \
         -H "Content-Type: application/json" -d '{"dryRun":true}'
  fi
}
odmitnuto() { echo "$1" | grep -q "obsluhuje jen server"; }

# --- 1-4: co NESMÍ projít (obě verze je odmítnou, proto to nic nerozlišuje) ---
odmitnuto "$(vol '')"      && ok "bez hlavičky Authorization neprojde"        || spatne "bez hlavičky PROŠLO"
odmitnuto "$(vol "$ANON")" && ok "anon/publishable klíč z prohlížeče neprojde" || spatne "ANON KLÍČ PROŠEL"
odmitnuto "$(vol 'eyJhbGciOiJIUzI1NiJ9.padelek.padelek')" \
  && ok "padělaný token neprojde" || spatne "PADĚLEK PROŠEL"

# Platny JWT prihlaseneho ADMINA (podepsany lokalnim JWT secretem).
ADMIN=$(python3 - <<'PY'
import hmac,hashlib,base64,json,time
S=b"super-secret-jwt-token-with-at-least-32-characters-long"
b=lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
h=b(json.dumps({"alg":"HS256","typ":"JWT"},separators=(",",":")).encode())
p=b(json.dumps({"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated",
  "aud":"authenticated","iat":int(time.time()),"exp":int(time.time())+3600},separators=(",",":")).encode())
print((h+b"."+p+b"."+b(hmac.new(S,h+b"."+p,hashlib.sha256).digest())).decode())
PY
)
odmitnuto "$(vol "$ADMIN")" && ok "JWT přihlášeného ADMINA neprojde" || spatne "ADMIN PROŠEL"

# --- 5: ROZLIŠUJÍCÍ PŘÍPAD --------------------------------------------------
# Vlastnorucne podepsany JWT s role=service_role. Je to platne servisni
# povereni (PostgREST ho prijme a prepne na service_role), ale jako RETEZEC
# se vstriknutemu klici nerovna.
SRJWT=$(python3 - <<'PY'
import hmac,hashlib,base64,json,time
S=b"super-secret-jwt-token-with-at-least-32-characters-long"
b=lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
h=b(json.dumps({"alg":"HS256","typ":"JWT"},separators=(",",":")).encode())
p=b(json.dumps({"role":"service_role","iss":"supabase",
  "iat":int(time.time()),"exp":int(time.time())+3600},separators=(",",":")).encode())
print((h+b"."+p+b"."+b(hmac.new(S,h+b"."+p,hashlib.sha256).digest())).decode())
PY
)
[ "$SRJWT" = "$SRK" ] && { echo "Rozlišující token se rovná vstřikovanému klíči, test by netvrdil nic."; exit 1; }
ODP=$(vol "$SRJWT")
if odmitnuto "$ODP"; then
  spatne "ROZLIŠUJÍCÍ: platné servisní pověření jiného tvaru NEPROŠLO -> funkce pořád porovnává řetězec"
else
  ok "ROZLIŠUJÍCÍ: platné servisní pověření projde i s jiným tvarem klíče"
fi

# --- 6: vlastni servisni klic musi projit poad (rychla cesta) ----------------
odmitnuto "$(vol "$SRK")" && spatne "vlastní servisní klíč NEPROŠEL" || ok "vlastní servisní klíč projde"

# =============================================================================
# 7-10: CO SMÍ CRON TOKEN — a co ne
# =============================================================================
# Tohle jsou nálezy bezpečnostní brány a code review z 12. 9. 2026. Jsou tady
# v SHELLU schválně: `branyFrontendu.test.ts` je jen regex nad zdrojákem
# a zůstal 48/48 zelený i po čtyřech mutacích, které tu opravu VYPNOU
# (vypuštěné `return` z obou bran, neužitý `smiVidetObsah`, obalený
# `jenOdeslat`). Regex vidí, že text v souboru je; nevidí, jestli něco dělá.
#
# Běží jen tehdy, když má lokální funkce nastavený EMAIL_CRON_TOKEN.
if [ -n "${EMAIL_CRON_TOKEN:-}" ]; then
  volcron() {  # $1 = telo pozadavku, $2 = metoda (vychozi POST)
    curl -s -X "${2:-POST}" "$URL/functions/v1/send-emails" \
         -H "Authorization: Bearer $ANON" \
         -H "x-cron-token: $EMAIL_CRON_TOKEN" \
         -H "Content-Type: application/json" -d "${1:-{\}}"
  }

  # 7) Cron token frontu ODESLAT smí.
  ODP=$(volcron '{}')
  odmitnuto "$ODP" && spatne "cron token neprošel ani na odeslání fronty" \
                   || ok "cron token frontu odeslat smí"

  # 8) ROZLIŠUJÍCÍ: náhled s ním NESMÍ. Dokud šel, vracel adresy a plná těla
  # až 200 zpráv do `net._http_response`, což je tabulka bez RLS.
  ODP=$(volcron '{"dryRun":true,"limit":200}')
  if echo "$ODP" | grep -q "servisní pověření"; then
    ok "ROZLIŠUJÍCÍ: náhled fronty cron token odmítne"
  else
    spatne "ROZLIŠUJÍCÍ: cron token si PŘEČETL frontu přes dryRun -> $(echo "$ODP" | head -c 120)"
  fi

  # 9) A opravdu se nevrátil obsah, ne jen jiná hláška.
  echo "$ODP" | grep -qE '"(prijemce|telo)"' \
    && spatne "odpověď na dryRun s cron tokenem OBSAHUJE adresy nebo těla" \
    || ok "v odpovědi nejsou ani adresy, ani těla zpráv"

  # 10) Vyprázdnit frontu je změna stavu, takže GET ne.
  echo "$(volcron '{}' GET)" | grep -q "Použijte POST" \
    && ok "GET se správným cron tokenem neprojde" \
    || spatne "GET se správným cron tokenem FRONTU ODESLAL"

  # 11) AUTOMATICKÝ NÁHLED nesmí vysypat obsah fronty.
  # Tohle je jiná cesta než 8-9 a jiný únik: když chybí (nebo se zrotuje)
  # RESEND_API_KEY, spadne funkce do náhledu SAMA — a cron posílá `{}`, takže
  # by každých 5 minut sypala adresy a plná těla do `net._http_response`,
  # tabulky bez RLS. Scénáře 8-9 to nezměří, protože ty končí na 403 dřív.
  psql_() { docker exec -i supabase_db_ltrazktulfxvzlvkxdsb psql -U postgres -X -q -A -t "$@"; }
  psql_ -c "INSERT INTO public.email_outbox (email, subject, body, status)
            VALUES ('zastupce.klubu@test.local','Rezervace byla zrušena',
                    'Vaši rezervaci za CK Ostravské kameny zrušil správce.','pending');" >/dev/null

  ODP=$(volcron '{}')
  if echo "$ODP" | grep -qE '"(prijemce|telo)"|zastupce\.klubu@test\.local'; then
    spatne "AUTOMATICKÝ NÁHLED vrátil adresy nebo těla -> $(echo "$ODP" | head -c 120)"
  else
    ok "automatický náhled bez klíče vrací jen počty, ne obsah"
  fi

  # ROZLIŠUJÍCÍ PROTIPŘÍKLAD: se SERVISNÍM pověřením a výslovným dryRun se
  # obsah vrátit MÁ. Bez tohohle by testu vyhověla i funkce, která náhled
  # nevrací nikdy — a přišli bychom o způsob, jak si zkontrolovat šablony.
  ODP=$(curl -s -X POST "$URL/functions/v1/send-emails" -H "Authorization: Bearer $SRK" \
        -H "Content-Type: application/json" -d '{"dryRun":true}')
  echo "$ODP" | grep -q 'zastupce.klubu@test.local' \
    && ok "ROZLIŠUJÍCÍ: se servisním pověřením náhled obsah vrátí" \
    || spatne "ROZLIŠUJÍCÍ: ani servisní pověření obsah náhledu nedostane -> $(echo "$ODP" | head -c 120)"

  psql_ -c "DELETE FROM public.email_outbox WHERE email='zastupce.klubu@test.local';" >/dev/null
else
  echo "➖ 7-10 přeskočeno: nastav EMAIL_CRON_TOKEN a pusť znovu (jinak se cesta cronu neměří)"
fi

echo
[ "$CHYB" -eq 0 ] && { echo "=== BRÁNA PROŠLA ==="; exit 0; }
echo "=== BRÁNA SELHALA ($CHYB) ==="; exit 1
