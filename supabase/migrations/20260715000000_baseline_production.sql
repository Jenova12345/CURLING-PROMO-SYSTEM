-- =============================================================================
-- BASELINE MIGRACE — Curling Ostrava / MladeKameny
-- =============================================================================
-- Projekt Supabase : MladeKameny (ref: fareavttiwkamrukpfqk) — PRODUKCE
-- Postgres         : 17.6
-- Schéma           : public
-- Datum            : 2026-07-15
--
-- CO TO JE:
-- Squashed baseline — jediný soubor, který popisuje PŘESNÝ stav produkční databáze
-- k 2026-07-15. Nahrazuje 19 historických Lovable migrací (přesunuty do
-- supabase/migrations/archive_lovable/, viz jejich README). Od teď je tento soubor
-- výchozí bod migrační historie; další změny schématu jdou jako NOVÉ migrace nad ním.
--
-- ZDROJ: rekonstruováno z živé DB přes Supabase MCP (read-only) — pg_catalog /
-- information_schema (pg_get_functiondef, pg_get_triggerdef, pg_get_constraintdef,
-- pg_indexes, pg_policies). Shodné s backups/2026-07-15/schema.sql.
--
-- POUŽITÍ: `supabase db reset` (lokálně) tímto souborem reprodukuje produkční schéma.
-- Na PRODUKCI se NEAPLIKUJE znovu — tam už schéma existuje; baseline se v cloudu
-- označí jako aplikovaný přes `supabase migration repair` (viz docs/STAV.md).
--
-- Pořadí: enum typy -> funkce -> tabulky -> constrainty -> indexy -> view
--         -> triggery -> RLS + politiky.
--
-- ⚠ NEÚPLNOST vůči kódu: baseline zachycuje SKUTEČNÝ (i nekonzistentní) stav produkce.
-- Známé nesoulady schéma vs. kód NEOPRAVUJEME zde — viz docs/SCHEMA_DRIFT.md.
--
-- POZNÁMKA: Trigger handle_new_user() je v živé DB navázán na auth.users (mimo schéma
-- public), takže není v sekci triggerů níže. Funkce samotná zde je; trigger na
-- auth.users je nutné při čisté obnově vytvořit ručně (viz docs/SCHEMA_DRIFT.md).
-- =============================================================================

-- Baseline zachovává pořadí z produkce (funkce před tabulkami). Funkce get_user_role
-- a has_role jsou LANGUAGE sql a odkazují public.user_roles, která vzniká později —
-- proto vypneme validaci těl funkcí při CREATE (přesně jako pg_dump), ať reset na
-- čisté DB projde bez chyby "relation does not exist". Za běhu se těla ověřují normálně.
SET check_function_bodies = false;

-- -----------------------------------------------------------------------------
-- 1) ENUM TYPY
-- -----------------------------------------------------------------------------

CREATE TYPE public.app_role AS ENUM (
  'admin', 'trainer', 'part_time_staff', 'pro_player', 'hobby_player',
  'instructor', 'bar_staff', 'manager'
);

CREATE TYPE public.event_type AS ENUM (
  'commercial', 'training', 'maintenance', 'recruitment'
);

CREATE TYPE public.shift_status AS ENUM (
  'open', 'pending', 'claimed', 'completed', 'cancelled'
);

-- -----------------------------------------------------------------------------
-- 2) FUNKCE
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_user_role(_user_id uuid)
 RETURNS app_role
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT role
  FROM public.user_roles
  WHERE user_id = _user_id
  ORDER BY
    CASE role
      WHEN 'admin' THEN 1
      WHEN 'trainer' THEN 2
      WHEN 'part_time_staff' THEN 3
      WHEN 'pro_player' THEN 4
      WHEN 'hobby_player' THEN 5
    END
  LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role app_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = _role
  )
$function$;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$;

-- Vytvoří profil + výchozí roli hobby_player při registraci uživatele.
-- (Trigger je navázán na auth.users — mimo schéma public.)
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Vytvoř profil
  INSERT INTO public.profiles (user_id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data ->> 'full_name');

  -- Přiřaď výchozí roli hobby_player
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'hobby_player');

  RETURN NEW;
