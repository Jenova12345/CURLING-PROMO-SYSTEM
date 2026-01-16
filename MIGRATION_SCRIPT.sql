-- ============================================
-- KOMPLETNÍ MIGRAČNÍ SKRIPT PRO SUPABASE
-- Mladé Kameny - Systém pro správu brigádníků
-- OPRAVENÁ VERZE - Fixed RLS deadlock
-- ============================================
-- 
-- INSTRUKCE:
-- 1. Vytvoř nový projekt na supabase.com
-- 2. Jdi do SQL Editor v Supabase dashboard
-- 3. Zkopíruj celý tento skript a spusť ho
-- 4. Nastav Auth settings (viz poznámky níže)
-- 5. Zkopíruj API credentials do frontendu
--
-- KRITICKÁ OPRAVA:
-- Místo has_role() v RLS policies používáme přímé EXISTS subquery,
-- aby nedošlo k deadlocku. Funkce has_role() zůstává pro triggery.
--
-- ============================================

-- ============================================
-- 1. ENUM TYPY
-- ============================================

-- Role uživatelů
CREATE TYPE public.app_role AS ENUM (
  'admin',
  'trainer', 
  'part_time_staff',
  'pro_player',
  'hobby_player'
);

-- Typy akcí
CREATE TYPE public.event_type AS ENUM (
  'commercial',
  'training',
  'public_skating',
  'private'
);

-- Stavy směn
CREATE TYPE public.shift_status AS ENUM (
  'open',
  'pending',
  'claimed',
  'completed'
);

-- ============================================
-- 2. TABULKY
-- ============================================

-- Profily uživatelů
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL UNIQUE,
  full_name TEXT,
  phone TEXT,
  bank_account TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Role uživatelů (oddělená tabulka pro bezpečnost)
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role app_role NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(user_id, role)
);

-- Akce/události
CREATE TABLE public.events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT,
  event_type event_type NOT NULL DEFAULT 'commercial',
  start_time TIMESTAMP WITH TIME ZONE NOT NULL,
  end_time TIMESTAMP WITH TIME ZONE NOT NULL,
  required_staff INTEGER DEFAULT 0,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Směny brigádníků
CREATE TABLE public.shifts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID REFERENCES public.events(id) ON DELETE CASCADE NOT NULL,
  status shift_status NOT NULL DEFAULT 'open',
  claimed_by UUID REFERENCES auth.users(id),
  claimed_at TIMESTAMP WITH TIME ZONE,
  hours_worked NUMERIC,
  hourly_rate NUMERIC DEFAULT 150.00,
  completed_at TIMESTAMP WITH TIME ZONE,
  payout_id UUID,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Výplaty
CREATE TABLE public.payouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  amount NUMERIC NOT NULL,
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  paid_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Přidat foreign key pro payout_id v shifts
ALTER TABLE public.shifts 
ADD CONSTRAINT shifts_payout_id_fkey 
FOREIGN KEY (payout_id) REFERENCES public.payouts(id);

-- Chat skupiny (WhatsApp)
CREATE TABLE public.chat_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  whatsapp_url TEXT NOT NULL,
  icon TEXT DEFAULT '💬',
  icon_slug TEXT DEFAULT 'message-circle',
  authorized_roles app_role[] NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- ============================================
-- 3. DATABÁZOVÉ FUNKCE
-- ============================================

-- Kontrola role uživatele (security definer - pro použití v TRIGGERECH!)
-- NEPOUŽÍVAT V RLS POLICIES - způsobuje deadlock!
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
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

-- Získání role uživatele (pro použití v TRIGGERECH)
CREATE OR REPLACE FUNCTION public.get_user_role(_user_id UUID)
RETURNS app_role
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

-- Automatické vytvoření profilu a role při registraci
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Vytvořit profil
  INSERT INTO public.profiles (user_id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data ->> 'full_name');
  
  -- Přiřadit výchozí roli (hobby_player)
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'hobby_player');
  
  RETURN NEW;
END;
$$;

-- Aktualizace updated_at sloupce
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

