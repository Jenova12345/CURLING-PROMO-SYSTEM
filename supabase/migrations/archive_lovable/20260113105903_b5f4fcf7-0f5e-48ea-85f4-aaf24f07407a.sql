-- =====================================================
-- SECURITY ENHANCEMENT: RLS Policies & Validation Triggers
-- =====================================================

-- 1. FIX PROFILES RLS - Restrict personal data visibility
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;

-- Users can view:
-- - Their own profile (full data)
-- - Admin sees all
-- - Staff/trainers see profiles for shift coordination
CREATE POLICY "Users can view profiles based on role" ON public.profiles
FOR SELECT USING (
  auth.uid() = user_id
  OR has_role(auth.uid(), 'admin'::app_role)
  OR has_role(auth.uid(), 'part_time_staff'::app_role)
  OR has_role(auth.uid(), 'trainer'::app_role)
);

-- 2. FIX EVENTS RLS - Restrict commercial events visibility
DROP POLICY IF EXISTS "All authenticated users can view events" ON public.events;

-- Commercial events visible only to staff/admins/trainers
-- Other event types visible to all authenticated users
CREATE POLICY "Users can view events based on type" ON public.events
FOR SELECT USING (
  event_type != 'commercial'
  OR has_role(auth.uid(), 'admin'::app_role)
  OR has_role(auth.uid(), 'part_time_staff'::app_role)
  OR has_role(auth.uid(), 'trainer'::app_role)
);

-- 3. ADD NOTIFICATIONS DELETE POLICY
CREATE POLICY "Users can delete own notifications" ON public.notifications
FOR DELETE USING (user_id = auth.uid());

-- 4. ENHANCE SHIFT VALIDATION TRIGGER
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Validate hours_worked range (OWASP: server-side validation)
  IF NEW.hours_worked IS NOT NULL THEN
    IF NEW.hours_worked < 0.1 OR NEW.hours_worked > 24 THEN
      RAISE EXCEPTION 'Hodiny musí být mezi 0.1 a 24';
    END IF;
  END IF;

  -- Validate hourly_rate range
  IF NEW.hourly_rate IS NOT NULL THEN
    IF NEW.hourly_rate < 1 OR NEW.hourly_rate > 10000 THEN
      RAISE EXCEPTION 'Hodinová sazba musí být mezi 1 a 10000 Kč';
    END IF;
  END IF;

  -- Staff requesting a shift (open -> pending)
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
  
  -- Admin approving shift (pending -> claimed)
  IF OLD.status = 'pending' AND NEW.status = 'claimed' THEN
    IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
      RAISE EXCEPTION 'Pouze admin může schválit směnu';
    END IF;
  END IF;
  
  -- Admin rejecting shift (pending -> open)
  IF OLD.status = 'pending' AND NEW.status = 'open' THEN
    IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
      IF OLD.claimed_by != auth.uid() THEN
        RAISE EXCEPTION 'Nemůžete zrušit cizí přihlášku';
      END IF;
    END IF;
  END IF;
  
  -- Staff canceling their claimed shift
  IF OLD.status = 'claimed' AND NEW.status = 'open' THEN
    IF OLD.claimed_by != auth.uid() AND NOT has_role(auth.uid(), 'admin'::app_role) THEN
      RAISE EXCEPTION 'Nemůžete zrušit cizí směnu';
    END IF;
  END IF;
  
  -- Admin completing shift (claimed -> completed) - ONLY ADMIN
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
$function$;

-- 5. CREATE PAYOUT VALIDATION TRIGGER
CREATE OR REPLACE FUNCTION public.validate_payout()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Validate amount range (OWASP: server-side validation)
  IF NEW.amount < 1 OR NEW.amount > 1000000 THEN
    RAISE EXCEPTION 'Částka výplaty musí být mezi 1 a 1 000 000 Kč';
  END IF;
  
  -- Only admins can create payouts
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Pouze admin může vytvářet výplaty';
  END IF;
  
  RETURN NEW;
END;
$function$;

-- Create trigger for payout validation
DROP TRIGGER IF EXISTS validate_payout_trigger ON public.payouts;
CREATE TRIGGER validate_payout_trigger
BEFORE INSERT ON public.payouts
FOR EACH ROW EXECUTE FUNCTION public.validate_payout();