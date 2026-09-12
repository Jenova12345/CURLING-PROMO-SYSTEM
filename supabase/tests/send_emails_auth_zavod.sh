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

echo
[ "$CHYB" -eq 0 ] && { echo "=== BRÁNA PROŠLA ==="; exit 0; }
echo "=== BRÁNA SELHALA ($CHYB) ==="; exit 1
