-- =============================================================================
-- TESTY: kontrolní součet vidí i doklady z Fakturoidu (nález 6)
-- Migrace 20260902200000_reconcile_vidi_fakturoid.sql
--        + 20260902180000_jeden_doklad_napric_enginy.sql (nález 5)
-- =============================================================================
-- Fakturoidí cesta do `reservations.invoice_id` schválně nezapisuje, takže
-- vyfakturovaná rezervace zůstávala napořád v „k fakturaci" — a `rozdil = 0`
-- vypadal jako zdraví, přestože měřil jen vyřazovaný interní engine.
--
-- Nejcennější tvrzení: po vystavení dokladu rezervace z „k fakturaci" ZMIZÍ
-- a objeví se ve `fakturoid`, přičemž `rozdil` zůstane nula.
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

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);

-- Komerční akce 4 h × 5 000 = 20 000 Kč, schválená.
DO $$
DECLARE _ev uuid; _rez uuid; _sub uuid;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name='Demo Firma s.r.o.';
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST reconcile','commercial','2029-07-04 16:00+02','2029-07-04 20:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _sub, _ev,
          '2029-07-04 16:00+02','2029-07-04 20:00+02', now(),
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _rez;
  INSERT INTO _s VALUES ('ev',_ev::text), ('rez',_rez::text), ('sub',_sub::text);
END $$;

-- -----------------------------------------------------------------------------
-- 1) PŘED vystavením: rezervace je „k fakturaci"
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT * INTO _r FROM public.billing_reconcile('2029-07-01','2029-07-31')
   WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.k_fakturaci = 20000, 'PŘED: 20 000 Kč čeká na fakturaci');
  PERFORM pg_temp.tvrd(_r.fakturoid = 0,       'PŘED: z Fakturoidu nic');
  PERFORM pg_temp.tvrd(_r.rozdil = 0,          'PŘED: kontrolní součet sedí');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO: po vystavení dokladu rezervace z „k fakturaci" ZMIZÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _ev uuid; _rez uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  SELECT hodnota::uuid INTO _rez FROM _s WHERE klic='rez';

  PERFORM public.fakturoid_zkus_zabrat('test-rec-'||_ev::text,'commercial_event',_sub,_ev,
          NULL, NULL, 20000, 1, 'koncept', ARRAY[_rez]);

  SELECT * INTO _r FROM public.billing_reconcile('2029-07-01','2029-07-31')
   WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.k_fakturaci = 0,
    'PO VYSTAVENÍ: „k fakturaci" spadlo na nulu (jádro nálezu 6)');
  PERFORM pg_temp.tvrd(_r.fakturoid = 20000,
    '… a 20 000 Kč se objevilo ve sloupci `fakturoid`');
  PERFORM pg_temp.tvrd(_r.fakturoid_rozdil = 0,
    '… doklad zní na tutéž částku jako rezervace (fakturoid_rozdil = 0)');
  PERFORM pg_temp.tvrd(_r.rozdil = 0,
    '… a kontrolní součet pořád sedí');
  PERFORM pg_temp.tvrd(_r.dluzi = 20000,
    '… „Kdo kolik dluží" se nezměnilo — zaplaceno ještě není');
END $$;

-- Rozjezd dokladu a rezervace se MUSÍ projevit.
DO $$
DECLARE _sub uuid; _ev uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  UPDATE public.fakturoid_invoices SET nas_soucet = 17000
   WHERE idempotency_key = 'test-rec-'||_ev::text;
  SELECT * INTO _r FROM public.billing_reconcile('2029-07-01','2029-07-31')
   WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.fakturoid_rozdil = -3000,
    'kdyby doklad zněl na jinou částku než rezervace, fakturoid_rozdil to ukáže (−3 000)');
  UPDATE public.fakturoid_invoices SET nas_soucet = 20000
   WHERE idempotency_key = 'test-rec-'||_ev::text;
END $$;

-- Uvolnění zabrání vrátí rezervaci zpět mezi „k fakturaci".
DO $$
DECLARE _sub uuid; _ev uuid; _r record;
BEGIN
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  PERFORM public.fakturoid_uvolni_zabrani('test-rec-'||_ev::text, 'test');
  SELECT * INTO _r FROM public.billing_reconcile('2029-07-01','2029-07-31')
   WHERE subject_id = _sub;
  PERFORM pg_temp.tvrd(_r.k_fakturaci = 20000 AND _r.fakturoid = 0,
    'uvolněné zabrání vrátí rezervaci mezi „k fakturaci"');
END $$;

-- -----------------------------------------------------------------------------
-- 3) NÁLEZ 5: tvrdý zámek napříč enginy
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _rez uuid; _sub uuid; _int uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev  FROM _s WHERE klic='ev';
  SELECT hodnota::uuid INTO _rez FROM _s WHERE klic='rez';
  SELECT hodnota::uuid INTO _sub FROM _s WHERE klic='sub';

  PERFORM public.fakturoid_zkus_zabrat('test-zamek-'||_ev::text,'commercial_event',_sub,_ev,
          NULL, NULL, 20000, 1, 'koncept', ARRAY[_rez]);

  -- Interní doklad na tutéž rezervaci — i kdyby se vat_mode přepnul zpět.
  -- `komercni` doklad musí mít akci (CHECK invoices_komercni_ma_akci).
  INSERT INTO public.invoices (kind, subject_id, event_id, status, obdobi_od, obdobi_do)
  VALUES ('komercni', _sub, _ev, 'koncept', '2029-07-01','2029-07-31')
  RETURNING id INTO _int;

  -- `app.trusted_booking` napodobuje cestu interního enginu: přímý zápis do
  -- `invoice_id` zvenčí zastaví už `guard_reservation_rep_changes` („Vazbu
  -- rezervace na fakturu mění jen fakturační funkce"), takže bez tohohle by
  -- test měřil ten starý guard, ne nový zámek.
  PERFORM set_config('app.trusted_booking', 'on', true);
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET invoice_id = %L WHERE id = %L', _int, _rez),
    'už je na dokladu z Fakturoidu',
    'INTERNÍ doklad nezabere rezervaci, kterou drží Fakturoid (nález 5)');

  PERFORM public.fakturoid_uvolni_zabrani('test-zamek-'||_ev::text, 'test');
  UPDATE public.reservations SET invoice_id = _int WHERE id = _rez;
  PERFORM set_config('app.trusted_booking', 'off', true);

  PERFORM pg_temp.ocekavej_chybu(
    format($q$SELECT public.fakturoid_zkus_zabrat('test-zamek2-%s','commercial_event',%L,%L,
              NULL, NULL, 20000, 1, 'koncept', ARRAY[%L]::uuid[])$q$, _ev, _sub, _ev, _rez),
    'už je na interním dokladu',
    '… a zrcadlově: Fakturoid nezabere, co drží interní doklad');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Prázdné `request.jwt.claims` = slušné odmítnutí, ne pád
-- -----------------------------------------------------------------------------
DO $$
DECLARE _smi boolean;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT public.fakturoid_smi_volat() INTO _smi;
  PERFORM pg_temp.tvrd(_smi IS NOT NULL,
    'prázdné claims nezpůsobí pád (dřív „invalid input syntax for type json")');
  PERFORM set_config('request.jwt.claims',
    '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
