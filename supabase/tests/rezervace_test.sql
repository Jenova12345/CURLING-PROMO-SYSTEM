-- =============================================================================
-- TESTY REZERVAČNÍHO SYSTÉMU (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/rezervace_test.sql
-- Celý běh je v jedné transakci, která se na konci ROLLBACKuje → data zůstanou
-- jako po `supabase db reset`. Test projde, když skript doběhne bez chyby a vypíše
-- „VŠECHNY TESTY PROŠLY".
--
-- Pokrývá: kolize na dráze, celé hodiny, otevírací dobu, obě dráhy najednou,
-- schvalování členem/zástupcem, komerční akci s instruktorem, přebití tréninku
-- komerční akcí + notifikace, maskování ceny, opakované rezervace, přesun, storno.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Uživatelé ze seedu
--   1111… admin | 2222… instruktor (zástupce Curling Ostrava) | 4444… zástupce CPO | 5555… člen CPO
CREATE OR REPLACE FUNCTION pg_temp.prihlas(_user uuid) RETURNS void
 LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claims', json_build_object('sub', _user)::text, true);
$$;

CREATE OR REPLACE FUNCTION pg_temp.draha(_n int) RETURNS uuid
 LANGUAGE sql STABLE AS $$ SELECT id FROM public.sheets WHERE name = 'Dráha ' || _n; $$;

CREATE OR REPLACE FUNCTION pg_temp.cas(_text text) RETURNS timestamptz
 LANGUAGE sql IMMUTABLE AS $$ SELECT (_text::timestamp) AT TIME ZONE 'Europe/Prague'; $$;

-- Očekávaná chyba: tělo musí spadnout a hláška musí obsahovat úryvek.
CREATE OR REPLACE FUNCTION pg_temp.ocekavej_chybu(_sql text, _obsahuje text, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(_obsahuje) in lower(SQLERRM)) = 0 THEN
      RAISE EXCEPTION 'TEST SELHAL (%): čekal jsem chybu obsahující „%", přišlo: %', _popis, _obsahuje, SQLERRM;
    END IF;
    RAISE NOTICE 'OK  %: % ', _popis, SQLERRM;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST SELHAL (%): operace měla skončit chybou, ale prošla', _popis;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Admin: rezervace na OBĚ dráhy najednou (1 akce, 2 rezervace)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _pocet int;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _r := public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'training', 'Test obě dráhy',
    pg_temp.cas('2026-09-15 17:00'), pg_temp.cas('2026-09-15 19:00'),
    'aaaa1111-0000-0000-0000-000000000001');
  SELECT count(*) INTO _pocet FROM public.reservations
   WHERE event_id = (_r->>'event_id')::uuid AND status = 'confirmed';
  PERFORM pg_temp.tvrd(_pocet = 2, 'obě dráhy: jedna akce má dvě rezervace');
  PERFORM pg_temp.tvrd((_r->>'approved')::boolean, 'rezervace admina je rovnou potvrzená');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Kolize na jedné dráze — druhý dostane hlášku, ne pád
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  -- zástupce jiného klubu (Curling Ostrava) na obsazenou dráhu
  PERFORM pg_temp.prihlas('22222222-2222-2222-2222-222222222222');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid)',
      pg_temp.draha(1), 'training', 'Kolizní trénink',
      pg_temp.cas('2026-09-15 18:00'), pg_temp.cas('2026-09-15 19:00'),
      'aaaa1111-0000-0000-0000-000000000002'),
    'obsazená', 'kolize na dráze → srozumitelná hláška');

  -- admin bez vědomého přebití to taky nesmí projet potichu
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid, NULL, %L::jsonb)',
      pg_temp.draha(1), 'commercial', 'Komerční bez přebití',
      pg_temp.cas('2026-09-15 18:00'), pg_temp.cas('2026-09-15 19:00'),
      'bbbb2222-0000-0000-0000-000000000001', '{"instructor": 1}'),
    'přebit', 'admin: kolize vyžaduje vědomé přebití');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Jen celé hodiny + otevírací doba
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid)',
      pg_temp.draha(1), 'training', 'Půlhodina',
      pg_temp.cas('2026-09-16 17:30'), pg_temp.cas('2026-09-16 19:00'),
      'aaaa1111-0000-0000-0000-000000000001'),
    'celé hodiny', 'půlhodinu nelze rezervovat');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid)',
      pg_temp.draha(1), 'training', 'Před otevřením',
      pg_temp.cas('2026-09-16 06:00'), pg_temp.cas('2026-09-16 07:00'),
      'aaaa1111-0000-0000-0000-000000000001'),
    'otevírací dob', 'mimo otevírací dobu (před 7:00)');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid)',
      pg_temp.draha(1), 'training', 'Po zavírací',
      pg_temp.cas('2026-09-16 21:00'), pg_temp.cas('2026-09-16 23:00'),
      'aaaa1111-0000-0000-0000-000000000001'),
    'otevírací dob', 'mimo otevírací dobu (po 22:00)');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Člen klubu rezervuje → čeká na potvrzení zástupce (+ notifikace)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _res uuid; _appr timestamptz; _notif int;
