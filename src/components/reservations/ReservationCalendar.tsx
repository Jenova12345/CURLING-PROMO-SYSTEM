import { useMemo, useRef, useState } from 'react';
import { format, addDays, isSameDay, startOfWeek } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Clock, Link2 } from 'lucide-react';
import { cn } from '@/lib/utils';
import { fmtKc } from '@/lib/money';
import { barvaProRezervaci, jeKomercni, vzhledRezervace, BARVA_KOMERCE } from '@/lib/barvaKlubu';
import type { Sheet, CalendarReservation, ShiftFill } from '@/hooks/useReservations';

const PX_PER_MIN = 1;      // 1 minuta = 1 px
const DRAG_THRESHOLD = 6;  // menší posun bereme jako klik, ne tažení

// Blok se barví podle KLUBU, ne podle typu akce — tři kluby na tréninku
// vypadaly dřív úplně stejně a v týdnu nešlo poznat, kdo kde je. Barvu drží
// `subjects.barva`, kreslí ji `podkladKlubu` (viz lib/barvaKlubu.ts).
//
// Tohle je jen vzhled pro rezervace BEZ vlastní barvy: rezervace bez subjektu
// a kluby, kterým admin barvu nenastavil. Zůstávají neutrálně šedé, aby bylo
// na první pohled vidět, co je barevně rozlišený led a co ne.
//
// KOMERCE UŽ MEZI NĚ NEPATŘÍ (11. 9. 2026): má vlastní sytě červenou
// (`BARVA_KOMERCE`) a přebíjí i barvu klubu. Rozhoduje o tom `vzhledRezervace`,
// ne tahle funkce.
//
// Údržba je jediná výjimka: není to „akce klubu", ale stav ledu, a splynutí
// s komerční akcí by v provozu mátlo. Podklad má neutrální jako ostatní,
// rozlišuje ji jen oranžový pruh. (Stejné pravidlo platí pro měsíční chip
// v `Calendar.tsx` — kdyby se měnilo tady, musí se změnit i tam.)
function neutralniStyl(eventType: string | null | undefined): string {
  return eventType === 'maintenance'
    ? 'border-l-orange-500 bg-slate-50'
    : 'border-l-slate-400 bg-slate-50';
}

// Jemné odlišení drah — barva tady nesmí konkurovat barvám KLUBŮ,
// proto jen decentní podklad druhé dráhy + popisek nad každým sloupcem.
// (Hala má dvě dráhy; při případné třetí by se odstíny opakovaly — přidat další.)
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
  /** otevírací doba konkrétního dne (mřížka kreslí obálku týdne, validace jede po dnech) */
  hoursForDay?: (day: Date) => { open: number; close: number };
}

