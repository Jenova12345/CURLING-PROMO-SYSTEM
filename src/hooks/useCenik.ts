import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

/** Jedno pásmo standardního ceníku ledu, jak ho vydává `cenik_pasma_public`. */
export type CenikPasmo = {
  id: string;
  den_typ: 'vsedni' | 'vikend';
  od_hodina: number;
  do_hodina: number;
  sazba: number;
  popis: string | null;
};

/**
 * Standardní pásmový ceník ledu — ke ČTENÍ, pro každého přihlášeného.
 *
 * Čte se z pohledu `cenik_pasma_public`, ne z tabulky: `cenik_pasma` má RLS
 * `has_role(admin)`, takže běžný účet z ní dostane nula řádků. Pohled vydává
 * jen platná pásma (bez `deleted_at`) a bez auditních sloupců.
 *
 * CO TU SCHVÁLNĚ NENÍ: komerční sazba, klubové výchozí sazby ani individuální
 * sazby klubů (`subjects.default_rate`). Ty zůstávají adminovi — rozhodnutí
 * A2b z 31. 7. 2026, které migrace 20260914140000 vědomě NERUŠÍ, jen z něj
 * vyjímá vyvěšený ceník. Kdo sem bude přidávat další číslo, ať si to přečte.
 *
 * `as any` u `.from()` je kvůli tomu, že vygenerované `types.ts` nový pohled
 * ještě neznají — týž postup, jaký repo používá u čerstvých RPC.
 */
export const useCenik = () => {
  const { user } = useAuth();

  const { data: pasma = [], isLoading, error } = useQuery({
    queryKey: ['cenik-pasma'],
    queryFn: async () => {
      const { data, error } = await (supabase as any)
        .from('cenik_pasma_public')
        .select('id, den_typ, od_hodina, do_hodina, sazba, popis')
        // Víkend až za všedním dnem, uvnitř po hodinách — stejné pořadí, v jakém
        // to má člověk před očima na vyvěšeném ceníku.
        .order('den_typ', { ascending: true })
        .order('od_hodina', { ascending: true });
      if (error) throw error;
      return ((data ?? []) as CenikPasmo[]).map((p) => ({ ...p, sazba: Number(p.sazba) }));
    },
    enabled: !!user,
  });

  return { pasma, isLoading, error };
};
