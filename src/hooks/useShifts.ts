import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export const useShifts = () => {
  const { user, isAdmin } = useAuth();
  const queryClient = useQueryClient();

  const { data: shifts = [], isLoading } = useQuery({
    queryKey: ['shifts'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('shifts')
        .select(`
          *,
          event:events(*),
          claimed_profile:profiles!shifts_claimed_by_fkey(full_name)
        `)
        .order('created_at', { ascending: false });

      if (error) throw error;
      return data;
    },
    enabled: !!user,
  });

  // Staff requests a shift (open -> pending)
  const requestShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'pending',
          claimed_by: user?.id,
          claimed_at: new Date().toISOString(),
        })
        .eq('id', shiftId)
        .eq('status', 'open')
        .select()
        .single();

      if (error) {
        if (error.message.includes('již byla obsazena')) {
          throw new Error('Směna již byla obsazena někým jiným.');
        }
        if (error.message.includes('již máte jinou směnu')) {
          throw new Error('Na této akci již máte jinou směnu.');
        }
        throw new Error('Nepodařilo se přihlásit na směnu.');
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

  // Admin approves shift (pending -> claimed)
  const approveShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'claimed',
        })
        .eq('id', shiftId)
        .eq('status', 'pending')
        .select()
        .single();

      if (error) {
        throw new Error('Nepodařilo se schválit směnu.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Admin rejects shift (pending -> open)
  const rejectShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'open',
          claimed_by: null,
          claimed_at: null,
        })
        .eq('id', shiftId)
        .eq('status', 'pending')
        .select()
        .single();

      if (error) {
        throw new Error('Nepodařilo se odmítnout přihlášku.');
      }
      return data;
    },
    onSuccess: () => {
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

  // Staff cancels their pending request
  const cancelRequest = useMutation({
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
        if (error.message.includes('cizí přihlášku')) {
          throw new Error('Nemůžete zrušit cizí přihlášku.');
        }
        throw new Error('Nepodařilo se zrušit přihlášku.');
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

  // Cancel claimed shift
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
  
  // Get event IDs where the user already has a pending, claimed or completed shift
  const myEventIds = new Set(
    myShifts
      .filter(s => s.status === 'pending' || s.status === 'claimed' || s.status === 'completed')
      .map(s => s.event_id)
  );
  
  // Filter open shifts - exclude events where user already has a shift
  const openShifts = shifts.filter(s => 
    s.status === 'open' && !myEventIds.has(s.event_id)
  );
  
  // Pending shifts for admin approval
  const pendingShifts = shifts.filter(s => s.status === 'pending');
  
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
    pendingShifts,
    isLoading,
    requestShift: requestShift.mutateAsync,
    approveShift: approveShift.mutateAsync,
    rejectShift: rejectShift.mutateAsync,
    completeShift: completeShift.mutateAsync,
    cancelRequest: cancelRequest.mutateAsync,
    cancelShift: cancelShift.mutateAsync,
    isRequesting: requestShift.isPending,
    isApproving: approveShift.isPending,
    isRejecting: rejectShift.isPending,
    totalHoursWorked,
    totalEarnings,
  };
};