BEGIN
  PERFORM pg_temp.prihlas('55555555-5555-5555-5555-555555555555');  -- člen CPO
  _r := public.create_booking(
    ARRAY[pg_temp.draha(2)], 'training', 'Trénink člena',
    pg_temp.cas('2026-09-16 17:00'), pg_temp.cas('2026-09-16 18:00'),
    'aaaa1111-0000-0000-0000-000000000001');
  _res := ((_r->'reservation_ids')->>0)::uuid;

  SELECT approved_at INTO _appr FROM public.reservations WHERE id = _res;
  PERFORM pg_temp.tvrd(_appr IS NULL, 'rezervace člena čeká na potvrzení');

  SELECT count(*) INTO _notif FROM public.notifications
   WHERE type = 'reservation_needs_approval'
     AND user_id = '44444444-4444-4444-4444-444444444444'   -- zástupce CPO
     AND reservation_id = _res;
  PERFORM pg_temp.tvrd(_notif = 1, 'zástupce dostal upozornění k potvrzení');

  -- člen sám sobě nepotvrdí
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_reservation(%L::uuid)', _res),
    'zástupce', 'člen si rezervaci sám nepotvrdí');

  -- zástupce potvrdí → autor dostane zprávu
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM public.approve_reservation(_res);
  SELECT approved_at INTO _appr FROM public.reservations WHERE id = _res;
  PERFORM pg_temp.tvrd(_appr IS NOT NULL, 'zástupce rezervaci potvrdil');

  SELECT count(*) INTO _notif FROM public.notifications
   WHERE type = 'reservation_approved'
     AND user_id = '55555555-5555-5555-5555-555555555555'
     AND reservation_id = _res;
  PERFORM pg_temp.tvrd(_notif = 1, 'autor dostal zprávu o potvrzení');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Komerční akce: bez instruktora nejde; s instruktorem vzniknou směny
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _smeny int;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid, NULL, %L::jsonb)',
      pg_temp.draha(1), 'commercial', 'Teambuilding bez instruktora',
      pg_temp.cas('2026-09-17 17:00'), pg_temp.cas('2026-09-17 19:00'),
      'bbbb2222-0000-0000-0000-000000000001', '{"bar_staff": 1}'),
    'instruktora', 'komerční akce bez instruktora neprojde');

  _r := public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'commercial', 'Teambuilding Demo Firma',
    pg_temp.cas('2026-09-17 17:00'), pg_temp.cas('2026-09-17 19:00'),
    'bbbb2222-0000-0000-0000-000000000001', NULL, '{"instructor": 2, "bar_staff": 1}'::jsonb);

  SELECT count(*) INTO _smeny FROM public.shifts WHERE event_id = (_r->>'event_id')::uuid;
  PERFORM pg_temp.tvrd(_smeny = 3, 'komerční akce vygenerovala 3 směny (2 instruktoři + bar)');
END $$;

