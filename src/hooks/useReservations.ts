import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

type SubjectType = Database['public']['Enums']['subject_type'];
type ReservationStatus = Database['public']['Enums']['reservation_status'];

export type Sheet = Database['public']['Tables']['sheets']['Row'];
export type Subject = Database['public']['Tables']['subjects']['Row'];
export type Settings = Database['public']['Tables']['settings']['Row'];

// Plná rezervace (viditelná adminovi za vše, zástupci jen za jeho klub) + název subjektu.
export type ReservationRow = Database['public']['Tables']['reservations']['Row'] & {
  subjects?: { name: string; type: SubjectType } | null;
};

// Maskovaná obsazenost z view (bez identity/částek) — vidí každý přihlášený.
export type CalendarSlot = {
  sheet_id: string;
  start_at: string;
  end_at: string;
  status: ReservationStatus;
};

export interface CreateReservationData {
  sheet_id: string;
  subject_id: string;
  start_at: string;
  end_at: string;
  note?: string;
}

interface DateRange {
  from: string; // ISO začátek zobrazeného období
  to: string;   // ISO konec zobrazeného období
}

/**
 * Data vrstva rezervačního kalendáře. `range` = zobrazené období (den/týden).
 * RLS na serveru vynucuje, kdo co vidí a smí — UI to jen zrcadlí.
 */
export const useReservations = (range: DateRange | null) => {
  const { user } = useAuth();
  const queryClient = useQueryClient();

  // Plné rezervace v období (RLS: admin vše, zástupce jen svůj klub).
  const { data: reservations = [], isLoading: reservationsLoading } = useQuery({
    queryKey: ['reservations', range?.from, range?.to],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('reservations')
        .select('*, subjects(name, type)')
        .eq('status', 'confirmed')
        .is('deleted_at', null)
        .gte('start_at', range!.from)
        .lt('start_at', range!.to)
        .order('start_at', { ascending: true });
      if (error) throw error;
      return (data ?? []) as ReservationRow[];
    },
    enabled: !!user && !!range,
  });

  // Obsazenost VŠECH pláten (maskovaná) — kvůli tomu, aby zástupce nedvojrezervoval.
  const { data: calendar = [], isLoading: calendarLoading } = useQuery({
    queryKey: ['reservations-calendar', range?.from, range?.to],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('reservations_calendar')
        .select('sheet_id, start_at, end_at, status')
        .gte('start_at', range!.from)
        .lt('start_at', range!.to)
        .order('start_at', { ascending: true });
      if (error) throw error;
      return (data ?? []) as CalendarSlot[];
    },
    enabled: !!user && !!range,
  });

  // Plátna (čte každý přihlášený).
  const { data: sheets = [] } = useQuery({
    queryKey: ['sheets'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('sheets')
        .select('*')
        .eq('active', true)
        .order('name', { ascending: true });
      if (error) throw error;
      return (data ?? []) as Sheet[];
    },
    enabled: !!user,
  });

  // Subjekty, za které smím rezervovat (RLS: admin všechny, zástupce jen svůj klub).
  const { data: mySubjects = [] } = useQuery({
    queryKey: ['my-subjects'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('subjects')
        .select('*')
        .is('deleted_at', null)
        .order('name', { ascending: true });
      if (error) throw error;
      return (data ?? []) as Subject[];
    },
    enabled: !!user,
  });

  // Nastavení (otevírací doba pro rozsah časové osy).
  const { data: settings = null } = useQuery({
    queryKey: ['reservation-settings'],
    queryFn: async () => {
      const { data, error } = await supabase.from('settings').select('*').maybeSingle();
      if (error) throw error;
      return (data ?? null) as Settings | null;
    },
    enabled: !!user,
  });

  const createReservation = useMutation({
    mutationFn: async (input: CreateReservationData) => {
      const { data, error } = await supabase
        .from('reservations')
        .insert({
          sheet_id: input.sheet_id,
          subject_id: input.subject_id,
          start_at: input.start_at,
          end_at: input.end_at,
          note: input.note || null,
          // rate_per_hour záměrně neposíláme — dopočítá server (snapshot z ceníku)
        })
        .select()
        .single();

      if (error) {
        // Kolize na plátně (exclusion constraint)
        if (error.code === '23P01' || error.message.includes('reservations_no_overlap')) {
          throw new Error('Tento slot je na daném plátně už obsazený. Vyber jiný čas nebo plátno.');
        }
        if (error.message.includes('Sazba není nastavena')) {
          throw new Error('Sazba není nastavena — správce musí nejdřív doplnit ceník.');
        }
        // RLS / práva
        if (error.code === '42501' || error.message.toLowerCase().includes('row-level security')) {
          throw new Error('Za tento subjekt nemáte oprávnění rezervovat.');
        }
        throw new Error('Nepodařilo se vytvořit rezervaci.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['reservations'] });
      queryClient.invalidateQueries({ queryKey: ['reservations-calendar'] });
    },
  });

  const cancelReservation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('reservations')
        .update({ status: 'cancelled' })
        .eq('id', id);
      if (error) {
        if (error.code === '42501' || error.message.toLowerCase().includes('row-level security')) {
          throw new Error('Tuto rezervaci nemůžete stornovat.');
        }
        if (error.message.includes('pouze stornovat') || error.message.includes('storno')) {
          throw new Error('Tuto rezervaci nelze stornovat.');
        }
        throw new Error('Nepodařilo se stornovat rezervaci.');
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['reservations'] });
      queryClient.invalidateQueries({ queryKey: ['reservations-calendar'] });
    },
  });

  return {
    reservations,
    calendar,
    sheets,
    mySubjects,
    settings,
    isLoading: reservationsLoading || calendarLoading,
    createReservation: createReservation.mutateAsync,
    cancelReservation: cancelReservation.mutateAsync,
    isCreating: createReservation.isPending,
    isCancelling: cancelReservation.isPending,
  };
};
