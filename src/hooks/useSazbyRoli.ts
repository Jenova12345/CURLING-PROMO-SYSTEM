import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

export type SazbaRole = Database['public']['Tables']['sazby_roli']['Row'];
export type AppRole = Database['public']['Enums']['app_role'];

/**
 * Ceník hodinových sazeb podle role (rozhodnutí PM R9, 27. 8. 2026).
 *
 * Celá tabulka je admin-only (RLS + granty), takže ne-admin dostane prázdno —
 * dotaz se proto pouští jen jemu a `enabled` to hlídá. Brigádník sazbu, která
 * se ho týká, vidí na SVÉ směně (`shifts.hourly_rate`, snapshot), ceník jako
 * celek je mzdový přehled celé haly.
 *
 * Ceník je UZAVŘENÝ SEZNAM: řádky se nepřidávají ani nemažou (nová placená
 * role je migrace, ne klik v nastavení). Proto tu není `insert` ani `delete` —
 * databáze by je stejně odmítla.
 *
 * Z měnitelných polí umí tenhle hook JEN `sazba`. Databáze pouští i `popis`,
 * `poradi` a `poznamka`, ale ty dnes nemá kde zadat — a dokud pro ně není
 * formulář, je užší mutace lepší než široká, kterou nikdo nevolá.
 */
export const useSazbyRoli = () => {
  const { user, isAdmin } = useAuth();
  const qc = useQueryClient();

  const { data: sazby = [], isLoading, error } = useQuery({
    // Uživatel je součástí klíče schválně — brání to znovupoužití cizího
    // záznamu po přepnutí účtu ve stejné záložce (týž důvod jako
    // u `useBillingSettings`).
    queryKey: ['sazby-roli', user?.id],
    queryFn: async () => {
      const { data, error: chyba } = await supabase
        .from('sazby_roli').select('*').order('poradi');
      if (chyba) throw chyba;
      return (data ?? []) as SazbaRole[];
    },
    enabled: !!user && isAdmin,
  });

  const update = useMutation({
    mutationFn: async ({ role, sazba }: { role: AppRole; sazba: number }) => {
      // `count: 'exact'` je NUTNÝ, ne kosmetika: UPDATE zablokovaný RLS není
      // chyba — PostgREST vrátí 204, `chyba` je null a mutace by se vyřešila
      // jako úspěch. Admin by dostal zelené „uloženo" a sazba by zůstala stará;
      // rozdíl by se projevil až ve výplatě, tedy pozdě a na cizí účet.
      //
      // `.select()` se schválně nepoužívá: vynutilo by `return=representation`,
      // které potřebuje SELECT na měněné sloupce — u sloupcových grantů je to
      // zbytečná další podmínka.
      const { error: chyba, count } = await supabase
        .from('sazby_roli')
        .update({ sazba }, { count: 'exact' })
        .eq('role', role);

      if (chyba) throw new Error('Sazbu se nepodařilo uložit: ' + chyba.message);
      if (count !== 1) {
        throw new Error(
          'Sazba se neuložila — databáze změnu odmítla. '
          + 'Nejspíš na to nemáš práva; zkus se odhlásit a přihlásit znovu.',
        );
      }
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['sazby-roli'] }); },
  });

  return {
    sazby,
    isLoading,
    error,
    updateSazba: update.mutateAsync,
    isSaving: update.isPending,
  };
};
