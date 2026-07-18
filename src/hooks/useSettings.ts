import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

export type Settings = Database['public']['Tables']['settings']['Row'];
export type Sheet = Database['public']['Tables']['sheets']['Row'];
export type OpeningHours = Record<string, { open: string; close: string }>;

// Nastavení haly (ceník + otevírací doba) a plátna. Zápis = jen admin (RLS).
export const useSettings = () => {
  const { user } = useAuth();
  const qc = useQueryClient();

  const { data: settings = null, isLoading } = useQuery({
    queryKey: ['reservation-settings'],
    queryFn: async () => {
      const { data, error } = await supabase.from('settings').select('*').maybeSingle();
      if (error) throw error;
      return (data ?? null) as Settings | null;
    },
    enabled: !!user,
  });

  // pro admina i neaktivní plátna (kvůli správě)
  const { data: sheets = [] } = useQuery({
    queryKey: ['sheets-all'],
    queryFn: async () => {
      const { data, error } = await supabase.from('sheets').select('*').order('name', { ascending: true });
      if (error) throw error;
      return (data ?? []) as Sheet[];
    },
    enabled: !!user,
  });

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['reservation-settings'] });
    qc.invalidateQueries({ queryKey: ['sheets'] });
    qc.invalidateQueries({ queryKey: ['sheets-all'] });
  };

  const updateSettings = useMutation({
    mutationFn: async (fields: { club_default_rate?: number | null; commercial_default_rate?: number | null; opening_hours?: OpeningHours }) => {
      const { error } = await supabase.from('settings').update(fields).eq('singleton', true);
      if (error) throw new Error('Nepodařilo se uložit nastavení.');
    },
    onSuccess: invalidate,
  });

  const addSheet = useMutation({
    mutationFn: async (name: string) => {
      const { error } = await supabase.from('sheets').insert({ name });
      if (error) throw new Error('Nepodařilo se přidat plátno.');
    },
    onSuccess: invalidate,
  });

  const updateSheet = useMutation({
    mutationFn: async ({ id, fields }: { id: string; fields: { name?: string; active?: boolean } }) => {
      const { error } = await supabase.from('sheets').update(fields).eq('id', id);
      if (error) throw new Error('Nepodařilo se upravit plátno.');
    },
    onSuccess: invalidate,
  });

  return {
    settings, sheets, isLoading,
    updateSettings: updateSettings.mutateAsync,
    addSheet: addSheet.mutateAsync,
    updateSheet: updateSheet.mutateAsync,
    isSaving: updateSettings.isPending || addSheet.isPending || updateSheet.isPending,
  };
};
