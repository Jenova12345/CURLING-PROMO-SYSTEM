import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

export type Subject = Database['public']['Tables']['subjects']['Row'];
export type SubjectType = Database['public']['Enums']['subject_type'];
export type RepLevel = Database['public']['Enums']['subject_rep_level'];
export type RepRow = { id: string; subject_id: string; user_id: string; level: RepLevel; member_name?: string };
export type ProfileLite = { user_id: string; full_name: string | null };

// Správa subjektů (kluby/firmy) + přiřazení lidí. Vše admin (RLS). ARES přes edge funkci.
export const useSubjectsAdmin = () => {
  const { user, isAdmin } = useAuth();
  const qc = useQueryClient();

  const { data: subjects = [], isLoading } = useQuery({
    queryKey: ['subjects-admin'],
    queryFn: async () => {
      const { data, error } = await supabase.from('subjects').select('*').is('deleted_at', null).order('type').order('name');
      if (error) throw error;
      return (data ?? []) as Subject[];
    },
    enabled: !!user && isAdmin,
  });

  const { data: reps = [] } = useQuery({
    queryKey: ['subject-reps-admin'],
    queryFn: async () => {
      const { data, error } = await supabase.from('subject_reps').select('id, subject_id, user_id, level');
      if (error) throw error;
      const rows = (data ?? []) as RepRow[];
      const ids = [...new Set(rows.map((r) => r.user_id))];
      if (ids.length) {
        const { data: profs } = await supabase.from('profiles_public').select('user_id, full_name').in('user_id', ids);
        const map: Record<string, string> = {};
        (profs ?? []).forEach((p: ProfileLite) => { if (p.user_id) map[p.user_id] = p.full_name || 'Neznámý'; });
        return rows.map((r) => ({ ...r, member_name: map[r.user_id] ?? 'Neznámý' }));
      }
      return rows;
    },
    enabled: !!user && isAdmin,
  });

  const { data: profiles = [] } = useQuery({
    queryKey: ['profiles-lite'],
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles_public').select('user_id, full_name').order('full_name');
      if (error) throw error;
      return (data ?? []) as ProfileLite[];
    },
    enabled: !!user && isAdmin,
  });

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['subjects-admin'] });
    qc.invalidateQueries({ queryKey: ['my-subjects'] });
    qc.invalidateQueries({ queryKey: ['subject-reps-admin'] });
    qc.invalidateQueries({ queryKey: ['my-memberships'] });
  };

  const aresLookup = async (ico: string): Promise<{ name: string; address: string; dic: string }> => {
    const { data, error } = await supabase.functions.invoke('ares-lookup', { body: { ico } });
    if (error) throw new Error('Nepodařilo se spojit s ARESem.');
    if (data?.error) throw new Error(data.error);
    return data as { name: string; address: string; dic: string };
  };

  // Existuje už subjekt s tímhle IČO? (server — cizí subjekty admin sice vidí, ale
  // kontrola musí projít i soft-smazané/cizí případy jednotně)
  const findSubjectByIco = async (ico: string): Promise<Subject | null> => {
    const { data, error } = await supabase.rpc('find_subject_by_ico', { p_ico: ico });
    if (error) throw new Error('Ověření IČO selhalo.');
    return ((data ?? []) as Subject[])[0] ?? null;
  };

  const createSubject = useMutation({
    mutationFn: async (s: { type: SubjectType; name: string; ico?: string; dic?: string; address?: string; default_rate?: number | null }) => {
      const { error } = await supabase.from('subjects').insert({
        type: s.type, name: s.name, ico: s.ico || null, dic: s.dic || null, address: s.address || null, default_rate: s.default_rate ?? null,
      });
      if (error) {
        if (error.code === '23505') throw new Error('Subjekt s tímto IČO už v systému je.');
        throw new Error('Nepodařilo se založit subjekt.');
      }
    },
    onSuccess: invalidate,
  });

  const updateSubject = useMutation({
    mutationFn: async ({ id, fields }: { id: string; fields: Partial<Pick<Subject, 'name' | 'ico' | 'dic' | 'address' | 'default_rate'>> }) => {
      const { error } = await supabase.from('subjects').update(fields).eq('id', id);
      if (error) throw new Error('Nepodařilo se upravit subjekt.');
    },
    onSuccess: invalidate,
  });

  const deleteSubject = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('subjects').update({ deleted_at: new Date().toISOString() }).eq('id', id);
      if (error) throw new Error('Nepodařilo se smazat subjekt.');
    },
    onSuccess: invalidate,
  });

  const addRep = useMutation({
    mutationFn: async (r: { subject_id: string; user_id: string; level: RepLevel }) => {
      const { error } = await supabase.from('subject_reps').insert(r);
      if (error) throw new Error(error.message.includes('duplicate') ? 'Tento uživatel už u subjektu je.' : 'Nepodařilo se přiřadit.');
    },
    onSuccess: invalidate,
  });

  const updateRep = useMutation({
    mutationFn: async ({ id, level }: { id: string; level: RepLevel }) => {
      const { error } = await supabase.from('subject_reps').update({ level }).eq('id', id);
      if (error) throw new Error('Nepodařilo se změnit úroveň.');
    },
    onSuccess: invalidate,
  });

  const removeRep = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('subject_reps').delete().eq('id', id);
      if (error) throw new Error('Nepodařilo se odebrat.');
    },
    onSuccess: invalidate,
  });

  return {
    subjects, reps, profiles, isLoading, aresLookup, findSubjectByIco,
    createSubject: createSubject.mutateAsync,
    updateSubject: updateSubject.mutateAsync,
    deleteSubject: deleteSubject.mutateAsync,
    addRep: addRep.mutateAsync,
    updateRep: updateRep.mutateAsync,
    removeRep: removeRep.mutateAsync,
    isBusy: createSubject.isPending || updateSubject.isPending || deleteSubject.isPending || addRep.isPending || updateRep.isPending || removeRep.isPending,
  };
};
