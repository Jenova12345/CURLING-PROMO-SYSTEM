import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export const useProfile = () => {
  const { user } = useAuth();
  const queryClient = useQueryClient();

  const updateProfile = useMutation({
    mutationFn: async ({ 
      fullName, 
      phone, 
      bankAccount,
    }: { 
      fullName?: string; 
      phone?: string;
      bankAccount?: string;
    }) => {
      const updateData: Record<string, any> = {};
      if (fullName !== undefined) updateData.full_name = fullName;
      if (phone !== undefined) updateData.phone = phone;
      if (bankAccount !== undefined) updateData.bank_account = bankAccount;

      const { data, error } = await supabase
        .from('profiles')
        .update(updateData as any)
        .eq('user_id', user?.id)
        .select()
        .single();

      if (error) throw new Error('Nepodařilo se aktualizovat profil.');
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['profile'] });
    },
  });

  return {
    updateProfile: updateProfile.mutateAsync,
    isUpdating: updateProfile.isPending,
  };
};
