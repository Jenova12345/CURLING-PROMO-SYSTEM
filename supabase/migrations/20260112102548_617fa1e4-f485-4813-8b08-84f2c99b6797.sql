-- Drop existing UPDATE policy
DROP POLICY IF EXISTS "Staff can update shifts" ON public.shifts;

-- Create new UPDATE policy with proper WITH CHECK clause
CREATE POLICY "Staff can update shifts"
ON public.shifts
FOR UPDATE
USING (
  -- Who can SELECT rows to update
  has_role(auth.uid(), 'admin'::app_role) 
  OR has_role(auth.uid(), 'part_time_staff'::app_role)
)
WITH CHECK (
  -- Who can WRITE new values
  has_role(auth.uid(), 'admin'::app_role)
  OR (
    has_role(auth.uid(), 'part_time_staff'::app_role)
    AND (
      -- Can claim an open shift
      (status = 'claimed' AND claimed_by = auth.uid())
      -- Or can complete their own shift
      OR (status = 'completed' AND claimed_by = auth.uid())
      -- Or can cancel (return to open) their own shift
      OR (status = 'open' AND claimed_by IS NULL)
    )
  )
);

-- Create validation trigger to prevent race conditions
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
RETURNS TRIGGER AS $$
BEGIN
  -- Staff claiming a shift
  IF OLD.status = 'open' AND NEW.status = 'claimed' THEN
    -- Verify shift is still available
    IF OLD.claimed_by IS NOT NULL THEN
      RAISE EXCEPTION 'Směna již byla obsazena';
    END IF;
    
    -- Verify staff doesn't have another shift for this event
    IF EXISTS (
      SELECT 1 FROM public.shifts 
      WHERE event_id = NEW.event_id 
        AND claimed_by = NEW.claimed_by
        AND id != NEW.id
        AND status IN ('claimed', 'completed')
    ) THEN
      RAISE EXCEPTION 'Na této akci již máte jinou směnu';
    END IF;
  END IF;
  
  -- Staff canceling their shift
  IF OLD.status = 'claimed' AND NEW.status = 'open' THEN
    IF OLD.claimed_by != auth.uid() AND NOT has_role(auth.uid(), 'admin'::app_role) THEN
      RAISE EXCEPTION 'Nemůžete zrušit cizí směnu';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Create the trigger
DROP TRIGGER IF EXISTS validate_shift_claim_trigger ON public.shifts;
CREATE TRIGGER validate_shift_claim_trigger
BEFORE UPDATE ON public.shifts
FOR EACH ROW
EXECUTE FUNCTION public.validate_shift_claim();