-- =============================================================================
-- C5 — stav PDF na obrazovce + opakování neúspěšného renderu
-- =============================================================================
-- Admin musí ze seznamu poznat tři různé situace, které dnes vypadají stejně
-- („není odkaz ke stažení"):
--   * PDF se teprve generuje — počkej,
--   * generování selhalo — je co řešit,
--   * doklad PDF nemá a mít nebude (koncept).
--
-- Bez toho by první pomalý render vypadal jako rozbitá aplikace.
--
-- FALLBACK ZŮSTÁVÁ: tisk z obrazovky se neruší, dokud si serverový render
-- neproklikáme naživo (rozhodnutí PM 18. 8. 2026). Doklad musí jít dostat ven
-- i ve chvíli, kdy fronta stojí.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Stav PDF do seznamu dokladů
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.invoices_list;
CREATE VIEW public.invoices_list WITH (security_invoker = on) AS
  SELECT i.id,
         i.cislo,
         i.variabilni_symbol,
         i.kind,
         i.status,
         i.subject_id,
         COALESCE(i.odberatel_nazev, s.name) AS odberatel,
         i.obdobi_od,
         i.obdobi_do,
         i.datum_vystaveni,
         i.datum_splatnosti,
         i.datum_uhrady,
         i.subtotal,
         i.total,
         i.total_rounded,
         i.pdf_path,
         (SELECT count(*) FROM public.invoice_items it WHERE it.invoice_id = i.id) AS polozek,
         i.status = 'vystaveno'::invoice_status
           AND i.datum_splatnosti < (now() AT TIME ZONE 'Europe/Prague')::date AS po_splatnosti,
         i.created_at,
         i.issued_at,
         i.opravuje_id,
         i.storno_duvod,
         (SELECT p.cislo FROM public.invoices p WHERE p.id = i.opravuje_id) AS opravuje_cislo,
         (SELECT o.cislo FROM public.invoices o WHERE o.opravuje_id = i.id)  AS stornovan_dokladem,
         -- Fronta PDF. `pdf_error` se vydává schválně: když render selže,
         -- admin má vidět PROČ, ne jen že se to nepovedlo.
         i.pdf_status,
         i.pdf_attempts,
         i.pdf_error
    FROM public.invoices i
    LEFT JOIN public.subjects s ON s.id = i.subject_id;

REVOKE ALL ON public.invoices_list FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.invoices_list TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) Opakování renderu na vyžádání
--
-- Po pěti pokusech se fronta zastaví a čeká na člověka (typicky je potřeba
-- opravit fakturační nastavení). Tohle je to tlačítko, kterým se rozjede znovu.
-- Počítadlo se nuluje: je to nový pokus po zásahu, ne pokračování starého.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retry_invoice_pdf(_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _stav public.invoice_status;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Generování dokladů řídí jen správce haly.';
  END IF;

  SELECT status INTO _stav FROM public.invoices WHERE id = _invoice_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Doklad neexistuje.';
  END IF;
  IF _stav = 'koncept' THEN
    RAISE EXCEPTION 'Koncept PDF nemá — vystav ho nejdřív.';
  END IF;

  UPDATE public.invoices
     SET pdf_status = 'pending', pdf_attempts = 0, pdf_error = NULL, pdf_claimed_at = NULL
   WHERE id = _invoice_id;
END;
$$;

REVOKE ALL ON FUNCTION public.retry_invoice_pdf(uuid) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.retry_invoice_pdf(uuid) TO authenticated;

COMMENT ON FUNCTION public.retry_invoice_pdf(uuid) IS
  'Vrátí doklad do fronty na PDF a vynuluje počítadlo pokusů. Pro případ, kdy render pětkrát selhal a admin mezitím opravil příčinu.';
