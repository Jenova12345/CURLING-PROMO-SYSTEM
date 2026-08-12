import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

// Nastavení tak, jak ho vidí frontend: čte se z pohledu `settings_public`,
// protože sazby jsou v tabulce po A2b nedostupné a pohled je vydá jen adminovi.
// Pro ostatní role přijdou sazby jako null — `can_see_rates` říká, jestli je to
// „nemáš na to právo" nebo „ceník není vyplněný".
export type Settings = Database['public']['Views']['settings_public']['Row'];
export type Sheet = Database['public']['Tables']['sheets']['Row'];
export type OpeningHours = Record<string, { open: string; close: string }>;

// Nastavení haly (ceník + otevírací doba) a dráhy. Zápis = jen admin (RLS).
export const useSettings = () => {
  const { user } = useAuth();
  const qc = useQueryClient();

  const { data: settings = null, isLoading } = useQuery({
    queryKey: ['reservation-settings'],
    queryFn: async () => {
      // Čte se z pohledu, ne z tabulky: sazby jsou v `settings` sloupcovým
      // REVOKE nedostupné (A2b) a pohled je vydá jen adminovi. Zápis níž
      // míří dál na tabulku, kde ho hlídá politika settings_update_admin.
      const { data, error } = await supabase.from('settings_public').select('*').maybeSingle();
      if (error) throw error;
      return (data ?? null) as Settings | null;
    },
    enabled: !!user,
  });

  // pro admina i neaktivní dráhy (kvůli správě)
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
    mutationFn: async (fields: {
      club_default_rate?: number | null;
      commercial_default_rate?: number | null;
      training_rate?: number | null;
      tournament_rate?: number | null;
      opening_hours?: OpeningHours;
    }) => {
      // POZOR: nepřidávej sem `.select()`. Vynutilo by `return=representation`,
      // což potřebuje SELECT na měněné sloupce — a ten je na sazbách po A2b
      // odebraný, takže by adminovi přestalo jít ukládat ceníku (403 / 42501).
      const { error } = await supabase.from('settings').update(fields).eq('singleton', true);
      if (error) throw new Error('Nepodařilo se uložit nastavení.');
    },
    onSuccess: invalidate,
  });

  const addSheet = useMutation({
    mutationFn: async (name: string) => {
      const { error } = await supabase.from('sheets').insert({ name });
      if (error) throw new Error('Nepodařilo se přidat dráhu.');
    },
    onSuccess: invalidate,
  });

  const updateSheet = useMutation({
    mutationFn: async ({ id, fields }: { id: string; fields: { name?: string; active?: boolean } }) => {
      const { error } = await supabase.from('sheets').update(fields).eq('id', id);
      if (error) throw new Error('Nepodařilo se upravit dráhu.');
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
