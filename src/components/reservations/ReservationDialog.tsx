import { useEffect, useState } from 'react';
import { format } from 'date-fns';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Minus, Plus } from 'lucide-react';
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/components/ui/use-toast';
import { safeValidate, reservationSchema, sanitizeText, VALIDATION_LIMITS } from '@/lib/validation';
import type {
  Sheet, Subject, Settings, ReservationRow,
  CreateClubReservation, CreateCommercialBooking, CreateInternalBooking, UpdateReservationFields,
} from '@/hooks/useReservations';

type BookingType = 'club' | 'commercial' | 'internal';

const STAFF_ROLES = [
  { key: 'instructor', label: 'Instruktor' },
  { key: 'bar_staff', label: 'Obsluha baru' },
  { key: 'manager', label: 'Provozní hospoda' },
];

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  isAdmin: boolean;
  sheets: Sheet[];
  subjects: Subject[];
  settings: Settings | null;
  defaultSheetId?: string;
  defaultStart?: Date;
  editing?: ReservationRow | null;
  isCreating: boolean;
  isUpdating: boolean;
  onClub: (data: CreateClubReservation) => Promise<unknown>;
  onCommercial: (data: CreateCommercialBooking) => Promise<unknown>;
  onInternal: (data: CreateInternalBooking) => Promise<unknown>;
  onUpdateReservation: (args: { id: string; fields: UpdateReservationFields }) => Promise<unknown>;
  onUpdateEvent: (args: { id: string; fields: { title?: string; start_time?: string; end_time?: string } }) => Promise<unknown>;
  onAresLookup: (ico: string) => Promise<{ name: string; address: string; dic: string }>;
  onCreateSubject: (s: { name: string; ico?: string; dic?: string; address?: string }) => Promise<Subject>;
}

