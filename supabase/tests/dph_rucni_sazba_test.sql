-- =============================================================================
-- TEST: daňový význam ceny se určí i při ručně zadané sazbě (nález F3)
-- Migrace 20260902264000_dph_i_pri_rucni_sazbe.sql
-- =============================================================================
-- MUTAČNÍ ZKOUŠKA: vrať v `set_reservation_pricing()` podmínku
-- `AND NEW.rate_per_hour IS NULL` zpátky na VNĚJŠÍ `IF` a pusť to znovu.
-- Musí zčervenat na scénáři 1, 1b a 4 („Kdo dluží" z toho počítá).
--
-- Scénáře 2 a 3 zčervenat NEMUSÍ a taky nezčervenají — tvrdí `false` a rozbitá
-- funkce dává `false` taky. Změřeno, ne odhadnuto. Jsou to regresní pojistky
-- proti tomu, aby oprava neotočila klubovou stranu, ne detektory nálezu; kdo
-- se na sílu téhle sady spoléhá, ať to ví.
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
-- 1b) KOMERČNÍ AKCE NA KLUBOVÉM SUBJEKTU + ruční sazba → taky true
--
--     ⚠️ TENHLE SCÉNÁŘ TU JE ZÁMĚRNĚ, A NE JAKO OZDOBA. Scénáře 2 a 3 níž
--     tvrdí `false` — a rozbitá funkce dává `false` taky (příznak zůstane na
--     defaultu sloupce), takže by prošly i BEZ opravy. Změřeno: s vrácenou
--     vadnou funkcí projde scénář 2 i 3, spadne jen 1. Jsou to tedy regresní
--     pojistky, ne detektory.
--
--     Rozliší to jedině případ, kde se pravidlo a default ROZCHÁZEJÍ na
--     klubové straně: klub, ale komerční akce. Přesně ta kombinace, kterou
--     zmiňuje komentář v `set_reservation_pricing()` jako důvod, proč se
--     daňový význam snapshotuje spolu se sazbou — kontrolní součet se na ní
--     kdysi rozešel o 12 %.
-- ---------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _r uuid; _klub uuid; _drah uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic='klub';
  SELECT hodnota::uuid INTO _drah FROM _s WHERE klic='drah';

  _v := public.create_booking(ARRAY[_drah], 'commercial', 'TEST klub komercni akce',
        '2028-07-06 09:00+02','2028-07-06 11:00+02', _klub, NULL, '{"instructor":1}'::jsonb, 3000);
  _r := (_v->'reservation_ids'->>0)::uuid;

  PERFORM pg_temp.tvrd(
    (SELECT cena_bez_dph FROM public.reservations WHERE id=_r),
    'KLUBOVÝ subjekt + KOMERČNÍ akce + ruční sazba → true (druhý detektor F3)');
END $$;

-- ---------------------------------------------------------------------------
-- 2) KLUB s ruční sazbou — klubová cena je vedená VČETNĚ DPH, tedy false
--    REGRESNÍ POJISTKA, ne detektor: projde i bez opravy (viz 1b).
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
--    REGRESNÍ POJISTKA, ne detektor: projde i bez opravy (viz 1b).
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
  -- `cena_bez_dph = _pred` by NESTAČILO: pod mutací je `_pred` false a rovnost
  -- platí, takže by scénář prošel i s rozbitou funkcí. Musí se tvrdit i to,
  -- KTERÁ hodnota to je.
  PERFORM pg_temp.tvrd(
    (SELECT _pred AND cena_bez_dph AND rate_per_hour = 4000
       FROM public.reservations WHERE id=_r),
    'přecenění akce změní sazbu, ale daňový snapshot (true) nechá být');
END $$;

-- ---------------------------------------------------------------------------
-- 7) DATOVÁ NÁPRAVA SKUTEČNĚ OPRAVUJE — a nechá razítko úpravy být
--
--    Předchozí verze tohohle scénáře počítala živé rezervace odporující
--    pravidlu a čekala nulu. Jenže seed zakládá rezervace BEZ explicitní
--    sazby, takže jdou vnitřní větví a jsou konzistentní od začátku, a
--    zbylé tři si vyrábí sám test a tvrdí je scénáře 1–3. Počítalo to
--    NULU Z NULY a o DO bloku s nápravou netvrdilo nic — přitom je to
--    dnes nejsložitější část té migrace (dvě zastávky, `app.preceneni`
--    na obě strany, DISABLE/ENABLE triggeru) a poprvé se spustila
--    až na ostré produkci.
-- ---------------------------------------------------------------------------
DO $$
DECLARE _r uuid; _kdo uuid; _kdy timestamptz; _castka numeric; _hod numeric;
        _razitko timestamptz; _notif int; _n int;
