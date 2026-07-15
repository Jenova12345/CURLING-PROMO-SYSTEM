-- Create payouts table for tracking payments to staff
CREATE TABLE public.payouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  amount numeric NOT NULL,
  paid_at timestamp with time zone DEFAULT now(),
  notes text,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.payouts ENABLE ROW LEVEL SECURITY;

-- Admins can manage all payouts
CREATE POLICY "Admins can manage payouts"
ON public.payouts FOR ALL
USING (has_role(auth.uid(), 'admin'::app_role));

-- Users can view their own payouts
CREATE POLICY "Users can view own payouts"
ON public.payouts FOR SELECT
USING (user_id = auth.uid());

-- Add payout_id and completed_at columns to shifts
ALTER TABLE public.shifts 
ADD COLUMN payout_id uuid REFERENCES public.payouts(id),
ADD COLUMN completed_at timestamp with time zone;

-- Update the validate_shift_claim trigger to handle admin-only completion
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
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