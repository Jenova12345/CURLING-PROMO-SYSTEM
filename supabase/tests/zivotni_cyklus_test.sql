-- =============================================================================
-- TESTY ŽIVOTNÍHO CYKLU ÚČTU (blok C)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/zivotni_cyklus_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Registrace už nedává roli. Účet čeká, dokud ho admin nebo zástupce klubu
-- neschválí — a schválení přidělí členství, roli i stav `aktivni` najednou.
-- Nejcennější tvrzení jsou proto ta o tom, co účet ve stavu `ceka` NESMÍ,
-- a to, že deaktivovaný účet zavře brána `ucet_aktivni()` i tehdy, když mu
-- role zůstala.
--
-- ⚠️ POVINNĚ POD `SET LOCAL ROLE authenticated` (pravidlo 8 z CLAUDE.md).
-- Jako `postgres` projde všechno — takový test by tvrdil zavřeno o dveřích,
-- vedle kterých je otevřené okno. Že se role opravdu přepíná, kontroluje
-- tvrzení `current_user = 'authenticated'` v každé takové sekci.
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
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
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
GRANT ALL ON _s TO authenticated;

CREATE OR REPLACE FUNCTION pg_temp.registruj(_email text, _jmeno text, _klub text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE _id uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  VALUES (
    '00000000-0000-0000-0000-000000000000', _id, 'authenticated', 'authenticated', _email,
    'x', now(), now(), now(),
    '{"provider":"email","providers":["email"]}',
    jsonb_build_object('full_name', _jmeno) || CASE WHEN _klub IS NULL THEN '{}'::jsonb
                                                    ELSE jsonb_build_object('subject_id', _klub) END,
    '', '', '', '');
  RETURN _id;
END $$;

-- -----------------------------------------------------------------------------
-- 1) Registrace: profil ano, role ne
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _novy uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  _novy := pg_temp.registruj('cyklus-novy@test.local', 'Nováček', _klub::text);
  INSERT INTO _s VALUES ('novy', _novy::text), ('klub', _klub::text);

  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _novy) = 'ceka',
    'po registraci je účet ve stavu „ceka"');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.user_roles WHERE user_id = _novy) = 0,
    'a nemá ŽÁDNOU roli (dřív dostal hobby_player hned)');
  PERFORM pg_temp.tvrd(NOT public.ucet_aktivni(_novy),
    '… takže ho default-deny brána nepustí nikam');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_requests WHERE user_id = _novy AND status = 'ceka') = 1,
    'a čeká na něj žádost o klub z registračního formuláře');
END $$;

-- -----------------------------------------------------------------------------
-- 2) DEFAULT-DENY: deaktivovaný účet zavře brána i s rolí (R6)
--
-- Tohle je ten případ, kvůli kterému brána vůbec je. Účet ve stavu `ceka`
-- neprojde „náhodou" (nemá roli ani členství), ale deaktivovaný admin roli MÁ.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _admin uuid := '11111111-1111-1111-1111-111111111111';
BEGIN
  PERFORM pg_temp.tvrd(public.has_role(_admin, 'admin'),
    'aktivní admin má roli admin');

  UPDATE public.profiles SET stav = 'deaktivovan' WHERE user_id = _admin;
  PERFORM pg_temp.tvrd(NOT public.has_role(_admin, 'admin'),
    'DEAKTIVOVANÝ admin roli ztrácí, i když mu v user_roles zůstala');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.user_roles WHERE user_id = _admin AND role = 'admin') = 1,
    '… a to bez sahání na user_roles (řádek tam pořád je)');

  UPDATE public.profiles SET stav = 'aktivni' WHERE user_id = _admin;
  PERFORM pg_temp.tvrd(public.has_role(_admin, 'admin'),
    'a znovuaktivací se role vrací');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Schvaluje i ZÁSTUPCE, a schválení přidělí roli i klub (R4, R5)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _zastupce uuid := '55555555-5555-5555-5555-555555555555';
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  INSERT INTO public.subject_reps (subject_id, user_id, level)
  VALUES (_klub, _zastupce, 'rep')
  ON CONFLICT (subject_id, user_id) DO UPDATE SET level = 'rep';
  PERFORM pg_temp.tvrd(true, 'příprava: clen2 je zástupcem klubu');
END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';

DO $$
DECLARE _z uuid; _novy uuid; _klub uuid;
BEGIN
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'sekce práv OPRAVDU běží jako authenticated, ne jako postgres');

  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';

  -- Zástupce musí žádost ve frontě VIDĚT, jinak by mu právo schválit bylo k ničemu.
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_requests
      WHERE user_id = _novy AND subject_id = _klub) = 1,
    'zástupce vidí čekající žádost do svého klubu');

  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _novy AND status = 'ceka';

  -- Úroveň „zástupce" smí udělit jen admin — jinak by si zástupce vyrobil dalšího.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, ''rep'')', _z),
    'jmenovat jen správce haly', 'zástupce NESMÍ jmenovat dalšího zástupce');

  PERFORM public.approve_subject_request(_z, 'member');
  PERFORM pg_temp.tvrd(true, 'zástupce schválil žádost do svého klubu (R5)');
END $$;

RESET ROLE;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

DO $$
DECLARE _novy uuid; _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps
      WHERE user_id = _novy AND subject_id = _klub AND level = 'member') = 1,
    'schválením vzniklo členství v klubu');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.user_roles WHERE user_id = _novy AND role = 'hobby_player') = 1,
    '… a JEDNÍM KROKEM i role hobby_player (R4)');
  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _novy) = 'aktivni',
    '… a účet je aktivní');
  PERFORM pg_temp.tvrd(public.ucet_aktivni(_novy),
    '… takže ho brána pouští dovnitř');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Zástupce jen do SVÉHO klubu