END;
$function$;

-- Po vložení akce vygeneruje směny podle role_reqs (JSON) nebo required_staff.
CREATE OR REPLACE FUNCTION public.handle_new_commercial_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _role text;
  _count int;
  _i int;
  _total_created int := 0;
BEGIN
  -- Pokud je v akci vyplněn nový JSON rozpis (role_reqs), použijeme ten
  IF NEW.role_reqs IS NOT NULL AND NEW.role_reqs != '{}'::jsonb THEN

    -- Projdeme každou roli v JSONu (např. key='instructor', value=2)
    FOR _role, _count IN SELECT * FROM jsonb_each_text(NEW.role_reqs)
    LOOP
      IF _count > 0 THEN
        FOR _i IN 1.._count LOOP
          INSERT INTO public.shifts (event_id, status, required_role)
          VALUES (NEW.id, 'open', _role::public.app_role);
          _total_created := _total_created + 1;
        END LOOP;
      END IF;
    END LOOP;

  -- Pokud JSON není vyplněn, jedeme podle starého systému (pro zpětnou kompatibilitu)
  -- To platí hlavně pro 'commercial' a 'recruitment'
  ELSIF (NEW.event_type = 'commercial' OR NEW.event_type = 'recruitment') AND NEW.required_staff > 0 THEN
    FOR _i IN 1..NEW.required_staff LOOP
      -- Vytvoříme směnu bez specifické role (pro všechny)
      INSERT INTO public.shifts (event_id, status)
      VALUES (NEW.id, 'open');
    END LOOP;
  END IF;

  RETURN NEW;
END;
$function$;

-- Validace výplaty: rozsah částky + jen admin.
CREATE OR REPLACE FUNCTION public.validate_payout()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Validace částky
  IF NEW.amount < 1 OR NEW.amount > 1000000 THEN
    RAISE EXCEPTION 'Částka výplaty musí být mezi 1 a 1 000 000 Kč';
  END IF;

  -- Pouze admin může vytvářet výplaty
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Pouze admin může vytvářet výplaty';
  END IF;

  RETURN NEW;
END;
$function$;

-- Validace přechodu stavů směny (open/pending/claimed/completed) + práva.
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Validace hours_worked
  IF NEW.hours_worked IS NOT NULL THEN
    IF NEW.hours_worked < 0.1 OR NEW.hours_worked > 24 THEN
      RAISE EXCEPTION 'Hodiny musí být mezi 0.1 a 24';
    END IF;
  END IF;

  -- Validace hourly_rate
  IF NEW.hourly_rate IS NOT NULL THEN
    IF NEW.hourly_rate < 1 OR NEW.hourly_rate > 10000 THEN
      RAISE EXCEPTION 'Hodinová sazba musí být mezi 1 a 10000 Kč';
    END IF;
  END IF;

  -- Staff žádá o směnu (open -> pending)
  IF OLD.status = 'open' AND NEW.status = 'pending' THEN
    IF OLD.claimed_by IS NOT NULL THEN
      RAISE EXCEPTION 'Směna již byla obsazena';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.shifts
      WHERE event_id = NEW.event_id
        AND claimed_by = NEW.claimed_by
        AND id != NEW.id
        AND status IN ('pending', 'claimed', 'completed')
    ) THEN
      RAISE EXCEPTION 'Na této akci již máte jinou směnu';
    END IF;
  END IF;

  -- Admin schvaluje směnu (pending -> claimed)
  IF OLD.status = 'pending' AND NEW.status = 'claimed' THEN
    IF NOT has_role(auth.uid(), 'admin') THEN
      RAISE EXCEPTION 'Pouze admin může schválit směnu';
    END IF;
  END IF;

  -- Zamítnutí směny (pending -> open)
  IF OLD.status = 'pending' AND NEW.status = 'open' THEN
    IF NOT has_role(auth.uid(), 'admin') THEN
      IF OLD.claimed_by != auth.uid() THEN
        RAISE EXCEPTION 'Nemůžete zrušit cizí přihlášku';
      END IF;
    END IF;
  END IF;

  -- Zrušení schválené směny
  IF OLD.status = 'claimed' AND NEW.status = 'open' THEN
    IF OLD.claimed_by != auth.uid() AND NOT has_role(auth.uid(), 'admin') THEN
      RAISE EXCEPTION 'Nemůžete zrušit cizí směnu';
    END IF;
  END IF;

  -- Dokončení směny (claimed -> completed) - pouze admin
  IF OLD.status = 'claimed' AND NEW.status = 'completed' THEN
    IF NOT has_role(auth.uid(), 'admin') THEN
      RAISE EXCEPTION 'Pouze admin může dokončit směnu';
    END IF;

    IF NEW.hours_worked IS NULL OR NEW.hours_worked <= 0 THEN
      RAISE EXCEPTION 'Musíte zadat odpracované hodiny';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3) TABULKY
