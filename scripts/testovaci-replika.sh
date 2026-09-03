#!/usr/bin/env bash
#
# testovaci-replika.sh — postaví lokální repliku produkce pro SQL testy.
#
# PROČ EXISTUJE: obvyklá cesta je `supabase start` (lokální Supabase v Dockeru).
# Na strojích bez Dockeru ale nejde spustit vůbec nic, a testy práv se pak
# nemají kde spustit — což v praxi znamená, že se neudělají. Tenhle skript
# postaví náhradu z čerstvého dumpu produkce.
#
# ČEMU VĚŘIT A ČEMU NE:
#   * schéma, RLS politiky, triggery i data      = z dumpu, tedy věrné
#   * práva rolí (granty)                        = kopírují se z produkce
#     zvlášť, protože `pg_dump --no-privileges` je nenese
#   * rozšíření `supabase_vault`                 = lokálně není, neřeší se
#
# Granty se kopírují VČETNĚ SLOUPCOVÝCH a včetně práv na schémata. Není to
# detail: Supabase je používá (na `reservations` má `authenticated` jen
# sloupcové granty, ne tabulkové) a bez nich testy hlásí „permission denied"
# místo toho, co měly měřit — nebo, hůř, projdou jako zelené, protože „něco
# selhalo" vypadá jako „brána drží".
#
# Použití:
#   scripts/testovaci-replika.sh                 # port 5433, db curling_test
#
# Heslo k produkci bere z `.env.local` (SUPABASE_DB_PASSWORD), stejně jako
# safe-deploy.sh. Do příkazové řádky se nikdy nedostane.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${PGPORT_TEST:-5433}"
DB="${DB_TEST:-curling_test}"
REF=fcwubbytqxubgptftnru   # curling-promo-prod, jen pro ČTENÍ

if [ ! -f .env.local ]; then
  echo "❌ Chybí .env.local (a v něm SUPABASE_DB_PASSWORD)." >&2; exit 1
fi
HESLO=$(grep -E '^SUPABASE_DB_PASSWORD=' .env.local | head -1 | cut -d= -f2- | tr -d "\"'")
[ -n "$HESLO" ] || { echo "❌ SUPABASE_DB_PASSWORD není vyplněné." >&2; exit 1; }

prod() { PGPASSWORD="$HESLO" psql -h aws-1-eu-west-1.pooler.supabase.com -p 5432 \
           -U "postgres.${REF}" -d postgres -X -tAc "$1"; }
lokal() { psql -p "$PORT" -U postgres -d "$1" -X -q "${@:2}"; }

pg_isready -p "$PORT" >/dev/null 2>&1 || {
  echo "❌ Na portu $PORT neběží Postgres. Nastartuj ho, např.:" >&2
  echo "   pg_ctl -D <datadir> -o \"-p $PORT\" -l pg.log start" >&2
  exit 1
}

echo "── ROLE ───────────────────────────────────────────────"
lokal postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['authenticated','anon','service_role','authenticator',
                           'supabase_auth_admin','supabase_storage_admin','pgbouncer','dashboard_user'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOINHERIT', r);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_admin') THEN
    CREATE ROLE supabase_admin SUPERUSER NOLOGIN;
  END IF;
END $$;
SQL

echo "── DUMP PRODUKCE (jen čtení) ──────────────────────────"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PGPASSWORD="$HESLO" pg_dump -h aws-1-eu-west-1.pooler.supabase.com -p 5432 \
  -U "postgres.${REF}" -d postgres --no-owner --no-privileges > "$TMP/prod.sql"
VEL=$(wc -c < "$TMP/prod.sql" | tr -d ' ')
echo "   velikost: $VEL B"
[ "$VEL" -ge 100000 ] || { echo "❌ Dump je podezřele malý, končím." >&2; exit 1; }

echo "── OBNOVA DO $DB ──────────────────────────────────────"
lokal postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
# `supabase_vault` lokálně není; chyby kolem něj jsou očekávané a neškodné.
lokal "$DB" -f "$TMP/prod.sql" 2>&1 | grep -E "^psql.*ERROR" | grep -v "supabase_vault\|vault.secrets" || true

echo "── GRANTY Z PRODUKCE (tabulkové, sloupcové, schémata) ─"
{
  prod "SELECT 'GRANT USAGE ON SCHEMA '||quote_ident(nspname)||' TO '||r.rolname||';'
        FROM pg_namespace n CROSS JOIN (SELECT unnest(ARRAY['authenticated','anon','service_role']) AS rolname) r
        WHERE n.nspname IN ('public','auth','extensions','storage','graphql_public')
          AND has_schema_privilege(r.rolname, n.oid, 'USAGE');"
  prod "SELECT 'GRANT EXECUTE ON FUNCTION auth.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') TO '||r.rolname||';'
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        CROSS JOIN (SELECT unnest(ARRAY['authenticated','anon','service_role']) AS rolname) r
        WHERE n.nspname='auth' AND has_function_privilege(r.rolname, p.oid, 'EXECUTE');"
  prod "SELECT 'GRANT '||privilege_type||' ('||string_agg(quote_ident(column_name), ', ' ORDER BY column_name)
             ||') ON public.'||quote_ident(table_name)||' TO '||quote_ident(grantee)||';'
        FROM information_schema.role_column_grants
        WHERE table_schema='public' AND grantee IN ('authenticated','anon','service_role')
        GROUP BY table_name, grantee, privilege_type;"
  prod "SELECT 'GRANT EXECUTE ON FUNCTION public.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') TO authenticated;'
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND has_function_privilege('authenticated', p.oid, 'EXECUTE');"
} > "$TMP/granty.sql"
lokal "$DB" -f "$TMP/granty.sql" > /dev/null

echo "── KONTROLA SHODY PRÁV ────────────────────────────────"
# Bez tohohle kroku se replice nedá věřit: chybějící grant umí vydávat
# „permission denied" za funkční bezpečnostní bránu.
PARITA="SELECT c.relname||'.'||a.attname||'|'||r.rolname||'|'||p.priv||'|'||
          has_column_privilege(r.rolname, c.oid, a.attname, p.priv)::text
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
        CROSS JOIN (SELECT unnest(ARRAY['authenticated','anon']) AS rolname) r
        CROSS JOIN (SELECT unnest(ARRAY['SELECT','INSERT','UPDATE']) AS priv) p
        WHERE n.nspname='public' AND c.relkind IN ('r','v') ORDER BY 1;"
prod "$PARITA" | tr -d '\r' > "$TMP/parita_prod.txt"
psql -p "$PORT" -U postgres -d "$DB" -X -tAc "$PARITA" | tr -d '\r' > "$TMP/parita_repl.txt"
if diff -q "$TMP/parita_prod.txt" "$TMP/parita_repl.txt" > /dev/null; then
  echo "   ✓ práva sedí 1:1 ($(wc -l < "$TMP/parita_prod.txt") kombinací)"
else
  echo "❌ Práva se od produkce liší — testům by se nedalo věřit:" >&2
  diff "$TMP/parita_prod.txt" "$TMP/parita_repl.txt" | head -20 >&2
  exit 1
fi

echo
echo "✓ Replika hotová: psql -p $PORT -U postgres -d $DB"
echo "  Testy: psql -p $PORT -U postgres -d $DB -X -q -v ON_ERROR_STOP=1 -f supabase/tests/<soubor>.sql"