-- -----------------------------------------------------------------------------
-- 6) Priorita: komerční přebije trénink (vědomě) → storno + notifikace klubu
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _zruseno int; _notif int; _duvod text;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _r := public.create_booking(
    ARRAY[pg_temp.draha(1)], 'commercial', 'Firemní akce přes trénink',
    pg_temp.cas('2026-09-15 17:00'), pg_temp.cas('2026-09-15 19:00'),
    'bbbb2222-0000-0000-0000-000000000001', NULL, '{"instructor": 1}'::jsonb, NULL, true);

  PERFORM pg_temp.tvrd(jsonb_array_length(_r->'cancelled') = 1, 'přebití zrušilo kolidující trénink');

  SELECT count(*), max(cancel_reason) INTO _zruseno, _duvod
    FROM public.reservations
   WHERE status = 'cancelled' AND cancel_reason LIKE 'Přebito akcí vyšší priority%';
  PERFORM pg_temp.tvrd(_zruseno >= 1 AND _duvod IS NOT NULL, 'zrušená rezervace má důvod i autora storna');

  SELECT count(*) INTO _notif FROM public.notifications
   WHERE type = 'reservation_overridden'
     AND user_id IN ('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555');
  PERFORM pg_temp.tvrd(_notif >= 2, 'zástupce i člen klubu dostali upozornění o zrušení');

  -- opačně to nejde: trénink nepřebije komerční akci
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid, NULL, ''{}''::jsonb, NULL, true)',
      pg_temp.draha(1), 'training', 'Trénink přes komerci',
      pg_temp.cas('2026-09-15 17:00'), pg_temp.cas('2026-09-15 18:00'),
      'aaaa1111-0000-0000-0000-000000000001'),
    'nelze přebít', 'trénink nepřebije komerční akci');
END $$;

-- -----------------------------------------------------------------------------
-- 7) Opakované tréninky (Út + Čt do data)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _pocet int;
BEGIN
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');   -- zástupce CPO
  _r := public.create_booking_series(
    ARRAY[pg_temp.draha(2)], 'training', 'Pravidelný trénink',
    pg_temp.cas('2026-10-06 16:00'), pg_temp.cas('2026-10-06 18:00'),
    ARRAY[2, 4], '2026-10-31'::date,
    'aaaa1111-0000-0000-0000-000000000001');

  SELECT count(*) INTO _pocet FROM public.reservations
   WHERE series_id = (_r->>'series_id')::uuid AND status = 'confirmed';
  PERFORM pg_temp.tvrd(_pocet = 8, format('série vytvořila 8 termínů (Út+Čt v říjnu), vytvořeno %s', _pocet));
  PERFORM pg_temp.tvrd((_r->>'created')::int = _pocet, 'počet v odpovědi sedí s DB');
END $$;

-- -----------------------------------------------------------------------------
-- 8) Přesun (drag & drop) — volný termín ano, obsazený ne
-- -----------------------------------------------------------------------------
DO $$
DECLARE _res uuid; _novy timestamptz;
BEGIN
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  SELECT id INTO _res FROM public.reservations
   WHERE subject_id = 'aaaa1111-0000-0000-0000-000000000001'
     AND status = 'confirmed' AND start_at = pg_temp.cas('2026-10-06 16:00') LIMIT 1;

  PERFORM public.move_booking(_res, pg_temp.cas('2026-10-07 16:00'), pg_temp.cas('2026-10-07 18:00'));
  SELECT start_at INTO _novy FROM public.reservations WHERE id = _res;
  PERFORM pg_temp.tvrd(_novy = pg_temp.cas('2026-10-07 16:00'), 'přesun na volný termín proběhl');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L::uuid, %L::timestamptz, %L::timestamptz)',
      _res, pg_temp.cas('2026-10-08 16:00'), pg_temp.cas('2026-10-08 18:00')),
    'kryje', 'přesun na obsazený termín odmítnut');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L::uuid, %L::timestamptz, %L::timestamptz)',
      _res, pg_temp.cas('2026-10-07 16:30'), pg_temp.cas('2026-10-07 18:30')),
    'celé hodiny', 'přesun mimo celé hodiny odmítnut');
END $$;

