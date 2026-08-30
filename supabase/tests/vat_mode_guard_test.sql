-- =============================================================================
-- GUARD REŽIMU DPH — interní engine pod plátcem NEVYSTAVÍ
-- =============================================================================
-- Spuštění:
--   docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
--     < supabase/tests/vat_mode_guard_test.sql
--
-- PROČ VLASTNÍ SOUBOR:
-- Migrace `20260830140000_vat_mode_platce.sql` přepnula halu na plátce a tím
-- ZAVŘELA interní fakturační engine. To je celý její smysl — pod S2 vystavuje
-- ostré doklady Fakturoid.
--
-- Jenže všechny čtyři testy interního enginu (`fakturace_test`, `storno_test`,
-- `dobropis_test`, `pdf_fronta_test`) si na začátku nastaví `vat_mode='neplatce'`,
-- aby vůbec mohly testovat jeho logiku. Guard tedy jen OBCHÁZEJÍ a nikde nebylo
-- jediné tvrzení, že drží. Kdo by ho zítra uvolnil, nedozvěděl by se to.
--
-- Do `fakturace_test.sql` to nešlo přidat: ten si v jedné transakci postupně
-- vyfakturuje všechny rezervace, takže na konci už není z čeho udělat koncept
-- a tvrzení by se tiše přeskočilo. Vlastní transakce má vlastní data.
--
-- POUČENÍ Z CLAUDE.md, BOD 8: tvrzení o právech i o guardech se testuje pod
-- rolí `authenticated`. Jako `postgres` projde všechno.
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

-- Admin, jinak se koncept nedá ani založit.
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);

-- Fakturační údaje haly. Bez nich `issue_invoice` odmítne vystavit i pod
-- neplátcem — a to je JINÉ odmítnutí než to, které se tu testuje. Kontrolní
-- krok 4 níž by na něm spadl a hláška by mluvila o chybějícím IČO, ne o DPH.
UPDATE public.billing_settings
   SET supplier_name = 'TEST Curling Ostrava z.s.',
       supplier_address = 'Sportovní 12, 702 00 Ostrava',
       supplier_ico = '26512345',
       bank_account = '19-2000145399/0800'
 WHERE singleton;

DO $$
DECLARE
  _sub uuid; _koncept uuid; _spadlo boolean := false; _hlaska text; _rezim public.vat_mode;
BEGIN
  -- 1) Výchozí stav po migraci MUSÍ být plátce. Kdyby nebyl, celý tenhle soubor
  --    by testoval něco jiného, než si myslí.
  SELECT vat_mode INTO _rezim FROM public.billing_settings WHERE singleton;
  IF _rezim <> 'platce' THEN
    RAISE EXCEPTION 'TEST SELHAL: po migraci má být vat_mode=platce, je %.', _rezim;
  END IF;
  RAISE NOTICE 'OK  po migraci je hala vedená jako plátce DPH';

  -- 2) Koncept se založit DÁ i pod plátcem — guard sedí až na vystavení.
  --    (Kdyby zavíral i zakládání, byla by to jiná, širší změna.)
  SELECT id INTO _sub FROM public.subjects WHERE name = 'CK Ostravské kameny';
  _koncept := public.create_invoice_draft_club(_sub, '2026-07-01', '2026-07-31');
  IF _koncept IS NULL THEN
    RAISE EXCEPTION 'TEST SELHAL: koncept se nezaložil, guard by se nezkusil.';
  END IF;
  RAISE NOTICE 'OK  koncept jde založit i pod plátcem (guard je až na vystavení)';

  -- 3) A TEĎ TO PODSTATNÉ: vystavit ho nejde.
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.issue_invoice(_koncept);
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    _spadlo := true;
    _hlaska := SQLERRM;
  END;

  IF NOT _spadlo THEN
    RAISE EXCEPTION 'TEST SELHAL: pod vat_mode=platce interní engine doklad VYSTAVIL. Guard nedrží — a hala by měla doklady ve dvou daňových režimech, každý v jiné číselné řadě.';
  END IF;
  IF position('neplátce' in _hlaska) = 0 THEN
    RAISE EXCEPTION 'TEST SELHAL: odmítnuto, ale jinou hláškou než o režimu DPH: %', _hlaska;
  END IF;
  RAISE NOTICE 'OK  pod plátcem interní engine odmítne vystavit a řekne proč: %', _hlaska;

  -- 4) A pod neplátcem týž koncept vystavit JDE. Bez tohohle by test prošel
  --    i tehdy, kdyby `issue_invoice` odmítala všechno bez rozdílu.
  UPDATE public.billing_settings SET vat_mode = 'neplatce' WHERE singleton;
  _spadlo := false;
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.issue_invoice(_koncept);
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    _spadlo := true;
    _hlaska := SQLERRM;
  END;

  IF _spadlo THEN
    RAISE EXCEPTION 'TEST SELHAL: pod neplátcem měl doklad projít, ale spadl: %', _hlaska;
  END IF;
  RAISE NOTICE 'OK  … a pod neplátcem týž koncept projde (guard rozlišuje, neodmítá všechno)';
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
