-- =============================================================================
-- TESTY FAKTURAČNÍHO NASTAVENÍ (lokální Supabase)
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/billing_settings_test.sql
--
-- PROČ TENHLE SOUBOR EXISTUJE (A3):
-- `billing_settings` drží IBAN, IČO dodavatele a režim DPH. Je to nejcitlivější
-- tabulka celé Etapy 2 a jediná ochrana je RLS — žádné maskování pohledem tu není,
-- protože ne-admin z ní nepotřebuje vůbec nic.
--
-- POZOR NA POUČENÍ Z A2b: tvrzení o právech se MUSÍ testovat pod skutečnou rolí
-- `authenticated`. Jako `postgres` projde všechno, protože obchází granty i RLS —
-- právě proto předchozí verze testu u A2b propustila blokér.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- Pojistka: jen lokální seed databáze (tenhle test zapisuje).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '11111111-1111-1111-1111-111111111111')
     OR EXISTS (SELECT 1 FROM auth.users WHERE email IS NULL OR email NOT LIKE '%@test.local') THEN
    RAISE EXCEPTION 'ODMÍTNUTO: tohle není lokální seed databáze. Test patří jen na lokální Docker Postgres.';
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

-- -----------------------------------------------------------------------------
-- 1) Defaulty podle zadání PM
--
-- Čte se DEFAULT SLOUPCE z katalogu, ne hodnota v řádku. Řádek je totiž určený
-- k tomu, aby ho admin změnil — jakmile v A4 poprvé klikne na Uložit, tvrzení
-- „údaje jsou prázdné" přestane platit natrvalo a test by zčervenal navždy.
-- Červený test, který „to tak má", je horší než žádný: odnaučí lidi reagovat.
-- Default sloupce je naopak invariant schématu a drží i po vyplnění údajů.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.default_sloupce(_sloupec text) RETURNS text
 LANGUAGE sql STABLE AS $$
  SELECT column_default FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'billing_settings' AND column_name = _sloupec;
$$;

DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.billing_settings;
  PERFORM pg_temp.tvrd(_radku = 1, 'existuje právě jeden řádek');

  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('vat_mode') LIKE '''neplatce''%',      'default DPH: neplátce');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('due_days') = '14',                    'default splatnost 14 dní');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('number_format') LIKE '''RRRRNNNN''%', 'default číslo faktury RRRRNNNN');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('separate_series') = 'false',          'default jedna společná řada');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('file_prefix') LIKE '''curling''%',    'default prefix souborů curling');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('monthly_run_day') = '1',              'default měsíční běh 1. den');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('monthly_run_hour') = '6',             'default měsíční běh v 06:00');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('daily_run_hour') = '6',               'default denní běh v 06:00');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('automation_enabled') = 'false',       'default automatika vypnutá');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('auto_issue') = 'false',               'default auto_issue vypnuté (režim náběhu)');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('invoice_only_approved') = 'true',     'default: fakturují se jen schválené rezervace (Q4)');

  -- SAZBA DPH ZA LED JE NA DVOU MÍSTECH a musí zůstat táž.
  --
  -- Tady, protože „Kdo kolik dluží" je stránka v `src/`, a ta si `billing/`
  -- (kde je `SAZBA_DPH_LED`) importovat NESMÍ — hlídá to `hranice.test.ts`.
  -- Sazbu pro dopočet dluhu tedy musí dodat databáze.
  --
  -- Je to přesně ta situace, na kterou v tomhle repu doplatily `iban_je_platny`
  -- a `overIban`: dvě implementace téhož pravidla, které se tiše rozešly.
  -- Proto obě strany přišpendlené na TOTÉŽ ČÍSLO — druhá polovina je
  -- `expect(SAZBA_DPH_LED).toBe(12)` v `billing/mapping.test.ts`.
  -- Změnit jedno bez druhého nejde tiše: jeden z těch dvou testů zčervená.
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('vat_rate_ice') = '12',
    'default sazba DPH za led je 12 % (musí sedět se SAZBA_DPH_LED v billing/mapping.ts)');

  -- Údaje od klienta nesmí mít default — nemá je kdo vymyslet.
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('supplier_ico') IS NULL, 'IČO dodavatele nemá default');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('bank_iban') IS NULL,    'IBAN nemá default');
  PERFORM pg_temp.tvrd(pg_temp.default_sloupce('supplier_name') IS NULL,'název dodavatele nemá default');
END $$;

