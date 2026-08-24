-- =============================================================================
-- Etapa 3 / PR 4 — testy PRÁV, spouštěné jako `authenticator`
-- =============================================================================
-- MUSÍ SE SPOUŠTĚT TÍMHLE KANÁLEM, jinak netestuje nic:
--
--   docker exec -e PGPASSWORD=postgres -i supabase_db_<project> \
--     psql -h 127.0.0.1 -U authenticator -d postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/fakturoid_prava_test.sql
--
-- PROČ NE PŘES `psql -U postgres`: `SET LOCAL ROLE authenticated` mění
-- `current_user`, ale `session_user` zůstává `postgres` — a guard má větev
-- „běh bez tokenu pod databázovou rolí", takže by prošel a test by tvrdil
-- zavřeno o dveřích, vedle kterých je otevřené okno. `authenticator` je role,
-- kterou se připojuje PostgREST, tedy věrný kanál. (Pravidlo 8 v CLAUDE.md
-- a kapitola 5 v docs/ETAPA2-STAV.md.)
--
-- CO TENHLE SOUBOR HLÍDÁ: guard `fakturoid_smi_volat()` vracel NULL, ne false.
-- Mimo PostgREST není `request.jwt.claims` nastavené, takže porovnání na
-- `service_role` je NULL a `false OR NULL OR false` je NULL. `IF NOT NULL THEN
-- RAISE` se neprovede — guard tiše propustil. Změřeno na živé databázi.
-- =============================================================================

\set ON_ERROR_STOP on
\o /dev/null
BEGIN;

CREATE TEMP TABLE vysledky (tvrzeni text, ok boolean);
GRANT INSERT ON vysledky TO authenticated, anon;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_popis text, _ok boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO vysledky VALUES (_popis, coalesce(_ok, false));
  IF NOT coalesce(_ok, false) THEN RAISE WARNING 'SELHALO: %', _popis; END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Pod rolí `authenticated` bez admina musí KAŽDÁ fakturoidí RPC odmítnout
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  _fn text;
  _volani text[] := ARRAY[
    $q$SELECT public.fakturoid_je_vyfakturovana(gen_random_uuid())$q$,
    $q$SELECT * FROM public.fakturoid_najdi_podle_klice('x')$q$,
    $q$SELECT public.fakturoid_zkus_zabrat('x','club_monthly',gen_random_uuid(),NULL,NULL,NULL,1,1,'koncept',ARRAY[gen_random_uuid()])$q$,
    $q$SELECT public.fakturoid_uvolni_zabrani('x','d')$q$,
    $q$SELECT public.fakturoid_zapis_vazbu('x','1','1','1','1',NULL,'open',1,NULL)$q$,
    $q$SELECT public.fakturoid_zapis_pdf('x','p',NULL)$q$,
    $q$SELECT public.fakturoid_oznac_odeslano('x')$q$,
    $q$SELECT * FROM public.fakturoid_podklady_klub(gen_random_uuid(),'2026-08-01','2026-08-31')$q$,
    $q$SELECT * FROM public.fakturoid_podklady_akce(gen_random_uuid())$q$,
    $q$SELECT * FROM public.fakturoid_subjekt(gen_random_uuid())$q$
  ];
  _odmitnuto boolean;
BEGIN
  FOREACH _fn IN ARRAY _volani LOOP
    _odmitnuto := false;
    BEGIN
      SET LOCAL ROLE authenticated;
      EXECUTE _fn;
      RESET ROLE;
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      -- Odmítnutí smí přijít buď z guardu, nebo z chybějícího EXECUTE.
      _odmitnuto := (SQLERRM LIKE '%Nemáte oprávnění%' OR SQLERRM LIKE '%permission denied%');
    END;
    PERFORM pg_temp.tvrd(format('authenticated bez admina NEPROJDE: %s', left(_fn, 60)), _odmitnuto);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Totéž pod `anon`
-- ---------------------------------------------------------------------------
DO $$
DECLARE _odmitnuto boolean := false;
BEGIN
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.fakturoid_je_vyfakturovana(gen_random_uuid());
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    _odmitnuto := true;
  END;
  PERFORM pg_temp.tvrd('anon NEPROJDE ani k je_vyfakturovana', _odmitnuto);
END $$;

-- ---------------------------------------------------------------------------
-- Souhrn
-- ---------------------------------------------------------------------------
\o
\echo ''
SELECT tvrzeni FROM vysledky WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS proslo,
       count(*) FILTER (WHERE NOT ok) AS selhalo,
       count(*) AS celkem
  FROM vysledky;

DO $$
DECLARE _s int;
BEGIN
  SELECT count(*) INTO _s FROM vysledky WHERE NOT ok;
  IF _s > 0 THEN RAISE EXCEPTION 'Fakturoid/práva: % tvrzení SELHALO', _s; END IF;
  RAISE NOTICE 'Fakturoid/práva: všechna tvrzení prošla.';
END $$;

ROLLBACK;
