-- =============================================================================
-- Sjednocený kalendář ledu (varianta A) — DB vrstva
-- =============================================================================
-- reservations = jediný zdroj pravdy o obsazenosti ledu (na plátně, exclusion constraint).
-- events + shifts = vrstva štábu, navázaná na rezervaci přes reservations.event_id.
--   • klubová rezervace  → jen reservations (event_id NULL, subject = klub)
--   • komerční rezervace → events(commercial)→trigger→shifts + reservations(event_id, subject=komerční)
--   • interní (trénink/údržba) → events(training/maintenance) + reservations(event_id, subject NULL)
-- Vše se vyvíjí a ověřuje LOKÁLNĚ; na produkci se NEAPLIKUJE bez zálohy a souhlasu PM.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Vazba rezervace → akce
-- -----------------------------------------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN event_id uuid REFERENCES public.events(id) ON DELETE SET NULL;

-- 1 akce ↔ nejvýš 1 živá rezervace (aby storno nerušilo směny akce, kterou drží jiná rezervace).
CREATE UNIQUE INDEX idx_reservations_event ON public.reservations (event_id)
  WHERE event_id IS NOT NULL AND deleted_at IS NULL;

-- Interní rezervace (trénink/údržba) nemá fakturační subjekt → subject_id smí být NULL,
-- ale každá rezervace musí mít aspoň jedno z (subject_id, event_id).
ALTER TABLE public.reservations ALTER COLUMN subject_id DROP NOT NULL;
ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_subject_or_event CHECK (subject_id IS NOT NULL OR event_id IS NOT NULL);

-- -----------------------------------------------------------------------------
-- 2) Pricing: interní rezervace (bez subjektu) se neúčtuje
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_reservation_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE
  _rate numeric;
BEGIN
  -- Interní rezervace (bez fakturačního subjektu) se neúčtuje: bez sazby a částky.
  IF NEW.subject_id IS NULL THEN
    NEW.rate_per_hour    := NULL;
    NEW.amount           := NULL;
    NEW.corrected_amount := NULL;
    NEW.hours := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    RETURN NEW;
  END IF;

  -- Snapshot sazby jen při vzniku; pozdější změna ceníku nepřepočítává minulé.
  IF TG_OP = 'INSERT' AND NEW.rate_per_hour IS NULL THEN
    SELECT COALESCE(s.default_rate,
             CASE s.type WHEN 'club' THEN st.club_default_rate
                         ELSE st.commercial_default_rate END)
      INTO _rate
      FROM public.subjects s, public.settings st
      WHERE s.id = NEW.subject_id;
    IF _rate IS NULL THEN
      RAISE EXCEPTION 'Sazba není nastavena — admin musí nejdřív vyplnit ceník (settings) nebo default_rate subjektu';
    END IF;
    NEW.rate_per_hour := _rate;
  END IF;

  IF NEW.rate_per_hour IS NULL THEN
    RAISE EXCEPTION 'Sazba (rate_per_hour) nesmí zůstat prázdná';
  END IF;

  NEW.hours  := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
  NEW.amount := round(NEW.hours * NEW.rate_per_hour, 2);
  NEW.corrected_amount := CASE
    WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
    ELSE NULL END;

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3) Guard: ne-admin (zástupce) smí jen klubovou rezervaci — žádná vazba na akci
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_reservation_rep_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF has_role(auth.uid(), 'admin') THEN
    RETURN NEW;  -- admin: bez omezení (komerční/interní vazby, korekce, storno)
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Zástupce zakládá jen čistě klubovou rezervaci; nesmí podvrhnout autora/stav/cenu
    -- ani navázat akci (komerční/interní tvoří jen admin).
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

  -- TG_OP = 'UPDATE': zástupce smí jen stornovat vlastní rezervaci
  IF NOT public.is_subject_rep(OLD.subject_id) THEN
    RAISE EXCEPTION 'Nemáte právo měnit tuto rezervaci';
  END IF;

  IF NEW.sheet_id       IS DISTINCT FROM OLD.sheet_id
     OR NEW.subject_id  IS DISTINCT FROM OLD.subject_id
     OR NEW.event_id    IS DISTINCT FROM OLD.event_id
     OR NEW.start_at    IS DISTINCT FROM OLD.start_at
     OR NEW.end_at      IS DISTINCT FROM OLD.end_at
     OR NEW.rate_per_hour   IS DISTINCT FROM OLD.rate_per_hour
     OR NEW.corrected_hours IS DISTINCT FROM OLD.corrected_hours
     OR NEW.correction_reason IS DISTINCT FROM OLD.correction_reason
     OR NEW.deleted_at  IS DISTINCT FROM OLD.deleted_at THEN
    RAISE EXCEPTION 'Zástupce klubu smí rezervaci pouze stornovat, ne měnit její obsah';
  END IF;

  IF NOT (OLD.status = 'confirmed' AND NEW.status = 'cancelled') THEN
    RAISE EXCEPTION 'Zástupce klubu smí provést pouze storno (confirmed -> cancelled)';
  END IF;

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) Storno rezervace navázané na akci → zruš jen VOLNÉ směny (obsazené nech = historie)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_open_shifts_on_reservation_cancel()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  -- Pokryje storno (confirmed→cancelled) i soft-delete (deleted_at nově vyplněné).
  IF NEW.event_id IS NOT NULL
     AND (
       (OLD.status = 'confirmed' AND NEW.status = 'cancelled')
       OR (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
     ) THEN
    UPDATE public.shifts
       SET status = 'cancelled'
     WHERE event_id = NEW.event_id
       AND status IN ('open', 'pending');   -- volné i nepotvrzené žádosti se uvolní
    -- claimed/completed směny záměrně ZŮSTÁVAJÍ (historie výplat); admin je řeší ručně.
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_reservations_cancel_shifts AFTER UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.cancel_open_shifts_on_reservation_cancel();

-- -----------------------------------------------------------------------------
-- 5) Zpřísnění RLS na shifts: běžný člen bez role už směny NEVIDÍ
-- -----------------------------------------------------------------------------
-- Dnes existují dvě permisivní SELECT politiky; ta první ("USING (true)") pouští směny
-- KAŽDÉMU přihlášenému. Zrušíme ji — zůstane politika "Staff and admins can view shifts"
--   (admin OR part_time_staff/instructor/bar_staff/manager OR claimed_by = auth.uid()),
-- takže brigádník i admin vidí směny beze změny, běžný člen bez role je neuvidí.
DROP POLICY IF EXISTS "Anyone authenticated can read shifts" ON public.shifts;

-- Pozn.: migrace je forward-only (Supabase styl), bez DOWN. Zpětné vrácení = revert přes git
-- + re-přidání subject_id NOT NULL by vyžadovalo, aby neexistovaly interní rezervace (subject NULL).
