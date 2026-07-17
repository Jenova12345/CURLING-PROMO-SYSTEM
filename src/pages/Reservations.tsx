import { useMemo, useState } from 'react';
import {
  format, startOfDay, addDays, subDays, startOfWeek, addWeeks, subWeeks,
} from 'date-fns';
import { cs } from 'date-fns/locale';
import { ChevronLeft, ChevronRight, CalendarCheck, Plus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/components/ui/use-toast';
import { useRateLimit } from '@/hooks/useRateLimit';
import { useReservations, type ReservationRow } from '@/hooks/useReservations';
import { ReservationCalendar } from '@/components/reservations/ReservationCalendar';
import { ReservationDialog } from '@/components/reservations/ReservationDialog';

type View = 'day' | 'week';

// Otevírací doba → rozsah svislé osy. Fallback 8–22.
function parseOpeningHours(openingHours: unknown): { open: number; close: number } {
  const fallback = { open: 8, close: 22 };
  if (!openingHours || typeof openingHours !== 'object') return fallback;
  let open = 24, close = 0, seen = false;
  for (const v of Object.values(openingHours as Record<string, { open?: string; close?: string }>)) {
    if (!v?.open || !v?.close) continue; // přeskoč zavřené/neúplné dny
    const o = Number(v.open.split(':')[0]);
    const c = Number(v.close.split(':')[0]);
    if (Number.isNaN(o) || Number.isNaN(c)) continue;
    open = Math.min(open, o);
    close = Math.max(close, c);
    seen = true;
  }
  if (!seen || open >= close) return fallback;
  return { open, close };
}

const fmtKc = (n: number) => `${n.toLocaleString('cs-CZ')} Kč`;

const Reservations = () => {
  const { toast } = useToast();
  const { checkLimit } = useRateLimit('createReservation');

  const [view, setView] = useState<View>('day');
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
    const from = startOfWeek(currentDate, { weekStartsOn: 1 });
    return { from: from.toISOString(), to: addDays(from, 7).toISOString() };
  }, [view, currentDate]);

  const {
    reservations, calendar, sheets, mySubjects, settings, isLoading,
    createReservation, cancelReservation, isCreating, isCancelling,
  } = useReservations(range);

  const { open: openHour, close: closeHour } = useMemo(
    () => parseOpeningHours(settings?.opening_hours),
    [settings],
  );

  // Kdo smí rezervovat: admin nebo zástupce (má vrácený aspoň jeden subjekt přes RLS).
  const canBook = mySubjects.length > 0;

  const goPrev = () => setCurrentDate((d) => (view === 'day' ? subDays(d, 1) : subWeeks(d, 1)));
  const goNext = () => setCurrentDate((d) => (view === 'day' ? addDays(d, 1) : addWeeks(d, 1)));
  const goToday = () => setCurrentDate(startOfDay(new Date()));

  const headerLabel = useMemo(() => {
    if (view === 'day') return format(currentDate, 'EEEE d. MMMM yyyy', { locale: cs });
    const ws = startOfWeek(currentDate, { weekStartsOn: 1 });
    return `${format(ws, 'd. M.', { locale: cs })} – ${format(addDays(ws, 6), 'd. M. yyyy', { locale: cs })}`;
  }, [view, currentDate]);

  const handleSlotClick = (sheetId: string, start: Date) => {
    setDefaultSheetId(sheetId);
    setDefaultStart(start);
    setDialogOpen(true);
  };

  const openNewFromButton = () => {
    const base = new Date(currentDate);
    base.setHours(openHour, 0, 0, 0);
    setDefaultSheetId(sheets[0]?.id);
    setDefaultStart(base);
    setDialogOpen(true);
  };

  const handleCreate = async (data: Parameters<typeof createReservation>[0]) => {
    if (!checkLimit()) throw new Error('Příliš mnoho pokusů. Zkuste to za chvíli.');
    return createReservation(data);
  };

  const handleCancel = async () => {
    if (!detail) return;
    try {
      await cancelReservation(detail.id);
      toast({ title: 'Rezervace stornována' });
      setDetail(null);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se stornovat.';
      toast({ title: 'Chyba', description: message, variant: 'destructive' });
    }
  };

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Hlavička */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2">
            <CalendarCheck className="h-6 w-6" /> Rezervace ledu
          </h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">
            {canBook ? 'Klikni na volný slot v kalendáři a zarezervuj plátno.' : 'Přehled obsazenosti pláten.'}
          </p>
        </div>
        {canBook && (
          <Button onClick={openNewFromButton} className="w-full sm:w-auto">
            <Plus className="h-4 w-4 mr-2" /> Nová rezervace
          </Button>
        )}
      </div>

      {/* Ovládání: navigace + přepínač pohledu */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={goPrev} aria-label="Předchozí"><ChevronLeft className="h-4 w-4" /></Button>
          <Button variant="outline" size="sm" onClick={goToday}>Dnes</Button>
          <Button variant="outline" size="icon" onClick={goNext} aria-label="Další"><ChevronRight className="h-4 w-4" /></Button>
          <span className="ml-2 font-medium capitalize text-sm md:text-base">{headerLabel}</span>
        </div>
        <div className="flex gap-1">
          <Button variant={view === 'day' ? 'default' : 'outline'} size="sm" onClick={() => setView('day')}>Den</Button>
          <Button variant={view === 'week' ? 'default' : 'outline'} size="sm" onClick={() => setView('week')}>Týden</Button>
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
          ) : (
            <ReservationCalendar
              view={view}
              currentDate={currentDate}
              sheets={sheets}
              reservations={reservations}
              calendar={calendar}
              openHour={openHour}
              closeHour={closeHour}
              canBook={canBook}
              onSlotClick={handleSlotClick}
              onReservationClick={setDetail}
            />
          )}
        </CardContent>
      </Card>

      {/* Formulář nové rezervace */}
      <ReservationDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        sheets={sheets}
        subjects={mySubjects}
        defaultSheetId={defaultSheetId}
        defaultStart={defaultStart}
        onSubmit={handleCreate}
        isCreating={isCreating}
      />

      {/* Detail rezervace + storno */}
      <AlertDialog open={!!detail} onOpenChange={(o) => !o && setDetail(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{detail?.subjects?.name ?? 'Rezervace'}</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-1 text-sm">
                {detail && (
                  <>
                    <div>
                      {format(new Date(detail.start_at), 'EEEE d. MMMM, HH:mm', { locale: cs })}
                      {' – '}{format(new Date(detail.end_at), 'HH:mm', { locale: cs })}
                    </div>
                    {detail.subjects?.type === 'commercial' && <div>Typ: komerční</div>}
                    {(detail.corrected_amount ?? detail.amount) != null && (
                      <div>Částka: {fmtKc(Number(detail.corrected_amount ?? detail.amount))}
                        {' '}({Number(detail.corrected_hours ?? detail.hours)} h × {fmtKc(Number(detail.rate_per_hour))}/h)</div>
                    )}
                    {detail.note && <div className="text-muted-foreground">Poznámka: {detail.note}</div>}
                  </>
                )}
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zavřít</AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => { e.preventDefault(); handleCancel(); }}
              disabled={isCancelling}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isCancelling ? 'Ruším…' : 'Stornovat rezervaci'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default Reservations;
