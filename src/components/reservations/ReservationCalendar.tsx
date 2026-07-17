import { useMemo } from 'react';
import { format, addDays, isSameDay, startOfWeek } from 'date-fns';
import { cs } from 'date-fns/locale';
import { cn } from '@/lib/utils';
import type { Sheet, ReservationRow, CalendarSlot, ShiftFill } from '@/hooks/useReservations';

const PX_PER_MIN = 1; // 1 minuta = 1 px

// Barevný akcent podle pořadí plátna (index 0/1).
const SHEET_ACCENT = ['border-l-blue-500', 'border-l-emerald-500'];
const SHEET_DOT = ['bg-blue-500', 'bg-emerald-500'];

interface Props {
  view: 'day' | 'week';
  currentDate: Date;
  sheets: Sheet[];
  reservations: ReservationRow[]; // plné (moje/vše dle role)
  calendar: CalendarSlot[];        // obsazenost všech (maskovaná)
  shiftFill?: Record<string, ShiftFill>; // event_id → obsazenost štábu (admin/staff)
  openHour: number;
  closeHour: number;
  canBook: boolean;
  onSlotClick: (sheetId: string, start: Date) => void;
  onReservationClick: (reservation: ReservationRow) => void;
}

const fmtKc = (n: number) => `${n.toLocaleString('cs-CZ')} Kč`;

