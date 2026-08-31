import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import type { Database } from '@/integrations/supabase/types';

export type RepLevel = Database['public']['Enums']['subject_rep_level'];

export interface ClenKlubu {
  user_id: string;
  jmeno: string;
  level: RepLevel;
  muze_potvrzovat: boolean;
}

export interface MujKlub {
  subject_id: string;
  nazev: string;
  clenove: ClenKlubu[];
}

/**
 * Klub(y), kterých je přihlášený ZÁSTUPCEM, i s jejich členy.
 *
 * SCHVÁLNĚ NENÍ ROZŠÍŘENÍM `useSubjectsAdmin`. Ten píše do `subjects`
 * a `subject_reps` napřímo přes PostgREST a je celý admin-only; zástupci se ta
 * práva nemají nabídnout ani omylem. Tenhle hook proto jen ČTE, a jedinou věc,
 * kterou mění, dělá přes RPC `nastav_pravo_navic` — tedy přes funkci, která si
 * oprávnění ověří sama.
 *
 * Že zástupce vidí členy svého klubu, umožnila až migrace
 * `20260831160000_zastupce_vidi_klub.sql`. Do té doby mu `subject_reps` vracely
 * jediný řádek — jeho vlastní.
 */
export const useMujKlub = () => {
  const { user, isRep, isAdmin } = useAuth();
  const qc = useQueryClient();

  const { data: kluby = [], isLoading, error } = useQuery({
    queryKey: ['muj-klub', user?.id],
    queryFn: async (): Promise<MujKlub[]> => {
      // 1) Ve kterých klubech jsem zástupce. Vlastní řádek vidím vždycky,
      //    takže tenhle dotaz funguje i bez rozšířené politiky.
      const { data: moje, error: e1 } = await supabase
        .from('subject_reps')
        .select('subject_id, level')
        .eq('user_id', user!.id)
        .eq('level', 'rep');
      if (e1) throw e1;

      const ids = (moje ?? []).map((r) => r.subject_id);
      if (ids.length === 0) return [];

      // 2) Členové těch klubů. RLS vydá jen kluby, kde jsem zástupce —
      //    filtr `.in()` je tu kvůli srozumitelnosti dotazu, ne kvůli
      //    bezpečnosti. Tu drží politika, ne tenhle řádek.
      const { data: clenove, error: e2 } = await supabase
        .from('subject_reps')
        .select('subject_id, user_id, level, muze_potvrzovat')
        .in('subject_id', ids);
      if (e2) throw e2;

      // 3) Jména. `profiles_public` vydává `full_name` každému přihlášenému;
      //    telefon a číslo účtu z něj vidí jen vlastník a admin.
      const userIds = [...new Set((clenove ?? []).map((c) => c.user_id))];
      const jmena: Record<string, string> = {};
      if (userIds.length > 0) {
        const { data: profily } = await supabase
          .from('profiles_public')
          .select('user_id, full_name')
          .in('user_id', userIds);
        for (const p of profily ?? []) {
          jmena[p.user_id as string] = (p.full_name as string) ?? '(bez jména)';
        }
      }

      // 4) Názvy klubů z veřejného seznamu.
      const { data: nazvy } = await supabase
        .from('clubs_public')
        .select('id, name')
        .in('id', ids);
      const podleId: Record<string, string> = {};
      for (const k of nazvy ?? []) podleId[k.id as string] = k.name as string;

      return ids.map((sid) => ({
        subject_id: sid,
        nazev: podleId[sid] ?? '(neznámý klub)',
        clenove: (clenove ?? [])
          .filter((c) => c.subject_id === sid)
          .map((c) => ({
            user_id: c.user_id as string,
            jmeno: jmena[c.user_id as string] ?? '(neznámý uživatel)',
            level: c.level as RepLevel,
            muze_potvrzovat: !!c.muze_potvrzovat,
          }))
          // Zástupci nahoře, pak podle jména — ať je seznam pokaždé stejný.
          .sort((a, b) =>
            a.level === b.level
              ? a.jmeno.localeCompare(b.jmeno, 'cs')
              : a.level === 'rep' ? -1 : 1),
      }));
    },
    enabled: !!user && (isRep || isAdmin),
  });

  /**
   * „Právo navíc" — člen si smí sám potvrdit SVOJI rezervaci před akcí (R11).
   *
   * Netýká se potvrzení PO akci, které spouští fakturaci a výplaty; to zůstává
   * adminovi a zástupci (R10). Kontrolu oprávnění dělá RPC, ne tenhle kód.
   */
  const nastavPravoNavic = useMutation({
    mutationFn: async (p: { subject_id: string; user_id: string; hodnota: boolean }) => {
      const { error: e } = await supabase.rpc('nastav_pravo_navic', {
        _subject: p.subject_id,
        _user: p.user_id,
        _hodnota: p.hodnota,
      });
      // Hláška z databáze je česká a konkrétní, tak ji nepřebalujeme.
      if (e) throw new Error(e.message?.trim() || 'Právo se nepodařilo nastavit.');
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['muj-klub'] });
    },
  });

  return {
    kluby,
    isLoading,
    error,
    nastavPravoNavic: nastavPravoNavic.mutateAsync,
    isBusy: nastavPravoNavic.isPending,
  };
};
