-- =====================================================
-- MLADÉ KAMENY - FINÁLNÍ PRODUKČNÍ MIGRACE
-- =====================================================
-- Verze: 2.0 (Production Ready)
-- Datum: 2025-01
-- 
-- INSTRUKCE:
-- 1. Spusť tento skript na PRÁZDNÉ Supabase databázi
-- 2. Po spuštění nastav admina pomocí SQL příkazu v sekci na konci
-- 3. Aplikace by měla fungovat okamžitě bez dalších úprav
-- =====================================================

-- =====================================================
-- 1. ENUM TYPY
-- =====================================================

CREATE TYPE public.app_role AS ENUM (
  'admin',
  'trainer', 
  'part_time_staff',
  'pro_player',
  'hobby_player'
);

CREATE TYPE public.event_type AS ENUM (
  'commercial',
  'training',
  'maintenance'
);

CREATE TYPE public.shift_status AS ENUM (
  'open',
  'pending',
  'claimed',
  'completed',
  'cancelled'
);

-- =====================================================
-- 2. TABULKY
-- =====================================================

-- PROFILES - uživatelské profily
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE,
  full_name TEXT,
  phone TEXT,
  bank_account TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- USER_ROLES - role uživatelů (oddělená tabulka pro bezpečnost)
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  role public.app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, role)
);

-- EVENTS - akce/události
CREATE TABLE public.events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT,
  event_type public.event_type NOT NULL DEFAULT 'commercial',
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  required_staff INTEGER DEFAULT 0,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- SHIFTS - směny
CREATE TABLE public.shifts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  claimed_by UUID,
  claimed_at TIMESTAMPTZ,
  status public.shift_status NOT NULL DEFAULT 'open',
  hours_worked NUMERIC,
  hourly_rate NUMERIC DEFAULT 150.00,
  completed_at TIMESTAMPTZ,
  payout_id UUID,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- PAYOUTS - výplaty
CREATE TABLE public.payouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  amount NUMERIC NOT NULL,
  notes TEXT,
  paid_at TIMESTAMPTZ DEFAULT now(),
  created_by UUID,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- CHAT_GROUPS - WhatsApp skupiny
CREATE TABLE public.chat_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  whatsapp_url TEXT NOT NULL,
  icon TEXT DEFAULT '💬',
  icon_slug TEXT DEFAULT 'message-circle',
  authorized_roles public.app_role[] NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Foreign keys pro shifts a payouts
ALTER TABLE public.shifts 
  ADD CONSTRAINT shifts_payout_id_fkey 
  FOREIGN KEY (payout_id) REFERENCES public.payouts(id);

ALTER TABLE public.payouts 
  ADD CONSTRAINT payouts_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES public.profiles(user_id);

ALTER TABLE public.payouts 
  ADD CONSTRAINT payouts_created_by_fkey 
  FOREIGN KEY (created_by) REFERENCES public.profiles(user_id);

-- =====================================================
-- 3. GRANT OPRÁVNĚNÍ (KRITICKÉ PRO PRODUKCI!)
-- =====================================================

-- Oprávnění pro schéma
GRANT USAGE ON SCHEMA public TO postgres, anon, authenticated, service_role;

-- Oprávnění pro všechny existující tabulky
GRANT ALL ON ALL TABLES IN SCHEMA public TO postgres, anon, authenticated, service_role;

-- Oprávnění pro všechny existující sekvence
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO postgres, anon, authenticated, service_role;

-- Oprávnění pro všechny existující funkce
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO postgres, anon, authenticated, service_role;

-- Automatická oprávnění pro budoucí objekty
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;

-- =====================================================
-- 4. DATABÁZOVÉ FUNKCE
-- =====================================================

-- Funkce pro kontrolu role (SECURITY DEFINER - pro triggery)
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = _role
  )
$$;

-- Funkce pro získání role uživatele
CREATE OR REPLACE FUNCTION public.get_user_role(_user_id UUID)
RETURNS public.app_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