export function ReservationCalendar({
  view, currentDate, sheets, reservations, calendar, shiftFill = {},
  openHour, closeHour, canBook, onSlotClick, onReservationClick,
}: Props) {
  const openMin = openHour * 60;
  const totalMin = (closeHour - openHour) * 60;
  const gridHeight = totalMin * PX_PER_MIN;

  const days = useMemo(() => {
    if (view === 'day') return [currentDate];
    const weekStart = startOfWeek(currentDate, { weekStartsOn: 1 });
    return Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));
  }, [view, currentDate]);

  const hours = useMemo(
    () => Array.from({ length: closeHour - openHour + 1 }, (_, i) => openHour + i),
    [openHour, closeHour],
  );

  // Mapa plných rezervací podle plátna+začátku (kvůli spárování s maskovanou obsazeností).
  const fullByKey = useMemo(() => {
    const m = new Map<string, ReservationRow>();
    for (const r of reservations) m.set(`${r.sheet_id}|${new Date(r.start_at).getTime()}`, r);
    return m;
  }, [reservations]);

  const minutesFromOpen = (iso: string) => {
    const d = new Date(iso);
    return d.getHours() * 60 + d.getMinutes() - openMin;
  };

  const handleColumnClick = (e: React.MouseEvent<HTMLDivElement>, sheetId: string, day: Date) => {
    if (!canBook) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const offsetY = e.clientY - rect.top;
    const rawMin = openMin + offsetY / PX_PER_MIN;
    const snapped = Math.round(rawMin / 30) * 30; // krok 30 min
    const clamped = Math.max(openMin, Math.min(snapped, closeHour * 60 - 90));
    const start = new Date(day);
    start.setHours(Math.floor(clamped / 60), clamped % 60, 0, 0);
    onSlotClick(sheetId, start);
  };

  const renderSheetColumn = (day: Date, sheet: Sheet, sheetIndex: number) => {
    const slots = calendar.filter((c) => c.sheet_id === sheet.id && isSameDay(new Date(c.start_at), day));
    return (
      <div
        key={sheet.id}
        className={cn('relative flex-1 border-l', canBook && 'cursor-pointer')}
        style={{ height: gridHeight }}
        onClick={(e) => handleColumnClick(e, sheet.id, day)}
        aria-label={`${sheet.name}, ${format(day, 'd. M.', { locale: cs })}${canBook ? ' — klikni na volný čas pro rezervaci' : ''}`}
      >
        {/* hodinové linky */}
        {hours.map((h) => (
          <div
            key={h}
            className="absolute left-0 right-0 border-t border-dashed border-muted"
            style={{ top: (h * 60 - openMin) * PX_PER_MIN }}
          />
        ))}

        {slots.map((slot) => {
          const top = minutesFromOpen(slot.start_at) * PX_PER_MIN;
          const height = Math.max(
            ((new Date(slot.end_at).getTime() - new Date(slot.start_at).getTime()) / 60000) * PX_PER_MIN,
            22,
          );
          const full = fullByKey.get(`${sheet.id}|${new Date(slot.start_at).getTime()}`);
          const timeLabel = `${format(new Date(slot.start_at), 'HH:mm')}–${format(new Date(slot.end_at), 'HH:mm')}`;

          if (full) {
            const amount = full.corrected_amount ?? full.amount;
            const label = full.subjects?.name ?? full.events?.title ?? 'Rezervace';
            const fill = full.event_id ? shiftFill[full.event_id] : undefined;
            const isCommercial = full.events?.event_type === 'commercial';
            return (
              <button
                key={slot.start_at + sheet.id}
                type="button"
                onClick={(e) => { e.stopPropagation(); onReservationClick(full); }}
                className={cn(
                  'absolute left-1 right-1 rounded-md border border-l-4 bg-card p-1.5 text-left shadow-sm',
                  'hover:ring-2 hover:ring-ring overflow-hidden',
                  SHEET_ACCENT[sheetIndex % SHEET_ACCENT.length],
                )}
                style={{ top, height }}
              >
                <div className="flex items-center gap-1">
                  <span className="truncate text-xs font-medium">{label}</span>
                  {isCommercial && fill && (
                    <span className={cn(
                      'ml-auto shrink-0 rounded px-1 text-[10px] font-semibold',
                      fill.filled >= fill.total ? 'bg-green-100 text-green-700' : 'bg-amber-100 text-amber-700',
                    )}>{fill.filled}/{fill.total}</span>
                  )}
                </div>
                <div className="truncate text-[11px] text-muted-foreground">{timeLabel}</div>
                {view === 'day' && amount != null && (
                  <div className="text-[11px] text-muted-foreground">{fmtKc(Number(amount))}</div>
                )}
              </button>
            );
          }
          // Maskovaná (cizí) obsazenost — bez identity/částky
          return (
            <div
              key={slot.start_at + sheet.id}
              className="absolute left-1 right-1 rounded-md bg-muted p-1.5 text-muted-foreground overflow-hidden"
              style={{ top, height }}
              onClick={(e) => e.stopPropagation()}
            >
              <div className="truncate text-xs font-medium">Obsazeno</div>
              <div className="truncate text-[11px]">{timeLabel}</div>
            </div>
          );
        })}
      </div>
    );
  };

  return (
    <div className="overflow-x-auto">
      <div className="flex min-w-fit">
        {/* časová osa */}
        <div className="w-12 flex-shrink-0 pt-8">
          <div className="relative" style={{ height: gridHeight }}>
            {hours.map((h) => (
              <div
                key={h}
                className="absolute right-1 -translate-y-1/2 text-[11px] text-muted-foreground"
                style={{ top: (h * 60 - openMin) * PX_PER_MIN }}
              >
                {String(h).padStart(2, '0')}:00
              </div>
            ))}
          </div>
        </div>

        {/* dny */}
        <div className="flex flex-1">
          {days.map((day) => (
            <div
              key={day.toISOString()}
              className={cn('flex flex-col border-l', view === 'week' ? 'min-w-[160px] flex-1' : 'flex-1')}
            >
              <div className={cn(
                'h-8 flex items-center justify-center border-b text-xs font-medium capitalize',
                isSameDay(day, new Date()) && 'bg-accent',
              )}>
                {view === 'week' ? format(day, 'EEE d. M.', { locale: cs }) : format(day, 'EEEE d. MMMM', { locale: cs })}
              </div>
              <div className="flex flex-1">
                {sheets.map((sheet, i) => renderSheetColumn(day, sheet, i))}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* legenda pláten */}
      <div className="mt-3 flex flex-wrap items-center gap-4 px-2 text-xs text-muted-foreground">
        {sheets.map((s, i) => (
          <span key={s.id} className="flex items-center gap-1.5">
            <span className={cn('inline-block h-2.5 w-2.5 rounded-full', SHEET_DOT[i % SHEET_DOT.length])} />
            {s.name}
          </span>
        ))}
        <span className="flex items-center gap-1.5">
          <span className="inline-block h-2.5 w-2.5 rounded-full bg-muted" /> Obsazeno (jiný klub)
        </span>
      </div>
    </div>
  );
}
