-- =============================================================================
-- Etapa 1 / krok 1 — SCHÉMA rezervací + audit
-- =============================================================================
-- Nové tabulky pro rezervační systém ledu (subjects, subject_reps, sheets,
-- reservations, settings, audit_log) + triggery (výpočet ceny/hodin, audit
-- sloupce, audit_log) + soft-delete + reference data (2 plátna, default settings).
-- RLS je v samostatné migraci (…_etapa1_rls.sql). Nic ze stávajícího schématu nemaže.
-- Vše read-only vůči produkci — vyvíjeno a ověřeno na lokálním Supabase.
-- =============================================================================

-- btree_gist: umožní v exclusion constraintu porovnávat sheet_id (uuid) přes "="
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- -----------------------------------------------------------------------------
-- ENUM TYPY
-- -----------------------------------------------------------------------------
CREATE TYPE public.subject_type AS ENUM ('club', 'commercial');
CREATE TYPE public.reservation_status AS ENUM ('confirmed', 'cancelled');

-- -----------------------------------------------------------------------------
-- TABULKY
-- -----------------------------------------------------------------------------

-- Fakturační subjekty: kluby (rezervují si samy) a komerční zákazníci (zadává admin).
CREATE TABLE public.subjects (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type          public.subject_type NOT NULL,
  name          text NOT NULL,
  ico           text,
  dic           text,
  address       text,
  default_rate  numeric(10,2),                       -- override sazby pro subjekt (Kč/h)
  created_by    uuid DEFAULT auth.uid() REFERENCES public.profiles(user_id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid REFERENCES public.profiles(user_id),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

-- Napojení přihlášeného uživatele (zástupce) na klub, za který smí rezervovat.
CREATE TABLE public.subject_reps (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id  uuid NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
  created_by  uuid DEFAULT auth.uid() REFERENCES public.profiles(user_id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subject_id, user_id)
);

-- Plátna (led). Naplněno 2 řádky níže (reference data).
CREATE TABLE public.sheets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Rezervace. rate_per_hour = snapshot sazby v době vzniku (pozdější změna ceníku
-- nemění minulé rezervace). hours/amount počítá trigger. Kolize řeší exclusion constraint.
CREATE TABLE public.reservations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sheet_id          uuid NOT NULL REFERENCES public.sheets(id),
  subject_id        uuid NOT NULL REFERENCES public.subjects(id),
  start_at          timestamptz NOT NULL,
  end_at            timestamptz NOT NULL,
  status            public.reservation_status NOT NULL DEFAULT 'confirmed',
  rate_per_hour     numeric(10,2),                    -- doplní trigger, pokud NULL
  hours             numeric(6,2),                     -- počítá trigger
  amount            numeric(12,2),                    -- počítá trigger
  corrected_hours   numeric(6,2),                     -- volitelná ruční korekce (admin)
  corrected_amount  numeric(12,2),                    -- počítá trigger z corrected_hours
  correction_reason text,
  note              text,
  created_by        uuid DEFAULT auth.uid() REFERENCES public.profiles(user_id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        uuid REFERENCES public.profiles(user_id),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT reservations_time_valid CHECK (end_at > start_at),
  -- Zákaz překryvu na stejném plátně pro platné (confirmed, ne-smazané) rezervace.
  CONSTRAINT reservations_no_overlap EXCLUDE USING gist (
    sheet_id WITH =,
    tstzrange(start_at, end_at) WITH &&
  ) WHERE (status = 'confirmed' AND deleted_at IS NULL)
);

-- Konfigurace (jeden řádek — singleton). Sazby + otevírací doba (jsonb po dnech týdne).
CREATE TABLE public.settings (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton                boolean NOT NULL DEFAULT true UNIQUE,
  club_default_rate        numeric(10,2),             -- Kč/h; NULL = admin nastaví ceník
  commercial_default_rate  numeric(10,2),             -- Kč/h; NULL = admin nastaví ceník
  opening_hours            jsonb NOT NULL,            -- {"1":{"open":"08:00","close":"22:00"}, …} (1=Po … 7=Ne)
  updated_by               uuid REFERENCES public.profiles(user_id),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT settings_singleton CHECK (singleton = true)
);

-- Audit log — plněn triggery na reservations, subjects, settings.
CREATE TABLE public.audit_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name  text NOT NULL,
  record_id   uuid,
  action      text NOT NULL,               -- insert | update | delete | override
  changed_by  uuid,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  old_data    jsonb,
  new_data    jsonb
);

-- -----------------------------------------------------------------------------
-- INDEXY
-- -----------------------------------------------------------------------------
CREATE INDEX idx_reservations_sheet_start ON public.reservations (sheet_id, start_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_reservations_subject     ON public.reservations (subject_id)          WHERE deleted_at IS NULL;
CREATE INDEX idx_reservations_start       ON public.reservations (start_at)            WHERE deleted_at IS NULL;
CREATE INDEX idx_subject_reps_user        ON public.subject_reps (user_id);
CREATE INDEX idx_subjects_type            ON public.subjects (type)                    WHERE deleted_at IS NULL;
CREATE INDEX idx_audit_log_table_record   ON public.audit_log (table_name, record_id);

-- -----------------------------------------------------------------------------
-- FUNKCE + TRIGGERY
-- -----------------------------------------------------------------------------

-- Výpočet ceny/hodin. Snapshot sazby jen při vzniku (INSERT); pozdější změna ceníku
-- nepřepočítává minulé rezervace. Sazba: subjects.default_rate ?? default podle typu.
CREATE OR REPLACE FUNCTION public.set_reservation_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE
  _rate numeric;
BEGIN
  -- Pozn.: ne-adminovi vynuluje sazbu/korekce už guard trigger (trg_reservations_a_guard),
  -- který běží dřív; tady se sazba jen dopočítá z ceníku a spočítají hodiny/částka.
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

  -- Sazba nesmí zůstat prázdná ani po UPDATE (backstop proti tichému NULL v amount).
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

-- Nastaví updated_by/updated_at (rozšíření vzoru update_updated_at_column z baseline).
CREATE OR REPLACE FUNCTION public.set_updated_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  NEW.updated_by := auth.uid();
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- Generický zápis do audit_log. SECURITY DEFINER, aby zápis prošel i pod RLS.
CREATE OR REPLACE FUNCTION public.write_audit_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _rec_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN _rec_id := OLD.id; ELSE _rec_id := NEW.id; END IF;
  INSERT INTO public.audit_log (table_name, record_id, action, changed_by, old_data, new_data)
  VALUES (
    TG_TABLE_NAME, _rec_id, lower(TG_OP), auth.uid(),
    CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) ELSE NULL END
  );
  RETURN NULL;  -- AFTER trigger, návratová hodnota se ignoruje
END;
$$;

-- reservations: pricing (BEFORE) + updated fields (BEFORE) + audit (AFTER)
CREATE TRIGGER trg_reservations_pricing BEFORE INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_reservation_pricing();
CREATE TRIGGER trg_reservations_updated BEFORE INSERT OR UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_fields();
CREATE TRIGGER trg_reservations_audit AFTER INSERT OR UPDATE OR DELETE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- subjects: updated fields (BEFORE) + audit (AFTER)
CREATE TRIGGER trg_subjects_updated BEFORE INSERT OR UPDATE ON public.subjects
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_fields();
CREATE TRIGGER trg_subjects_audit AFTER INSERT OR UPDATE OR DELETE ON public.subjects
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- settings: updated fields (BEFORE) + audit (AFTER)
CREATE TRIGGER trg_settings_updated BEFORE INSERT OR UPDATE ON public.settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_fields();
CREATE TRIGGER trg_settings_audit AFTER INSERT OR UPDATE OR DELETE ON public.settings
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- subject_reps: audit (AFTER) — „kdo koho zmocnil rezervovat za klub" musí být dohledatelné
CREATE TRIGGER trg_subject_reps_audit AFTER INSERT OR UPDATE OR DELETE ON public.subject_reps
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- -----------------------------------------------------------------------------
-- REFERENCE DATA (potřebné i v produkci)
-- -----------------------------------------------------------------------------

-- 2 plátna
INSERT INTO public.sheets (name) VALUES ('Plátno 1'), ('Plátno 2');

-- Singleton settings: default otevírací doba 08:00–22:00 (Po–Ne). Sazby zatím NULL
-- (ceník od zákazníka nemáme — admin doplní přes obrazovku Nastavení).
INSERT INTO public.settings (club_default_rate, commercial_default_rate, opening_hours)
VALUES (
  NULL, NULL,
  '{"1":{"open":"08:00","close":"22:00"},
    "2":{"open":"08:00","close":"22:00"},
    "3":{"open":"08:00","close":"22:00"},
    "4":{"open":"08:00","close":"22:00"},
    "5":{"open":"08:00","close":"22:00"},
    "6":{"open":"08:00","close":"22:00"},
    "7":{"open":"08:00","close":"22:00"}}'::jsonb
);
