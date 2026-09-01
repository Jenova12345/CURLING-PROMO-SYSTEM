-- =============================================================================
-- TESTY: úprava schválené rezervace ji vrací k potvrzení (bug #5)
-- Migrace 20260902110000_uprava_rusi_schvaleni.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/schvaleni_po_uprave_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- `fakturovatelne_rezervace` bere `approved_at IS NOT NULL` jako „potvrzeno".
-- Když tedy schválenou rezervaci někdo přesune do levnějšího pásma a razítko
-- zůstane, vyfakturuje se částka, kterou nikdo neodkýval. Nejcennější tvrzení
-- je první: přesun času schválení SHODÍ.
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

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- Založí SCHVÁLENOU klubovou rezervaci 17–19 (večerní pásmo, 2 400 Kč).
--
-- KAŽDÉ VOLÁNÍ NA JINÝ DEN: dráha i čas jsou pořád stejné, takže druhá
-- rezervace ve stejném slotu narazí na `reservations_no_overlap`. Posun po
-- dnech je jednodušší než žonglovat s drahami a nechává všechny rezervace
-- ve VEČERNÍM pásmu, na kterém test stojí.
CREATE TEMP SEQUENCE IF NOT EXISTS _den;
CREATE OR REPLACE FUNCTION pg_temp.schvalena(_poznamka text) RETURNS uuid
 LANGUAGE plpgsql AS $$
DECLARE _ev uuid; _id uuid; _od timestamptz; _do timestamptz;
BEGIN
  -- listopad 2028: 1. 11. je středa, takže +n dní drží všední dny i víkendy
  -- ve stejném pásmu jen do soboty — sekvence se proto posouvá po TÝDNECH.
  _od := timestamptz '2028-11-01 17:00+01' + (nextval('_den') * interval '7 days');
  _do := _od + interval '2 hours';
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES (_poznamka,'training',_od,_do,
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, note,
                                   approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name='CK Ostravské kameny'), _ev,
          _od, _do, _poznamka,
          now(),'11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _id;
  RETURN _id;
END $$;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: přesun do jiného pásma shodí schválení
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _pred numeric; _po numeric;
BEGIN
  _id := pg_temp.schvalena('TEST presun');
  SELECT amount INTO _pred FROM public.reservations WHERE id=_id;
  PERFORM pg_temp.tvrd(_pred = 2400, 'příprava: schválená rezervace 17–19 za 2 400 Kč');

  PERFORM public.move_booking(_id,
    (SELECT date_trunc('day', start_at AT TIME ZONE 'Europe/Prague') + interval '9 hours'
       FROM public.reservations WHERE id=_id) AT TIME ZONE 'Europe/Prague',
    (SELECT date_trunc('day', start_at AT TIME ZONE 'Europe/Prague') + interval '11 hours'
       FROM public.reservations WHERE id=_id) AT TIME ZONE 'Europe/Prague', NULL);

  SELECT amount INTO _po FROM public.reservations WHERE id=_id;
  PERFORM pg_temp.tvrd(_po = 1600, 'přesun na ráno cenu srazil na 1 600 Kč');
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations WHERE id=_id) IS NULL,
    'PŘESUN SHODIL SCHVÁLENÍ (jádro bugu #5)');
  PERFORM pg_temp.tvrd(
    (SELECT approved_by FROM public.reservations WHERE id=_id) IS NULL,
    '… včetně toho, kdo schvaloval');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.fakturovatelne_rezervace(
                  (SELECT subject_id FROM public.reservations WHERE id=_id),
                  '2028-11-01','2029-01-01') f WHERE f.id=_id),
    '… a rezervace vypadla z fakturace, dokud ji někdo znovu nepotvrdí');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Další cesty, které hýbou cenou
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _ev uuid;
BEGIN
  _id := pg_temp.schvalena('TEST sazba');
  SELECT event_id INTO _ev FROM public.reservations WHERE id=_id;
  PERFORM public.uprav_sazbu_akce(_ev, 900);
  PERFORM pg_temp.tvrd((SELECT approved_at FROM public.reservations WHERE id=_id) IS NULL,
    'přecenění akce (uprav_sazbu_akce) taky shodí schválení');

  _id := pg_temp.schvalena('TEST typ');
  SELECT event_id INTO _ev FROM public.reservations WHERE id=_id;
  PERFORM public.zmen_typ_akce(_ev, 'commercial');
  PERFORM pg_temp.tvrd((SELECT approved_at FROM public.reservations WHERE id=_id) IS NULL,
    'změna typu akce taky');

  _id := pg_temp.schvalena('TEST draha');
  UPDATE public.reservations
     SET sheet_id = (SELECT id FROM public.sheets WHERE active AND id <> (SELECT sheet_id FROM public.reservations WHERE id=_id) ORDER BY name LIMIT 1)
   WHERE id = _id;
  PERFORM pg_temp.tvrd((SELECT approved_at FROM public.reservations WHERE id=_id) IS NULL,
    'změna dráhy taky');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Co schválení shodit NESMÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid;
BEGIN
  _id := pg_temp.schvalena('TEST poznamka');
  UPDATE public.reservations SET note = 'jen poznámka' WHERE id=_id;
  PERFORM pg_temp.tvrd((SELECT approved_at FROM public.reservations WHERE id=_id) IS NOT NULL,
    'změna poznámky schválení NESHODÍ (cenou nehýbe)');

  -- Korekce po akci: zadává ji admin až po odehrání, nové schválení nedává smysl.
  UPDATE public.reservations SET corrected_hours = 1, correction_reason = 'hráli hodinu' WHERE id=_id;
  PERFORM pg_temp.tvrd((SELECT approved_at FROM public.reservations WHERE id=_id) IS NOT NULL,
    'korekce po akci schválení NESHODÍ (vědomá výjimka)');

  -- A samotné schvalování se nesmí shodit samo.
  _id := pg_temp.schvalena('TEST znovu');
  UPDATE public.reservations SET approved_at = NULL, approved_by = NULL WHERE id=_id;
  PERFORM public.approve_reservation(_id);
  PERFORM pg_temp.tvrd((SELECT approved_at FROM public.reservations WHERE id=_id) IS NOT NULL,
    'approve_reservation() razítko nastaví a trigger ho neshodí');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
