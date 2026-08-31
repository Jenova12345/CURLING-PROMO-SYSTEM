-- =============================================================================
-- TESTY: trenér — viditelnost, přání a jednoznačný klub
-- Migrace 20260831233000_trener_prava.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/trener_prava_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Nález, který by se projevil první den provozu: zástupce klubu trenéra
-- PŘIŘADIL, ale neuviděl — a přiřazoval znovu, takže vznikaly duplicitní
-- PLACENÉ směny. Nejcennější je proto dvojice tvrzení „ze `shifts` nevidí nic"
-- + „přes `trener_akce` vidí jméno, ale ne sazbu".
--
-- Všechno kolem práv běží pod `SET LOCAL ROLE authenticated` (pravidlo 8).
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
  IF NOT COALESCE(_podminka, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
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

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- Příprava: trénink klubu CK Ostravské kameny, autor = ČLEN (55555555),
-- zástupce klubu = 44444444, trenér = 22222222.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _klub uuid; _rez uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';

  INSERT INTO public.user_roles (user_id, role)
  VALUES ('22222222-2222-2222-2222-222222222222','trainer') ON CONFLICT DO NOTHING;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST trener prava','training','2027-05-12 17:00+02','2027-05-12 19:00+02',
          '55555555-5555-5555-5555-555555555555') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, created_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _klub, _ev,
          '2027-05-12 17:00+02','2027-05-12 19:00+02','55555555-5555-5555-5555-555555555555')
  RETURNING id INTO _rez;

  PERFORM public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');
  INSERT INTO _s VALUES ('ev',_ev::text), ('rez',_rez::text), ('klub',_klub::text);
END $$;

-- -----------------------------------------------------------------------------
-- 1) ZÁSTUPCE TRENÉRA VIDÍ — ale ne přes `shifts`
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _r record; _pocet int;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'kontrola práv běží jako authenticated, ne jako postgres');

  -- Tohle je PŮVODNÍ cesta, kterou používalo UI. Vrací nula řádků BEZ CHYBY —
  -- proto se to nikomu neprojevilo jako chyba práv, ale jako „trenér není".
  SELECT count(*) INTO _pocet FROM public.shifts
   WHERE event_id = _ev AND required_role = 'trainer' AND status <> 'cancelled';
  PERFORM pg_temp.tvrd(_pocet = 0,
    'zástupce ze `shifts` nevidí NIC (a bez chyby) — proto UI tvrdilo „trenér nepřiřazen"');

  SELECT * INTO _r FROM public.trener_akce(_ev);
  PERFORM pg_temp.tvrd(_r.user_id = '22222222-2222-2222-2222-222222222222',
    'přes trener_akce() zástupce trenéra VIDÍ');
  PERFORM pg_temp.tvrd(_r.jmeno IS NOT NULL, '… i se jménem, aby ho nemusel dohledávat');
  PERFORM pg_temp.tvrd(_r.hourly_rate IS NULL,
    '… ale SAZBU ne — mzdový náklad haly klubu nepatří');

  EXECUTE 'RESET ROLE';
END $$;

-- Autor rezervace (člen klubu) taky vidí; cizí člověk nic.
DO $$
DECLARE _ev uuid; _r record; _pocet int;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT * INTO _r FROM public.trener_akce(_ev);
  PERFORM pg_temp.tvrd(_r.user_id IS NOT NULL, 'člen klubu (a autor rezervace) trenéra vidí');
  PERFORM pg_temp.tvrd(_r.hourly_rate IS NULL, '… taky bez sazby');
  EXECUTE 'RESET ROLE';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _pocet FROM public.trener_akce(_ev);
  PERFORM pg_temp.tvrd(_pocet = 0, 'cizí člověk (brigádník bez klubu) se nedozví nic');
  EXECUTE 'RESET ROLE';
END $$;

-- Admin vidí i sazbu — je to jeho mzdový náklad.
DO $$
DECLARE _ev uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT * INTO _r FROM public.trener_akce(_ev);
  PERFORM pg_temp.tvrd(_r.hourly_rate IS NOT NULL, 'admin sazbu trenérské směny vidí');
  EXECUTE 'RESET ROLE';
END $$;

-- -----------------------------------------------------------------------------
-- 2) PŘÁNÍ TRENÉRA V KALENDÁŘI VIDÍ JEN OKRUH KOLEM AKCE
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rez uuid;
BEGIN
  SELECT hodnota::uuid INTO _rez FROM _s WHERE klic='rez';
  PERFORM public.nastav_prani_trenera(ARRAY[_rez], '22222222-2222-2222-2222-222222222222');

  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(
    (SELECT preferovany_trener_jmeno FROM public.reservations_calendar WHERE id = _rez) IS NOT NULL,
    'zástupce klubu přání v kalendáři vidí');
  EXECUTE 'RESET ROLE';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(
    (SELECT preferovany_trener FROM public.reservations_calendar WHERE id = _rez) IS NULL
    AND (SELECT preferovany_trener_jmeno FROM public.reservations_calendar WHERE id = _rez) IS NULL,
    'cizí přihlášený uživatel přání NEVIDÍ (dřív si vyjel, koho chce který klub)');
  PERFORM pg_temp.tvrd(
    (SELECT subject_name FROM public.reservations_calendar WHERE id = _rez) IS NOT NULL,
    '… ale obsazenost a název klubu vidí dál (rozhodnutí klienta z 31. 7.)');
  EXECUTE 'RESET ROLE';
