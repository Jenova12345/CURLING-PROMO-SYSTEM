-- =====================================================
-- SECURITY FIX: Protect bank_account from non-admin access
-- =====================================================
-- This migration creates a secure view for profile data
-- that hides bank_account from non-admin users.

-- 1. Create a view for public profile info (excludes bank_account for non-admins)
CREATE OR REPLACE VIEW public.profiles_public
WITH (security_invoker = on) AS
SELECT 
  id,
  user_id,
  full_name,
  phone,
  created_at,
  updated_at,
  -- Only show bank_account to admins or the account owner
  CASE 
    WHEN auth.uid() = user_id THEN bank_account
    WHEN has_role(auth.uid(), 'admin'::app_role) THEN bank_account
    ELSE NULL
  END as bank_account
FROM public.profiles;

-- 2. Grant access to the view
GRANT SELECT ON public.profiles_public TO authenticated;

-- Add comment explaining the security purpose
COMMENT ON VIEW public.profiles_public IS 
'Secure view for profile access. bank_account is only visible to the account owner and admins. 
Other authenticated users can see full_name and phone for coordination purposes.';