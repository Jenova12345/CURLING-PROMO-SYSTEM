import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { toast } from 'sonner';
import type { Database } from '@/integrations/supabase/types';

type AppRole = Database['public']['Enums']['app_role'];

interface ChatGroup {
  id: string;
  name: string;
  description: string | null;
  whatsapp_url: string;
  icon: string | null;
  icon_slug: string | null;
  authorized_roles: AppRole[];
  created_at: string;
  updated_at: string;
}

interface CreateChatGroupInput {
  name: string;
  description?: string;
  whatsapp_url: string;
  icon?: string;
  icon_slug?: string;
  authorized_roles: AppRole[];
}

interface UpdateChatGroupInput extends Partial<CreateChatGroupInput> {
  id: string;
}

export const useChatGroups = () => {
  const { user } = useAuth();
  const queryClient = useQueryClient();

  const { data: chatGroups = [], isLoading, error } = useQuery({
    queryKey: ['chat-groups'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('chat_groups')
        .select('*')
        .order('name');

      if (error) throw error;
      return data as ChatGroup[];
    },
    enabled: !!user,
  });

  const createGroup = useMutation({
    mutationFn: async (input: CreateChatGroupInput) => {
      const { data, error } = await supabase
        .from('chat_groups')
        .insert({
          name: input.name,
          description: input.description || null,
          whatsapp_url: input.whatsapp_url,
          icon: input.icon || null,
          icon_slug: input.icon_slug || 'message-circle',
          authorized_roles: input.authorized_roles,
        })
        .select()
        .single();

      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['chat-groups'] });
      toast.success('Skupina byla vytvořena');
    },
    onError: (error) => {
      toast.error('Nepodařilo se vytvořit skupinu');
      console.error('Error creating chat group:', error);
    },
  });

  const updateGroup = useMutation({
    mutationFn: async (input: UpdateChatGroupInput) => {
      const { id, ...updates } = input;
      const { data, error } = await supabase
        .from('chat_groups')
        .update(updates)
        .eq('id', id)
        .select()
        .single();

      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['chat-groups'] });
      toast.success('Skupina byla aktualizována');
    },
    onError: (error) => {
      toast.error('Nepodařilo se aktualizovat skupinu');
      console.error('Error updating chat group:', error);
    },
  });

  const deleteGroup = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('chat_groups')
        .delete()
        .eq('id', id);

      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['chat-groups'] });
      toast.success('Skupina byla smazána');
    },
    onError: (error) => {
      toast.error('Nepodařilo se smazat skupinu');
      console.error('Error deleting chat group:', error);
    },
  });

  return {
    chatGroups,
    isLoading,
    error,
    createGroup,
    updateGroup,
    deleteGroup,
  };
};
