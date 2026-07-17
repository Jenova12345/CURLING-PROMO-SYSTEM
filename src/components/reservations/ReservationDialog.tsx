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
  Sheet, Subject, CreateClubReservation, CreateCommercialBooking, CreateInternalBooking,
} from '@/hooks/useReservations';

type BookingType = 'club' | 'commercial' | 'internal';

const STAFF_ROLES: { key: string; label: string }[] = [
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
  defaultSheetId?: string;
  defaultStart?: Date;
  isCreating: boolean;
  onClub: (data: CreateClubReservation) => Promise<unknown>;
  onCommercial: (data: CreateCommercialBooking) => Promise<unknown>;
  onInternal: (data: CreateInternalBooking) => Promise<unknown>;
}

function addMinutes(time: string, mins: number): string {
  const [h, m] = time.split(':').map(Number);
  const total = h * 60 + m + mins;
  return `${String(Math.floor((total % 1440) / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
}

export function ReservationDialog({
  open, onOpenChange, isAdmin, sheets, subjects, defaultSheetId, defaultStart, isCreating,
  onClub, onCommercial, onInternal,
}: Props) {
  const { toast } = useToast();
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

  useEffect(() => {
    if (!open) return;
    const start = defaultStart ?? new Date();
    // ne-admin může jen klub; admin má default klub, ale může přepnout
    setType('club');
    setSheetId(defaultSheetId ?? sheets[0]?.id ?? '');
    setSubjectId(clubs.length === 1 ? clubs[0].id : '');
    setDate(format(start, 'yyyy-MM-dd'));
    const st = format(start, 'HH:mm');
    setStartTime(st);
    setEndTime(addMinutes(st, 90));
    setNote('');
    setTitle('');
    setInternalKind('training');
    setRoleCounts({ instructor: 0, bar_staff: 0, manager: 0 });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, defaultStart, defaultSheetId]);

  // při přepnutí typu předvyplň relevantní subjekt
  useEffect(() => {
    if (type === 'club') setSubjectId(clubs.length === 1 ? clubs[0].id : '');
    if (type === 'commercial') setSubjectId(commercials.length === 1 ? commercials[0].id : '');
    if (type === 'internal') setSubjectId('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [type]);

  const adjust = (role: string, delta: number) =>
    setRoleCounts((prev) => ({ ...prev, [role]: Math.max(0, Math.min(VALIDATION_LIMITS.STAFF_COUNT_MAX, (prev[role] ?? 0) + delta)) }));
  const totalStaff = Object.values(roleCounts).reduce((a, b) => a + b, 0);

  const handleSubmit = async () => {
    const startDate = new Date(`${date}T${startTime}`);
    const endDate = new Date(`${date}T${endTime}`);
    if (!date || !startTime || !endTime || isNaN(startDate.getTime()) || isNaN(endDate.getTime())) {
      toast({ title: 'Zkontroluj formulář', description: 'Vyplň datum i čas od–do.', variant: 'destructive' });
      return;
    }
    const start_at = startDate.toISOString();
    const end_at = endDate.toISOString();

    // společná validace ledového slotu (subjekt validujeme jen tam, kde je povinný)
    const base = safeValidate(reservationSchema, {
      sheet_id: sheetId,
      subject_id: type === 'internal' ? '00000000-0000-0000-0000-000000000000' : subjectId,
      start_at, end_at, note: note ? sanitizeText(note) : undefined,
    });
    if (!base.success) {
      toast({ title: 'Zkontroluj formulář', description: base.error, variant: 'destructive' });
      return;
    }
    if (type !== 'club' && !title.trim()) {
      toast({ title: 'Zkontroluj formulář', description: 'Vyplň název akce.', variant: 'destructive' });
      return;
    }
    if (type === 'commercial' && totalStaff === 0) {
      toast({ title: 'Zkontroluj formulář', description: 'Nastav aspoň jednu roli do štábu.', variant: 'destructive' });
      return;
    }

    try {
      if (type === 'club') {
        await onClub({ sheet_id: sheetId, subject_id: subjectId, start_at, end_at, note: note || undefined });
      } else if (type === 'commercial') {
        const role_reqs = Object.fromEntries(Object.entries(roleCounts).filter(([, c]) => c > 0));
        await onCommercial({ sheet_id: sheetId, subject_id: subjectId, start_at, end_at, note: note || undefined, title: sanitizeText(title), role_reqs });
      } else {
        await onInternal({ sheet_id: sheetId, start_at, end_at, note: note || undefined, title: sanitizeText(title), event_type: internalKind });
      }
      toast({ title: 'Rezervace vytvořena', description: 'Slot je zamluvený.' });
      onOpenChange(false);
    } catch (error) {
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Nepodařilo se vytvořit rezervaci.', variant: 'destructive' });
    }
  };

  const subjectMissing =
    (type === 'club' && !subjectId) || (type === 'commercial' && !subjectId);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md max-h-[90vh] flex flex-col">
        <DialogHeader className="flex-shrink-0">
          <DialogTitle>Nová rezervace</DialogTitle>
          <DialogDescription>Zarezervuj plátno. Sazbu dopočítá systém; u komerční akce se založí i štáb.</DialogDescription>
        </DialogHeader>

        <div className="space-y-4 overflow-y-auto flex-1 pr-2">
          {isAdmin && (
            <div className="space-y-2">
              <Label>Typ</Label>
              <div className="flex gap-1">
                {([['club', 'Klub'], ['commercial', 'Komerční'], ['internal', 'Interní']] as const).map(([val, lab]) => (
                  <Button key={val} type="button" size="sm" variant={type === val ? 'default' : 'outline'} onClick={() => setType(val)}>{lab}</Button>
                ))}
              </div>
            </div>
          )}

          {type !== 'internal' && (
            <div className="space-y-2">
              <Label>{type === 'club' ? 'Klub' : 'Komerční zákazník'}</Label>
              <Select value={subjectId} onValueChange={setSubjectId} disabled={(type === 'club' ? clubs : commercials).length === 1}>
                <SelectTrigger><SelectValue placeholder="Vyber subjekt" /></SelectTrigger>
                <SelectContent>
                  {(type === 'club' ? clubs : commercials).map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
                </SelectContent>
              </Select>
              {(type === 'club' ? clubs : commercials).length === 0 && (
                <p className="text-xs text-muted-foreground">Žádný dostupný subjekt.</p>
              )}
            </div>
          )}

          {type !== 'club' && (
            <div className="space-y-2">
              <Label htmlFor="res-title">Název akce</Label>
              <Input id="res-title" value={title} maxLength={VALIDATION_LIMITS.TITLE_MAX}
                onChange={(e) => setTitle(e.target.value)} placeholder={type === 'commercial' ? 'Např. Firemní teambuilding' : 'Např. Trénink MK'} />
            </div>
          )}

          {type === 'internal' && (
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
            <Label>Plátno</Label>
            <Select value={sheetId} onValueChange={setSheetId}>
              <SelectTrigger><SelectValue placeholder="Vyber plátno" /></SelectTrigger>
              <SelectContent>{sheets.map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}</SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="res-date">Datum</Label>
            <Input id="res-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-2">
              <Label htmlFor="res-start">Od</Label>
              <Input id="res-start" type="time" value={startTime}
                onChange={(e) => { setStartTime(e.target.value); setEndTime(addMinutes(e.target.value, 90)); }} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="res-end">Do</Label>
              <Input id="res-end" type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} />
            </div>
          </div>

          {type === 'commercial' && (
            <div className="space-y-2">
              <Label>Konfigurace týmu (štáb)</Label>
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
          <Button onClick={handleSubmit} disabled={isCreating || !sheetId || !date || !startTime || !endTime || subjectMissing}>
            {isCreating ? 'Ukládám…' : 'Rezervovat'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
