-- =============================================================================
-- A3 — `billing_settings`: fakturační nastavení haly (Etapa 2)
-- =============================================================================
-- Jedno místo pro to, co spec označuje [POTVRDIT] v kapitolách 3, 4, 5 a 7:
-- údaje dodavatele, bankovní spojení, režim DPH, splatnost, formát čísla faktury,
-- časy automatiky. Odpověď klienta má být `UPDATE`, ne nová migrace.
--
-- Kde ten slib NEPLATÍ, ať se na něj nikdo nespoléhá naslepo: `number_format`
-- je whitelist dvou hodnot, protože formát musí umět parsovat kód v B1 — jiný
-- tvar (`FV-2026-0001`) je migrace. A mimo tuhle tabulku zůstávají body, které
-- sem nepatří: pravidlo pro akce přes půlnoc (spec §11) a vzor názvu souboru
-- (Q5, „hybridní") — z toho je tu jen `file_prefix`.
--
-- PROČ SAMOSTATNÁ TABULKA, A NE SLOUPCE V `public.settings` (rozhodnutí R9):
-- `settings` měla `settings_select USING (true)` a tabulkový grant, takže ji četl
-- každý přihlášený — A2b to zúžila, ale principiálně je to tabulka pro provozní
-- nastavení, kterou frontend potřebuje široce (otevírací doba). Přidat do ní IBAN
-- a IČO dodavatele by znamenalo mít citlivé fakturační údaje v tabulce, kterou
-- kdokoli může omylem zase otevřít jedním GRANTem. Oddělením se ta chyba nedá
-- udělat: `billing_settings` nemá pro ne-admina žádnou politiku vůbec.
--
-- VŠECHNY ÚDAJE OD KLIENTA JSOU NULLABLE (údaje dodavatele, banka, texty).
-- Modul se má dát celý postavit a otestovat, dokud klient nedodá IČO a číslo
-- účtu. Co chybí, blokuje až vystavení první ostré faktury — ne vývoj. Kontrola
-- úplnosti proto NEpatří do NOT NULL constraintů, ale do funkce, která doklad
-- vystavuje (fáze B). Provozní přepínače a defaulty naopak `NOT NULL DEFAULT`
-- jsou — u nich je „nevyplněno" nebezpečnější než jakákoli hodnota.
--
-- VRATNOST:
--   DROP TABLE public.billing_settings;   -- vezme s sebou triggery, politiky i granty
--   DROP TYPE  public.vat_mode;
-- Žádná jiná tabulka na ní zatím nezávisí. Dvě upozornění:
--   • záznamy v `audit_log` revert NEmaže, a je to tak správně;
--   • jakmile B2 postaví `invoices.vat_mode`, `DROP TYPE` bez CASCADE přestane
--     projít — enum zakládá tahle migrace, ne B2 (plán ho vede pod B2, opraveno).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Režim DPH jako ENUM, ne boolean (rozhodnutí R2)
--
-- `is_vat_payer boolean` by byl levnější dnes a dražší při první změně. Chybí mu
-- totiž třetí stav, který reálně existuje: IDENTIFIKOVANÁ OSOBA má DIČ, ale
-- v tuzemsku fakturuje bez DPH (§ 6g–6l ZDPH). S booleanem by se to muselo
-- vyjádřit kombinací „není plátce, ale má DIČ", což je přesně ten druh
-- implicitního stavu, na kterém se doklady rozcházejí.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  -- Filtr na schéma je nutný: bez něj by guard našel stejnojmenný typ jinde,
  -- přeskočil vytvoření a CREATE TABLE by spadl na neexistující public.vat_mode.
  IF NOT EXISTS (SELECT 1 FROM pg_type
                  WHERE typname = 'vat_mode' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.vat_mode AS ENUM ('neplatce', 'identifikovana_osoba', 'platce');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2) Tabulka
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_settings (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton  boolean NOT NULL DEFAULT true UNIQUE,

  -- ---- Dodavatel (náležitosti dokladu) -------------------------------------
  -- `supplier_registry` je zápis do rejstříku (soud, oddíl, vložka) podle § 435
  -- ObčZ. Na dokladu být musí a nejde ho odvodit z IČO, takže vlastní pole.
  supplier_name      text,
  supplier_legal_form text,
  supplier_address   text,
  supplier_ico       text,
  supplier_dic       text,
  supplier_registry  text,

  -- ---- Bankovní spojení ----------------------------------------------------
  -- Číslo účtu v českém tvaru i IBAN zvlášť: na doklad se tiskne české číslo,
  -- do QR platby patří IBAN. Dopočet je v UI (A4) a admin ho musí potvrdit —
  -- špatný IBAN pošle peníze jinam a zjistí se to po týdnech.
  bank_account       text,
  bank_iban          text,
  bank_bic           text,
  payment_message    text,

  -- ---- Daňový režim --------------------------------------------------------
  vat_mode           public.vat_mode NOT NULL DEFAULT 'neplatce',

  -- ---- Doklad --------------------------------------------------------------
  due_days           integer NOT NULL DEFAULT 14,
  -- `RRRRNNNN` = rok + čtyřmístné pořadí (20260001). Vejde se do 10 číslic, které
  -- povoluje variabilní symbol, a je jednoznačné napříč lety.
  number_format      text    NOT NULL DEFAULT 'RRRRNNNN',
  -- Jedna společná řada pro komerční i klubové faktury. Oddělené řady by chtěly
  -- jiný formát (RRRR{1|2}NNN), proto je to přepínač, ne dopočet.
  separate_series    boolean NOT NULL DEFAULT false,
  file_prefix        text    NOT NULL DEFAULT 'curling',

  -- ---- Automatika ----------------------------------------------------------
  -- Vypínač je schválně v DATECH, ne v migraci: plánovač se pak dá nasadit
  -- a týdny sledovat, jestli tiká, dřív než smí cokoli vystavit.
  automation_enabled boolean NOT NULL DEFAULT false,
  -- Režim náběhu: automat první měsíc vyrábí jen koncepty, admin je po kontrole
  -- vystaví jedním klikem. Koncepty se do kontrolního součtu nezapočítávají.
  auto_issue         boolean NOT NULL DEFAULT false,

  -- Měsíční běh: 1. den následujícího měsíce v 06:00 pražského času.
  -- Rozhodnutí PM proti původnímu zadání „poslední den v měsíci" — běh 31. 8.
  -- ve 2:00 by nezachytil rezervace z 31. srpna večer, tedy by tiše ztrácel data.
  monthly_run_day    integer NOT NULL DEFAULT 1,
  monthly_run_hour   integer NOT NULL DEFAULT 6,
  -- Denní běh komerčních akcí. PM určil čas jen pro měsíční běh; tenhle default
  -- ho zrcadlí, ať se to nechová pokaždé jinak. Je to hodnota v nastavení.
  daily_run_hour     integer NOT NULL DEFAULT 6,

  -- ---- Co se fakturuje -----------------------------------------------------
  -- Rozhodnutí PM k otázce Q4: fakturují se JEN schválené rezervace. Nepotvrzená
  -- rezervace led drží, ale klub nemá dostat fakturu za něco, co jeho zástupce
  -- neodsouhlasil.
  invoice_only_approved boolean NOT NULL DEFAULT true,

  -- ---- Audit ---------------------------------------------------------------
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.profiles(user_id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.profiles(user_id),

  CONSTRAINT billing_settings_singleton CHECK (singleton = true),
  -- Splatnost 0 = „splatné ihned", což je legitimní; záporná ne.
  CONSTRAINT billing_settings_due_days      CHECK (due_days BETWEEN 0 AND 365),
  -- 0 = POSLEDNÍ DEN V MĚSÍCI. Původní zadání klienta znělo „poslední den",
  -- PM to přebil na 1. následujícího (běh 31. 8. ve 2:00 by nezachytil
  -- rezervace z 31. srpna večer). Ale zavřít klientovi jeho vlastní variantu
  -- není naše věc — musí zůstat vyjádřitelná hodnotou, ne migrací.
  CONSTRAINT billing_settings_monthly_day   CHECK (monthly_run_day BETWEEN 0 AND 31),
  CONSTRAINT billing_settings_monthly_hour  CHECK (monthly_run_hour BETWEEN 0 AND 23),
  CONSTRAINT billing_settings_daily_hour    CHECK (daily_run_hour BETWEEN 0 AND 23),
  -- Prefix jde do názvu souboru, takže bez lomítek a jiných cestových znaků.
  CONSTRAINT billing_settings_file_prefix   CHECK (file_prefix ~ '^[a-z0-9_-]{1,32}$'),
  CONSTRAINT billing_settings_number_format CHECK (number_format IN ('RRRRNNNN', 'RRRRSNNN')),
  -- Ty dvě pole jsou 1:1, ne nezávislá. `separate_series = true` s formátem
  -- bez rozlišovací číslice by dal komerční i klubové faktuře číslo 20260001 —
  -- tedy duplicitu, kterou spec §4 zakazuje. Rozporuplný stav proto nevznikne.
  CONSTRAINT billing_settings_series_format CHECK (separate_series = (number_format = 'RRRRSNNN'))
);

COMMENT ON TABLE public.billing_settings IS
  'Fakturační nastavení haly (singleton). Vše nullable — modul jde postavit dřív, než klient dodá IČO a účet. Vidí a mění jen admin.';
COMMENT ON COLUMN public.billing_settings.monthly_run_day IS
  'Den měsíce pro souhrnné klubové faktury, v pražském čase. 0 = poslední den v měsíci. Dny 29-31 v kratších měsících neexistují; běh (D2) je musí ořezat přes least(den, dní_v_měsíci) — plánovač je podle R6 hodinový tik, takže rozhodnutí dělá funkce, ne cron výraz.';
COMMENT ON COLUMN public.billing_settings.invoice_only_approved IS
  'Rozhodnutí PM k Q4: fakturují se jen schválené rezervace.';

-- -----------------------------------------------------------------------------
-- 3) Triggery: updated_by/updated_at, audit a zákaz mazání
--
-- POŘADÍ: triggery se zakládají PŘED vložením řádku, aby i jeho vznik měl
-- auditní stopu. Obráceně (jak to bylo napsané napoprvé) `audit_log` o založení
-- nastavení neví vůbec — a požadavek klienta zní „musí být vidět, kdo co zadával".
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_billing_settings_updated ON public.billing_settings;
CREATE TRIGGER trg_billing_settings_updated
  BEFORE UPDATE ON public.billing_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_fields();

DROP TRIGGER IF EXISTS trg_billing_settings_audit ON public.billing_settings;
CREATE TRIGGER trg_billing_settings_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.billing_settings
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- Mazání zakazuje trigger, ne jen chybějící grant a politika.
--
-- Granty i RLS totiž obchází `service_role` (má BYPASSRLS a plná práva) — a to
-- je role, kterou budou fáze C a D používat. `DELETE FROM billing_settings` pod
-- ní dnes projde a nechá halu bez fakturačního nastavení. Trigger platí i na ni.
--
-- Pozn.: DELETE větev `write_audit_log` proto NENÍ mrtvá — pokud by se mazání
-- někdy povolilo, zůstane po něm stopa.
CREATE OR REPLACE FUNCTION public.guard_billing_settings_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'Fakturační nastavení se nemaže — je to singleton. Uprav ho, nebo vyprázdni jednotlivá pole.';
END;
$$;

DROP TRIGGER IF EXISTS trg_billing_settings_no_delete ON public.billing_settings;
CREATE TRIGGER trg_billing_settings_no_delete
  BEFORE DELETE ON public.billing_settings
  FOR EACH ROW EXECUTE FUNCTION public.guard_billing_settings_delete();

-- A TOTÉŽ PRO TRUNCATE, jinak je slib výš nepravdivý: `TRUNCATE` řádkové
-- BEFORE DELETE triggery VŮBEC NESPOUŠTÍ. Ověřeno — pod `service_role` prošel
-- a nechal tabulku prázdnou, přestože guard nad DELETE existoval. Musí to být
-- statement-level trigger.
DROP TRIGGER IF EXISTS trg_billing_settings_no_truncate ON public.billing_settings;
CREATE TRIGGER trg_billing_settings_no_truncate
  BEFORE TRUNCATE ON public.billing_settings
  FOR EACH STATEMENT EXECUTE FUNCTION public.guard_billing_settings_delete();

-- -----------------------------------------------------------------------------
-- 4) Jediný řádek — ať se nemusí řešit „co když chybí"
-- Všechna pole zůstanou prázdná; vyplní je admin v Nastavení (A4).
-- -----------------------------------------------------------------------------
INSERT INTO public.billing_settings (singleton)
VALUES (true)
ON CONFLICT (singleton) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5) RLS a granty — admin-only na SELECT i UPDATE
--
-- Pozor na pořadí a na to, co se NEuděluje:
--   • `anon` nedostane nic. Ani SELECT.
--   • INSERT ani DELETE politika neexistuje — řádek zakládá tahle migrace
--     a mazat se nemá. Bez politiky RLS operaci odmítne.
--   • Poučení z A2b: tabulkový grant přebíjí sloupcové odebrání, takže se
--     granty rovnou dávají úzké.
-- -----------------------------------------------------------------------------
ALTER TABLE public.billing_settings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.billing_settings FROM anon, authenticated, public;

