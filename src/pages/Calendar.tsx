import { useMemo, useState } from 'react';
import {
  format, startOfDay, addDays, subDays, startOfWeek, addWeeks, subWeeks,
  startOfMonth, endOfMonth, eachDayOfInterval, isSameDay, addMonths, subMonths,
} from 'date-fns';
import { cs } from 'date-fns/locale';
import { ChevronLeft, ChevronRight, CalendarCheck, Plus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { cn } from '@/lib/utils';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/components/ui/use-toast';
import { useAuth } from '@/contexts/AuthContext';
import { useRateLimit } from '@/hooks/useRateLimit';
import { useReservations, type ReservationRow } from '@/hooks/useReservations';
import { ReservationCalendar } from '@/components/reservations/ReservationCalendar';
import { ReservationDialog } from '@/components/reservations/ReservationDialog';

type View = 'day' | 'week' | 'month';

const DAY_NAMES = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];
const fmtKc = (n: number) => `${n.toLocaleString('cs-CZ')} Kč`;

function parseOpeningHours(openingHours: unknown): { open: number; close: number } {
  const fallback = { open: 8, close: 22 };
  if (!openingHours || typeof openingHours !== 'object') return fallback;
  let open = 24, close = 0, seen = false;
  for (const v of Object.values(openingHours as Record<string, { open?: string; close?: string }>)) {
    if (!v?.open || !v?.close) continue;
    const o = Number(v.open.split(':')[0]);
    const c = Number(v.close.split(':')[0]);
    if (Number.isNaN(o) || Number.isNaN(c)) continue;
    open = Math.min(open, o); close = Math.max(close, c); seen = true;
  }
  if (!seen || open >= close) return fallback;
  return { open, close };
}

// Barva chipu podle typu rezervace/akce.
function chipClass(r: ReservationRow): string {
  const t = r.events?.event_type;
  if (t === 'commercial') return 'bg-green-100 text-green-800';
  if (t === 'training') return 'bg-blue-100 text-blue-800';
  if (t === 'maintenance') return 'bg-orange-100 text-orange-800';
  return 'bg-slate-100 text-slate-800'; // klubová (bez akce)
}
function reservationLabel(r: ReservationRow): string {
  return r.subjects?.name ?? r.events?.title ?? 'Rezervace';
}