-- Zbytek testu pracuje s řádkem, tak ho uvedeme do známého stavu. Celý soubor
-- končí ROLLBACKem, takže to nic nestojí — a test tím přestane záviset na tom,
-- co si kdo předtím naklikal.
UPDATE public.billing_settings SET
  supplier_name = NULL, supplier_legal_form = NULL, supplier_address = NULL,
  supplier_ico = NULL, supplier_dic = NULL, supplier_registry = NULL,
  bank_account = NULL, bank_iban = NULL, bank_bic = NULL, payment_message = NULL;

-- Druhý řádek nesmí vzniknout — jinak by „nastavení haly" bylo dvojí.
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    'INSERT INTO public.billing_settings (singleton) VALUES (true)',
    'billing_settings_singleton_key', 'druhý řádek je odmítnut (singleton)');
END $$;

-- -----------------------------------------------------------------------------
-- 2) CHECKy na hodnoty
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.billing_settings SET due_days = -1',
    'billing_settings_due_days', 'záporná splatnost odmítnuta');

  -- Den 31 i 0 („poslední den v měsíci") projít MUSÍ — klientova původní varianta
  -- nesmí být zavřená, ořez na kratší měsíce dělá běh v D2.
  UPDATE public.billing_settings SET monthly_run_day = 0;
  PERFORM pg_temp.tvrd((SELECT monthly_run_day FROM public.billing_settings) = 0,
    '0 = poslední den v měsíci projde (klientova varianta zůstala vyjádřitelná)');
  UPDATE public.billing_settings SET monthly_run_day = 31;
  PERFORM pg_temp.tvrd((SELECT monthly_run_day FROM public.billing_settings) = 31,
    'den 31 projde (ořez na kratší měsíce patří do běhu, ne do CHECKu)');
  UPDATE public.billing_settings SET monthly_run_day = 1;

  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.billing_settings SET monthly_run_day = 32',
    'billing_settings_monthly_day', 'den 32 odmítnut');

  -- Řada a formát čísla jsou 1:1. Rozpor by dal dvěma fakturám totéž číslo.
  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.billing_settings SET separate_series = true',
    'billing_settings_series_format', 'oddělené řady bez odpovídajícího formátu odmítnuty');
  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET number_format = 'RRRRSNNN'$q$,
    'billing_settings_series_format', 'formát s číslicí řady bez oddělených řad odmítnut');

  UPDATE public.billing_settings SET separate_series = true, number_format = 'RRRRSNNN';
  PERFORM pg_temp.tvrd((SELECT separate_series FROM public.billing_settings),
    'oddělené řady SPOLU s odpovídajícím formátem projdou');
  UPDATE public.billing_settings SET separate_series = false, number_format = 'RRRRNNNN';

  PERFORM pg_temp.ocekavej_chybu(
    'UPDATE public.billing_settings SET monthly_run_hour = 24',
    'billing_settings_monthly_hour', 'hodina 24 odmítnuta');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET file_prefix = '../../etc'$q$,
    'billing_settings_file_prefix', 'prefix s cestou odmítnut');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET number_format = 'cokoliv'$q$,
    'billing_settings_number_format', 'neznámý formát čísla odmítnut');

  -- A co projít MÁ
  UPDATE public.billing_settings SET due_days = 0;
  PERFORM pg_temp.tvrd((SELECT due_days FROM public.billing_settings) = 0,
    'splatnost 0 projde („splatné ihned" je legitimní)');
  UPDATE public.billing_settings SET due_days = 14;

  UPDATE public.billing_settings SET vat_mode = 'identifikovana_osoba';
  PERFORM pg_temp.tvrd((SELECT vat_mode FROM public.billing_settings) = 'identifikovana_osoba',
    'režim identifikovaná osoba existuje (má DIČ, ale fakturuje bez DPH)');
  UPDATE public.billing_settings SET vat_mode = 'neplatce';
END $$;

-- -----------------------------------------------------------------------------
-- 3) PŘÍSTUP pod skutečnou rolí `authenticated`
--    Tohle je ta část, kvůli které soubor existuje.
-- -----------------------------------------------------------------------------
DO $$ BEGIN RAISE NOTICE '--- pod rolí authenticated ---'; END $$;

-- 3a) Admin: čte i mění
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.billing_settings;
  PERFORM pg_temp.tvrd(_radku = 1, 'admin: nastavení vidí');

  UPDATE public.billing_settings SET supplier_ico = '12345678', bank_iban = 'CZ6508000000192000145399';
  PERFORM pg_temp.tvrd(
    (SELECT supplier_ico FROM public.billing_settings) = '12345678',
    'admin: nastavení uloží');
