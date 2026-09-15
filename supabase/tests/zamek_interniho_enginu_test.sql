-- =============================================================================
-- ZÁMEK INTERNÍHO FAKTURAČNÍHO ENGINU — testy k migraci 20260915100000
-- =============================================================================
--
-- Co se dokazuje:
--   A1–A5  všech pět vstupních bodů je ZAVŘENÝCH, a to V REŽIMU `neplatce` —
--          tedy přesně ve světě po migraci 20260915090000, kde starý guard
--          na `vat_mode` mlčí. Kdyby se testovalo pod `platce`, zčervenal by
--          test i bez nového zámku (odmítl by ho ten starý) a nedokázal by nic.
--   A6     zámek se nedá vypnout z aplikace (žádný UPDATE grant na sloupec)
--   A7     zapnutý přepínač engine OPRAVDU otevře — jinak by testy A1–A5
--          mohly měřit cokoli jiného, co ty funkce shodou okolností odmítá
--   A8     chybějící nastavení engine ZAVÍRÁ (fail-closed), neotevírá
--   A9     starý zámek na `vat_mode` zůstal nedotčený a je na tomhle nezávislý
--   A10    práva na samotnou funkci zámku
--
-- VŠECHNO POD REÁLNÝM TOKENEM ADMINA (`SET LOCAL ROLE authenticated` +
-- `request.jwt.claims`). Jako `postgres` je `has_role()` sice pořád false,
-- ale granty a RLS se obcházejí — a test A6 (že se přepínač nedá přepsat)
-- by jako `postgres` prošel vždycky a neměřil nic. CLAUDE.md, pravidlo 3 a 9.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF current_database() <> 'curling_test' THEN
    RAISE EXCEPTION 'ODMÍTNUTO: test ZAPISUJE, patří jen do repliky curling_test, běží nad "%".',
      current_database();
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE '  OK  %', _popis;
END $$;

-- Kulisy: reálný admin. Doklad ani subjekt se nevyrábí schválně — zámek stojí
-- PŘED vyhledáním dokladu, takže na neexistující id musí spadnout na zámku,
-- ne na „Faktura neexistuje". To je samo o sobě tvrzení, které testy A3–A5 měří.
CREATE TEMP TABLE t_kul AS
SELECT ur.user_id AS admin,
       '00000000-0000-0000-0000-0000000000ff'::uuid AS nic
  FROM public.user_roles ur WHERE ur.role = 'admin' ORDER BY ur.user_id LIMIT 1;

DO $$
DECLARE _k record;
BEGIN
  SELECT * INTO _k FROM t_kul;
  PERFORM pg_temp.tvrd(_k.admin IS NOT NULL, 'kulisa) je reálný admin, pod kterým se testuje');
END $$;

-- Svět po KROKU 4: neplátce. Starý guard na `vat_mode` tím mlčí a všechno,
-- co dál zčervená, jde na vrub NOVÉHO zámku.
UPDATE public.billing_settings SET vat_mode = 'neplatce' WHERE singleton;

DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    (SELECT vat_mode::text FROM public.billing_settings WHERE singleton) = 'neplatce',
    'kulisa) testuje se v režimu NEPLÁTCE — tedy tam, kde starý zámek už nedrží');
  PERFORM pg_temp.tvrd(
    (SELECT interni_engine_povolen FROM public.billing_settings WHERE singleton) = false,
    'kulisa) a přepínač enginu je ve výchozí poloze = zavřeno');
END $$;

-- Jedno volání pod tokenem admina, vrátí hlášku (NULL = prošlo bez chyby).
CREATE OR REPLACE FUNCTION pg_temp.zkus(_sql text, _admin uuid) RETURNS text
 LANGUAGE plpgsql AS $$
DECLARE _hlaska text;
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
    EXECUTE _sql;
  EXCEPTION WHEN OTHERS THEN
    _hlaska := SQLERRM;
  END;
  RESET ROLE;
  RETURN _hlaska;
END $$;

-- ===========================================================================
-- A1–A5) VŠECH PĚT VSTUPNÍCH BODŮ JE ZAVŘENÝCH I V REŽIMU NEPLÁTCE
-- ===========================================================================
SAVEPOINT a1;
DO $$
DECLARE
  _k record; _h text;
  _cesty text[][] := ARRAY[
    ARRAY['A1', 'create_invoice_draft_club',
          'SELECT public.create_invoice_draft_club($1, current_date - 30, current_date)'],
    ARRAY['A2', 'create_invoice_draft_commercial',
          'SELECT public.create_invoice_draft_commercial($1)'],
    ARRAY['A3', 'issue_invoice',
          'SELECT public.issue_invoice($1)'],
    ARRAY['A4', 'dobropis_invoice',
          'SELECT public.dobropis_invoice($1, ARRAY[$1], ''test'')'],
    ARRAY['A5', 'storno_invoice',
          'SELECT public.storno_invoice($1, ''test'')']
  ];
  _i integer;