function addMinutes(time: string, mins: number): string {
  const [h, m] = time.split(':').map(Number);
  const total = h * 60 + m + mins;
  return `${String(Math.floor((total % 1440) / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
}

function editingType(r: ReservationRow): BookingType {
  if (!r.event_id) return 'club';
  return r.events?.event_type === 'commercial' ? 'commercial' : 'internal';
}

export function ReservationDialog({
  open, onOpenChange, isAdmin, sheets, subjects, settings, defaultSheetId, defaultStart, editing,
  isCreating, isUpdating, onClub, onCommercial, onInternal, onUpdateReservation, onUpdateEvent,
  onAresLookup, onCreateSubject,
}: Props) {
  const { toast } = useToast();
  const isEdit = !!editing;
  const clubs = subjects.filter((s) => s.type === 'club');
  const commercials = subjects.filter((s) => s.type === 'commercial');

  const [type, setType] = useState<BookingType>('club');
  const [subjectId, setSubjectId] = useState('');
  const [sheetId, setSheetId] = useState('');
  const [date, setDate] = useState('');
  const [startTime, setStartTime] = useState('');
  const [endTime, setEndTime] = useState('');
  const [note, setNote] = useState('');
  const [title, setTitle] = useState('');
  const [internalKind, setInternalKind] = useState<'training' | 'maintenance'>('training');
  const [roleCounts, setRoleCounts] = useState<Record<string, number>>({ instructor: 0, bar_staff: 0, manager: 0 });
  const [rate, setRate] = useState(''); // Kč/h; editovatelné jen adminem

  // ARES / nová firma
  const [newFirm, setNewFirm] = useState(false);
  const [ico, setIco] = useState('');
  const [firmName, setFirmName] = useState('');
  const [firmAddress, setFirmAddress] = useState('');
  const [firmDic, setFirmDic] = useState('');
  const [aresLoading, setAresLoading] = useState(false);

  const defaultRateFor = (t: BookingType, sid: string): string => {
    if (t === 'internal') return '';
    const subj = subjects.find((s) => s.id === sid);
    const r = subj?.default_rate ?? (t === 'club' ? settings?.club_default_rate : settings?.commercial_default_rate);
    return r != null ? String(r) : '';
  };

  useEffect(() => {
    if (!open) return;
    if (editing) {
      const t = editingType(editing);
      setType(t);
      setSubjectId(editing.subject_id ?? '');
      setSheetId(editing.sheet_id);
      setDate(format(new Date(editing.start_at), 'yyyy-MM-dd'));
      setStartTime(format(new Date(editing.start_at), 'HH:mm'));
      setEndTime(format(new Date(editing.end_at), 'HH:mm'));
      setNote(editing.note ?? '');
      setTitle(editing.events?.title ?? '');
      setRate(editing.rate_per_hour != null ? String(editing.rate_per_hour) : '');
    } else {
      const start = defaultStart ?? new Date();
      setType('club');
      setSubjectId(clubs.length === 1 ? clubs[0].id : '');
      setSheetId(defaultSheetId ?? sheets[0]?.id ?? '');
      setDate(format(start, 'yyyy-MM-dd'));
      const st = format(start, 'HH:mm');
      setStartTime(st);
      setEndTime(addMinutes(st, 90));
      setNote(''); setTitle(''); setInternalKind('training');
      setRoleCounts({ instructor: 0, bar_staff: 0, manager: 0 });
      setRate(defaultRateFor('club', clubs.length === 1 ? clubs[0].id : ''));
    }
    setNewFirm(false); setIco(''); setFirmName(''); setFirmAddress(''); setFirmDic('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, editing, defaultStart, defaultSheetId]);

  // přepnutí typu (jen create): předvyplň subjekt + sazbu
  useEffect(() => {
    if (isEdit || !open) return;
    const sid = type === 'club' ? (clubs.length === 1 ? clubs[0].id : '')
      : type === 'commercial' ? (commercials.length === 1 ? commercials[0].id : '') : '';
    setSubjectId(sid);
    setRate(defaultRateFor(type, sid));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [type]);

  // změna subjektu → přepočítej předvyplněnou sazbu (create)
  useEffect(() => {
    if (isEdit || !open || type === 'internal') return;
    setRate(defaultRateFor(type, subjectId));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [subjectId]);

  const adjust = (role: string, delta: number) =>
    setRoleCounts((p) => ({ ...p, [role]: Math.max(0, Math.min(VALIDATION_LIMITS.STAFF_COUNT_MAX, (p[role] ?? 0) + delta)) }));
  const totalStaff = Object.values(roleCounts).reduce((a, b) => a + b, 0);
  const rateNum = rate.trim() ? Number(rate.replace(',', '.')) : undefined;
  const busy = isCreating || isUpdating || aresLoading;
  // u komerční editace nelze měnit čas/dráha/obsazení (řeší se storno + nová)
  const lockTime = isEdit && type === 'commercial';

  const handleAres = async () => {
    if (!/^\d{8}$/.test(ico.trim())) {
      toast({ title: 'Neplatné IČO', description: 'Zadej 8 číslic.', variant: 'destructive' });
      return;
    }
    setAresLoading(true);
    try {
      const d = await onAresLookup(ico.trim());
      setFirmName(d.name); setFirmAddress(d.address); setFirmDic(d.dic);
      toast({ title: 'Načteno z ARESu', description: d.name });
    } catch (e) {
      toast({ title: 'ARES', description: e instanceof Error ? e.message : 'Načtení selhalo.', variant: 'destructive' });
    } finally {
      setAresLoading(false);
    }
  };

  const handleCreateFirm = async () => {
    if (!firmName.trim()) { toast({ title: 'Vyplň název firmy', variant: 'destructive' }); return; }
    try {
      const subj = await onCreateSubject({ name: sanitizeText(firmName), ico: ico.trim() || undefined, dic: firmDic || undefined, address: firmAddress || undefined });
      setNewFirm(false); setSubjectId(subj.id); setRate(defaultRateFor('commercial', subj.id));
      toast({ title: 'Firma založena', description: subj.name });
    } catch (e) {
      toast({ title: 'Chyba', description: e instanceof Error ? e.message : 'Nepodařilo se založit firmu.', variant: 'destructive' });
    }
  };

  const handleSubmit = async () => {
    const startDate = new Date(`${date}T${startTime}`);
    const endDate = new Date(`${date}T${endTime}`);
    if (!date || !startTime || !endTime || isNaN(startDate.getTime()) || isNaN(endDate.getTime())) {
      toast({ title: 'Zkontroluj formulář', description: 'Vyplň datum i čas od–do.', variant: 'destructive' }); return;
    }
    const start_at = startDate.toISOString();
    const end_at = endDate.toISOString();
    const noteVal = note ? sanitizeText(note) : undefined;
    // Sazbu smí zadat jen admin; když ji zadá, musí to být kladné číslo (prázdné = dopočet z ceníku).
    if (isAdmin && type !== 'internal' && rate.trim() && (rateNum === undefined || isNaN(rateNum) || rateNum <= 0)) {
      toast({ title: 'Neplatná sazba', description: 'Zadej kladné číslo, nebo nech prázdné (dopočte se z ceníku).', variant: 'destructive' });
      return;
    }
    const adminRate = isAdmin && rate.trim() && rateNum !== undefined && !isNaN(rateNum) ? rateNum : undefined;

    try {
      if (isEdit && editing) {
        // EDITACE
        if (type === 'club') {
          const base = safeValidate(reservationSchema, { sheet_id: sheetId, subject_id: subjectId, start_at, end_at, note: noteVal });
          if (!base.success) { toast({ title: 'Zkontroluj formulář', description: base.error, variant: 'destructive' }); return; }
          await onUpdateReservation({ id: editing.id, fields: { sheet_id: sheetId, start_at, end_at, note: noteVal ?? null, ...(adminRate ? { rate_per_hour: adminRate } : {}) } });
        } else if (type === 'internal') {
          if (!title.trim()) { toast({ title: 'Vyplň název', variant: 'destructive' }); return; }
          const iv = safeValidate(reservationSchema, { sheet_id: sheetId, subject_id: '00000000-0000-0000-0000-000000000000', start_at, end_at, note: noteVal });
          if (!iv.success) { toast({ title: 'Zkontroluj formulář', description: iv.error, variant: 'destructive' }); return; }
          await onUpdateReservation({ id: editing.id, fields: { sheet_id: sheetId, start_at, end_at, note: noteVal ?? null } });
          if (editing.event_id) await onUpdateEvent({ id: editing.event_id, fields: { title: sanitizeText(title), start_time: start_at, end_time: end_at } });
        } else {
          // commercial: jen název/poznámka/sazba (čas/dráha/obsazení = storno+nová)
          if (!title.trim()) { toast({ title: 'Vyplň název', variant: 'destructive' }); return; }
          await onUpdateReservation({ id: editing.id, fields: { note: noteVal ?? null, ...(adminRate ? { rate_per_hour: adminRate } : {}) } });
          if (editing.event_id) await onUpdateEvent({ id: editing.event_id, fields: { title: sanitizeText(title) } });
        }
        toast({ title: 'Rezervace upravena' });
        onOpenChange(false);
        return;
      }

      // VYTVOŘENÍ
      const base = safeValidate(reservationSchema, {
        sheet_id: sheetId,
        subject_id: type === 'internal' ? '00000000-0000-0000-0000-000000000000' : subjectId,
        start_at, end_at, note: noteVal,
      });
      if (!base.success) { toast({ title: 'Zkontroluj formulář', description: base.error, variant: 'destructive' }); return; }
      if (type !== 'club' && !title.trim()) { toast({ title: 'Vyplň název akce', variant: 'destructive' }); return; }
      if (type === 'commercial' && totalStaff === 0) { toast({ title: 'Nastav aspoň jednu roli do obsazení', variant: 'destructive' }); return; }

      if (type === 'club') {
        await onClub({ sheet_id: sheetId, subject_id: subjectId, start_at, end_at, note: noteVal, rate_per_hour: adminRate });
      } else if (type === 'commercial') {
        const role_reqs = Object.fromEntries(Object.entries(roleCounts).filter(([, c]) => c > 0));
        await onCommercial({ sheet_id: sheetId, subject_id: subjectId, start_at, end_at, note: noteVal, title: sanitizeText(title), role_reqs, rate_per_hour: adminRate });
      } else {
        await onInternal({ sheet_id: sheetId, start_at, end_at, note: noteVal, title: sanitizeText(title), event_type: internalKind });
      }
      toast({ title: 'Rezervace vytvořena' });
      onOpenChange(false);
    } catch (error) {
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Operace selhala.', variant: 'destructive' });
    }
  };

  const subjectMissing = (type === 'club' && !subjectId) || (type === 'commercial' && !subjectId);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md max-h-[90vh] flex flex-col">
        <DialogHeader className="flex-shrink-0">
          <DialogTitle>{isEdit ? 'Upravit rezervaci' : 'Nová rezervace'}</DialogTitle>
          <DialogDescription>
            {isEdit ? 'Uprav údaje rezervace.' : 'Zarezervuj dráhu. U komerční akce se založí i obsazení (směny).'}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 overflow-y-auto flex-1 pr-2">
          {isAdmin && !isEdit && (
            <div className="space-y-2">
              <Label>Typ</Label>
              <div className="flex gap-1">
                {([['club', 'Klub'], ['commercial', 'Komerční'], ['internal', 'Interní']] as const).map(([val, lab]) => (
                  <Button key={val} type="button" size="sm" variant={type === val ? 'default' : 'outline'} onClick={() => setType(val)}>{lab}</Button>
                ))}
              </div>
            </div>
          )}

          {type !== 'internal' && !newFirm && (
            <div className="space-y-2">
              <Label>{type === 'club' ? 'Klub' : 'Komerční zákazník'}</Label>
              <Select value={subjectId} onValueChange={setSubjectId} disabled={isEdit || (type === 'club' ? clubs : commercials).length === 1}>
                <SelectTrigger><SelectValue placeholder="Vyber subjekt" /></SelectTrigger>
                <SelectContent>
                  {(type === 'club' ? clubs : commercials).map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
                </SelectContent>
              </Select>
              {type === 'commercial' && isAdmin && !isEdit && (
                <Button type="button" variant="link" size="sm" className="h-auto p-0" onClick={() => setNewFirm(true)}>+ Přidat novou firmu (ARES)</Button>
              )}
            </div>
          )}

          {/* Nová firma přes ARES (jen komerční create, admin) */}
          {type === 'commercial' && newFirm && !isEdit && (
            <div className="space-y-2 rounded-md border p-3">
              <Label>Nová firma podle IČO</Label>
              <div className="flex gap-2">
                <Input value={ico} onChange={(e) => setIco(e.target.value)} placeholder="IČO (8 číslic)" inputMode="numeric" />
                <Button type="button" variant="outline" onClick={handleAres} disabled={aresLoading}>{aresLoading ? '…' : 'Načíst z ARESu'}</Button>
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

          {type !== 'club' && (
            <div className="space-y-2">
              <Label htmlFor="res-title">Název akce</Label>
              <Input id="res-title" value={title} maxLength={VALIDATION_LIMITS.TITLE_MAX} onChange={(e) => setTitle(e.target.value)} />
            </div>
          )}

          {type === 'internal' && !isEdit && (
            <div className="space-y-2">
              <Label>Druh</Label>
              <Select value={internalKind} onValueChange={(v) => setInternalKind(v as 'training' | 'maintenance')}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="training">Trénink</SelectItem>
                  <SelectItem value="maintenance">Údržba ledu</SelectItem>
                </SelectContent>
              </Select>
            </div>
          )}

          <div className="space-y-2">
            <Label>Dráha</Label>
            <Select value={sheetId} onValueChange={setSheetId} disabled={lockTime}>
              <SelectTrigger><SelectValue placeholder="Vyber dráhu" /></SelectTrigger>
              <SelectContent>{sheets.map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}</SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="res-date">Datum</Label>
            <Input id="res-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} disabled={lockTime} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-2">
              <Label htmlFor="res-start">Od</Label>
              <Input id="res-start" type="time" value={startTime} disabled={lockTime}
                onChange={(e) => { setStartTime(e.target.value); if (!isEdit) setEndTime(addMinutes(e.target.value, 90)); }} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="res-end">Do</Label>
              <Input id="res-end" type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} disabled={lockTime} />
            </div>
          </div>
          {lockTime && (
            <p className="text-xs text-muted-foreground">Čas, dráha a obsazení u komerční akce změň přes storno a novou rezervaci.</p>
          )}

          {/* Sazba — jen klub/komerční; editace jen admin */}
          {type !== 'internal' && (
            <div className="space-y-2">
              <Label htmlFor="res-rate">Sazba (Kč/h)</Label>
              <Input id="res-rate" value={rate} onChange={(e) => setRate(e.target.value)} readOnly={!isAdmin}
                inputMode="numeric" placeholder={rate ? undefined : 'z ceníku'} />
              {!isAdmin && <p className="text-xs text-muted-foreground">Sazbu určuje správce podle ceníku.</p>}
            </div>
          )}

          {type === 'commercial' && !isEdit && (
            <div className="space-y-2">
              <Label>Konfigurace obsazení</Label>
              {STAFF_ROLES.map(({ key, label }) => (
                <div key={key} className="flex items-center justify-between rounded-lg bg-muted/50 p-2">
                  <span className="text-sm font-medium">{label}</span>
                  <div className="flex items-center gap-3">
                    <Button type="button" variant="outline" size="icon" className="h-7 w-7" onClick={() => adjust(key, -1)} disabled={roleCounts[key] <= 0}><Minus className="h-4 w-4" /></Button>
                    <span className="w-6 text-center font-semibold">{roleCounts[key]}</span>
                    <Button type="button" variant="outline" size="icon" className="h-7 w-7" onClick={() => adjust(key, 1)}><Plus className="h-4 w-4" /></Button>
                  </div>
                </div>
              ))}
              {totalStaff > 0 && <p className="text-right text-xs text-muted-foreground">Celkem směn: {totalStaff}</p>}
            </div>
          )}

          <div className="space-y-2">
            <Label htmlFor="res-note">Poznámka (nepovinné)</Label>
            <Textarea id="res-note" value={note} maxLength={VALIDATION_LIMITS.NOTES_MAX} onChange={(e) => setNote(e.target.value)} />
          </div>
        </div>

        <DialogFooter className="flex-shrink-0">
          <Button variant="outline" onClick={() => onOpenChange(false)}>Zrušit</Button>
          <Button onClick={handleSubmit} disabled={busy || !sheetId || !date || !startTime || !endTime || subjectMissing}>
            {busy ? 'Ukládám…' : isEdit ? 'Uložit' : 'Rezervovat'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