-- Trigger pro nové uživatele
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Vytvoř profil
  INSERT INTO public.profiles (user_id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data ->> 'full_name');
  
  -- Přiřaď výchozí roli hobby_player
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'hobby_player');
  
  RETURN NEW;
END;
$$;

-- Trigger pro aktualizaci updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- Trigger pro validaci směn
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

-- Trigger pro validaci výplat
CREATE OR REPLACE FUNCTION public.validate_payout()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

-- Trigger pro automatické vytvoření směn při commercial eventu
CREATE OR REPLACE FUNCTION public.handle_new_commercial_event()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  i INTEGER;
BEGIN
  IF NEW.event_type = 'commercial' AND NEW.required_staff > 0 THEN
    FOR i IN 1..NEW.required_staff LOOP
      INSERT INTO public.shifts (event_id, status)
      VALUES (NEW.id, 'open');
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$$;

-- =====================================================
-- 5. TRIGGERY
-- =====================================================

-- Trigger pro nové uživatele v auth.users
CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Updated_at triggery
CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_events_updated_at
  BEFORE UPDATE ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_shifts_updated_at
  BEFORE UPDATE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_chat_groups_updated_at
  BEFORE UPDATE ON public.chat_groups
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Validační triggery
CREATE TRIGGER validate_shift_before_update
  BEFORE UPDATE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.validate_shift_claim();

CREATE TRIGGER validate_payout_before_insert
  BEFORE INSERT ON public.payouts
  FOR EACH ROW EXECUTE FUNCTION public.validate_payout();

CREATE TRIGGER create_shifts_for_commercial_event
  AFTER INSERT ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_commercial_event();

-- =====================================================
-- 6. ROW LEVEL SECURITY - ENABLE
-- =====================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_groups ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- 7. RLS POLICIES - ZJEDNODUŠENÉ PRO PRODUKCI
-- =====================================================

-- =====================================================
-- USER_ROLES POLICIES
-- =====================================================

-- SELECT: Všichni authenticated mohou číst všechny role (Open Read)
CREATE POLICY "Authenticated can read all roles"
ON public.user_roles FOR SELECT TO authenticated
USING (true);

-- INSERT/UPDATE/DELETE: Pouze admin
CREATE POLICY "Admins can manage roles"
ON public.user_roles FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- =====================================================
-- PROFILES POLICIES
-- =====================================================

-- SELECT: Všichni authenticated mohou číst profily (Open Read)
CREATE POLICY "Authenticated can read profiles"
ON public.profiles FOR SELECT TO authenticated
USING (true);

-- INSERT: Uživatel může vytvořit svůj profil
CREATE POLICY "Users can insert own profile"
ON public.profiles FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id);

-- UPDATE: Uživatel může upravit svůj profil
CREATE POLICY "Users can update own profile"
ON public.profiles FOR UPDATE TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- =====================================================
-- EVENTS POLICIES
-- =====================================================

-- SELECT: Všichni authenticated mohou číst všechny eventy (Open Read)
CREATE POLICY "Authenticated can read events"
ON public.events FOR SELECT TO authenticated
USING (true);

-- INSERT: Pouze admin
CREATE POLICY "Admins can create events"
ON public.events FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- UPDATE: Pouze admin
CREATE POLICY "Admins can update events"
ON public.events FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- DELETE: Pouze admin
CREATE POLICY "Admins can delete events"
ON public.events FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- =====================================================
-- SHIFTS POLICIES
-- =====================================================

-- SELECT: Všichni authenticated mohou číst směny (Open Read)
CREATE POLICY "Authenticated can read shifts"
ON public.shifts FOR SELECT TO authenticated
USING (true);

