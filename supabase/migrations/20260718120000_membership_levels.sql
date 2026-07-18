-- =============================================================================
-- Dvě úrovně členství v klubu (zástupce vs člen) + přepis RLS/guard
-- =============================================================================
-- subject_reps.level:
--   'rep'    = zástupce klubu → vidí a edituje/stornuje VŠECHNY rezervace svého klubu
--   'member' = člen klubu     → vidí rezervace klubu, ale edituje/stornuje jen JÍM vytvořené
-- Každý přihlášený dál vidí obsazenost celého kalendáře přes maskovaný view (nezměněno).
-- Cizí klub/firma: nikdo (ani zástupce) nevidí detail ani needituje.
-- Lokální vývoj; na produkci se NEAPLIKUJE bez zálohy a souhlasu PM.
-- =============================================================================

CREATE TYPE public.subject_rep_level AS ENUM ('rep', 'member');

-- Nové napojení je default 'member'; existující (pokud by nějaká byla) povýšíme na 'rep'.
ALTER TABLE public.subject_reps
  ADD COLUMN level public.subject_rep_level NOT NULL DEFAULT 'member';
UPDATE public.subject_reps SET level = 'rep';

-- -----------------------------------------------------------------------------
-- Helpery
-- -----------------------------------------------------------------------------
-- Jakékoli napojení (rep i member) na ne-smazaný subjekt → „vidí detail svého klubu".
CREATE OR REPLACE FUNCTION public.is_subject_member(_subject uuid)
 RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.subject_reps sr
    JOIN public.subjects s ON s.id = sr.subject_id
    WHERE sr.subject_id = _subject AND sr.user_id = auth.uid() AND s.deleted_at IS NULL
  );
$$;

-- Napojení úrovně 'rep' → „plná editace klubu".
CREATE OR REPLACE FUNCTION public.is_subject_rep(_subject uuid)
 RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.subject_reps sr
    JOIN public.subjects s ON s.id = sr.subject_id
    WHERE sr.subject_id = _subject AND sr.user_id = auth.uid()
      AND sr.level = 'rep' AND s.deleted_at IS NULL
  );
$$;

-- -----------------------------------------------------------------------------
-- RLS: reservations + subjects (přepis podle úrovní)
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "reservations_select" ON public.reservations;
CREATE POLICY "reservations_select" ON public.reservations
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin') OR (deleted_at IS NULL AND public.is_subject_member(subject_id)));

DROP POLICY IF EXISTS "reservations_insert" ON public.reservations;
CREATE POLICY "reservations_insert" ON public.reservations
  FOR INSERT TO authenticated
  WITH CHECK (has_role(auth.uid(), 'admin') OR public.is_subject_member(subject_id));

DROP POLICY IF EXISTS "reservations_update" ON public.reservations;
CREATE POLICY "reservations_update" ON public.reservations
  FOR UPDATE TO authenticated
  USING (
    has_role(auth.uid(), 'admin')
    OR public.is_subject_rep(subject_id)
    OR (public.is_subject_member(subject_id) AND created_by = auth.uid())
  )
  WITH CHECK (
    has_role(auth.uid(), 'admin')
    OR public.is_subject_rep(subject_id)
    OR (public.is_subject_member(subject_id) AND created_by = auth.uid())
  );

DROP POLICY IF EXISTS "subjects_select" ON public.subjects;
CREATE POLICY "subjects_select" ON public.subjects
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin') OR (deleted_at IS NULL AND public.is_subject_member(id)));

-- -----------------------------------------------------------------------------
-- Guard: ne-admin smí editovat (ne jen stornovat) rezervace, ke kterým má přes RLS
-- přístup — ale NESMÍ měnit subjekt, vazbu na akci, sazbu ani korekce (to je adminské).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_reservation_rep_changes()
 RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF has_role(auth.uid(), 'admin') THEN
    RETURN NEW;  -- admin: bez omezení
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- zástupce i člen zakládají jen čistě klubovou rezervaci; nic nepodvrhnou
    NEW.created_by        := auth.uid();
    NEW.status            := 'confirmed';
    NEW.deleted_at        := NULL;
    NEW.event_id          := NULL;
    NEW.rate_per_hour     := NULL;   -- sazbu dopočítá pricing z ceníku
    NEW.corrected_hours   := NULL;
    NEW.corrected_amount  := NULL;
    NEW.correction_reason := NULL;
    RETURN NEW;
  END IF;

  -- UPDATE: přístup k řádku hlídá RLS (rep = celý klub, člen = jen created_by=self).
  -- Guard hlídá jen to, co ne-admin NESMÍ změnit.
  IF NOT public.is_subject_member(OLD.subject_id) THEN
    RAISE EXCEPTION 'Nemáte právo měnit tuto rezervaci';
  END IF;
  IF NEW.subject_id       IS DISTINCT FROM OLD.subject_id
     OR NEW.event_id      IS DISTINCT FROM OLD.event_id
     OR NEW.created_by    IS DISTINCT FROM OLD.created_by   -- autora nelze přepsat (audit)
     OR NEW.rate_per_hour IS DISTINCT FROM OLD.rate_per_hour
     OR NEW.corrected_hours   IS DISTINCT FROM OLD.corrected_hours
     OR NEW.corrected_amount  IS DISTINCT FROM OLD.corrected_amount
     OR NEW.correction_reason IS DISTINCT FROM OLD.correction_reason
     OR NEW.deleted_at    IS DISTINCT FROM OLD.deleted_at THEN
    RAISE EXCEPTION 'Sazbu, subjekt, autora a vazby smí měnit jen správce';
  END IF;
  -- povoleno: sheet_id, start_at, end_at, note, status (storno confirmed->cancelled)
  RETURN NEW;
END;
$$;