BEGIN
  SELECT * INTO _k FROM t_kul;
  FOR _i IN 1 .. array_length(_cesty, 1) LOOP
    _h := pg_temp.zkus(
      replace(_cesty[_i][3], '$1', quote_literal(_k.nic) || '::uuid'), _k.admin);

    PERFORM pg_temp.tvrd(_h IS NOT NULL,
      _cesty[_i][1] || 'a) ' || _cesty[_i][2] || ' v režimu neplátce NEPROJDE');
    PERFORM pg_temp.tvrd(_h LIKE '%Interní fakturační engine je vyřazený%',
      _cesty[_i][1] || 'b) a spadne na ZÁMKU ENGINU, ne na něčem jiném (hláška: '
      || left(COALESCE(_h, '(žádná)'), 60) || ')');
    -- Zámek musí stát PŘED vyhledáním dokladu: na neexistující id se nesmí
    -- prozradit ani „doklad neexistuje" — a hlavně se nesmí nic zamknout.
    PERFORM pg_temp.tvrd(_h NOT LIKE '%neexistuje%',
      _cesty[_i][1] || 'c) zámek je PŘED vyhledáním dokladu, ne za ním');
  END LOOP;

  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.invoices) = 0,
    'A1–A5e) a nevznikl u toho ani jeden doklad');
END $$;
ROLLBACK TO a1;

-- ===========================================================================
-- A6) PŘEPÍNAČ SE NEDÁ PŘEHODIT Z APLIKACE
-- ===========================================================================
SAVEPOINT a6;
DO $$
DECLARE _k record; _h text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  _h := pg_temp.zkus(
    'UPDATE public.billing_settings SET interni_engine_povolen = true WHERE singleton',
    _k.admin);

  PERFORM pg_temp.tvrd(_h IS NOT NULL,
    'A6a) admin pod reálným tokenem přepínač NEPŘEPNE');
  PERFORM pg_temp.tvrd(_h ILIKE '%permission denied%' OR _h ILIKE '%odepřen%',
    'A6b) a je to odepřením práva na sloupec, ne náhodou (' || left(_h, 60) || ')');
  PERFORM pg_temp.tvrd(
    (SELECT interni_engine_povolen FROM public.billing_settings WHERE singleton) = false,
    'A6c) hodnota opravdu zůstala false');

  -- Kontrolní vzorek: `vat_mode` PŘEPNOUT JDE. Tím je vidět, že A6a není
  -- o tom, že by admin nemohl do `billing_settings` vůbec — a zároveň proč
  -- zámek na `vat_mode` viset nesmí: ten se z webu přehodí jedním kliknutím.
  _h := pg_temp.zkus(
    'UPDATE public.billing_settings SET vat_mode = ''platce'' WHERE singleton', _k.admin);
  PERFORM pg_temp.tvrd(_h IS NULL,
    'A6d) kontrolní vzorek: vat_mode tentýž admin přepnout SMÍ (proto na něm zámek viset nemůže)');

  -- A6e/f) REGRESE, KTERÁ BY BOLELA NEJVÍC: nový sloupec nesmí rozbít obrazovku
  -- Nastavení → Fakturace. Ta čte `select('*')` (potřebuje tedy SELECT i na nový
  -- sloupec) a ukládá výčet polí z `BillingSettingsUpdate` (nový sloupec v něm
  -- NENÍ, takže UPDATE projít musí). Obojí se tu zkouší tak, jak to dělá aplikace.
  _h := pg_temp.zkus('SELECT * FROM public.billing_settings', _k.admin);
  PERFORM pg_temp.tvrd(_h IS NULL,
    'A6e) `select(*)` nad nastavením adminovi pořád projde (jinak padne celá obrazovka Fakturace)');

  _h := pg_temp.zkus(
    'UPDATE public.billing_settings SET supplier_name = supplier_name, vat_mode = vat_mode, '
    'due_days = due_days, file_prefix = file_prefix, automation_enabled = automation_enabled, '
    'auto_issue = auto_issue, invoice_only_approved = invoice_only_approved WHERE singleton',
    _k.admin);
  PERFORM pg_temp.tvrd(_h IS NULL,
    'A6f) a uložení formuláře (výčet polí bez nového sloupce) taky projde');
END $$;
ROLLBACK TO a6;

-- ===========================================================================
-- A7) ZAPNUTÝ PŘEPÍNAČ ENGINE OPRAVDU OTEVŘE
--     Bez tohohle by A1–A5 mohly měřit jakékoli jiné odmítnutí.
-- ===========================================================================
SAVEPOINT a7;
DO $$
DECLARE _k record; _h text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  UPDATE public.billing_settings SET interni_engine_povolen = true WHERE singleton;

  _h := pg_temp.zkus(
    'SELECT public.issue_invoice(' || quote_literal(_k.nic) || '::uuid)', _k.admin);

  PERFORM pg_temp.tvrd(_h NOT LIKE '%Interní fakturační engine je vyřazený%',
    'A7a) se zapnutým přepínačem už zámek enginu nebrzdí');
  PERFORM pg_temp.tvrd(_h LIKE '%neexistuje%',
    'A7b) a funkce pokračuje dál normální cestou (' || left(COALESCE(_h,'(prošlo)'), 50) || ')');
END $$;
ROLLBACK TO a7;

