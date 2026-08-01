import { useMemo, useRef, useState } from 'react';
import { format, addDays, isSameDay, startOfWeek } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Clock } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { Sheet, CalendarReservation, ShiftFill } from '@/hooks/useReservations';

const PX_PER_MIN = 1;      // 1 minuta = 1 px
const DRAG_THRESHOLD = 6;  // menší posun bereme jako klik, ne tažení

// Barva podle typu akce (komerční / turnaj / trénink / údržba).
const TYPE_STYLE: Record<string, string> = {
  commercial:  'border-l-green-500 bg-green-50',
  recruitment: 'border-l-green-500 bg-green-50',
  tournament:  'border-l-purple-500 bg-purple-50',
  maintenance: 'border-l-orange-500 bg-orange-50',
  training:    'border-l-blue-500 bg-blue-50',
};

const TYPE_LEGEND: [string, string, string][] = [
  ['commercial', 'Komerční akce', 'bg-green-500'],
  ['tournament', 'Turnaj', 'bg-purple-500'],
  ['training', 'Trénink / klub', 'bg-blue-500'],
  ['maintenance', 'Údržba ledu', 'bg-orange-500'],
];

// Jemné odlišení drah — barva tady nesmí konkurovat barvám typů akcí,
// proto jen decentní podklad druhé dráhy + popisek nad každým sloupcem.
const LANE_TINT = ['', 'bg-muted/40'];

interface Props {
  view: 'day' | 'week';
  currentDate: Date;
  sheets: Sheet[];
  /** potvrzené rezervace zobrazeného období (částky maskuje už databáze) */
  reservations: CalendarReservation[];
  shiftFill?: Record<string, ShiftFill>;
  openHour: number;
  closeHour: number;
  canBook: boolean;
  onSlotClick: (sheetId: string, start: Date) => void;
  onReservationClick: (reservation: CalendarReservation) => void;
  /**
   * Uživatel dotáhl rezervaci na nový termín. Stránka se nejdřív zeptá na potvrzení,
   * teprve pak ukládá — do té doby blok zůstává na původním místě.
   */
  onMove?: (reservation: CalendarReservation, start: Date, end: Date, sheetId: string) => void;
  /** cílový termín je mimo otevírací dobu — hlásí stránka, neukládá se nic */
  onOutsideHours?: (start: Date, end: Date) => void;
}

const fmtKc = (n: number) => `${n.toLocaleString('cs-CZ')} Kč`;

