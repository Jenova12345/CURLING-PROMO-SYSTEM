-- =============================================================================
-- TESTY: správce klubu (subject_reps.level = 'rep')
-- Migrace 20260902140000_spravce_klubu_uprava.sql
-- =============================================================================
-- Role „správce klubu" NENÍ nová — je to `subject_reps.level = 'rep'` z Etapy 3
-- (R2: vztah ke klubu, ne globální role). Tenhle soubor je proto z větší části
-- REGRESNÍ: přišpendluje, co role uměla už předtím, aby to nikdo omylem
-- nezrušil při dalších zásazích do schvalování. Nové je jen chování při
-- úpravě vlastní rezervace.
--
-- Všechno běží pod `SET LOCAL ROLE authenticated` (pravidlo 8).
--
-- Seed: 44444444 = správce CK Ostravské kameny, 55555555 = řadový člen téhož
-- klubu, 22222222 = správce JINÉHO klubu (Curling Ostrava).
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

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_p boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_p, false) THEN RAISE EXCEPTION 'TEST SELHAL: %', _popis; END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis; RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): mělo to skončit chybou, ale prošlo', _popis;
END $$;

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);
INSERT INTO public.user_roles (user_id, role)
VALUES ('55555555-5555-5555-5555-555555555555','pro_player') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pg_temp.jako(_uid text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', _uid), true);
END $$;

-- -----------------------------------------------------------------------------
-- 1) ZAKLÁDÁNÍ: správce rovnou schválený, profi hráč čeká
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _d1 uuid; _d2 uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name='CK Ostravské kameny';
  SELECT id INTO _d1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _d2 FROM public.sheets WHERE active AND id <> _d1 ORDER BY name LIMIT 1;
  INSERT INTO _s VALUES ('klub',_klub::text), ('d1',_d1::text), ('d2',_d2::text);

  PERFORM pg_temp.jako('44444444-4444-4444-4444-444444444444');
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(current_user='authenticated', 'testy práv běží jako authenticated');
  PERFORM public.create_booking(ARRAY[_d1],'training','TEST správce',
          '2029-03-07 17:00+01','2029-03-07 19:00+01', _klub);
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations r JOIN public.events e ON e.id=r.event_id
      WHERE e.title='TEST správce') IS NOT NULL,
    'SPRÁVCE KLUBU: vlastní rezervace je rovnou schválená');

  PERFORM pg_temp.jako('55555555-5555-5555-5555-555555555555');
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.create_booking(ARRAY[_d2],'training','TEST profi',
          '2029-03-07 17:00+01','2029-03-07 19:00+01', _klub);
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations r JOIN public.events e ON e.id=r.event_id
      WHERE e.title='TEST profi') IS NULL,
    'PROFI HRÁČ: jeho rezervace ČEKÁ na potvrzení');
END $$;

-- -----------------------------------------------------------------------------
-- 2) POTVRZOVÁNÍ: jen svůj klub
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rez uuid;
BEGIN
  SELECT r.id INTO _rez FROM public.reservations r JOIN public.events e ON e.id=r.event_id
   WHERE e.title='TEST profi';

  -- Správce JINÉHO klubu na ni nesmí.
  PERFORM pg_temp.jako('22222222-2222-2222-2222-222222222222');
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_reservation(%L)', _rez),
    'zástupce klubu nebo správce',
    'správce CIZÍHO klubu rezervaci nepotvrdí');
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.jako('44444444-4444-4444-4444-444444444444');
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.approve_reservation(_rez);
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations WHERE id=_rez) IS NOT NULL,
    'správce SVÉHO klubu rezervaci člena potvrdí');
END $$;

-- -----------------------------------------------------------------------------
-- 3) ÚPRAVA VLASTNÍ REZERVACE — souhra s #5
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rez uuid; _kdo uuid;
BEGIN
  SELECT r.id INTO _rez FROM public.reservations r JOIN public.events e ON e.id=r.event_id
   WHERE e.title='TEST správce';

  PERFORM pg_temp.jako('44444444-4444-4444-4444-444444444444');
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.move_booking(_rez, '2029-03-07 09:00+01','2029-03-07 11:00+01', NULL);
  EXECUTE 'RESET ROLE';

  SELECT approved_by INTO _kdo FROM public.reservations WHERE id=_rez;
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations WHERE id=_rez) IS NOT NULL,
    'SPRÁVCE po přesunu vlastní rezervace NESTOJÍ frontu — razítko se přerazí');
  PERFORM pg_temp.tvrd(_kdo = '44444444-4444-4444-4444-444444444444',
    '… a v razítku je ON, tedy ten, kdo cenu doopravdy odsouhlasil');
  PERFORM pg_temp.tvrd(
    (SELECT amount FROM public.reservations WHERE id=_rez) = 1600,
    '… cena se přitom opravdu změnila (2 400 → 1 600 Kč)');
