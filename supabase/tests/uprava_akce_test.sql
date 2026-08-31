-- =============================================================================
-- TESTY: úprava akce — dráhy, typ akce, akce zadarmo (úkoly B, C, D)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/uprava_akce_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Všechny tři věci sahají na cenu. Nejcennější tvrzení jsou proto ta o penězích:
-- že přidaná dráha stojí totéž co první, že změna typu cenu opravdu přepočítá
-- (a nepřepočítá ji nic jiného), a že akce za nulu zmizí z fakturace, ale ne
-- z „Kdo kolik dluží" — a kontrolní součet přitom zůstane nulový.
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
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %', _popis;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): mělo to skončit chybou, ale prošlo', _popis;
END $$;

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- Komerční akce na JEDNÉ dráze, 4 h
DO $$
DECLARE _ev uuid; _d1 uuid; _d2 uuid;
BEGIN
  SELECT id INTO _d1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _d2 FROM public.sheets WHERE active AND id <> _d1 ORDER BY name LIMIT 1;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST úprava akce','commercial','2027-06-09 16:00+02','2027-06-09 20:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES (_d1, (SELECT id FROM public.subjects WHERE name='Demo Firma s.r.o.'),
          _ev, '2027-06-09 16:00+02','2027-06-09 20:00+02');

  INSERT INTO _s VALUES ('ev',_ev::text), ('d1',_d1::text), ('d2',_d2::text);
  PERFORM pg_temp.tvrd(
    (SELECT sum(amount) FROM public.reservations WHERE event_id=_ev) = 20000,
    'příprava: komerční akce na 1 dráze × 4 h × 5 000 = 20 000 Kč');
END $$;

-- -----------------------------------------------------------------------------
-- B) PŘIDÁNÍ A UBRÁNÍ DRÁHY
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _d1 uuid; _d2 uuid; _v jsonb;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';
  SELECT hodnota::uuid INTO _d1 FROM _s WHERE klic='d1';
  SELECT hodnota::uuid INTO _d2 FROM _s WHERE klic='d2';

  _v := public.uprav_drahy_akce(_ev, ARRAY[_d1, _d2]);
  PERFORM pg_temp.tvrd((_v->>'pridano')::int = 1, 'přidání druhé dráhy vytvořilo jednu rezervaci');
  PERFORM pg_temp.tvrd((_v->>'drah')::int = 2,   '… akce má nově dvě dráhy');

  -- Peněžní jádro: přidaná dráha musí stát TOTÉŽ co první.
  PERFORM pg_temp.tvrd(
    (SELECT count(DISTINCT rate_per_hour) FROM public.reservations
      WHERE event_id=_ev AND deleted_at IS NULL) = 1,
    'obě dráhy mají STEJNOU sazbu (jinak by jedna akce měla dvě ceny)');
  PERFORM pg_temp.tvrd((_v->>'celkem')::numeric = 40000,
    'celková cena akce je 2 × 4 h × 5 000 = 40 000 Kč');

  -- Přidání pod TOUTÉŽ akcí, ne nová akce.
  PERFORM pg_temp.tvrd(
    (SELECT count(DISTINCT event_id) FROM public.reservations
      WHERE event_id=_ev AND deleted_at IS NULL) = 1,
    '… a obě rezervace visí pod jedním event_id');

  -- UBRÁNÍ: soft delete, nikdy DELETE.
  _v := public.uprav_drahy_akce(_ev, ARRAY[_d1]);
  PERFORM pg_temp.tvrd((_v->>'ubrano')::int = 1, 'ubrání dráhy proběhlo');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE event_id=_ev AND sheet_id=_d2 AND deleted_at IS NOT NULL) = 1,
    '… a ubraná dráha je SOFT smazaná (nic nezmizelo)');
  PERFORM pg_temp.tvrd((_v->>'celkem')::numeric = 20000, '… cena spadla zpět na 20 000 Kč');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_drahy_akce(%L, ARRAY[]::uuid[])', _ev),
    'aspoň jednu dráhu', 'akci nejde nechat bez dráhy (na to je storno)');
END $$;

