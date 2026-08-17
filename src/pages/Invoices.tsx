import { useMemo, useState } from 'react';
import { addMonths, endOfMonth, format, startOfMonth, subMonths } from 'date-fns';
import { cs } from 'date-fns/locale';
import {
  FileText, Printer, Trash2, Check, AlertTriangle, ChevronLeft, ChevronRight, Scale,
  Banknote, Undo2, FileMinus, Download, Loader2, RefreshCw,
} from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useAuth } from '@/contexts/AuthContext';
import { denZDb, dnesPrahaProInput } from '@/lib/datum';
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

/**
 * Štítek stavu klientovým slovníkem: nezaplaceno / zaplaceno / po splatnosti.
 *
 * „Vystaveno" v databázi a „nezaplaceno" na obrazovce jsou totéž — jen se na to
 * dívá jednou účetní a jednou člověk, který chce vědět, jestli přišly peníze.
 * „Po splatnosti" zůstává ODVOZENÝ stav (spec, bod 9), ne hodnota v databázi,
 * a počítá se jen u nezaplacených: zaplacená faktura po splatnosti už po
 * splatnosti není, byla zaplacena pozdě.
 */
const StavBadge = ({ stav, poSplatnosti, opravny }: {
  stav: string; poSplatnosti: boolean | null; opravny?: boolean;
}) => {
  // Opravný doklad má vlastní štítek dřív než stav: v seznamu je to jinak
  // k nerozeznání od běžné vystavené faktury, tedy od druhé výzvy k zaplacení.
  if (opravny) return <Badge variant="outline">Opravný doklad</Badge>;
  if (stav === 'koncept') return <Badge variant="secondary">Koncept</Badge>;
  if (stav === 'stornovano') return <Badge variant="outline">Stornováno</Badge>;
  if (stav === 'zaplaceno') {
    return <Badge className="border-emerald-300 bg-emerald-100 text-emerald-900 hover:bg-emerald-100">Zaplaceno</Badge>;
  }
  if (poSplatnosti) return <Badge variant="destructive">Po splatnosti</Badge>;
  return <Badge className="border-amber-300 bg-amber-100 text-amber-900 hover:bg-amber-100">Nezaplaceno</Badge>;
};



/**
 * Stav serverového PDF. Tři různé situace vypadaly na obrazovce stejně — jako
 * „chybí odkaz" — a první pomalý render se pak čte jako rozbitá aplikace.
 */
const PdfStav = ({ stav, chyba }: { stav: string | null; chyba: string | null }) => {
  if (stav === 'ready') return null;   // hotové PDF se pozná podle tlačítka Stáhnout
  if (stav === 'failed') {
    return (
      <span className="inline-flex items-center gap-1 text-xs text-destructive" title={chyba ?? undefined}>
        <AlertTriangle className="h-3 w-3" aria-hidden="true" /> PDF selhalo
      </span>
    );
  }
  if (stav === 'pending' || stav === 'generating') {
    return (
      <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
        <Loader2 className="h-3 w-3 animate-spin" aria-hidden="true" /> PDF se generuje
      </span>
    );
  }
  return null;
};

