-- =============================================================================
-- TESTY: přebití akcí posílá jednu zprávu na člověka, ne na každý řádek
-- Migrace 20260912200000_prebiti_jedna_zprava.sql
-- =============================================================================
-- CO SE ZMĚŘILO PŘED OPRAVOU (12. 9. 2026, bezpečnostní brána, ne odhad):
--   admin přebil komerční akcí celý den na obou drahách (30 rezervací)
--   → zástupce klubu dostal 45 zpráv o JEDNÉ akci
--
-- PROČ TO HLÍDAT I PO ZAPNUTÍ E-MAILŮ: se stropem odchozí pošty se z toho
-- nestane 45 e-mailů naráz, ale 45 e-mailů rozložených do několika hodin.
-- Obojí je špatně a projevilo by se to až na klientovi.
--
-- MUTAČNÍ ZKOUŠKA (ověřeno, každá tenhle soubor zčervená):
--   * `notify_user` zpět dovnitř smyčky přes kolizní rezervace → scénář 1
--   * `count(*)` místo `count(DISTINCT COALESCE(event_id, id))` → scénář 3
--   * vypuštěné `GROUP BY u.user_id`                            → scénář 1
--
-- POZOR NA PAST: každý scénář potřebuje VLASTNÍ den a vlastní akci. Dedup
-- upozornění na změnu je transakčně lokální a tenhle soubor je jedna
-- transakce, takže sdílený termín by druhý scénář umlčel a test by byl
-- falešně zelený.
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

-- Rezervace klubu na daný den a hodinu, _drah drah.
CREATE OR REPLACE FUNCTION pg_temp.rezervuj(_den date, _od int, _do int, _drah int DEFAULT 1)
 RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.create_booking(
    (SELECT array_agg(id) FROM (SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT _drah) q),
    'training', 'TEST prebiti ' || _den || ' ' || _od,
    (_den + make_time(_od,0,0)) AT TIME ZONE 'Europe/Prague',
    (_den + make_time(_do,0,0)) AT TIME ZONE 'Europe/Prague',
    (SELECT id FROM public.subjects WHERE name = 'CK Ostravské kameny'));
END $$;

-- Komerční akce admina, která přebije, co jí stojí v cestě.
CREATE OR REPLACE FUNCTION pg_temp.prebij(_den date, _od int, _do int, _drah int DEFAULT 1)
 RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.create_booking(
    (SELECT array_agg(id) FROM (SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT _drah) q),
    'commercial', 'TEST komerce ' || _den,
    (_den + make_time(_od,0,0)) AT TIME ZONE 'Europe/Prague',
    (_den + make_time(_do,0,0)) AT TIME ZONE 'Europe/Prague',
    (SELECT id FROM public.subjects WHERE name = 'Demo Firma s.r.o.'),
    -- Komerční akce musí mít aspoň jednoho instruktora (požadavek klienta),
    -- jinak `create_booking` odmítne ještě před kolizemi.
    p_role_reqs := '{"instructor": 1}'::jsonb,
    p_override := true);
END $$;

UPDATE public.settings SET email_notifications_enabled = true, email_max_za_hodinu = 1000;

