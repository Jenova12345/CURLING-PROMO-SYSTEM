-- Add icon_slug column for Lucide icons
ALTER TABLE public.chat_groups 
ADD COLUMN IF NOT EXISTS icon_slug text DEFAULT 'message-circle';

-- Migrate existing emoji to Lucide icon slugs
UPDATE public.chat_groups SET icon_slug = CASE icon
  WHEN '💬' THEN 'message-circle'
  WHEN '👥' THEN 'users'
  WHEN '🏃' THEN 'briefcase'
  WHEN '🎯' THEN 'target'
  WHEN '🏒' THEN 'trophy'
  WHEN '🎳' THEN 'heart'
  ELSE 'message-circle'
END WHERE icon_slug IS NULL OR icon_slug = 'message-circle';

-- Drop existing SELECT policy
DROP POLICY IF EXISTS "Users can view authorized groups" ON public.chat_groups;

-- Create new SELECT policy with support for public groups (empty array)
CREATE POLICY "Users can view authorized groups" ON public.chat_groups
FOR SELECT TO authenticated
USING (
  has_role(auth.uid(), 'admin'::app_role)
  OR authorized_roles = '{}'::app_role[]
  OR get_user_role(auth.uid()) = ANY(authorized_roles)
);