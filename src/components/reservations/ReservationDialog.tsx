import { useEffect, useMemo, useState } from 'react';
import { format } from 'date-fns';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter,
} from '@/components/ui/dialog';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Checkbox } from '@/components/ui/checkbox';
import { Switch } from '@/components/ui/switch';
import { Minus, Plus } from 'lucide-react';
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/components/ui/use-toast';
import { sanitizeText, VALIDATION_LIMITS } from '@/lib/validation';
import { hoursForDay } from '@/lib/openingHours';
import { parseSazba } from '@/lib/money';
import type {
  Sheet, Subject, Settings, CalendarReservation, BookingKind, Conflict,
  BookingInput, SeriesInput, Membership,
} from '@/hooks/useReservations';

const STAFF_ROLES = [
  { key: 'instructor', label: 'Instruktor' },
  { key: 'bar_staff', label: 'Obsluha baru' },
  { key: 'manager', label: 'Provozní hospoda' },
];

const KIND_LABELS: Record<BookingKind, string> = {
  training: 'Trénink',
  tournament: 'Turnaj',
  commercial: 'Komerční akce',
  maintenance: 'Údržba ledu',
};

const WEEKDAYS: [number, string][] = [
  [1, 'Po'], [2, 'Út'], [3, 'St'], [4, 'Čt'], [5, 'Pá'], [6, 'So'], [7, 'Ne'],
];

export interface ReservationApi {
  createBooking: (input: BookingInput) => Promise<unknown>;
  createSeries: (input: SeriesInput) => Promise<{ created: number; skipped: { date: string; reason: string }[] }>;
  updateBooking: (args: { id: string; title?: string; note?: string | null; rate_per_hour?: number | null }) => Promise<unknown>;
  moveBooking: (args: { id: string; start_at: string; end_at: string; sheet_id?: string }) => Promise<unknown>;
  checkConflicts: (args: { sheet_ids: string[]; start_at: string; end_at: string; kind: BookingKind; ignore_event?: string }) => Promise<Conflict[]>;
  aresLookup: (ico: string) => Promise<{ name: string; address: string; dic: string }>;
  findSubjectByIco: (ico: string) => Promise<Subject | null>;
  createSubject: (s: { name: string; ico?: string; dic?: string; address?: string }) => Promise<Subject>;
  isCreating: boolean;
  isUpdating: boolean;
}

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  isAdmin: boolean;
  sheets: Sheet[];
  subjects: Subject[];
  memberships: Membership[];
  settings: Settings | null;
  defaultSheetId?: string;
  defaultStart?: Date;
  editing?: CalendarReservation | null;
  /** kolik drah drží editovaná akce (u dvou nejde měnit dráha) */
  editingLanes?: number;
  api: ReservationApi;
}

const hh = (h: number) => `${String(h).padStart(2, '0')}:00`;

function kindOf(r: CalendarReservation): BookingKind {
  const t = r.event_type;
  if (t === 'commercial' || t === 'recruitment') return 'commercial';
  if (t === 'tournament') return 'tournament';
  if (t === 'maintenance') return 'maintenance';
  return 'training';
}

