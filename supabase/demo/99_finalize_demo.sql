-- =============================================================================
-- DOKONČENÍ DEMA — běží jako poslední část demo_setup.sql
-- =============================================================================
-- Reset smazal schéma public (a s ním profily a role), ale účty v auth.users,
-- které si někdo v demu založil sám, zůstaly. Bez profilu a role by se sice
-- přihlásili, ale aplikace by je nikam nepustila — tak jim je doplníme.
-- =============================================================================

INSERT INTO public.profiles (user_id, full_name)
SELECT u.id, COALESCE(u.raw_user_meta_data ->> 'full_name', split_part(u.email, '@', 1))
  FROM auth.users u
 WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.user_id = u.id);

INSERT INTO public.user_roles (user_id, role)
SELECT u.id, 'hobby_player'
  FROM auth.users u
 WHERE NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = u.id)
ON CONFLICT (user_id, role) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Fakturační údaje pro demo — VYMYŠLENÉ
--
-- Migrace A3 nechává `billing_settings` schválně prázdné: skutečné údaje haly
-- (IČO, zápis v rejstříku, účet) nejde vymyslet a vystavit fakturu s vymyšlenými
-- je horší než ji nevystavit vůbec. Na DEMU je to ale naopak: bez nich se
-- `issue_invoice` (správně) zastaví na „chybí IČO dodavatele" a klient si celou
-- cestu k dokladu neproklikáte.
--
-- Proto se plní JEN TADY, v demo skriptu — ne v seedu a ne v migraci, ať se
-- vymyšlené IČO nikdy nedostane na ostrou databázi. Účet i IČO jsou schválně
-- zjevně testovací (IČO 12345678) a admin je v Nastavení → Fakturace přepíše.
-- Číslo účtu a IBAN k sobě PATŘÍ, a je to potřeba: `19-2000145399/0800` je
-- předčíslí 19 + účet 2000145399 + kód banky 0800, což je přesně BBAN uvnitř
-- CZ6508000000192000145399. Kdyby si neodpovídaly, doklad by tiskl jedno číslo
-- a QR platba by poslala peníze jinam — a na demu by si toho nikdo nevšiml.
-- (Zápis bez pomlčky, tedy `192000145399/0800`, navíc neprojde CHECKem
-- `billing_settings_bank_account`: povoluje nejvýš 10 číslic za předčíslím.)
-- -----------------------------------------------------------------------------
UPDATE public.billing_settings SET
  supplier_name       = COALESCE(supplier_name,       'Curling Promo Ostrava z.s. (DEMO)'),
  supplier_legal_form = COALESCE(supplier_legal_form, 'zapsaný spolek'),
  supplier_address    = COALESCE(supplier_address,    'Ledová 1, 700 30 Ostrava'),
  supplier_ico        = COALESCE(supplier_ico,        '12345678'),
  supplier_registry   = COALESCE(supplier_registry,   'Spolkový rejstřík vedený Krajským soudem v Ostravě, oddíl L, vložka 00000 (demo)'),
  bank_account        = COALESCE(bank_account,        '19-2000145399/0800'),
  bank_iban           = COALESCE(bank_iban,           'CZ6508000000192000145399'),
  payment_message     = COALESCE(payment_message,     'Pronájem ledové plochy');

DO $$
DECLARE _uzivatelu int; _rezervaci int; _drah int;
BEGIN
  SELECT count(*) INTO _uzivatelu FROM auth.users;
  SELECT count(*) INTO _rezervaci FROM public.reservations WHERE status = 'confirmed';
  SELECT count(*) INTO _drah FROM public.sheets;
  RAISE NOTICE 'DEMO připraveno: % uživatelů, % potvrzených rezervací, % dráhy.', _uzivatelu, _rezervaci, _drah;
  RAISE NOTICE 'DEMO: fakturační údaje jsou VYMYŠLENÉ (IČO 12345678) — přepiš je v Nastavení → Fakturace.';
END $$;
