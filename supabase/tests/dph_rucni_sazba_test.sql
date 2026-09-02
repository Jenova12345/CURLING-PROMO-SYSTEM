-- =============================================================================
-- TEST: daňový význam ceny se určí i při ručně zadané sazbě (nález F3)
-- Migrace 20260902264000_dph_i_pri_rucni_sazbe.sql
-- =============================================================================
-- MUTAČNÍ ZKOUŠKA: vrať v `set_reservation_pricing()` podmínku
-- `AND NEW.rate_per_hour IS NULL` zpátky na VNĚJŠÍ `IF` a pusť to znovu.
-- Musí zčervenat na scénáři 1 (a s ním i 4, protože „Kdo dluží" z toho počítá).
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

-- Hala je plátce s 12 % na led — jinak nemá „chybějící DPH" co měřit.
UPDATE public.billing_settings SET vat_mode='platce', vat_rate_ice=12 WHERE singleton;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);

DO $$
DECLARE _komercni uuid; _klub uuid; _drah uuid; _r uuid;
BEGIN
  SELECT id INTO _drah FROM public.sheets WHERE active ORDER BY name LIMIT 1;

  INSERT INTO public.subjects (name, type, created_by)
  VALUES ('TEST Firma s.r.o.','commercial','11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _komercni;
  INSERT INTO public.subjects (name, type, created_by)
  VALUES ('TEST Klub','club','11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _klub;

  INSERT INTO _s VALUES ('komercni',_komercni::text),('klub',_klub::text),('drah',_drah::text);
END $$;

-- ---------------------------------------------------------------------------
-- 1) JÁDRO NÁLEZU — komerční zákazník, sazbu zadal admin při zakládání
-- ---------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _r uuid; _komercni uuid; _drah uuid;
BEGIN
  SELECT hodnota::uuid INTO _komercni FROM _s WHERE klic='komercni';
  SELECT hodnota::uuid INTO _drah     FROM _s WHERE klic='drah';

  _v := public.create_booking(ARRAY[_drah], 'commercial', 'TEST ruční sazba',
        '2028-07-03 09:00+02','2028-07-03 11:00+02', _komercni, NULL, '{"instructor":1}'::jsonb, 5000);
  _r := (_v->'reservation_ids'->>0)::uuid;
  INSERT INTO _s VALUES ('r_komercni', _r::text);

  PERFORM pg_temp.tvrd(
    (SELECT rate_per_hour = 5000 AND amount = 10000 FROM public.reservations WHERE id=_r),
    'sazba od admina se použije (5 000 Kč/h → 10 000 Kč za 2 h)');

  PERFORM pg_temp.tvrd(
    (SELECT cena_bez_dph FROM public.reservations WHERE id=_r),
    'KOMERČNÍ + ruční sazba → cena_bez_dph = true (jádro F3)');
END $$;

-- ---------------------------------------------------------------------------
-- 2) KLUB s ruční sazbou — klubová cena je vedená VČETNĚ DPH, tedy false
-- ---------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _r uuid; _klub uuid; _drah uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic='klub';
  SELECT hodnota::uuid INTO _drah FROM _s WHERE klic='drah';

  _v := public.create_booking(ARRAY[_drah], 'training', 'TEST klub ruční sazba',
        '2028-07-04 09:00+02','2028-07-04 11:00+02', _klub, NULL, '{}'::jsonb, 900);
  _r := (_v->'reservation_ids'->>0)::uuid;

  PERFORM pg_temp.tvrd(
    (SELECT NOT cena_bez_dph FROM public.reservations WHERE id=_r),
    'KLUB + ruční sazba → cena_bez_dph = false (klubový ceník je s DPH)');
END $$;

-- ---------------------------------------------------------------------------
-- 3) PÁSMOVÁ CESTA SE NESMÍ HNOUT — klub bez ruční sazby
-- ---------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _r uuid; _klub uuid; _drah uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic='klub';
  SELECT hodnota::uuid INTO _drah FROM _s WHERE klic='drah';

  _v := public.create_booking(ARRAY[_drah], 'training', 'TEST klub z ceníku',
        '2028-07-05 09:00+02','2028-07-05 11:00+02', _klub);
  _r := (_v->'reservation_ids'->>0)::uuid;

  PERFORM pg_temp.tvrd(
    (SELECT cenove_pasma IS NOT NULL AND NOT cena_bez_dph FROM public.reservations WHERE id=_r),
    'klub z pásmového ceníku má dál rozpis a cena_bez_dph = false (beze změny)');
END $$;

-- ---------------------------------------------------------------------------
-- 4) „KDO DLUŽÍ" — u komerční rezervace se teď připočte 12 %
-- ---------------------------------------------------------------------------
DO $$
DECLARE _r uuid;
BEGIN
  SELECT hodnota::uuid INTO _r FROM _s WHERE klic='r_komercni';
  PERFORM pg_temp.tvrd(
    (SELECT dluh = 11200 AND dluh_zaklad = 10000 FROM public.reservations_billing WHERE id=_r),
    '„Kdo dluží" ukáže 11 200 Kč (základ 10 000 + 12 % DPH)');
END $$;

-- ---------------------------------------------------------------------------
-- 5) KONTROLNÍ SOUČET DÁL SEDÍ
-- ---------------------------------------------------------------------------
DO $$
DECLARE _rozdil numeric; _fakt numeric;
BEGIN
  SELECT COALESCE(sum(rozdil),0), COALESCE(sum(fakturoid_rozdil),0)
    INTO _rozdil, _fakt
    FROM public.billing_reconcile('2025-01-01','2029-12-31');
  PERFORM pg_temp.tvrd(_rozdil = 0 AND _fakt = 0,
    format('kontrolní součet drží (rozdil=%s, fakturoid_rozdil=%s)', _rozdil, _fakt));
END $$;

-- ---------------------------------------------------------------------------
-- 6) SNAPSHOT SE PŘI BĚŽNÉM PŘECENĚNÍ NEHÝBE
--    `uprav_sazbu_akce()` jede BEZ `app.preceneni` → daňový význam zůstává.
-- ---------------------------------------------------------------------------
DO $$
DECLARE _r uuid; _ev uuid; _pred boolean;
BEGIN
  SELECT hodnota::uuid INTO _r FROM _s WHERE klic='r_komercni';
  SELECT event_id, cena_bez_dph INTO _ev, _pred FROM public.reservations WHERE id=_r;
  PERFORM public.uprav_sazbu_akce(_ev, 4000);
  PERFORM pg_temp.tvrd(
    (SELECT cena_bez_dph = _pred AND rate_per_hour = 4000 FROM public.reservations WHERE id=_r),
    'přecenění akce změní sazbu, ale daňový snapshot nechá být');
END $$;

-- ---------------------------------------------------------------------------
-- 7) PO MIGRACI UŽ ŽÁDNÁ ŽIVÁ REZERVACE S PRAVIDLEM NEKOLIDUJE
-- ---------------------------------------------------------------------------
DO $$
DECLARE _n int;
BEGIN
  SELECT count(*) INTO _n
    FROM public.reservations r
    JOIN public.subjects s ON s.id = r.subject_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.deleted_at IS NULL
     AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate);
  PERFORM pg_temp.tvrd(_n = 0,
    format('žádná živá rezervace neodporuje pravidlu o DPH (nalezeno %s)', _n));
END $$;

ROLLBACK;
