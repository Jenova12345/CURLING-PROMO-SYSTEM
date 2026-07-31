import { useMemo } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database, Json } from '@/integrations/supabase/types';

type SubjectType = Database['public']['Enums']['subject_type'];
export type EventType = Database['public']['Enums']['event_type'];

export type Sheet = Database['public']['Tables']['sheets']['Row'];
export type Subject = Database['public']['Tables']['subjects']['Row'];
export type Settings = Database['public']['Tables']['settings']['Row'];

// Jediný zdroj pravdy pro kalendář: maskované view.
// Obsazenost a název klubu/akce vidí každý přihlášený, částku jen admin a autor
// rezervace (maskování je v DB, ne v UI — přes API to nejde obejít).
export type CalendarReservation = Database['public']['Views']['reservations_calendar']['Row'];

export type BookingKind = 'training' | 'tournament' | 'commercial' | 'maintenance';

// Obsazenost štábu u komerční akce (jen admin/staff přes RLS na shifts).
export type ShiftFill = { filled: number; total: number };

export type SubjectRepLevel = Database['public']['Enums']['subject_rep_level'];
export type Membership = { subject_id: string; level: SubjectRepLevel };

export interface BookingInput {
  sheet_ids: string[];
  kind: BookingKind;
  title: string;
  start_at: string;
  end_at: string;
  subject_id?: string | null;
  note?: string;
  role_reqs?: Record<string, number>;
  rate_per_hour?: number | null;
  /** vědomé přebití kolidující akce nižší priority (jen admin) */
  override?: boolean;
}

export interface SeriesInput extends BookingInput {
  /** 1 = pondělí … 7 = neděle */
  weekdays: number[];
  /** poslední den opakování (včetně), formát yyyy-MM-dd */
  until: string;
}

export type Conflict = {
  reservation_id: string;
  sheet_id: string;
  sheet_name: string;
  subject_name: string | null;
  event_title: string | null;
  event_type: EventType;
  start_at: string;
  end_at: string;
  can_override: boolean;
};

interface DateRange {
  from: string;
  to: string;
}

// Serverové funkce hlásí chyby už česky a srozumitelně („Dráha 1 je v tomto čase
// obsazená…"), takže je nepřepisujeme — jen podchytíme technické případy.
function rpcError(error: { code?: string; message?: string } | null, fallback: string): Error {
  const msg = (error?.message ?? '').trim();
  if (!msg) return new Error(fallback);
  if (error?.code === '42501' || msg.toLowerCase().includes('row-level security')) {
    return new Error('K této operaci nemáte oprávnění.');
  }
  if (msg.toLowerCase().includes('permission denied')) {
    return new Error('K této operaci nemáte oprávnění.');
  }
  if (msg.includes('exclusion') || msg.includes('reservations_no_overlap')) {
    return new Error('Termín je už obsazený — někdo byl rychlejší. Zvolte jiný čas nebo dráhu.');
  }
  return new Error(msg);
}

