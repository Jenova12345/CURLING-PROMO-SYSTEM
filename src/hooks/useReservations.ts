import { useMemo } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

type SubjectType = Database['public']['Enums']['subject_type'];
type ReservationStatus = Database['public']['Enums']['reservation_status'];
type EventType = Database['public']['Enums']['event_type'];

export type Sheet = Database['public']['Tables']['sheets']['Row'];
export type Subject = Database['public']['Tables']['subjects']['Row'];
export type Settings = Database['public']['Tables']['settings']['Row'];

// Plná rezervace (viditelná adminovi za vše, zástupci jen za jeho klub) + název subjektu + akce.
export type ReservationRow = Database['public']['Tables']['reservations']['Row'] & {
  subjects?: { name: string; type: SubjectType } | null;
  events?: { title: string; event_type: EventType } | null;
};

// Maskovaná obsazenost z view (bez identity/částek) — vidí každý přihlášený.
export type CalendarSlot = {
  sheet_id: string;
  start_at: string;
  end_at: string;
  status: ReservationStatus;
};

// Obsazenost štábu u komerční akce (jen admin/staff přes RLS na shifts).
export type ShiftFill = { filled: number; total: number };

export interface CreateClubReservation {
  sheet_id: string;
  subject_id: string;
  start_at: string;
  end_at: string;
  note?: string;
  rate_per_hour?: number; // jen admin (guard u ne-admina stejně vynuluje)
}

export interface CreateCommercialBooking {
  sheet_id: string;
  subject_id: string;
  start_at: string;
  end_at: string;
  note?: string;
  title: string;
  role_reqs: Record<string, number>; // {instructor, bar_staff, manager} > 0
  rate_per_hour?: number; // jen admin
}

export type SubjectRepLevel = Database['public']['Enums']['subject_rep_level'];
export type Membership = { subject_id: string; level: SubjectRepLevel };

// Pole rezervace, která smí upravit i ne-admin (guard pouští sheet/time/note; rate jen admin).
export interface UpdateReservationFields {
  sheet_id?: string;
  start_at?: string;
  end_at?: string;
  note?: string | null;
  rate_per_hour?: number; // jen admin
}

export interface CreateInternalBooking {
  sheet_id: string;
  start_at: string;
  end_at: string;
  note?: string;
  title: string;
  event_type: 'training' | 'maintenance';
}

interface DateRange {
  from: string;
  to: string;
}

function mapReservationError(error: { code?: string; message: string }): Error {
  if (error.code === '23P01' || error.message.includes('reservations_no_overlap')) {
    return new Error('Tento slot je na daném plátně už obsazený. Vyber jiný čas nebo plátno.');
  }
  if (error.message.includes('Sazba není nastavena')) {
    return new Error('Sazba není nastavena — správce musí nejdřív doplnit ceník.');
  }
  if (error.code === '42501' || error.message.toLowerCase().includes('row-level security')) {
    return new Error('Za tento subjekt nemáte oprávnění rezervovat.');
  }
  return new Error('Nepodařilo se vytvořit rezervaci.');
}