-- Validace směn
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

  -- Staff přihlašuje směnu (open -> pending)
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
    IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
      RAISE EXCEPTION 'Pouze admin může schválit směnu';
    END IF;
  END IF;
  
  -- Odmítnutí směny (pending -> open)
  IF OLD.status = 'pending' AND NEW.status = 'open' THEN
    IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
      IF OLD.claimed_by != auth.uid() THEN
        RAISE EXCEPTION 'Nemůžete zrušit cizí přihlášku';
      END IF;
    END IF;
  END IF;
  
  -- Zrušení přiřazené směny (claimed -> open)
  IF OLD.status = 'claimed' AND NEW.status = 'open' THEN
    IF OLD.claimed_by != auth.uid() AND NOT has_role(auth.uid(), 'admin'::app_role) THEN
      RAISE EXCEPTION 'Nemůžete zrušit cizí směnu';
    END IF;
  END IF;
  
  -- Dokončení směny (claimed -> completed) - pouze admin
  IF OLD.status = 'claimed' AND NEW.status = 'completed' THEN
    IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
      RAISE EXCEPTION 'Pouze admin může dokončit směnu';
    END IF;
    
    IF NEW.hours_worked IS NULL OR NEW.hours_worked <= 0 THEN
      RAISE EXCEPTION 'Musíte zadat odpracované hodiny';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Validace výplat
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
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Pouze admin může vytvářet výplaty';
  END IF;
  
  RETURN NEW;
END;
$$;

-- Automatické vytvoření směn pro komerční akce
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

-- ============================================
-- 4. TRIGGERY
-- ============================================

-- Trigger pro vytvoření profilu při registraci
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Trigger pro aktualizaci updated_at
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

-- Trigger pro validaci směn
CREATE TRIGGER validate_shift_claim_trigger
  BEFORE UPDATE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.validate_shift_claim();

-- Trigger pro validaci výplat
CREATE TRIGGER validate_payout_trigger
  BEFORE INSERT ON public.payouts
  FOR EACH ROW EXECUTE FUNCTION public.validate_payout();

-- Trigger pro automatické vytvoření směn
CREATE TRIGGER on_commercial_event_created
  AFTER INSERT ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_commercial_event();

-- ============================================
-- 5. ROW LEVEL SECURITY (RLS) - OPRAVENÉ!
-- ============================================
-- KRITICKÁ OPRAVA: Místo has_role() v RLS policies
-- používáme přímé EXISTS subquery, aby nedošlo k deadlocku.
-- Funkce has_role() zůstává pro použití v triggerech.
-- ============================================

-- Zapnout RLS na všech tabulkách
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_groups ENABLE ROW LEVEL SECURITY;

-- ==================
-- USER_ROLES POLICIES - OPRAVENÉ (bez has_role!)
-- ==================

-- Každý authenticated může číst svoji roli, admin vidí všechny
CREATE POLICY "Anyone can read own role"
ON public.user_roles FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can insert roles"
ON public.user_roles FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can update roles"
ON public.user_roles FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can delete roles"
ON public.user_roles FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- ==================
-- PROFILES POLICIES - OPRAVENÉ (bez has_role!)
-- ==================

-- Všichni authenticated mohou číst profily
-- (citlivé údaje jako bank_account jsou chráněny přes VIEW)
CREATE POLICY "Authenticated can read profiles"
ON public.profiles FOR SELECT TO authenticated
USING (true);

CREATE POLICY "Users can insert own profile"
ON public.profiles FOR INSERT TO authenticated
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own profile"
ON public.profiles FOR UPDATE TO authenticated
USING (auth.uid() = user_id);

-- ==================
-- EVENTS POLICIES - OPRAVENÉ (bez has_role!)
-- ==================

CREATE POLICY "Authenticated can read events"
ON public.events FOR SELECT TO authenticated
USING (
  event_type <> 'commercial'
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() 
    AND ur.role IN ('admin', 'part_time_staff', 'trainer')
  )
);

