import { useMemo, useState } from 'react';
import {
  format, startOfDay, addDays, subDays, startOfWeek, addWeeks, subWeeks,
  startOfMonth, endOfMonth, eachDayOfInterval, isSameDay, addMonths, subMonths,
} from 'date-fns';
import { cs } from 'date-fns/locale';
import { ChevronLeft, ChevronRight, CalendarCheck, Plus, Clock } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';
import { cn } from '@/lib/utils';
import {
  AlertDialog, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/components/ui/use-toast';
import { useAuth } from '@/contexts/AuthContext';
import { useRateLimit } from '@/hooks/useRateLimit';
import { useReservations, type CalendarReservation } from '@/hooks/useReservations';
import { hoursForDay, openingHoursEnvelope } from '@/lib/openingHours';
import { ReservationCalendar } from '@/components/reservations/ReservationCalendar';
import { ReservationDialog } from '@/components/reservations/ReservationDialog';
import { ObsazeniDetail } from '@/components/reservations/ObsazeniDetail';

type View = 'day' | 'week' | 'month';

const DAY_NAMES = ['Po', 'Út', 'St', 'Čt', 'Pá', 'So', 'Ne'];
const fmtKc = (n: number) => `${n.toLocaleString('cs-CZ')} Kč`;

const EVENT_TYPE_LABELS: Record<string, string> = {
  commercial: 'Komerční akce',
  recruitment: 'Náborová akce',
  tournament: 'Turnaj',
  training: 'Trénink',
  maintenance: 'Údržba ledu',
};

// Barva podle typu akce (stejná paleta se používá i v mřížce kalendáře).
function chipClass(r: CalendarReservation): string {
  switch (r.event_type) {
    case 'commercial':
    case 'recruitment': return 'bg-green-100 text-green-800';
    case 'tournament': return 'bg-purple-100 text-purple-800';
    case 'maintenance': return 'bg-orange-100 text-orange-800';
    default: return 'bg-blue-100 text-blue-800';
  }
}

// Název, který vidí VŠICHNI přihlášení (klub / akce) — maskuje se jen částka.
function reservationLabel(r: CalendarReservation): string {
  if (r.subject_name && r.event_title) return `${r.subject_name} — ${r.event_title}`;
  return r.event_title ?? r.subject_name ?? 'Rezervace';
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
  const [editing, setEditing] = useState<CalendarReservation | null>(null);
  const [detail, setDetail] = useState<CalendarReservation | null>(null);
  const [cancelling, setCancelling] = useState<CalendarReservation | null>(null);
  const [pendingMove, setPendingMove] = useState<
    { reservation: CalendarReservation; start: Date; end: Date; sheetId: string } | null
  >(null);

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

  const api = useReservations(range);
  const {
    reservations, sheets, mySubjects, myMemberships, settings, shiftFill, isLoading,
    cancelBooking, approveReservation, isCancelling, isApproving,
  } = api;

  const sheetName = (id: string | null) => sheets.find((s) => s.id === id)?.name ?? 'Dráha';

  // Kolik drah drží stejná akce (kvůli stornu „celé akce" a přesunu).
  const lanesOfEvent = (r: CalendarReservation | null) =>
    r?.event_id ? reservations.filter((x) => x.event_id === r.event_id).length : 1;

  // Mřížka se kreslí přes obálku celého týdne, ale validuje se vždy podle
  // konkrétního dne — otevírací doba se v Nastavení dá zadat pro každý den zvlášť.
  const { open: openHour, close: closeHour } = useMemo(
    () => openingHoursEnvelope(settings?.opening_hours), [settings],
  );
  const hoursOfDay = useMemo(
    () => (day: Date) => hoursForDay(settings?.opening_hours, day),
    [settings],
  );
  const canBook = isAdmin || mySubjects.some((s) => myMemberships.some((m) => m.subject_id === s.id));

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
    setEditing(null); setDefaultSheetId(sheetId); setDefaultStart(start); setDialogOpen(true);
  };
  const openNew = () => {
    const base = new Date(currentDate); base.setHours(openHour, 0, 0, 0);
    setEditing(null); setDefaultSheetId(sheets[0]?.id); setDefaultStart(base); setDialogOpen(true);
  };
  const openEdit = (r: CalendarReservation) => {
    setDetail(null); setEditing(r); setDialogOpen(true);
  };

  // Zakládání rezervací drží rate limit (ochrana proti překlikání i proti robotům).
  const limit = () => {
    if (!checkLimit()) throw new Error('Příliš mnoho pokusů. Zkuste to za chvíli.');
  };

  const handleCancel = async (scope: 'single' | 'event' | 'series') => {
    if (!cancelling) return;
    try {
      await cancelBooking({ id: cancelling.id!, scope });
      toast({ title: scope === 'single' ? 'Rezervace stornována' : scope === 'event' ? 'Akce stornována' : 'Série stornována' });
      setCancelling(null); setDetail(null);
    } catch (error) {
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Nepodařilo se stornovat.', variant: 'destructive' });
    }
  };

  const handleApprove = async (r: CalendarReservation) => {
    try {
      await approveReservation(r.id!);
      toast({ title: 'Rezervace potvrzena' });
      setDetail(null);
    } catch (error) {
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Nepodařilo se potvrdit.', variant: 'destructive' });
    }
  };

  // Tažení jen navrhne nový termín — uloží se až po potvrzení. Do té doby rezervace
  // zůstává na původním místě, takže „Zrušit" nemá co vracet.
  // U akce na obou drahách se dráha nemění (server to ani nedovolí) — kdyby uživatel
  // v úzkých týdenních sloupcích trefil tu druhou, posune se jen čas.
  const requestMove = (r: CalendarReservation, start: Date, end: Date, sheetId: string) =>
    setPendingMove({
      reservation: r,
      start,
      end,
      sheetId: lanesOfEvent(r) > 1 ? r.sheet_id! : sheetId,
    });

  const confirmMove = async () => {
    if (!pendingMove) return;
    const { reservation, start, end, sheetId } = pendingMove;
    try {
      await api.moveBooking({
        id: reservation.id!, start_at: start.toISOString(), end_at: end.toISOString(), sheet_id: sheetId,
      });
      toast({
        title: 'Rezervace přesunuta',
        description: `${format(start, 'EEEE d. M. HH:mm', { locale: cs })}–${format(end, 'HH:mm')}`,
      });
      setPendingMove(null);
    } catch (error) {
      toast({ title: 'Přesun se nepovedl', description: error instanceof Error ? error.message : 'Zkuste to znovu.', variant: 'destructive' });
      setPendingMove(null);
    }
  };

  const handleOutsideHours = (start: Date, end: Date) => {
    const { open, close } = hoursOfDay(start);
    toast({
      title: 'Mimo otevírací dobu',
      description: `${format(start, 'EEEE', { locale: cs })} se hraje ${String(open).padStart(2, '0')}:00–${String(close).padStart(2, '0')}:00, termín ${format(start, 'HH:mm')}–${format(end, 'HH:mm')} je mimo. Rezervace zůstala na původním místě.`,
      variant: 'destructive',
    });
  };

  // Měsíční přehled: rezervace podle dne.
  const monthDays = useMemo(() => {
    if (view !== 'month') return [];
    return eachDayOfInterval({ start: startOfMonth(currentDate), end: endOfMonth(currentDate) });
  }, [view, currentDate]);
  const reservationsByDay = (day: Date) =>
    reservations.filter((r) => isSameDay(new Date(r.start_at!), day));
  const monthLead = view === 'month' ? (startOfMonth(currentDate).getDay() + 6) % 7 : 0;

  const detailLanes = lanesOfEvent(detail);
  const cancelLanes = lanesOfEvent(cancelling);

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2">
            <CalendarCheck className="h-6 w-6" /> Kalendář ledu
          </h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">
            {canBook ? 'Rezervace ledu, komerční akce i tréninky na jednom místě.' : 'Přehled obsazenosti drah.'}
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
          Rezervovat můžou členové a zástupci klubů. Pokud za klub rezervovat potřebujete, ozvěte se správci haly.
        </div>
      )}

      <Card>
        <CardContent className="pt-4">
          {isLoading ? (
            <div className="py-12 text-center text-muted-foreground">Načítám…</div>
          ) : sheets.length === 0 ? (
            <div className="py-12 text-center text-muted-foreground">Zatím nejsou nastavené žádné dráhy.</div>
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
                            {format(new Date(r.start_at!), 'HH:mm')} {reservationLabel(r)}
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
              shiftFill={shiftFill}
              openHour={openHour}
              closeHour={closeHour}
              canBook={canBook}
              onSlotClick={handleSlotClick}
              onReservationClick={setDetail}
              onMove={requestMove}
              onOutsideHours={handleOutsideHours}
              hoursForDay={hoursOfDay}
            />
          )}
        </CardContent>
      </Card>

      <ReservationDialog
        open={dialogOpen}
        onOpenChange={(o) => { setDialogOpen(o); if (!o) setEditing(null); }}
        isAdmin={isAdmin}
        sheets={sheets}
        subjects={mySubjects}
        memberships={myMemberships}
        settings={settings}
        defaultSheetId={defaultSheetId}
        defaultStart={defaultStart}
        editing={editing}
        editingLanes={lanesOfEvent(editing)}
        api={{
          createBooking: (input) => { limit(); return api.createBooking(input); },
          createSeries: (input) => { limit(); return api.createSeries(input); },
          updateBooking: api.updateBooking,
          moveBooking: api.moveBooking,
          checkConflicts: api.checkConflicts,
          aresLookup: api.aresLookup,
          findSubjectByIco: api.findSubjectByIco,
          createSubject: api.createSubject,
          isCreating: api.isCreating,
          isUpdating: api.isUpdating,
        }}
      />

      {/* Detail rezervace */}
      <AlertDialog open={!!detail} onOpenChange={(o) => !o && setDetail(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{detail ? reservationLabel(detail) : ''}</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-1 text-sm">
                {detail && (
                  <>
                    <div>
                      {format(new Date(detail.start_at!), 'EEEE d. MMMM, HH:mm', { locale: cs })}
                      {' – '}{format(new Date(detail.end_at!), 'HH:mm', { locale: cs })}
                    </div>
                    <div className="flex flex-wrap items-center gap-2 pt-1">
                      <Badge variant="outline">{EVENT_TYPE_LABELS[detail.event_type ?? 'training'] ?? 'Akce'}</Badge>
                      <Badge variant="secondary">{sheetName(detail.sheet_id)}</Badge>
                      {detailLanes > 1 && <Badge variant="secondary">obě dráhy</Badge>}
                      {detail.series_id && <Badge variant="secondary">opakovaná</Badge>}
                      {!detail.approved_at && (
                        <Badge variant="outline" className="border-amber-500 text-amber-600">
                          <Clock className="mr-1 h-3 w-3" /> čeká na potvrzení
                        </Badge>
                      )}
                    </div>
                    {detail.can_see_amount && (detail.corrected_amount ?? detail.amount) != null && (
                      <div className="pt-1">Částka: {fmtKc(Number(detail.corrected_amount ?? detail.amount))}
                        {' '}({Number(detail.corrected_hours ?? detail.hours)} h × {fmtKc(Number(detail.rate_per_hour))}/h)</div>
                    )}
                    {detail.event_id && shiftFill[detail.event_id] && (
                      <div>Obsazení štábu: {shiftFill[detail.event_id].filled}/{shiftFill[detail.event_id].total}</div>
                    )}
                    {detail.note && <div className="text-muted-foreground">Poznámka: {detail.note}</div>}

                    {/* audit — kdo zadal, kdo zrušil */}
                    <div className="pt-2 text-xs text-muted-foreground">
                      <div>
                        Zadal: <span className="font-medium">{detail.created_by_name ?? 'neznámý'}</span>
                        {detail.created_at && ` · ${format(new Date(detail.created_at), 'd. M. yyyy HH:mm')}`}
                      </div>
                      {detail.approved_at && (
                        <div>Potvrzeno: {format(new Date(detail.approved_at), 'd. M. yyyy HH:mm')}</div>
                      )}
                      {detail.cancelled_at && (
                        <div>
                          Zrušil: <span className="font-medium">{detail.cancelled_by_name ?? 'neznámý'}</span>
                          {` · ${format(new Date(detail.cancelled_at), 'd. M. yyyy HH:mm')}`}
                          {detail.cancel_reason && ` — ${detail.cancel_reason}`}
                        </div>
                      )}
                    </div>

                    {detail.event_id && detailLanes === 1 && (
                      <div className="text-muted-foreground text-xs">Storno zruší i volné/nepotvrzené směny této akce; potvrzené zůstanou.</div>
                    )}
                    {isAdmin && detail.event_id && (detail.event_type === 'commercial' || detail.event_type === 'recruitment') && (
                      <ObsazeniDetail eventId={detail.event_id} />
                    )}
                  </>
                )}
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zavřít</AlertDialogCancel>
            {detail?.can_approve && !detail.approved_at && (
              <Button variant="outline" onClick={() => handleApprove(detail)} disabled={isApproving}>
                {isApproving ? 'Potvrzuji…' : 'Potvrdit rezervaci'}
              </Button>
            )}
            {detail?.can_manage && detail.status === 'confirmed' && (
              <>
                <Button variant="outline" onClick={() => openEdit(detail)}>Upravit</Button>
                <Button
                  variant="destructive"
                  onClick={() => { setCancelling(detail); setDetail(null); }}
                >
                  Stornovat
                </Button>
              </>
            )}
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Potvrzení přesunu tažením */}
      <AlertDialog open={!!pendingMove} onOpenChange={(o) => !o && setPendingMove(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Přesunout akci?</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2 text-sm">
                {pendingMove && (
                  <>
                    <div className="font-medium text-foreground">{reservationLabel(pendingMove.reservation)}</div>
                    <div>
                      Z: {format(new Date(pendingMove.reservation.start_at!), 'EEEE d. M. HH:mm', { locale: cs })}
                      –{format(new Date(pendingMove.reservation.end_at!), 'HH:mm')}
                      {' · '}{sheetName(pendingMove.reservation.sheet_id)}
                    </div>
                    <div className="font-medium text-foreground">
                      Na: {format(pendingMove.start, 'EEEE d. M. HH:mm', { locale: cs })}
                      –{format(pendingMove.end, 'HH:mm')}
                      {' · '}{sheetName(pendingMove.sheetId)}
                    </div>
                    {lanesOfEvent(pendingMove.reservation) > 1 && (
                      <div className="text-muted-foreground">
                        Akce běží na obou drahách — přesune se celá, dráhy zůstanou.
                      </div>
                    )}
                  </>
                )}
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zrušit</AlertDialogCancel>
            <Button onClick={confirmMove} disabled={api.isUpdating}>
              {api.isUpdating ? 'Přesouvám…' : 'Přesunout'}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Storno — u akce na obou drahách a u série se doptáme na rozsah */}
      <AlertDialog open={!!cancelling} onOpenChange={(o) => !o && setCancelling(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Stornovat rezervaci?</AlertDialogTitle>
            <AlertDialogDescription>
              {cancelling && (
                <>
                  {reservationLabel(cancelling)} — {format(new Date(cancelling.start_at!), 'EEEE d. M. HH:mm', { locale: cs })}
                  {cancelLanes > 1 && '. Akce běží na obou drahách.'}
                  {cancelling.series_id && ' Rezervace je součástí opakované série.'}
                </>
              )}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter className="flex-col gap-2 sm:flex-row">
            <AlertDialogCancel>Zpět</AlertDialogCancel>
            <Button variant="destructive" onClick={() => handleCancel('single')} disabled={isCancelling}>
              {cancelLanes > 1 ? 'Jen tuhle dráhu' : 'Stornovat'}
            </Button>
            {cancelLanes > 1 && (
              <Button variant="destructive" onClick={() => handleCancel('event')} disabled={isCancelling}>
                Celou akci (obě dráhy)
              </Button>
            )}
            {cancelling?.series_id && (
              <Button variant="destructive" onClick={() => handleCancel('series')} disabled={isCancelling}>
                Celou sérii (budoucí termíny)
              </Button>
            )}
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default Calendar;
