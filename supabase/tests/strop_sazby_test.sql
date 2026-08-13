-- =============================================================================
-- TESTY STROPU SAZBY 50 000 Kč/h (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/strop_sazby_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE:
-- `rate_per_hour` byl do 13. 8. 2026 jediný neomezený peněžní vstup v systému —
-- `99999999 Kč/h` prošlo a udělalo z rezervace fakturu na sto milionů. A5 zavřela
-- druhý činitel součinu (korekce hodin ≤ 24 h), tenhle test hlídá první.
--
-- Strop je produktové rozhodnutí PM, ne technikálie. Právě proto se snadno tiše
-- zruší: nic viditelného nerozbije a číslo v CHECKu vypadá jako libovolná
-- konstanta. Test ho přišpendluje spolu s hláškou, kterou uživatel uvidí.
--
-- POUČENÍ Z A2b: tvrzení o právech a o cestě přes RPC se testují pod SKUTEČNOU
-- rolí `authenticated`. Jako `postgres` projde všechno — granty i RLS se na něj
-- nevztahují.
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
-- 1) CHECKy existují na VŠECH čtyřech zdrojích sazby
--
-- Nejen na `reservations`: sazba se tam dopočítává z ceníku a ze sazby subjektu
-- (`trg_reservations_pricing`), takže strop jen na rezervaci by šlo obejít
-- zápisem do ceníku — a projevilo by se to až o krok dál, hláškou o sazbě,
-- kterou nikdo nezadával.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _chybi text;
BEGIN
  SELECT string_agg(ocekavany, ', ') INTO _chybi
    FROM unnest(ARRAY['reservations_rate_per_hour_strop', 'subjects_default_rate_strop',
                      'settings_club_rate_strop', 'settings_commercial_rate_strop',
                      'settings_tournament_rate_strop', 'settings_training_rate_strop']) AS ocekavany
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = ocekavany);
  PERFORM pg_temp.tvrd(_chybi IS NULL, format('strop má CHECK na všech zdrojích sazby (%s)', COALESCE(_chybi, 'všechny')));
END $$;

-- -----------------------------------------------------------------------------
-- 2) Rezervace: hranice je 50 000 včetně
--
-- Testuje se na kopii existující rezervace, ne na `UPDATE … LIMIT 1` napříč
-- tabulkou — test nesmí záviset na tom, kterou rezervaci seed vyrobil první.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid;
BEGIN
  SELECT id INTO _id FROM public.reservations WHERE deleted_at IS NULL ORDER BY start_at LIMIT 1;
  PERFORM pg_temp.tvrd(_id IS NOT NULL, 'seed má aspoň jednu rezervaci k testování');

  -- Přesně na stropu projde.
  UPDATE public.reservations SET rate_per_hour = 50000 WHERE id = _id;
  PERFORM pg_temp.tvrd(
    (SELECT rate_per_hour FROM public.reservations WHERE id = _id) = 50000,
    'sazba přesně 50 000 Kč/h projde (strop je včetně)');

  -- O korunu výš ne.
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET rate_per_hour = 50001 WHERE id = %L', _id),
    'nejvýš 50 000', 'sazba 50 001 Kč/h neprojde');

  -- Původní překlep z driftu 8g.
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET rate_per_hour = 99999999 WHERE id = %L', _id),
    'nejvýš 50 000', 'sazba 99 999 999 Kč/h (drift 8g) neprojde');

  -- Reálné sazby se strop nesmí dotknout — jinak by chytal ceník, ne překlepy.
  UPDATE public.reservations SET rate_per_hour = 1500 WHERE id = _id;
  PERFORM pg_temp.tvrd(
    (SELECT rate_per_hour FROM public.reservations WHERE id = _id) = 1500,
    'běžná sazba 1 500 Kč/h projde beze změny');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Hláška mluví česky a nevysype obsah řádku
--
-- Trigger `trg_reservations_z_money` je `SECURITY DEFINER`, takže bez něj by
-- promluvil syrový CHECK — a u RPC posílá PostgREST klientovi `DETAIL: Failing
-- row contains (…)` i se sazbou a částkou (drift 8b, uzavřený v A5). Test hlídá
-- obojí naráz: srozumitelnost i to, že A5 zůstala v platnosti.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _hlaska text; _detail text;
BEGIN
  SELECT id INTO _id FROM public.reservations WHERE deleted_at IS NULL ORDER BY start_at LIMIT 1;
  BEGIN
    EXECUTE format('UPDATE public.reservations SET rate_per_hour = 60000 WHERE id = %L', _id);
    RAISE EXCEPTION 'TEST SELHAL: sazba 60 000 Kč/h prošla';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS _hlaska = MESSAGE_TEXT, _detail = PG_EXCEPTION_DETAIL;
    IF _hlaska LIKE 'TEST SELHAL%' THEN RAISE; END IF;
  END;

  PERFORM pg_temp.tvrd(position('violates check constraint' in _hlaska) = 0,
    'hláška o stropu není syrový CHECK (mluví trigger, ne Postgres)');
  PERFORM pg_temp.tvrd(position('překlep' in _hlaska) > 0,
    'hláška o stropu pojmenuje pravděpodobnou příčinu (překlep)');
  PERFORM pg_temp.tvrd(position('Failing row' in COALESCE(_detail, '')) = 0,
    'hláška o stropu nevysype obsah řádku (drift 8b zůstává zavřený)');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Ceník a sazba subjektu
