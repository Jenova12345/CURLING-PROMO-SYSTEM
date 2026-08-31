import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';

export interface StabKontrola {
  event_id: string;
  event_type: string;
  drah: number;
  instruktoru_smen: number;
  instruktoru_chybi: number;
  smen_navic: number;
  smen_obsazenych: number;
}

/**
 * Varování o obsazení akce — kolik drah proti kolika instruktorům.
 *
 * Čte pohled `stab_kontrola` z migrace `20260827100000_dorovnani_stabu.sql`.
 * Ten pohled existoval od 27. 8. 2026, ale v `src/` se ho dosud nikdo nezeptal,
 * takže varování nikdo neviděl. Tenhle hook je ta chybějící půlka bodu D.
 *
 * ⚠️ JE TO VAROVÁNÍ, NE ZÁKAZ (rozhodnutí PM R8). Akce se dvěma dráhami
 * a jedním instruktorem je legitimní — jeden instruktor může obsloužit obě.
 * Systém na to jen upozorní; směnu navíc založí ČLOVĚK tím, že zvedne
 * `role_reqs`. Automaticky kvůli dráze nikdy nevznikne ani nezmizí.
 *
 * Pohled sám je admin-only (`WHERE has_role(auth.uid(),'admin')`), takže
 * neadminovi vrátí prázdno — dotaz se pro něj ani nespouští.
 *
 * ⚠️ VAROVÁNÍ PLATÍ JEN PRO KOMERČNÍ AKCE A NÁBOR.
 *
 * Pohled počítá `instruktoru_chybi` jako „dráhy minus instruktorské směny"
 * u VŠECH typů akcí, takže každý trénink v něm vyjde jako podstavený
 * (1 dráha, 0 instruktorů → chybí 1). Trénink ale instruktora mít nemá —
 * pravidlo „1 instruktor na dráhu" je o komerčkách.
 *
 * Dnes to není vidět jen shodou okolností: `ObsazeniDetail` se u akce bez směn
 * vůbec nevykreslí a tréninky směny nemají. Jenže blok C (trenér k tréninku)
 * jim směny dá — a od té chvíle by u každého tréninku svítilo falešné
 * varování. Filtrujeme proto podle typu akce už tady, ne až tehdy.
 */
export const useStabKontrola = (eventId?: string) => {
  const { isAdmin } = useAuth();

  const { data, isLoading } = useQuery({
    queryKey: ['stab-kontrola', eventId],
    queryFn: async (): Promise<StabKontrola | null> => {
      const { data: rows, error } = await supabase
        .from('stab_kontrola')
        .select('event_id, event_type, drah, instruktoru_smen, instruktoru_chybi, smen_navic, smen_obsazenych')
        .eq('event_id', eventId!)
        .maybeSingle();
      // Výpadek tohohle dotazu nesmí shodit detail akce — varování je nadstavba.
      if (error) return null;
      const r = (rows as StabKontrola | null) ?? null;
      if (!r) return null;
      // Viz komentář výš — u tréninků a údržby varování nedává smysl.
      if (r.event_type !== 'commercial' && r.event_type !== 'recruitment') return null;
      return r;
    },
    enabled: !!eventId && isAdmin,
  });

  return { kontrola: data ?? null, isLoading };
};