-- ===========================================================================
-- A8) FAIL-CLOSED: BEZ NASTAVENÍ JE ZAVŘENO
-- ===========================================================================
SAVEPOINT a8;
-- Řádek nastavení normálně zmizet NEMŮŽE: `billing_settings_singleton` je CHECK
-- a `trg_billing_settings_no_delete` mazání brání. Tenhle test je proto pojistka
-- pro případ, že by ta ochrana někdy padla — trigger se kvůli němu na chvíli
-- vypne a savepoint ho vrátí. Bez toho by větev `NOT FOUND` v zámku nikdy
-- nikdo nezměřil a nikdo by nevěděl, jestli otevírá, nebo zavírá.
ALTER TABLE public.billing_settings DISABLE TRIGGER trg_billing_settings_no_delete;
DO $$
DECLARE _k record; _h text; _drzi boolean := false;
BEGIN
  SELECT * INTO _k FROM t_kul;
  DELETE FROM public.billing_settings WHERE singleton;
  PERFORM pg_temp.tvrd((SELECT count(*) FROM public.billing_settings) = 0,
    'A8-kulisa) nastavení je pryč — teď se měří, co zámek udělá bez něj');

  BEGIN
    PERFORM public.over_interni_engine();
  EXCEPTION WHEN OTHERS THEN
    _drzi := true; _h := SQLERRM;
  END;

  PERFORM pg_temp.tvrd(_drzi,
    'A8a) bez řádku nastavení zámek DRŽÍ (fail-closed), neotevírá');
  PERFORM pg_temp.tvrd(_h LIKE '%Interní fakturační engine je vyřazený%',
    'A8b) a je to tentýž zámek, ne pád na chybějícím řádku');
END $$;
ALTER TABLE public.billing_settings ENABLE TRIGGER trg_billing_settings_no_delete;
ROLLBACK TO a8;

-- A8c) A ještě jednou, tentokrát bez berličky: ochrana proti smazání opravdu drží.
DO $$
DECLARE _smazano boolean := false;
BEGIN
  BEGIN
    DELETE FROM public.billing_settings WHERE singleton;
    _smazano := true;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  PERFORM pg_temp.tvrd(NOT _smazano,
    'A8c) v běžném provozu řádek nastavení smazat nejde — větev z A8 je jen pojistka');
END $$;

-- ===========================================================================
-- A9) STARÝ ZÁMEK NA `vat_mode` ZŮSTAL A JE NA TOMHLE NEZÁVISLÝ
-- ===========================================================================
SAVEPOINT a9;
DO $$
DECLARE _k record; _h text;
BEGIN
  SELECT * INTO _k FROM t_kul;
  -- Engine povolený, ale režim plátce: musí zabrat ten DRUHÝ, starší zámek.
  UPDATE public.billing_settings
     SET interni_engine_povolen = true, vat_mode = 'platce' WHERE singleton;

  _h := pg_temp.zkus(
    'SELECT public.create_invoice_draft_commercial(' || quote_literal(_k.nic) || '::uuid)',
    _k.admin);

  PERFORM pg_temp.tvrd(_h IS NOT NULL,
    'A9a) s povoleným enginem, ale v režimu plátce se doklad pořád nezaloží');
  PERFORM pg_temp.tvrd(_h LIKE '%jen režim neplátce%',
    'A9b) a drží to STARÝ zámek na vat_mode, nedotčený (' || left(_h, 50) || ')');
END $$;
ROLLBACK TO a9;

-- ===========================================================================
-- A10) PRÁVA NA SAMOTNOU FUNKCI ZÁMKU
-- ===========================================================================
DO $$
DECLARE _acl text;
BEGIN
  SELECT COALESCE(array_to_string(proacl, ' '), '(default)') INTO _acl
    FROM pg_proc WHERE oid = to_regprocedure('public.over_interni_engine()');

  PERFORM pg_temp.tvrd(_acl <> '(default)',
    'A10a) funkce nemá výchozí ACL (to je EXECUTE pro PUBLIC)');
  -- PUBLIC se v ACL píše jako PRÁZDNÝ grantee, tedy položka začínající '='.
  -- Dřívější znění téhle věty bylo `NOT LIKE '%=X/%' OR NOT LIKE '% =X%'` —
  -- disjunkce dvou skoro vždy pravdivých podmínek, tedy zelená ať se stane
  -- cokoli. Regulární výraz měří to, co měřit má.
  PERFORM pg_temp.tvrd(_acl !~ '(^|\s)=',
    'A10b) PUBLIC na ní EXECUTE nemá (acl: ' || _acl || ')');
  PERFORM pg_temp.tvrd(_acl LIKE '%authenticated=X%',
    'A10c) authenticated na ni EXECUTE má (volá se zevnitř SECURITY DEFINER funkcí)');
  PERFORM pg_temp.tvrd(
    (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.over_interni_engine()')),
    'A10d) a je SECURITY DEFINER — čte nastavení, na které volající nemusí mít RLS');
END $$;

DO $$ BEGIN RAISE NOTICE 'VYSLEDEK: všechny testy zámku interního enginu PROŠLY'; END $$;

ROLLBACK;
