-- =============================================================================
-- C1 — fronta na generování PDF + privátní bucket `invoices`
-- =============================================================================
-- PROČ FRONTA A NE DÁVKA (rozhodnutí R4): Edge funkce má strop 2 s CPU na
-- požadavek. Vygenerovat PDF k dvaceti fakturám najednou se do něj nevejde,
-- takže se render nedělá při vystavení, ale AŽ POTOM, po jednom.
--
-- Z toho plyne pořadí operací (R5): číslo se přidělí a doklad se zakomituje
-- DŘÍV, než PDF vůbec vznikne. Selhání renderu proto nedělá díru v číselné
-- řadě — dělá frontu. Faktura bez PDF je platný doklad se štítkem
-- „PDF se generuje".
--
-- STAVY: pending → generating → ready, plus failed po vyčerpání pokusů.
-- Vzor je `email_outbox`, který v repu funguje; tady je navíc `generating`,
-- protože render trvá vteřiny a bez něj by druhý worker vzal tutéž fakturu.
--
-- VRATNOST:
--   ALTER TABLE public.invoices DROP COLUMN IF EXISTS pdf_status, ... ;
--   DROP FUNCTION IF EXISTS public.claim_invoice_pdf(int);
--   DROP FUNCTION IF EXISTS public.finish_invoice_pdf(uuid, text, text, bigint);
--   DROP FUNCTION IF EXISTS public.fail_invoice_pdf(uuid, text);
--   -- bucket a jeho politiky se nechávají: smazat bucket = smazat doklady
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Stav renderu na dokladu
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pdf_status'
                  AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.pdf_status AS ENUM ('pending', 'generating', 'ready', 'failed');
  END IF;
END $$;

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS pdf_status       public.pdf_status,
  ADD COLUMN IF NOT EXISTS pdf_attempts     integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pdf_error        text,
  ADD COLUMN IF NOT EXISTS pdf_claimed_at   timestamptz,
  ADD COLUMN IF NOT EXISTS pdf_generated_at timestamptz,
  ADD COLUMN IF NOT EXISTS pdf_bytes        bigint;

COMMENT ON COLUMN public.invoices.pdf_status IS
  'Stav renderu PDF: pending → generating → ready, failed po vyčerpání pokusů. NULL u konceptu — koncept dokladem ještě není a PDF nemá.';
COMMENT ON COLUMN public.invoices.pdf_claimed_at IS
  'Kdy si frontu vzal worker. Slouží k uvolnění zaseknutého renderu (worker spadl uprostřed), ne k měření výkonu.';

-- Koncept PDF nemá a mít nemá; vystavený doklad ho mít má, i kdyby zatím jen ve frontě.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_pdf_status_dle_stavu') THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_pdf_status_dle_stavu CHECK (
      (status = 'koncept' AND pdf_status IS NULL)
      OR (status <> 'koncept' AND pdf_status IS NOT NULL)
    ) NOT VALID;   -- NOT VALID: staré doklady vznikly před frontou, dorovnají se níž
  END IF;
  -- `ready` bez cesty k souboru je lež o tom, že je co stáhnout.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_pdf_ready_ma_soubor') THEN
    ALTER TABLE public.invoices ADD CONSTRAINT invoices_pdf_ready_ma_soubor CHECK (
      pdf_status IS DISTINCT FROM 'ready'
      OR (pdf_path IS NOT NULL AND pdf_sha256 IS NOT NULL)
    );
  END IF;
END $$;

-- Dorovnání dokladů vystavených před frontou: mají PDF? → ready, jinak pending.
UPDATE public.invoices
   SET pdf_status = CASE WHEN pdf_path IS NOT NULL THEN 'ready'::public.pdf_status
                         ELSE 'pending'::public.pdf_status END
 WHERE status <> 'koncept' AND pdf_status IS NULL;

DO $$
BEGIN
  ALTER TABLE public.invoices VALIDATE CONSTRAINT invoices_pdf_status_dle_stavu;
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Dorovnání pdf_status neproběhlo úplně: %', SQLERRM;
END $$;

-- Fronta se čte přesně jedním dotazem, tak ať má vlastní index.
CREATE INDEX IF NOT EXISTS idx_invoices_pdf_fronta
  ON public.invoices (issued_at) WHERE pdf_status IN ('pending', 'generating');

