-- =============================================================================
-- TESTY ŽÁDOSTÍ O PŘIŘAZENÍ KE KLUBU
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/zadosti_o_klub_test.sql
--
-- CO TENHLE SOUBOR HLÍDÁ PŘEDEVŠÍM:
-- Členství v klubu je OPRÁVNĚNÍ, ne údaj o uživateli — člen vidí rezervace celého
-- klubu a smí za něj rezervovat, zástupce navíc potvrzuje rezervace ostatních.
-- Celá tahle změna proto stojí na jediné větě: **výběrem klubu při registraci
-- členství NEVZNIKÁ**. Kdyby vzniklo, stačilo by se zaregistrovat a vybrat si
-- cizí klub.
--
-- POUČENÍ Z A2b: tvrzení o právech se testují pod SKUTEČNOU rolí `authenticated`.
-- Jako `postgres` projde všechno.
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

CREATE TEMP TABLE _stav (klic text PRIMARY KEY, hodnota text);
GRANT ALL ON _stav TO authenticated;

-- Nový uživatel se zaregistruje a v metadatech si nese vybraný klub.
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
-- 1) JÁDRO: registrace s vybraným klubem vytvoří ŽÁDOST, ne členství
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _novy uuid; _z record;
BEGIN
  SELECT id INTO _klub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  _novy := pg_temp.registruj('zadatel@test.local', 'Nový Žadatel', _klub::text);
  INSERT INTO _stav VALUES ('novy', _novy::text), ('klub', _klub::text);

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps WHERE user_id = _novy) = 0,
    'ČLENSTVÍ NEVZNIKLO — jinak by stačilo zaregistrovat se a vybrat si cizí klub');

  SELECT * INTO _z FROM public.subject_requests WHERE user_id = _novy;
  PERFORM pg_temp.tvrd(_z.id IS NOT NULL, 'vznikla žádost');
  PERFORM pg_temp.tvrd(_z.status = 'ceka', 'a čeká na vyřízení');
  PERFORM pg_temp.tvrd(_z.subject_id = _klub, 'u klubu, který si vybral');
  PERFORM pg_temp.tvrd(_z.decided_at IS NULL AND _z.decided_by IS NULL,
    'bez razítka o rozhodnutí');

  -- Profil vzniká jako dřív, ROLE UŽ NE (blok C, R4). Dokud účet nikdo
  -- neschválí, nemá roli ani přístup — tohle je ta hlavní změna životního cyklu.
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.profiles WHERE user_id = _novy) = 1,
    'registrace pořád zakládá profil');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.user_roles WHERE user_id = _novy) = 0,
    'ale ŽÁDNOU roli — účet po registraci čeká na schválení (R4)');
  PERFORM pg_temp.tvrd(
    (SELECT stav FROM public.profiles WHERE user_id = _novy) = 'ceka',
    'a profil je ve stavu „ceka"');
  PERFORM pg_temp.tvrd(NOT public.ucet_aktivni(_novy),
    '… takže ho default-deny brána nikam nepustí (R6)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Nesmysl v metadatech NESMÍ shodit registraci
--
-- Kdo se překlepne, má dostat účet bez žádosti — ne hlášku „registrace selhala".
-- -----------------------------------------------------------------------------
DO $$
DECLARE _a uuid; _b uuid; _c uuid;
BEGIN
  _a := pg_temp.registruj('nesmysl@test.local', 'Nesmysl', 'tohle-není-uuid');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.profiles WHERE user_id = _a) = 1,
    'neplatné uuid klubu registraci nezastaví');
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.subject_requests WHERE user_id = _a) = 0,
    'a žádost z něj nevznikne');

  _b := pg_temp.registruj('neznamy@test.local', 'Neznámý klub', gen_random_uuid()::text);
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.subject_requests WHERE user_id = _b) = 0,
    'neexistující klub žádost nevytvoří');

  -- Komerční subjekt není klub — registrovat se k němu nejde.
  _c := pg_temp.registruj('firma@test.local', 'Firemní pokus',
        (SELECT id::text FROM public.subjects WHERE type = 'commercial' AND deleted_at IS NULL LIMIT 1));
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.subject_requests WHERE user_id = _c) = 0,
    'ke komerčnímu subjektu se přiřadit nedá');

  _c := pg_temp.registruj('bezklubu@test.local', 'Bez klubu', NULL);
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.profiles WHERE user_id = _c) = 1,
    'registrace bez vybraného klubu funguje jako dřív');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Zapsat si členství sám nejde ani přes REST
