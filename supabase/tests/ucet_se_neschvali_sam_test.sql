-- =============================================================================
-- TESTY: účet se nesmí schválit sám (tři nálezy z auditu rolí)
-- Migrace 20260901090000_ucet_se_neschvali_sam.sql
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/ucet_se_neschvali_sam_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ:
-- Nejcennější tvrzení je hned první: účet ve stavu `ceka` NESMÍ přepsat vlastní
-- `stav`. Dokud to šlo, bylo schválení adminem doporučení, ne podmínka — a celá
-- brána `ucet_aktivni()` stála na sloupci, který si žadatel měnil sám.
--
-- Všechno běží pod `SET LOCAL ROLE authenticated` (pravidlo 8). Jako postgres
-- projde zápis vždycky, protože vlastník tabulky obchází granty i RLS — tenhle
-- test by pak tvrdil zavřeno o dveřích, které nikdo nezkusil.
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

-- Čerstvá registrace se žádostí o klub.
DO $$
DECLARE _novy uuid := '99999999-9999-9999-9999-999999999991'; _klub uuid;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  INSERT INTO auth.users (id, email, instance_id, aud, role, raw_user_meta_data)
  VALUES (_novy, 'sameschvaleni@test.local', '00000000-0000-0000-0000-000000000000',
          'authenticated', 'authenticated',
          jsonb_build_object('full_name','Sám Sebe','subject_id',_klub::text));
  INSERT INTO _s VALUES ('novy', _novy::text), ('klub', _klub::text);
  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _novy) = 'ceka',
    'příprava: účet je ve stavu „ceka"');
END $$;

-- -----------------------------------------------------------------------------
-- 1) NÁLEZ 1 — vlastní `stav` si účet nepřepíše
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.tvrd(current_user = 'authenticated',
    'test práv běží jako authenticated, ne jako postgres');

  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.profiles SET stav = %L WHERE user_id = %L', 'aktivni', _novy),
    'permission denied',
    'ČEKAJÍCÍ ÚČET SI STAV NEPŘEPÍŠE (jádro nálezu — dřív to prošlo jako HTTP 204)');

  -- Ani oklikou přes jiný stav.
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.profiles SET stav = %L WHERE user_id = %L', 'zamitnut', _novy),
    'permission denied', '… ani na žádnou jinou hodnotu');

  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _novy) = 'ceka',
    '… a v databázi pořád stojí „ceka"');
END $$;

-- Formulář profilu ale fungovat MUSÍ — jinak by oprava rozbila běžnou práci.
DO $$
DECLARE _novy uuid; _jmeno text;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  UPDATE public.profiles SET full_name = 'Nové Jméno', phone = '+420777123456',
                             bank_account = '123456789/0800'
   WHERE user_id = _novy;

  EXECUTE 'RESET ROLE';
  SELECT full_name INTO _jmeno FROM public.profiles WHERE user_id = _novy;
  PERFORM pg_temp.tvrd(_jmeno = 'Nové Jméno',
    'jméno, telefon a číslo účtu si uživatel uložit SMÍ (formulář profilu žije)');
END $$;

-- A schvalování přes RPC (SECURITY DEFINER) musí fungovat dál.
DO $$
DECLARE _novy uuid; _z uuid;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _novy AND status = 'ceka';

  PERFORM set_config('request.jwt.claims',
    '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.approve_subject_request(_z, 'member');
  EXECUTE 'RESET ROLE';

  PERFORM pg_temp.tvrd((SELECT stav FROM public.profiles WHERE user_id = _novy) = 'aktivni',
    'zástupce klubu účet schválit POŘÁD MŮŽE (RPC je SECURITY DEFINER, grant nepotřebuje)');
END $$;

-- A deaktivovaný účet se nevrátí sám.
DO $$
DECLARE _novy uuid;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  UPDATE public.profiles SET stav = 'deaktivovan' WHERE user_id = _novy;

  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM pg_temp.ocekavej_chybu(
    format('UPDATE public.profiles SET stav = %L WHERE user_id = %L', 'aktivni', _novy),
    'permission denied', 'DEAKTIVOVANÝ ÚČET SE SÁM NEVRÁTÍ');
  EXECUTE 'RESET ROLE';

  UPDATE public.profiles SET stav = 'aktivni' WHERE user_id = _novy;
END $$;

-- -----------------------------------------------------------------------------
-- 2) NÁLEZ 2 — role vidí až vpuštěný účet
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid; _n bigint;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  UPDATE public.profiles SET stav = 'ceka' WHERE user_id = _novy;

  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  -- Vlastní řádek vidět SMÍ (AuthContext si po přihlášení tahá svoje role);
  -- zakázané jsou CIZÍ — dřív si čekající účet vyjel i UUID adminů.
  SELECT count(*) INTO _n FROM public.user_roles WHERE user_id <> _novy;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n = 0,
    'čekající účet nevidí ŽÁDNOU cizí roli (dřív si vyjel i UUID adminů)');

  UPDATE public.profiles SET stav = 'aktivni' WHERE user_id = _novy;
  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n FROM public.user_roles WHERE user_id <> _novy;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n > 0, '… po schválení už vidí i role ostatních (aplikace je potřebuje)');
END $$;

-- -----------------------------------------------------------------------------
-- 3) NÁLEZ 3 — tabulka settings je zavřená stejně jako pohled nad ní
-- -----------------------------------------------------------------------------
DO $$
DECLARE _novy uuid; _n bigint;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _s WHERE klic = 'novy';
  UPDATE public.profiles SET stav = 'ceka' WHERE user_id = _novy;

  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n FROM public.settings;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n = 0,
    'čekající účet nevytáhne z tabulky settings ani otevírací dobu');

  UPDATE public.profiles SET stav = 'aktivni' WHERE user_id = _novy;
  PERFORM set_config('request.jwt.claims',
    format('{"sub":"%s","role":"authenticated"}', _novy), true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO _n FROM public.settings_public;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.tvrd(_n = 1, '… vpuštěný účet otevírací dobu z pohledu vidí');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
