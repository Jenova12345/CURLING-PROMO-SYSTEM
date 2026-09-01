import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export interface ShiftApplication {
  id: string;
  shift_id: string;
  user_id: string;
  status: 'pending' | 'approved' | 'rejected' | 'cancelled';
  created_at: string;
  updated_at: string;
  applicant_name?: string;
}

export const useShiftApplications = () => {
  const { user, isAdmin } = useAuth();
  const queryClient = useQueryClient();

  const { data: applications = [], isLoading } = useQuery({
    queryKey: ['shift_applications'],
    queryFn: async () => {
      // ŘADÍ SE PODLE DATA AKCE, ne podle pořadí zadání.
      //
      // `created_at` je okamžik, kdy někdo přihlášku odeslal — pro toho, kdo
      // frontu vyřizuje, je to nezajímavé číslo, které navíc míchá dohromady
      // směny z různých dnů. Rozhoduje, co je nejdřív na řadě.
      //
      // Datum se dotahuje přes vnořený `shift → event`. Seřadit se to musí
      // AŽ TADY, ne v dotazu: PostgREST umí `order` jen přes jednu úroveň
      // vnoření, a tohle jsou dvě.
      const { data, error } = await (supabase as any)
        .from('shift_applications')
        .select('*, shift:shifts(event_id, event:events(start_time))');
      if (error) throw error;

      const kdy = (a: any) => a?.shift?.event?.start_time ?? a?.created_at ?? '';
      const apps = ((data || []) as any[])
        .sort((x, y) => kdy(x).localeCompare(kdy(y))) as ShiftApplication[];
      const userIds = [...new Set(apps.map(a => a.user_id))];
      if (userIds.length > 0) {
        const { data: profiles } = await supabase
          .from('profiles_public')
          .select('user_id, full_name')
          .in('user_id', userIds);
        const map: Record<string, string> = {};
        (profiles || []).forEach((p: any) => {
          if (p.user_id) map[p.user_id] = p.full_name || 'Neznámý';
        });
        return apps.map(a => ({ ...a, applicant_name: map[a.user_id] || 'Neznámý' }));
      }
      return apps;
    },
    enabled: !!user,
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ['shift_applications'] });
    queryClient.invalidateQueries({ queryKey: ['shifts'] });
  };

  // Worker applies to a shift (upsert — re-apply allowed after rejected/cancelled)
  const applyToShift = useMutation({
    mutationFn: async (shiftId: string) => {
      if (!user) throw new Error('Nepřihlášený uživatel.');
      const { data, error } = await (supabase as any)
        .from('shift_applications')
        .upsert(
          { shift_id: shiftId, user_id: user.id, status: 'pending', updated_at: new Date().toISOString() },
          { onConflict: 'shift_id,user_id' }
        )
        .select()
        .single();
      if (error) throw new Error(error.message || 'Nepodařilo se přihlásit.');
      return data;
    },
    onSuccess: invalidate,
  });

  // Worker cancels own application
  const cancelMyApplication = useMutation({
    mutationFn: async (applicationId: string) => {
      const { error } = await (supabase as any)
        .from('shift_applications')
        .update({ status: 'cancelled' })
        .eq('id', applicationId);
      if (error) throw new Error('Nepodařilo se zrušit přihlášku.');
    },
    onSuccess: invalidate,
  });

  // Admin approves: app -> approved, shift -> claimed, other pending apps -> rejected
  const approveApplication = useMutation({
    mutationFn: async (applicationId: string) => {
      const app = applications.find(a => a.id === applicationId);
      if (!app) throw new Error('Přihláška nenalezena.');

      // Update shift -> claimed
      const { data: shiftData, error: shiftErr } = await supabase
        .from('shifts')
        .update({
          status: 'claimed',
          claimed_by: app.user_id,
          claimed_at: new Date().toISOString(),
        })
        .eq('id', app.shift_id)
        .eq('status', 'open')
        .select()
        .single();
      if (shiftErr || !shiftData) {
        throw new Error('Směna již byla obsazena nebo není volná.');
      }

      // Update this app -> approved
      const { error: appErr } = await (supabase as any)
        .from('shift_applications')
        .update({ status: 'approved' })
        .eq('id', applicationId);
      if (appErr) throw new Error('Nepodařilo se schválit přihlášku.');

      // Reject other pending apps on the same shift
      await (supabase as any)
        .from('shift_applications')
        .update({ status: 'rejected' })
        .eq('shift_id', app.shift_id)
        .eq('status', 'pending')
        .neq('id', applicationId);
    },
    onSuccess: invalidate,
  });

  // Admin rejects a single pending application
  const rejectApplication = useMutation({
    mutationFn: async (applicationId: string) => {
      const { error } = await (supabase as any)
        .from('shift_applications')
        .update({ status: 'rejected' })
        .eq('id', applicationId);
      if (error) throw new Error('Nepodařilo se zamítnout přihlášku.');
    },
    onSuccess: invalidate,
  });

  // Admin revokes approval: app -> cancelled, shift -> open
  const revokeApproval = useMutation({
    mutationFn: async (applicationId: string) => {
      const app = applications.find(a => a.id === applicationId);
      if (!app) throw new Error('Přihláška nenalezena.');

      const { error: shiftErr } = await supabase
        .from('shifts')
        .update({ status: 'open', claimed_by: null, claimed_at: null })
        .eq('id', app.shift_id);
      if (shiftErr) throw new Error('Nepodařilo se uvolnit směnu.');

      const { error: appErr } = await (supabase as any)
        .from('shift_applications')
        .update({ status: 'cancelled' })
        .eq('id', applicationId);
      if (appErr) throw new Error('Nepodařilo se odebrat přihlášku.');
    },
    onSuccess: invalidate,
  });

  const myApplications = applications.filter(a => a.user_id === user?.id);

  const applicationsByShift = applications.reduce((acc, app) => {
    if (!acc[app.shift_id]) acc[app.shift_id] = [];
    acc[app.shift_id].push(app);
    return acc;
  }, {} as Record<string, ShiftApplication[]>);

  // Pending applications grouped (for admin view)
  const pendingApplications = applications.filter(a => a.status === 'pending');

  return {
    applications,
    myApplications,
    applicationsByShift,
    pendingApplications,
    isLoading,
    applyToShift: applyToShift.mutateAsync,
    cancelMyApplication: cancelMyApplication.mutateAsync,
    approveApplication: approveApplication.mutateAsync,
    rejectApplication: rejectApplication.mutateAsync,
    revokeApproval: revokeApproval.mutateAsync,
    isApplying: applyToShift.isPending,
    isApproving: approveApplication.isPending,
    isRejecting: rejectApplication.isPending,
    isRevoking: revokeApproval.isPending,
    isCancelling: cancelMyApplication.isPending,
  };
};
