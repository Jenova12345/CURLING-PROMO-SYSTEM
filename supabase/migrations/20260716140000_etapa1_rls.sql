-- =============================================================================
-- Etapa 1 / krok 1 — RLS, maskovací view, guard trigger
-- =============================================================================
-- Přístup: admin (Jakub) = vše; zástupce klubu = jen svůj klub; nikdo nepřihlášený.
-- Zástupci vidí obsazenost cizích slotů (aby nedvojrezervovali), ale NE identitu ani
-- částky cizích klubů — přes maskovací view reservations_calendar.
-- =============================================================================

-- Pomocná funkce: je přihlášený uživatel zástupcem daného subjektu? (vzor has_role)
CREATE OR REPLACE FUNCTION public.is_subject_rep(_subject uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  -- zástupce = existuje napojení a klub NENÍ soft-smazaný
  SELECT EXISTS (
    SELECT 1
    FROM public.subject_reps sr
    JOIN public.subjects s ON s.id = sr.subject_id
    WHERE sr.subject_id = _subject
      AND sr.user_id = auth.uid()
      AND s.deleted_at IS NULL
  );
$$;

-- -----------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- -----------------------------------------------------------------------------
ALTER TABLE public.subjects      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subject_reps  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sheets        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settings      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log     ENABLE ROW LEVEL SECURITY;

-- ---- subjects ----
CREATE POLICY "subjects_select" ON public.subjects
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin') OR (deleted_at IS NULL AND public.is_subject_rep(id)));
CREATE POLICY "subjects_insert_admin" ON public.subjects
  FOR INSERT TO authenticated WITH CHECK (has_role(auth.uid(), 'admin'));
CREATE POLICY "subjects_update_admin" ON public.subjects
  FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'admin')) WITH CHECK (has_role(auth.uid(), 'admin'));
-- (žádné DELETE — jen soft-delete přes deleted_at)

-- ---- subject_reps ----
CREATE POLICY "subject_reps_select" ON public.subject_reps
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin') OR user_id = auth.uid());
CREATE POLICY "subject_reps_insert_admin" ON public.subject_reps
  FOR INSERT TO authenticated WITH CHECK (has_role(auth.uid(), 'admin'));
CREATE POLICY "subject_reps_update_admin" ON public.subject_reps
  FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'admin')) WITH CHECK (has_role(auth.uid(), 'admin'));
CREATE POLICY "subject_reps_delete_admin" ON public.subject_reps
  FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'));

-- ---- sheets (čte každý přihlášený, spravuje admin) ----
CREATE POLICY "sheets_select" ON public.sheets
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "sheets_insert_admin" ON public.sheets
  FOR INSERT TO authenticated WITH CHECK (has_role(auth.uid(), 'admin'));
CREATE POLICY "sheets_update_admin" ON public.sheets
  FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'admin')) WITH CHECK (has_role(auth.uid(), 'admin'));

-- ---- reservations ----
-- Plné řádky vidí admin (vše) a zástupce jen svého subjektu. Obsazenost cizích
-- slotů řeší view reservations_calendar níže.
CREATE POLICY "reservations_select" ON public.reservations
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin') OR (deleted_at IS NULL AND public.is_subject_rep(subject_id)));
CREATE POLICY "reservations_insert" ON public.reservations
  FOR INSERT TO authenticated
  WITH CHECK (has_role(auth.uid(), 'admin') OR public.is_subject_rep(subject_id));
CREATE POLICY "reservations_update" ON public.reservations
  FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'admin') OR public.is_subject_rep(subject_id))
  WITH CHECK (has_role(auth.uid(), 'admin') OR public.is_subject_rep(subject_id));
-- (žádné DELETE — storno = status cancelled, mazání = soft přes deleted_at adminem)

-- ---- settings (čte každý přihlášený — sazby/doba nejsou citlivé; mění admin) ----
CREATE POLICY "settings_select" ON public.settings
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "settings_update_admin" ON public.settings
  FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'admin')) WITH CHECK (has_role(auth.uid(), 'admin'));

