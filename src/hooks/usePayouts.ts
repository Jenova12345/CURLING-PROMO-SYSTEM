import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export const usePayouts = () => {
  const { user, isAdmin } = useAuth();
  const queryClient = useQueryClient();

  // Fetch all payouts (admin sees all, staff sees their own)
  const { data: payouts = [], isLoading: isLoadingPayouts } = useQuery({
    queryKey: ['payouts'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('payouts')
        .select(`
          *,
          profile:profiles!payouts_user_id_fkey(full_name),
          created_by_profile:profiles!payouts_created_by_fkey(full_name)
        `)
        .order('paid_at', { ascending: false });

      if (error) throw error;
      return data;
    },
    enabled: !!user,
  });

  // Create a payout for a staff member
  const createPayout = useMutation({
    mutationFn: async ({ userId, amount, notes }: { 
      userId: string; 
      amount: number;
      notes?: string;
    }) => {
      // 1. Create payout record
      const { data: payout, error: payoutError } = await supabase
        .from('payouts')
        .insert({
          user_id: userId,
          amount,
          notes,
          created_by: user?.id,
        })
        .select()
        .single();

      if (payoutError) throw new Error('Nepodařilo se vytvořit výplatu.');

      // 2. Link all unpaid completed shifts to this payout
      const { error: shiftsError } = await supabase
        .from('shifts')
        .update({ payout_id: payout.id })
        .eq('claimed_by', userId)
        .eq('status', 'completed')
        .is('payout_id', null);

      if (shiftsError) throw new Error('Nepodařilo se propojit směny s výplatou.');

      return payout;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['payouts'] });
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Get my payouts (for staff)
  const myPayouts = payouts.filter(p => p.user_id === user?.id);

  return {
    payouts,
    myPayouts,
    isLoadingPayouts,
    createPayout: createPayout.mutateAsync,
    isCreatingPayout: createPayout.isPending,
  };
};