END $$;

-- 3b) Člen: nevidí NIC a nezmění NIC
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _radku int; _ico text;
BEGIN
  SELECT count(*) INTO _radku FROM public.billing_settings;
  PERFORM pg_temp.tvrd(_radku = 0,
    format('člen: nevidí ani řádek (IBAN a IČO dodavatele mu nepřísluší), vrátil %s', _radku));

  UPDATE public.billing_settings SET supplier_ico = '99999999';

  RESET ROLE;
  SELECT supplier_ico INTO _ico FROM public.billing_settings;
  SET LOCAL ROLE authenticated;

  PERFORM pg_temp.tvrd(_ico = '12345678',
    format('člen: IČO nepřepsal (v DB zůstalo %s)', _ico));
END $$;

-- 3c) Instruktor: personál haly, ale ne admin — taky nic
SET LOCAL request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.billing_settings;
  PERFORM pg_temp.tvrd(_radku = 0, 'instruktor: nevidí nic, i když je to personál haly');
END $$;

-- 3c2) Anon: nesmí na tabulku vůbec
--      Hlídá to sice i kontrolní blok v migraci, ale ten běží jednou při nasazení.
--      Regresi (`GRANT SELECT … TO anon` v budoucí migraci) chytí až tenhle test.
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
DECLARE _spadlo boolean := false;
BEGIN
  BEGIN
    PERFORM 1 FROM public.billing_settings;
  EXCEPTION WHEN insufficient_privilege THEN
    _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo, 'anon: na billing_settings nedosáhne vůbec');
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;

-- 3d) Nikdo nesmí zakládat ani mazat.
--     Zastaví se to už na GRANTECH (`authenticated` má jen SELECT a UPDATE),
--     tedy o vrstvu dřív než na RLS — a to je silnější, ne slabší: politika se
--     dá omylem přidat, chybějící grant je tvrdší hranice.
SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    'INSERT INTO public.billing_settings (singleton, supplier_ico) VALUES (true, ''1'')',
    'permission denied', 'ani admin nezaloží druhý řádek (chybí INSERT grant i politika)');

  PERFORM pg_temp.ocekavej_chybu(
    'DELETE FROM public.billing_settings',
    'permission denied', 'ani admin nemaže nastavení (chybí DELETE grant i politika)');
END $$;

-- 3e) Ani `service_role` nastavení nesmaže.
--     Ta role obchází granty i RLS (má BYPASSRLS) a budou ji používat fáze C a D,
--     takže „nemaže se" musí být invariant v triggeru, ne jen v právech.
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    'DELETE FROM public.billing_settings',
    'nemaže', 'ani service_role nastavení nesmaže (drží to trigger, ne granty)');
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;

RESET ROLE;

-- -----------------------------------------------------------------------------
-- 4) Audit: změna fakturačních údajů musí být dohledatelná
--    Požadavek klienta zní „musí být vidět, kdo co zadával". U bankovního účtu
--    to platí dvojnásob — je to pole, jehož změna přesměruje peníze.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _zaznamu int; _kdo uuid; _stary jsonb; _novy jsonb;
BEGIN
  SELECT count(*) INTO _zaznamu FROM public.audit_log WHERE table_name = 'billing_settings';
  PERFORM pg_temp.tvrd(_zaznamu > 0,
    format('změny se zapisují do audit_log (%s záznamů)', _zaznamu));

  SELECT changed_by, old_data, new_data INTO _kdo, _stary, _novy
    FROM public.audit_log
   WHERE table_name = 'billing_settings' AND action = 'update'
     AND new_data->>'bank_iban' IS NOT NULL
   ORDER BY changed_at DESC LIMIT 1;

  PERFORM pg_temp.tvrd(_kdo = '11111111-1111-1111-1111-111111111111',
    'audit ví, KDO bankovní účet změnil');
  PERFORM pg_temp.tvrd(_novy->>'bank_iban' = 'CZ6508000000192000145399',
    'audit ví, NA CO se změnil');
  -- `_stary->>'bank_iban' IS NULL` by splnil i prázdný objekt nebo chybějící
  -- old_data. Musí se ověřit, že klíč EXISTUJE a je prázdný — tedy že audit
  -- opravdu zaznamenal „předtím tam nebylo nic", ne že o poli neví.
  PERFORM pg_temp.tvrd(_stary ? 'bank_iban' AND _stary->>'bank_iban' IS NULL,
    'audit ví, co tam bylo předtím (klíč existuje a byl prázdný)');
END $$;