BEGIN
  SELECT hodnota::uuid INTO _r FROM _s WHERE klic='r_komercni';

  -- Vadný řádek se normální cestou vyrobit nedá — trigger ho po opravě sám
  -- srovná. Musí se obejít, přesně jako se obchází v samotné migraci.
  ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_pricing;
  UPDATE public.reservations SET cena_bez_dph = false WHERE id = _r;
  ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_pricing;

  SELECT updated_by, updated_at, amount, hours, approved_at
    INTO _kdo, _kdy, _castka, _hod, _razitko
    FROM public.reservations WHERE id = _r;
  SELECT count(*) INTO _notif FROM public.notifications;

  PERFORM pg_temp.tvrd((SELECT NOT cena_bez_dph FROM public.reservations WHERE id=_r),
    'příprava: rezervace má vadný příznak DPH');

  -- ---- TOTÉŽ, CO DĚLÁ MIGRACE ----
  PERFORM set_config('app.preceneni', 'on', true);
  ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_updated;
  WITH k_naprave AS (
    SELECT r.id FROM public.reservations r
      JOIN public.subjects s ON s.id = r.subject_id
      LEFT JOIN public.events e ON e.id = r.event_id
     WHERE r.deleted_at IS NULL
       AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate))
  UPDATE public.reservations r SET rate_per_hour = r.rate_per_hour
    FROM k_naprave k WHERE r.id = k.id;
  GET DIAGNOSTICS _n = ROW_COUNT;
  ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_updated;
  PERFORM set_config('app.preceneni', 'off', true);
  -- --------------------------------

  PERFORM pg_temp.tvrd(_n = 1, format('náprava sáhla přesně na 1 rezervaci (sáhla na %s)', _n));
  PERFORM pg_temp.tvrd((SELECT cena_bez_dph FROM public.reservations WHERE id=_r),
    'náprava srovnala příznak DPH podle pravidla');
  PERFORM pg_temp.tvrd(
    (SELECT amount = _castka AND hours = _hod AND approved_at IS NOT DISTINCT FROM _razitko
       FROM public.reservations WHERE id=_r),
    '… a nehnula částkou, hodinami ani razítkem schválení');
  PERFORM pg_temp.tvrd(
    (SELECT updated_by IS NOT DISTINCT FROM _kdo AND updated_at = _kdy
       FROM public.reservations WHERE id=_r),
    '… a nechala „kdo naposledy zadával" být (DISABLE TRIGGER funguje)');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.notifications) = _notif,
    '… a nikomu nerozeslala upozornění');

  SELECT count(*) INTO _n
    FROM public.reservations r
    JOIN public.subjects s ON s.id = r.subject_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.deleted_at IS NULL
     AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate);
  PERFORM pg_temp.tvrd(_n = 0, 'po nápravě neodporuje pravidlu žádná živá rezervace');
END $$;

-- ---------------------------------------------------------------------------
-- 8) OBĚ ZASTÁVKY MIGRACE OPRAVDU ZASTAVÍ
--    Bez nich by se rezervace bez sazby místo přeznačení PŘECENILA dnešním
--    ceníkem a koncová kontrola by to ohlásila jako úspěch.
-- ---------------------------------------------------------------------------
DO $$
DECLARE _bez_sazby int; _na_dokladu int; _v jsonb; _r uuid; _klub uuid; _drah uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic='klub';
  SELECT hodnota::uuid INTO _drah FROM _s WHERE klic='drah';

  _v := public.create_booking(ARRAY[_drah], 'training', 'TEST bez sazby',
        '2028-07-20 09:00+02','2028-07-20 10:00+02', _klub);
  _r := (_v->'reservation_ids'->>0)::uuid;

  ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_pricing;
  UPDATE public.reservations SET rate_per_hour = NULL, cenove_pasma = NULL, cena_bez_dph = true
   WHERE id = _r;
  ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_pricing;

  SELECT count(*) INTO _bez_sazby
    FROM public.reservations r
    JOIN public.subjects s ON s.id = r.subject_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.deleted_at IS NULL AND r.rate_per_hour IS NULL
     AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate);
  PERFORM pg_temp.tvrd(_bez_sazby = 1,
    'zastávka „rezervace bez sazby" takový řádek najde (a migrace by se zastavila)');

  -- a co by se stalo, kdyby se nezastavila: přecenění dnešním ceníkem
  PERFORM set_config('app.preceneni', 'on', true);
  UPDATE public.reservations SET rate_per_hour = rate_per_hour WHERE id = _r;
  PERFORM set_config('app.preceneni', 'off', true);
  PERFORM pg_temp.tvrd(
    (SELECT rate_per_hour IS NOT NULL AND cenove_pasma IS NOT NULL FROM public.reservations WHERE id=_r),
    '… protože bez ní se rezervace PŘECENÍ z ceníku, ne přeznačí (proto ta zastávka je)');
END $$;

ROLLBACK;