--
-- Tady žádný trigger není a je to schválně: formuláře chytí hodnotu dřív
-- (`parseSazba`, tatáž mez 50 000 v `src/lib/money.ts`) a CHECK je poslední
-- obrana. Test proto ověřuje jen to, že obrana drží.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid;
BEGIN
  SELECT id INTO _id FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1;
  PERFORM pg_temp.tvrd(_id IS NOT NULL, 'seed má aspoň jeden subjekt k testování');

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.subjects SET default_rate = 50001 WHERE id = %L', _id),
    'subjects_default_rate_strop', 'sazba subjektu nad stropem neprojde');

  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.settings SET club_default_rate = 50001',
    'settings_club_rate_strop', 'klubová sazba v ceníku nad stropem neprojde');
  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.settings SET commercial_default_rate = 99999999',
    'settings_commercial_rate_strop', 'komerční sazba v ceníku nad stropem neprojde');
  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.settings SET tournament_rate = 50001',
    'settings_tournament_rate_strop', 'turnajová sazba v ceníku nad stropem neprojde');
  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.settings SET training_rate = 50001',
    'settings_training_rate_strop', 'tréninková sazba v ceníku nad stropem neprojde');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Cesta, kudy se sazba doopravdy zadává: RPC pod rolí `authenticated`
--
-- `create_booking` bere `p_rate` bez validace a volat ho může každý přihlášený
-- admin — to je důvod, proč A2 vůbec zavedla trigger s českou hláškou. Test
-- běží pod skutečnou rolí, ne jako `postgres`: jinak by tvrdil zavřeno o dveřích,
-- vedle kterých je otevřené okno.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _sheet uuid; _subjekt uuid; _hlaska text; _detail text;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _subjekt FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1;

  BEGIN
    PERFORM public.create_booking(
      p_sheet_ids := ARRAY[_sheet],
      p_kind := 'training',
      p_title := 'Test stropu sazby',
      p_start := (TIMESTAMP '2031-06-03 10:00' AT TIME ZONE 'Europe/Prague'),
      p_end   := (TIMESTAMP '2031-06-03 11:00' AT TIME ZONE 'Europe/Prague'),
      p_subject_id := _subjekt,
      p_rate  := 99999999);
    RAISE EXCEPTION 'TEST SELHAL: RPC create_booking pustilo sazbu 99 999 999 Kč/h';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS _hlaska = MESSAGE_TEXT, _detail = PG_EXCEPTION_DETAIL;
    IF _hlaska LIKE 'TEST SELHAL%' THEN RAISE; END IF;
  END;

  PERFORM pg_temp.tvrd(position('nejvýš 50 000' in _hlaska) > 0,
    format('RPC odmítne sazbu nad stropem českou hláškou (přišlo: %s)', left(_hlaska, 80)));
  PERFORM pg_temp.tvrd(position('Failing row' in COALESCE(_detail, '')) = 0,
    'RPC při odmítnutí nevysype obsah řádku');
END $$;

-- Rezervace se stropovou sazbou naopak vzniknout musí — kdyby strop blokoval
-- i platný vstup, byl by to výpadek provozu, ne pojistka.
DO $$
DECLARE _sheet uuid; _subjekt uuid; _vysledek jsonb;
BEGIN
  SELECT id INTO _sheet FROM public.sheets ORDER BY name LIMIT 1;
  SELECT id INTO _subjekt FROM public.subjects WHERE deleted_at IS NULL ORDER BY name LIMIT 1;
  _vysledek := public.create_booking(
    p_sheet_ids := ARRAY[_sheet],
    p_kind := 'training',
    p_title := 'Test stropu sazby — na hranici',
    p_start := (TIMESTAMP '2031-06-04 10:00' AT TIME ZONE 'Europe/Prague'),
    p_end   := (TIMESTAMP '2031-06-04 11:00' AT TIME ZONE 'Europe/Prague'),
    p_subject_id := _subjekt,
    p_rate  := 50000);
  PERFORM pg_temp.tvrd(_vysledek IS NOT NULL, 'RPC pustí sazbu přesně na stropu');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 6) Shoda obou stran: mez v `src/lib/money.ts` musí sedět na CHECK
--
-- Tady se dá ověřit jen SQL strana. Kdyby se čísla rozešla, formulář pustí
-- hodnotu, kterou databáze odmítne — proto je konstanta v CHECKu vytažená
-- z katalogu a porovnaná s očekáváním, ne jen „nějaký strop existuje".
-- -----------------------------------------------------------------------------
DO $$
DECLARE _def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO _def
    FROM pg_constraint WHERE conname = 'reservations_rate_per_hour_strop';
  PERFORM pg_temp.tvrd(position('50000' in _def) > 0,
    format('CHECK drží hodnotu 50 000 (SAZBA_STROP v money.ts musí být stejná): %s', _def));
END $$;

ROLLBACK;