-- -----------------------------------------------------------------------------
-- 9) Storno: jedna dráha vs celá akce; směny se ruší až s poslední rezervací
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r jsonb; _res uuid[]; _ev uuid; _open int; _ziv int;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  _r := public.create_booking(
    ARRAY[pg_temp.draha(1), pg_temp.draha(2)], 'commercial', 'Akce ke stornu',
    pg_temp.cas('2026-09-18 17:00'), pg_temp.cas('2026-09-18 19:00'),
    'bbbb2222-0000-0000-0000-000000000001', NULL, '{"instructor": 1}'::jsonb);
  _ev := (_r->>'event_id')::uuid;
  SELECT array_agg(id) INTO _res FROM public.reservations WHERE event_id = _ev;

  PERFORM public.cancel_booking(_res[1], 'single', 'test storno jedné dráhy');
  SELECT count(*) INTO _open FROM public.shifts WHERE event_id = _ev AND status = 'open';
  PERFORM pg_temp.tvrd(_open = 1, 'storno jedné dráhy nesebralo akci štáb');

  PERFORM public.cancel_booking(_res[2], 'single', 'test storno druhé dráhy');
  SELECT count(*) INTO _open FROM public.shifts WHERE event_id = _ev AND status = 'open';
  PERFORM pg_temp.tvrd(_open = 0, 'storno poslední dráhy uvolnilo volné směny');

  SELECT count(*) INTO _ziv FROM public.reservations
   WHERE event_id = _ev AND status = 'confirmed';
  PERFORM pg_temp.tvrd(_ziv = 0, 'obě rezervace akce jsou stornované');

  PERFORM pg_temp.tvrd(
    (SELECT bool_and(cancelled_by = '11111111-1111-1111-1111-111111111111' AND cancelled_at IS NOT NULL)
       FROM public.reservations WHERE event_id = _ev),
    'u storna je vidět kdo a kdy zrušil');
END $$;

-- -----------------------------------------------------------------------------
-- 10) Maskování ceny: jméno vidí všichni, částku jen admin a autor
-- -----------------------------------------------------------------------------
DO $$
DECLARE _cizi uuid; _jmeno text; _castka numeric;
BEGIN
  -- rezervace, kterou založil admin za CPO (autor = admin)
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  SELECT id INTO _cizi FROM public.reservations
   WHERE created_by = '11111111-1111-1111-1111-111111111111'
     AND subject_id = 'aaaa1111-0000-0000-0000-000000000001'
     AND status = 'confirmed' LIMIT 1;

  -- očima člena jiného klubu (instruktor = zástupce Curling Ostrava)
  PERFORM pg_temp.prihlas('22222222-2222-2222-2222-222222222222');
  SELECT subject_name, amount INTO _jmeno, _castka
    FROM public.reservations_calendar WHERE id = _cizi;
  PERFORM pg_temp.tvrd(_jmeno IS NOT NULL, 'cizí klub vidí název subjektu/akce');
  PERFORM pg_temp.tvrd(_castka IS NULL, 'cizí klub NEvidí částku');

  -- očima admina
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  SELECT amount INTO _castka FROM public.reservations_calendar WHERE id = _cizi;
  PERFORM pg_temp.tvrd(_castka IS NOT NULL, 'admin vidí částku');
END $$;

-- Sloupcová práva: role authenticated se k cenám přes tabulku vůbec nedostane
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    'SET LOCAL ROLE authenticated; SELECT amount FROM public.reservations LIMIT 1',
    'permission denied', 'cenu nejde číst přímo z tabulky reservations');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 11) Duplicitní IČO — ARES musí najít existující subjekt
-- -----------------------------------------------------------------------------
DO $$
DECLARE _id uuid; _n int;
BEGIN
  PERFORM pg_temp.prihlas('11111111-1111-1111-1111-111111111111');
  SELECT id INTO _id FROM public.find_subject_by_ico('12345678');
  PERFORM pg_temp.tvrd(_id = 'bbbb2222-0000-0000-0000-000000000002', 'find_subject_by_ico našel existující firmu');

  BEGIN
    INSERT INTO public.subjects (type, name, ico) VALUES ('commercial', 'Duplicitní firma', '12345678');
    RAISE EXCEPTION 'TEST SELHAL: duplicitní IČO prošlo';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  duplicitní IČO odmítnuto na úrovni DB';
  END;
END $$;

