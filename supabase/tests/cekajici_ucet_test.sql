-- =============================================================================
-- TESTY: čekající účet nevidí nic, schválený vidí přesně své
-- Migrace 20260831235000_cekajici_ucet_nevidi_nic.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/cekajici_ucet_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Celá brána mezi „zaregistroval se" a „je uvnitř" — a hlídá ji tam, kde se
-- doopravdy rozhoduje, tedy pod `SET LOCAL ROLE authenticated` (pravidlo 8).
-- Jako postgres projde všechno a test by tvrdil zavřeno o dveřích, vedle
-- kterých je otevřené okno.
--
-- Nejcennější tvrzení je to první: účet ve stavu `ceka` nesmí přečíst ANI JEDEN
-- řádek kalendáře. Do 31. 8. jich četl osmdesát — jména klubů, firem i časy —
-- protože `reservations_calendar` běží pod vlastníkem a RLS ho míjí.
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

-- Kolik řádků uvidí přihlášený uživatel `_uid` v daném pohledu/tabulce.
CREATE OR REPLACE FUNCTION pg_temp.vidi(_uid uuid, _co text) RETURNS bigint
 LANGUAGE plpgsql AS $$
DECLARE _n bigint;
BEGIN
  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _uid), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE format('SELECT count(*) FROM public.%I', _co) INTO _n;
  EXECUTE 'RESET ROLE';
  RETURN _n;
END $$;

CREATE TEMP TABLE _s (klic text PRIMARY KEY, hodnota text);
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

-- -----------------------------------------------------------------------------
-- Příprava: registrace nového člověka (přes trigger na auth.users, ne ručně)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid := '88888888-8888-8888-8888-888888888881'; _klub uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';

  INSERT INTO auth.users (id, email, instance_id, aud, role, raw_user_meta_data)
  VALUES (_novy, 'novacek@test.local', '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          jsonb_build_object('full_name','Nováček Čekající','subject_id',_klub::text));

  INSERT INTO _s VALUES ('novy', _novy::text), ('klub', _klub::text);

  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _novy) = 'ceka',
    'registrace založila profil ve stavu „ceka" (trigger handle_new_user)');
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _novy),
    '… a NEPŘIDĚLILA žádnou roli');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_requests WHERE user_id = _novy AND status = 'ceka') = 1,
    '… ale vyrobila žádost o klub z registračního formuláře');
  PERFORM pg_temp.tvrd(NOT public.ucet_aktivni(_novy), '… a ucet_aktivni() ho nepouští');
END $$;

-- -----------------------------------------------------------------------------
-- 1) ČEKAJÍCÍ ÚČET NEVIDÍ NIC
--
-- Měřeno reálným dotazem pod jeho vlastním tokenem, ne úvahou o politikách.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid; _co text; _n bigint;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';

  FOREACH _co IN ARRAY ARRAY[
    'reservations_calendar',   -- do 31. 8. jich viděl 80: jména klubů, firem, časy
    'events',                  -- … a 42 akcí
    'reservations', 'subjects', 'subjects_rates', 'cenik_pasma', 'settings_public',
    'shifts', 'reservations_billing', 'invoices_list', 'subject_reps',
    'stab_kontrola'
  ] LOOP
    _n := pg_temp.vidi(_novy, _co);
    PERFORM pg_temp.tvrd(_n = 0, format('čekající účet nevidí v „%s" ani řádek (vidí %s)', _co, _n));
  END LOOP;
END $$;

-- Vlastní žádost o klub vidět SMÍ — je to jeho žádost a stojí na ní čekací
-- obrazovka. Politika na `subject_requests` je self-scoped
-- (`user_id = auth.uid() OR admin OR is_subject_rep`), takže cizí neuvidí.
DO $$
DECLARE _novy uuid; _n bigint; _cizich bigint;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';

  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n      FROM public.subject_requests_list;
  SELECT count(*) INTO _cizich FROM public.subject_requests_list WHERE user_id <> _novy;
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd(_n = 1,      'ze žádostí vidí přesně jednu — tu svoji');
  PERFORM pg_temp.tvrd(_cizich = 0, '… a ani jednu cizí');
END $$;

-- Výjimky, které vidět MUSÍ: svůj profil a seznam klubů.
DO $$
DECLARE _novy uuid; _n bigint; _stav text;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';

  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  SELECT count(*) INTO _n FROM public.profiles_self;
  PERFORM pg_temp.tvrd(_n = 1, 'vidí PŘESNĚ JEDEN profil — svůj (jinak by nepoznal, že se čeká)');
  SELECT stav INTO _stav FROM public.profiles_self;
  PERFORM pg_temp.tvrd(_stav = 'ceka', '… a je v něm stav „ceka", ze kterého UI udělá čekací obrazovku');

  SELECT count(*) INTO _n FROM public.clubs_public;
  PERFORM pg_temp.tvrd(_n > 0, 'seznam klubů zůstal čitelný (bez něj nejde dokončit registrace)');

  EXECUTE 'RESET ROLE';