-- UPDATE je SLOUPCOVÝ, ne tabulkový. Tabulkový by adminovi dovolil přepsat i `id`
-- a `created_at` — a změna `id` rozpojí `audit_log.record_id` od celé historie
-- tohohle řádku. Přes formulář to nikdo neudělá, přes `PATCH /rest/v1/…` ano.
GRANT SELECT ON public.billing_settings TO authenticated;
GRANT UPDATE (
  supplier_name, supplier_legal_form, supplier_address,
  supplier_ico, supplier_dic, supplier_registry,
  bank_account, bank_iban, bank_bic, payment_message,
  vat_mode, due_days, number_format, separate_series, file_prefix,
  automation_enabled, auto_issue,
  monthly_run_day, monthly_run_hour, daily_run_hour,
  invoice_only_approved
) ON public.billing_settings TO authenticated;

DROP POLICY IF EXISTS billing_settings_select_admin ON public.billing_settings;
CREATE POLICY billing_settings_select_admin ON public.billing_settings
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS billing_settings_update_admin ON public.billing_settings;
CREATE POLICY billing_settings_update_admin ON public.billing_settings
  FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'admin'))
  WITH CHECK (has_role(auth.uid(), 'admin'));

-- -----------------------------------------------------------------------------
-- 5b) `audit_log` — tenhle PR do něj právě naložil IBAN, tak ať je taky zavřený
--
-- Auditní trigger ukládá do `old_data`/`new_data` CELÝ řádek, tedy včetně IBANu,
-- čísla účtu a IČO dodavatele. Čtení sice hlídá `audit_log_select_admin`, ale
-- granty na téhle tabulce nikdo nikdy nezúžil: `anon` i `authenticated` na ní mají
-- výchozí supabase práva `arwdDxtm` — a `TRUNCATE` je jediná operace, na kterou
-- se RLS NEVZTAHUJE. Ověřeno: `SET ROLE anon; TRUNCATE public.audit_log;` projde
-- a smaže celou auditní stopu.
--
-- Přes PostgREST se `TRUNCATE` vyjádřit nedá, takže to není živý exploit (verdikt
-- k tomu je v docs/SCHEMA_DRIFT.md, kap. 8d) a celý REVOKE sweep patří do A5.
-- Tenhle jediný řádek si ale A3 bere s sebou, protože je to A3, kdo do té tabulky
-- bankovní spojení dal — nechat to na později by znamenalo vědomě zvýšit sázku
-- a odejít.
--
-- `write_audit_log` je SECURITY DEFINER vlastněný `postgres`, takže INSERT grant
-- k psaní nepotřebuje. Ověřeno, že trigger po tomhle píše dál.
-- -----------------------------------------------------------------------------
REVOKE ALL ON public.audit_log FROM anon, authenticated, public;
GRANT SELECT ON public.audit_log TO authenticated;

