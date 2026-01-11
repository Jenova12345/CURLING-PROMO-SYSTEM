-- Create chat_groups table for WhatsApp group links
CREATE TABLE public.chat_groups (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  whatsapp_url TEXT NOT NULL,
  icon TEXT DEFAULT '💬',
  authorized_roles app_role[] NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable Row Level Security
ALTER TABLE public.chat_groups ENABLE ROW LEVEL SECURITY;

-- Policy: Users can view groups where their role is in authorized_roles
CREATE POLICY "Users can view authorized groups"
ON public.chat_groups
FOR SELECT
USING (
  get_user_role(auth.uid()) = ANY(authorized_roles)
);

-- Policy: Only admins can insert groups
CREATE POLICY "Only admins can create groups"
ON public.chat_groups
FOR INSERT
WITH CHECK (has_role(auth.uid(), 'admin'));

-- Policy: Only admins can update groups
CREATE POLICY "Only admins can update groups"
ON public.chat_groups
FOR UPDATE
USING (has_role(auth.uid(), 'admin'));

-- Policy: Only admins can delete groups
CREATE POLICY "Only admins can delete groups"
ON public.chat_groups
FOR DELETE
USING (has_role(auth.uid(), 'admin'));

-- Create trigger for automatic timestamp updates
CREATE TRIGGER update_chat_groups_updated_at
BEFORE UPDATE ON public.chat_groups
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Insert default groups
INSERT INTO public.chat_groups (name, description, whatsapp_url, icon, authorized_roles) VALUES
('Všichni členové', 'Hlavní skupina pro všechny členy klubu', 'https://chat.whatsapp.com/example-all', '👥', ARRAY['admin', 'trainer', 'part_time_staff', 'pro_player', 'hobby_player']::app_role[]),
('Brigádníci', 'Koordinace směn a pracovních záležitostí', 'https://chat.whatsapp.com/example-staff', '🏃', ARRAY['admin', 'part_time_staff']::app_role[]),
('Trenéři', 'Koordinace tréninků a metodika', 'https://chat.whatsapp.com/example-trainers', '🎯', ARRAY['admin', 'trainer']::app_role[]),
('Profi hráči', 'Tréninkový plán a soutěže', 'https://chat.whatsapp.com/example-pro', '🏒', ARRAY['admin', 'trainer', 'pro_player']::app_role[]),
('Hobby hráči', 'Rekreační curling a společenské akce', 'https://chat.whatsapp.com/example-hobby', '🎳', ARRAY['admin', 'hobby_player']::app_role[]);