import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

type EventType = Database['public']['Enums']['event_type'];

interface CreateEventData {
  title: string;
  description?: string;
  event_type: EventType;
  start_time: string;
  end_time: string;
  required_staff?: number;
  role_reqs?: Record<string, number>;
}

export const useEvents = () => {
  const { user } = useAuth();
  const queryClient = useQueryClient();

  const { data: events = [], isLoading } = useQuery({
    queryKey: ['events'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('events')
        .select('*')
        .order('start_time', { ascending: true });

      if (error) throw error;
      return data;
    },
    enabled: !!user,
  });

  const createEvent = useMutation({
    mutationFn: async (eventData: CreateEventData) => {
      const { data, error } = await supabase
        .from('events')
        .insert({
          ...eventData,
          created_by: user?.id,
        } as any)
        .select()
        .single();

      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['events'] });
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  const updateEvent = useMutation({
    mutationFn: async ({ id, ...updates }: Partial<CreateEventData> & { id: string }) => {
      const { data, error } = await supabase
        .from('events')
        .update(updates as any)
        .eq('id', id)
        .select()
        .single();

      if (error) throw error;

      // Směny tady NEDOROVNÁVÁME. Dělá to databáze — trigger `trg_events_dorovnani`
      // (migrace 20260827100000) nad funkcí `dorovnej_stab`.
      //
      // Dřív tu byl vlastní dopočet a měl tři vady, kvůli kterým by teď
      // s triggerem přímo BOJOVAL:
      //   • počítal podle `required_staff`, kdežto rozpis je v `role_reqs` —
      //     u akce se dvěma instruktory a barmanem by to viděl jako „3 směny"
      //     bez rolí a rozdíl by pořád dorovnával tam a zpátky;
      //   • zakládal směny BEZ `required_role`, takže se nedalo poznat, kdo je
      //     na co potřeba (a od migrace 20260827090000 by nedostaly ani sazbu
      //     z ceníku, jen záložních 150 Kč/h);
      //   • přebytek MAZAL natvrdo (`delete`), proti zásadě „nic nemazat
      //     natvrdo" — dorovnání ho ruší softly a s razítkem, kdo to udělal.
      // A selhání jen zapisoval do konzole, takže rozpor mezi akcí a štábem
      // vznikal tiše.
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['events'] });
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  const deleteEvent = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('events')
        .delete()
        .eq('id', id);

      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['events'] });
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  return {
    events,
    isLoading,
    createEvent: createEvent.mutateAsync,
    updateEvent: updateEvent.mutateAsync,
    deleteEvent: deleteEvent.mutateAsync,
    isCreating: createEvent.isPending,
    isUpdating: updateEvent.isPending,
    isDeleting: deleteEvent.isPending,
  };
};
