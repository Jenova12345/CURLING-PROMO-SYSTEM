-- Update trigger to remove notification creation
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
    -- Notifications removed - using WhatsApp for communication
  END IF;
  
  RETURN NEW;
END;
$$;

-- Drop the notifications table
DROP TABLE IF EXISTS public.notifications CASCADE;