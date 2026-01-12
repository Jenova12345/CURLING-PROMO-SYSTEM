import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export const useShifts = () => {
  const { user } = useAuth();
  const queryClient = useQueryClient();

  const { data: shifts = [], isLoading } = useQuery({
    queryKey: ['shifts'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('shifts')
        .select(`
          *,
          event:events(*)
        `)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return data;
    },
    enabled: !!user,
  });

  const claimShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'claimed',
          claimed_by: user?.id,
          claimed_at: new Date().toISOString(),
        })
        .eq('id', shiftId)
        .eq('status', 'open')
        .select()
        .single();

      if (error) {
        // Parse specific error messages from trigger
        if (error.message.includes('již byla obsazena')) {
          throw new Error('Směna již byla obsazena někým jiným.');
        }
        if (error.message.includes('již máte jinou směnu')) {
          throw new Error('Na této akci již máte jinou směnu.');
        }
        throw new Error('Nepodařilo se převzít směnu.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
    onError: () => {
      // Refetch to sync state after error
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  const completeShift = useMutation({
    mutationFn: async ({ shiftId, hoursWorked, notes }: { 
      shiftId: string; 
      hoursWorked: number;
      notes?: string;
    }) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'completed',
          hours_worked: hoursWorked,
          notes,
        })
        .eq('id', shiftId)
        .select()
        .single();

      if (error) throw new Error('Nepodařilo se dokončit směnu.');
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  const cancelShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'open',
          claimed_by: null,
          claimed_at: null,
        })
        .eq('id', shiftId)
        .select()
        .single();

      if (error) {
        if (error.message.includes('cizí směnu')) {
          throw new Error('Nemůžete zrušit cizí směnu.');
        }
        throw new Error('Nepodařilo se zrušit směnu.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
    onError: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  const myShifts = shifts.filter(s => s.claimed_by === user?.id);
  
  // Get event IDs where the user already has a claimed or completed shift
  const myEventIds = new Set(
    myShifts
      .filter(s => s.status === 'claimed' || s.status === 'completed')
      .map(s => s.event_id)
  );
  
  // Filter open shifts - exclude events where user already has a shift
  const openShifts = shifts.filter(s => 
    s.status === 'open' && !myEventIds.has(s.event_id)
  );
  const myCompletedShifts = myShifts.filter(s => s.status === 'completed');
  
  const totalHoursWorked = myCompletedShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0), 
    0
  );
  
  const totalEarnings = myCompletedShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0) * (Number(shift.hourly_rate) || 150),
    0
  );

  return {
    shifts,
    openShifts,
    myShifts,
    isLoading,
    claimShift: claimShift.mutateAsync,
    completeShift: completeShift.mutateAsync,
    cancelShift: cancelShift.mutateAsync,
    isClaiming: claimShift.isPending,
    totalHoursWorked,
    totalEarnings,
  };
};
