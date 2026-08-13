import { useMemo, useState } from 'react';
import { addMonths, endOfMonth, format, startOfMonth, subMonths } from 'date-fns';
import { cs } from 'date-fns/locale';
import {
  FileText, Printer, Trash2, Check, AlertTriangle, ChevronLeft, ChevronRight, Scale,
} from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { useAuth } from '@/contexts/AuthContext';
import { denZDb } from '@/lib/datum';
import { useToast } from '@/components/ui/use-toast';
import { useBillingReconcile, useInvoiceDetail, useInvoices } from '@/hooks/useInvoices';
import { openInvoicePrint } from '@/lib/invoicePrint';
import { fmtHodin, fmtKc, fmtSazba } from '@/lib/money';

const STAV_POPIS: Record<string, string> = {
  koncept: 'Koncept',
  vystaveno: 'Vystaveno',
  zaplaceno: 'Zaplaceno',
  stornovano: 'Stornováno',
};

// `denZDb`, ne `new Date`: holé `RRRR-MM-DD` z `date` sloupce je půlnoc UTC.
const den = (d: string | null) => {
  const datum = denZDb(d);
  return datum ? format(datum, 'd. M. yyyy', { locale: cs }) : '—';
};

const StavBadge = ({ stav, poSplatnosti }: { stav: string; poSplatnosti: boolean | null }) => {
  // „Po splatnosti" je odvozený stav (spec, bod 9), ne hodnota v databázi —
  // proto se ukazuje vedle stavu, ne místo něj.
  if (poSplatnosti) return <Badge variant="destructive">Po splatnosti</Badge>;
  if (stav === 'koncept') return <Badge variant="secondary">Koncept</Badge>;
  if (stav === 'zaplaceno') return <Badge>Zaplaceno</Badge>;
  if (stav === 'stornovano') return <Badge variant="outline">Stornováno</Badge>;
  return <Badge variant="default">Vystaveno</Badge>;
};