const Calendar = () => {
  const { toast } = useToast();
  const { isAdmin } = useAuth();
  const { checkLimit } = useRateLimit('createReservation');

  const [view, setView] = useState<View>('week');
  const [currentDate, setCurrentDate] = useState(() => startOfDay(new Date()));
  const [dialogOpen, setDialogOpen] = useState(false);
  const [defaultSheetId, setDefaultSheetId] = useState<string | undefined>();
  const [defaultStart, setDefaultStart] = useState<Date | undefined>();
  const [detail, setDetail] = useState<ReservationRow | null>(null);

  const range = useMemo(() => {
    if (view === 'day') {
      const from = startOfDay(currentDate);
      return { from: from.toISOString(), to: addDays(from, 1).toISOString() };
    }
    if (view === 'week') {
      const from = startOfWeek(currentDate, { weekStartsOn: 1 });
      return { from: from.toISOString(), to: addDays(from, 7).toISOString() };
    }
    const from = startOfMonth(currentDate);
    return { from: from.toISOString(), to: addDays(endOfMonth(currentDate), 1).toISOString() };
  }, [view, currentDate]);

  const {
    reservations, calendar, sheets, mySubjects, settings, shiftFill, isLoading,
    createClub, createCommercial, createInternal, cancelReservation, isCreating, isCancelling,
  } = useReservations(range);

  const { open: openHour, close: closeHour } = useMemo(() => parseOpeningHours(settings?.opening_hours), [settings]);
  const canBook = isAdmin || mySubjects.length > 0;

  const goPrev = () => setCurrentDate((d) => view === 'day' ? subDays(d, 1) : view === 'week' ? subWeeks(d, 1) : subMonths(d, 1));
  const goNext = () => setCurrentDate((d) => view === 'day' ? addDays(d, 1) : view === 'week' ? addWeeks(d, 1) : addMonths(d, 1));
  const goToday = () => setCurrentDate(startOfDay(new Date()));

  const headerLabel = useMemo(() => {
    if (view === 'day') return format(currentDate, 'EEEE d. MMMM yyyy', { locale: cs });
    if (view === 'month') return format(currentDate, 'LLLL yyyy', { locale: cs });
    const ws = startOfWeek(currentDate, { weekStartsOn: 1 });
    return `${format(ws, 'd. M.', { locale: cs })} – ${format(addDays(ws, 6), 'd. M. yyyy', { locale: cs })}`;
  }, [view, currentDate]);

  const handleSlotClick = (sheetId: string, start: Date) => {
    setDefaultSheetId(sheetId); setDefaultStart(start); setDialogOpen(true);
  };
  const openNew = () => {
    const base = new Date(currentDate); base.setHours(openHour, 0, 0, 0);
    setDefaultSheetId(sheets[0]?.id); setDefaultStart(base); setDialogOpen(true);
  };
  const guard = async <T,>(fn: () => Promise<T>): Promise<T> => {
    if (!checkLimit()) throw new Error('Příliš mnoho pokusů. Zkuste to za chvíli.');
    return fn();
  };

  const handleCancel = async () => {
    if (!detail) return;
    try {
      await cancelReservation(detail.id);
      toast({ title: 'Rezervace stornována' });
      setDetail(null);
    } catch (error) {
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Nepodařilo se stornovat.', variant: 'destructive' });
    }
  };

  // Měsíční přehled: rezervace podle dne.
  const monthDays = useMemo(() => {
    if (view !== 'month') return [];
    return eachDayOfInterval({ start: startOfMonth(currentDate), end: endOfMonth(currentDate) });
  }, [view, currentDate]);
  const reservationsByDay = (day: Date) =>
    reservations.filter((r) => isSameDay(new Date(r.start_at), day));
  const monthLead = view === 'month' ? (startOfMonth(currentDate).getDay() + 6) % 7 : 0;

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2">
            <CalendarCheck className="h-6 w-6" /> Kalendář ledu
          </h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">
            {canBook ? 'Rezervace ledu, komerční akce i tréninky na jednom místě.' : 'Přehled obsazenosti pláten.'}
          </p>
        </div>
        {canBook && (
          <Button onClick={openNew} className="w-full sm:w-auto"><Plus className="h-4 w-4 mr-2" /> Nová rezervace</Button>
        )}
      </div>

      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={goPrev} aria-label="Předchozí"><ChevronLeft className="h-4 w-4" /></Button>
          <Button variant="outline" size="sm" onClick={goToday}>Dnes</Button>
          <Button variant="outline" size="icon" onClick={goNext} aria-label="Další"><ChevronRight className="h-4 w-4" /></Button>
          <span className="ml-2 font-medium capitalize text-sm md:text-base">{headerLabel}</span>
        </div>
        <div className="flex gap-1">
          {(['day', 'week', 'month'] as const).map((v) => (
            <Button key={v} variant={view === v ? 'default' : 'outline'} size="sm" onClick={() => setView(v)}>
              {v === 'day' ? 'Den' : v === 'week' ? 'Týden' : 'Měsíc'}
            </Button>
          ))}
        </div>
      </div>

      {!canBook && (
        <div className="rounded-md border border-dashed p-3 text-sm text-muted-foreground">
          Pro vytváření rezervací musíte být zástupcem klubu. Kontaktujte správce haly.
        </div>
      )}

      <Card>
        <CardContent className="pt-4">
          {isLoading ? (
            <div className="py-12 text-center text-muted-foreground">Načítám…</div>
          ) : sheets.length === 0 ? (
            <div className="py-12 text-center text-muted-foreground">Zatím nejsou nastavená žádná plátna.</div>
          ) : view === 'month' ? (
            <div>
              <div className="grid grid-cols-7 gap-1 mb-1">
                {DAY_NAMES.map((d) => <div key={d} className="text-center text-xs font-medium text-muted-foreground">{d}</div>)}
              </div>
              <div className="grid grid-cols-7 gap-1">
                {Array.from({ length: monthLead }).map((_, i) => <div key={`b${i}`} />)}
                {monthDays.map((day) => {
                  const dayRes = reservationsByDay(day);
                  return (
                    <button
                      key={day.toISOString()} type="button"
                      onClick={() => { setCurrentDate(startOfDay(day)); setView('day'); }}
                      className={cn('min-h-[70px] md:min-h-[96px] rounded border p-1 text-left align-top hover:bg-accent',
                        isSameDay(day, new Date()) && 'border-primary bg-primary/5')}
                    >
                      <div className="text-xs font-medium">{format(day, 'd')}</div>
                      <div className="mt-1 space-y-0.5">
                        {dayRes.slice(0, 3).map((r) => (
                          <div key={r.id} className={cn('truncate rounded px-1 text-[10px]', chipClass(r))}>
                            {format(new Date(r.start_at), 'HH:mm')} {reservationLabel(r)}
                          </div>
                        ))}
                        {dayRes.length > 3 && <div className="text-[10px] text-muted-foreground">+{dayRes.length - 3} dalších</div>}
                      </div>
                    </button>
                  );
                })}
              </div>
            </div>
          ) : (
            <ReservationCalendar
              view={view}
              currentDate={currentDate}
              sheets={sheets}
              reservations={reservations}
              calendar={calendar}
              shiftFill={shiftFill}
              openHour={openHour}
              closeHour={closeHour}
              canBook={canBook}
              onSlotClick={handleSlotClick}
              onReservationClick={setDetail}
            />
          )}
        </CardContent>
      </Card>

      <ReservationDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        isAdmin={isAdmin}
        sheets={sheets}
        subjects={mySubjects}
        defaultSheetId={defaultSheetId}
        defaultStart={defaultStart}
        isCreating={isCreating}
        onClub={(d) => guard(() => createClub(d))}
        onCommercial={(d) => guard(() => createCommercial(d))}
        onInternal={(d) => guard(() => createInternal(d))}
      />

      <AlertDialog open={!!detail} onOpenChange={(o) => !o && setDetail(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{detail ? reservationLabel(detail) : ''}</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-1 text-sm">
                {detail && (
                  <>
                    <div>
                      {format(new Date(detail.start_at), 'EEEE d. MMMM, HH:mm', { locale: cs })}
                      {' – '}{format(new Date(detail.end_at), 'HH:mm', { locale: cs })}
                    </div>
                    {detail.events?.event_type && <div>Typ: {detail.events.event_type === 'commercial' ? 'komerční akce' : detail.events.event_type === 'training' ? 'trénink' : detail.events.event_type === 'maintenance' ? 'údržba' : 'akce'}</div>}
                    {(detail.corrected_amount ?? detail.amount) != null && (
                      <div>Částka: {fmtKc(Number(detail.corrected_amount ?? detail.amount))}
                        {' '}({Number(detail.corrected_hours ?? detail.hours)} h × {fmtKc(Number(detail.rate_per_hour))}/h)</div>
                    )}
                    {detail.event_id && shiftFill[detail.event_id] && (
                      <div>Štáb: {shiftFill[detail.event_id].filled}/{shiftFill[detail.event_id].total} obsazeno</div>
                    )}
                    {detail.note && <div className="text-muted-foreground">Poznámka: {detail.note}</div>}
                    {detail.event_id && (
                      <div className="text-muted-foreground text-xs">Storno zruší i volné směny této akce; obsazené zůstanou.</div>
                    )}
                  </>
                )}
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zavřít</AlertDialogCancel>
            <AlertDialogAction onClick={(e) => { e.preventDefault(); handleCancel(); }} disabled={isCancelling}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90">
              {isCancelling ? 'Ruším…' : 'Stornovat rezervaci'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default Calendar;
