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

      // `.select()` tu být NESMÍ: vynutilo by `return=representation`, které
      // potřebuje SELECT na měněné sloupce — a `phone` s `bank_account` jsou
      // po A5 v tabulce nečitelné (vydává je pohled `profiles_self`).
      //
      // `count: 'exact'` místo toho: UPDATE zahozený RLS totiž NENÍ chyba,
      // PostgREST vrátí 204 a uživatel by dostal „uloženo", i kdyby se nic
      // nezměnilo. Aktuální hodnoty si stejně natáhne invalidace níž.
      const { error, count } = await supabase
        .from('profiles')
        .update(updateData as any, { count: 'exact' })
        .eq('user_id', user?.id);

      if (error) throw new Error('Nepodařilo se aktualizovat profil.');
      if (count !== 1) throw new Error('Profil se neuložil — databáze změnu odmítla.');
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