-- -----------------------------------------------------------------------------
-- 6) Kontrola, že to sedí — migrace si nemá jen přát (vzor z A2b)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _anon      int;
  _politiky  text[];
  _radku     int;
BEGIN
  -- Ptáme se na SLOUPCOVÉ granty, ne tabulkové: `role_table_grants` by minula
  -- `GRANT SELECT (bank_iban) … TO anon`, což je nejtišší možná varianta úniku.
  SELECT count(*) INTO _anon FROM information_schema.column_privileges
   WHERE table_schema = 'public' AND table_name = 'billing_settings'
     AND grantee IN ('anon', 'PUBLIC');
  IF _anon > 0 THEN
    RAISE EXCEPTION 'A3 selhala: anon/PUBLIC má práva na billing_settings (%).', _anon;
  END IF;

  -- Test 3d se opírá o to, že `authenticated` INSERT ani DELETE grant NEMÁ —
  -- takže se tady musí hlídat, ne předpokládat. Bez tohohle by `GRANT INSERT`
  -- prošel a kontrolní blok by mlčel.
  IF has_table_privilege('authenticated', 'public.billing_settings', 'INSERT')
     OR has_table_privilege('authenticated', 'public.billing_settings', 'DELETE')
     OR has_table_privilege('authenticated', 'public.billing_settings', 'TRUNCATE') THEN
    RAISE EXCEPTION 'A3 selhala: authenticated má na billing_settings víc než SELECT a UPDATE.';
  END IF;

  -- A naopak: co potřebuje, mít musí — jinak by admin nastavení neuložil.
  IF NOT has_table_privilege('authenticated', 'public.billing_settings', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.billing_settings', 'bank_iban', 'UPDATE') THEN
    RAISE EXCEPTION 'A3 selhala: authenticated nemá práva, která potřebuje (SELECT / UPDATE sloupců).';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT cmd ORDER BY cmd), ARRAY[]::text[]) INTO _politiky
    FROM pg_policies WHERE schemaname = 'public' AND tablename = 'billing_settings';
  IF _politiky <> ARRAY['SELECT', 'UPDATE'] THEN
    RAISE EXCEPTION 'A3 selhala: čekal jsem politiky jen pro SELECT a UPDATE, jsou %.',
      array_to_string(_politiky, ', ');
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.billing_settings'::regclass) THEN
    RAISE EXCEPTION 'A3 selhala: RLS není zapnutá.';
  END IF;

  SELECT count(*) INTO _radku FROM public.billing_settings;
  IF _radku <> 1 THEN
    RAISE EXCEPTION 'A3 selhala: čekal jsem právě jeden řádek, je jich %.', _radku;
  END IF;

  -- Vznik řádku musí být v auditu — proto se triggery zakládají před INSERTem.
  IF NOT EXISTS (SELECT 1 FROM public.audit_log
                  WHERE table_name = 'billing_settings' AND action = 'insert') THEN
    RAISE EXCEPTION 'A3 selhala: založení nastavení nemá auditní stopu (špatné pořadí triggerů a INSERTu).';
  END IF;

  -- audit_log drží kopie fakturačních údajů, takže i on musí být zavřený.
  IF has_table_privilege('anon', 'public.audit_log', 'SELECT')
     OR has_table_privilege('authenticated', 'public.audit_log', 'TRUNCATE') THEN
    RAISE EXCEPTION 'A3 selhala: audit_log je pořád otevřený (drží kopie IBANu).';
  END IF;

  RAISE NOTICE 'A3: billing_settings založena (admin-only, jeden prázdný řádek).';
END $$;