-- -----------------------------------------------------------------------------

CREATE TABLE public.profiles (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  full_name   text,
  phone       text,
  bank_account text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profiles_pkey PRIMARY KEY (id),
  CONSTRAINT profiles_user_id_key UNIQUE (user_id)
);

CREATE TABLE public.user_roles (
  id         uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL,
  role       public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_roles_pkey PRIMARY KEY (id),
  CONSTRAINT user_roles_user_id_role_key UNIQUE (user_id, role)
);

CREATE TABLE public.events (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  title         text NOT NULL,
  description   text,
  event_type    public.event_type NOT NULL DEFAULT 'commercial'::public.event_type,
  start_time    timestamptz NOT NULL,
  end_time      timestamptz NOT NULL,
  required_staff integer DEFAULT 0,
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  role_reqs     jsonb DEFAULT '{}'::jsonb,
  CONSTRAINT events_pkey PRIMARY KEY (id)
);

CREATE TABLE public.payouts (
  id         uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL,
  amount     numeric NOT NULL,
  notes      text,
  paid_at    timestamptz DEFAULT now(),
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT payouts_pkey PRIMARY KEY (id)
);

CREATE TABLE public.shifts (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  event_id    uuid NOT NULL,
  claimed_by  uuid,
  claimed_at  timestamptz,
  status      public.shift_status NOT NULL DEFAULT 'open'::public.shift_status,
  hours_worked numeric,
  hourly_rate numeric DEFAULT 150.00,
  completed_at timestamptz,
  payout_id   uuid,
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  required_role public.app_role,
  CONSTRAINT shifts_pkey PRIMARY KEY (id)
);

CREATE TABLE public.shift_applications (
  id         uuid NOT NULL DEFAULT gen_random_uuid(),
  shift_id   uuid NOT NULL,
  user_id    uuid NOT NULL,
  status     text NOT NULL DEFAULT 'pending'::text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shift_applications_pkey PRIMARY KEY (id),
  CONSTRAINT shift_applications_shift_id_user_id_key UNIQUE (shift_id, user_id),
  CONSTRAINT shift_applications_status_check CHECK (
    status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text])
  )
);

CREATE TABLE public.chat_groups (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  name                text NOT NULL,
  description         text,
  whatsapp_url        text NOT NULL,
  icon                text DEFAULT '💬'::text,
  icon_slug           text DEFAULT 'message-circle'::text,
  authorized_roles    public.app_role[] NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  visible_to_user_ids uuid[],
  CONSTRAINT chat_groups_pkey PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- 4) CIZÍ KLÍČE (přidané po vytvoření všech tabulek kvůli závislostem)
-- -----------------------------------------------------------------------------

ALTER TABLE public.payouts
  ADD CONSTRAINT payouts_user_id_fkey    FOREIGN KEY (user_id)    REFERENCES public.profiles(user_id),
  ADD CONSTRAINT payouts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(user_id);