-- -----------------------------------------------------------------------------
-- 4b) `audit_log` drží KOPIE fakturačních údajů — musí být zavřený stejně
--
-- Auditní záznam obsahuje celý řádek, tedy i IBAN. Kdo se dostane k auditu,
-- dostane se k bankovnímu spojení, i kdyby na `billing_settings` nedosáhl.
-- Test hlídá obě vrstvy: politiku (kdo čte) i granty (na TRUNCATE se RLS nevztahuje).
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.audit_log WHERE table_name = 'billing_settings';
  PERFORM pg_temp.tvrd(_radku = 0,
    format('člen: auditní záznamy o fakturaci nevidí (vrátil %s)', _radku));
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _radku int;
BEGIN
  SELECT count(*) INTO _radku FROM public.audit_log WHERE table_name = 'billing_settings';
  PERFORM pg_temp.tvrd(_radku > 0, format('admin: auditní záznamy vidí (%s)', _radku));

  PERFORM pg_temp.ocekavej_chybu('TRUNCATE public.audit_log',
    'permission denied', 'ani admin nesmí TRUNCATE audit_log (RLS na něj neplatí)');
END $$;

RESET ROLE;
SET LOCAL ROLE anon;
DO $$
DECLARE _spadlo boolean := false;
BEGIN
  BEGIN
    PERFORM 1 FROM public.audit_log;
  EXCEPTION WHEN insufficient_privilege THEN
    _spadlo := true;
  END;
  PERFORM pg_temp.tvrd(_spadlo, 'anon: na audit_log nedosáhne vůbec');
END $$;
RESET ROLE;

-- Nikdo nesmí tabulku vyprázdnit ani přes TRUNCATE, který obchází DELETE trigger.
SET LOCAL ROLE service_role;
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu('TRUNCATE public.billing_settings',
    'nemaže', 'ani service_role nastavení nevyprázdní (TRUNCATE má vlastní guard)');
END $$;
RESET ROLE;

-- -----------------------------------------------------------------------------
-- 5) Fakturační údaje NEJSOU v public.settings (rozhodnutí R9)
--
-- WHITELIST, ne regex. Regex („obsahuje iban|ico|bank|…") mine většinu polí,
-- která by sem propašovat šla — `payment_message`, `due_days`, `number_format`,
-- `tax_id`, `billing_account`. A hlavně projde naprázdno, když tabulka
-- `settings` vůbec neexistuje: `string_agg` nad prázdnou množinou vrátí NULL.
-- Whitelist obojí řeší: cokoli nového v `settings` test shodí a vyžádá si
-- vědomé rozhodnutí, kam to patří.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _ocekavane text[] := ARRAY['id', 'singleton', 'club_default_rate', 'commercial_default_rate',
                             'opening_hours', 'updated_by', 'updated_at', 'training_rate',
                             'tournament_rate', 'email_notifications_enabled'];
  _skutecne text[];
  _navic    text[];
BEGIN
  PERFORM pg_temp.tvrd(
    EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'settings'),
    'public.settings existuje (jinak by test prošel naprázdno)');

  SELECT COALESCE(array_agg(column_name ORDER BY column_name), ARRAY[]::text[]) INTO _skutecne
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'settings';

  SELECT COALESCE(array_agg(c ORDER BY c), ARRAY[]::text[]) INTO _navic
    FROM unnest(_skutecne) c WHERE c <> ALL (_ocekavane);

  PERFORM pg_temp.tvrd(array_length(_navic, 1) IS NULL,
    format('v public.settings nepřibyl žádný sloupec (nové: %s)', array_to_string(_navic, ', ')));
END $$;

-- -----------------------------------------------------------------------------
-- 6) CHECKy na peněžní pole (A4) — databáze je poslední slovo, ne formulář
--
-- Všechny kontroly IBANu (mod-97, křížová kontrola s číslem účtu, potvrzení
-- adminem) žijí ve formuláři. Fáze C a D ale poběží pod `service_role`, která
-- formulářem neprojde a RLS i granty obchází — pro ni je tohle jediná obrana.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET bank_iban = 'CZ9999999999999999999999'$q$,
    'billing_settings_bank_iban', 'IBAN s nesedícími kontrolními číslicemi odmítnut');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET bank_iban = 'CZ340800000019200014539'$q$,
    'billing_settings_bank_iban', '23znakový IBAN odmítnut (samotné mod-97 by ho pustilo)');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET bank_account = '1/9999'$q$,
    'billing_settings_bank_account', 'číslo účtu mimo český tvar odmítnuto');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET bank_account = 'asdf'$q$,
    'billing_settings_bank_account', 'nesmyslné číslo účtu odmítnuto');

  PERFORM pg_temp.ocekavej_chybu(
    $q$UPDATE public.billing_settings SET supplier_ico = '123'$q$,
    'billing_settings_supplier_ico', 'IČO s jiným než osmi číslicemi odmítnuto');

  -- A co projít MÁ
  UPDATE public.billing_settings SET bank_iban = 'CZ6508000000192000145399',
                                     bank_account = '19-2000145399/0800',
                                     supplier_ico = '27074358';
  PERFORM pg_temp.tvrd(
    (SELECT bank_iban FROM public.billing_settings) = 'CZ6508000000192000145399',
    'platný IBAN, číslo účtu i IČO projdou');