const Invoices = () => {
  const { isAdmin } = useAuth();
  const { toast } = useToast();
  const { invoices, isLoading, error, issue, deleteDraft, isBusy } = useInvoices();
  const [detailId, setDetailId] = useState<string | null>(null);
  const { data: detail, isLoading: detailLoading } = useInvoiceDetail(detailId);

  // Kontrolní součet za měsíc. Vlastní období, ne to z „Kdo dluží": tady se
  // kontroluje účetní období, ne to, co má admin zrovna rozkliknuté jinde.
  const [mesic, setMesic] = useState(() => startOfMonth(new Date()));
  const obdobi = useMemo(() => ({
    from: format(startOfMonth(mesic), 'yyyy-MM-dd'),
    to: format(endOfMonth(mesic), 'yyyy-MM-dd'),
  }), [mesic]);
  const { data: soucet = [], isLoading: soucetLoading } = useBillingReconcile(obdobi);
  const nesedi = soucet.filter((r) => Number(r.rozdil) !== 0);

  if (!isAdmin) return <div className="p-6 text-muted-foreground">Faktury vidí jen správce.</div>;

  // Berou ID, ne celý řádek: detail dialogu má jinou strukturu než řádek seznamu
  // a přetypovávat kvůli tomu neúplný objekt na `InvoiceListRow` je lež kompilátoru.
  const vystav = async (id: string, popis?: string) => {
    // Vystavení je NEVRATNÉ: spálí číslo v řadě, doklad je od té chvíle neměnný
    // a storno ani dobropis v tomhle rozsahu nejsou. Jediná cesta zpět vede přes
    // `app.invoice_repair` z psql. Jeden překlik na špatném řádku proto stojí
    // za jedno potvrzení.
    if (!window.confirm(
      `Vystavit fakturu${popis ? ` — ${popis}` : ''}?\n\n`
      + 'Doklad dostane číslo a už nepůjde změnit ani smazat.'
    )) return;
    try {
      const v = await issue(id);
      toast({
        title: `Faktura ${v.cislo} vystavena`,
        description: `K úhradě ${fmtKc(Number(v.total_rounded))}, splatnost ${den(v.datum_splatnosti)}.`,
      });
    } catch (e) {
      // Hláška z databáze je česká a konkrétní („chybí: IČO dodavatele“) —
      // ukazuje se tak, jak přišla, protože přesně ta říká, co má admin doplnit.
      toast({ title: 'Fakturu nelze vystavit', description: (e as Error).message, variant: 'destructive' });
    }
  };

  const zahod = async (id: string) => {
    try {
      const uvolneno = await deleteDraft(id);
      toast({
        title: 'Koncept zahozen',
        description: `Uvolnilo se ${uvolneno} rezervací — půjdou vyfakturovat znovu.`,
      });
      if (detailId === id) setDetailId(null);
    } catch (e) {
      toast({ title: 'Nepovedlo se', description: (e as Error).message, variant: 'destructive' });
    }
  };

  const tisk = () => {
    if (!detail) return;
    if (!openInvoicePrint(detail.invoice, detail.items)) {
      toast({
        title: 'Okno se neotevřelo',
        description: 'Prohlížeč zablokoval vyskakovací okno — povolte ho pro tuto stránku a zkuste znovu.',
        variant: 'destructive',
      });
    }
  };

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div>
        <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2">
          <FileText className="h-6 w-6" /> Faktury
        </h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          Doklady za pronájem ledu. Koncept se dá zkontrolovat a teprve pak vystavit —
          číslo se přiděluje až vystavením.
        </p>
      </div>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between gap-3 space-y-0">
          <CardTitle className="text-base flex items-center gap-2">
            <Scale className="h-4 w-4" aria-hidden="true" /> Kontrolní součet
          </CardTitle>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="icon" aria-label="Předchozí měsíc"
                    onClick={() => setMesic((m) => subMonths(m, 1))}>
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <span className="min-w-32 text-center text-sm font-medium capitalize">
              {format(mesic, 'LLLL yyyy', { locale: cs })}
            </span>
            <Button variant="outline" size="icon" aria-label="Další měsíc"
                    onClick={() => setMesic((m) => addMonths(m, 1))}>
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </CardHeader>
        <CardContent className="space-y-3">
          {/* Akceptační kritérium Etapy 2 na obrazovce. Verdikt je schválně první
              věc, kterou je vidět: rozpad po subjektech je až vysvětlení, proč
              zrovna nesedí. */}
          {soucetLoading ? (
            <div className="text-muted-foreground">Načítám…</div>
          ) : soucet.length === 0 ? (
            <div className="text-muted-foreground text-sm">V tomto měsíci nejsou žádné účtovatelné rezervace.</div>
          ) : nesedi.length === 0 ? (
            <div className="flex items-center gap-2 rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-900">
              <Check className="h-4 w-4 shrink-0" aria-hidden="true" />
              <span>
                Sedí to. Suma vystavených faktur odpovídá tomu, co ukazuje „Kdo dluží",
                u všech {soucet.length} subjektů.
              </span>
            </div>
          ) : (
            <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
              <span>
                <b>Nesedí u {nesedi.length} {nesedi.length === 1 ? 'subjektu' : 'subjektů'}.</b>{' '}
                Rozdíl znamená, že se doklad rozešel s rezervacemi — nefakturuj dál
                a nejdřív to dohledej.
              </span>
            </div>
          )}

          {soucet.length > 0 && (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Subjekt</TableHead>
                  <TableHead className="text-right">Fakturováno</TableHead>
                  <TableHead className="text-right">V konceptu</TableHead>
                  <TableHead className="text-right">K fakturaci</TableHead>
                  <TableHead className="text-right">Neschválené</TableHead>
                  <TableHead className="text-right">Dluží</TableHead>
                  <TableHead className="text-right">Rozdíl</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {soucet.map((r) => (
                  <TableRow key={r.subject_id}>
                    <TableCell className="font-medium">{r.subjekt}</TableCell>
                    <TableCell className="text-right">{fmtKc(Number(r.fakturovano))}</TableCell>
                    <TableCell className="text-right">{fmtKc(Number(r.v_konceptu))}</TableCell>
                    <TableCell className="text-right">{fmtKc(Number(r.k_fakturaci))}</TableCell>
                    <TableCell className="text-right">{fmtKc(Number(r.neschvalene))}</TableCell>
                    <TableCell className="text-right font-semibold">{fmtKc(Number(r.dluzi))}</TableCell>
                    <TableCell className={`text-right ${Number(r.rozdil) !== 0 ? 'font-bold text-destructive' : ''}`}>
                      {fmtKc(Number(r.rozdil))}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          <p className="text-xs text-muted-foreground">
            Neschválené rezervace se nefakturují (rozhodnutí PM), proto jsou ve „Dluží"
            a zároveň mimo „Fakturováno" — rozdíl to ale dělat nesmí.
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle className="text-base">Přehled dokladů</CardTitle></CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="text-muted-foreground">Načítám…</div>
          ) : error ? (
            <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
              <span>Faktury se nepodařilo načíst: {error.message}</span>
            </div>
          ) : invoices.length === 0 ? (
            <div className="text-muted-foreground text-sm">
              Zatím tu není žádná faktura. Vygeneruj ji v „Kdo dluží" tlačítkem u subjektu.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Číslo</TableHead>
                  <TableHead>Odběratel</TableHead>
                  <TableHead>Období</TableHead>
                  <TableHead>Splatnost</TableHead>
                  <TableHead className="text-right">K úhradě</TableHead>
                  <TableHead>Stav</TableHead>
                  <TableHead className="text-right">Akce</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {invoices.map((f) => (
                  <TableRow
                    key={f.id}
                    className="cursor-pointer"
                    onClick={() => setDetailId(f.id)}
                  >
                    <TableCell className="font-medium">{f.cislo ?? '—'}</TableCell>
                    <TableCell>
                      {f.odberatel}
                      {/* `kind` je typ DOKLADU (souhrnná za období vs. za akci),
                          ne typ odběratele — firma může dostat obojí. Štítek
                          „Klub / Komerční" by u souhrnné faktury firmě lhal. */}
                      <Badge variant="outline" className="ml-2">
                        {f.kind === 'klub' ? 'Souhrnná' : 'Za akci'}
                      </Badge>
                    </TableCell>
                    <TableCell className="whitespace-nowrap">{den(f.obdobi_od)} – {den(f.obdobi_do)}</TableCell>
                    <TableCell className="whitespace-nowrap">{den(f.datum_splatnosti)}</TableCell>
                    <TableCell className="text-right font-semibold">{fmtKc(Number(f.total_rounded ?? 0))}</TableCell>
                    <TableCell><StavBadge stav={f.status ?? ''} poSplatnosti={f.po_splatnosti} /></TableCell>
                    <TableCell className="text-right">
                      {/* stopPropagation: řádek otevírá detail, tlačítka dělají něco jiného */}
                      <div className="flex justify-end gap-1" onClick={(e) => e.stopPropagation()}>
                        {f.status === 'koncept' && (
                          <>
                            <Button size="sm" disabled={isBusy} onClick={() => vystav(f.id!, `${f.odberatel} · ${fmtKc(Number(f.total_rounded ?? 0))}`)}>
                              <Check className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Vystavit
                            </Button>
                            <Button
                              size="sm" variant="outline" disabled={isBusy}
                              aria-label={`Zahodit koncept ${f.odberatel}`}
                              onClick={() => zahod(f.id!)}
                            >
                              <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
                            </Button>
                          </>
                        )}
                        <Button size="sm" variant="outline" onClick={() => setDetailId(f.id)}>
                          Detail
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Dialog open={!!detailId} onOpenChange={(o) => !o && setDetailId(null)}>
        <DialogContent className="max-w-3xl max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>
              {detail?.invoice.cislo ? `Faktura č. ${detail.invoice.cislo}` : 'Koncept faktury'}
            </DialogTitle>
          </DialogHeader>

          {detailLoading || !detail ? (
            <div className="text-muted-foreground">Načítám…</div>
          ) : (
            <div className="space-y-4">
              {detail.invoice.status === 'koncept' && (
                <div className="flex items-start gap-2 rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
                  <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                  <span>
                    Koncept ještě není doklad — nemá číslo a údaje dodavatele se do něj
                    doplní až vystavením. Do té doby drží rezervace, takže se nedají
                    vyfakturovat znovu.
                  </span>
                </div>
              )}

              <div className="grid gap-4 sm:grid-cols-2 text-sm">
                <div>
                  <div className="text-xs uppercase text-muted-foreground">Dodavatel</div>
                  <div className="font-semibold">{detail.invoice.dodavatel_nazev ?? '— doplní se vystavením —'}</div>
                  {detail.invoice.dodavatel_adresa && <div>{detail.invoice.dodavatel_adresa}</div>}
                  {detail.invoice.dodavatel_ico && <div>IČO: {detail.invoice.dodavatel_ico}</div>}
                </div>
                <div>
                  <div className="text-xs uppercase text-muted-foreground">Odběratel</div>
                  <div className="font-semibold">{detail.invoice.odberatel_nazev ?? '— doplní se vystavením —'}</div>
                  {detail.invoice.odberatel_adresa && <div>{detail.invoice.odberatel_adresa}</div>}
                  {detail.invoice.odberatel_ico && <div>IČO: {detail.invoice.odberatel_ico}</div>}
                </div>
              </div>

              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Datum</TableHead>
                    <TableHead>Popis</TableHead>
                    <TableHead className="text-right">Hodiny</TableHead>
                    <TableHead className="text-right">Sazba</TableHead>
                    <TableHead className="text-right">Cena</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {detail.items.map((it) => (
                    <TableRow key={it.id}>
                      <TableCell className="whitespace-nowrap">
                        {den(it.datum)}
                        {it.cas_od && it.cas_do && (
                          <span className="ml-1 text-muted-foreground">
                            {format(new Date(it.cas_od), 'HH:mm')}–{format(new Date(it.cas_do), 'HH:mm')}
                          </span>
                        )}
                      </TableCell>
                      <TableCell>{it.popis}</TableCell>
                      <TableCell className="text-right">{fmtHodin(Number(it.hodiny))}</TableCell>
                      <TableCell className="text-right">{fmtSazba(Number(it.sazba))}</TableCell>
                      <TableCell className="text-right font-medium">{fmtKc(Number(it.line_total))}</TableCell>
                    </TableRow>
                  ))}
                  {/* Mezisoučet a zaokrouhlení se BEROU z faktury, nepočítají se znovu:
                      dopočítal je trigger v databázi z položek, takže druhý výpočet
                      v prohlížeči by byl druhá peněžní politika vedle money.ts. */}
                  <TableRow>
                    <TableCell colSpan={4} className="text-right text-muted-foreground">Mezisoučet</TableCell>
                    <TableCell className="text-right">{fmtKc(Number(detail.invoice.subtotal))}</TableCell>
                  </TableRow>
                  {Number(detail.invoice.rounding_amount) !== 0 && (
                    <TableRow>
                      <TableCell colSpan={4} className="text-right text-muted-foreground">Zaokrouhlení</TableCell>
                      <TableCell className="text-right">{fmtKc(Number(detail.invoice.rounding_amount))}</TableCell>
                    </TableRow>
                  )}
                  <TableRow>
                    <TableCell colSpan={4} className="text-right font-bold">Celkem k úhradě</TableCell>
                    <TableCell className="text-right font-bold">{fmtKc(Number(detail.invoice.total_rounded))}</TableCell>
                  </TableRow>
                </TableBody>
              </Table>

              <div className="flex flex-wrap gap-2">
                {detail.invoice.status === 'koncept' ? (
                  <>
                    <Button
                      disabled={isBusy}
                      onClick={() => vystav(
                        detail.invoice.id,
                        `${detail.invoice.odberatel_nazev ?? ''} · ${fmtKc(Number(detail.invoice.total_rounded))}`,
                      )}
                    >
                      <Check className="mr-1 h-4 w-4" aria-hidden="true" /> Vystavit fakturu
                    </Button>
                    <Button
                      variant="outline" disabled={isBusy}
                      onClick={() => zahod(detail.invoice.id)}
                    >
                      <Trash2 className="mr-1 h-4 w-4" aria-hidden="true" /> Zahodit koncept
                    </Button>
                  </>
                ) : (
                  <Button variant="outline" onClick={tisk}>
                    <Printer className="mr-1 h-4 w-4" aria-hidden="true" /> Tisk / uložit jako PDF
                  </Button>
                )}
              </div>

              <div className="text-xs text-muted-foreground">
                Stav: {STAV_POPIS[detail.invoice.status ?? ''] ?? detail.invoice.status}
                {detail.invoice.datum_vystaveni && ` · vystaveno ${den(detail.invoice.datum_vystaveni)}`}
                {detail.invoice.datum_splatnosti && ` · splatnost ${den(detail.invoice.datum_splatnosti)}`}
                {detail.invoice.variabilni_symbol && ` · VS ${detail.invoice.variabilni_symbol}`}
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Invoices;