-- -----------------------------------------------------------------------------
-- 12) Oprávnění: co ne-admin a cizí klub NESMÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _cizi uuid; _moje uuid; _r jsonb; _rate numeric;
BEGIN
  PERFORM pg_temp.prihlas('55555555-5555-5555-5555-555555555555');  -- člen CPO

  -- rezervace za cizí klub
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid)',
      pg_temp.draha(1), 'training', 'Rezervace za cizí klub',
      pg_temp.cas('2026-09-22 17:00'), pg_temp.cas('2026-09-22 18:00'),
      'aaaa1111-0000-0000-0000-000000000002'),
    'oprávnění', 'člen nerezervuje za cizí klub');

  -- komerční akce a údržba jsou adminské
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz, %L::uuid, NULL, %L::jsonb)',
      pg_temp.draha(1), 'commercial', 'Komerční od člena',
      pg_temp.cas('2026-09-22 17:00'), pg_temp.cas('2026-09-22 18:00'),
      'bbbb2222-0000-0000-0000-000000000001', '{"instructor": 1}'),
    'jen správce', 'člen nezaloží komerční akci');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.create_booking(ARRAY[%L::uuid], %L, %L, %L::timestamptz, %L::timestamptz)',
      pg_temp.draha(1), 'maintenance', 'Údržba od člena',
      pg_temp.cas('2026-09-22 17:00'), pg_temp.cas('2026-09-22 18:00')),
    'jen správce', 'člen nezaloží údržbu ledu');

  -- sazbu si ne-admin nediktuje: RPC ji ignoruje a vezme ceník
  _r := public.create_booking(
    ARRAY[pg_temp.draha(1)], 'training', 'Trénink se sazbou 1 Kč',
    pg_temp.cas('2026-09-22 17:00'), pg_temp.cas('2026-09-22 18:00'),
    'aaaa1111-0000-0000-0000-000000000001', NULL, '{}'::jsonb, 1);
  _moje := ((_r->'reservation_ids')->>0)::uuid;
  SELECT rate_per_hour INTO _rate FROM public.reservations WHERE id = _moje;
  PERFORM pg_temp.tvrd(_rate > 1, format('sazba od ne-admina se ignoruje (v DB je %s)', _rate));

  -- cizí rezervaci nelze stornovat ani přesunout
  SELECT id INTO _cizi FROM public.reservations
   WHERE subject_id = 'aaaa1111-0000-0000-0000-000000000002' AND status = 'confirmed' LIMIT 1;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.cancel_booking(%L::uuid)', _cizi),
    'nemáte právo', 'cizí rezervaci nelze stornovat');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.move_booking(%L::uuid, %L::timestamptz, %L::timestamptz)',
      _cizi, pg_temp.cas('2026-09-23 17:00'), pg_temp.cas('2026-09-23 18:00')),
    'nemáte právo', 'cizí rezervaci nelze přesunout');

  -- člen nesmí sáhnout ani na rezervaci kolegy ze stejného klubu (vytvořil ji admin)
  SELECT id INTO _cizi FROM public.reservations
   WHERE subject_id = 'aaaa1111-0000-0000-0000-000000000001'
     AND created_by = '11111111-1111-1111-1111-111111111111'
     AND status = 'confirmed' LIMIT 1;
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.cancel_booking(%L::uuid)', _cizi),
    'nemáte právo', 'člen nestornuje cizí rezervaci vlastního klubu');

  -- zástupce téhož klubu ale ano
  PERFORM pg_temp.prihlas('44444444-4444-4444-4444-444444444444');
  PERFORM public.cancel_booking(_cizi, 'single', 'zástupce ruší za klub');
  PERFORM pg_temp.tvrd(
    (SELECT status = 'cancelled' FROM public.reservations WHERE id = _cizi),
    'zástupce klubu smí stornovat rezervace celého klubu');
END $$;

-- -----------------------------------------------------------------------------
-- 13) Guard: přímý zápis do tabulky (mimo RPC) nesmí nic podvrhnout
-- -----------------------------------------------------------------------------
DO $$
DECLARE _res uuid;
BEGIN
  PERFORM pg_temp.prihlas('55555555-5555-5555-5555-555555555555');

  -- přímý INSERT bez RPC: člen si nesmí sám potvrdit rezervaci ani určit sazbu
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, rate_per_hour, approved_at, approved_by)
  VALUES (pg_temp.draha(2), 'aaaa1111-0000-0000-0000-000000000001',
          pg_temp.cas('2026-09-24 17:00'), pg_temp.cas('2026-09-24 18:00'),
          1, now(), '55555555-5555-5555-5555-555555555555')
  RETURNING id INTO _res;

  PERFORM pg_temp.tvrd(
    (SELECT approved_at IS NULL FROM public.reservations WHERE id = _res),
    'guard: člen si přímým zápisem rezervaci nepotvrdí');
  PERFORM pg_temp.tvrd(
    (SELECT rate_per_hour > 1 FROM public.reservations WHERE id = _res),
    'guard: člen si přímým zápisem nenastaví sazbu');

  -- potvrzení cizí rukou také ne
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.reservations SET approved_at = now() WHERE id = %L::uuid', _res),
    'zástupce klubu', 'guard: člen si nepotvrdí rezervaci ani UPDATEm');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
