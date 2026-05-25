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

      // Sync shift slots to match new required_staff (commercial/recruitment only)
      try {
        const eventType = (updates.event_type ?? data.event_type) as string;
        if (eventType === 'commercial' || eventType === 'recruitment') {
          const desired = updates.required_staff ?? data.required_staff ?? 0;

          const { data: existing, error: fetchErr } = await supabase
            .from('shifts')
            .select('id, status')
            .eq('event_id', id);
          if (fetchErr) throw fetchErr;

          const currentCount = existing?.length ?? 0;
          const openIds = (existing ?? [])
            .filter((s) => s.status === 'open')
            .map((s) => s.id);

          if (desired > currentCount) {
            const toInsert = Array.from({ length: desired - currentCount }, () => ({
              event_id: id,
              status: 'open' as const,
            }));
            const { error: insErr } = await supabase.from('shifts').insert(toInsert);
            if (insErr) throw insErr;
          } else if (desired < currentCount) {
            const removeCount = Math.min(currentCount - desired, openIds.length);
            if (removeCount > 0) {
              const { error: delErr } = await supabase
                .from('shifts')
                .delete()
                .in('id', openIds.slice(0, removeCount));
              if (delErr) throw delErr;
            }
          }
        }
      } catch (syncErr) {
        console.error('Shift slot sync failed:', syncErr);
      }

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