-- -----------------------------------------------------------------------------
DO $$
DECLARE _cizi uuid; _dalsi uuid; _z uuid;
BEGIN
  SELECT id INTO _cizi FROM public.subjects WHERE name = 'HC Ostrava';
  _dalsi := pg_temp.registruj('cyklus-cizi@test.local', 'Cizí Žadatel', _cizi::text);
  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _dalsi AND status = 'ceka';
  INSERT INTO _s VALUES ('zadost_cizi', _z::text);
END $$;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';

DO $$
DECLARE _z uuid;
BEGIN
  SELECT hodnota::uuid INTO _z FROM _s WHERE klic = 'zadost_cizi';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, ''member'')', _z),
    'jen jako jeho zástupce', 'zástupce NESMÍ schvalovat do CIZÍHO klubu');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.reject_subject_request(%L)', _z),
    'jen zástupce toho klubu', '… ani zamítat cizí žádost');
END $$;

RESET ROLE;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- 5) PRÁVO NAVÍC: hráč si potvrdí JEN SVOJI rezervaci (R11)
--
-- Hráčem je tu `_novy` — účet, který jsme před chvílí nechali schválit, takže
-- je ŘADOVÝ ČLEN klubu. Seedový `clen@test.local` se na tohle nehodí: je
-- v `CK Ostravské kameny` vedený jako ZÁSTUPCE, takže by rezervace potvrzoval
-- z titulu úrovně a test by měřil úplně jinou větev.
--
-- Role i claim se přepínají uvnitř DO bloku přes `set_config` a `EXECUTE SET
-- LOCAL ROLE`, protože id uživatele je dynamické.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _novy uuid; _moje uuid; _cizi uuid; _sheet uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  SELECT id INTO _sheet FROM public.sheets WHERE active ORDER BY name LIMIT 1;

  PERFORM pg_temp.tvrd(
    (SELECT level FROM public.subject_reps WHERE subject_id = _klub AND user_id = _novy) = 'member',
    'příprava: hráč je řadový ČLEN klubu, ne zástupce');

  -- Jeho vlastní rezervace a rezervace někoho jiného, obě nepotvrzené.
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, created_by, approved_at)
  VALUES (_sheet, _klub, '2027-02-03 17:00+01', '2027-02-03 19:00+01', _novy, NULL)
  RETURNING id INTO _moje;
  INSERT INTO public.reservations (sheet_id, subject_id, start_at, end_at, created_by, approved_at)
  VALUES (_sheet, _klub, '2027-02-10 17:00+01', '2027-02-10 19:00+01',
          '55555555-5555-5555-5555-555555555555', NULL)
  RETURNING id INTO _cizi;

  INSERT INTO _s VALUES ('moje', _moje::text), ('cizi_rez', _cizi::text);
END $$;

DO $$
DECLARE _moje uuid; _novy uuid;
BEGIN
  SELECT hodnota::uuid INTO _moje FROM _s WHERE klic = 'moje';
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _novy, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'sekce práv OPRAVDU běží jako authenticated');
  PERFORM pg_temp.tvrd(NOT public.is_subject_rep(
    (SELECT hodnota::uuid FROM _s WHERE klic = 'klub')),
    '… a pod NEzástupcem');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_reservation(%L)', _moje),
    'jen zástupce klubu nebo správce',
    'hráč BEZ práva navíc nepotvrdí ani svoji rezervaci');

  EXECUTE 'RESET ROLE';
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

DO $$
DECLARE _klub uuid; _novy uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  PERFORM public.nastav_pravo_navic(_klub, _novy, true);
  PERFORM pg_temp.tvrd(true, 'admin udělil hráči právo navíc');
END $$;

DO $$
DECLARE _moje uuid; _cizi uuid; _novy uuid;
BEGIN
  SELECT hodnota::uuid INTO _moje FROM _s WHERE klic = 'moje';
  SELECT hodnota::uuid INTO _cizi FROM _s WHERE klic = 'cizi_rez';
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _novy, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  -- CIZÍ rezervaci nepotvrdí ani s právem navíc — to je celý smysl slova
  -- „svoji". Jinak by z práva navíc bylo tiché povýšení na zástupce.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_reservation(%L)', _cizi),
    'jen zástupce klubu nebo správce',
    'hráč s právem navíc NEPOTVRDÍ cizí rezervaci');

  PERFORM public.approve_reservation(_moje);
  PERFORM pg_temp.tvrd(true, 'hráč s právem navíc potvrdil SVOJI rezervaci (R11)');

  EXECUTE 'RESET ROLE';
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

DO $$
DECLARE _moje uuid; _cizi uuid;
BEGIN
  SELECT hodnota::uuid INTO _moje FROM _s WHERE klic = 'moje';
  SELECT hodnota::uuid INTO _cizi FROM _s WHERE klic = 'cizi_rez';
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations WHERE id = _moje) IS NOT NULL,
    'jeho rezervace je opravdu potvrzená');
  PERFORM pg_temp.tvrd(
    (SELECT approved_at FROM public.reservations WHERE id = _cizi) IS NULL,
    '… a ta cizí zůstala nepotvrzená');
END $$;

-- -----------------------------------------------------------------------------
-- 6) Právo navíc uděluje jen zástupce nebo admin
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _novy uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', _novy, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.nastav_pravo_navic(%L, %L, true)', _klub,
           '33333333-3333-3333-3333-333333333333'),
    'uděluje zástupce klubu nebo správce',
    'hráč s právem navíc ho nemůže rozdávat dál');

  EXECUTE 'RESET ROLE';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
