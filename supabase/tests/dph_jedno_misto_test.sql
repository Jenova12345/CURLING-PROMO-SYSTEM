-- =============================================================================
-- TESTY: daňový význam ceny má JEDNO místo (cena_bez_dph)
-- Migrace 20260831231000_dph_jedno_misto.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/dph_jedno_misto_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Rovnici z CLAUDE.md („suma vystavených faktur == Kdo kolik dluží"). Rozešla
-- se o celou sazbu DPH ve chvíli, kdy typ akce a typ subjektu přestaly chodit
-- spolu — a to umí jedno kliknutí (`zmen_typ_akce`). Nejcennější tvrzení je
-- proto první: klubový subjekt s KOMERČNÍ akcí dluží základ + 12 %, protože
-- přesně tolik bude na dokladu.
--
-- POZOR: testy počítají s `vat_mode = 'platce'` a `vat_rate_ice = 12`. Když
-- se to v nastavení změní, mají zčervenat — je to peněžní invariant, ne
-- náhodná konfigurace.
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

DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT vat_mode FROM public.billing_settings WHERE singleton) = 'platce'
    AND (SELECT vat_rate_ice FROM public.billing_settings WHERE singleton) = 12,
    'příprava: hala je plátce a sazba za led je 12 %');
END $$;

-- -----------------------------------------------------------------------------
-- 1) PRAVIDLO SAMO
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(public.cena_je_bez_dph('commercial', 'commercial', NULL),
    'firma na komerční akci: amount je ZÁKLAD daně');
  PERFORM pg_temp.tvrd(public.cena_je_bez_dph('commercial', 'training', NULL),
    'firma na tréninku taky — komerční sazba se používá i tam');
  PERFORM pg_temp.tvrd(public.cena_je_bez_dph('club', 'commercial', NULL),
    'KLUB na komerční akci: taky základ, protože dostane komerční sazbu (jádro nálezu)');
  PERFORM pg_temp.tvrd(NOT public.cena_je_bez_dph('club', 'training', NULL),
    'klubový trénink: pásmový ceník je vedený S daní');
  PERFORM pg_temp.tvrd(NOT public.cena_je_bez_dph('club', 'commercial', 450),
    'klub s DOHODNUTOU sazbou: dohoda s klubem je s daní, ať se akce jmenuje jakkoli');
  PERFORM pg_temp.tvrd(NOT public.cena_je_bez_dph(NULL, NULL, NULL),
    'bez subjektu není komu fakturovat, takže ani daň');
END $$;

-- -----------------------------------------------------------------------------
-- 2) JÁDRO NÁLEZU: klub + komerční akce → dluh je základ + 12 %
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _rez uuid; _klub uuid; _r record;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';

  -- Klubový TRÉNINK 16–20 (pásma: 1 h × 1 000 + 3 h × 1 200 = 4 600).
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST dph klub','training','2027-09-08 16:00+02','2027-09-08 20:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _klub, _ev,
          '2027-09-08 16:00+02','2027-09-08 20:00+02', now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _rez;
  INSERT INTO _s VALUES ('ev', _ev::text), ('rez', _rez::text), ('klub', _klub::text);

  SELECT cena_bez_dph, amount INTO _r FROM public.reservations WHERE id = _rez;
  PERFORM pg_temp.tvrd(NOT _r.cena_bez_dph, 'klubový trénink má cenu VČETNĚ daně');
  PERFORM pg_temp.tvrd(
    (SELECT dluh FROM public.reservations_billing WHERE id = _rez) = _r.amount,
    '… takže dluh je rovnou částka z rezervace, nic se nepřipočítává');

  -- A teď to jedno kliknutí, které rovnici rozbíjelo.
  PERFORM public.zmen_typ_akce(_ev, 'commercial');

  SELECT cena_bez_dph, amount INTO _r FROM public.reservations WHERE id = _rez;
  PERFORM pg_temp.tvrd(_r.cena_bez_dph,
    'po přepnutí na KOMERČNÍ akci je cena vedená bez daně (dostala komerční sazbu)');
  PERFORM pg_temp.tvrd(_r.amount = 20000, '… 4 h × 5 000 Kč/h = 20 000 Kč základ');
  PERFORM pg_temp.tvrd(
    (SELECT dluh FROM public.reservations_billing WHERE id = _rez) = 22400,
    'DLUH JE 22 400 Kč — základ + 12 %, tedy přesně to, na co bude znít doklad');
  PERFORM pg_temp.tvrd(
    (SELECT dluh_zaklad FROM public.reservations_billing WHERE id = _rez) = 20000,
    '… a `dluh_zaklad` pořád ukazuje základ, ať jde poznat, z čeho dluh vznikl');
