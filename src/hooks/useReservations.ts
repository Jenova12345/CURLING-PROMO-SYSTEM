import { useMemo } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database, Json } from '@/integrations/supabase/types';

type SubjectType = Database['public']['Enums']['subject_type'];
export type EventType = Database['public']['Enums']['event_type'];

export type Sheet = Database['public']['Tables']['sheets']['Row'];
export type Subject = Database['public']['Tables']['subjects']['Row'];
/**
 * Nově založená firma tak, jak ji smí přečíst `authenticated`.
 *
 * Schválně NENÍ `Subject`: ten obsahuje `default_rate`, na který `authenticated`
 * nemá SELECT grant, takže by se do návratové hodnoty nikdy nedostal. Typ, který
 * slibuje pole, jež nemůžou dorazit, je jen tiše připravená chyba.
 */
export type NovaFirma = Pick<Subject, 'id' | 'name' | 'type' | 'ico' | 'dic' | 'address'>;
// Nastavení tak, jak ho vidí frontend: čte se z pohledu `settings_public`,
// protože sazby jsou v tabulce po A2b nedostupné a pohled je vydá jen adminovi.
// Pro ostatní role přijdou sazby jako null — `can_see_rates` říká, jestli je to
// „nemáš na to právo" nebo „ceník není vyplněný".
export type Settings = Database['public']['Views']['settings_public']['Row'];

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