ALTER TABLE public.shifts
  ADD CONSTRAINT shifts_event_id_fkey  FOREIGN KEY (event_id)  REFERENCES public.events(id) ON DELETE CASCADE,
  ADD CONSTRAINT shifts_payout_id_fkey FOREIGN KEY (payout_id) REFERENCES public.payouts(id);

ALTER TABLE public.shift_applications
  ADD CONSTRAINT shift_applications_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES public.shifts(id) ON DELETE CASCADE;

-- -----------------------------------------------------------------------------
-- 5) INDEXY (mimo těch vytvořených automaticky pro PK / UNIQUE)
-- -----------------------------------------------------------------------------

CREATE INDEX idx_events_event_type ON public.events USING btree (event_type);
CREATE INDEX idx_events_start_time ON public.events USING btree (start_time);

CREATE INDEX idx_payouts_paid_at ON public.payouts USING btree (paid_at);
CREATE INDEX idx_payouts_user_id ON public.payouts USING btree (user_id);

CREATE INDEX idx_profiles_user_id ON public.profiles USING btree (user_id);

CREATE INDEX idx_shifts_claimed_by ON public.shifts USING btree (claimed_by);
CREATE INDEX idx_shifts_event_id   ON public.shifts USING btree (event_id);
CREATE INDEX idx_shifts_payout_id  ON public.shifts USING btree (payout_id);
CREATE INDEX idx_shifts_status     ON public.shifts USING btree (status);

CREATE INDEX idx_user_roles_role    ON public.user_roles USING btree (role);
CREATE INDEX idx_user_roles_user_id ON public.user_roles USING btree (user_id);

-- -----------------------------------------------------------------------------
-- 6) VIEWS
-- -----------------------------------------------------------------------------

-- profiles_public: skrývá bank_account před všemi kromě vlastníka a admina.
CREATE OR REPLACE VIEW public.profiles_public AS
 SELECT id,
    user_id,
    full_name,
    phone,
        CASE
            WHEN auth.uid() = user_id THEN bank_account
            WHEN (EXISTS ( SELECT 1
               FROM user_roles ur
              WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role)) THEN bank_account
            ELSE NULL::text
        END AS bank_account,
    created_at,
    updated_at
   FROM profiles;

-- -----------------------------------------------------------------------------
-- 7) TRIGGERY (schéma public)
-- -----------------------------------------------------------------------------

CREATE TRIGGER update_chat_groups_updated_at BEFORE UPDATE ON public.chat_groups
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER create_shifts_for_commercial_event AFTER INSERT ON public.events
  FOR EACH ROW EXECUTE FUNCTION handle_new_commercial_event();

CREATE TRIGGER update_events_updated_at BEFORE UPDATE ON public.events
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER validate_payout_before_insert BEFORE INSERT ON public.payouts
  FOR EACH ROW EXECUTE FUNCTION validate_payout();

CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trg_updated_at_apps BEFORE UPDATE ON public.shift_applications
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_shifts_updated_at BEFORE UPDATE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER validate_shift_before_update BEFORE UPDATE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION validate_shift_claim();

-- -----------------------------------------------------------------------------
-- 8) ROW LEVEL SECURITY + POLITIKY
-- -----------------------------------------------------------------------------

ALTER TABLE public.profiles           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payouts            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shift_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_groups        ENABLE ROW LEVEL SECURITY;

-- ---- profiles ----
CREATE POLICY "Anyone authenticated can read profiles" ON public.profiles
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Users can insert own profile" ON public.profiles
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ---- user_roles ----
CREATE POLICY "Anyone authenticated can read all roles" ON public.user_roles
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Only admins can insert roles" ON public.user_roles
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can update roles" ON public.user_roles
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role))
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can delete roles" ON public.user_roles
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));

-- ---- events ----
CREATE POLICY "Anyone authenticated can read events" ON public.events
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Only admins can create events" ON public.events
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can update events" ON public.events
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role))
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can delete events" ON public.events
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));

-- ---- payouts ----
CREATE POLICY "Users can view own payouts and admins all" ON public.payouts
  FOR SELECT TO authenticated
  USING ((user_id = auth.uid()) OR (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role)));
