-- =============================================================================
-- TESTY BEZPEČNOSTNÍHO ZPEVNĚNÍ A5 (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/security_hardening_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE:
-- A5 sbírá nálezy bran z A2, A3 a A4 — věci, které nebyly dosažitelné dnes, ale
-- staly by se dosažitelnými ve fázích B–D. Přesně takové opravy se nejsnáz tiše
-- zruší, protože nic viditelného nerozbijí. Test je proto přišpendluje.
--
-- POUČENÍ Z A2b: tvrzení o právech se testují pod SKUTEČNOU rolí `authenticated`.
-- Jako `postgres` projde všechno — granty i RLS se na něj nevztahují.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale prošla', _popis;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Únik obsahu řádku z RPC (drift 8b)
--
-- Uvnitř SECURITY DEFINER neplatí RLS, takže Postgres do chyby doplní
-- „Failing row contains (…)" s celým řádkem — a PostgREST ho u RPC přepošle.
-- U rezervací je v tom řádku sazba i částka.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _hlaska text; _detail text;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text, true);

  -- Neexistující subjekt → porušení cizího klíče uvnitř definera.
  BEGIN
    PERFORM public.create_booking(
      p_sheet_ids := ARRAY[(SELECT id FROM public.sheets ORDER BY name LIMIT 1)],
      p_kind := 'training',
      p_title := 'Test úniku',
      p_start := (TIMESTAMP '2031-05-05 10:00' AT TIME ZONE 'Europe/Prague'),
      p_end   := (TIMESTAMP '2031-05-05 11:00' AT TIME ZONE 'Europe/Prague'),
      p_subject_id := '00000000-0000-0000-0000-0000000000ff');
    RAISE EXCEPTION 'TEST SELHAL: rezervace na neexistující subjekt prošla';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS _hlaska = MESSAGE_TEXT, _detail = PG_EXCEPTION_DETAIL;
    IF _hlaska LIKE 'TEST SELHAL%' THEN RAISE; END IF;
  END;

  PERFORM pg_temp.tvrd(position('Failing row' in COALESCE(_detail, '')) = 0,
    'RPC neposílá obsah řádku (žádné „Failing row contains")');
  PERFORM pg_temp.tvrd(_hlaska NOT LIKE '%rate_per_hour%' AND _hlaska NOT LIKE '%amount%',
    'hláška neobsahuje názvy peněžních sloupců');
  RAISE NOTICE '    (hláška: %)', _hlaska;
END $$;

-- Handler musí být ve VŠECH SECURITY DEFINER RPC, ne jen v tom, který jsem zkoušel.
DO $$
DECLARE _bez_handleru text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO _bez_handleru
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('create_booking','create_booking_series','update_booking',
                       'move_booking','cancel_booking','approve_reservation')
     AND p.prosrc !~ 'check_violation';
  PERFORM pg_temp.tvrd(_bez_handleru IS NULL,
    format('všechny rezervační RPC dusí chyby integrity (bez handleru: %s)', COALESCE(_bez_handleru, 'žádná')));
END $$;

-- -----------------------------------------------------------------------------
-- 2) `deleted_at IS NULL` v politice reservations_update (drift 8c)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _qual text;
BEGIN
  SELECT qual INTO _qual FROM pg_policies
   WHERE schemaname='public' AND tablename='reservations' AND policyname='reservations_update';
  PERFORM pg_temp.tvrd(_qual LIKE '%deleted_at IS NULL%',
    'reservations_update vylučuje soft-smazané rezervace');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Korekce hodin: strop 24 h a povinný důvod (drift 8e)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r uuid;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text, true);
  SELECT id INTO _r FROM public.reservations
   WHERE deleted_at IS NULL AND subject_id IS NOT NULL ORDER BY id LIMIT 1;

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET corrected_hours = 9999.75, correction_reason = %L WHERE id = %L', 'x', _r),
    'nejvýš 24', 'korekce 9 999,75 h odmítnuta (faktura na šest milionů)');

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET corrected_hours = 24.25, correction_reason = %L WHERE id = %L', 'x', _r),
    'nejvýš 24', 'korekce těsně nad stropem odmítnuta');

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET corrected_hours = 2 WHERE id = %L', _r),
    'potřeba důvod', 'korekce bez zdůvodnění odmítnuta');

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET corrected_hours = 2, correction_reason = %L WHERE id = %L', '   ', _r),
    'potřeba důvod', 'korekce s prázdným zdůvodněním odmítnuta');

  -- A co projít MÁ: strop je 24 včetně, a legitimní „led o půl hodiny déle“.
  UPDATE public.reservations SET corrected_hours = 24, correction_reason = 'celodenní turnaj' WHERE id = _r;
  PERFORM pg_temp.tvrd((SELECT corrected_hours FROM public.reservations WHERE id = _r) = 24,
    'korekce přesně 24 h projde (strop je včetně)');

  UPDATE public.reservations SET corrected_hours = 1.5, correction_reason = 'klub zůstal o půl hodiny déle' WHERE id = _r;
  PERFORM pg_temp.tvrd((SELECT corrected_hours FROM public.reservations WHERE id = _r) = 1.5,
    'naúčtovat VÍC, než bylo rezervováno, jde dál (proto strop není vázaný na rezervaci)');