export function ReservationCalendar({
  view, currentDate, sheets, reservations, shiftFill = {},
  openHour, closeHour, canBook, onSlotClick, onReservationClick, onMove, onOutsideHours,
}: Props) {
  const openMin = openHour * 60;
  const totalMin = (closeHour - openHour) * 60;
  const gridHeight = totalMin * PX_PER_MIN;

  // Tažení dává smysl u myši; na dotyku by bralo scrollování.
  const canDrag = useMemo(
    () => !!onMove && typeof window !== 'undefined' && !!window.matchMedia?.('(pointer: fine)').matches,
    [onMove],
  );

  const dragRef = useRef<{ res: CalendarReservation; x: number; y: number; moved: boolean } | null>(null);
  const [preview, setPreview] = useState<{ id: string; dx: number; dy: number } | null>(null);

  const days = useMemo(() => {
    if (view === 'day') return [currentDate];
    const weekStart = startOfWeek(currentDate, { weekStartsOn: 1 });
    return Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));
  }, [view, currentDate]);

  const hours = useMemo(
    () => Array.from({ length: closeHour - openHour + 1 }, (_, i) => openHour + i),
    [openHour, closeHour],
  );

  const minutesFromOpen = (iso: string) => {
    const d = new Date(iso);
    return d.getHours() * 60 + d.getMinutes() - openMin;
  };

  const handleColumnClick = (e: React.MouseEvent<HTMLDivElement>, sheetId: string, day: Date) => {
    if (!canBook) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const offsetY = e.clientY - rect.top;
    const rawMin = openMin + offsetY / PX_PER_MIN;
    const snapped = Math.floor(rawMin / 60) * 60;                        // celé hodiny
    const clamped = Math.max(openMin, Math.min(snapped, closeHour * 60 - 60));
    const start = new Date(day);
    start.setHours(Math.floor(clamped / 60), 0, 0, 0);
    onSlotClick(sheetId, start);
  };

  // ---- tažení rezervace (drag & drop) ----------------------------------------
  const onPointerDown = (e: React.PointerEvent, r: CalendarReservation) => {
    if (!canDrag || !r.can_manage) return;
    (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
    dragRef.current = { res: r, x: e.clientX, y: e.clientY, moved: false };
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const d = dragRef.current;
    if (!d) return;
    const dx = e.clientX - d.x;
    const dy = e.clientY - d.y;
    if (!d.moved && Math.abs(dx) + Math.abs(dy) < DRAG_THRESHOLD) return;
    d.moved = true;
    setPreview({ id: d.res.id!, dx, dy });
  };

  const onPointerUp = (e: React.PointerEvent, r: CalendarReservation) => {
    const d = dragRef.current;
    dragRef.current = null;
    setPreview(null);
    if (!d || !d.moved || !onMove) { onReservationClick(r); return; }

    const hourShift = Math.round((e.clientY - d.y) / (60 * PX_PER_MIN));
    const origStart = new Date(d.res.start_at!);
    const origEnd = new Date(d.res.end_at!);
    const duration = origEnd.getTime() - origStart.getTime();

    let start = new Date(origStart.getTime() + hourShift * 3_600_000);
    let sheetId = d.res.sheet_id!;

    // Cílový sloupec (den + dráha) podle místa, kde uživatel pustil myš.
    // Tažený blok se drží pod kurzorem, takže by ho elementFromPoint našel místo
    // sloupce pod ním — na okamžik ho proto vyřadíme z hit-testu.
    const dragged = e.currentTarget as HTMLElement;
    const prevPointerEvents = dragged.style.pointerEvents;
    dragged.style.pointerEvents = 'none';
    const target = (document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null)
      ?.closest('[data-lane]') as HTMLElement | null;
    dragged.style.pointerEvents = prevPointerEvents;

    if (target?.dataset.day && target.dataset.sheetId) {
      const [y, m, dd] = target.dataset.day.split('-').map(Number);
      start = new Date(y, m - 1, dd, start.getHours(), 0, 0, 0);
      sheetId = target.dataset.sheetId;
    }
    const end = new Date(start.getTime() + duration);

    if (start.getTime() === origStart.getTime() && sheetId === d.res.sheet_id) return;

    // Otevírací dobu ověříme hned — ať se uživatel neptá na termín, který server odmítne.
    const endsNextDay = end.getDate() !== start.getDate();
    if (start.getHours() < openHour || endsNextDay || end.getHours() > closeHour
        || (end.getHours() === 0 && end.getMinutes() === 0)) {
      onOutsideHours?.(start, end);
      return;
    }

    onMove(d.res, start, end, sheetId);
  };

  const renderSheetColumn = (day: Date, sheet: Sheet, laneIndex: number) => {
    const dayReservations = reservations.filter(
      (r) => r.sheet_id === sheet.id && isSameDay(new Date(r.start_at!), day),
    );
    return (
      <div
        key={sheet.id}
        data-lane=""
        data-sheet-id={sheet.id}
        data-day={format(day, 'yyyy-MM-dd')}
        className={cn('relative flex-1 border-l', LANE_TINT[laneIndex % LANE_TINT.length], canBook && 'cursor-pointer')}
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

        {dayReservations.map((r) => {
          const top = minutesFromOpen(r.start_at!) * PX_PER_MIN;
          const height = Math.max(
            ((new Date(r.end_at!).getTime() - new Date(r.start_at!).getTime()) / 60000) * PX_PER_MIN,
            26,
          );
          const timeLabel = `${format(new Date(r.start_at!), 'HH:mm')}–${format(new Date(r.end_at!), 'HH:mm')}`;
          const amount = r.corrected_amount ?? r.amount;
          const fill = r.event_id ? shiftFill[r.event_id] : undefined;
          const isCommercial = r.event_type === 'commercial' || r.event_type === 'recruitment';
          const label = r.event_title ?? r.subject_name ?? 'Rezervace';
          const dragging = preview?.id === r.id;

          return (
            <button
              key={r.id}
              type="button"
              onClick={(e) => e.stopPropagation()}
              onPointerDown={(e) => { e.stopPropagation(); onPointerDown(e, r); }}
              onPointerMove={onPointerMove}
              onPointerUp={(e) => { e.stopPropagation(); onPointerUp(e, r); }}
              onPointerCancel={() => { dragRef.current = null; setPreview(null); }}
              className={cn(
                'absolute left-1 right-1 rounded-md border border-l-4 p-1.5 text-left shadow-sm',
                'hover:ring-2 hover:ring-ring overflow-hidden',
                TYPE_STYLE[r.event_type ?? 'training'] ?? 'border-l-slate-400 bg-slate-50',
                !r.approved_at && 'border-dashed',
                canDrag && r.can_manage && 'cursor-grab touch-none',
                dragging && 'z-20 cursor-grabbing opacity-80 ring-2 ring-primary',
              )}
              style={{
                top, height,
                transform: dragging ? `translate(${preview!.dx}px, ${preview!.dy}px)` : undefined,
              }}
              title={`${label} · ${timeLabel}${r.approved_at ? '' : ' · čeká na potvrzení zástupcem'}`}
            >
              <div className="flex items-center gap-1">
                {/* název vidí každý přihlášený — maskuje se jen částka */}
                <span className="truncate text-xs font-medium">{label}</span>
                {!r.approved_at && <Clock className="h-3 w-3 shrink-0 text-amber-600" />}
                {isCommercial && fill && (
                  <span className={cn(
                    'ml-auto shrink-0 rounded px-1 text-[10px] font-semibold',
                    fill.filled >= fill.total ? 'bg-green-100 text-green-700' : 'bg-amber-100 text-amber-700',
                  )}>{fill.filled}/{fill.total}</span>
                )}
              </div>
              <div className="truncate text-[11px] text-muted-foreground">{timeLabel}</div>
              {view === 'day' && r.can_see_amount && amount != null && (
                <div className="text-[11px] text-muted-foreground">{fmtKc(Number(amount))}</div>
              )}
            </button>
          );
        })}
      </div>
    );
  };

  return (
    <div className="overflow-x-auto">
      <div className="flex min-w-fit">
        {/* časová osa — odsazení = hlavička dne (h-8) + popisky drah (h-6) */}
        <div className="w-12 flex-shrink-0 pt-14">
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
              {/* popisek dráhy nad každým sloupcem — v týdnu i ve dni stejně */}
              <div className="flex border-b">
                {sheets.map((s, i) => (
                  <div
                    key={s.id}
                    className={cn(
                      'flex h-6 flex-1 items-center justify-center truncate border-l px-1',
                      'text-[11px] font-medium text-muted-foreground',
                      LANE_TINT[i % LANE_TINT.length],
                    )}
                    title={s.name}
                  >
                    {s.name}
                  </div>
                ))}
              </div>
              <div className="flex flex-1">
                {sheets.map((sheet, i) => renderSheetColumn(day, sheet, i))}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* legenda */}
      <div className="mt-3 flex flex-wrap items-center gap-4 px-2 text-xs text-muted-foreground">
        {TYPE_LEGEND.map(([key, label, dot]) => (
          <span key={key} className="flex items-center gap-1.5">
            <span className={cn('inline-block h-2.5 w-2.5 rounded-full', dot)} />
            {label}
          </span>
        ))}
        <span className="flex items-center gap-1.5">
          <Clock className="h-3 w-3 text-amber-600" /> čeká na potvrzení zástupcem
        </span>
        {view === 'week' && <span>Dráhy jsou vedle sebe v každém dni (pořadí podle názvu).</span>}
        {canDrag && <span>Rezervaci lze přetáhnout myší na jiný čas nebo den.</span>}
      </div>
    </div>
  );
}