CREATE POLICY "Only admins can create payouts" ON public.payouts
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can update payouts" ON public.payouts
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role))
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can delete payouts" ON public.payouts
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));

-- ---- shifts ----
CREATE POLICY "Anyone authenticated can read shifts" ON public.shifts
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "Staff and admins can view shifts" ON public.shifts
  FOR SELECT TO public
  USING (has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'part_time_staff'::app_role)
    OR has_role(auth.uid(), 'instructor'::app_role) OR has_role(auth.uid(), 'bar_staff'::app_role)
    OR has_role(auth.uid(), 'manager'::app_role) OR (claimed_by = auth.uid()));
CREATE POLICY "Only admins can create shifts" ON public.shifts
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Staff and admins can update shifts" ON public.shifts
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = ANY (ARRAY['admin'::app_role, 'part_time_staff'::app_role])))
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = ANY (ARRAY['admin'::app_role, 'part_time_staff'::app_role])));
CREATE POLICY "Staff can update shifts" ON public.shifts
  FOR UPDATE TO public
  USING (has_role(auth.uid(), 'admin'::app_role) OR has_role(auth.uid(), 'part_time_staff'::app_role)
    OR has_role(auth.uid(), 'instructor'::app_role) OR has_role(auth.uid(), 'bar_staff'::app_role)
    OR has_role(auth.uid(), 'manager'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role) OR ((has_role(auth.uid(), 'part_time_staff'::app_role)
    OR has_role(auth.uid(), 'instructor'::app_role) OR has_role(auth.uid(), 'bar_staff'::app_role)
    OR has_role(auth.uid(), 'manager'::app_role)) AND (((status = 'pending'::shift_status) AND (claimed_by = auth.uid()))
    OR ((status = 'completed'::shift_status) AND (claimed_by = auth.uid()))
    OR ((status = 'open'::shift_status) AND (claimed_by IS NULL)))));
CREATE POLICY "Only admins can delete shifts" ON public.shifts
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));

-- ---- shift_applications ----
CREATE POLICY "view own or admin" ON public.shift_applications
  FOR SELECT TO public
  USING ((user_id = auth.uid()) OR has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "user insert own" ON public.shift_applications
  FOR INSERT TO public
  WITH CHECK (user_id = auth.uid());
CREATE POLICY "user cancel own / admin update" ON public.shift_applications
  FOR UPDATE TO public
  USING ((user_id = auth.uid()) OR has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "admin delete" ON public.shift_applications
  FOR DELETE TO public
  USING (has_role(auth.uid(), 'admin'::app_role));

-- ---- chat_groups ----
CREATE POLICY "Users can view authorized groups" ON public.chat_groups
  FOR SELECT TO public
  USING (has_role(auth.uid(), 'admin'::app_role) OR (authorized_roles = '{}'::app_role[])
    OR (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = ANY (chat_groups.authorized_roles)))
    OR (auth.uid() = ANY (visible_to_user_ids)));
CREATE POLICY "Users see groups matching their highest role" ON public.chat_groups
  FOR SELECT TO authenticated
  USING ((EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role))
    OR (authorized_roles = '{}'::app_role[])
    OR ((SELECT ur.role FROM user_roles ur WHERE ur.user_id = auth.uid()
         ORDER BY CASE ur.role
           WHEN 'admin'::app_role THEN 1
           WHEN 'trainer'::app_role THEN 2
           WHEN 'part_time_staff'::app_role THEN 3
           WHEN 'pro_player'::app_role THEN 4
           WHEN 'hobby_player'::app_role THEN 5
           ELSE NULL::integer END
         LIMIT 1) = ANY (authorized_roles)));
CREATE POLICY "Only admins can create chat groups" ON public.chat_groups
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can update chat groups" ON public.chat_groups
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role))
  WITH CHECK (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));
CREATE POLICY "Only admins can delete chat groups" ON public.chat_groups
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = auth.uid() AND ur.role = 'admin'::app_role));

-- =============================================================================
-- KONEC ZÁLOHY SCHÉMATU
-- =============================================================================
