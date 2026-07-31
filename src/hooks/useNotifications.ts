import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export type Notification = {
  id: string;
  type: string;
  title: string;
  body: string | null;
  link: string | null;
  reservation_id: string | null;
  subject_id: string | null;
  read_at: string | null;
  created_at: string;
};

// Upozornění v aplikaci (zrušená akce, rezervace čekající na potvrzení, potvrzení…).
// Zakládá je server (triggery a RPC funkce); klient je smí jen číst a označit přečtené.
export const useNotifications = () => {
  const { user } = useAuth();
  const qc = useQueryClient();

  const { data: notifications = [], isLoading } = useQuery({
    queryKey: ['notifications'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('notifications')
        .select('id, type, title, body, link, reservation_id, subject_id, read_at, created_at')
        .order('created_at', { ascending: false })
        .limit(50);
      if (error) throw error;
      return (data ?? []) as Notification[];
    },
    enabled: !!user,
    refetchInterval: 60_000, // stačí občas — nejde o chat
  });

  const unreadCount = notifications.filter((n) => !n.read_at).length;

  const invalidate = () => qc.invalidateQueries({ queryKey: ['notifications'] });

  const markRead = useMutation({
    mutationFn: async (ids: string[]) => {
      if (!ids.length) return;
      const { error } = await supabase
        .from('notifications')
        .update({ read_at: new Date().toISOString() })
        .in('id', ids);
      if (error) throw new Error('Nepodařilo se označit upozornění jako přečtené.');
    },
    onSuccess: invalidate,
  });

  return {
    notifications,
    unreadCount,
    isLoading,
    markRead: markRead.mutateAsync,
    markAllRead: () => markRead.mutateAsync(notifications.filter((n) => !n.read_at).map((n) => n.id)),
  };
};