-- INSERT: Pouze admin
CREATE POLICY "Admins can create shifts"
ON public.shifts FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- UPDATE: Admin nebo staff (s omezeními v triggeru)
CREATE POLICY "Staff and admins can update shifts"
ON public.shifts FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role IN ('admin', 'part_time_staff')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role IN ('admin', 'part_time_staff')
  )
);

-- DELETE: Pouze admin
CREATE POLICY "Admins can delete shifts"
ON public.shifts FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- =====================================================
-- PAYOUTS POLICIES
-- =====================================================

-- SELECT: Vlastník nebo admin
CREATE POLICY "Users can view own payouts"
ON public.payouts FOR SELECT TO authenticated
USING (
  user_id = auth.uid() OR
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- INSERT/UPDATE/DELETE: Pouze admin (validace v triggeru)
CREATE POLICY "Admins can manage payouts"
ON public.payouts FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- =====================================================
-- CHAT_GROUPS POLICIES
-- =====================================================

-- SELECT: Uživatel vidí skupiny podle své role nebo admin vidí vše
CREATE POLICY "Users can view authorized groups"
ON public.chat_groups FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
  OR authorized_roles = '{}'::public.app_role[]
  OR (
    SELECT role FROM public.user_roles ur
    WHERE ur.user_id = auth.uid()
    ORDER BY 
      CASE role 
        WHEN 'admin' THEN 1 
        WHEN 'trainer' THEN 2 
        WHEN 'part_time_staff' THEN 3 
        WHEN 'pro_player' THEN 4 
        WHEN 'hobby_player' THEN 5 
      END
    LIMIT 1
  ) = ANY(authorized_roles)
);

-- INSERT/UPDATE/DELETE: Pouze admin
CREATE POLICY "Admins can manage chat groups"
ON public.chat_groups FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- =====================================================
-- 8. INDEXY PRO VÝKON
-- =====================================================

CREATE INDEX idx_profiles_user_id ON public.profiles(user_id);
CREATE INDEX idx_user_roles_user_id ON public.user_roles(user_id);
CREATE INDEX idx_user_roles_role ON public.user_roles(role);
CREATE INDEX idx_events_start_time ON public.events(start_time);
CREATE INDEX idx_events_event_type ON public.events(event_type);
CREATE INDEX idx_shifts_event_id ON public.shifts(event_id);
CREATE INDEX idx_shifts_claimed_by ON public.shifts(claimed_by);
CREATE INDEX idx_shifts_status ON public.shifts(status);
CREATE INDEX idx_shifts_payout_id ON public.shifts(payout_id);
CREATE INDEX idx_payouts_user_id ON public.payouts(user_id);
CREATE INDEX idx_payouts_paid_at ON public.payouts(paid_at);

-- =====================================================
-- 9. VIEW PRO VEŘEJNÉ PROFILY (skrývá bank_account)
-- =====================================================

CREATE OR REPLACE VIEW public.profiles_public AS
SELECT 
  id,
  user_id,
  full_name,
  phone,
  -- bank_account je viditelný pouze pro vlastníka nebo admina
  CASE 
    WHEN auth.uid() = user_id THEN bank_account
    WHEN EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN bank_account
    ELSE NULL
  END as bank_account,
  created_at,
  updated_at
FROM public.profiles;

-- =====================================================
-- 10. INSTRUKCE PO NASAZENÍ
-- =====================================================

-- Po registraci prvního uživatele (admin) spusť:
-- 
-- UPDATE public.user_roles 
-- SET role = 'admin' 
-- WHERE user_id = (
--   SELECT user_id FROM public.profiles 
--   WHERE full_name = 'JMÉNO_ADMINA' 
--   LIMIT 1
-- );
--
-- Nebo pomocí email:
--
-- UPDATE public.user_roles 
-- SET role = 'admin' 
-- WHERE user_id = (
--   SELECT id FROM auth.users 
--   WHERE email = 'admin@email.cz' 
--   LIMIT 1
-- );

-- =====================================================
-- HOTOVO! Databáze je připravena pro produkci.
-- =====================================================
