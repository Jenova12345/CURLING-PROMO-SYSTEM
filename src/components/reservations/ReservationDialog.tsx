import { useEffect, useState } from 'react';
import { format } from 'date-fns';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/components/ui/use-toast';
import { safeValidate, reservationSchema, sanitizeText, VALIDATION_LIMITS } from '@/lib/validation';
import type { Sheet, Subject, CreateReservationData } from '@/hooks/useReservations';

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  sheets: Sheet[];
  subjects: Subject[];
  defaultSheetId?: string;
  defaultStart?: Date;
  onSubmit: (data: CreateReservationData) => Promise<unknown>;
  isCreating: boolean;
}

// Přičte minuty k času "HH:mm" a vrátí zase "HH:mm".
function addMinutes(time: string, mins: number): string {
  const [h, m] = time.split(':').map(Number);
  const total = h * 60 + m + mins;
  const hh = Math.floor((total % 1440) / 60);
  const mm = total % 60;
  return `${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}`;
}

export function ReservationDialog({
  open, onOpenChange, sheets, subjects, defaultSheetId, defaultStart, onSubmit, isCreating,
}: Props) {
  const { toast } = useToast();
  const [subjectId, setSubjectId] = useState('');
  const [sheetId, setSheetId] = useState('');
  const [date, setDate] = useState('');
  const [startTime, setStartTime] = useState('');
  const [endTime, setEndTime] = useState('');
  const [note, setNote] = useState('');

  // Předvyplnění při otevření.
  useEffect(() => {
    if (!open) return;
    const start = defaultStart ?? new Date();
    setSheetId(defaultSheetId ?? sheets[0]?.id ?? '');
    setSubjectId(subjects.length === 1 ? subjects[0].id : '');
    setDate(format(start, 'yyyy-MM-dd'));
    const st = format(start, 'HH:mm');
    setStartTime(st);
    setEndTime(addMinutes(st, 90)); // default 1,5 h
    setNote('');
  }, [open, defaultStart, defaultSheetId, sheets, subjects]);

  const handleSubmit = async () => {
    const startDate = new Date(`${date}T${startTime}`);
    const endDate = new Date(`${date}T${endTime}`);
    if (!date || !startTime || !endTime || isNaN(startDate.getTime()) || isNaN(endDate.getTime())) {
      toast({ title: 'Zkontroluj formulář', description: 'Vyplň datum i čas od–do.', variant: 'destructive' });
      return;
    }
    const start_at = startDate.toISOString();
    const end_at = endDate.toISOString();

    const validation = safeValidate(reservationSchema, {
      sheet_id: sheetId,
      subject_id: subjectId,
      start_at,
      end_at,
      note: note ? sanitizeText(note) : undefined,
    });
    if (!validation.success) {
      toast({ title: 'Zkontroluj formulář', description: validation.error, variant: 'destructive' });
      return;
    }

    try {
      await onSubmit(validation.data as CreateReservationData);
      toast({ title: 'Rezervace vytvořena', description: 'Slot je zamluvený.' });
      onOpenChange(false);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se vytvořit rezervaci.';
      toast({ title: 'Chyba', description: message, variant: 'destructive' });
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md max-h-[90vh] flex flex-col">
        <DialogHeader className="flex-shrink-0">
          <DialogTitle>Nová rezervace</DialogTitle>
          <DialogDescription>Zarezervuj plátno na konkrétní čas. Sazbu dopočítá systém.</DialogDescription>
        </DialogHeader>

        <div className="space-y-4 overflow-y-auto flex-1 pr-2">
          <div className="space-y-2">
            <Label>Subjekt (klub / zákazník)</Label>
            <Select value={subjectId} onValueChange={setSubjectId} disabled={subjects.length === 1}>
              <SelectTrigger><SelectValue placeholder="Vyber subjekt" /></SelectTrigger>
              <SelectContent>
                {subjects.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name}{s.type === 'commercial' ? ' (komerční)' : ''}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {subjects.length === 0 && (
              <p className="text-xs text-muted-foreground">Nemáte přiřazený žádný subjekt k rezervaci.</p>
            )}
          </div>

          <div className="space-y-2">
            <Label>Plátno</Label>
            <Select value={sheetId} onValueChange={setSheetId}>
              <SelectTrigger><SelectValue placeholder="Vyber plátno" /></SelectTrigger>
              <SelectContent>
                {sheets.map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="res-date">Datum</Label>
            <Input id="res-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-2">
              <Label htmlFor="res-start">Od</Label>
              <Input
                id="res-start" type="time" value={startTime}
                onChange={(e) => {
                  setStartTime(e.target.value);
                  setEndTime(addMinutes(e.target.value, 90));
                }}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="res-end">Do</Label>
              <Input id="res-end" type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} />
            </div>
          </div>

          <div className="space-y-2">
            <Label htmlFor="res-note">Poznámka (nepovinné)</Label>
            <Textarea
              id="res-note" value={note} maxLength={VALIDATION_LIMITS.NOTES_MAX}
              onChange={(e) => setNote(e.target.value)} placeholder="Např. trénink týmu A"
            />
          </div>
        </div>

        <DialogFooter className="flex-shrink-0">
          <Button variant="outline" onClick={() => onOpenChange(false)}>Zrušit</Button>
          <Button onClick={handleSubmit} disabled={isCreating || !subjectId || !sheetId || !date || !startTime || !endTime}>
            {isCreating ? 'Ukládám…' : 'Rezervovat'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
