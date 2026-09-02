-- =============================================================================
-- TESTY: jedna UPDATE politika na shifts + řazení rolí v chat_groups
-- Migrace 20260902240000_shifts_jedna_politika.sql
-- =============================================================================
-- CO TENHLE SOUBOR HLÍDÁ:
-- Dvě permisivní UPDATE politiky se OR-ovaly, takže volnější („admin OR
-- part_time_staff", bez omezení CO se smí zapsat) rušila přísnější. Brigádník
-- si díky tomu mohl schválit směnu sám, proplatit si ji sám a přepsat sazbu
-- kolegovi.
--
-- MĚŘÍ SE POD `SET LOCAL ROLE authenticated`. Jako `postgres` projde všechno
-- (obchází granty i RLS), takže by tenhle soubor tvrdil zavřeno o dveřích,
-- vedle kterých je otevřené okno.
--
-- Nejcennější tvrzení: sebeproplacení (`pending → completed` s vlastními
-- hodinami a sazbou) NEPROJDE — je to přímo řádek „k výplatě".
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

-- Vrací true, když zápis PROŠEL. `GET DIAGNOSTICS`, ne `FOUND`: FOUND po
-- EXECUTE počet dotčených řádků nedrží a sonda by hlásila „odmítnuto"
-- i o zápisu, který v pohodě prošel (na tohle jsem už jednou naletěl).
CREATE OR REPLACE FUNCTION pg_temp.proslo(_sql text) RETURNS boolean
 LANGUAGE plpgsql AS $$
DECLARE _n int;
BEGIN
  EXECUTE _sql;
  GET DIAGNOSTICS _n = ROW_COUNT;
  RETURN _n > 0;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

CREATE TEMP TABLE _s (klic text PRIMARY KEY, id uuid);

DO $$
DECLARE _ev uuid; _id uuid;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST jedna politika','training','2029-01-10 17:00+01','2029-01-10 19:00+01',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;

  INSERT INTO public.shifts (event_id, required_role, status)
  VALUES (_ev,'bar_staff','open') RETURNING id INTO _id;
  INSERT INTO _s VALUES ('volna', _id);

  INSERT INTO public.shifts (event_id, required_role, status)
  VALUES (_ev,'manager','open') RETURNING id INTO _id;
  INSERT INTO _s VALUES ('volna2', _id);

  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_ev,'part_time_staff','pending','33333333-3333-3333-3333-333333333333', now())
  RETURNING id INTO _id;
  INSERT INTO _s VALUES ('moje_pending', _id);

  INSERT INTO public.shifts (event_id, required_role, status, claimed_by, claimed_at)
  VALUES (_ev,'instructor','claimed','55555555-5555-5555-5555-555555555555', now())
  RETURNING id INTO _id;
  INSERT INTO _s VALUES ('cizi', _id);
END $$;

