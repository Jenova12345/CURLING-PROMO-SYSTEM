import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export const useProfile = () => {
  const { user, profile } = useAuth();
  const queryClient = useQueryClient();

  const updateProfile = useMutation({
    mutationFn: async ({ 
      fullName, 
      phone, 
      avatarUrl,
      bankAccount,
    }: { 
      fullName?: string; 
      phone?: string;
      avatarUrl?: string;
      bankAccount?: string;
    }) => {
      const updateData: Record<string, any> = {};
      if (fullName !== undefined) updateData.full_name = fullName;
      if (phone !== undefined) updateData.phone = phone;
      if (avatarUrl !== undefined) updateData.avatar_url = avatarUrl;
      if (bankAccount !== undefined) updateData.bank_account = bankAccount;

      const { data, error } = await supabase
        .from('profiles')
        .update(updateData)
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

  const uploadAvatar = async (file: File): Promise<string> => {
    if (!user) throw new Error('Uživatel není přihlášen.');

    const fileExt = file.name.split('.').pop();
    const fileName = `${Date.now()}.${fileExt}`;
    const filePath = `${user.id}/${fileName}`;

    // Delete old avatar if exists
    if (profile?.avatar_url) {
      const oldPath = profile.avatar_url.split('/avatars/')[1];
      if (oldPath) {
        await supabase.storage.from('avatars').remove([oldPath]);
      }
    }

    const { error: uploadError } = await supabase.storage
      .from('avatars')
      .upload(filePath, file, { upsert: true });

    if (uploadError) throw new Error('Nepodařilo se nahrát obrázek.');

    const { data } = supabase.storage
      .from('avatars')
      .getPublicUrl(filePath);

    return data.publicUrl;
  };

  return {
    updateProfile: updateProfile.mutateAsync,
    isUpdating: updateProfile.isPending,
    uploadAvatar,
  };
};