export const useReservations = (range: DateRange | null) => {
  const { user, isAdmin, isStaff } = useAuth();
  const queryClient = useQueryClient();

  // Rezervace v období — vč. stornovaných (kvůli auditu); kalendář si filtruje sám.
  const { data: calendar = [], isLoading } = useQuery({
    queryKey: ['reservations-calendar', range?.from, range?.to],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('reservations_calendar')
        .select('*')
        .gte('start_at', range!.from)
        .lt('start_at', range!.to)
        .order('start_at', { ascending: true });
      if (error) throw error;
      return (data ?? []) as CalendarReservation[];
    },
    enabled: !!user && !!range,
  });

  const reservations = useMemo(
    () => calendar.filter((r) => r.status === 'confirmed'),
    [calendar],
  );

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

  // Subjekty, za které smím rezervovat (RLS: admin vše, ostatní jen své kluby).
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

  // Obsazenost štábu u navázaných akcí (jen admin/staff — RLS na shifts).
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
    queryClient.invalidateQueries({ queryKey: ['reservations-calendar'] });
    queryClient.invalidateQueries({ queryKey: ['calendar-shift-fill'] });
    queryClient.invalidateQueries({ queryKey: ['shifts'] });
    queryClient.invalidateQueries({ queryKey: ['notifications'] });
    queryClient.invalidateQueries({ queryKey: ['dues'] });
  };

  const rpcArgs = (input: BookingInput) => ({
    p_sheet_ids: input.sheet_ids,
    p_kind: input.kind,
    p_title: input.title,
    p_start: input.start_at,
    p_end: input.end_at,
    p_subject_id: input.subject_id ?? undefined,
    p_note: input.note ?? undefined,
    p_role_reqs: (input.role_reqs ?? {}) as Json,
    p_rate: input.rate_per_hour ?? undefined,
  });

  // Založení rezervace — jedna transakce na serveru: akce + rezervace na všech
  // vybraných drahách (+ případné vědomé přebití vč. upozornění dotčenému klubu).
  const createBooking = useMutation({
    mutationFn: async (input: BookingInput) => {
      const { data, error } = await supabase.rpc('create_booking', {
        ...rpcArgs(input),
        p_override: input.override ?? false,
      });
      if (error) throw rpcError(error, 'Rezervaci se nepodařilo založit.');
      return data as { event_id: string; reservation_ids: string[]; approved: boolean; cancelled: unknown[] };
    },
    onSuccess: invalidate,
  });

  // Pravidelný trénink — série termínů; kolizní termíny se přeskočí a vrátí se seznam.
  const createSeries = useMutation({
    mutationFn: async (input: SeriesInput) => {
      const { data, error } = await supabase.rpc('create_booking_series', {
        ...rpcArgs(input),
        p_weekdays: input.weekdays,
        p_until: input.until,
      });
      if (error) throw rpcError(error, 'Sérii se nepodařilo založit.');
      return data as { series_id: string; created: number; skipped: { date: string; reason: string }[] };
    },
    onSuccess: invalidate,
  });

  const updateBooking = useMutation({
    mutationFn: async (args: { id: string; title?: string; note?: string | null; rate_per_hour?: number | null }) => {
      const { error } = await supabase.rpc('update_booking', {
        p_reservation_id: args.id,
        p_title: args.title ?? undefined,
        p_note: args.note ?? undefined,
        p_rate: args.rate_per_hour ?? undefined,
      });
      if (error) throw rpcError(error, 'Úpravu se nepodařilo uložit.');
    },
    onSuccess: invalidate,
  });

  // Přesun v kalendáři (drag & drop). Akce na obou drahách se posune celá.
  const moveBooking = useMutation({
    mutationFn: async (args: { id: string; start_at: string; end_at: string; sheet_id?: string }) => {
      const { error } = await supabase.rpc('move_booking', {
        p_reservation_id: args.id,
        p_start: args.start_at,
        p_end: args.end_at,
        p_sheet_id: args.sheet_id ?? undefined,
      });
      if (error) throw rpcError(error, 'Rezervaci se nepodařilo přesunout.');
    },
    onSuccess: invalidate,
  });

  const cancelBooking = useMutation({
    mutationFn: async (args: { id: string; scope?: 'single' | 'event' | 'series'; reason?: string }) => {
      const { error } = await supabase.rpc('cancel_booking', {
        p_reservation_id: args.id,
        p_scope: args.scope ?? 'single',
        p_reason: args.reason ?? undefined,
      });
      if (error) throw rpcError(error, 'Rezervaci se nepodařilo stornovat.');
    },
    onSuccess: invalidate,
  });

  const approveReservation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('approve_reservation', { p_reservation_id: id });
      if (error) throw rpcError(error, 'Rezervaci se nepodařilo potvrdit.');
    },
    onSuccess: invalidate,
  });

  // Co by nová rezervace přebila (pro potvrzovací dialog před založením).
  const checkConflicts = async (args: {
    sheet_ids: string[]; start_at: string; end_at: string; kind: BookingKind; ignore_event?: string;
  }): Promise<Conflict[]> => {
    const { data, error } = await supabase.rpc('check_booking_conflicts', {
      p_sheet_ids: args.sheet_ids,
      p_start: args.start_at,
      p_end: args.end_at,
      p_kind: args.kind,
      p_ignore_event: args.ignore_event ?? undefined,
    });
    if (error) throw rpcError(error, 'Kontrolu kolizí se nepodařilo provést.');
    return (data ?? []) as Conflict[];
  };

  // ARES: serverová edge funkce načte firmu podle IČO (obchodniJmeno/adresa/dic).
  const aresLookup = async (ico: string): Promise<{ name: string; address: string; dic: string }> => {
    const { data, error } = await supabase.functions.invoke('ares-lookup', { body: { ico } });
    if (error) throw new Error('Nepodařilo se spojit s ARESem.');
    if (data?.error) throw new Error(data.error);
    return data as { name: string; address: string; dic: string };
  };

  // Existuje už subjekt s tímhle IČO? (server — cizí subjekty uživatel přes RLS nevidí)
  const findSubjectByIco = async (ico: string): Promise<Subject | null> => {
    const { data, error } = await supabase.rpc('find_subject_by_ico', { p_ico: ico });
    if (error) throw rpcError(error, 'Ověření IČO selhalo.');
    const rows = (data ?? []) as Subject[];
    return rows[0] ?? null;
  };

  // Založení komerčního subjektu (firmy) — jen admin (subjects RLS).
  const createSubject = useMutation({
    mutationFn: async (s: { name: string; ico?: string; dic?: string; address?: string }) => {
      const { data, error } = await supabase
        .from('subjects')
        .insert({ type: 'commercial', name: s.name, ico: s.ico || null, dic: s.dic || null, address: s.address || null })
        .select().single();
      if (error) {
        if (error.code === '23505') throw new Error('Firma s tímto IČO už v systému je.');
        throw new Error('Nepodařilo se založit firmu.');
      }
      return data as Subject;
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['my-subjects'] }),
  });

  return {
    /** potvrzené rezervace (obsazenost kalendáře) */
    reservations,
    /** vč. stornovaných — pro audit a přehled zrušených akcí */
    calendar,
    sheets,
    mySubjects,
    myMemberships,
    settings,
    shiftFill,
    isLoading,
    createBooking: createBooking.mutateAsync,
    createSeries: createSeries.mutateAsync,
    updateBooking: updateBooking.mutateAsync,
    moveBooking: moveBooking.mutateAsync,
    cancelBooking: cancelBooking.mutateAsync,
    approveReservation: approveReservation.mutateAsync,
    checkConflicts,
    aresLookup,
    findSubjectByIco,
    createSubject: createSubject.mutateAsync,
    isCreating: createBooking.isPending || createSeries.isPending,
    isUpdating: updateBooking.isPending || moveBooking.isPending,
    isCancelling: cancelBooking.isPending,
    isApproving: approveReservation.isPending,
  };
};