END $$;

-- -----------------------------------------------------------------------------
-- 3) PŘÁNÍ SE NEDÁ PODSTRČIT
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rez uuid; _ev2 uuid; _rez2 uuid; _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _rez  FROM _s WHERE klic='rez';
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic='klub';

  -- Zpátky pod admina: `request.jwt.claims` je transakčně lokální a drží se
  -- i mezi DO bloky, takže by sem jinak propadl uživatel z předchozí sekce.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.nastav_prani_trenera(ARRAY[%L]::uuid[], %L)', _rez,
           '33333333-3333-3333-3333-333333333333'),
    'není vedený jako trenér',
    'přání nejde pověsit na člověka bez role trenéra');

  -- Turnaj: přání trenéra tam nedává smysl (dřív to hlídalo jen UI).
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST turnaj prani','tournament','2027-05-19 17:00+02','2027-05-19 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev2;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _klub, _ev2,
          '2027-05-19 17:00+02','2027-05-19 19:00+02')
  RETURNING id INTO _rez2;

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.nastav_prani_trenera(ARRAY[%L]::uuid[], %L)', _rez2,
           '22222222-2222-2222-2222-222222222222'),
    'jen u tréninku', 'přání nejde pověsit na turnaj');
END $$;

-- Člen klubu si přání na SVOJI rezervaci nastavit smí — a dřív mu to padalo
-- na whitelistu v guardu, přestože je funkce určená právě jemu.
DO $$
DECLARE _rez uuid; _v jsonb;
BEGIN
  SELECT hodnota::uuid INTO _rez FROM _s WHERE klic='rez';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  _v := public.nastav_prani_trenera(ARRAY[_rez], '22222222-2222-2222-2222-222222222222');
  PERFORM pg_temp.tvrd((_v->>'zmeneno')::int = 1,
    'člen klubu si přání na SVOJI rezervaci nastaví (dřív mu to guard shodil)');

  -- A přímý zápis do sloupce ať pořád nejde — jinak by RPC byla jen ozdoba.
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET preferovany_trener = %L WHERE id = %L',
           '11111111-1111-1111-1111-111111111111', _rez),
    'smí měnit jen správce', '… ale přímým zápisem do sloupce to pořád nejde');

  EXECUTE 'RESET ROLE';
END $$;

-- Cizí člověk na cizí rezervaci nesmí.
DO $$
DECLARE _rez uuid;
BEGIN
  SELECT hodnota::uuid INTO _rez FROM _s WHERE klic='rez';
  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.nastav_prani_trenera(ARRAY[%L]::uuid[], %L)', _rez,
           '22222222-2222-2222-2222-222222222222'),
    'nemáte právo', 'cizí člověk přání na cizí rezervaci nenastaví');
  EXECUTE 'RESET ROLE';
END $$;

-- -----------------------------------------------------------------------------
-- 4) AKCE S DRAHAMI DVOU KLUBŮ — zástupce k ní trenéra nepřipne
--
-- Dřív o tom, ČÍ zástupce smí, rozhodoval `LIMIT 1` bez `ORDER BY`, tedy
-- plánovač.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _k1 uuid; _k2 uuid; _d1 uuid; _d2 uuid;
BEGIN
  SELECT id INTO _k1 FROM public.subjects WHERE name = 'CK Ostravské kameny';
  SELECT id INTO _k2 FROM public.subjects WHERE name = 'Curling Ostrava';
  SELECT id INTO _d1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _d2 FROM public.sheets WHERE active AND id <> _d1 ORDER BY name LIMIT 1;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST dva kluby','training','2027-05-26 17:00+02','2027-05-26 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES (_d1, _k1, _ev, '2027-05-26 17:00+02','2027-05-26 19:00+02'),
         (_d2, _k2, _ev, '2027-05-26 17:00+02','2027-05-26 19:00+02');

  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.prirad_trenera(%L, %L)', _ev, '22222222-2222-2222-2222-222222222222'),
    'správce haly nebo zástupce klubu',
    'u akce s drahami dvou klubů zástupce trenéra nepřiřadí (dřív rozhodoval plánovač)');
  EXECUTE 'RESET ROLE';

  -- Admin ano — je to jeho hala. (Claims se drží mezi bloky, tak zpátky na admina.)
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  PERFORM public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _ev AND required_role = 'trainer' AND status <> 'cancelled') = 1,
    '… ale správce haly ano');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
