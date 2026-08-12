-- =============================================================================
-- A4 — CHECKy na fakturační údaje (Etapa 2)
-- =============================================================================
-- PROČ: A3 pečlivě ohradila provozní pole (`due_days`, časy běhů, `file_prefix`),
-- ale pole, která rozhodují o penězích, nechala volná. Celá premisa A4 přitom zní
-- „špatný IBAN pošle peníze jinam a zjistí se to po týdnech" — a všechny kontroly,
-- které tu premisu naplňují (mod-97, křížová kontrola účet ↔ IBAN, povinné
-- potvrzení adminem), žily výhradně ve formuláři.
--
-- Ověřeno útokem z přihlášené admin session, ještě než tahle migrace vznikla:
--   PATCH /rest/v1/billing_settings {"bank_iban":"CZ9999999999999999999999",
--                                    "bank_account":"1/9999"}   → 200, zapsáno
-- Tedy IBAN, který neprojde mod-97, a číslo účtu, které není české — a databáze
-- to spolkla.
--
-- Dokud píše jen formulář, je to teoretické. Fáze C a D ale poběží pod
-- `service_role`, která obchází RLS i granty a formulářem neprojde vůbec.
-- Vynutit „admin to odklikl" na serveru nejde a nemusí; vynutit se dá PLATNOST
-- toho, co odklikává.
--
-- VRATNOST:
--   ALTER TABLE public.billing_settings
--     DROP CONSTRAINT billing_settings_bank_iban,
--     DROP CONSTRAINT billing_settings_bank_account,
--     DROP CONSTRAINT billing_settings_supplier_ico;
--   DROP FUNCTION public.iban_je_platny(text);
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Kontrolní číslice IBANu podle ISO 7064 (mod-97)
--
-- IMMUTABLE, aby šla použít v CHECK constraintu. Kontroluje totéž co `overIban`
-- v src/lib/iban.ts — tvar, délku a kontrolní číslice. Obě strany musí dávat
-- stejný výsledek; hlídá to test `billing_settings_test.sql`.
--
-- Záměrně jen pro CZ: hala fakturuje v Česku a zahraniční číslo by stejně
-- potřebovalo jinou délku podle země. Co není CZ, projde jen na obecný tvar —
-- to je vědomé zúžení, ne opomenutí.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.iban_je_platny(_iban text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  _text    text;
  _prehoz  text;
  _cislice text := '';
  _znak    text;
  _zbytek  int := 0;
  _i       int;
BEGIN
  IF _iban IS NULL THEN RETURN true; END IF;   -- prázdné pole je legitimní

  _text := upper(regexp_replace(_iban, '\s', '', 'g'));

  -- Český IBAN má právě 24 znaků a celý BBAN je číselný. Bez kontroly délky
  -- by mod-97 pustilo i kratší řetězec — kontrolní číslice si sednou na cokoli.
  IF _text ~ '^CZ' THEN
    IF _text !~ '^CZ\d{22}$' THEN RETURN false; END IF;
  ELSIF _text !~ '^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$' THEN
    RETURN false;
  END IF;

  -- „CZ00" na konec, písmena na čísla (A = 10 … Z = 35)
  _prehoz := substring(_text FROM 5) || substring(_text FROM 1 FOR 4);
  FOR _i IN 1..length(_prehoz) LOOP
    _znak := substring(_prehoz FROM _i FOR 1);
    IF _znak ~ '[0-9]' THEN
      _cislice := _cislice || _znak;
    ELSE
      _cislice := _cislice || (ascii(_znak) - 55)::text;
    END IF;
  END LOOP;

  -- Po znacích, protože 24místné číslo se do bigintu nevejde.
  FOR _i IN 1..length(_cislice) LOOP
    _zbytek := (_zbytek * 10 + substring(_cislice FROM _i FOR 1)::int) % 97;
  END LOOP;

  RETURN _zbytek = 1;
END;
$$;

COMMENT ON FUNCTION public.iban_je_platny(text) IS
  'Kontrola IBANu (tvar, délka pro CZ, mod-97 podle ISO 7064). Zrcadlí overIban v src/lib/iban.ts; shodu obou stran hlídá billing_settings_test.sql.';

-- -----------------------------------------------------------------------------
-- 2) CHECKy na peněžní a identifikační pole
-- -----------------------------------------------------------------------------
DO $$
DECLARE _spatne int;
BEGIN
  SELECT count(*) INTO _spatne FROM public.billing_settings
   WHERE (bank_iban IS NOT NULL AND NOT public.iban_je_platny(bank_iban))
      OR (bank_account IS NOT NULL AND bank_account !~ '^(\d{1,6}-)?\d{2,10}/\d{4}$')
      OR (supplier_ico IS NOT NULL AND supplier_ico !~ '^\d{8}$');
  IF _spatne > 0 THEN
    RAISE EXCEPTION 'Migrace zastavena: fakturační nastavení obsahuje neplatné údaje (%). Oprav je v Nastavení a spusť znovu.', _spatne;
  END IF;
END $$;

ALTER TABLE public.billing_settings
  ADD CONSTRAINT billing_settings_bank_iban
  CHECK (bank_iban IS NULL OR public.iban_je_platny(bank_iban));

-- České číslo účtu: [předčíslí-]číslo/kód banky. Tiskne se na doklad, takže
-- „asdf" tam nemá co dělat.
ALTER TABLE public.billing_settings
  ADD CONSTRAINT billing_settings_bank_account
  CHECK (bank_account IS NULL OR bank_account ~ '^(\d{1,6}-)?\d{2,10}/\d{4}$');

-- IČO má osm číslic. Neověřuje se kontrolní součet — to dělá ARES při načtení
-- a vlastní IČO haly zadává admin jednou.
ALTER TABLE public.billing_settings
  ADD CONSTRAINT billing_settings_supplier_ico
  CHECK (supplier_ico IS NULL OR supplier_ico ~ '^\d{8}$');

-- -----------------------------------------------------------------------------
-- 3) Kontrola, že to opravdu drží
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF public.iban_je_platny('CZ6508000000192000145399') IS NOT TRUE THEN
    RAISE EXCEPTION 'A4 selhala: referenční IBAN neprošel vlastní kontrolou.';
  END IF;
  IF public.iban_je_platny('CZ9999999999999999999999') IS NOT FALSE THEN
    RAISE EXCEPTION 'A4 selhala: neplatný IBAN prošel.';
  END IF;
  IF public.iban_je_platny('CZ340800000019200014539') IS NOT FALSE THEN
    RAISE EXCEPTION 'A4 selhala: 23znakový IBAN prošel (chybí kontrola délky).';
  END IF;
  RAISE NOTICE 'A4: fakturační údaje mají CHECKy (IBAN mod-97, číslo účtu, IČO).';
END $$;
