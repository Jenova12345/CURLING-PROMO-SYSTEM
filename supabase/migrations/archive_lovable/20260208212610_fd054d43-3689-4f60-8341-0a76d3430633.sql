-- Add visible_to_user_ids column to chat_groups
ALTER TABLE public.chat_groups 
ADD COLUMN visible_to_user_ids uuid[] DEFAULT NULL;

-- Update RLS SELECT policy to support multi-role and specific users
DROP POLICY IF EXISTS "Users can view authorized groups" ON public.chat_groups;

CREATE POLICY "Users can view authorized groups" ON public.chat_groups
FOR SELECT USING (
  -- Admins see everything
  has_role(auth.uid(), 'admin'::app_role) 
  -- Public groups (empty roles array)
  OR (authorized_roles = '{}'::app_role[]) 
  -- User has one of the authorized roles (checks ALL user roles, not just primary)
  OR EXISTS (
    SELECT 1 FROM public.user_roles ur 
    WHERE ur.user_id = auth.uid() 
    AND ur.role = ANY(authorized_roles)
  )
  -- User is in the visible_to_user_ids list
  OR (auth.uid() = ANY(visible_to_user_ids))
);