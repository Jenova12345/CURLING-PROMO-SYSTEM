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

  -- 2) KONCEPT SE POD PLÁTCEM NESMÍ ZALOŽIT ANI ZAČÍT.
  --
  --    Dřív šel — a to byla past: koncept vznikl, ZAMKL rezervace
  --    (`invoice_id` + `invoiced_at`) a vystavit ho pak už nešlo. Admin
  --    v „Kdo dluží" klikl, dostal „Koncept faktury založen" a narazil až
  --    o obrazovku dál, s rezervacemi visícími na dokladu, který nikdy
  --    nevznikne. Zavírá to migrace 20260830160000.
  SELECT id INTO _sub FROM public.subjects WHERE name = 'CK Ostravské kameny';

  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.create_invoice_draft_club(_sub, '2026-07-01', '2026-07-31');
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    _spadlo := true;
    _hlaska := SQLERRM;
  END;

  IF NOT _spadlo THEN
    RAISE EXCEPTION 'TEST SELHAL: pod plátcem se založil koncept. Zamkne rezervace na dokladu, který nepůjde vystavit.';
  END IF;
  IF position('neplátce' in _hlaska) = 0 THEN
    RAISE EXCEPTION 'TEST SELHAL: zakládání odmítnuto, ale jinou hláškou: %', _hlaska;
  END IF;

  -- A NIC SE NEZAMKLO. Bez tohohle tvrzení by test prošel i tehdy, kdyby guard
  -- odmítal až PO zabrání rezervací — tedy kdyby po sobě musel uklízet.
  IF EXISTS (SELECT 1 FROM public.reservations WHERE invoice_id IS NOT NULL) THEN
    RAISE EXCEPTION 'TEST SELHAL: guard odmítl, ale rezervace už byly zamčené.';
  END IF;
  RAISE NOTICE 'OK  pod plátcem se koncept nezaloží — a nic se přitom nezamkne';

  -- Pro zbytek testu si koncept vyrobíme pod neplátcem.
  _spadlo := false;
  UPDATE public.billing_settings SET vat_mode = 'neplatce' WHERE singleton;
  _koncept := public.create_invoice_draft_club(_sub, '2026-07-01', '2026-07-31');
  UPDATE public.billing_settings SET vat_mode = 'platce' WHERE singleton;
  IF _koncept IS NULL THEN
    RAISE EXCEPTION 'TEST SELHAL: nepodařilo se vyrobit koncept ani pod neplátcem.';
  END IF;

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

-- -----------------------------------------------------------------------------
-- A AUTOMATIKA POD PLÁTCEM TAKY NIC NEVYROBÍ
--
-- `billing_automation_tick` volá `create_invoice_draft_commercial` uvnitř
-- `EXCEPTION WHEN OTHERS`, takže po přepnutí NESPADNE — jen tiše počítá `chyb`.
-- To je přesně ten stav, před kterým varuje hlavička migrace 20260830140000
-- („automatiku nezapínat, dokud interní engine nevypadne"), a je lepší mít ho
-- doložený než odhadnutý.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _v jsonb; _pred int; _po int;
BEGIN
  UPDATE public.billing_settings
     SET vat_mode = 'platce', automation_enabled = true, auto_issue = false
   WHERE singleton;

  SELECT count(*) INTO _pred FROM public.invoices;
  _v := public.billing_automation_tick();
  SELECT count(*) INTO _po FROM public.invoices;

  IF _po <> _pred THEN
    RAISE EXCEPTION 'TEST SELHAL: automatika pod plátcem vyrobila % dokladů.', _po - _pred;
  END IF;
  RAISE NOTICE 'OK  automatika pod plátcem nevyrobí doklad (%)' , _v;
END $$;

DO $$ BEGIN RAISE NOTICE '=== VŠECHNY TESTY PROŠLY ==='; END $$;

ROLLBACK;