export function ReservationDialog({
  open, onOpenChange, isAdmin, sheets, subjects, memberships, settings,
  defaultSheetId, defaultStart, editing, editingLanes = 1, api,
}: Props) {
  const { toast } = useToast();
  const isEdit = !!editing;

  const clubs = useMemo(() => subjects.filter((s) => s.type === 'club'), [subjects]);
  const commercials = useMemo(() => subjects.filter((s) => s.type === 'commercial'), [subjects]);

  // Kluby, za které smím rezervovat (člen i zástupce). Admin může za kterýkoli.
  const myClubs = useMemo(
    () => (isAdmin ? clubs : clubs.filter((c) => memberships.some((m) => m.subject_id === c.id))),
    [clubs, memberships, isAdmin],
  );

  const kinds: BookingKind[] = isAdmin
    ? ['training', 'tournament', 'commercial', 'maintenance']
    : ['training', 'tournament'];

  const [kind, setKind] = useState<BookingKind>('training');
  const [subjectId, setSubjectId] = useState('');
  const [sheetIds, setSheetIds] = useState<string[]>([]);
  const [date, setDate] = useState('');
  const [startHour, setStartHour] = useState(17);
  const [endHour, setEndHour] = useState(19);
  const [note, setNote] = useState('');
  const [title, setTitle] = useState('');
  const [titleTouched, setTitleTouched] = useState(false);
  const [roleCounts, setRoleCounts] = useState<Record<string, number>>({ instructor: 1, bar_staff: 0, manager: 0 });
  const [instructorsTouched, setInstructorsTouched] = useState(false);
  const [rate, setRate] = useState('');

  // opakování
  const [repeat, setRepeat] = useState(false);
  const [weekdays, setWeekdays] = useState<number[]>([]);
  const [until, setUntil] = useState('');

  // ARES / nová firma
  const [newFirm, setNewFirm] = useState(false);
  const [ico, setIco] = useState('');
  const [firmName, setFirmName] = useState('');
  const [firmAddress, setFirmAddress] = useState('');
  const [firmDic, setFirmDic] = useState('');
  const [aresLoading, setAresLoading] = useState(false);

  // potvrzení vědomého přebití
  const [conflicts, setConflicts] = useState<Conflict[] | null>(null);

  const { open: openHour, close: closeHour } = hoursForDay(settings?.opening_hours, date);

  const defaultRateFor = (k: BookingKind, sid: string): string => {
    if (k === 'maintenance') return '';
    const subj = subjects.find((s) => s.id === sid);
    if (subj?.default_rate != null) return String(subj.default_rate);
    const s = settings;
    const r =
      k === 'commercial' ? s?.commercial_default_rate
      : k === 'tournament' ? (s?.tournament_rate ?? s?.club_default_rate)
      : (s?.training_rate ?? s?.club_default_rate);
    return r != null ? String(r) : '';
  };

  useEffect(() => {
    if (!open) return;
    if (editing) {
      const start = new Date(editing.start_at!);
      const end = new Date(editing.end_at!);
      setKind(kindOf(editing));
      setSubjectId(editing.subject_id ?? '');
      setSheetIds(editing.sheet_id ? [editing.sheet_id] : []);
      setDate(format(start, 'yyyy-MM-dd'));
      setStartHour(start.getHours());
      // Konec o půlnoci (starší data z doby před validací) posuneme na 23:00 —
      // „24:00" by se do formuláře ani do data nedalo přeložit.
      setEndHour(end.getHours() === 0 ? 23 : end.getHours());
      setNote(editing.note ?? '');
      setTitle(editing.event_title ?? '');
      setTitleTouched(true);
      setRate(editing.rate_per_hour != null ? String(editing.rate_per_hour) : '');
      setRepeat(false);
    } else {
      const start = defaultStart ?? new Date();
      const sh = Math.max(openHour, Math.min(start.getHours(), closeHour - 1));
      const firstClub = myClubs.length === 1 ? myClubs[0].id : '';
      setKind('training');
      setSubjectId(firstClub);
      setSheetIds(defaultSheetId ? [defaultSheetId] : sheets[0] ? [sheets[0].id] : []);
      setDate(format(start, 'yyyy-MM-dd'));
      setStartHour(sh);
      setEndHour(Math.min(sh + 2, closeHour));
      setNote(''); setTitle(''); setTitleTouched(false);
      setRoleCounts({ instructor: 1, bar_staff: 0, manager: 0 });
      setInstructorsTouched(false);
      setRate(defaultRateFor('training', firstClub));
      setRepeat(false); setWeekdays([]); setUntil('');
    }
    setNewFirm(false); setIco(''); setFirmName(''); setFirmAddress(''); setFirmDic('');
    setConflicts(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, editing, defaultStart, defaultSheetId]);

  // přepnutí typu (jen nová rezervace): předvyplň subjekt + sazbu
  useEffect(() => {
    if (isEdit || !open) return;
    const sid =
      kind === 'commercial' ? (commercials.length === 1 ? commercials[0].id : '')
      : kind === 'maintenance' ? ''
      : (myClubs.length === 1 ? myClubs[0].id : '');
    setSubjectId(sid);
    setRate(defaultRateFor(kind, sid));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [kind]);

  // změna subjektu → sazba + automatický název u komerční akce („Teambuilding <firma>")
  useEffect(() => {
    if (isEdit || !open) return;
    setRate(defaultRateFor(kind, subjectId));
    if (kind === 'commercial' && subjectId && !titleTouched) {
      const firm = commercials.find((s) => s.id === subjectId);
      if (firm) setTitle(`Teambuilding ${firm.name}`);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [subjectId, kind]);

  // počet instruktorů se předvyplní podle počtu drah (dokud do toho uživatel nesáhne)
  useEffect(() => {
    if (isEdit || !open || kind !== 'commercial' || instructorsTouched) return;
    setRoleCounts((p) => ({ ...p, instructor: Math.max(1, sheetIds.length) }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sheetIds, kind]);

  // čas musí zůstat uvnitř otevírací doby vybraného dne
  useEffect(() => {
    if (!open) return;
    setStartHour((h) => Math.min(Math.max(h, openHour), closeHour - 1));
    setEndHour((h) => Math.min(Math.max(h, Math.max(startHour, openHour) + 1), closeHour));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [date, openHour, closeHour]);

  const toggleSheet = (id: string) =>
    setSheetIds((prev) => (prev.includes(id) ? prev.filter((s) => s !== id) : [...prev, id]));

  const toggleWeekday = (d: number) =>
    setWeekdays((prev) => (prev.includes(d) ? prev.filter((x) => x !== d) : [...prev, d].sort()));

  const adjust = (role: string, delta: number) => {
    if (role === 'instructor') setInstructorsTouched(true);
    setRoleCounts((p) => ({
      ...p,
      [role]: Math.max(0, Math.min(VALIDATION_LIMITS.STAFF_COUNT_MAX, (p[role] ?? 0) + delta)),
    }));
  };

  // Jedna politika sazeb pro celou appku (viz src/lib/money.ts) — prázdné pole
  // znamená „z ceníku", ne chybu.
  const sazba = parseSazba(rate);
  const rateNum = sazba.hodnota != null ? sazba.hodnota : undefined;
  const busy = api.isCreating || api.isUpdating || aresLoading;
  const needsSubject = kind !== 'maintenance';
  const startOptions = Array.from({ length: Math.max(closeHour - openHour, 1) }, (_, i) => openHour + i);
  const endOptions = Array.from({ length: Math.max(closeHour - startHour, 1) }, (_, i) => startHour + 1 + i);
  const subjectOptions = kind === 'commercial' ? commercials : myClubs;

  const toIso = (h: number) => new Date(`${date}T${hh(h)}`).toISOString();

  // ---- ARES ------------------------------------------------------------------
  const handleAres = async () => {
    const clean = ico.trim();
    if (!/^\d{8}$/.test(clean)) {
      toast({ title: 'Neplatné IČO', description: 'Zadejte 8 číslic.', variant: 'destructive' });
      return;
    }
    setAresLoading(true);
    try {
      // Nejdřív ověříme, jestli firmu už nemáme — ať nevznikají duplicity.
      const existing = await api.findSubjectByIco(clean);
      if (existing) {
        setNewFirm(false);
        setSubjectId(existing.id);
        setRate(defaultRateFor('commercial', existing.id));
        if (!titleTouched) setTitle(`Teambuilding ${existing.name}`);
        toast({ title: 'Firma už v systému je', description: `Použil jsem existující záznam: ${existing.name}` });
        return;
      }
      const d = await api.aresLookup(clean);
      setFirmName(d.name); setFirmAddress(d.address); setFirmDic(d.dic);
      toast({ title: 'Načteno z ARESu', description: d.name });
    } catch (e) {
      toast({ title: 'ARES', description: e instanceof Error ? e.message : 'Načtení selhalo.', variant: 'destructive' });
    } finally {
      setAresLoading(false);
    }
  };

  const handleCreateFirm = async () => {
    if (!firmName.trim()) { toast({ title: 'Vyplňte název firmy', variant: 'destructive' }); return; }
    try {
      const subj = await api.createSubject({
        name: sanitizeText(firmName), ico: ico.trim() || undefined,
        dic: firmDic || undefined, address: firmAddress || undefined,
      });
      setNewFirm(false); setSubjectId(subj.id); setRate(defaultRateFor('commercial', subj.id));
      if (!titleTouched) setTitle(`Teambuilding ${subj.name}`);
      toast({ title: 'Firma založena', description: subj.name });
    } catch (e) {
      toast({ title: 'Chyba', description: e instanceof Error ? e.message : 'Nepodařilo se založit firmu.', variant: 'destructive' });
    }
  };

  // ---- odeslání --------------------------------------------------------------
  const validate = (): string | null => {
    if (!date) return 'Vyberte datum.';
    if (!sheetIds.length) return 'Vyberte aspoň jednu dráhu.';
    if (endHour <= startHour) return 'Konec musí být po začátku.';
    if (startHour < openHour || endHour > closeHour) return `Mimo otevírací dobu (${hh(openHour)}–${hh(closeHour)}).`;
    if (!title.trim()) return 'Vyplňte název akce.';
    if (needsSubject && !subjectId) return kind === 'commercial' ? 'Vyberte firmu.' : 'Vyberte klub.';
    if (kind === 'commercial' && (roleCounts.instructor ?? 0) < 1) return 'Komerční akce potřebuje aspoň jednoho instruktora.';
    if (isAdmin && kind !== 'maintenance' && sazba.chyba) {
      return `${sazba.chyba} Prázdné pole znamená sazbu z ceníku.`;
    }
    if (repeat) {
      if (!weekdays.length) return 'Vyberte dny v týdnu, kdy se má opakovat.';
      if (!until) return 'Vyplňte, do kdy se má opakovat.';
      if (new Date(until) < new Date(date)) return 'Datum konce opakování musí být po prvním termínu.';
    }
    return null;
  };

  const buildInput = (): BookingInput => ({
    sheet_ids: sheetIds,
    kind,
    title: sanitizeText(title),
    start_at: toIso(startHour),
    end_at: toIso(endHour),
    subject_id: needsSubject ? subjectId : null,
    note: note ? sanitizeText(note) : undefined,
    role_reqs: kind === 'commercial'
      ? Object.fromEntries(Object.entries(roleCounts).filter(([, c]) => c > 0))
      : {},
    rate_per_hour: isAdmin && rateNum !== undefined ? rateNum : null,
  });

  const submitBooking = async (override: boolean) => {
    try {
      if (repeat) {
        const res = await api.createSeries({ ...buildInput(), weekdays, until });
        const skipped = res.skipped?.length ?? 0;
        toast({
          title: `Založeno ${res.created} termínů`,
          description: skipped
            ? `${skipped} termínů se přeskočilo (kolize nebo mimo otevírací dobu): ${res.skipped.map((s) => s.date).join(', ')}`
            : 'Celá série je v kalendáři.',
        });
      } else {
        await api.createBooking({ ...buildInput(), override });
        toast({ title: override ? 'Rezervace založena, kolidující akce byly zrušeny' : 'Rezervace vytvořena' });
      }
      setConflicts(null);
      onOpenChange(false);
    } catch (error) {
      setConflicts(null);
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Operace selhala.', variant: 'destructive' });
    }
  };

  const handleSubmit = async () => {
    const problem = validate();
    if (problem) { toast({ title: 'Zkontrolujte formulář', description: problem, variant: 'destructive' }); return; }

    try {
      // EDITACE — název/poznámka/sazba + případný přesun času nebo dráhy
      if (isEdit && editing) {
        // Porovnáváme okamžiky, ne řetězce — z databáze chodí jiný formát než z toISOString().
        const sameMoment = (a: string, b: string) => new Date(a).getTime() === new Date(b).getTime();
        const movedTime =
          !sameMoment(toIso(startHour), editing.start_at!) || !sameMoment(toIso(endHour), editing.end_at!);
        const movedSheet = sheetIds[0] !== editing.sheet_id;
        if (movedTime || (movedSheet && editingLanes === 1)) {
          await api.moveBooking({
            id: editing.id!,
            start_at: toIso(startHour),
            end_at: toIso(endHour),
            sheet_id: editingLanes > 1 ? undefined : sheetIds[0],
          });
        }
        await api.updateBooking({
          id: editing.id!,
          title: sanitizeText(title),
          // prázdný řetězec = „smaž poznámku" (null by znamenalo „neměň")
          note: note ? sanitizeText(note) : '',
          rate_per_hour: isAdmin && rateNum !== undefined ? rateNum : undefined,
        });
        toast({ title: 'Rezervace upravena' });
        onOpenChange(false);
        return;
      }

      // NOVÁ — nejdřív se serveru zeptáme, co by se přebilo
      const found = await api.checkConflicts({
        sheet_ids: sheetIds, start_at: toIso(startHour), end_at: toIso(endHour), kind,
      });
      if (found.length && !repeat) {
        if (!isAdmin || found.some((c) => !c.can_override)) {
          const c = found[0];
          toast({
            title: 'Termín je obsazený',
            description: `${c.sheet_name}: ${c.event_title ?? c.subject_name ?? 'rezervace'} ${format(new Date(c.start_at), 'HH:mm')}–${format(new Date(c.end_at), 'HH:mm')}. Vyberte jiný čas nebo dráhu.`,
            variant: 'destructive',
          });
          return;
        }
        setConflicts(found);   // admin → nabídneme vědomé přebití
        return;
      }
      await submitBooking(false);
    } catch (error) {
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Operace selhala.', variant: 'destructive' });
    }
  };

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="max-w-md max-h-[90vh] flex flex-col">
          <DialogHeader className="flex-shrink-0">
            <DialogTitle>{isEdit ? 'Upravit rezervaci' : 'Nová rezervace'}</DialogTitle>
            <DialogDescription>
              {isEdit
                ? 'Upravte údaje rezervace. Čas jde posunout i tažením v kalendáři.'
                : 'Rezervuje se na celé hodiny. U komerční akce se rovnou založí i směny.'}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 overflow-y-auto flex-1 pr-2">
            {/* typ akce */}
            <div className="space-y-2">
              <Label>Typ akce</Label>
              <div className="flex flex-wrap gap-1">
                {kinds.map((k) => (
                  <Button
                    key={k} type="button" size="sm"
                    variant={kind === k ? 'default' : 'outline'}
                    disabled={isEdit}
                    onClick={() => setKind(k)}
                  >
                    {KIND_LABELS[k]}
                  </Button>
                ))}
              </div>
            </div>

            {/* subjekt */}
            {needsSubject && !newFirm && (
              <div className="space-y-2">
                <Label>{kind === 'commercial' ? 'Firma (zákazník)' : 'Klub'}</Label>
                <Select value={subjectId} onValueChange={setSubjectId} disabled={isEdit}>
                  <SelectTrigger><SelectValue placeholder={kind === 'commercial' ? 'Vyberte firmu' : 'Vyberte klub'} /></SelectTrigger>
                  <SelectContent>
                    {subjectOptions.map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
                  </SelectContent>
                </Select>
                {kind === 'commercial' && isAdmin && !isEdit && (
                  <Button type="button" variant="link" size="sm" className="h-auto p-0" onClick={() => setNewFirm(true)}>
                    + Přidat novou firmu (ARES)
                  </Button>
                )}
              </div>
            )}

            {/* nová firma přes ARES */}
            {kind === 'commercial' && newFirm && !isEdit && (
              <div className="space-y-2 rounded-md border p-3">
                <Label>Nová firma podle IČO</Label>
                <div className="flex gap-2">
                  <Input value={ico} onChange={(e) => setIco(e.target.value)} placeholder="IČO (8 číslic)" inputMode="numeric" />
                  <Button type="button" variant="outline" onClick={handleAres} disabled={aresLoading}>
                    {aresLoading ? '…' : 'Načíst z ARESu'}
                  </Button>
                </div>
                <Input value={firmName} onChange={(e) => setFirmName(e.target.value)} placeholder="Název firmy" />
                <Input value={firmAddress} onChange={(e) => setFirmAddress(e.target.value)} placeholder="Adresa" />
                <Input value={firmDic} onChange={(e) => setFirmDic(e.target.value)} placeholder="DIČ" />
                <div className="flex gap-2">
                  <Button type="button" size="sm" onClick={handleCreateFirm}>Založit a použít</Button>
                  <Button type="button" size="sm" variant="ghost" onClick={() => setNewFirm(false)}>Zpět na výběr</Button>
                </div>
              </div>
            )}

            {/* název akce */}
            <div className="space-y-2">
              <Label htmlFor="res-title">Název akce</Label>
              <Input
                id="res-title" value={title} maxLength={VALIDATION_LIMITS.TITLE_MAX}
                placeholder={kind === 'training' ? 'Např. Trénink A-tým' : kind === 'tournament' ? 'Např. Podzimní turnaj' : 'Např. Teambuilding'}
                onChange={(e) => { setTitle(e.target.value); setTitleTouched(true); }}
              />
            </div>

            {/* dráhy */}
            <div className="space-y-2">
              <Label>Dráhy</Label>
              {isEdit && editingLanes > 1 ? (
                <p className="text-xs text-muted-foreground">
                  Akce běží na obou drahách — posunout jde jen její čas, dráhy ne.
                </p>
              ) : (
                <div className="flex flex-wrap gap-4">
                  {sheets.map((s) => (
                    <label key={s.id} className="flex items-center gap-2 text-sm">
                      <Checkbox
                        checked={sheetIds.includes(s.id)}
                        onCheckedChange={() => (isEdit ? setSheetIds([s.id]) : toggleSheet(s.id))}
                      />
                      {s.name}
                    </label>
                  ))}
                </div>
              )}
              {!isEdit && sheetIds.length > 1 && (
                <p className="text-xs text-muted-foreground">Rezervace vznikne na obou drahách (stejný čas i akce).</p>
              )}
            </div>

            {/* datum a čas — roletky po celých hodinách */}
            <div className="space-y-2">
              <Label htmlFor="res-date">Datum</Label>
              <Input id="res-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label>Od</Label>
                <Select value={String(startHour)} onValueChange={(v) => {
                  const h = Number(v);
                  setStartHour(h);
                  if (endHour <= h) setEndHour(Math.min(h + 1, closeHour));
                }}>
                  <SelectTrigger className="h-11"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    {startOptions.map((h) => <SelectItem key={h} value={String(h)}>{hh(h)}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label>Do</Label>
                <Select value={String(endHour)} onValueChange={(v) => setEndHour(Number(v))}>
                  <SelectTrigger className="h-11"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    {endOptions.map((h) => <SelectItem key={h} value={String(h)}>{hh(h)}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              Led je v tento den k dispozici {hh(openHour)}–{hh(closeHour)}. Rezervuje se po celých hodinách.
            </p>

            {/* opakování */}
            {!isEdit && (
              <div className="space-y-2 rounded-md border p-3">
                <div className="flex items-center justify-between">
                  <Label htmlFor="res-repeat">Opakovat každý týden</Label>
                  <Switch id="res-repeat" checked={repeat} onCheckedChange={(v) => {
                    setRepeat(v);
                    if (v && !weekdays.length && date) {
                      const d = new Date(`${date}T00:00`);
                      setWeekdays([d.getDay() === 0 ? 7 : d.getDay()]);
                    }
                  }} />
                </div>
                {repeat && (
                  <>
                    <div className="flex flex-wrap gap-1">
                      {WEEKDAYS.map(([d, label]) => (
                        <Button
                          key={d} type="button" size="sm"
                          variant={weekdays.includes(d) ? 'default' : 'outline'}
                          onClick={() => toggleWeekday(d)}
                        >
                          {label}
                        </Button>
                      ))}
                    </div>
                    <div className="space-y-1">
                      <Label htmlFor="res-until">Opakovat do</Label>
                      <Input id="res-until" type="date" value={until} min={date} onChange={(e) => setUntil(e.target.value)} />
                    </div>
                    <p className="text-xs text-muted-foreground">
                      Termíny, které kolidují s jinou akcí, se přeskočí — na konci uvidíte které.
                    </p>
                  </>
                )}
              </div>
            )}

            {/* sazba */}
            {kind !== 'maintenance' && (
              <div className="space-y-2">
                <Label htmlFor="res-rate">Sazba (Kč/h)</Label>
                <Input
                  id="res-rate" value={rate} onChange={(e) => setRate(e.target.value)}
                  readOnly={!isAdmin} inputMode="numeric" placeholder={rate ? undefined : 'z ceníku'}
                />
                {!isAdmin && <p className="text-xs text-muted-foreground">Sazbu určuje správce podle ceníku.</p>}
              </div>
            )}

            {/* obsazení štábu */}
            {kind === 'commercial' && !isEdit && (
              <div className="space-y-2">
                <Label>Obsazení (směny)</Label>
                <p className="text-xs text-muted-foreground">
                  Počet instruktorů se předvyplnil podle počtu drah — můžete ho změnit. Bez instruktora akci nelze založit.
                </p>
                {STAFF_ROLES.map(({ key, label }) => (
                  <div key={key} className="flex items-center justify-between rounded-lg bg-muted/50 p-2">
                    <span className="text-sm font-medium">{label}</span>
                    <div className="flex items-center gap-3">
                      <Button type="button" variant="outline" size="icon" className="h-7 w-7"
                        onClick={() => adjust(key, -1)} disabled={(roleCounts[key] ?? 0) <= 0}><Minus className="h-4 w-4" /></Button>
                      <span className="w-6 text-center font-semibold">{roleCounts[key] ?? 0}</span>
                      <Button type="button" variant="outline" size="icon" className="h-7 w-7"
                        onClick={() => adjust(key, 1)}><Plus className="h-4 w-4" /></Button>
                    </div>
                  </div>
                ))}
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="res-note">Poznámka (nepovinné)</Label>
              <Textarea id="res-note" value={note} maxLength={VALIDATION_LIMITS.NOTES_MAX} onChange={(e) => setNote(e.target.value)} />
            </div>
          </div>

          <DialogFooter className="flex-shrink-0">
            <Button variant="outline" onClick={() => onOpenChange(false)}>Zrušit</Button>
            <Button onClick={handleSubmit} disabled={busy}>
              {busy ? 'Ukládám…' : isEdit ? 'Uložit' : repeat ? 'Založit sérii' : 'Rezervovat'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Vědomé přebití — jen admin a jen akcí vyšší priority */}
      <AlertDialog open={!!conflicts} onOpenChange={(o) => !o && setConflicts(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Termín je obsazený — přebít?</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2 text-sm">
                <p>Založením této akce se zruší:</p>
                <ul className="list-disc pl-5">
                  {(conflicts ?? []).map((c) => (
                    <li key={c.reservation_id}>
                      <strong>{c.event_title ?? c.subject_name ?? 'Rezervace'}</strong> — {c.sheet_name},{' '}
                      {format(new Date(c.start_at), 'd. M. HH:mm')}–{format(new Date(c.end_at), 'HH:mm')}
                    </li>
                  ))}
                </ul>
                <p className="text-muted-foreground">
                  Dotčený klub dostane upozornění, že jeho akce byla zrušena kvůli komerční události.
                </p>
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zpět</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={(e) => { e.preventDefault(); submitBooking(true); }}
            >
              Přebít a rezervovat
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