const Invoices = () => {
  const { isAdmin } = useAuth();
  const { toast } = useToast();
  const { invoices, isLoading, error, issue, deleteDraft, markPaid, unmarkPaid,
          storno: stornoInvoice, stahnoutPdf, znovuPdf, isBusy } = useInvoices();
  const [detailId, setDetailId] = useState<string | null>(null);
  const [platba, setPlatba] = useState<{ id: string; popis: string } | null>(null);
  const [datumUhrady, setDatumUhrady] = useState(dnesPrahaProInput);
  const [storno, setStorno] = useState<
    { id: string; cislo: string; odberatel: string; castka: number } | null>(null);
  const [stornoDuvod, setStornoDuvod] = useState('');
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

  const otevriPlatbu = (id: string, popis: string) => {
    setDatumUhrady(dnesPrahaProInput());   // vždy dnešek, ať se nezdědí datum z minulé faktury
    setPlatba({ id, popis });
  };

  const zapisPlatbu = async () => {
    if (!platba) return;
    try {
      const v = await markPaid({ invoiceId: platba.id, datum: datumUhrady });
      setPlatba(null);
      toast({ title: `Faktura ${v.cislo} označena jako zaplacená`, description: `Datum úhrady ${den(v.datum_uhrady)}.` });
    } catch (e) {
      // Hláška z databáze je konkrétní („úhrada nemůže být dřív, než byl doklad
      // vystavený"), takže se ukazuje tak, jak přišla.
      toast({ title: 'Úhradu nelze zapsat', description: (e as Error).message, variant: 'destructive' });
    }
  };

  const otevriStorno = (id: string, cislo: string, odberatel: string, castka: number) => {
    setStornoDuvod('');
    setStorno({ id, cislo, odberatel, castka });
  };

  const provedStorno = async () => {
    if (!storno) return;
    try {
      const v = await stornoInvoice({ invoiceId: storno.id, duvod: stornoDuvod.trim() || undefined });
      setStorno(null);
      if (detailId === storno.id) setDetailId(null);
      toast({
        title: `Doklad ${v.stornovane_cislo} stornován`,
        // Číslo opravného dokladu je to, co admin potřebuje dál (posílá ho
        // odběrateli), a počet uvolněných rezervací říká, co se vrátilo k fakturaci.
        description: `Vystaven opravný doklad ${v.opravny_cislo} na ${fmtKc(Number(v.castka))}. `
          + `Uvolnilo se ${v.uvolneno_rezervaci} rezervací — půjdou vyfakturovat znovu.`,
      });
    } catch (e) {
      toast({ title: 'Storno se nepovedlo', description: (e as Error).message, variant: 'destructive' });
    }
  };

  const stahni = async (id: string) => {
    try {
      const odkaz = await stahnoutPdf(id);
      // Nové okno, ne `location.href`: podepsaná URL vede na stažení souboru
      // a přesměrování celé stránky by adminovi zahodilo rozdělanou práci.
      window.open(odkaz, '_blank', 'noopener');
    } catch (e) {
      toast({
        title: 'PDF zatím není',
        // Hláška z funkce je konkrétní („PDF se ještě generuje…") a rovnou
        // nabízí náhradní cestu, tak se ukazuje tak, jak přišla.
        description: (e as Error).message,
        variant: 'destructive',
      });
    }
  };

  const zkusZnovu = async (id: string, cislo: string) => {
    try {
      await znovuPdf(id);
      toast({ title: `Doklad ${cislo} je zpátky ve frontě`, description: 'Generování se spustí při dalším běhu.' });
    } catch (e) {
      toast({ title: 'Nepovedlo se', description: (e as Error).message, variant: 'destructive' });
    }
  };

  const zrusPlatbu = async (id: string, popis: string) => {
    if (!window.confirm(`Zrušit označení úhrady${popis ? ` — ${popis}` : ''}?\n\nFaktura se vrátí mezi nezaplacené.`)) return;
    try {
      await unmarkPaid(id);
      toast({ title: 'Označení úhrady zrušeno' });
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
                Sedí to. Suma vystavených faktur odpovídá tomu, co ukazuje „Přehled fakturace",
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
              Zatím tu není žádná faktura. Vygeneruj ji tlačítkem u subjektu
              v „Přehledu fakturace" — tam jsou nevyfakturované hodiny.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Číslo</TableHead>
                  <TableHead>Odběratel</TableHead>
                  <TableHead>Období</TableHead>
                  <TableHead>Splatnost</TableHead>
                  <TableHead>Uhrazeno</TableHead>
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
                    <TableCell className="whitespace-nowrap">{den(f.datum_uhrady)}</TableCell>
                    <TableCell className="text-right font-semibold">{fmtKc(Number(f.total_rounded ?? 0))}</TableCell>
                    <TableCell><div className="space-y-1">
                        <StavBadge stav={f.status ?? ''} poSplatnosti={f.po_splatnosti} opravny={!!f.opravuje_id} />
                        <div><PdfStav stav={f.pdf_status} chyba={f.pdf_error} /></div>
                      </div></TableCell>
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
                        {f.status === 'vystaveno' && (
                          <Button
                            size="sm" variant="outline" disabled={isBusy}
                            aria-label={`Označit jako zaplaceno — ${f.odberatel}`}
                            onClick={() => otevriPlatbu(f.id!, `${f.cislo ?? ''} · ${f.odberatel}`)}
                          >
                            <Banknote className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Označit zaplaceno
                          </Button>
                        )}
                        {f.status === 'zaplaceno' && (
                          <Button
                            size="sm" variant="ghost" disabled={isBusy}
                            aria-label={`Zrušit označení úhrady — ${f.odberatel}`}
                            onClick={() => zrusPlatbu(f.id!, `${f.cislo ?? ''} · ${f.odberatel}`)}
                          >
                            <Undo2 className="h-3.5 w-3.5" aria-hidden="true" />
                          </Button>
                        )}
                        {/* Storno jde i u ZAPLACENÉ faktury (rozhodnutí PM) — omylem
                            zaplacený doklad je přesně ten případ, kdy je potřeba. */}
                        {(f.status === 'vystaveno' || f.status === 'zaplaceno') && !f.opravuje_id && (
                          <Button
                            size="sm" variant="ghost" disabled={isBusy}
                            aria-label={`Stornovat doklad ${f.cislo ?? ''} — ${f.odberatel}`}
                            onClick={() => otevriStorno(f.id!, f.cislo ?? '', f.odberatel ?? '',
                                                        Number(f.total_rounded ?? 0))}
                          >
                            <FileMinus className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Stornovat
                          </Button>
                        )}
                        {f.pdf_status === 'ready' && (
                          <Button size="sm" variant="outline" disabled={isBusy}
                                  aria-label={`Stáhnout PDF dokladu ${f.cislo ?? ''}`}
                                  onClick={() => stahni(f.id!)}>
                            <Download className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> PDF
                          </Button>
                        )}
                        {f.pdf_status === 'failed' && (
                          <Button size="sm" variant="ghost" disabled={isBusy}
                                  aria-label={`Zkusit vygenerovat PDF dokladu ${f.cislo ?? ''} znovu`}
                                  onClick={() => zkusZnovu(f.id!, f.cislo ?? '')}>
                            <RefreshCw className="h-3.5 w-3.5" aria-hidden="true" />
                          </Button>
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

      <Dialog open={!!storno} onOpenChange={(o) => !o && setStorno(null)}>
        <DialogContent className="max-w-md">
          <DialogHeader><DialogTitle>Stornovat doklad</DialogTitle></DialogHeader>
          <p className="text-sm text-muted-foreground">
            {storno?.cislo} · {storno?.odberatel} · {fmtKc(storno?.castka ?? 0)}
          </p>
          {/* Co se stane, řečeno dopředu. Storno není mazání a admin musí vědět,
              že mu vznikne DRUHÝ doklad s vlastním číslem, který se posílá dál. */}
          <div className="rounded-md border bg-muted/40 p-3 text-sm space-y-1">
            <p>Vystaví se <strong>opravný doklad</strong> na tutéž částku, s vlastním číslem.</p>
            <p>Původní faktura zůstane v přehledu jako <strong>stornovaná</strong> — nemaže se.</p>
            <p>Rezervace se <strong>uvolní</strong> a půjdou vyfakturovat znovu.</p>
          </div>
          <div className="space-y-2">
            <Label htmlFor="storno-duvod">Důvod storna</Label>
            <Input
              id="storno-duvod"
              value={stornoDuvod}
              placeholder="Např. klub akci odvolal"
              onChange={(e) => setStornoDuvod(e.target.value)}
            />
            <p className="text-xs text-muted-foreground">
              Nepovinný, ale za půl roku se ptá právě na tohle. Zapíše se na opravný doklad.
            </p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setStorno(null)}>Zrušit</Button>
            <Button variant="destructive" disabled={isBusy} onClick={provedStorno}>
              <FileMinus className="mr-1 h-4 w-4" aria-hidden="true" /> Stornovat doklad
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={!!platba} onOpenChange={(o) => !o && setPlatba(null)}>
        <DialogContent className="max-w-md">
          <DialogHeader><DialogTitle>Označit jako zaplaceno</DialogTitle></DialogHeader>
          <p className="text-sm text-muted-foreground">{platba?.popis}</p>
          <div className="space-y-2">
            <Label htmlFor="datum-uhrady">Datum úhrady</Label>
            <Input
              id="datum-uhrady"
              type="date"
              value={datumUhrady}
              max={dnesPrahaProInput()}
              onChange={(e) => setDatumUhrady(e.target.value)}
            />
            <p className="text-xs text-muted-foreground">
              Datum z bankovního výpisu. Nemůže být v budoucnosti ani dřív, než byl
              doklad vystavený — hlídá to databáze.
            </p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPlatba(null)}>Zrušit</Button>
            <Button disabled={isBusy || !datumUhrady} onClick={zapisPlatbu}>
              <Check className="mr-1 h-4 w-4" aria-hidden="true" /> Zapsat úhradu
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

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
                  <>
                    {/* DVĚ CESTY K DOKLADU, obě zůstávají. Serverové PDF je to,
                        co umí i automatika bez člověka u obrazovky; tisk je
                        záložka pro chvíli, kdy fronta stojí nebo render selhal.
                        Fallback se ruší až po prokliknutí na betě (PM 18. 8.). */}
                    {detail.invoice.pdf_status === 'ready' && (
                      <Button variant="outline" disabled={isBusy}
                              onClick={() => stahni(detail.invoice.id)}>
                        <Download className="mr-1 h-4 w-4" aria-hidden="true" /> Stáhnout PDF
                      </Button>
                    )}
                    <Button variant="outline" onClick={tisk}>
                      <Printer className="mr-1 h-4 w-4" aria-hidden="true" />
                      {detail.invoice.pdf_status === 'ready' ? 'Tisk z obrazovky' : 'Tisk / uložit jako PDF'}
                    </Button>
                    {detail.invoice.status === 'vystaveno' && (
                      <Button
                        disabled={isBusy}
                        onClick={() => otevriPlatbu(
                          detail.invoice.id,
                          `${detail.invoice.cislo ?? ''} · ${detail.invoice.odberatel_nazev ?? ''}`,
                        )}
                      >
                        <Banknote className="mr-1 h-4 w-4" aria-hidden="true" /> Označit jako zaplaceno
                      </Button>
                    )}
                    {detail.invoice.status === 'zaplaceno' && (
                      <Button
                        variant="outline" disabled={isBusy}
                        onClick={() => zrusPlatbu(
                          detail.invoice.id,
                          `${detail.invoice.cislo ?? ''} · ${detail.invoice.odberatel_nazev ?? ''}`,
                        )}
                      >
                        <Undo2 className="mr-1 h-4 w-4" aria-hidden="true" /> Zrušit označení úhrady
                      </Button>
                    )}
                  </>
                )}
              </div>

              <div className="text-xs text-muted-foreground">
                Stav: {STAV_POPIS[detail.invoice.status ?? ''] ?? detail.invoice.status}
                {detail.invoice.datum_vystaveni && ` · vystaveno ${den(detail.invoice.datum_vystaveni)}`}
                {detail.invoice.datum_splatnosti && ` · splatnost ${den(detail.invoice.datum_splatnosti)}`}
                {detail.invoice.variabilni_symbol && ` · VS ${detail.invoice.variabilni_symbol}`}
                {detail.invoice.datum_uhrady && ` · uhrazeno ${den(detail.invoice.datum_uhrady)}`}
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Invoices;