END $$;

-- -----------------------------------------------------------------------------
-- 6b) SQL a JS musí dávat TOTÉŽ
--
-- `public.iban_je_platny` a `overIban` v src/lib/iban.ts jsou dvě implementace
-- téhož pravidla. Kdyby se rozešly, formulář by pustil IBAN, který databáze
-- odmítne (nebo hůř: naopak). Hodnoty níž jsou schválně tytéž jako v iban.test.ts.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r record;
BEGIN
  FOR _r IN
    SELECT * FROM (VALUES
      ('CZ6508000000192000145399', true,  'referenční český IBAN'),
      ('CZ65 0800 0000 1920 0014 5399', true, 'IBAN s mezerami'),
      ('CZ0308000000355609555113', true,  'IBAN s vedoucí nulou v kontrolních číslicích'),
      ('GB82WEST12345698765432',   true,  'britský vzorový IBAN'),
      ('DE89370400440532013000',   true,  'německý vzorový IBAN'),
      ('CZ6508000000192000145398', false, 'český IBAN s překlepem'),
      ('CZ340800000019200014539',  false, '23 znaků'),
      ('CZ41080000001920001453997', false, '25 znaků'),
      ('CZ72ABCDEFGHIJ0800000019', false, 'písmena v českém BBANu'),
      ('CZ790',                    false, 'příliš krátké'),
      ('GB82WEST12345698765433',   false, 'britský IBAN s překlepem')
    ) AS t(iban, ocekavano, popis)
  LOOP
    PERFORM pg_temp.tvrd(
      public.iban_je_platny(_r.iban) = _r.ocekavano,
      format('iban_je_platny: %s → %s', _r.popis, _r.ocekavano));
  END LOOP;

  PERFORM pg_temp.tvrd(public.iban_je_platny(NULL), 'prázdný IBAN projde (pole je nepovinné)');
END $$;

-- -----------------------------------------------------------------------------
-- 6c) ZNÁMÝ ROZDÍL SQL vs JS — cizí IBAN se správným součtem, ale špatnou délkou
--
-- Nadpis 6b říká „musí dávat TOTÉŽ", jenže mezi jeho případy žádný takový nebyl,
-- takže to tvrzení nic nehlídalo. Rozdíl je skutečný a vypadá takhle:
--
--   SK401200000019874263   SQL = true    overIban (JS) = false
--   DE863704004405320130   SQL = true    overIban (JS) = false
--
-- Mod-97 sedí, ale délka pro danou zemi ne. `overIban` má tabulku délek
-- (`DELKY_IBANU` v src/lib/iban.ts), `iban_je_platny` ji nemá.
--
-- CO TO ZNAMENÁ V PROVOZU: databáze takový IBAN uloží a frontend ho pak odmítne
-- použít pro QR platbu. Není to tichý rozpor — doklad od 14. 8. 2026 napíše,
-- že QR nevzniklo a proč. Halu to potká jen u zahraničního účtu, proto se to
-- neřeší migrací hned; až se bude, patří to do NOVÉ migrace, ne do přepsání
-- 20260812180000.
--
-- Test rozdíl PŘIŠPENDLÍ, aby se nezměnil nepozorovaně ani jedním směrem.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.tvrd(public.iban_je_platny('SK401200000019874263'),
    'SQL zatím pouští cizí IBAN se správným součtem a špatnou délkou (JS ne)');
  PERFORM pg_temp.tvrd(public.iban_je_platny('DE863704004405320130'),
    'totéž pro německý tvar — rozdíl je v tabulce délek, ne v mod-97');
  PERFORM pg_temp.tvrd(NOT public.iban_je_platny('CZ340800000019200014539'),
    'u ČESKÝCH IBANů je délka ohlídaná na obou stranách');
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