/** Co série vrátí. `celkem` je potřeba na větu „Vytvořeno 18 z 20". */
export type SeriesResult = {
  series_id: string;
  celkem: number;
  created: number;
  skipped: {
    iso: string;                                  // YYYY-MM-DD, na formátování v UI
    date: string;                                 // DD.MM.RRRR, pro člověka
    duvod: 'kolize' | 'mimo_otviraci_dobu' | 'neexistujici_cas';
    reason: string;                               // původní hláška ze serveru
  }[];
};

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
      // `select('*')` tu být nesmí: `default_rate` je po A2b pro `authenticated`
      // nečitelný a hvězdička by skončila na 42501. Sazby se dotahují zvlášť
      // z `subjects_rates`, který je vydá jen adminovi.
      const { data, error } = await supabase
        .from('subjects').select('id, type, name, ico, dic, address, created_by, created_at, updated_by, updated_at, deleted_at')
        .is('deleted_at', null).order('name', { ascending: true });
      if (error) throw error;

      // Ne-admin dostane z pohledu prázdno, takže mu sazby zůstanou null —
      // a to je správně: pole se sazbou má jen pro čtení a nacení ho trigger.
      const { data: sazby, error: chybaSazeb } = await supabase
        .from('subjects_rates').select('id, default_rate');
      if (chybaSazeb) throw chybaSazeb;
      const podleId = new Map((sazby ?? []).map((s) => [s.id, s.default_rate]));

      return (data ?? []).map((s) => ({ ...s, default_rate: podleId.get(s.id) ?? null })) as Subject[];
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
      // Pohled místo tabulky: sazby v `settings` jsou po A2b čitelné jen
      // adminovi. Kalendář z toho potřebuje jen otevírací dobu, ta zůstává
      // dostupná všem; dialog rezervace sazbu předvyplní jen adminovi.
      const { data, error } = await supabase.from('settings_public').select('*').maybeSingle();
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

  /**
   * Pravidelný trénink — série termínů.
   *
   * Server přeskočí termíny, které nejdou založit z důvodu vázaného NA TERMÍN
   * (obsazená dráha, mimo otevírací dobu), a zbytek série dojede. Chyba, která
   * platí pro celé zadání (chybí oprávnění, sazba nad stropem), sérii naopak
   * zastaví a probublá sem jako výjimka — proto se tady nic nefiltruje.
   */
  const createSeries = useMutation({
    mutationFn: async (input: SeriesInput) => {
      const { data, error } = await supabase.rpc('create_booking_series', {
        ...rpcArgs(input),
        p_weekdays: input.weekdays,
        p_until: input.until,
      });
      if (error) throw rpcError(error, 'Sérii se nepodařilo založit.');
      return data as SeriesResult;
    },
    onSuccess: invalidate,
  });

  const updateBooking = useMutation({
    // note: '' smaže poznámku, undefined/null ji nechá být (kontrakt serverové funkce)
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

  // Vrací počet potvrzených rezervací — u akce na obou drahách jsou to dvě.
  const approveReservation = useMutation({
    mutationFn: async (id: string) => {
      const { data, error } = await supabase.rpc('approve_reservation', { p_reservation_id: id });
      if (error) throw rpcError(error, 'Rezervaci se nepodařilo potvrdit.');
      return (data ?? { approved: 0 }) as { approved: number };
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

  // ---- TRENÉR K TRÉNINKU (blok C) -----------------------------------------

  /** Lidé s rolí `trainer` — koho lze přiřadit a koho si lze přát. */
  const { data: treneri = [] } = useQuery({
    queryKey: ['treneri'],
    queryFn: async (): Promise<Array<{ user_id: string; jmeno: string }>> => {
      const { data: role, error } = await supabase
        .from('user_roles').select('user_id').eq('role', 'trainer');
      if (error) throw error;
      const ids = [...new Set((role ?? []).map((r) => r.user_id as string))];
      if (ids.length === 0) return [];
      const { data: prof } = await supabase
        .from('profiles_public').select('user_id, full_name').in('user_id', ids);
      return (prof ?? []).map((p) => ({
        user_id: p.user_id as string,
        jmeno: (p.full_name as string) ?? '(bez jména)',
      })).sort((a, b) => a.jmeno.localeCompare(b.jmeno, 'cs'));
    },
    enabled: !!user,
  });

  /** Kdo je k akci PŘIŘAZENÝ (živá trenérská směna). */
  const trenerAkce = async (eventId: string) => {
    const { data } = await supabase
      .from('shifts')
      .select('claimed_by, status, hourly_rate')
      .eq('event_id', eventId).eq('required_role', 'trainer')
      .neq('status', 'cancelled').maybeSingle();
    return data ?? null;
  };

  // PŘIŘAZENÍM VZNIKÁ PLACENÁ SMĚNA (600 Kč/h). Není to jen údaj u akce —
  // proto to jde přes RPC, které si ověří práva i roli trenéra.
  const priradTrenera = useMutation({
    mutationFn: async (a: { event_id: string; user_id: string }) => {
      const { error } = await supabase.rpc('prirad_trenera', {
        _event_id: a.event_id, _user_id: a.user_id,
      });
      if (error) throw rpcError(error, 'Trenéra se nepodařilo přiřadit.');
    },
    onSuccess: invalidate,
  });

  const odeberTrenera = useMutation({
    mutationFn: async (eventId: string) => {
      const { error } = await supabase.rpc('odeber_trenera', { _event_id: eventId });
      if (error) throw rpcError(error, 'Trenéra se nepodařilo odebrat.');
    },
    onSuccess: invalidate,
  });

  /**
   * PŘÁNÍ trenéra — nezávazné, nic nespouští.
   *
   * Píše se do sloupce napřímo, ne přes RPC: je to obyčejný údaj na rezervaci
   * a kdo na ni smí sáhnout, řeší RLS. Placenou směnu z toho nikdy nevznikne —
   * na to je `prirad_trenera`.
   */
  const nastavPraniTrenera = useMutation({
    mutationFn: async (a: { reservation_ids: string[]; user_id: string | null }) => {
      const { error } = await supabase
        .from('reservations')
        .update({ preferovany_trener: a.user_id })
        .in('id', a.reservation_ids);
      if (error) throw new Error(error.message?.trim() || 'Přání se nepodařilo uložit.');
    },
    onSuccess: invalidate,
  });

  // Přecenění CELÉ komerční akce — všechny dráhy naráz (BUG 1).
  //
  // `update_booking` mění sazbu jen na jedné rezervaci, takže akce na dvou
  // drahách mohla skončit se dvěma různými cenami za touž hodinu ledu. RPC to
  // udělá atomicky nad celým `event_id`; smyčka v UI by při selhání druhého
  // volání nechala akci půl přeceněnou.
  const upravSazbuAkce = useMutation({
    mutationFn: async (args: { event_id: string; sazba: number }) => {
      const { error } = await supabase.rpc('uprav_sazbu_akce', {
        _event_id: args.event_id, _sazba: args.sazba,
      });
      if (error) throw rpcError(error, 'Cenu akce se nepodařilo uložit.');
    },
    onSuccess: invalidate,
  });

  // Založení komerčního subjektu (firmy) — jen admin (subjects RLS).
  //
  // ⚠️ `.select()` MUSÍ VYJMENOVAT SLOUPCE, holé `.select()` tady NEFUNGUJE.
  //
  // `subjects` má SLOUPCOVÉ granty: `authenticated` má SELECT na všech
  // sloupcích KROMĚ `default_rate` (migrace „ceník jen adminovi" — sazba je
  // peněžní údaj a nepatří všem). Holé `.select()` přeloží PostgREST na
  // `RETURNING *`, což si vyžádá i `default_rate`, a Postgres celý příkaz
  // odmítne:
  //
  //   ERROR: permission denied for table subjects
  //
  // Insert se přitom neprovede vůbec — práva na sloupce se kontrolují při
  // plánování dotazu. Navenek to vypadalo jako „firmu nejde založit", i když
  // zakládání funguje; rozbité bylo jen to, co se z něj vrací.
  //
  // Cesta přes stránku Subjekty tímhle netrpěla, protože `.select()` vůbec
  // nepoužívá (`useSubjectsAdmin.createSubject`) — a proto tatáž firma přes
  // Subjekty prošla a přes Kalendář ne.
  //
  // `default_rate` tu stejně nepotřebujeme: nová firma ho má NULL a dialog
  // z návratové hodnoty čte jen `id` a `name`.
  const createSubject = useMutation({
    mutationFn: async (s: { name: string; ico?: string; dic?: string; address?: string }) => {
      const { data, error } = await supabase
        .from('subjects')
        .insert({ type: 'commercial', name: s.name, ico: s.ico || null, dic: s.dic || null, address: s.address || null })
        .select('id, name, type, ico, dic, address')
        .single();
      if (error) {
        if (error.code === '23505') throw new Error('Firma s tímto IČO už v systému je.');
        throw new Error('Nepodařilo se založit firmu.');
      }
      return data as NovaFirma;
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
    upravSazbuAkce: upravSazbuAkce.mutateAsync,
    treneri,
    trenerAkce,
    priradTrenera: priradTrenera.mutateAsync,
    odeberTrenera: odeberTrenera.mutateAsync,
    nastavPraniTrenera: nastavPraniTrenera.mutateAsync,
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
