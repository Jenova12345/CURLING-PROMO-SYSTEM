import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

type SubjectType = Database['public']['Enums']['subject_type'];

export type DueReservation = {
  id: string;
  start_at: string;
  end_at: string;
  hours: number | null;
  amount: number | null;
  corrected_hours: number | null;
  corrected_amount: number | null;
  subject_id: string;
  subject_name: string | null;
  subject_type: SubjectType | null;
  sheet_name: string | null;
  event_title: string | null;
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
        .select('id, start_at, end_at, hours, amount, corrected_hours, corrected_amount, subject_id, subject_name, subject_type, sheet_name, event_title')
        .gte('start_at', range!.from)
        .lt('start_at', range!.to)
        .order('start_at', { ascending: true });
      if (error) throw error;
      return (data ?? []) as DueReservation[];
    },
    enabled: !!user && isAdmin && !!range,
  });

  const bySubject = new Map<string, DueRow>();
  for (const r of rows) {
    const hours = Number(r.corrected_hours ?? r.hours ?? 0);
    const amount = Number(r.corrected_amount ?? r.amount ?? 0);
    const key = r.subject_id;
    const cur = bySubject.get(key) ?? { subjectId: key, name: r.subject_name ?? 'Neznámý', type: r.subject_type ?? 'club', hours: 0, amount: 0, count: 0 };
    cur.hours += hours; cur.amount += amount; cur.count += 1;
    bySubject.set(key, cur);
  }
  const summary = Array.from(bySubject.values()).sort((a, b) => b.amount - a.amount);
  const totalAmount = summary.reduce((s, r) => s + r.amount, 0);
  const totalHours = summary.reduce((s, r) => s + r.hours, 0);

  return { reservations: rows, summary, totalAmount, totalHours, isLoading };
};