END $$;

-- Podklad pro Fakturoid nese ZÁKLAD (doklad za akci má pricesIncludeVat: false),
-- takže obě strany rovnice mluví o témž čísle, jen v jiném režimu.
DO $$
DECLARE _ev uuid; _castka numeric;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'ev';
  SELECT sum(castka) INTO _castka FROM public.fakturoid_podklady_akce(_ev);
  PERFORM pg_temp.tvrd(_castka = 20000,
    'podklad pro doklad za akci nese ZÁKLAD 20 000 Kč (daň dopočítá Fakturoid)');
  PERFORM pg_temp.tvrd(
    round(_castka * 1.12, 2) = (SELECT sum(dluh) FROM public.reservations_billing
                                 WHERE id IN (SELECT id FROM public.fakturoid_podklady_akce(_ev))),
    'KONTROLNÍ SOUČET: doklad (základ + 12 %) == „Kdo kolik dluží"');
END $$;

-- -----------------------------------------------------------------------------
-- 3) ZRCADLOVĚ: komerční subjekt na měsíčním klubovém dokladu se NEVYSTAVÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _firma uuid; _od date := '2027-10-01'; _do date := '2027-10-31';
BEGIN
  SELECT id INTO _firma FROM public.subjects WHERE name = 'Testovací Firma s.r.o.';

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST firma trenink','training','2027-10-06 17:00+02','2027-10-06 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _firma, _ev,
          '2027-10-06 17:00+02','2027-10-06 19:00+02', now(), '11111111-1111-1111-1111-111111111111');

  PERFORM pg_temp.tvrd(
    (SELECT bool_and(cena_bez_dph) FROM public.reservations WHERE event_id = _ev),
    'trénink FIRMY je oceněný komerční sazbou, tedy bez daně');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT * FROM public.fakturoid_podklady_klub(%L, %L, %L)', _firma, _od, _do),
    'míchal ceny',
    'měsíční klubový doklad (ceny S DPH) takovou rezervaci NEVYSTAVÍ — radši nic než dvakrát zdaněno');
END $$;

-- -----------------------------------------------------------------------------
-- 4) AKCE ZDARMA se nedostane ani na doklad za akci (dřív jen na klubový)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _firma uuid;
BEGIN
  SELECT id INTO _firma FROM public.subjects WHERE name = 'Demo Firma s.r.o.';

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST akce zdarma dph','commercial','2027-11-10 16:00+01','2027-11-10 18:00+01',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at,
                                   rate_per_hour, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _firma, _ev,
          '2027-11-10 16:00+01','2027-11-10 18:00+01', 0, now(),
          '11111111-1111-1111-1111-111111111111');

  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.fakturoid_podklady_akce(_ev)),
    'akce za 0 Kč nemá co poslat do Fakturoidu (jinak by spálila číslo v řadě)');
END $$;

-- -----------------------------------------------------------------------------
-- 5) KONTROLNÍ SOUČET interního enginu zůstává nulový
-- -----------------------------------------------------------------------------
DO $$
DECLARE _rozdil numeric;
BEGIN
  SELECT COALESCE(sum(rozdil),0) INTO _rozdil FROM public.billing_reconcile('2027-09-01','2027-09-30');
  PERFORM pg_temp.tvrd(_rozdil = 0, 'billing_reconcile za 9/2027 má rozdíl 0');

  SELECT COALESCE(sum(rozdil),0) INTO _rozdil FROM public.billing_reconcile('2026-08-01','2026-08-31');
  PERFORM pg_temp.tvrd(_rozdil = 0, 'billing_reconcile za 8/2026 (reálná data seedu) má rozdíl 0');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