-- -----------------------------------------------------------------------------
-- C) ZMĚNA TYPU AKCE s přepočtem ceny
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _v jsonb; _r record;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';

  -- Komerční (5 000/h) → trénink. Subjekt je ale FIRMA, takže i trénink firmy
  -- se účtuje komerční sazbou — pásma jsou jen pro kluby.
  _v := public.zmen_typ_akce(_ev, 'training');
  PERFORM pg_temp.tvrd((_v->>'zmena')::boolean, 'typ akce se změnil');
  PERFORM pg_temp.tvrd((_v->>'preceneno')::int = 1, '… a cena se přepočítala');

  SELECT event_type INTO _r FROM public.events WHERE id=_ev;
  PERFORM pg_temp.tvrd(_r.event_type = 'training', '… v databázi je nový typ');

  SELECT rate_per_hour, amount INTO _r FROM public.reservations
   WHERE event_id=_ev AND deleted_at IS NULL;
  PERFORM pg_temp.tvrd(_r.rate_per_hour = 5000,
    'trénink FIRMY se pořád účtuje komerční sazbou (pásma jsou pro kluby)');

  -- Opakovaná změna na týž typ nic nedělá.
  _v := public.zmen_typ_akce(_ev, 'training');
  PERFORM pg_temp.tvrd(NOT (_v->>'zmena')::boolean, 'změna na týž typ je bez efektu');
END $$;

-- Klubová akce: komerční → trénink musí spadnout na PÁSMA
DO $$
DECLARE _ev uuid; _r record; _v jsonb;
BEGIN
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST klub typ','commercial','2027-06-16 17:00+02','2027-06-16 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1),
          (SELECT id FROM public.subjects WHERE name='CK Ostravské kameny'),
          _ev, '2027-06-16 17:00+02','2027-06-16 19:00+02');

  SELECT rate_per_hour, amount INTO _r FROM public.reservations WHERE event_id=_ev;
  PERFORM pg_temp.tvrd(_r.amount = 10000, 'klub jako KOMERČNÍ akce: 2 h × 5 000 = 10 000 Kč');

  _v := public.zmen_typ_akce(_ev, 'training');
  SELECT rate_per_hour, amount, cenove_pasma INTO _r FROM public.reservations WHERE event_id=_ev;
  PERFORM pg_temp.tvrd(_r.amount = 2400,
    'po změně na TRÉNINK se klub ocení pásmy: 2 h × 1 200 = 2 400 Kč');
  PERFORM pg_temp.tvrd(_r.cenove_pasma IS NOT NULL, '… a dostane rozpis po pásmech');
END $$;

-- Cena se NESMÍ přepočítat při běžné úpravě
DO $$
DECLARE _ev uuid; _pred numeric; _po numeric;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic='ev';
  SELECT sum(amount) INTO _pred FROM public.reservations WHERE event_id=_ev AND deleted_at IS NULL;
  UPDATE public.reservations SET note = 'jen poznámka' WHERE event_id=_ev AND deleted_at IS NULL;
  SELECT sum(amount) INTO _po FROM public.reservations WHERE event_id=_ev AND deleted_at IS NULL;
  PERFORM pg_temp.tvrd(_pred = _po,
    'běžná úprava cenu NEPŘEPOČÍTÁ (přecenění jde jen přes zmen_typ_akce)');
END $$;

-- -----------------------------------------------------------------------------
-- D) AKCE ZA NULU
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _sub uuid; _rez uuid;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name='Testovací Firma s.r.o.';
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST akce zdarma','commercial','2027-07-07 16:00+02','2027-07-07 18:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, rate_per_hour, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _sub, _ev,
          '2027-07-07 16:00+02','2027-07-07 18:00+02', 0, now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _rez;

  INSERT INTO _s VALUES ('nula_rez', _rez::text), ('nula_sub', _sub::text);

  PERFORM pg_temp.tvrd(
    (SELECT amount FROM public.reservations WHERE id=_rez) = 0,
    'sazba 0 projde a částka je 0 Kč (databáze je podlaha, ne strop)');

  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.fakturovatelne_rezervace(_sub, '2027-07-01','2027-08-01') f
                 WHERE f.id = _rez),
    'nulová rezervace SE NEFAKTURUJE (doklad na nulu se nevystavuje)');

  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.reservations_billing WHERE id = _rez),
    '… ale z „Kdo kolik dluží" NEMIZÍ (led se odehrál, jen zadarmo)');

  PERFORM pg_temp.tvrd(
    (SELECT dluh FROM public.reservations_billing WHERE id = _rez) = 0,
    '… a dluží se za ni nula');