END $$;

-- Bez triggeru musí držet i samotné CHECKy — trigger je hlas, constraint zámek.
DO $$
DECLARE _r uuid;
BEGIN
  SELECT id INTO _r FROM public.reservations
   WHERE deleted_at IS NULL AND subject_id IS NOT NULL ORDER BY id LIMIT 1;
  ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_z_money;

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET corrected_hours = 100, correction_reason = %L WHERE id = %L', 'x', _r),
    'reservations_corrected_hours_strop', 'bez triggeru drží CHECK: strop 24 h');
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET corrected_hours = 2, correction_reason = NULL WHERE id = %L', _r),
    'reservations_korekce_ma_duvod', 'bez triggeru drží CHECK: povinný důvod');

  ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_z_money;
END $$;

-- -----------------------------------------------------------------------------
-- 4) TRUNCATE a DELETE na peněžních tabulkách (drift 8d)
--    TRUNCATE je jediná operace, na kterou se RLS NEVZTAHUJE — proto granty.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r record; _zbyva text;
BEGIN
  SELECT string_agg(DISTINCT table_name || '.' || privilege_type, ', ') INTO _zbyva
    FROM information_schema.role_table_grants
   WHERE table_schema='public'
     AND table_name IN ('settings','subjects','reservations','audit_log','billing_settings')
     AND grantee IN ('anon','authenticated','PUBLIC')
     AND privilege_type IN ('TRUNCATE','DELETE');
  PERFORM pg_temp.tvrd(_zbyva IS NULL,
    format('na peněžních tabulkách nezůstal TRUNCATE ani DELETE (%s)', COALESCE(_zbyva, 'čisté')));
END $$;

SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu('TRUNCATE public.audit_log',
    'permission denied', 'anon nesmí vyprázdnit audit_log');
  PERFORM pg_temp.ocekavej_chybu('TRUNCATE public.reservations',
    'permission denied', 'anon nesmí vyprázdnit rezervace');
  PERFORM pg_temp.ocekavej_chybu('SELECT 1 FROM public.settings',
    'permission denied', 'anon nemá na ceník vůbec dosáhnout');
END $$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu('TRUNCATE public.reservations',
    'permission denied', 'ani admin nesmí vyprázdnit rezervace');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 5) Citlivá pole profilu jen vlastník + admin (drift 8f)
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;

-- Brigádník: svoje ano, cizí ne
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
DO $$
DECLARE _muj record; _cizi record; _spadlo boolean := false;
BEGIN
  BEGIN
    PERFORM phone FROM public.profiles LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo, 'brigádník: telefon z tabulky profiles nepřečte vůbec');

  SELECT * INTO _muj FROM public.profiles_self WHERE user_id = '33333333-3333-3333-3333-333333333333';
  PERFORM pg_temp.tvrd(_muj.bank_account IS NOT NULL, 'brigádník: SVŮJ bankovní účet vidí');
  PERFORM pg_temp.tvrd(_muj.smim_videt_udaje, 'brigádník: smim_videt_udaje je true u vlastního profilu');

  SELECT * INTO _cizi FROM public.profiles_self WHERE user_id = '22222222-2222-2222-2222-222222222222';
  PERFORM pg_temp.tvrd(_cizi.bank_account IS NULL, 'brigádník: CIZÍ bankovní účet nevidí');
  PERFORM pg_temp.tvrd(_cizi.phone IS NULL, 'brigádník: cizí telefon nevidí');
  PERFORM pg_temp.tvrd(_cizi.full_name IS NOT NULL,
    'brigádník: cizí JMÉNO vidí dál (na tom stojí celá aplikace)');
END $$;

-- Admin: vidí všechno
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _cizi record;
BEGIN
  SELECT * INTO _cizi FROM public.profiles_self WHERE user_id = '22222222-2222-2222-2222-222222222222';
  PERFORM pg_temp.tvrd(_cizi.bank_account IS NOT NULL, 'admin: cizí bankovní účet vidí (potřebuje ho na výplaty)');
  PERFORM pg_temp.tvrd(_cizi.phone IS NOT NULL, 'admin: cizí telefon vidí');
END $$;

RESET ROLE;

