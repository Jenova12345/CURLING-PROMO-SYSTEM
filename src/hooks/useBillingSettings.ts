import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

export type BillingSettings = Database['public']['Tables']['billing_settings']['Row'];
export type VatMode = Database['public']['Enums']['vat_mode'];

/** Pole, která smí formulář měnit. Zbytek (id, singleton, razítka) drží databáze. */
export type BillingSettingsUpdate = Partial<
  Pick<
    BillingSettings,
    | 'supplier_name' | 'supplier_legal_form' | 'supplier_address'
    | 'supplier_ico' | 'supplier_dic' | 'supplier_registry'
    | 'bank_account' | 'bank_iban' | 'bank_bic' | 'payment_message'
    | 'vat_mode' | 'due_days' | 'number_format' | 'separate_series' | 'file_prefix'
    | 'automation_enabled' | 'auto_issue'
    | 'monthly_run_day' | 'monthly_run_hour' | 'daily_run_hour'
    | 'invoice_only_approved'
  >
>;

/**
 * Fakturační nastavení haly. Celá tabulka je admin-only (RLS), takže ne-admin
 * dostane prázdno — dotaz se proto pouští jen jemu a `enabled` to hlídá.
 */
export const useBillingSettings = () => {
  const { user, isAdmin } = useAuth();
  const qc = useQueryClient();

  const { data: settings = null, isLoading, error } = useQuery({
    // Uživatel je součástí klíče schválně: brání to ZNOVUPOUŽITÍ cizího záznamu
    // po přepnutí účtu ve stejné záložce. Nebrání to ale DRŽENÍ dat v paměti —
    // to řeší až `queryClient.clear()` v `signOut` (AuthContext). Původní znění
    // tohohle komentáře slibovalo obojí, což uid v klíči neumí.
    queryKey: ['billing-settings', user?.id],
    queryFn: async () => {
      const { data, error: chyba } = await supabase
        .from('billing_settings').select('*').maybeSingle();
      if (chyba) throw chyba;
      return (data ?? null) as BillingSettings | null;
    },
    enabled: !!user && isAdmin,
  });

  const update = useMutation({
    mutationFn: async (fields: BillingSettingsUpdate) => {
      // `count: 'exact'` je tu NUTNÝ, ne kosmetika. UPDATE zablokovaný RLS totiž
      // NENÍ chyba — PostgREST vrátí 204, `chyba` je null a mutace by se vyřešila
      // jako úspěch. Admin by dostal zelené „uloženo", zatímco IBAN by zůstal
      // starý a faktury by dál chodily na původní účet.
      //
      // `.select()` se schválně nepoužívá: vynutilo by `return=representation`,
      // které potřebuje SELECT na měněné sloupce, a u sloupcových grantů z A3
      // to je zbytečná další podmínka. `count` stačí a nic nevrací.
      const { error: chyba, count } = await supabase
        .from('billing_settings')
        .update(fields, { count: 'exact' })
        .eq('singleton', true);

      if (chyba) throw new Error('Nepodařilo se uložit fakturační nastavení: ' + chyba.message);
      if (count !== 1) {
        throw new Error(
          'Nastavení se neuložilo — databáze změnu odmítla. '
          + 'Nejspíš na to nemáš práva; zkus se odhlásit a přihlásit znovu.',
        );
      }
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['billing-settings'] }); },
  });

  return {
    settings,
    isLoading,
    error,
    updateBillingSettings: update.mutateAsync,
    isSaving: update.isPending,
  };
};