END $$;

-- NULOVÁ KOREKCE ale fakturu pořád ZASTAVÍ — to je jiný případ
DO $$
DECLARE _sub uuid; _ev uuid; _rez uuid;
BEGIN
  SELECT id INTO _sub FROM public.subjects WHERE name='Testovací Firma s.r.o.';
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST nedorazili','commercial','2027-07-14 16:00+02','2027-07-14 18:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _sub, _ev,
          '2027-07-14 16:00+02','2027-07-14 18:00+02', now(), '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _rez;

  -- Placená rezervace, kterou někdo zkorigoval na nulu („nedorazili").
  UPDATE public.reservations SET corrected_hours = 0, correction_reason = 'Nedorazili'
   WHERE id = _rez;

  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.fakturovatelne_rezervace(_sub, '2027-07-01','2027-08-01') f
             WHERE f.id = _rez),
    'nulová KOREKCE z fakturace NEMIZÍ — musí na ni narazit guard (jiný případ než cena zdarma)');
END $$;

-- KONTROLNÍ SOUČET nesmí nulová akce rozhodit
DO $$
DECLARE _rozdil numeric;
BEGIN
  SELECT COALESCE(sum(rozdil),0) INTO _rozdil
    FROM public.billing_reconcile('2027-07-01','2027-07-31');
  PERFORM pg_temp.tvrd(_rozdil = 0,
    'billing_reconcile má rozdíl 0 i s nulovou akcí (přispěje do obou stran nulou)');
END $$;

-- =============================================================================
-- NÁPRAVY Z BRÁNY (ultra review, 31. 8. 2026)
-- Migrace 20260831232000_uprava_akce_naprava.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- B2) PŘIDÁNÍ DRÁHY K PÁSMOVĚ OCENĚNÉ KLUBOVÉ REZERVACI
--
-- Tohle NEŠLO VŮBEC: do nové dráhy se kopírovala `rate_per_hour`, což je
-- u pásmové ceny odvozený průměr s haléři (3 400 / 3 = 1 133,33), a na tom
-- padly obě pojistky na celé koruny.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _d1 uuid; _d2 uuid; _v jsonb; _klub uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  SELECT id INTO _d1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _d2 FROM public.sheets WHERE active AND id <> _d1 ORDER BY name LIMIT 1;

  -- Středa 16–19: 1 h × 1 000 (odpolední) + 2 h × 1 200 (večerní) = 3 400 Kč.
  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST pasma draha','training','2027-06-23 16:00+02','2027-06-23 19:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES (_d1, _klub, _ev, '2027-06-23 16:00+02','2027-06-23 19:00+02');

  PERFORM pg_temp.tvrd(
    (SELECT amount FROM public.reservations WHERE event_id = _ev) = 3400,
    'příprava: klubový trénink přes dvě pásma stojí 3 400 Kč');
  PERFORM pg_temp.tvrd(
    (SELECT rate_per_hour FROM public.reservations WHERE event_id = _ev) = 1133.33,
    '… a odvozený průměr má haléře (to je ta mina)');

  _v := public.uprav_drahy_akce(_ev, ARRAY[_d1, _d2]);
  PERFORM pg_temp.tvrd((_v->>'pridano')::int = 1,
    'druhá dráha k DVOUPÁSMOVÉ klubové rezervaci se přidat DÁ (dřív to padalo na celé koruny)');
  PERFORM pg_temp.tvrd((_v->>'celkem')::numeric = 6800,
    '… a celá akce stojí 2 × 3 400 = 6 800 Kč');
  PERFORM pg_temp.tvrd(
    (SELECT count(DISTINCT amount) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL) = 1,
    '… obě dráhy stojí STEJNĚ (jedna akce, jedna cena)');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.reservations
      WHERE event_id = _ev AND deleted_at IS NULL AND cenove_pasma IS NOT NULL) = 2,
    '… a OBĚ mají rozpis po pásmech (bez něj by se z nich nesložil doklad)');