-- -----------------------------------------------------------------------------
-- 2) Guard: nové sloupce jsou provozní stav, ne obsah dokladu
--
-- `guard_invoice_immutable` pouští u vystaveného dokladu jen whitelist. Render
-- PDF mění stav fronty, ne částky, strany ani číslo — patří tedy dovnitř.
-- Whitelist se rozšiřuje v TÉŽE migraci, která sloupce přidává: jinak by mezi
-- oběma běhy existovala verze schématu, kde worker nemůže dopsat výsledek.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public.guard_invoice_immutable()'::regprocedure);

  IF position('pdf_status' in _def) = 0 THEN
    _def := replace(_def,
      $stare$'datum_uhrady', 'paid_at', 'paid_by'];$stare$,
      $nove$'datum_uhrady', 'paid_at', 'paid_by',
                            -- Fronta PDF: provozní stav renderu, ne obsah dokladu.
                            'pdf_status', 'pdf_attempts', 'pdf_error',
                            'pdf_claimed_at', 'pdf_generated_at', 'pdf_bytes'];$nove$);
    EXECUTE _def;
  END IF;

  IF position('pdf_status' in pg_get_functiondef('public.guard_invoice_immutable()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Rozšíření whitelistu guardu se nepovedlo — worker by nemohl dopsat výsledek renderu.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3) Atomický claim z fronty
--
-- `SKIP LOCKED` + přepnutí na `generating` v jedné větě: dva soubězné workery si
-- tak nikdy nevezmou tutéž fakturu. Bez toho by vznikly dva soubory a druhý by
-- přepsal `pdf_sha256` prvního — tedy doklad s otiskem, který nesedí na obsah.
--
-- Zaseknutý render (worker spadl mezi `generating` a zápisem) se po 10 minutách
-- vrací do fronty. Radši render dvakrát než doklad, který nikdy nevznikne.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_invoice_pdf(_limit integer DEFAULT 1)
RETURNS TABLE (id uuid, cislo text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Volá worker pod servisním klíčem (role `service_role`) nebo pg_cron
  -- (`postgres`). Přihlášený uživatel do fronty nesahá ani jako admin —
  -- generování je věc serveru, ne obrazovky.
  IF NOT (session_user IN ('postgres', 'supabase_admin')
          OR current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role') THEN
    RAISE EXCEPTION 'Frontu PDF obsluhuje jen server.';
  END IF;

  RETURN QUERY
  WITH vybrane AS (
    SELECT i.id
      FROM public.invoices i
     WHERE (i.pdf_status = 'pending'
            OR (i.pdf_status = 'generating' AND i.pdf_claimed_at < now() - interval '10 minutes'))
       AND i.pdf_attempts < 5
     ORDER BY i.issued_at
     LIMIT _limit
       FOR UPDATE SKIP LOCKED
  )
  UPDATE public.invoices i
     SET pdf_status     = 'generating',
         pdf_claimed_at = now(),
         pdf_attempts   = i.pdf_attempts + 1
    FROM vybrane v
   WHERE i.id = v.id
  RETURNING i.id, i.cislo;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_invoice_pdf(integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_invoice_pdf(integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Dokončení a selhání
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finish_invoice_pdf(
  _invoice_id uuid, _path text, _sha256 text, _bytes bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (session_user IN ('postgres', 'supabase_admin')
          OR current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role') THEN
    RAISE EXCEPTION 'Frontu PDF obsluhuje jen server.';
  END IF;
  IF _path IS NULL OR _sha256 IS NULL THEN
    RAISE EXCEPTION 'Hotové PDF musí mít cestu i otisk.';
  END IF;

  UPDATE public.invoices
     SET pdf_status = 'ready', pdf_path = _path, pdf_sha256 = _sha256,
         pdf_bytes = _bytes, pdf_generated_at = now(), pdf_error = NULL
   WHERE id = _invoice_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_invoice_pdf(_invoice_id uuid, _chyba text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _pokusu integer;
BEGIN
  IF NOT (session_user IN ('postgres', 'supabase_admin')
          OR current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role') THEN
    RAISE EXCEPTION 'Frontu PDF obsluhuje jen server.';
  END IF;

  SELECT pdf_attempts INTO _pokusu FROM public.invoices WHERE id = _invoice_id;

  -- Po pátém pokusu se to přestane zkoušet a čeká na člověka. Nekonečné retry by
  -- u trvalé chyby (vadný IBAN ve snapshotu) jen tiše topilo výkon.
  UPDATE public.invoices
     SET pdf_status = CASE WHEN COALESCE(_pokusu, 0) >= 5 THEN 'failed'::public.pdf_status
                           ELSE 'pending'::public.pdf_status END,
         pdf_error  = left(COALESCE(_chyba, 'neznámá chyba'), 500),
         pdf_claimed_at = NULL
   WHERE id = _invoice_id;
END;
$$;

REVOKE ALL ON FUNCTION public.finish_invoice_pdf(uuid, text, text, bigint) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finish_invoice_pdf(uuid, text, text, bigint) TO service_role;
REVOKE ALL ON FUNCTION public.fail_invoice_pdf(uuid, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_invoice_pdf(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 5) Vystavení a storno staví doklad do fronty
--
-- Znovu z `pg_get_functiondef` (pravidlo 7): obě funkce jsou dlouhé a přepsat je
-- z hlavy už jednou utnulo půlku guardu.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public.issue_invoice(uuid)'::regprocedure);
  IF position('pdf_status' in _def) = 0 THEN
    _def := replace(_def,
      $stare$      issued_at         = now(),
      issued_by         = _uid,$stare$,
      $nove$      issued_at         = now(),
      issued_by         = _uid,
      -- Doklad jde rovnou do fronty na PDF. Render se dělá až potom (R4/R5):
      -- číslo je vytištěné v PDF, takže musí být přidělené dřív, a selhání
      -- renderu nesmí udělat díru v řadě.
      pdf_status        = 'pending',$nove$);
    EXECUTE _def;
  END IF;

  _def := pg_get_functiondef('public.storno_invoice(uuid, text)'::regprocedure);
  IF position('pdf_status' in _def) = 0 THEN
    _def := replace(_def,
      $stare$      issued_at         = now(),
      issued_by         = _uid
   WHERE id = _opr;$stare$,
      $nove$      issued_at         = now(),
      issued_by         = _uid,
      pdf_status        = 'pending'   -- opravný doklad se posílá odběrateli, taky potřebuje PDF
   WHERE id = _opr;$nove$);
    EXECUTE _def;
  END IF;
END $$;

DO $$
BEGIN
  IF position('pdf_status' in pg_get_functiondef('public.issue_invoice(uuid)'::regprocedure)) = 0
     OR position('pdf_status' in pg_get_functiondef('public.storno_invoice(uuid, text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Vystavení/storno se nepodařilo napojit na frontu PDF — doklady by vznikaly bez PDF a nikdo by se to nedozvěděl.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 6) Privátní bucket `invoices`
--
-- PRIVÁTNÍ (rozhodnutí R7): doklad obsahuje jméno odběratele, adresu a částku.
-- Stahuje se přes podepsanou URL s krátkou platností, ne přes veřejný odkaz.
--
-- Klíč objektu je `{rok}/{číslo}/v{n}.pdf` — ASCII, bez diakritiky a bez identity
-- odběratele. Hezký název souboru se nastaví až parametrem `download` podepsané
-- URL, takže z cesty samotné se nedá vyčíst, komu doklad patří.
-- -----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('invoices', 'invoices', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE
  SET public = false,                       -- kdyby ho někdo omylem zveřejnil
      file_size_limit = 10485760,
      allowed_mime_types = ARRAY['application/pdf'];

-- Čte a zapisuje výhradně server (worker pod servisním klíčem). Admin se
-- k souboru dostane podepsanou URL, kterou mu vydá backend — ne přímým čtením
-- bucketu, aby přístup šel jedním auditovatelným místem.
DROP POLICY IF EXISTS invoices_bucket_service ON storage.objects;
CREATE POLICY invoices_bucket_service ON storage.objects
  FOR ALL TO service_role
  USING (bucket_id = 'invoices')
  WITH CHECK (bucket_id = 'invoices');

DO $$
DECLARE _verejny boolean;
BEGIN
  SELECT public INTO _verejny FROM storage.buckets WHERE id = 'invoices';
  IF _verejny IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Bucket `invoices` musí být privátní — jsou v něm jména, adresy a částky.';
  END IF;
  RAISE NOTICE 'Fronta PDF a privátní bucket `invoices` připravené.';
END $$;