GRANT SELECT ON _s TO authenticated;
GRANT EXECUTE ON FUNCTION pg_temp.proslo(text) TO authenticated;
GRANT EXECUTE ON FUNCTION pg_temp.tvrd(boolean, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- Brigádník (part_time_staff) — ten, komu politika A dělala výjimku
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

DO $$
BEGIN
  PERFORM pg_temp.tvrd(public.has_role(auth.uid(), 'part_time_staff'),
    'příprava: měříme opravdu pod brigádníkem, ne pod postgresem');

  -- ---- co MUSÍ dál fungovat ------------------------------------------------
  PERFORM pg_temp.tvrd(pg_temp.proslo(format(
    'UPDATE public.shifts SET status=''pending'', claimed_by=%L, claimed_at=now() WHERE id=%L',
    auth.uid(), (SELECT id FROM _s WHERE klic='volna'))),
    'LEGITIMNÍ: přihlásit se na volnou směnu (open → pending) dál projde');

  PERFORM pg_temp.tvrd(pg_temp.proslo(format(
    'UPDATE public.shifts SET status=''open'', claimed_by=NULL WHERE id=%L',
    (SELECT id FROM _s WHERE klic='volna'))),
    'LEGITIMNÍ: odhlásit se a vrátit směnu (→ open) dál projde');

  -- ---- co se muselo zavřít -------------------------------------------------
  PERFORM pg_temp.tvrd(NOT pg_temp.proslo(format(
    'UPDATE public.shifts SET status=''claimed'', claimed_by=%L, claimed_at=now() WHERE id=%L',
    auth.uid(), (SELECT id FROM _s WHERE klic='volna2'))),
    'JÁDRO: sebepřiřazení rovnou na claimed (obchází schválení) NEPROJDE');

  PERFORM pg_temp.tvrd(NOT pg_temp.proslo(format(
    'UPDATE public.shifts SET status=''completed'', hours_worked=24, hourly_rate=10000 WHERE id=%L',
    (SELECT id FROM _s WHERE klic='moje_pending'))),
    'JÁDRO: sebeproplacení vlastní směny (24 h × 10 000 Kč) NEPROJDE');

  PERFORM pg_temp.tvrd(NOT pg_temp.proslo(format(
    'UPDATE public.shifts SET hourly_rate=9999 WHERE id=%L',
    (SELECT id FROM _s WHERE klic='cizi'))),
    'JÁDRO: přepsat sazbu na CIZÍ směně NEPROJDE');

  -- A opravdu se nic z toho nezapsalo — ne že by jen „vrátilo 0 řádků".
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.shifts WHERE id=(SELECT id FROM _s WHERE klic='moje_pending')) = 'pending'
    AND (SELECT hourly_rate FROM public.shifts WHERE id=(SELECT id FROM _s WHERE klic='cizi')) IS DISTINCT FROM 9999,
    'stav v tabulce potvrzuje, že odmítnuté zápisy se nepropsaly');
END $$;

-- -----------------------------------------------------------------------------
-- Admin — přechody, které jsou legitimně jeho
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
DO $$
BEGIN
  PERFORM pg_temp.tvrd(pg_temp.proslo(format(
    'UPDATE public.shifts SET status=''claimed'' WHERE id=%L',
    (SELECT id FROM _s WHERE klic='moje_pending'))),
    'admin dál smí schválit směnu (pending → claimed)');

  PERFORM pg_temp.tvrd(pg_temp.proslo(format(
    'UPDATE public.shifts SET status=''completed'', hours_worked=2, hourly_rate=200 WHERE id=%L',
    (SELECT id FROM _s WHERE klic='moje_pending'))),
    'admin dál smí směnu dokončit a proplatit');
END $$;

RESET ROLE;

-- -----------------------------------------------------------------------------
-- Na shifts smí být jen JEDNA UPDATE politika
-- -----------------------------------------------------------------------------
-- Kdyby vedle ní kdykoli přibyla druhá permisivní, OR ji zase obejde — přesně
-- takhle ta díra vznikla.
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM pg_policies WHERE tablename='shifts' AND cmd='UPDATE') = 1,
    'na shifts je právě jedna UPDATE politika');
END $$;

-- -----------------------------------------------------------------------------
-- chat_groups: řazení zná všech 8 rolí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _q text;
BEGIN
  SELECT qual INTO _q FROM pg_policies
   WHERE tablename='chat_groups' AND policyname='Users see groups matching their highest role';

  PERFORM pg_temp.tvrd(_q LIKE '%instructor%' AND _q LIKE '%bar_staff%' AND _q LIKE '%manager%',
    'řazení chat_groups zná instructor, bar_staff i manager');
  -- NULL v ORDER BY ASC jde nakonec, takže „neznámá" role nikdy nevyhrála.
  PERFORM pg_temp.tvrd(_q NOT LIKE '%ELSE NULL%',
    'neznámá role se řadí určitě (ELSE 999), ne na NULL');

  -- Původní pětice si musí držet vzájemné pořadí — jinak by se změnilo,
  -- koho systém považuje za „nejvyšší roli", a to už není jen řazení.
  PERFORM pg_temp.tvrd(
    position('''admin''' in _q) < position('''trainer''' in _q)
    AND position('''trainer''' in _q) < position('''part_time_staff''' in _q)
    AND position('''part_time_staff''' in _q) < position('''pro_player''' in _q)
    AND position('''pro_player''' in _q) < position('''hobby_player''' in _q),
    'původních pět rolí si drží svoje vzájemné pořadí');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
