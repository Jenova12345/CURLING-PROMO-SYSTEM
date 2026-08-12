import { useMemo, useState } from 'react';
import {
  format, startOfDay, addDays, subDays, startOfWeek, addWeeks, subWeeks,
  startOfMonth, addMonths, subMonths,
} from 'date-fns';
import { cs } from 'date-fns/locale';
import { ChevronLeft, ChevronRight, Wallet, FileText } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useAuth } from '@/contexts/AuthContext';
import { useDues } from '@/hooks/useDues';
import { useToast } from '@/components/ui/use-toast';
import { openInvoiceDraft } from '@/lib/invoiceDraft';
import { fmtHodin as fmtH, fmtKc } from '@/lib/money';

type View = 'day' | 'week' | 'month';

const Dues = () => {
  const { isAdmin } = useAuth();
  const { toast } = useToast();
  const [view, setView] = useState<View>('month');
  const [currentDate, setCurrentDate] = useState(() => startOfDay(new Date()));

  const range = useMemo(() => {
    if (view === 'day') { const f = startOfDay(currentDate); return { from: f.toISOString(), to: addDays(f, 1).toISOString() }; }
    if (view === 'week') { const f = startOfWeek(currentDate, { weekStartsOn: 1 }); return { from: f.toISOString(), to: addDays(f, 7).toISOString() }; }
    return { from: startOfMonth(currentDate).toISOString(), to: startOfMonth(addMonths(currentDate, 1)).toISOString() };
  }, [view, currentDate]);

  const { reservations, summary, subjects, totalAmount, totalHours, isLoading } = useDues(isAdmin ? range : null);

  // Podklad k fakturaci pro jeden subjekt za zobrazené období — otevře se
  // v novém okně jako tisknutelná stránka („Uložit jako PDF"). Nic se neukládá.
  const vystavFakturu = (subjectId: string, subjectName: string) => {
    const radky = reservations.filter((r) => r.subject_id === subjectId);
    if (!radky.length) {
      toast({ title: 'Není co fakturovat', description: `${subjectName} nemá v tomto období žádnou rezervaci.` });
      return;
    }
    const subjekt = subjects.find((s) => s.id === subjectId);
    const otevreno = openInvoiceDraft({
      subject: {
        name: subjekt?.name ?? subjectName,
        address: subjekt?.address,
        ico: subjekt?.ico,
        dic: subjekt?.dic,
      },
      rows: radky.map((r) => {
        // Stejný výpočet jako v souhrnu, ať doklad sedí na to, co je na stránce.
        // Sazba se BERE, nedopočítává: corrected_amount je vždy
        // round(corrected_hours × rate_per_hour, 2), takže rate_per_hour sedí
        // i po ruční korekci. Dřívější dopočet částka/hodiny tiskl sazby jako
        // „1 251 Kč", které po vynásobení hodinami nedaly cenu na témže řádku.
        const hodiny = Number(r.corrected_hours ?? r.hours ?? 0);
        const castka = Number(r.corrected_amount ?? r.amount ?? 0);
        return {
          start_at: r.start_at,
          end_at: r.end_at,
          ordered_by: r.created_by_name,
          event_title: r.event_title,
          sheet_name: r.sheet_name,
          hours: hodiny,
          rate: r.rate_per_hour != null ? Number(r.rate_per_hour) : null,
          amount: castka,
        };
      }),
      periodFrom: new Date(range.from),
      periodTo: addDays(new Date(range.to), -1),
    });
    if (!otevreno) {
      toast({
        title: 'Okno se neotevřelo',
        description: 'Prohlížeč zablokoval vyskakovací okno — povolte ho pro tuto stránku a zkuste znovu.',
        variant: 'destructive',
      });
    }
  };

  const goPrev = () => setCurrentDate((d) => view === 'day' ? subDays(d, 1) : view === 'week' ? subWeeks(d, 1) : subMonths(d, 1));
  const goNext = () => setCurrentDate((d) => view === 'day' ? addDays(d, 1) : view === 'week' ? addWeeks(d, 1) : addMonths(d, 1));

  const headerLabel = useMemo(() => {
    if (view === 'day') return format(currentDate, 'EEEE d. MMMM yyyy', { locale: cs });
    if (view === 'month') return format(currentDate, 'LLLL yyyy', { locale: cs });
    const ws = startOfWeek(currentDate, { weekStartsOn: 1 });
    return `${format(ws, 'd. M.', { locale: cs })} – ${format(addDays(ws, 6), 'd. M. yyyy', { locale: cs })}`;
  }, [view, currentDate]);

  if (!isAdmin) return <div className="p-6 text-muted-foreground">Přehled úhrad může vidět jen správce.</div>;

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div>
        <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2"><Wallet className="h-6 w-6" /> Kdo kolik dluží</h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">Podklady k úhradě podle rezervovaných hodin. Interní (tréninky/údržba) se nepočítají.</p>
      </div>

      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="icon" onClick={goPrev} aria-label="Předchozí"><ChevronLeft className="h-4 w-4" /></Button>
          <Button variant="outline" size="sm" onClick={() => setCurrentDate(startOfDay(new Date()))}>Dnes</Button>
          <Button variant="outline" size="icon" onClick={goNext} aria-label="Další"><ChevronRight className="h-4 w-4" /></Button>
          <span className="ml-2 font-medium capitalize text-sm md:text-base">{headerLabel}</span>
        </div>
        <div className="flex gap-1">
          {(['day', 'week', 'month'] as const).map((v) => (
            <Button key={v} variant={view === v ? 'default' : 'outline'} size="sm" onClick={() => setView(v)}>{v === 'day' ? 'Den' : v === 'week' ? 'Týden' : 'Měsíc'}</Button>
          ))}
        </div>
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        {/* Schválně NE „k úhradě": tohle je přesný součet za období, kdežto k úhradě
            je až zaokrouhlená částka na konkrétním dokladu. Kdyby se to jmenovalo
            stejně, obrazovka a faktura by ukazovaly o korunu jiné číslo pod týmž popiskem. */}
        <Card><CardContent className="pt-4"><div className="text-xs text-muted-foreground">Celkem za období</div><div className="text-2xl font-bold">{fmtKc(totalAmount)}</div></CardContent></Card>
        <Card><CardContent className="pt-4"><div className="text-xs text-muted-foreground">Hodin celkem</div><div className="text-2xl font-bold">{fmtH(totalHours)}</div></CardContent></Card>
        <Card><CardContent className="pt-4"><div className="text-xs text-muted-foreground">Subjektů</div><div className="text-2xl font-bold">{summary.length}</div></CardContent></Card>
      </div>

      <Card>
        <CardHeader><CardTitle className="text-base">Po subjektech</CardTitle></CardHeader>
        <CardContent>
          {isLoading ? <div className="text-muted-foreground">Načítám…</div> : summary.length === 0 ? (
            <div className="text-muted-foreground text-sm">V tomto období nejsou žádné účtovatelné rezervace.</div>
          ) : (
            <Table>
              <TableHeader><TableRow><TableHead>Subjekt</TableHead><TableHead>Typ</TableHead><TableHead className="text-right">Hodiny</TableHead><TableHead className="text-right">Částka</TableHead><TableHead className="text-right">Podklad</TableHead></TableRow></TableHeader>
              <TableBody>
                {summary.map((r) => (
                  <TableRow key={r.subjectId}>
                    <TableCell className="font-medium">{r.name}</TableCell>
                    <TableCell><Badge variant="secondary">{r.type === 'club' ? 'Klub' : 'Komerční'}</Badge></TableCell>
                    <TableCell className="text-right">{fmtH(r.hours)}</TableCell>
                    <TableCell className="text-right font-semibold">{fmtKc(r.amount)}</TableCell>
                    <TableCell className="text-right">
                      <Button
                        variant="outline" size="sm"
                        aria-label={`Podklad k fakturaci — ${r.name}`}
                        onClick={() => vystavFakturu(r.subjectId, r.name)}
                      >
                        <FileText className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Faktura (PDF)
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow><TableCell colSpan={2} className="font-bold">Celkem</TableCell><TableCell className="text-right font-bold">{fmtH(totalHours)}</TableCell><TableCell className="text-right font-bold">{fmtKc(totalAmount)}</TableCell><TableCell /></TableRow>
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {view === 'day' && (
        <Card>
          <CardHeader><CardTitle className="text-base">Detail dne — kdo, jak dlouho, kolik</CardTitle></CardHeader>
          <CardContent>
            {reservations.length === 0 ? <div className="text-muted-foreground text-sm">Žádné účtovatelné rezervace.</div> : (
              <div className="space-y-1 text-sm">
                {reservations.map((r) => (
                  <div key={r.id} className="flex items-center justify-between gap-2 border-b py-1 last:border-0">
                    <span className="font-medium">{r.subject_name}{r.event_title ? ` — ${r.event_title}` : ''}</span>
                    <span className="text-muted-foreground">{format(new Date(r.start_at), 'HH:mm')}–{format(new Date(r.end_at), 'HH:mm')}</span>
                    <span>{fmtH(Number(r.corrected_hours ?? r.hours ?? 0))}</span>
                    <span className="font-semibold">{fmtKc(Number(r.corrected_amount ?? r.amount ?? 0))}</span>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  );
};

export default Dues;