-- -----------------------------------------------------------------------------
-- 1) JÁDRO: přebití osmi termínů = JEDNA zpráva, ne osm
-- -----------------------------------------------------------------------------
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
BEGIN
  FOR h IN 8..15 LOOP
    PERFORM pg_temp.rezervuj(DATE '2032-03-01', h, h+1);
  END LOOP;
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _zprav int; _prebito int; _telo text;
BEGIN
  DELETE FROM public.email_outbox;
  DELETE FROM public.notifications;

  PERFORM pg_temp.prebij(DATE '2032-03-01', 8, 16);

  SELECT count(*) INTO _prebito FROM public.reservations
   WHERE status = 'cancelled' AND cancel_reason LIKE 'Přebito akcí%'
     AND start_at >= '2032-03-01' AND start_at < '2032-03-02';
  PERFORM pg_temp.tvrd(_prebito = 8,
    'příprava: přebilo se opravdu 8 termínů, přebito ' || _prebito);

  SELECT count(*) INTO _zprav FROM public.notifications
   WHERE type = 'reservation_overridden'
     AND user_id = '44444444-4444-4444-4444-444444444444';
  PERFORM pg_temp.tvrd(_zprav = 1,
    'JÁDRO: 8 přebitých termínů = 1 zpráva majiteli, ne ' || _zprav);

  SELECT body INTO _telo FROM public.notifications
   WHERE type = 'reservation_overridden'
     AND user_id = '44444444-4444-4444-4444-444444444444';
  PERFORM pg_temp.tvrd(_telo LIKE '%bylo zrušeno 8 vašich termínů%',
    'JÁDRO: zpráva uvádí POČET zrušených termínů');
  PERFORM pg_temp.tvrd(_telo LIKE '%od 01.03.2032 08:00 do 01.03.2032 16:00%',
    'zpráva uvádí rozsah od–do');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: jediný přebitý termín si nechává konkrétní znění
-- -----------------------------------------------------------------------------
-- Opačná chyba než ta opravovaná: kdyby se souhrn použil vždycky, přišel by
-- majitel u jedné rezervace o dráhu a čas.
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$ BEGIN PERFORM pg_temp.rezervuj(DATE '2032-04-05', 9, 10); END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _zprav int; _telo text;
BEGIN
  DELETE FROM public.notifications;
  PERFORM pg_temp.prebij(DATE '2032-04-05', 9, 10);

  SELECT count(*), max(body) INTO _zprav, _telo FROM public.notifications
   WHERE type = 'reservation_overridden'
     AND user_id = '44444444-4444-4444-4444-444444444444';

  PERFORM pg_temp.tvrd(_zprav = 1, 'jeden přebitý termín = jedna zpráva');
  PERFORM pg_temp.tvrd(_telo LIKE '%05.04.2032 09:00–10:00%',
    'JÁDRO: u jednoho termínu zůstává konkrétní čas');
  PERFORM pg_temp.tvrd(_telo NOT LIKE '%vašich termínů%',
    'JÁDRO: u jednoho termínu se nepoužije souhrn');
END $$;

-- -----------------------------------------------------------------------------
-- 3) JÁDRO: dvoudráhový termín je JEDEN termín, ne dva
-- -----------------------------------------------------------------------------
-- Termín přes obě dráhy jsou DVA řádky se společným `event_id`. S `count(*)`
-- by se tři dvoudráhové termíny hlásily jako šest zrušených.
SET LOCAL request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
DO $$
BEGIN
  FOR h IN 10..12 LOOP
    PERFORM pg_temp.rezervuj(DATE '2032-05-10', h, h+1, 2);
  END LOOP;
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _radku int; _telo text;
BEGIN
  DELETE FROM public.notifications;
  PERFORM pg_temp.prebij(DATE '2032-05-10', 10, 13, 2);

  SELECT count(*) INTO _radku FROM public.reservations
   WHERE status = 'cancelled' AND cancel_reason LIKE 'Přebito akcí%'
     AND start_at >= '2032-05-10' AND start_at < '2032-05-11';
  PERFORM pg_temp.tvrd(_radku = 6,
    'příprava: přebilo se 6 ŘÁDKŮ (3 termíny × 2 dráhy), přebito ' || _radku);

  SELECT body INTO _telo FROM public.notifications
   WHERE type = 'reservation_overridden'
     AND user_id = '44444444-4444-4444-4444-444444444444';
  PERFORM pg_temp.tvrd(_telo LIKE '%bylo zrušeno 3 vašich termínů%',
    'JÁDRO: hlásí 3 termíny, ne 6 řádků. Tělo: ' || COALESCE(_telo, '(žádné)'));
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