END $$;

-- Členovi (profi hráči) razítko po jeho vlastní úpravě dál PADÁ.
DO $$
DECLARE _rez uuid;
BEGIN
  SELECT r.id INTO _rez FROM public.reservations r JOIN public.events e ON e.id=r.event_id
   WHERE e.title='TEST profi';
  PERFORM pg_temp.jako('55555555-5555-5555-5555-555555555555');
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.move_booking(_rez, '2029-03-07 13:00+01','2029-03-07 15:00+01', NULL);
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations WHERE id=_rez) IS NULL,
    'PROFI HRÁČ: jeho úprava razítko shodí a čeká na správce (#5 platí dál)');
END $$;

-- ADMINOVA úprava razítko SHODÍ — i když admin schvalovat smí.
-- Když cenu změní hala, klub o tom neví a musí ji potvrdit sám. To je jádro #5.
DO $$
DECLARE _rez uuid; _ev uuid;
BEGIN
  SELECT r.id, r.event_id INTO _rez, _ev FROM public.reservations r
    JOIN public.events e ON e.id=r.event_id WHERE e.title='TEST správce';
  PERFORM pg_temp.jako('11111111-1111-1111-1111-111111111111');
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.uprav_sazbu_akce(_ev, 900);
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations WHERE id=_rez) IS NULL,
    'ADMIN přecení akci → razítko SPADNE, klub musí potvrdit znovu (jádro #5)');
END $$;

-- -----------------------------------------------------------------------------
-- 4) CO SPRÁVCE KLUBU NESMÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _cizi uuid; _d1 uuid; _n bigint;
BEGIN
  -- Vše z `_s` se čte JEŠTĚ jako postgres: dočasná tabulka patří jemu a role
  -- `authenticated` na ni nemá grant (narazil jsem na to — „permission denied
  -- for table _s"). Do proměnných tedy dřív, přepnout role až potom.
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic='klub';
  SELECT hodnota::uuid INTO _d1   FROM _s WHERE klic='d1';
  SELECT id INTO _cizi FROM public.subjects WHERE type='club' AND id <> _klub AND deleted_at IS NULL LIMIT 1;

  PERFORM pg_temp.jako('44444444-4444-4444-4444-444444444444');
  EXECUTE 'SET LOCAL ROLE authenticated';

  SELECT count(*) INTO _n FROM public.cenik_pasma;            PERFORM pg_temp.tvrd(_n=0,'peníze: ceník ledu nevidí');
  SELECT count(*) INTO _n FROM public.reservations_billing;   PERFORM pg_temp.tvrd(_n=0,'peníze: „Kdo kolik dluží" nevidí');
  SELECT count(*) INTO _n FROM public.subjects_rates;         PERFORM pg_temp.tvrd(_n=0,'peníze: sazby subjektů nevidí');
  SELECT count(*) INTO _n FROM public.invoices_list;          PERFORM pg_temp.tvrd(_n=0,'peníze: faktury nevidí');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L]::uuid[],''training'',''TEST cizi'',
            ''2029-03-14 17:00+01'',''2029-03-14 19:00+01'',%L)',
           _d1, _cizi),
    'nemáte oprávnění', 'cizí klub: rezervaci za něj nezaloží');

  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.user_roles (user_id, role)
       VALUES ('44444444-4444-4444-4444-444444444444','admin')$q$,
    'row-level security', 'nepovýší sám sebe na admina');
  PERFORM pg_temp.ocekavej_chybu(
    $q$INSERT INTO public.subject_reps (subject_id, user_id, level)
       VALUES ((SELECT id FROM public.subjects WHERE name='CK Ostravské kameny'),
               '33333333-3333-3333-3333-333333333333','rep')$q$,
    'row-level security', 'nejmenuje dalšího správce klubu');

  EXECUTE 'RESET ROLE';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
