-- First update any existing events with 'free' type to 'commercial'
UPDATE public.events 
SET event_type = 'commercial' 
WHERE event_type = 'free';

-- Drop the RLS policy that depends on event_type
DROP POLICY IF EXISTS "Users can view events based on type" ON public.events;

-- Drop the default
ALTER TABLE public.events 
  ALTER COLUMN event_type DROP DEFAULT;

-- Create new enum type without 'free'
CREATE TYPE public.event_type_new AS ENUM ('commercial', 'training', 'maintenance');

-- Update the events table to use the new enum
ALTER TABLE public.events 
  ALTER COLUMN event_type TYPE public.event_type_new 
  USING event_type::text::public.event_type_new;

-- Set the new default
ALTER TABLE public.events 
  ALTER COLUMN event_type SET DEFAULT 'commercial'::public.event_type_new;

-- Drop the old enum and rename the new one
DROP TYPE public.event_type;
ALTER TYPE public.event_type_new RENAME TO event_type;

-- Recreate the RLS policy without 'free' (commercial events need staff/admin, others are public)
CREATE POLICY "Users can view events based on type" 
ON public.events 
FOR SELECT 
USING (
  (event_type <> 'commercial'::event_type) OR 
  has_role(auth.uid(), 'admin'::app_role) OR 
  has_role(auth.uid(), 'part_time_staff'::app_role) OR 
  has_role(auth.uid(), 'trainer'::app_role)
);