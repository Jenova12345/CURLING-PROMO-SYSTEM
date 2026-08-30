import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';
import { fromHal, sumHodin, sumKc, toHal } from '@/lib/money';

type SubjectType = Database['public']['Enums']['subject_type'];

export type DueReservation = {
  id: string;
  start_at: string;
  end_at: string;
  hours: number | null;
  /** Snapshot sazby z doby vzniku rezervace. Na doklad patří tohle, ne dopočet z částky. */
  rate_per_hour: number | null;
  amount: number | null;
  corrected_hours: number | null;
  corrected_amount: number | null;
  /**
   * SKUTEČNÁ dlužná částka — u komerčního subjektu včetně DPH.
   *
   * Dopočítává ji pohled `reservations_billing`, ne frontend: sazbu má
   * databáze (`billing_settings.vat_rate_ice`) a `src/` si `billing/`,
   * kde žije `SAZBA_DPH_LED`, importovat nesmí.
   */
  dluh: number | null;
  /** Týž údaj BEZ daně — to, co jde na řádek dokladu u komerční faktury. */
  dluh_zaklad: number | null;
  subject_id: string;
  subject_name: string | null;
  subject_type: SubjectType | null;
  sheet_name: string | null;
  event_title: string | null;
  created_by_name: string | null;
};

// Fakturační údaje odběratele — na faktuře je potřeba adresa a IČO/DIČ,
// které v podkladech k úhradě nejsou.
export type BillingSubject = {
  id: string;
  name: string;
  address: string | null;
  ico: string | null;
  dic: string | null;
};

export type DueRow = { subjectId: string; name: string; type: SubjectType; hours: number; amount: number; count: number };

// Podklady „kdo kolik dluží" za období. Čte se z view reservations_billing, které
// pouští částky jen adminovi (obyčejný uživatel dostane prázdný výsledek i přes API).
// Interní rezervace (bez subjektu) se nepočítají; jen confirmed.
export const useDues = (range: { from: string; to: string } | null) => {
  const { user, isAdmin } = useAuth();

  const { data: rows = [], isLoading } = useQuery({
    queryKey: ['dues', range?.from, range?.to],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('reservations_billing')
        .select('id, start_at, end_at, hours, rate_per_hour, amount, corrected_hours, corrected_amount, dluh, dluh_zaklad, subject_id, subject_name, subject_type, sheet_name, event_title, created_by_name')
        .gte('start_at', range!.from)
        .lt('start_at', range!.to)
        .order('start_at', { ascending: true });
      if (error) throw error;
      return (data ?? []) as DueReservation[];
    },
    enabled: !!user && isAdmin && !!range,
  });

  // Fakturační údaje subjektů (adresa, IČO, DIČ) — RLS je pouští jen adminovi.
  const { data: subjects = [] } = useQuery({
    queryKey: ['billing-subjects'],
    queryFn: async () => {
      // Bez filtru na deleted_at schválně: faktura za starší období musí mít
      // adresu a IČO i pro subjekt, který byl mezitím skryt.
      const { data, error } = await supabase
        .from('subjects')
        .select('id, name, address, ico, dic');
      if (error) throw error;
      return (data ?? []) as BillingSubject[];
    },
    enabled: !!user && isAdmin,
  });

  // Sčítá se v haléřích (resp. setinách hodiny) a NIC se průběžně nezaokrouhluje —
  // zaokrouhlení patří až na doklad, k částce k úhradě. Viz src/lib/money.ts.
  const bySubject = new Map<string, { subjectId: string; name: string; type: SubjectType; hal: number; hodinySetiny: number; count: number }>();
  for (const r of rows) {
    const hours = Number(r.corrected_hours ?? r.hours ?? 0);
    // `dluh` je SKUTEČNÁ dlužná částka, ne `amount`.
    //
    // `amount` je snapshot `hodiny × sazba` a pod DPH znamená u klubu částku
    // S DANÍ, u komerce ZÁKLAD — sečíst ho napříč typy tedy míchá jablka
    // s hruškami a u komerčních zákazníků podhodnotí dluh o celou sazbu daně.
    // Dopočet dělá pohled `reservations_billing`, protože sazbu má databáze;
    // `src/` si `billing/` (kde je `SAZBA_DPH_LED`) importovat nesmí.
    //
    // Fallback na `amount` je pro jistotu, ne pro provoz: `dluh` pohled vrací
    // vždycky. Kdyby chyběl, je lepší ukázat základ než nulu.
    const amount = Number(r.dluh ?? r.corrected_amount ?? r.amount ?? 0);
    const key = r.subject_id;
    const cur = bySubject.get(key) ?? {
      subjectId: key,
      name: r.subject_name ?? 'Neznámý',
      type: r.subject_type ?? 'club',
      hal: 0, hodinySetiny: 0, count: 0,
    };
    cur.hal += toHal(amount);
    cur.hodinySetiny += toHal(hours);
    cur.count += 1;
    bySubject.set(key, cur);
  }

  const summary: DueRow[] = Array.from(bySubject.values())
    .map((s) => ({
      subjectId: s.subjectId, name: s.name, type: s.type, count: s.count,
      hours: fromHal(s.hodinySetiny),
      amount: fromHal(s.hal),
    }))
    .sort((a, b) => b.amount - a.amount);

  const totalAmount = sumKc(summary.map((r) => r.amount));
  const totalHours = sumHodin(summary.map((r) => r.hours));

  return { reservations: rows, summary, subjects, totalAmount, totalHours, isLoading };
};