-- ---- audit_log (čte jen admin; zapisuje jen SECURITY DEFINER trigger) ----
CREATE POLICY "audit_log_select_admin" ON public.audit_log
  FOR SELECT TO authenticated USING (has_role(auth.uid(), 'admin'));

-- -----------------------------------------------------------------------------
-- GUARD: co smí ne-admin (zástupce klubu) na rezervaci — admin smí vše
--   INSERT: zakládat smí (RLS hlídá jeho klub), ale nesmí podvrhnout autora,
--           stav, cenu ani korekce (ochrana auditu i fakturace).
--   UPDATE: smí POUZE stornovat vlastní rezervaci (confirmed -> cancelled).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_reservation_rep_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF has_role(auth.uid(), 'admin') THEN
    RETURN NEW;  -- admin: bez omezení (korekce, přeobsazení, soft-delete)
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Ne-admin nesmí při zakládání podvrhnout autora/stav/cenu/korekce.
    -- (Že subjekt patří jeho klubu, vynucuje RLS WITH CHECK.)
    NEW.created_by        := auth.uid();
    NEW.status            := 'confirmed';
    NEW.deleted_at        := NULL;
    NEW.rate_per_hour     := NULL;   -- sazbu dopočítá pricing trigger z ceníku
    NEW.corrected_hours   := NULL;   -- korekce jsou výhradně adminské
    NEW.corrected_amount  := NULL;
    NEW.correction_reason := NULL;
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF NOT public.is_subject_rep(OLD.subject_id) THEN
    RAISE EXCEPTION 'Nemáte právo měnit tuto rezervaci';
  END IF;

  IF NEW.sheet_id       IS DISTINCT FROM OLD.sheet_id
     OR NEW.subject_id  IS DISTINCT FROM OLD.subject_id
     OR NEW.start_at    IS DISTINCT FROM OLD.start_at
     OR NEW.end_at      IS DISTINCT FROM OLD.end_at
     OR NEW.rate_per_hour   IS DISTINCT FROM OLD.rate_per_hour
     OR NEW.corrected_hours IS DISTINCT FROM OLD.corrected_hours
     OR NEW.correction_reason IS DISTINCT FROM OLD.correction_reason  -- korekce jsou adminské
     OR NEW.deleted_at  IS DISTINCT FROM OLD.deleted_at THEN
    RAISE EXCEPTION 'Zástupce klubu smí rezervaci pouze stornovat, ne měnit její obsah';
  END IF;

  IF NOT (OLD.status = 'confirmed' AND NEW.status = 'cancelled') THEN
    RAISE EXCEPTION 'Zástupce klubu smí provést pouze storno (confirmed -> cancelled)';
  END IF;

  RETURN NEW;
END;
$$;

-- Název začíná „a_", aby guard běžel PŘED pricing/updated triggery (abecední pořadí).
CREATE TRIGGER trg_reservations_a_guard BEFORE INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.guard_reservation_rep_changes();

-- -----------------------------------------------------------------------------
-- MASKOVACÍ VIEW: obsazenost pro kalendář (bez identity a částek cizích klubů)
-- -----------------------------------------------------------------------------
-- security_invoker = off (běží s právy vlastníka, obchází RLS na reservations),
-- ale ZÁMĚRNĚ vystavuje jen necitlivé sloupce (plátno + čas + stav), aby každý
-- přihlášený viděl, které sloty jsou obsazené, a nemohl je dvojrezervovat.
CREATE VIEW public.reservations_calendar
  WITH (security_invoker = off) AS
  SELECT sheet_id, start_at, end_at, status
  FROM public.reservations
  WHERE status = 'confirmed' AND deleted_at IS NULL;

-- Přístup jen pro přihlášené (spec: „nikdo nepřihlášený"). View obchází RLS (definer),
-- proto explicitně odebrat výchozí granty pro anon/public a povolit jen authenticated.
REVOKE ALL ON public.reservations_calendar FROM anon, public;
GRANT SELECT ON public.reservations_calendar TO authenticated;