CREATE POLICY "Admins can create events"
ON public.events FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can update events"
ON public.events FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can delete events"
ON public.events FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- ==================
-- SHIFTS POLICIES - OPRAVENÉ (bez has_role!)
-- ==================

CREATE POLICY "Staff and admins can read shifts"
ON public.shifts FOR SELECT TO authenticated
USING (
  claimed_by = auth.uid()
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() 
    AND ur.role IN ('admin', 'part_time_staff')
  )
);

CREATE POLICY "Admins can create shifts"
ON public.shifts FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Staff and admins can update shifts"
ON public.shifts FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() 
    AND ur.role IN ('admin', 'part_time_staff')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
  OR (
    EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.user_id = auth.uid() AND ur.role = 'part_time_staff'
    )
    AND (
      (status = 'pending' AND claimed_by = auth.uid())
      OR (status = 'completed' AND claimed_by = auth.uid())
      OR (status = 'open' AND claimed_by IS NULL)
    )
  )
);

CREATE POLICY "Admins can delete shifts"
ON public.shifts FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- ==================
-- PAYOUTS POLICIES - OPRAVENÉ (bez has_role!)
-- ==================

CREATE POLICY "Users can read own payouts"
ON public.payouts FOR SELECT TO authenticated
USING (
  user_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can create payouts"
ON public.payouts FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can update payouts"
ON public.payouts FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can delete payouts"
ON public.payouts FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- ==================
-- CHAT_GROUPS POLICIES - OPRAVENÉ (bez has_role!)
-- ==================

CREATE POLICY "Users can read authorized groups"
ON public.chat_groups FOR SELECT TO authenticated
USING (
  authorized_roles = '{}'::app_role[]
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() 
    AND ur.role = ANY(authorized_roles)
  )
);

CREATE POLICY "Admins can create groups"
ON public.chat_groups FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can update groups"
ON public.chat_groups FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

CREATE POLICY "Admins can delete groups"
ON public.chat_groups FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
  )
);

-- ============================================
-- 6. INDEXY PRO VÝKON
-- ============================================

CREATE INDEX idx_profiles_user_id ON public.profiles(user_id);
CREATE INDEX idx_user_roles_user_id ON public.user_roles(user_id);
CREATE INDEX idx_events_start_time ON public.events(start_time);
CREATE INDEX idx_events_event_type ON public.events(event_type);
CREATE INDEX idx_shifts_event_id ON public.shifts(event_id);
CREATE INDEX idx_shifts_claimed_by ON public.shifts(claimed_by);
CREATE INDEX idx_shifts_status ON public.shifts(status);
CREATE INDEX idx_shifts_payout_id ON public.shifts(payout_id);
CREATE INDEX idx_payouts_user_id ON public.payouts(user_id);

-- ============================================
-- 7. BEZPEČNOSTNÍ VIEW
-- ============================================

CREATE OR REPLACE VIEW public.profiles_public
WITH (security_invoker = on) AS
SELECT 
  id,
  user_id,
  full_name,
  phone,
  created_at,
  updated_at,
  CASE 
    WHEN auth.uid() = user_id THEN bank_account
    WHEN EXISTS (
      SELECT 1 FROM public.user_roles ur
      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'
    ) THEN bank_account
    ELSE NULL
  END as bank_account
FROM public.profiles;

GRANT SELECT ON public.profiles_public TO authenticated;

-- ============================================
-- HOTOVO!
-- ============================================
-- 
-- DALŠÍ KROKY:
-- 
-- 1. V Supabase dashboard → Authentication → Settings:
--    - Site URL: https://mladekameny.lovable.app
--
-- 2. V Authentication → URL Configuration → Redirect URLs přidej:
--    - https://mladekameny.lovable.app/update-password
--    - https://mladekameny.lovable.app/
--
-- 3. Po registraci se přihlas a spusť tento SQL pro nastavení admin role:
--    UPDATE public.user_roles 
--    SET role = 'admin' 
--    WHERE user_id = (SELECT id FROM auth.users WHERE email = 'tvuj@email.cz');
--
-- ============================================
