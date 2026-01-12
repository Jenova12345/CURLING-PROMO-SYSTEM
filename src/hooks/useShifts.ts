import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export const useShifts = () => {
  const { user, isAdmin } = useAuth();
  const queryClient = useQueryClient();

  const { data: shifts = [], isLoading } = useQuery({
    queryKey: ['shifts'],
    queryFn: async () => {
      // First get shifts with events
      const { data: shiftsData, error } = await supabase
        .from('shifts')
        .select(`
          *,
          event:events(*)
        `)
        .order('created_at', { ascending: false });

      if (error) throw error;
      
      // Get unique claimed_by user IDs
      const userIds = [...new Set(shiftsData.filter(s => s.claimed_by).map(s => s.claimed_by!))];
      
      // Fetch profiles for those users
      let profilesMap: Record<string, string> = {};
      if (userIds.length > 0) {
        const { data: profiles } = await supabase
          .from('profiles')
          .select('user_id, full_name')
          .in('user_id', userIds);
        
        if (profiles) {
          profilesMap = profiles.reduce((acc, p) => {
            acc[p.user_id] = p.full_name || 'Neznámý';
            return acc;
          }, {} as Record<string, string>);
        }
      }
      
      // Merge profile names into shifts
      return shiftsData.map(shift => ({
        ...shift,
        claimed_profile: shift.claimed_by ? { full_name: profilesMap[shift.claimed_by] || 'Neznámý' } : null,
      }));
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

  // Admin completes shift (claimed -> completed)
  const completeShift = useMutation({
    mutationFn: async ({ shiftId, hoursWorked, hourlyRate, notes }: { 
      shiftId: string; 
      hoursWorked: number;
      hourlyRate: number;
      notes?: string;
    }) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'completed',
          hours_worked: hoursWorked,
          hourly_rate: hourlyRate,
          notes,
          completed_at: new Date().toISOString(),
        })
        .eq('id', shiftId)
        .eq('status', 'claimed')
        .select()
        .single();

      if (error) {
        if (error.message.includes('Pouze admin')) {
          throw new Error('Pouze admin může dokončit směnu.');
        }
        if (error.message.includes('odpracované hodiny')) {
          throw new Error('Musíte zadat odpracované hodiny.');
        }
        throw new Error('Nepodařilo se dokončit směnu.');
      }
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
  
  // Claimed shifts ready to be completed (event has passed)
  const shiftsToComplete = shifts.filter(s => {
    if (s.status !== 'claimed') return false;
    if (!s.event?.end_time) return false;
    return new Date(s.event.end_time) < new Date();
  });
  
  // My completed unpaid shifts
  const myUnpaidShifts = myShifts.filter(s => s.status === 'completed' && !s.payout_id);
  
  const myCompletedShifts = myShifts.filter(s => s.status === 'completed');
  
  const totalHoursWorked = myCompletedShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0), 
    0
  );
  
  // Unpaid earnings (only completed shifts without payout_id)
  const unpaidEarnings = myUnpaidShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0) * (Number(shift.hourly_rate) || 150),
    0
  );
  
  // Total earnings (all completed shifts)
  const totalEarnings = myCompletedShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0) * (Number(shift.hourly_rate) || 150),
    0
  );

  // Get unpaid amounts per staff member (for admin)
  const staffUnpaidAmounts = shifts
    .filter(s => s.status === 'completed' && !s.payout_id && s.claimed_by)
    .reduce((acc, shift) => {
      const staffId = shift.claimed_by!;
      const amount = (Number(shift.hours_worked) || 0) * (Number(shift.hourly_rate) || 150);
      if (!acc[staffId]) {
        acc[staffId] = {
          staffId,
          staffName: shift.claimed_profile?.full_name || 'Neznámý',
          amount: 0,
          shiftCount: 0,
        };
      }
      acc[staffId].amount += amount;
      acc[staffId].shiftCount += 1;
      return acc;
    }, {} as Record<string, { staffId: string; staffName: string; amount: number; shiftCount: number }>);

  return {
    shifts,
    openShifts,
    myShifts,
    myUnpaidShifts,
    pendingShifts,
    shiftsToComplete,
    staffUnpaidAmounts: Object.values(staffUnpaidAmounts),
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
    isCompleting: completeShift.isPending,
    totalHoursWorked,
    unpaidEarnings,
    totalEarnings,
  };
};
