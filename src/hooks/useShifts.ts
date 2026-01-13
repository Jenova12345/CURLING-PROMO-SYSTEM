import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export const useShifts = () => {
  const { user, isAdmin } = useAuth();
  const queryClient = useQueryClient();

  // Fetch all part-time staff for admin to assign shifts
  const { data: availableStaff = [] } = useQuery({
    queryKey: ['available-staff', isAdmin],
    queryFn: async () => {
      // Only fetch if admin
      if (!isAdmin) return [];
      
      const { data: roles, error: rolesError } = await supabase
        .from('user_roles')
        .select('user_id')
        .eq('role', 'part_time_staff');

      if (rolesError) throw rolesError;

      const userIds = roles.map(r => r.user_id);
      if (userIds.length === 0) return [];

      const { data: profiles, error: profilesError } = await supabase
        .from('profiles')
        .select('user_id, full_name')
        .in('user_id', userIds);

      if (profilesError) throw profilesError;

      return profiles.map(p => ({
        userId: p.user_id,
        fullName: p.full_name || 'Neznámý',
      }));
    },
    enabled: !!user,
  });

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

  // Admin completes all shifts for an event at once
  const completeEvent = useMutation({
    mutationFn: async ({ eventId, hoursWorked, hourlyRate, notes }: { 
      eventId: string; 
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
        .eq('event_id', eventId)
        .eq('status', 'claimed')
        .select();

      if (error) {
        throw new Error('Nepodařilo se dokončit směny.');
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

  // Admin directly assigns a staff member to a shift (open -> claimed, bypassing pending)
  const assignShift = useMutation({
    mutationFn: async ({ shiftId, staffId }: { shiftId: string; staffId: string }) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'claimed',
          claimed_by: staffId,
          claimed_at: new Date().toISOString(),
        })
        .eq('id', shiftId)
        .eq('status', 'open')
        .select()
        .single();

      if (error) {
        throw new Error('Nepodařilo se přiřadit směnu.');
      }
      return data;
    },
    onSuccess: () => {
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

  // Group open shifts by event_id for staff view (show one entry per event)
  const openShiftsByEvent = Object.values(
    openShifts.reduce((acc, shift) => {
      const eventId = shift.event_id;
      if (!acc[eventId]) {
        // Count total slots for this event (all shifts regardless of status)
        const totalSlots = shifts.filter(s => s.event_id === eventId).length;
        acc[eventId] = {
          eventId,
          event: shift.event,
          hourlyRate: shift.hourly_rate,
          availableShiftIds: [],
          openCount: 0,
          totalSlots,
        };
      }
      acc[eventId].availableShiftIds.push(shift.id);
      acc[eventId].openCount += 1;
      return acc;
    }, {} as Record<string, { eventId: string; event: any; hourlyRate: number | null; availableShiftIds: string[]; openCount: number; totalSlots: number }>)
  );
  
  // Pending shifts for admin approval
  const pendingShifts = shifts.filter(s => s.status === 'pending');
  
  // Claimed shifts ready to be completed (event has passed)
  const shiftsToComplete = shifts.filter(s => {
    if (s.status !== 'claimed') return false;
    if (!s.event?.end_time) return false;
    return new Date(s.event.end_time) < new Date();
  });

  // Group shifts to complete by event (for admin to complete whole events at once)
  const eventsToComplete = Object.values(
    shiftsToComplete.reduce((acc, shift) => {
      const eventId = shift.event_id;
      if (!acc[eventId]) {
        acc[eventId] = {
          eventId,
          event: shift.event,
          hourlyRate: shift.hourly_rate,
          shifts: [],
          staffNames: [],
        };
      }
      acc[eventId].shifts.push(shift);
      if (shift.claimed_profile?.full_name) {
        acc[eventId].staffNames.push(shift.claimed_profile.full_name);
      }
      return acc;
    }, {} as Record<string, { eventId: string; event: any; hourlyRate: number | null; shifts: any[]; staffNames: string[] }>)
  );
  
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

  // Admin statistics
  const allCompletedShifts = shifts.filter(s => s.status === 'completed');
  
  const adminStats = {
    totalPaidOut: 0, // Will be calculated from payouts in component
    totalHoursAllStaff: allCompletedShifts.reduce((sum, s) => sum + (Number(s.hours_worked) || 0), 0),
    totalEarningsAllStaff: allCompletedShifts.reduce((sum, s) => sum + (Number(s.hours_worked) || 0) * (Number(s.hourly_rate) || 150), 0),
    unpaidTotal: allCompletedShifts.filter(s => !s.payout_id).reduce((sum, s) => sum + (Number(s.hours_worked) || 0) * (Number(s.hourly_rate) || 150), 0),
    activeStaffCount: new Set(allCompletedShifts.map(s => s.claimed_by)).size,
    completedShiftsCount: allCompletedShifts.length,
    
    // Per-staff breakdown
    staffStats: allCompletedShifts.reduce((acc, shift) => {
      const staffId = shift.claimed_by;
      if (!staffId) return acc;
      
      const hours = Number(shift.hours_worked) || 0;
      const earnings = hours * (Number(shift.hourly_rate) || 150);
      const isPaid = !!shift.payout_id;
      
      if (!acc[staffId]) {
        acc[staffId] = {
          staffId,
          staffName: shift.claimed_profile?.full_name || 'Neznámý',
          shiftsCount: 0,
          hoursWorked: 0,
          totalEarnings: 0,
          paidAmount: 0,
          unpaidAmount: 0,
        };
      }
      
      acc[staffId].shiftsCount += 1;
      acc[staffId].hoursWorked += hours;
      acc[staffId].totalEarnings += earnings;
      if (isPaid) {
        acc[staffId].paidAmount += earnings;
      } else {
        acc[staffId].unpaidAmount += earnings;
      }
      
      return acc;
    }, {} as Record<string, { staffId: string; staffName: string; shiftsCount: number; hoursWorked: number; totalEarnings: number; paidAmount: number; unpaidAmount: number }>),
  };

  return {
    shifts,
    openShifts,
    openShiftsByEvent,
    availableStaff,
    myShifts,
    myUnpaidShifts,
    pendingShifts,
    shiftsToComplete,
    eventsToComplete,
    staffUnpaidAmounts: Object.values(staffUnpaidAmounts),
    adminStats: {
      ...adminStats,
      staffStats: Object.values(adminStats.staffStats),
    },
    isLoading,
    requestShift: requestShift.mutateAsync,
    approveShift: approveShift.mutateAsync,
    rejectShift: rejectShift.mutateAsync,
    completeShift: completeShift.mutateAsync,
    completeEvent: completeEvent.mutateAsync,
    cancelRequest: cancelRequest.mutateAsync,
    cancelShift: cancelShift.mutateAsync,
    assignShift: assignShift.mutateAsync,
    isRequesting: requestShift.isPending,
    isApproving: approveShift.isPending,
    isRejecting: rejectShift.isPending,
    isCompleting: completeShift.isPending || completeEvent.isPending,
    isAssigning: assignShift.isPending,
    totalHoursWorked,
    unpaidEarnings,
    totalEarnings,
  };
};