-- -----------------------------------------------------------------------------
-- 5b) `profiles_public` — pohled, kterým to teklo dál
--
-- Sama tabulka `profiles` byla zamčená, ale tenhle pohled má
-- `security_invoker = off`, takže obchází sloupcové granty i RLS. Maskoval jen
-- bankovní účet, ne telefon, a měl plná zápisová práva pro `anon` — takže se jím
-- daly číst telefony BEZ PŘIHLÁŠENÍ a zapisovat do cizích profilů.
--
-- Test na tabulku nestačí. Musí se ptát i na pohledy nad ní, jinak tvrdí zavřeno
-- o dveřích, vedle kterých je otevřené okno.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE anon;
DO $$
DECLARE _spadlo boolean := false;
BEGIN
  BEGIN
    PERFORM 1 FROM public.profiles_public;
  EXCEPTION WHEN insufficient_privilege THEN _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo, 'anon: na profiles_public nedosáhne vůbec');

  _spadlo := false;
  BEGIN
    UPDATE public.profiles_public SET full_name = 'HACKED'
     WHERE user_id = '22222222-2222-2222-2222-222222222222';
  EXCEPTION WHEN insufficient_privilege THEN _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo, 'anon: do cizího profilu přes pohled nezapíše');
END $$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
DO $$
DECLARE _cizi record; _spadlo boolean := false;
BEGIN
  SELECT * INTO _cizi FROM public.profiles_public
   WHERE user_id = '22222222-2222-2222-2222-222222222222';
  PERFORM pg_temp.tvrd(_cizi.phone IS NULL,
    'brigádník: cizí telefon nevidí ani přes profiles_public');
  PERFORM pg_temp.tvrd(_cizi.bank_account IS NULL,
    'brigádník: cizí účet nevidí ani přes profiles_public');
  PERFORM pg_temp.tvrd(_cizi.full_name IS NOT NULL,
    'brigádník: jméno přes profiles_public vidí (na tom stojí seznamy a směny)');

  BEGIN
    UPDATE public.profiles_public SET full_name = 'HACKED'
     WHERE user_id = '22222222-2222-2222-2222-222222222222';
  EXCEPTION WHEN insufficient_privilege THEN _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo, 'brigádník: přes pohled taky nezapíše (je jen ke čtení)');
END $$;
RESET ROLE;

-- Pozn.: kontrola „který pohled vydává telefon nebo účet bez maskování" je
-- v části 6 níž, plošně přes celé schéma. Dřív tu stála kontrola „nad profiles
-- nevznikl nový pohled", ta ale hlásila i `reservations_calendar`
-- a `reservations_billing` — ty na `profiles` sahají legitimně kvůli jménům.
-- Zajímá nás, CO pohled vydá, ne jestli na tabulku sáhl.

-- Legitimní cesty nesmí padnout: jména se čtou napříč aplikací.
DO $$
DECLARE _jmen int;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', '55555555-5555-5555-5555-555555555555')::text, true);
  SELECT count(*) INTO _jmen FROM public.profiles_public WHERE full_name IS NOT NULL;
  PERFORM pg_temp.tvrd(_jmen > 0, format('profiles_public dál vrací jména (%s)', _jmen));
END $$;

-- -----------------------------------------------------------------------------
-- 6) PLOŠNÉ kontroly — výčet tabulek je špatný nástroj
--
-- Obě brány u A5 našly totéž: kontrola na jmenovitém seznamu propustí všechno,
-- co v seznamu není. `TRUNCATE user_roles` jako anon procházel, protože tabulka
-- nebyla „peněžní" — a přitom `has_role()` je skoro v každé RLS politice, takže
-- její vyprázdnění rozpadne přístupová práva v celém systému.
--
-- Tyhle testy se proto ptají katalogu na CELÉ SCHÉMA, ne na výčet.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _zbyva text;
BEGIN
  SELECT string_agg(DISTINCT table_name || '/' || grantee, ', ') INTO _zbyva
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND privilege_type = 'TRUNCATE'
     AND grantee IN ('anon', 'authenticated', 'PUBLIC');
  PERFORM pg_temp.tvrd(_zbyva IS NULL,
    format('NIKDE v public nezůstal TRUNCATE pro anon/authenticated (%s)', COALESCE(_zbyva, 'čisté')));

  -- Nové tabulky ho nesmí dostat ani výchozími právy.
  --
  -- Ptáme se na výchozí práva role `postgres`, protože migrace běží pod ní
  -- a všechny tabulky v `public` vlastní ona. Supabase má vedle toho ještě
  -- výchozí práva role `supabase_admin`, na která `ALTER DEFAULT PRIVILEGES`
  -- z migrace nedosáhne (na hostované instanci není `postgres` superuser).
  -- Ta se uplatní jen na tabulky vytvořené `supabase_admin` — což tenhle projekt
  -- nedělá. Zbytkové riziko je tím pojmenované, ne přehlédnuté.
  SELECT string_agg(DISTINCT unnest_acl, ', ') INTO _zbyva
    FROM pg_default_acl d, unnest(d.defaclacl::text[]) AS unnest_acl
   WHERE d.defaclnamespace = 'public'::regnamespace
     AND d.defaclrole = 'postgres'::regrole
     AND unnest_acl ~ '^(anon|authenticated)=' AND unnest_acl ~ 'D';
  PERFORM pg_temp.tvrd(_zbyva IS NULL,
    format('nová tabulka od migrace nedostane TRUNCATE (%s)', COALESCE(_zbyva, 'čisté')));