--
-- Pod SKUTEČNOU rolí: `authenticated` nesmí mít na `subject_requests` ani na
-- `subject_reps` zápis. Kdyby měl, obejde celé schvalování.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _klub uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _stav WHERE klic = 'klub';

  PERFORM pg_temp.ocekavej_chybu(format(
    'INSERT INTO public.subject_reps (subject_id, user_id, level) VALUES (%L, %L, ''rep'')',
    _klub, '55555555-5555-5555-5555-555555555555'),
    -- Tady brání RLS, ne granty: `subject_reps` má tabulkový GRANT z výchozích
    -- práv Supabase, ale politika pustí zápis jen adminovi. Výsledek je týž,
    -- hláška jiná — a test má tvrdit, že to NEPROJDE, ne kudy to spadne.
    'row-level security', 'člen si nezapíše členství (ani zástupcovství) přímo');

  PERFORM pg_temp.ocekavej_chybu(format(
    'INSERT INTO public.subject_requests (user_id, subject_id, status) VALUES (%L, %L, ''schvalena'')',
    '55555555-5555-5555-5555-555555555555', _klub),
    'permission denied', 'ani si nezaloží rovnou schválenou žádost');

  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.subject_requests SET status = ''schvalena''',
    'permission denied', 'ani si nepřepíše stav existující žádosti');
END $$;

-- Povýšení sebe sama na zástupce: RLS tady NEHÁZÍ CHYBU, jen tiše odfiltruje
-- řádky. Kdo testuje jen „spadlo to?", přečte si mlčení jako úspěch útoku —
-- nebo naopak jako obranu. Proto se tvrdí počet dotčených řádků, ne výjimka.
DO $$
DECLARE _n int;
BEGIN
  UPDATE public.subject_reps SET level = 'rep'
   WHERE user_id = '55555555-5555-5555-5555-555555555555';
  GET DIAGNOSTICS _n = ROW_COUNT;
  PERFORM pg_temp.tvrd(_n = 0, 'člen se sám na zástupce nepovýší (UPDATE nedotkne ani řádek)');
END $$;

-- Žádost si podat SMÍ — a jen jednu.
DO $$
DECLARE _klub uuid; _id uuid;
BEGIN
  SELECT hodnota::uuid INTO _klub FROM _stav WHERE klic = 'klub';
  -- clen2 (55555…) je členem CK Ostravské kameny už ze seedu → jiný klub.
  SELECT id INTO _klub FROM public.clubs_public WHERE name = 'TJ Poruba';

  _id := public.request_subject_membership(_klub, 'Chodím tam na tréninky.');
  PERFORM pg_temp.tvrd(_id IS NOT NULL, 'přihlášený si žádost podat může');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.request_subject_membership(%L)', _klub),
    'už čeká', 'druhá čekající žádost se odmítne (jinak jde fronta zahltit)');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.request_subject_membership(%L)', gen_random_uuid()),
    'neexistuje', 'žádost na neexistující klub se odmítne');
END $$;

-- Dlouhá poznámka: musí přijít ČESKÁ věta, ne `DETAIL: Failing row contains (…)`
-- s celým řádkem a jménem constraintu. Hláška z RPC jde v UI rovnou uživateli
-- (`useSubjectRequests`), takže tudy uniká vnitřní schéma na obrazovku.
DO $$
DECLARE _klub uuid; _det text;
BEGIN
  SELECT id INTO _klub FROM public.clubs_public WHERE name = 'TJ Poruba';
  BEGIN
    PERFORM public.request_subject_membership(_klub, repeat('A', 600));
    PERFORM pg_temp.tvrd(false, 'dlouhá poznámka měla skončit chybou');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS _det = PG_EXCEPTION_DETAIL;
    PERFORM pg_temp.tvrd(SQLERRM LIKE '%moc dlouhá%',
      'dlouhá poznámka vrátí českou větu, ne hlášku databáze');
    PERFORM pg_temp.tvrd(coalesce(_det, '') = '',
      'a klientovi neuteče DETAIL s obsahem řádku (R11)');
  END;
END $$;

-- Poslední obranu proti dvěma čekajícím žádostem drží unikátní index, ne ta
-- kontrola výš — ta je TOCTOU. Že index existuje a je PARTIAL (jinak by člověk
-- po zamítnutí nesměl požádat znovu) se tvrdí tady; že se z jeho porušení
-- vyklube česká věta a ne „duplicate key value…", ověřuje `zadosti_o_klub_zavod.sh`
-- — na to jsou potřeba dvě soubězná spojení, jedním se závod zahrát nedá.
-- Klub smazaný MEZI podáním a schválením. Kontrola při podání tady nepomůže,
-- protože ta proběhla dávno. (Vlastní test je v admin sekci níž — schvaluje
-- jedině admin, takže odsud, zpod běžného člena, se nedá zahrát.)
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_subject_requests_jedna_cekajici')
      = 'CREATE UNIQUE INDEX idx_subject_requests_jedna_cekajici ON public.subject_requests'
        || ' USING btree (user_id) WHERE (status = ''ceka''::subject_request_status)',
    'dvě čekající žádosti hlídá unikátní index, a jen ty čekající');
END $$;

-- Vyřizovat je nesmí.
DO $$
DECLARE _z uuid;
BEGIN
  SELECT hodnota::uuid INTO _z FROM _stav WHERE klic = 'zadost';
  SELECT id INTO _z FROM public.subject_requests WHERE status = 'ceka' LIMIT 1;
  -- Hláška se blokem C změnila (schvalovat smí i zástupce), tvrzení ne:
  -- ŘADOVÝ ČLEN nesmí ani schválit, ani zamítnout.
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, ''rep'')', _z),
    'správce haly nebo zástupce klubu', 'člen si žádost neschválí');
  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.reject_subject_request(%L)', _z),
    'správce haly nebo zástupce klubu', 'člen žádost nezamítne');
END $$;

-- A ve frontě vidí jen svoje.
DO $$
DECLARE _cizich int; _svoje int; _klub text;
BEGIN
  SELECT count(*) INTO _cizich FROM public.subject_requests_list
   WHERE user_id <> '55555555-5555-5555-5555-555555555555';
  PERFORM pg_temp.tvrd(_cizich = 0, 'člen vidí ve frontě jen svoje žádosti, ne cizí jména');

  -- Druhá půlka téhož tvrzení. Samotné „cizí = 0" projde i tehdy, když žadatel
  -- nevidí VŮBEC NIC — a přesně to se dělo: pohled spojoval `subjects`, kam
  -- čekající žadatel nesmí, takže si vlastní žádost nepřečetl. Slepota se od
  -- soukromí musí poznat, jinak test hlídá prázdno.
  SELECT count(*), max(klub) INTO _svoje, _klub FROM public.subject_requests_list
   WHERE user_id = '55555555-5555-5555-5555-555555555555';
  PERFORM pg_temp.tvrd(_svoje = 1, 'ale svoji žádost vidí (jinak by nezjistil, jak dopadla)');
  PERFORM pg_temp.tvrd(_klub = 'TJ Poruba', 'a je u ní název klubu, o který žádal');
END $$;
RESET ROLE;

-- Druhá půlka předchozího tvrzení, už bez RLS: úroveň se opravdu nezměnila.
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.subject_reps
                 WHERE user_id = '55555555-5555-5555-5555-555555555555' AND level = 'rep'),
    'a v datech po tom pokusu žádné zástupcovství nezůstalo');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Schválení: admin přiděluje ÚROVEŇ, žadatel o ní nerozhoduje
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _novy uuid; _klub uuid; _z uuid; _r jsonb;
BEGIN
  SELECT hodnota::uuid INTO _novy FROM _stav WHERE klic = 'novy';
  SELECT hodnota::uuid INTO _klub FROM _stav WHERE klic = 'klub';
  SELECT id INTO _z FROM public.subject_requests WHERE user_id = _novy;

  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_requests_list WHERE id = _z
      AND zadatel = 'Nový Žadatel' AND klub = 'CK Ostravské kameny') = 1,
    'admin vidí ve frontě jméno i zvolený klub');

  _r := public.approve_subject_request(_z, 'rep');
  PERFORM pg_temp.tvrd((_r ->> 'level') = 'rep', 'schválení vrátí přidělenou úroveň');

  PERFORM pg_temp.tvrd(
    (SELECT level FROM public.subject_reps WHERE user_id = _novy AND subject_id = _klub) = 'rep',
    'členství vzniklo v úrovni, kterou zvolil ADMIN (zástupce se nastavuje ručně)');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.subject_requests WHERE id = _z) = 'schvalena',
    'a žádost je vyřízená');
  PERFORM pg_temp.tvrd(
    (SELECT decided_by FROM public.subject_requests WHERE id = _z) = '11111111-1111-1111-1111-111111111111',
    'se stopou, KDO ji vyřídil');

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L)', _z),
    'už je vyřízená', 'dvakrát schválit nejde');
END $$;

-- Zamítnutí s důvodem.
DO $$
DECLARE _z uuid;
BEGIN
  SELECT id INTO _z FROM public.subject_requests WHERE status = 'ceka' LIMIT 1;
  PERFORM public.reject_subject_request(_z, 'Není v našem oddíle.');
  PERFORM pg_temp.tvrd(
    (SELECT status FROM public.subject_requests WHERE id = _z) = 'zamitnuta', 'zamítnutí projde');
  PERFORM pg_temp.tvrd(
    (SELECT decision_reason FROM public.subject_requests WHERE id = _z) = 'Není v našem oddíle.',
    'i s důvodem, ať se dá dohledat proč');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.subject_reps sr
      JOIN public.subject_requests z ON z.user_id = sr.user_id AND z.subject_id = sr.subject_id
     WHERE z.id = _z) = 0,
    'a členství ze zamítnuté žádosti NEVZNIKLO');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 4b) Klub smazaný MEZI podáním žádosti a jejím schválením
--
-- Kontrola při podání tady nepomůže — proběhla dávno. Bez druhé kontroly při
-- schválení vzniklo členství ve smazaném klubu: nikde není vidět (`subjects`
-- skryté kluby nepouští), ale opravňuje. Žádost se zakládá zpod `postgres`,
-- protože do `subject_requests` nesmí přímo zapsat ani admin — jen přes RPC.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _klub uuid; _z uuid; _u uuid := '33333333-3333-3333-3333-333333333333';
BEGIN
  SELECT id INTO _klub FROM public.clubs_public WHERE name = 'TJ Poruba';
  DELETE FROM public.subject_requests WHERE user_id = _u;
  INSERT INTO public.subject_requests (user_id, subject_id, status)
  VALUES (_u, _klub, 'ceka') RETURNING id INTO _z;
  UPDATE public.subjects SET deleted_at = now() WHERE id = _klub;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

  PERFORM pg_temp.ocekavej_chybu(
    format('SELECT public.approve_subject_request(%L, ''member'')', _z),
    'Klub už neexistuje', 'do smazaného klubu nejde nikoho přiřadit');

  RESET ROLE;
  PERFORM pg_temp.tvrd(
    NOT EXISTS (SELECT 1 FROM public.subject_reps WHERE user_id = _u AND subject_id = _klub),
    'a žádné členství po tom pokusu nezůstalo');

  UPDATE public.subjects SET deleted_at = NULL WHERE id = _klub;
END $$;

-- Zamítnutí: týž strop na délku jako u žadatele a týž R11 obal. Nesouměrné
-- pravidlo („žadateli 500 znaků, adminovi neomezeně") je jen čekání na to,
-- až se do `decision_reason` vleze něco, co nikdo nečeká.
DO $$
DECLARE _klub uuid; _z uuid; _u uuid := '22222222-2222-2222-2222-222222222222'; _det text;
BEGIN
  SELECT id INTO _klub FROM public.clubs_public WHERE name = 'TJ Poruba';
  DELETE FROM public.subject_requests WHERE user_id = _u;
  INSERT INTO public.subject_requests (user_id, subject_id, status)
  VALUES (_u, _klub, 'ceka') RETURNING id INTO _z;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  BEGIN
    PERFORM public.reject_subject_request(_z, repeat('B', 600));
    PERFORM pg_temp.tvrd(false, 'dlouhý důvod zamítnutí měl skončit chybou');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS _det = PG_EXCEPTION_DETAIL;
    PERFORM pg_temp.tvrd(SQLERRM LIKE '%moc dlouhý%', 'dlouhý důvod zamítnutí se odmítne česky');
    PERFORM pg_temp.tvrd(coalesce(_det, '') = '', 'a bez DETAILu (R11 i u zamítnutí)');
  END;
  RESET ROLE;
  DELETE FROM public.subject_requests WHERE id = _z;
END $$;

-- Obrana do hloubky: `subject_reps` je jediné úložiště klubových oprávnění,
-- takže nepřihlášený na něj nesmí mít vůbec nic. Dnes ho zastaví RLS, ale to je
-- jedna vrstva — a jediná budoucí politika `FOR ALL USING (true)` by z grantu
-- udělala zápis do tabulky členství.
DO $$
DECLARE _prava text;
BEGIN
  SELECT string_agg(privilege_type, ', ' ORDER BY privilege_type) INTO _prava
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'subject_reps' AND grantee = 'anon';
  PERFORM pg_temp.tvrd(_prava IS NULL,
    format('nepřihlášený nemá na subject_reps žádné právo (má: %s)', COALESCE(_prava, 'žádné')));
END $$;

-- -----------------------------------------------------------------------------
-- 5) Veřejné rozbalovátko klubů
--
-- Registrace je veřejná stránka, takže seznam musí přečíst i nepřihlášený.
-- Nesmí z něj ale vypadnout nic dalšího — `subjects` má IČO, adresy i sazby.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE anon;
DO $$
DECLARE _sloupce text;
BEGIN
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.clubs_public) > 0,
    'nepřihlášený návštěvník vidí seznam klubů (jinak by si klub nevybral)');

  SELECT string_agg(column_name, ',' ORDER BY column_name) INTO _sloupce
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'clubs_public';
  PERFORM pg_temp.tvrd(_sloupce = 'id,name', format('a JEN id a název (%s)', _sloupce));

  PERFORM pg_temp.ocekavej_chybu('SELECT ico FROM public.subjects LIMIT 1',
    'permission denied', 'na subjects samotné nepřihlášený nedosáhne');
  PERFORM pg_temp.ocekavej_chybu('SELECT * FROM public.subject_requests_list LIMIT 1',
    'permission denied', 'ani na frontu žádostí se jmény');
END $$;
RESET ROLE;

-- Komerční subjekty ve veřejném seznamu nemají co dělat.
DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.clubs_public c
      JOIN public.subjects s ON s.id = c.id WHERE s.type <> 'club') = 0,
    'veřejný seznam obsahuje jen kluby, ne firmy');
  PERFORM pg_temp.tvrd(
    (SELECT count(*) FROM public.clubs_public c
      JOIN public.subjects s ON s.id = c.id WHERE s.deleted_at IS NOT NULL) = 0,
    'a ne skryté kluby');
END $$;

ROLLBACK;