END $$;

-- -----------------------------------------------------------------------------
-- 2) PO SCHVÁLENÍ VIDÍ TO, CO MU ROLE DOVOLÍ
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid; _z uuid; _n bigint;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _novy AND status = 'ceka';

  -- Schvaluje ZÁSTUPCE klubu (44444444), ne admin — to je ta rizikovější cesta.
  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.approve_subject_request(_z, 'member');
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _novy) = 'aktivni',
    'po schválení je účet „aktivni"');
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _novy AND role = 'hobby_player'),
    '… a má roli hobby_player');

  _n := pg_temp.vidi(_novy, 'reservations_calendar');
  PERFORM pg_temp.tvrd(_n > 0, 'teprve teď vidí kalendář (obsazenost vidí všichni VPUŠTĚNÍ)');

  -- Ale peníze pořád ne — role člena na ně nemá.
  PERFORM pg_temp.tvrd(pg_temp.vidi(_novy, 'reservations_billing') = 0,
    '… „Kdo kolik dluží" ale pořád nevidí (to je jen pro admina)');
  PERFORM pg_temp.tvrd(pg_temp.vidi(_novy, 'cenik_pasma') = 0,
    '… ani ceník ledu (sazby jsou částky)');
  PERFORM pg_temp.tvrd(pg_temp.vidi(_novy, 'subjects_rates') = 0,
    '… ani sazby subjektů');

  -- Částku u cizí rezervace nesmí vidět ani v kalendáři.
  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n FROM public.reservations_calendar WHERE amount IS NOT NULL;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n = 0, '… a v kalendáři nevidí u žádné rezervace částku');
END $$;

-- -----------------------------------------------------------------------------
-- 3) DEAKTIVACE ÚČET ZASE ZAVŘE (brána drží oběma směry)
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  UPDATE public.profiles SET stav = 'deaktivovan' WHERE user_id = _novy;

  PERFORM pg_temp.tvrd(pg_temp.vidi(_novy, 'reservations_calendar') = 0,
    'deaktivovaný účet přijde o kalendář hned, i když roli i členství má dál');
  PERFORM pg_temp.tvrd(pg_temp.vidi(_novy, 'events') = 0, '… i o akce');

  UPDATE public.profiles SET stav = 'aktivni' WHERE user_id = _novy;
END $$;

-- -----------------------------------------------------------------------------
-- 4) ZÁSTUPCE SCHVALUJE JEN DO SVÉHO KLUBU
-- -----------------------------------------------------------------------------
DO $$
DECLARE _cizi uuid := '88888888-8888-8888-8888-888888888882'; _jiny_klub uuid; _z uuid;
BEGIN
  -- Žadatel míří do klubu „Curling Ostrava", jehož zástupce je 22222222.
  SELECT id INTO _jiny_klub FROM public.subjects WHERE name = 'Curling Ostrava';

  INSERT INTO auth.users (id, email, instance_id, aud, role, raw_user_meta_data)
  VALUES (_cizi, 'cizi@test.local', '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          jsonb_build_object('full_name','Cizí Žadatel','subject_id',_jiny_klub::text));
  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _cizi AND status = 'ceka';

  -- 44444444 je zástupce JINÉHO klubu (CK Ostravské kameny).
  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, %L)', _z, 'member'),
    'jen jako jeho zástupce', 'zástupce NEschválí člověka do cizího klubu');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.reject_subject_request(%L, NULL)', _z),
    'zástupce toho klubu', '… ani ho do cizího klubu nezamítne');

  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _cizi) = 'ceka',
    '… a cizí žadatel zůstal čekat');
END $$;

-- A ÚROVEŇ „ZÁSTUPCE" NEUDĚLÍ ANI VE SVÉM KLUBU — to smí jen admin.
DO $$
DECLARE _treti uuid := '88888888-8888-8888-8888-888888888883'; _klub uuid; _z uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _s WHERE klic = 'klub';
  INSERT INTO auth.users (id, email, instance_id, aud, role, raw_user_meta_data)
  VALUES (_treti, 'treti@test.local', '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          jsonb_build_object('full_name','Třetí Žadatel','subject_id',_klub::text));
  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _treti AND status = 'ceka';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, %L)', _z, 'rep'),
    'jmenovat jen správce haly', 'zástupce nevyrobí dalšího zástupce (obešel by admina)');
  EXECUTE 'RESET ROLE';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
