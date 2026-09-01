-- =============================================================================
-- TESTY: upozornění majiteli na úpravu / zrušení rezervace (bug #4)
-- Migrace 20260902220000_upozorneni_na_zmenu_rezervace.sql
-- =============================================================================
-- CO TENHLE SOUBOR HLÍDÁ:
-- Než tohle vzniklo, správce mohl klubu posunout trénink na jiný den nebo ho
-- zrušit a klub se to dozvěděl jen tak, že si toho v kalendáři sám všiml.
--
-- Nejcennější tvrzení jsou dvě: (1) cizí zásah upozornění VYROBÍ,
-- (2) vlastní zásah ho NEVYROBÍ.
--
-- POZOR NA PAST, KTERÁ TENHLE TEST UŽ JEDNOU UDĚLALA FALEŠNĚ ZELENÝM:
-- upozornění se posílá JEDNOU NA AKCI (jinak by dvoudráhová rezervace poslala
-- dvě hlášky o jedné změně). Když tedy víc scénářů jede přes TUTÉŽ akci
-- v jedné transakci, druhý a další scénář umlčí dedup — a test pak tvrdí
-- „brána drží", i když je brána vypnutá. Proto má KAŽDÝ scénář vlastní
-- rezervaci. Ověřeno mutacemi: bez obou bran tenhle soubor padá.
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

-- Kolik upozornění daného typu má majitel (44444444 = zástupce CK Ostravské kameny).
CREATE OR REPLACE FUNCTION pg_temp.pocet(_typ text) RETURNS int
 LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.notifications
   WHERE user_id = '44444444-4444-4444-4444-444444444444' AND type = _typ;
$$;

-- Založí rezervaci majitele (44444444) na daný den. Vrací id první rezervace.
CREATE OR REPLACE FUNCTION pg_temp.rezervuj(_den date, _drah int DEFAULT 1) RETURNS uuid
 LANGUAGE plpgsql AS $$
DECLARE _r jsonb;
BEGIN
  _r := public.create_booking(
    (SELECT array_agg(id) FROM (SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT _drah) q),
    'training', 'TEST upozornění ' || _den,
    (_den + time '17:00') AT TIME ZONE 'Europe/Prague',
    (_den + time '19:00') AT TIME ZONE 'Europe/Prague',
    (SELECT id FROM public.subjects WHERE name = 'CK Ostravské kameny'));
  RETURN (_r -> 'reservation_ids' ->> 0)::uuid;
END $$;

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota uuid);

-- Rezervace zakládá MAJITEL, ne admin — každý scénář svou vlastní.
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
BEGIN
  INSERT INTO _s VALUES
    ('cizi_uprava',  pg_temp.rezervuj(DATE '2028-11-14')),
    ('vlastni',      pg_temp.rezervuj(DATE '2028-11-15')),
    ('storno',       pg_temp.rezervuj(DATE '2028-11-16')),
    ('dve_drahy',    pg_temp.rezervuj(DATE '2028-11-20', 2)),
    ('servisni',     pg_temp.rezervuj(DATE '2028-11-22'));

  PERFORM pg_temp.tvrd(pg_temp.pocet('reservation_changed') = 0
                   AND pg_temp.pocet('reservation_cancelled') = 0,
    'příprava: majitel zatím nemá žádné upozornění na změnu');
END $$;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: cizí úprava (admin posune čas) → majitel dostane upozornění
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _telo text;
BEGIN
  PERFORM public.move_booking((SELECT hodnota FROM _s WHERE klic='cizi_uprava'),
                              '2028-11-25 18:00+01', '2028-11-25 20:00+01');

  PERFORM pg_temp.tvrd(pg_temp.pocet('reservation_changed') = 1,
    'JÁDRO: admin posunul rezervaci → majitel má právě jedno upozornění');

  SELECT body INTO _telo FROM public.notifications
   WHERE user_id = '44444444-4444-4444-4444-444444444444'
     AND type = 'reservation_changed' ORDER BY created_at DESC LIMIT 1;

  -- Bez původního času je zpráva k ničemu: „upravil vám rezervaci" neřekne co.
  PERFORM pg_temp.tvrd(_telo LIKE '%14.11.2028 17:00%' AND _telo LIKE '%25.11.2028 18:00%',
    'zpráva nese PŮVODNÍ i NOVÝ čas');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: vlastní úprava upozornění NEVYROBÍ
-- -----------------------------------------------------------------------------
-- Vlastní rezervace, vlastní akce — dedup tu nemá co umlčet, takže když
-- brána zmizí, počet vyskočí na 2 a test padne.
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
BEGIN
  PERFORM public.move_booking((SELECT hodnota FROM _s WHERE klic='vlastni'),
                              '2028-11-26 18:00+01', '2028-11-26 20:00+01');
  PERFORM pg_temp.tvrd(pg_temp.pocet('reservation_changed') = 1,
    'JÁDRO: majitel si posunul rezervaci sám → žádné nové upozornění');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Zrušení cizí rezervace → upozornění VČETNĚ důvodu
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _telo text;
BEGIN
  PERFORM public.cancel_booking((SELECT hodnota FROM _s WHERE klic='storno'),
                                'single', 'Údržba ledu');

  PERFORM pg_temp.tvrd(pg_temp.pocet('reservation_cancelled') = 1,
    'admin zrušil rezervaci → majitel má upozornění o zrušení');

  SELECT body INTO _telo FROM public.notifications
   WHERE user_id = '44444444-4444-4444-4444-444444444444'
     AND type = 'reservation_cancelled' ORDER BY created_at DESC LIMIT 1;
  -- Bez důvodu vypadá zrušení jako svévole haly.
  PERFORM pg_temp.tvrd(_telo LIKE '%Údržba ledu%', 'zpráva o zrušení nese důvod');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Akce přes DVĚ DRÁHY = jedna zpráva, ne dvě
-- -----------------------------------------------------------------------------
DO $$
DECLARE _pred int := pg_temp.pocet('reservation_changed');
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations r
      WHERE r.event_id = (SELECT event_id FROM public.reservations
                           WHERE id = (SELECT hodnota FROM _s WHERE klic='dve_drahy'))) = 2,
    'příprava: akce opravdu drží dvě dráhy');

  -- `move_booking` posouvá celou akci, tedy oba řádky v jedné transakci.
  PERFORM public.move_booking((SELECT hodnota FROM _s WHERE klic='dve_drahy'),
                              '2028-11-27 18:00+01', '2028-11-27 20:00+01');
  PERFORM pg_temp.tvrd(pg_temp.pocet('reservation_changed') = _pred + 1,
    'dvě dráhy → přibyla JEDNA zpráva, ne dvě');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Servisní zápis bez přihlášeného člověka neupozorňuje
-- -----------------------------------------------------------------------------
-- Jinak by každý hromadný přepočet v migraci vyrobil klubům desítky zpráv
-- o změně, kterou nikdo neudělal.
DO $$
DECLARE _pred int := pg_temp.pocet('reservation_changed');
BEGIN
  SET LOCAL request.jwt.claims = '';
  UPDATE public.reservations
     SET start_at = start_at + interval '1 hour', end_at = end_at + interval '1 hour'
   WHERE id = (SELECT hodnota FROM _s WHERE klic='servisni');
  PERFORM pg_temp.tvrd(pg_temp.pocet('reservation_changed') = _pred,
    'servisní zápis (bez auth.uid()) žádnou zprávu nevyrobí');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
