-- Drop existing UPDATE policy
DROP POLICY IF EXISTS "Staff can claim open shifts" ON public.shifts;

-- Create new UPDATE policy that allows:
-- 1. Admins can update any shift
-- 2. Staff can claim open shifts (update from open)
-- 3. Staff can update their own claimed shifts (cancel or complete)
CREATE POLICY "Staff can update shifts"
ON public.shifts
FOR UPDATE
USING (
  has_role(auth.uid(), 'admin'::app_role) 
  OR (
    has_role(auth.uid(), 'part_time_staff'::app_role) 
    AND (
      status = 'open'::shift_status 
      OR claimed_by = auth.uid()
    )
  )
);