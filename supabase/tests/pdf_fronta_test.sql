-- =============================================================================
-- TESTY FRONTY NA GENEROVÁNÍ PDF (C1 + C5)
-- =============================================================================
-- Co se tu hlídá: že se doklad po vystavení dostane do fronty, že si ho vezme
-- právě jeden worker, že selhání nekončí nekonečným opakováním — a hlavně že
-- se k frontě nedostane nikdo z prohlížeče.
--
-- PRAVIDLO 8: guardy ve frontě se ptají na `session_user`, který se pod
-- `SET LOCAL ROLE` NEMĚNÍ. Testovat je odsud by tvrdilo zavřeno o dveřích,
-- které se ani nezkoušely — ta část se testuje připojením jako `authenticator`
-- (viz komentář u sekce 4).
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.tvrd(_podminka boolean, _popis text) RETURNS void
 LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(_podminka, false) THEN
    RAISE EXCEPTION 'TEST SELHAL: %', _popis;
  END IF;
  RAISE NOTICE 'OK  %', _popis;
END $$;

UPDATE public.billing_settings SET
  supplier_name = 'Curling Promo Ostrava z.s.', supplier_address = 'Ledová 1, Ostrava',
  supplier_ico = '12345678', bank_account = '19-2000145399/0800',
  bank_iban = 'CZ6508000000192000145399';

-- -----------------------------------------------------------------------------
-- 1) Vystavení staví doklad do fronty; koncept do ní nepatří
-- -----------------------------------------------------------------------------
DO $$
DECLARE _sub uuid; _fid uuid; _stav public.pdf_status;
BEGIN
  SELECT r.subject_id INTO _sub FROM public.reservations r
   WHERE r.status = 'confirmed' AND r.deleted_at IS NULL AND r.subject_id IS NOT NULL
     AND r.invoice_id IS NULL AND COALESCE(r.corrected_amount, r.amount) > 0
   GROUP BY r.subject_id ORDER BY count(*) DESC LIMIT 1;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
  _fid := public.create_invoice_draft_club(_sub, '2026-07-01', '2026-08-31');

  SELECT pdf_status INTO _stav FROM public.invoices WHERE id = _fid;
  PERFORM pg_temp.tvrd(_stav IS NULL, 'koncept nemá stav PDF (dokladem ještě není)');

  PERFORM public.issue_invoice(_fid);
  RESET ROLE;

  SELECT pdf_status INTO _stav FROM public.invoices WHERE id = _fid;
  PERFORM pg_temp.tvrd(_stav = 'pending', 'vystavený doklad čeká ve frontě na PDF');
  PERFORM pg_temp.tvrd(
    (SELECT cislo FROM public.invoices WHERE id = _fid) IS NOT NULL,
    'a číslo dostal HNED — selhání renderu nesmí udělat díru v řadě');
END $$;

-- -----------------------------------------------------------------------------
-- 2) Claim: jeden doklad si vezme právě jeden worker
-- -----------------------------------------------------------------------------
DO $$
DECLARE _prvni int; _druhy int;
BEGIN
  SELECT count(*) INTO _prvni FROM public.claim_invoice_pdf(10);
  PERFORM pg_temp.tvrd(_prvni >= 1, 'worker si z fronty vezme čekající doklad');

  -- Druhý běh hned po prvním: co je `generating`, se nesmí vydat znovu.
  -- Bez toho by vznikly dva soubory a druhý by přepsal otisk prvního — doklad
  -- s `pdf_sha256`, který nesedí na obsah.
  SELECT count(*) INTO _druhy FROM public.claim_invoice_pdf(10);
  PERFORM pg_temp.tvrd(_druhy = 0, 'a podruhé už si tentýž doklad nevezme');
END $$;

