import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

export type SubjectRequest = Database['public']['Views']['subject_requests_list']['Row'];
export type RepLevel = Database['public']['Enums']['subject_rep_level'];

/**
 * Žádosti o přiřazení ke klubu.
 *
 * Zápis jde VÝHRADNĚ přes RPC — `subject_requests` nemá jedinou zápisovou
 * politiku a `subject_reps` pustí zápis jen adminovi. Kdyby to šlo z klienta,
 * stačilo by se zaregistrovat, vybrat si cizí klub a schválit si to.
 *
 * Úroveň (člen / zástupce) se přiděluje AŽ TADY, při schválení. V žádosti není
 * ani jako přání — rozhodnutí PM: zástupce nastavuje admin ručně.
 */
export const useSubjectRequests = () => {
  const { user, isAdmin } = useAuth();
  const qc = useQueryClient();

  const { data: requests = [], isLoading, error } = useQuery({
    queryKey: ['subject-requests', user?.id],
    queryFn: async () => {
      const { data, error: chyba } = await supabase
        .from('subject_requests_list')
        .select('*')
        .order('created_at', { ascending: true });   // nejstarší nahoře, ať nikdo nečeká věčně
      if (chyba) throw chyba;
      return (data ?? []) as SubjectRequest[];
    },
    enabled: !!user,
  });

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['subject-requests'] });
    // Schválením vzniklo členství — obrazovky, které z něj čtou, jsou teď staré.
    qc.invalidateQueries({ queryKey: ['subject-reps-admin'] });
    qc.invalidateQueries({ queryKey: ['my-memberships'] });
    qc.invalidateQueries({ queryKey: ['my-subjects'] });
  };

  /** Hláška z databáze je česká a konkrétní, tak ji nepřebalujeme. */
  const chyba = (e: { message?: string } | null, nahradni: string) =>
    new Error(e?.message?.trim() || nahradni);

  const approve = useMutation({
    mutationFn: async (p: { id: string; level: RepLevel }) => {
      const { data, error: e } = await supabase.rpc('approve_subject_request', {
        _request_id: p.id, _level: p.level,
      });
      if (e) throw chyba(e, 'Žádost se nepodařilo schválit.');
      return data as { id: string; level: RepLevel };
    },
    onSuccess: invalidate,
  });

  const reject = useMutation({
    mutationFn: async (p: { id: string; duvod?: string }) => {
      const { error: e } = await supabase.rpc('reject_subject_request', {
        _request_id: p.id, _duvod: p.duvod ?? undefined,
      });
      if (e) throw chyba(e, 'Žádost se nepodařilo zamítnout.');
    },
    onSuccess: invalidate,
  });

  const request = useMutation({
    mutationFn: async (p: { subjectId: string; poznamka?: string }) => {
      const { data, error: e } = await supabase.rpc('request_subject_membership', {
        _subject_id: p.subjectId, _poznamka: p.poznamka ?? undefined,
      });
      if (e) throw chyba(e, 'Žádost se nepodařilo podat.');
      return data as string;
    },
    onSuccess: invalidate,
  });

  const cekajici = requests.filter((r) => r.status === 'ceka');

  return {
    requests,
    cekajici,
    isLoading,
    error: error as Error | null,
    isAdmin,
    approve: approve.mutateAsync,
    reject: reject.mutateAsync,
    request: request.mutateAsync,
    isBusy: approve.isPending || reject.isPending || request.isPending,
  };
};