export const useReservations = (range: DateRange | null) => {
  const { user, isAdmin, isStaff } = useAuth();
  const queryClient = useQueryClient();

  // Plné rezervace v období (RLS: admin vše, zástupce jen svůj klub) + název subjektu/akce.
  const { data: reservations = [], isLoading: reservationsLoading } = useQuery({
    queryKey: ['reservations', range?.from, range?.to],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('reservations')
        .select('*, subjects(name, type), events(title, event_type)')
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

  // Obsazenost VŠECH pláten (maskovaná).
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

  const { data: sheets = [] } = useQuery({
    queryKey: ['sheets'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('sheets').select('*').eq('active', true).order('name', { ascending: true });
      if (error) throw error;
      return (data ?? []) as Sheet[];
    },
    enabled: !!user,
  });

  const { data: mySubjects = [] } = useQuery({
    queryKey: ['my-subjects'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('subjects').select('*').is('deleted_at', null).order('name', { ascending: true });
      if (error) throw error;
      return (data ?? []) as Subject[];
    },
    enabled: !!user,
  });

  // Moje napojení na kluby (úroveň) — pro rozhodnutí, co smím editovat/stornovat.
  const { data: myMemberships = [] } = useQuery({
    queryKey: ['my-memberships'],
    queryFn: async () => {
      const { data, error } = await supabase.from('subject_reps').select('subject_id, level');
      if (error) throw error;
      return (data ?? []) as Membership[];
    },
    enabled: !!user,
  });

  const { data: settings = null } = useQuery({
    queryKey: ['reservation-settings'],
    queryFn: async () => {
      const { data, error } = await supabase.from('settings').select('*').maybeSingle();
      if (error) throw error;
      return (data ?? null) as Settings | null;
    },
    enabled: !!user,
  });

  // Obsazenost štábu u navázaných akcí (jen admin/staff — RLS na shifts). Mapa event_id → {filled,total}.
  const eventIds = useMemo(
    () => Array.from(new Set(reservations.map((r) => r.event_id).filter(Boolean))) as string[],
    [reservations],
  );
  const { data: shiftFill = {} } = useQuery({
    queryKey: ['calendar-shift-fill', eventIds],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('shifts').select('event_id, status').in('event_id', eventIds);
      if (error) throw error;
      const map: Record<string, ShiftFill> = {};
      for (const s of data ?? []) {
        const id = s.event_id as string;
        map[id] = map[id] ?? { filled: 0, total: 0 };
        map[id].total += 1;
        // „obsazeno" = reálně potvrzené (claimed/completed); pending je nepotvrzená žádost
        if (s.status === 'claimed' || s.status === 'completed') map[id].filled += 1;
      }
      return map;
    },
    enabled: !!user && (isAdmin || isStaff) && eventIds.length > 0,
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ['reservations'] });
    queryClient.invalidateQueries({ queryKey: ['reservations-calendar'] });
    queryClient.invalidateQueries({ queryKey: ['calendar-shift-fill'] });
    queryClient.invalidateQueries({ queryKey: ['shifts'] });
  };

  // Klubová rezervace — jen led.
  const createClub = useMutation({
    mutationFn: async (input: CreateClubReservation) => {
      const { data, error } = await supabase
        .from('reservations')
        .insert({ sheet_id: input.sheet_id, subject_id: input.subject_id, start_at: input.start_at, end_at: input.end_at, note: input.note || null, rate_per_hour: input.rate_per_hour ?? null })
        .select().single();
      if (error) throw mapReservationError(error);
      return data;
    },
    onSuccess: invalidate,
  });

  // Komerční rezervace — akce (→ trigger vygeneruje směny) + navázaná rezervace ledu.
  const createCommercial = useMutation({
    mutationFn: async (input: CreateCommercialBooking) => {
      const required = Object.values(input.role_reqs).reduce((a, b) => a + b, 0);
      const { data: ev, error: evErr } = await supabase
        .from('events')
        .insert({
          title: input.title, event_type: 'commercial',
          start_time: input.start_at, end_time: input.end_at,
          required_staff: required, role_reqs: input.role_reqs,
        })
        .select().single();
      if (evErr) throw new Error('Nepodařilo se vytvořit akci (štáb).');

      const { data, error } = await supabase
        .from('reservations')
        .insert({ sheet_id: input.sheet_id, subject_id: input.subject_id, start_at: input.start_at, end_at: input.end_at, note: input.note || null, event_id: ev.id, rate_per_hour: input.rate_per_hour ?? null })
        .select().single();
      if (error) {
        // úklid, ať nezůstane osiřelá akce+směny (CASCADE smaže i směny)
        const { error: delErr } = await supabase.from('events').delete().eq('id', ev.id);
        if (delErr) console.error('Úklid osiřelé akce po selhání rezervace se nezdařil:', delErr);
        throw mapReservationError(error);
      }
      return data;
    },
    onSuccess: invalidate,
  });

  // Interní akce (trénink/údržba) — akce + rezervace ledu bez fakturačního subjektu.
  const createInternal = useMutation({
    mutationFn: async (input: CreateInternalBooking) => {
      const { data: ev, error: evErr } = await supabase
        .from('events')
        .insert({ title: input.title, event_type: input.event_type, start_time: input.start_at, end_time: input.end_at, required_staff: 0 })
        .select().single();
      if (evErr) throw new Error('Nepodařilo se vytvořit akci.');

      const { data, error } = await supabase
        .from('reservations')
        .insert({ sheet_id: input.sheet_id, subject_id: null, start_at: input.start_at, end_at: input.end_at, note: input.note || null, event_id: ev.id })
        .select().single();
      if (error) {
        const { error: delErr } = await supabase.from('events').delete().eq('id', ev.id);
        if (delErr) console.error('Úklid osiřelé akce po selhání rezervace se nezdařil:', delErr);
        throw mapReservationError(error);
      }
      return data;
    },
    onSuccess: invalidate,
  });

  // Editace bezpečných polí rezervace (sheet/time/note; rate jen admin — hlídá guard).
  const updateReservation = useMutation({
    mutationFn: async ({ id, fields }: { id: string; fields: UpdateReservationFields }) => {
      const { error } = await supabase.from('reservations').update(fields).eq('id', id);
      if (error) throw mapReservationError(error);
    },
    onSuccess: invalidate,
  });

  // Editace navázané akce (název / časy) — jen admin (events RLS admin).
  const updateEvent = useMutation({
    mutationFn: async ({ id, fields }: { id: string; fields: { title?: string; start_time?: string; end_time?: string } }) => {
      const { error } = await supabase.from('events').update(fields).eq('id', id);
      if (error) throw new Error('Nepodařilo se upravit akci.');
    },
    onSuccess: invalidate,
  });

  // ARES: serverová edge funkce načte firmu podle IČO (obchodniJmeno/adresa/dic).
  const aresLookup = async (ico: string): Promise<{ name: string; address: string; dic: string }> => {
    const { data, error } = await supabase.functions.invoke('ares-lookup', { body: { ico } });
    if (error) throw new Error('Nepodařilo se spojit s ARESem.');
    if (data?.error) throw new Error(data.error);
    return data as { name: string; address: string; dic: string };
  };

  // Založení komerčního subjektu (firmy) — jen admin (subjects RLS).
  const createSubject = useMutation({
    mutationFn: async (s: { name: string; ico?: string; dic?: string; address?: string }) => {
      const { data, error } = await supabase
        .from('subjects')
        .insert({ type: 'commercial', name: s.name, ico: s.ico || null, dic: s.dic || null, address: s.address || null })
        .select().single();
      if (error) throw new Error('Nepodařilo se založit firmu.');
      return data as Subject;
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['my-subjects'] }),
  });

  // Storno (DB trigger navíc zruší volné směny navázané akce).
  const cancelReservation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('reservations').update({ status: 'cancelled' }).eq('id', id);
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
    onSuccess: invalidate,
  });

  return {
    reservations,
    calendar,
    sheets,
    mySubjects,
    myMemberships,
    settings,
    shiftFill,
    isLoading: reservationsLoading || calendarLoading,
    createClub: createClub.mutateAsync,
    createCommercial: createCommercial.mutateAsync,
    createInternal: createInternal.mutateAsync,
    updateReservation: updateReservation.mutateAsync,
    updateEvent: updateEvent.mutateAsync,
    aresLookup,
    createSubject: createSubject.mutateAsync,
    cancelReservation: cancelReservation.mutateAsync,
    isCreating: createClub.isPending || createCommercial.isPending || createInternal.isPending,
    isUpdating: updateReservation.isPending || updateEvent.isPending,
    isCancelling: cancelReservation.isPending,
  };
};