END $$;

-- -----------------------------------------------------------------------------
-- E) VYFAKTUROVANOU AKCI UŽ NEJDE PŘEPSAT
--
-- Tři nové RPC neznaly pojem „už je to na dokladu", takže jedno kliknutí po
-- odeslání faktury rozešlo doklad s „Kdo kolik dluží".
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _rez uuid; _d1 uuid; _firma uuid; _dok uuid;
BEGIN
  SELECT id INTO _firma FROM public.subjects WHERE name = 'Demo Firma s.r.o.';
  SELECT id INTO _d1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST vyfakturovana','commercial','2027-08-11 16:00+02','2027-08-11 18:00+02',
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, approved_at, approved_by)
  VALUES (_d1, _firma, _ev, '2027-08-11 16:00+02','2027-08-11 18:00+02', now(),
          '11111111-1111-1111-1111-111111111111')
  RETURNING id INTO _rez;

  -- Doklad z Fakturoidu, jak ho zakládá `zapisDoklad` — pro test stačí vazba.
  INSERT INTO public.fakturoid_invoices
    (idempotency_key, druh, subject_id, event_id, nas_soucet, radku, rezervace, cislo)
  VALUES ('akce-test-'||_ev::text, 'commercial_event', _firma, _ev, 10000, 1, ARRAY[_rez], '2027-0001')
  RETURNING id INTO _dok;
  INSERT INTO public.fakturoid_invoice_reservations (fakturoid_invoice_id, reservation_id)
  VALUES (_dok, _rez);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, 1234)', _ev),
    'na vystaveném dokladu', 'vyfakturovanou akci nejde PŘECENIT');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_typ_akce(%L, %L)', _ev, 'training'),
    'na vystaveném dokladu', '… ani jí změnit TYP (což taky přepočítá cenu)');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_drahy_akce(%L, ARRAY[%L]::uuid[])', _ev,
           (SELECT id FROM public.sheets WHERE active AND id <> _d1 ORDER BY name LIMIT 1)),
    'na vystaveném dokladu', '… ani jí přeskládat DRÁHY');

  PERFORM pg_temp.tvrd(
    (SELECT amount FROM public.reservations WHERE id = _rez) = 10000,
    '… a částka na rezervaci zůstala ta, na kterou zní doklad');
END $$;

-- -----------------------------------------------------------------------------
-- F) ZMĚNA TYPU: instruktor u komerčky, konec trenérské směny
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _klub uuid; _v jsonb; _r record;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';

  INSERT INTO public.events (title, event_type, start_time, end_time, role_reqs, created_by)
  VALUES ('TEST typ stab','training','2027-06-30 17:00+02','2027-06-30 19:00+02','{}'::jsonb,
          '11111111-1111-1111-1111-111111111111') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at)
  VALUES ((SELECT id FROM public.sheets WHERE active ORDER BY name LIMIT 1), _klub, _ev,
          '2027-06-30 17:00+02','2027-06-30 19:00+02');

  -- K tréninku patří trenér — a tím vzniká PLACENÁ směna.
  INSERT INTO public.user_roles (user_id, role)
  VALUES ('22222222-2222-2222-2222-222222222222','trainer') ON CONFLICT DO NOTHING;
  PERFORM public.prirad_trenera(_ev, '22222222-2222-2222-2222-222222222222');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _ev AND required_role = 'trainer' AND status <> 'cancelled') = 1,
    'příprava: trénink má placenou trenérskou směnu');

  _v := public.zmen_typ_akce(_ev, 'commercial');

  PERFORM pg_temp.tvrd((_v->>'trener_zrusen')::int = 1,
    'přepnutí na komerční akci ZRUŠILO trenérskou směnu (hala ji jinak platí dál)');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _ev AND required_role = 'trainer' AND status <> 'cancelled') = 0,
    '… a živá trenérská směna na akci nezůstala');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _ev AND required_role = 'trainer' AND status = 'cancelled') = 1,
    '… zrušila se SOFT, nesmazala (zásada 2)');

  PERFORM pg_temp.tvrd((_v->>'doplnen_instruktor')::boolean,
    'komerční akci se doplnil instruktor (create_booking ho vyžaduje, tahle cesta ho obcházela)');
  SELECT role_reqs, required_staff INTO _r FROM public.events WHERE id = _ev;
  PERFORM pg_temp.tvrd((_r.role_reqs->>'instructor')::int >= 1, '… v rozpisu rolí je aspoň jeden');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.shifts
      WHERE event_id = _ev AND required_role = 'instructor' AND status <> 'cancelled') >= 1,
    '… a dorovnání štábu z něj udělalo skutečnou směnu k obsazení');
