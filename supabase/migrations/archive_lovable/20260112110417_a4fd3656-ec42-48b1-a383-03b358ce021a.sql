-- Drop and recreate the UPDATE policy with pending logic
DROP POLICY IF EXISTS "Staff can update shifts" ON public.shifts;

CREATE POLICY "Staff can update shifts"
ON public.shifts
FOR UPDATE
USING (
  has_role(auth.uid(), 'admin'::app_role) 
  OR has_role(auth.uid(), 'part_time_staff'::app_role)
)
WITH CHECK (
  has_role(auth.uid(), 'admin'::app_role)
  OR (
    has_role(auth.uid(), 'part_time_staff'::app_role)
    AND (
      -- Can request (set pending) an open shift
      (status = 'pending' AND claimed_by = auth.uid())
      -- Or can complete their own claimed shift
      OR (status = 'completed' AND claimed_by = auth.uid())
      -- Or can cancel their pending request back to open
      OR (status = 'open' AND claimed_by IS NULL)
    )
  )
);

-- Update validation trigger to handle pending workflow
CREATE OR REPLACE FUNCTION public.validate_shift_claim()
RETURNS TRIGGER AS $$
BEGIN
  -- Staff requesting a shift (open -> pending)
  IF OLD.status = 'open' AND NEW.status = 'pending' THEN
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
      -- Staff can cancel their own pending request
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
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;