export function ReservationCalendar({
  view, currentDate, sheets, reservations, shiftFill = {},
  openHour, closeHour, canBook, onSlotClick, onReservationClick, onMove, onOutsideHours,
  hoursForDay,
}: Props) {
  /**
   * Kluby, které jsou v zobrazeném období vidět — pro legendu pod kalendářem.
   *
   * Odvozuje se z právě načtených rezervací, ne samostatným dotazem na
   * `subjects`: tu tabulka RLS běžnému členovi u cizích klubů nevydá vůbec,
   * takže by legenda buď byla prázdná, nebo by ji musel obsloužit nový, širší
   * přístup. Takhle platí jednoduché pravidlo — v legendě je přesně to,
   * co je v mřížce.
   */
  const legendaKlubu = useMemo(() => {
    const m = new Map<string, { id: string; nazev: string; barva: string }>();
    for (const r of reservations) {
      // Komerční akce se do klubové legendy nepočítá, i když jejím subjektem
      // klub je: v mřížce je červená, takže tečka v barvě klubu by slibovala
      // blok, který tam v té barvě není.
      if (jeKomercni(r.event_type)) continue;
      const barva = barvaProRezervaci(r);
      if (!barva || !r.subject_id) continue;
      if (!m.has(r.subject_id)) {
        m.set(r.subject_id, { id: r.subject_id, nazev: r.subject_name ?? 'Klub', barva });
      }
    }
    return [...m.values()].sort((a, b) => a.nazev.localeCompare(b.nazev, 'cs'));
  }, [reservations]);

  // Je v období aspoň jedna rezervace bez barvy klubu? Jen tehdy má smysl
  // v legendě vysvětlovat, co ta šedá znamená.
  //
  // Komerce se od 11. 9. 2026 NEPOČÍTÁ — má vlastní červenou a v legendě
  // vlastní řádek, takže by ji šedá položka popisovala nepravdivě.
  //
  // Popisek se ZÁMĚRNĚ nejmenuje po typech akcí a nic nevyjmenovává. Do šedé
  // spadají tři různé věci — údržba, rezervace bez subjektu a klub, kterému
  // admin barvu nenastavil (nebo ji vybral světlejší než MAX_JAS, takže by
  // nebyla vidět) — a každý výčet, který se sem zkusil vejít, jeden z nich
  // vynechal nebo popsal špatně. „Bez barvy klubu" je pravdivé o všech třech.
  // (Dřív tu stálo „(komerce, údržba)", pak „(údržba, rezervace bez klubu)" —
  // to první po zčervenání komerce lhalo, to druhé vydávalo klub bez barvy za
  // rezervaci bez klubu. Nález brány code review, 11. 9. 2026.)
  const maNeutralni = useMemo(
    () => reservations.some((r) => !jeKomercni(r.event_type) && !barvaProRezervaci(r)),
    [reservations],
  );

  // Je v období komerční akce? Legenda ukazuje jen to, co je v mřížce vidět —
  // stejné pravidlo jako u klubů výš.
  const maKomercni = useMemo(
    () => reservations.some((r) => jeKomercni(r.event_type)),
    [reservations],
  );

  /**
   * Akce, které jedou přes VÍC DRAH — kolik drah a kolik stojí dohromady.
   *
   * Kalendář má sloupec na dráhu, takže komerční akce na dvou drahách se
   * nutně kreslí jako dva bloky. To je v pořádku, ale bez označení to vypadá
   * jako dvě samostatné akce po 20 000 místo jedné za 40 000.
   *
   * Součet se počítá jen tehdy, když je částka vidět u VŠECH drah — částečný
   * součet by byl horší než žádný.
   */
  const akce = useMemo(() => {
    const m = new Map<string, {
      drah: number; celkem: number | null;
      lanes: number[]; start: string; end: string; stejnyCas: boolean;
    }>();
    const poradiDrahy = new Map(sheets.map((s, i) => [s.id, i]));

    for (const r of reservations) {
      if (!r.event_id) continue;
      const cur = m.get(r.event_id);
      const castka = Number(r.corrected_amount ?? r.amount);
      const lane = poradiDrahy.get(r.sheet_id!) ?? -1;

      if (!cur) {
        m.set(r.event_id, {
          drah: 1,
          celkem: r.can_see_amount && Number.isFinite(castka) ? castka : null,
          lanes: [lane], start: r.start_at!, end: r.end_at!, stejnyCas: true,
        });
        continue;
      }
      cur.drah += 1;
      cur.lanes.push(lane);
      cur.celkem = cur.celkem == null || !r.can_see_amount || !Number.isFinite(castka)
        ? null : cur.celkem + castka;
      // SPOJUJE SE JEN PŘI SHODNÉM ČASE. Kdyby jedna dráha běžela jinak,
      // roztažený blok by lhal o tom, kdy se hraje — pak radši dva bloky.
      if (r.start_at !== cur.start || r.end_at !== cur.end) cur.stejnyCas = false;
    }
    for (const v of m.values()) v.lanes.sort((a, b) => a - b);
    return m;
  }, [reservations, sheets]);

  /**
   * Má se akce vykreslit jako JEDEN blok roztažený přes dráhy?
   *
   * Platí pro VŠECHNY typy akcí (komerční, trénink, turnaj i údržba) — akce na
   * dvou drahách je jedna akce, ne dvě. Podmínky jsou tři:
   *   • víc než jedna dráha,
   *   • shodný čas na všech (jinak by blok lhal o tom, kdy se hraje),
   *   • dráhy jdou po sobě — roztáhnout blok přes mezeru nejde, sloupce mezi
   *     nimi patří jiné dráze.
   */
  const spojenaAkce = (eventId?: string | null) => {
    if (!eventId) return null;
    const a = akce.get(eventId);
    if (!a || a.drah < 2 || !a.stejnyCas) return null;
    const souvisle = a.lanes.every((l, i) => i === 0 || l === a.lanes[i - 1] + 1);
    if (!souvisle || a.lanes[0] < 0) return null;
    return a;
  };

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

    const shifted = new Date(origStart.getTime() + hourShift * 3_600_000);  // hodina z tahu

    // Cílový sloupec (den + dráha) podle místa, kde uživatel pustil myš.
    // Tažený blok se drží pod kurzorem, takže by ho elementFromPoint našel místo
    // sloupce pod ním — na okamžik ho proto vyřadíme z hit-testu.
    const dragged = e.currentTarget as HTMLElement;
    const prevPointerEvents = dragged.style.pointerEvents;
    dragged.style.pointerEvents = 'none';
    const target = (document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null)
      ?.closest('[data-lane]') as HTMLElement | null;
    dragged.style.pointerEvents = prevPointerEvents;

    // Puštěno mimo mřížku (vedle kalendáře, na legendu, mimo okno) → neděláme nic.
    // Jinak by se z toho stal posun o hodiny podle svislého tahu, o který nikdo nestál.
    if (!target?.dataset.day || !target.dataset.sheetId) return;

    const [y, m, dd] = target.dataset.day.split('-').map(Number);
    const start = new Date(y, m - 1, dd, shifted.getHours(), 0, 0, 0);   // den z cílového sloupce
    const sheetId = target.dataset.sheetId;
    const end = new Date(start.getTime() + duration);

    if (start.getTime() === origStart.getTime() && sheetId === d.res.sheet_id) return;

    // Otevírací dobu ověříme hned — ať se uživatel neptá na termín, který server odmítne.
    // Počítáme v minutách a podle CÍLOVÉHO dne (doba jde nastavit pro každý den zvlášť).
    const { open, close } = hoursForDay?.(start) ?? { open: openHour, close: closeHour };
    const startMin = start.getHours() * 60 + start.getMinutes();
    const endMin = end.getHours() * 60 + end.getMinutes();
    const endsNextDay = end.getDate() !== start.getDate();
    if (endsNextDay || startMin < open * 60 || endMin > close * 60) {
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
          // POZOR NA ROZDÍL PROTI `komercni` NÍŽ: tahle podmínka je širší
          // (bere i nábor) a je o BRIGÁDNÍCÍCH, ne o barvě. Dokud se jmenovala
          // `isCommercial`, stály tu pět řádků od sebe dvě skoro stejně znějící
          // proměnné s různým významem. (Nález brány code review, 11. 9. 2026.)
          const muzeMitBrigadniky = r.event_type === 'commercial' || r.event_type === 'recruitment';
          const label = r.event_title ?? r.subject_name ?? 'Rezervace';
          // Barvu i to, jestli na ní má být bílý text, rozhoduje `vzhledRezervace`
          // — táž funkce jako u měsíčních chipů, ať se ty dva pohledy nerozejdou.
          const vzhled = vzhledRezervace(r);
          const komercni = vzhled.bilyText;
          const dragging = preview?.id === r.id;
          const skupina = r.event_id ? akce.get(r.event_id) : undefined;
          const vicDrah = (skupina?.drah ?? 1) > 1;

          // JEDNA AKCE = JEDEN BLOK. Roztažený blok se kreslí jen v PRVNÍ
          // dráze skupiny; v ostatních se rezervace přeskočí, jinak by pod ním
          // zůstaly ležet duplicitní boxy.
          const spojena = spojenaAkce(r.event_id);
          if (spojena && laneIndex !== spojena.lanes[0]) return null;
          const roztazeniDrah = spojena ? spojena.drah : 1;

          return (
            <button
              key={r.id}
              type="button"
              onClick={(e) => e.stopPropagation()}
              onPointerDown={(e) => {
                e.stopPropagation();
                if (roztazeniDrah === 1) onPointerDown(e, r);
              }}
              onPointerMove={onPointerMove}
              onPointerUp={(e) => { e.stopPropagation(); onPointerUp(e, r); }}
              onPointerCancel={() => { dragRef.current = null; setPreview(null); }}
              // pojistka: když se myš pustí mimo okno a pointerup nedorazí,
              // ať náhled nezůstane viset posunutý
              onLostPointerCapture={() => { dragRef.current = null; setPreview(null); }}
              className={cn(
                'absolute left-1 right-1 rounded-md border border-l-4 p-1.5 text-left shadow-sm',
                'hover:ring-2 hover:ring-ring overflow-hidden',
                // Akce přes víc drah dostane výraznější rám, aby bylo vidět,
                // že ty bloky patří k sobě a nejsou to dvě samostatné akce.
                // Na sytě červené má `ring-primary/40` kontrast 1,88 : 1, tedy
                // je prakticky neviditelný — právě u komerce přes dvě dráhy,
                // kde ten rám nese nejvíc informace. Bílý rám tam dá 3,6 : 1,
                // nad hranicí 3 : 1, kterou WCAG chce po grafických prvcích
                // rozhraní. (Nález brány code review, 11. 9. 2026.)
                vicDrah && (komercni ? 'ring-1 ring-inset ring-white/70' : 'ring-1 ring-inset ring-primary/40'),
                // ROZTAŽENÝ BLOK MUSÍ BÝT NAD PODKLADEM DALŠÍ DRÁHY.
                // Sloupce drah jsou sourozenci a druhý má `bg-muted/40`;
                // protože je v DOM později a blok neměl žádné `z`, kreslil se
                // ten průsvitný šedý podklad PŘES pravou polovinu bloku.
                // U bledě modrého klubu to nebylo poznat, u syté červené ano:
                // #c1121f pod tím závojem vyjde jako rgb(212 109 118) a bílý
                // text na něm spadne ze 6,2 : 1 na 3,4 : 1, tedy pod WCAG AA.
                // (Změřeno v prohlížeči 11. 9. 2026 přes elementFromPoint.)
                roztazeniDrah > 1 && 'z-10',
                neutralniStyl(r.event_type),
                // Na sytě červené je výchozí tmavý text nečitelný. Bílá se
                // dává TŘÍDOU, ne inline: potomci uvnitř mají vlastní
                // `text-*` třídy a ty by inline barvu na rodiči stejně přebily,
                // takže se přepínají níž jedna po druhé.
                komercni && 'text-white',
                !r.approved_at && 'border-dashed',
                // Roztažený blok se netáhne: tah míří do jednoho sloupce
                // a akce jich zabírá víc. Přesouvá se přes Upravit.
                canDrag && r.can_manage && roztazeniDrah === 1 && 'cursor-grab touch-none',
                dragging && 'z-20 cursor-grabbing opacity-80 ring-2 ring-primary',
              )}
              style={{
                top, height,
                // Barva z `vzhledRezervace` vyhrává nad neutrálním základem
                // z neutralniStyl(). U KLUBU je podklad barva zesvětlená na
                // bílé, aby na něm zůstal čitelný tmavý text i u tmavě modrého
                // klubu, a plná barva jde jen do levého pruhu, kde text neleží.
                // U KOMERCE je podklad plná červená a text se přepíná na bílý.
                ...(vzhled.podklad
                  ? { backgroundColor: vzhled.podklad, borderLeftColor: vzhled.pruh }
                  : null),
                // Sloupce drah jsou stejně široké `flex-1` sourozenci, takže
                // roztažení přes N drah je N × šířka sloupce (minus okraje,
                // které blok drží uvnitř `left-1 right-1`).
                ...(roztazeniDrah > 1
                  ? { width: `calc(${roztazeniDrah} * 100% - 0.5rem)`, right: 'auto' }
                  : null),
                transform: dragging ? `translate(${preview!.dx}px, ${preview!.dy}px)` : undefined,
              }}
              title={
                `${label} · ${timeLabel}`
                + (vicDrah ? ` · jedna akce přes ${skupina!.drah} dráhy` : '')
                + (vicDrah && skupina?.celkem != null ? ` · celkem ${fmtKc(skupina.celkem)}` : '')
                + (r.approved_at ? '' : ' · čeká na potvrzení správcem klubu')
              }
            >
              <div className="flex items-center gap-1">
                {/* název vidí každý přihlášený — maskuje se jen částka */}
                {vicDrah && (
                  <Link2
                    className={cn('h-3 w-3 shrink-0', komercni ? 'text-white' : 'text-primary')}
                    aria-label={`Jedna akce přes ${skupina!.drah} dráhy`}
                  />
                )}
                <span className="truncate text-xs font-medium">{label}</span>
                {/* jantarová na červené zaniká — světlejší odstín drží
                    význam („čeká") i čitelnost */}
                {!r.approved_at && (
                  <Clock className={cn('h-3 w-3 shrink-0', komercni ? 'text-amber-200' : 'text-amber-600')} />
                )}
                {muzeMitBrigadniky && fill && (
                  <span className={cn(
                    'ml-auto shrink-0 rounded px-1 text-[10px] font-semibold',
                    fill.filled >= fill.total ? 'bg-green-100 text-green-700' : 'bg-amber-100 text-amber-700',
                  )}>{fill.filled}/{fill.total}</span>
                )}
              </div>
              <div className={cn('truncate text-[11px]', komercni ? 'text-white/85' : 'text-muted-foreground')}>
                {timeLabel}
              </div>
              {view === 'day' && r.can_see_amount && amount != null && (
                <div className={cn('text-[11px]', komercni ? 'text-white/85' : 'text-muted-foreground')}>
                  {vicDrah && skupina?.celkem != null ? (
                    // U akce přes víc drah je hlavní číslo CELEK; částka téhle
                    // dráhy je jen podíl a sama o sobě mate. U SPOJENÉHO bloku
                    // se podíl neuvádí vůbec — blok už zastupuje celou akci.
                    roztazeniDrah > 1
                      ? <>{fmtKc(skupina.celkem)} · {skupina.drah} dráhy</>
                      : <>celkem {fmtKc(skupina.celkem)} <span className="opacity-70">
                          (tato dráha {fmtKc(Number(amount))})</span></>
                  ) : fmtKc(Number(amount))}
                </div>
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
                      'flex h-6 min-w-0 flex-1 items-center justify-center border-l px-1',
                      'text-[11px] font-medium text-muted-foreground',
                      LANE_TINT[i % LANE_TINT.length],
                    )}
                    title={s.name}
                  >
                    <span className="truncate">{s.name}</span>
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

      {/* legenda — kluby se berou z právě zobrazených rezervací, ne zvlášť
          dotazem: `reservations_calendar` barvu i jméno vydává rovnou, takže
          legenda nemůže ukázat klub, který uživatel v mřížce stejně nevidí. */}
      <div className="mt-3 flex flex-wrap items-center gap-4 px-2 text-xs text-muted-foreground">
        {legendaKlubu.map((k) => (
          <span key={k.id} className="flex items-center gap-1.5">
            <span
              className="inline-block h-2.5 w-2.5 rounded-full border"
              style={{ backgroundColor: k.barva }}
            />
            {k.nazev}
          </span>
        ))}
        {maKomercni && (
          <span className="flex items-center gap-1.5">
            <span
              className="inline-block h-2.5 w-2.5 rounded-full border"
              style={{ backgroundColor: BARVA_KOMERCE.podklad }}
            />
            Komerční akce
          </span>
        )}
        {maNeutralni && (
          <span className="flex items-center gap-1.5">
            <span className="inline-block h-2.5 w-2.5 rounded-full border bg-slate-300" />
            Bez barvy klubu
          </span>
        )}
        <span className="flex items-center gap-1.5">
          <Clock className="h-3 w-3 text-amber-600" /> čeká na potvrzení správcem klubu
        </span>
        {view === 'week' && <span>Dráhy jsou vedle sebe v každém dni (pořadí podle názvu).</span>}
        {canDrag && <span>Rezervaci lze přetáhnout myší na jiný čas nebo den.</span>}
      </div>
    </div>
  );
}