END $$;

-- -----------------------------------------------------------------------------
-- G) PRÁVA POD SKUTEČNOU ROLÍ (pravidlo 8)
--
-- Dřív tenhle soubor neměl ani jedno `SET LOCAL ROLE authenticated`, takže
-- všechno běželo jako postgres — a ten obchází granty i RLS. O admin-only
-- bráně u `zmen_typ_akce` tedy netvrdil vůbec nic.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _ev uuid; _klub uuid; _d1 uuid; _d2 uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  SELECT id INTO _d1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _d2 FROM public.sheets WHERE active AND id <> _d1 ORDER BY name LIMIT 1;

  INSERT INTO public.events (title, event_type, start_time, end_time, created_by)
  VALUES ('TEST prava','training','2027-07-21 17:00+02','2027-07-21 19:00+02',
          '44444444-4444-4444-4444-444444444444') RETURNING id INTO _ev;
  INSERT INTO public.reservations (sheet_id, subject_id, event_id, start_at, end_at, created_by)
  VALUES (_d1, _klub, _ev, '2027-07-21 17:00+02','2027-07-21 19:00+02',
          '44444444-4444-4444-4444-444444444444');

  INSERT INTO _s VALUES ('prava_ev', _ev::text), ('prava_d1', _d1::text), ('prava_d2', _d2::text);
END $$;

-- Zástupce klubu (44444444) — dráhy své akce spravovat SMÍ, cenu a typ NE.
DO $$
DECLARE _ev uuid; _d1 uuid; _d2 uuid; _v jsonb;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'prava_ev';
  SELECT hodnota::uuid INTO _d1 FROM _s WHERE klic = 'prava_d1';
  SELECT hodnota::uuid INTO _d2 FROM _s WHERE klic = 'prava_d2';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'kontrola práv běží jako authenticated, ne jako postgres');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.zmen_typ_akce(%L, %L)', _ev, 'commercial'),
    'jen správce haly', 'zástupce klubu NEZMĚNÍ typ akce (typ hýbe cenou)');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, 900)', _ev),
    'jen správce haly', 'zástupce klubu NEPŘECENÍ akci');

  _v := public.uprav_drahy_akce(_ev, ARRAY[_d1, _d2]);
  PERFORM pg_temp.tvrd((_v->>'pridano')::int = 1,
    'zástupce klubu dráhu ve SVÉ akci přidat smí');

  EXECUTE 'RESET ROLE';
END $$;

-- Brigádník bez vztahu ke klubu (33333333) nesmí nic.
DO $$
DECLARE _ev uuid; _d1 uuid;
BEGIN
  SELECT hodnota::uuid INTO _ev FROM _s WHERE klic = 'prava_ev';
  SELECT hodnota::uuid INTO _d1 FROM _s WHERE klic = 'prava_d1';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_drahy_akce(%L, ARRAY[%L]::uuid[])', _ev, _d1),
    'nemáte právo', 'cizí člověk dráhy akce neupraví');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.uprav_sazbu_akce(%L, 900)', _ev),
    'jen správce haly', '… ani ji nepřecení');

  EXECUTE 'RESET ROLE';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