END $$;

-- Žádný pohled v public nesmí mít pro anon/authenticated jiné právo než SELECT.
-- Přesně tímhle tekl `profiles_public`: byl auto-updatable, běžel pod vlastníkem,
-- takže RLS neplatila, a `anon` do něj mohl zapisovat i mazat.
DO $$
DECLARE _spatne text;
BEGIN
  SELECT string_agg(DISTINCT g.table_name || '/' || g.grantee || ':' || g.privilege_type, ', ')
    INTO _spatne
    FROM information_schema.role_table_grants g
    JOIN pg_class c ON c.relname = g.table_name
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
   WHERE g.table_schema = 'public' AND c.relkind = 'v'
     AND (g.grantee = 'anon'
          OR (g.grantee IN ('authenticated', 'PUBLIC')
              AND g.privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')))
     -- JEDINÁ POVOLENÁ VÝJIMKA, a jen na ČTENÍ: `clubs_public` vydává názvy klubů
     -- do rozbalovátka v registraci, což je veřejná stránka — bez toho by si
     -- uchazeč klub nevybral. Vydává jen `id` a `name`, nikdy IČO, adresu ani
     -- sazby, a zápis nemá. Výjimka je jmenovitá schválně: kdyby anonovi zpřístupnil
     -- pohled někdo příště, tenhle test se ozve dál.
     AND NOT (g.table_name = 'clubs_public' AND g.grantee = 'anon' AND g.privilege_type = 'SELECT');
  PERFORM pg_temp.tvrd(_spatne IS NULL,
    format('žádný pohled není zapisovatelný ani přístupný anonovi (%s)', COALESCE(_spatne, 'čisté')));
END $$;

-- Ta výjimka výš musí zůstat úzká. Kdyby `clubs_public` někdy začal vydávat víc
-- než id a název, výjimka by tiše propustila i to — tak se hlídá i jeho obsah.
DO $$
DECLARE _sloupce text;
BEGIN
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO _sloupce
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'clubs_public';
  PERFORM pg_temp.tvrd(_sloupce = 'id,name',
    format('veřejný pohled clubs_public vydává jen id a název (má: %s)', COALESCE(_sloupce, 'neexistuje')));

  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants
                 WHERE table_name = 'clubs_public' AND grantee = 'anon'
                   AND privilege_type <> 'SELECT'),
    'a nepřihlášený do něj nesmí zapisovat');
END $$;

-- Citlivá pole profilu nesmí vytéct ŽÁDNÝM pohledem, ne jen tabulkou.
-- Kontrola se dívá na definice: kdo vydává `phone` nebo `bank_account` bez CASE,
-- vydává je všem.
DO $$
DECLARE _r record; _spatne text := NULL;
BEGIN
  FOR _r IN
    SELECT c.relname, pg_get_viewdef(c.oid) AS def
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'v'
       AND pg_get_viewdef(c.oid) ~ '\m(phone|bank_account)\M'
  LOOP
    IF _r.def !~ 'CASE' THEN
      _spatne := COALESCE(_spatne || ', ', '') || _r.relname;
    END IF;
  END LOOP;
  PERFORM pg_temp.tvrd(_spatne IS NULL,
    format('žádný pohled nevydává telefon ani účet bez maskování (%s)', COALESCE(_spatne, 'čisté')));
END $$;

-- -----------------------------------------------------------------------------
-- 7) Co MUSÍ jít dál: soft-delete rezervace
--
-- `USING (deleted_at IS NULL)` je záměr. Kdyby ale táž podmínka byla i ve
-- `WITH CHECK`, nešlo by `deleted_at` vůbec NASTAVIT — a protože A5 odebrala
-- i DELETE, rezervace by nešla odstranit nijak. To je opak zásady „nemazat
-- natvrdo, ale jít to musí".
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _r uuid; _po timestamptz;
BEGIN
  SELECT id INTO _r FROM public.reservations WHERE deleted_at IS NULL ORDER BY id LIMIT 1;
  UPDATE public.reservations SET deleted_at = now() WHERE id = _r;

  RESET ROLE;
  SELECT deleted_at INTO _po FROM public.reservations WHERE id = _r;
  SET LOCAL ROLE authenticated;

  PERFORM pg_temp.tvrd(_po IS NOT NULL, 'admin smí rezervaci soft-smazat');
END $$;
RESET ROLE;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
