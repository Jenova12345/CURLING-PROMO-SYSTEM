import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

/**
 * Z TOHOHLE SOUBORU ZBYL JEN KONTROLNÍ SOUČET — a je to záměr.
 *
 * Do 16. 9. 2026 tu bydlel celý interní fakturační engine: `useInvoices`
 * (seznam, založení konceptu klubového i komerčního, vystavení, smazání,
 * platby, storno, PDF, měsíční ZIP) a `useInvoiceDetail`. Jediným odběratelem
 * byla stránka Faktury, která toho dne zmizela — ostré doklady vystavuje
 * Fakturoid (varianta S2) a interní engine je od 15. 9. 2026 zamčený
 * (`billing_settings.interni_engine_povolen = false`).
 *
 * MAZAL SE JEN KLIENT, NE MOTOR. RPC, tabulky ani edge funkce
 * (`invoice-zip`, `invoice-pdf-url`) se nerušily — spí zamčené a jdou
 * kdykoli oživit. Kdo je bude chtít zpátky, najde tenhle kód v historii
 * (`git show cab4606^:src/hooks/useInvoices.ts`), ne ať ho píše znovu.
 *
 * `useBillingReconcile` zůstává, protože o Fakturoid se opírá: `billing_reconcile`
 * má sloupce `fakturoid` a `fakturoid_rozdil` a je to jediná obrazovka, která
 * porovná, co si myslíme my, s tím, co je vystavené. S interním enginem nemá
 * společného nic než soubor, ve kterém shodou okolností bydlí.
 */

/**
 * Kontrolní součet za období (B6). Sloupec `rozdil` musí být u všech subjektů
 * nula — cokoli jiného je vada, ne stav, a patří na obrazovku, ne do logu.
 */
export const useBillingReconcile = (range: { from: string; to: string } | null) => {
  const { user, isAdmin } = useAuth();

  return useQuery({
    queryKey: ['billing-reconcile', range?.from, range?.to],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('billing_reconcile', {
        _od: range!.from,
        _do: range!.to,
      });
      if (error) throw error;
      return (data ?? []) as Database['public']['Functions']['billing_reconcile']['Returns'];
    },
    enabled: !!user && isAdmin && !!range,
  });
};