-- -----------------------------------------------------------------------------
-- 3) Dokončení a selhání
-- -----------------------------------------------------------------------------
DO $$
DECLARE _fid uuid; _r record;
BEGIN
  SELECT id INTO _fid FROM public.invoices WHERE pdf_status = 'generating' LIMIT 1;

  PERFORM public.finish_invoice_pdf(_fid, '2026/20260001/v1.pdf', repeat('a', 64), 42000);
  SELECT pdf_status, pdf_path, pdf_sha256, pdf_bytes INTO _r FROM public.invoices WHERE id = _fid;
  PERFORM pg_temp.tvrd(_r.pdf_status = 'ready', 'dokončení překlopí doklad na ready');
  PERFORM pg_temp.tvrd(_r.pdf_path IS NOT NULL AND _r.pdf_sha256 IS NOT NULL,
    'a doklad má cestu i otisk (ready bez souboru by byla lež)');

  -- Selhání: doklad se vrací do fronty, dokud nedojdou pokusy.
  UPDATE public.invoices SET pdf_status = 'generating', pdf_attempts = 1 WHERE id = _fid;
  PERFORM public.fail_invoice_pdf(_fid, 'Upload selhal: síť');
  SELECT pdf_status, pdf_error INTO _r FROM public.invoices WHERE id = _fid;
  PERFORM pg_temp.tvrd(_r.pdf_status = 'pending', 'selhání vrací doklad do fronty');
  PERFORM pg_temp.tvrd(_r.pdf_error LIKE '%síť%', 'a nechá u něj důvod, ať admin ví proč');

  -- Po pátém pokusu se to přestane zkoušet. Nekonečné opakování by u trvalé
  -- chyby (vadný IBAN ve snapshotu) jen tiše topilo výkon.
  UPDATE public.invoices SET pdf_attempts = 5 WHERE id = _fid;
  PERFORM public.fail_invoice_pdf(_fid, 'pořád dokola');
  SELECT pdf_status INTO _r FROM public.invoices WHERE id = _fid;
  PERFORM pg_temp.tvrd(_r.pdf_status = 'failed', 'po vyčerpání pokusů se čeká na člověka');
END $$;

-- -----------------------------------------------------------------------------
-- 4) Opakování na vyžádání — a KDO ho smí spustit
--
-- `retry_invoice_pdf` se ptá na `has_role(auth.uid(),'admin')`, což pod
-- `SET LOCAL ROLE` funguje správně (čte se z tokenu, ne ze `session_user`).
-- Grantová část (`claim/finish/fail` jen pro service_role) se ověřuje přes
-- `has_function_privilege` — spustit je odsud jako `postgres` by neřeklo nic.
-- -----------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
DO $$
DECLARE _fid uuid;
BEGIN
  SELECT id INTO _fid FROM public.invoices WHERE pdf_status = 'failed' LIMIT 1;
  BEGIN
    PERFORM public.retry_invoice_pdf(_fid);
    PERFORM pg_temp.tvrd(false, 'člen NEMĚL spustit generování');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.tvrd(SQLERRM LIKE '%jen správce%', 'člen generování nespustí');
  END;
END $$;

SET LOCAL request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
DO $$
DECLARE _fid uuid; _r record;
BEGIN
  SELECT id INTO _fid FROM public.invoices WHERE pdf_status = 'failed' LIMIT 1;
  PERFORM public.retry_invoice_pdf(_fid);
  SELECT pdf_status, pdf_attempts, pdf_error INTO _r FROM public.invoices WHERE id = _fid;
  PERFORM pg_temp.tvrd(_r.pdf_status = 'pending', 'admin vrátí doklad do fronty');
  PERFORM pg_temp.tvrd(_r.pdf_attempts = 0, 'a počítadlo pokusů se vynuluje (je to nový pokus)');
  PERFORM pg_temp.tvrd(_r.pdf_error IS NULL, 'stará chyba u dokladu nezůstane');
END $$;
RESET ROLE;

DO $$
BEGIN
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('authenticated', 'public.claim_invoice_pdf(integer)', 'EXECUTE'),
    'přihlášený uživatel si z fronty nevezme nic (ani admin — je to věc serveru)');
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('authenticated', 'public.finish_invoice_pdf(uuid, text, text, bigint)', 'EXECUTE'),
    'ani nedopíše výsledek renderu');
  PERFORM pg_temp.tvrd(
    has_function_privilege('service_role', 'public.claim_invoice_pdf(integer)', 'EXECUTE'),
    'worker (service_role) do fronty smí');
  PERFORM pg_temp.tvrd(
    NOT has_function_privilege('anon', 'public.retry_invoice_pdf(uuid)', 'EXECUTE'),
    'nepřihlášený negeneruje nic');
END $$;

-- -----------------------------------------------------------------------------
-- 5) Bucket je privátní — jsou v něm jména, adresy a částky
-- -----------------------------------------------------------------------------
DO $$
DECLARE _r record;
BEGIN
  SELECT public, file_size_limit, allowed_mime_types INTO _r
    FROM storage.buckets WHERE id = 'invoices';
  PERFORM pg_temp.tvrd(FOUND, 'bucket `invoices` existuje');
  PERFORM pg_temp.tvrd(_r.public = false, 'a je PRIVÁTNÍ (doklad nese jméno, adresu i částku)');
  PERFORM pg_temp.tvrd(_r.allowed_mime_types = ARRAY['application/pdf'],
    'pustí do sebe jen PDF');
END $$;

ROLLBACK;
