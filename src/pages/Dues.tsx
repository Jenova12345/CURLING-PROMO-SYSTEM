import { useMemo, useState } from 'react';
import {
  format, startOfDay, addDays, subDays, startOfWeek, addWeeks, subWeeks,
  startOfMonth, endOfMonth, addMonths, subMonths,
} from 'date-fns';
import { cs } from 'date-fns/locale';
import {
  ChevronLeft, ChevronRight, Wallet, FileText, Receipt, ExternalLink, AlertTriangle, Check, Scale,
} from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useAuth } from '@/contexts/AuthContext';
import { useDues } from '@/hooks/useDues';
import { useToast } from '@/components/ui/use-toast';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { openInvoiceDraft } from '@/lib/invoiceDraft';
import { fmtHodin as fmtH, fmtKc } from '@/lib/money';
import { useBillingSettings } from '@/hooks/useBillingSettings';
import { useBillingReconcile } from '@/hooks/useInvoices';
import {
  useFakturoid, FakturoidNejistaChyba,
  type FakturoidPozadavek, type FakturoidVysledek, type FakturoidVarovani,
} from '@/hooks/useFakturoid';
import { supabase } from '@/integrations/supabase/client';
import { denZDb } from '@/lib/datum';

type View = 'day' | 'week' | 'month';

/**
 * Co u komerčního odběratele čeká na fakturu. `event_id = null` je zvláštní řádek
 * „rezervace bez akce" — ty se fakturují souhrnně za období, ne za akci, a bez
 * něj byly nevyfakturovatelné vůbec (dialog je přes akce neviděl).
 */
type NevyfakturovanaAkce = { event_id: string | null; nazev: string; den: string; rezervaci: number; castka: number };

/**
 * Co se chystá vystavit, dokud to admin nepotvrdí.
 *
 * `presna` říká, jestli je `castka` to, co doopravdy půjde na doklad. U akce
 * ano — `nevyfakturovane_akce` od migrace 20260915110000 vrací totéž co
 * `fakturoid_podklady_akce`. U klubu NE: přehled sčítá všechny zpoplatněné
 * rezervace období, kdežto na doklad jdou jen schválené a dosud nevyfakturované.
 * Tvářit se v dialogu jistě by znamenalo nechat admina odklepnout číslo,
 * které na dokladu neuvidí.
 */
type KPotvrzeni = {
  pozadavek: FakturoidPozadavek;
  odberatel: string;
  cemu: string;
  rezervaci: number | null;
  castka: number | null;
  presna: boolean;
};

const Dues = () => {
  const { isAdmin } = useAuth();
  const { toast } = useToast();
  const { doklady, nacitamDoklady, chybaDokladu, vystavit, vystavuje } = useFakturoid();
  // Podklad tiskne údaje haly z nastavení, ne z `BRAND` (riziko 5 v plánu):
  // doklad má ukazovat, co je nastavené, ne co je zadrátované ve frontendu.
  const {
    settings: fakturacniUdaje,
    isLoading: nacitamUdaje,
    error: chybaUdaju,
  } = useBillingSettings();
  const [akce, setAkce] = useState<{ subjectId: string; name: string; polozky: NevyfakturovanaAkce[] } | null>(null);
  const [nacitamAkce, setNacitamAkce] = useState<string | null>(null);
  const [potvrzeni, setPotvrzeni] = useState<KPotvrzeni | null>(null);
  /**
   * Doklad u Fakturoidu existuje, ale nesedí s naším podkladem. SCHVÁLNĚ TO
   * NENÍ TOAST: rozdíl mezi dokladem a podkladem patří člověku a toast po pár
   * vteřinách zmizí i s jediným vodítkem, podle kterého se dá dohledat.
   */
  const [nesedi, setNesedi] = useState<{ cislo: string | null; duvod: string } | null>(null);
  const [varovani, setVarovani] = useState<FakturoidVarovani[]>([]);
  const [view, setView] = useState<View>('month');
  const [currentDate, setCurrentDate] = useState(() => startOfDay(new Date()));

  /**
   * KONTROLNÍ SOUČET MÁ VLASTNÍ MĚSÍC, NE OBDOBÍ TÉHLE STRÁNKY.
   *
   * Je to rozhodnutí přenesené beze změny ze stránky Faktury, odkud se sem
   * kontrolní součet 16. 9. 2026 přestěhoval — a po přesunu platí ještě víc,
   * protože přepínač období je teď kousek nad ním.
   *
   * Důvod je věcný, ne kosmetický: tohle je kontrola ÚČETNÍHO OBDOBÍ. Kdyby
   * se navázal na přepínač Den/Týden/Měsíc, šel by zobrazit kontrolní součet
   * za JEDEN DEN — a `fakturoid_rozdil` by pak byl nenulový skoro pokaždé,
   * protože doklad zní na celý měsíc, ale do jednoho dne spadne jen část jeho
   * rezervací. Přesně tu druhou příčinu popisuje nápověda pod tabulkou.
   * Vyrábělo by to falešné poplachy u brány, která má křičet jen doopravdy.
   */
  const [mesic, setMesic] = useState(() => startOfMonth(new Date()));
  const obdobiSouctu = useMemo(() => ({
    from: format(startOfMonth(mesic), 'yyyy-MM-dd'),
    to: format(endOfMonth(mesic), 'yyyy-MM-dd'),
  }), [mesic]);
  const { data: soucet = [], isLoading: soucetLoading } = useBillingReconcile(obdobiSouctu);

  // POČÍTÁ SE I `fakturoid_rozdil`, ne jen `rozdil`.
  //
  // Jsou to dvě různé otázky a ani jedna druhou nezastoupí:
  //   `rozdil`           … sedí součet rezervací s tím, co za subjekt drží doklady?
  //   `fakturoid_rozdil` … sedí částka NA fakturoidím dokladu s rezervacemi, které nese?
  // Doklad může mít správného příjemce a špatnou částku — pak je `rozdil` nula
  // a rozejde se jen ten druhý. Kdyby se tu hlídal jen `rozdil`, svítil by nad
  // červenou buňkou zelený banner „Sedí to." — a to je přesně ten tichý souhlas,
  // kvůli kterému kontrolní součet existuje.
  // `nesediSoucet`, ne `nesedi` — `nesedi` je už stav panelu u vystavování
  // dokladu (jiná věc, jiný význam) a dvě různé „nesedí" na jedné stránce
  // jsou přesně ten druh záměny, který se pak hledá hodinu.
  const nesediSoucet = soucet.filter((r) => Number(r.rozdil) !== 0 || Number(r.fakturoid_rozdil) !== 0);

  const range = useMemo(() => {
    if (view === 'day') { const f = startOfDay(currentDate); return { from: f.toISOString(), to: addDays(f, 1).toISOString() }; }
    if (view === 'week') { const f = startOfWeek(currentDate, { weekStartsOn: 1 }); return { from: f.toISOString(), to: addDays(f, 7).toISOString() }; }
    return { from: startOfMonth(currentDate).toISOString(), to: startOfMonth(addMonths(currentDate, 1)).toISOString() };
  }, [view, currentDate]);

  const { reservations, summary, subjects, totalAmount, totalHours, isLoading } = useDues(isAdmin ? range : null);

  // Podklad k fakturaci pro jeden subjekt za zobrazené období — otevře se
  // v novém okně jako tisknutelná stránka („Uložit jako PDF"). Nic se neukládá.
  const vystavFakturu = (subjectId: string, subjectName: string) => {
    // Bez tohohle se nevyplněné nastavení nedá odlišit od nenačteného: hook vrací
    // `null` v obou případech, takže by podklad při výpadku sítě tiše spadl na
    // DEMO účet a na dokladu by svítilo „v nastavení nic není" — což by nebyla
    // pravda a admin by to hledal na špatném místě.
    if (chybaUdaju) {
      toast({
        title: 'Fakturační údaje se nenačetly',
        description: 'Podklad by vyšel s vymyšleným účtem. Zkus to prosím znovu.',
        variant: 'destructive',
      });
      return;
    }
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
      billing: fakturacniUdaje,
    });
    if (!otevreno) {
      toast({
        title: 'Okno se neotevřelo',
        description: 'Prohlížeč zablokoval vyskakovací okno — povolte ho pro tuto stránku a zkuste znovu.',
        variant: 'destructive',
      });
    }
  };

  // Období pro doklad: `range.to` je VÝLUČNÉ (začátek dalšího dne/měsíce), kdežto
  // RPC bere obě data VČETNĚ — proto se od horní meze odečítá den.
  //
  // Datum se skládá přes `format`, ne `toISOString().slice(0, 10)`: to druhé
  // převádí na UTC, takže by v létě z půlnoci 1. srpna udělalo „31. 7." a doklad
  // by měl období o den vedle.
  const obdobi = () => ({
    from: format(new Date(range.from), 'yyyy-MM-dd'),
    to: format(addDays(new Date(range.to), -1), 'yyyy-MM-dd'),
  });

  /**
   * KLUBOVÁ CESTA JDE JEN V MĚSÍČNÍM POHLEDU.
   *
   * Klíč idempotence klubového dokladu je `klub-{subjectId}-{RRRRMM}` a měsíc
   * se bere z počátku období. V týdenním pohledu by se tedy vystavil doklad na
   * JEDEN TÝDEN, ale se zámkem na CELÝ MĚSÍC — a druhý týden téhož měsíce by
   * pak narazil na „doklad už existuje" a nešel by vyfakturovat vůbec.
   * Zavřít to tady je levnější než to potom rozplétat dobropisem.
   */
  const klubovaJde = view === 'month';

  const chystejKlubovou = (subjectId: string, subjectName: string, radek?: { count: number; amount: number }) => {
    const { from, to } = obdobi();
    setPotvrzeni({
      pozadavek: { druh: 'klub', subjectId, obdobiOd: from, obdobiDo: to },
      odberatel: subjectName,
      cemu: `období ${format(new Date(range.from), 'LLLL yyyy', { locale: cs })}`,
      rezervaci: radek?.count ?? null,
      castka: radek?.amount ?? null,
      // Přehled sčítá VŠECHNY zpoplatněné rezervace období; na doklad jdou jen
      // schválené a dosud nevyfakturované. Číslo je tedy horní odhad, ne slib.
      presna: false,
    });
  };

  // Komerční odběratel se fakturuje po akcích, ne za období — proto nabídka.
  const nabidniAkce = async (subjectId: string, subjectName: string) => {
    const { from, to } = obdobi();
    // Vlastní indikace načítání: `vystavuje` z useFakturoid tenhle dotaz nekryje,
    // takže by tlačítko na pomalé síti vypadalo mrtvě.
    setNacitamAkce(subjectId);
    const { data, error } = await supabase.rpc('nevyfakturovane_akce', {
      _subject_id: subjectId, _obdobi_od: from, _obdobi_do: to,
    });
    setNacitamAkce(null);
    if (error) {
      toast({ title: 'Nepovedlo se', description: error.message, variant: 'destructive' });
      return;
    }
    const polozky = (data ?? []) as NevyfakturovanaAkce[];
    if (!polozky.length) {
      toast({ title: 'Není co fakturovat', description: `${subjectName} nemá v období nevyfakturovanou akci.` });
      return;
    }
    setAkce({ subjectId, name: subjectName, polozky });
  };

  const chystejZaAkci = (a: NevyfakturovanaAkce) => {
    if (!akce) return;
    // `event_id = null` znamená „rezervace bez akce" — ty se fakturují souhrnně
    // za období, ne za akci, takže jdou klubovou cestou i u komerčního odběratele
    // (a platí pro ně tentýž měsíční zámek).
    if (a.event_id === null) {
      // ⚠️ SCHVÁLNĚ SE NEPOSÍLAJÍ ČÍSLA TOHOHLE ŘÁDKU.
      //
      // Řádek říká „1 rezervace · 10 000 Kč", ale klubová cesta jde přes
      // `fakturoid_podklady_klub` → `fakturovatelne_rezervace`, a ta se na
      // `event_id` NEPTÁ — vystaví všechny zpoplatněné rezervace subjektu za
      // období, tedy i ty, které patří ke komerčním akcím vypsaným výš.
      // Změřeno: náhled 1 rez./10 000 Kč, server 3 rez./50 000 Kč.
      //
      // Číslo toho řádku by tedy byl slib, který doklad poruší SMĚREM NAHORU —
      // a protože je doklad rovnou ostrý, opravuje se to dobropisem. Posílá se
      // proto souhrn za celý subjekt: totéž, co má klubové tlačítko v tabulce
      // a co admin vidí na téže obrazovce. Je to horní odhad, ne slib.
      const s = summary.find((x) => x.subjectId === akce.subjectId);
      chystejKlubovou(akce.subjectId, akce.name, s ? { count: s.count, amount: s.amount } : undefined);
    } else {
      setPotvrzeni({
        pozadavek: { druh: 'akce', eventId: a.event_id },
        odberatel: akce.name,
        cemu: `akce „${a.nazev}"`,
        rezervaci: a.rezervaci,
        castka: Number(a.castka),
        // U akce náhled od migrace 20260915110000 ukazuje totéž, co půjde
        // na doklad — počet i součet se shodují s `fakturoid_podklady_akce`.
        presna: true,
      });
    }
    setAkce(null);
  };

  /**
   * Jediné místo, odkud se do Fakturoidu opravdu posílá. Všech šest stavů má
   * vlastní reakci — „ať to nespadne tiše" znamená, že žádná větev nesmí
   * skončit mlčky.
   */
  const potvrdAVystav = async () => {
    if (!potvrzeni) return;
    setNesedi(null);
    setVarovani([]);
    try {
      const v: FakturoidVysledek = await vystavit(potvrzeni.pozadavek);
      setPotvrzeni(null);

      switch (v.stav) {
        case 'vystaveno':
        case 'existoval':
          setVarovani(v.varovani);
          toast({
            title: v.stav === 'vystaveno'
              ? `Doklad ${v.cislo ?? ''} vystaven ve Fakturoidu`.trim()
              : `Doklad ${v.cislo ?? ''} už ve Fakturoidu byl`.trim(),
            // `odeslano` SE MUSÍ ČÍST, NE DOMÝŠLET. Režim je serverový
            // (`FAKTUROID_MODE`) a přepnutí na `odeslat` nevyžaduje žádnou
            // změnu frontendu — natvrdo napsané „e-mail se neodeslal" by
            // od toho dne lhalo a admin by fakturu poslal podruhé.
            description: v.stav !== 'vystaveno'
              ? 'Nic nového nevzniklo, doklad na tenhle podklad už existoval.'
              : v.odeslano
                ? 'Doklad byl odeslán e-mailem z Fakturoidu.'
                : 'E-mail se neodeslal — pošli ho z Fakturoidu.',
          });
          break;
        case 'prazdne':
          toast({
            title: 'Není co fakturovat',
            description: 'Všechny rezervace už na dokladu jsou, nebo podklad vyšel na nulu.',
          });
          break;
        case 'preskoceno':
          toast({ title: 'Doklad se nevystavil', description: v.duvod });
          break;
        case 'nesedi':
          // Do panelu, ne do toastu — viz komentář u `setNesedi`.
          setNesedi({ cislo: v.cislo, duvod: v.duvod });
          toast({
            title: 'Doklad nesedí s podkladem',
            description: 'Rozdíl je vypsaný na stránce — projdi ho, prosím, ručně.',
            variant: 'destructive',
          });
          break;
      }
    } catch (e) {
      setPotvrzeni(null);
      const nejiste = e instanceof FakturoidNejistaChyba;
      toast({
        title: nejiste ? 'Nevíme, jestli doklad vznikl' : 'Doklad se nepodařilo vystavit',
        description: (e as Error).message,
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
        <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2"><Wallet className="h-6 w-6" /> Přehled fakturace</h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">Podklady k úhradě podle rezervovaných hodin. Interní (tréninky/údržba) se nepočítají.</p>
      </div>

      {/* ROZDÍL MEZI DOKLADEM A PODKLADEM PATŘÍ ČLOVĚKU.
          Schválně to není toast: `duvod` nese částky a počty řádků, tedy to
          jediné, podle čeho se dá rozdíl dohledat — a toast po pár vteřinách
          zmizí i s ním. Zavře se jedině kliknutím. */}
      {nesedi && (
        <div role="alert" className="rounded-md border border-destructive bg-destructive/10 p-4 space-y-2">
          <div className="flex items-start gap-2">
            <AlertTriangle className="h-5 w-5 shrink-0 text-destructive" aria-hidden="true" />
            <div className="space-y-1">
              <div className="font-semibold text-destructive">
                Doklad {nesedi.cislo ?? ''} u Fakturoidu nesedí s naším podkladem
              </div>
              <p className="text-sm">{nesedi.duvod}</p>
              <p className="text-sm text-muted-foreground">
                Vazba se <b>nezapsala</b> a nic se nevystavilo. Projdi rozdíl ve Fakturoidu ručně —
                automatika ho rozhodnout nemá čím.
              </p>
            </div>
          </div>
          <Button variant="outline" size="sm" onClick={() => setNesedi(null)}>Rozumím, skrýt</Button>
        </div>
      )}

      {/* Varování se ukazují I PO ÚSPĚCHU. Typicky „PDF se nepodařilo uložit" —
          doklad přitom existuje, takže tichý úspěch by lhal. */}
      {varovani.length > 0 && (
        <div role="status" className="rounded-md border border-amber-500/50 bg-amber-500/10 p-4 space-y-2">
          <div className="font-semibold">Doklad vznikl, ale něco se nepovedlo</div>
          <ul className="list-disc pl-5 text-sm">
            {varovani.map((v) => <li key={v.kod}>{v.zprava}</li>)}
          </ul>
          <Button variant="outline" size="sm" onClick={() => setVarovani([])}>Skrýt</Button>
        </div>
      )}

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
                      <div className="flex justify-end gap-1">
                        <Button
                          size="sm"
                          disabled={vystavuje || nacitamAkce === r.subjectId || (r.type === 'club' && !klubovaJde)}
                          title={r.type === 'club' && !klubovaJde
                            ? 'Klubový doklad se vystavuje za celý měsíc — přepni nahoře na „Měsíc".'
                            : undefined}
                          aria-label={`Vystavit ve Fakturoidu — ${r.name}`}
                          onClick={() => r.type === 'club'
                            ? chystejKlubovou(r.subjectId, r.name, { count: r.count, amount: r.amount })
                            : nabidniAkce(r.subjectId, r.name)}
                        >
                          <Receipt className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Vystavit ve Fakturoidu
                        </Button>
                        {/* Podklad zůstává vedle dokladu schválně: vytiskne se za
                            jakékoli období a nic v databázi nevytvoří, takže se hodí
                            na rychlou kontrolu i tam, kde fakturu vystavovat nechceme. */}
                        <Button
                          variant="outline" size="sm" disabled={nacitamUdaje}
                          aria-label={`Podklad k fakturaci — ${r.name}`}
                          onClick={() => vystavFakturu(r.subjectId, r.name)}
                        >
                          <FileText className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Podklad
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
                <TableRow><TableCell colSpan={2} className="font-bold">Celkem</TableCell><TableCell className="text-right font-bold">{fmtH(totalHours)}</TableCell><TableCell className="text-right font-bold">{fmtKc(totalAmount)}</TableCell><TableCell /></TableRow>
              </TableBody>
            </Table>
          )}
          {/* Bez tohohle je rozdíl mezi číslem u tlačítka a částkou na konceptu
              nevysvětlitelný: tenhle přehled ukazuje VŠECHNY zpoplatněné rezervace
              období, kdežto faktura bere jen schválené a dosud nevyfakturované.
              Přesnou částku má proto až koncept — a od toho je krok „zkontroluj". */}
          {summary.length > 0 && (
            <div className="mt-3 space-y-2 text-xs text-muted-foreground">
              <p>
                Částky výš jsou za všechny zpoplatněné rezervace období. Na doklad jdou
                jen ty <b>schválené</b> a dosud nevyfakturované, takže může být nižší —
                přesnou částku určí až doklad ve Fakturoidu.
              </p>
              {!klubovaJde && (
                <p>
                  <b>Klubový doklad jde vystavit jen v měsíčním pohledu.</b> Vystavuje se
                  za celý kalendářní měsíc; v denním a týdenním pohledu by vznikl doklad
                  za pár dní, ale zamkl by celý měsíc a zbytek by už nešlo vyfakturovat.
                </p>
              )}
            </div>
          )}
        </CardContent>
      </Card>

      <Dialog open={!!akce} onOpenChange={(o) => !o && setAkce(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Faktura za akci — {akce?.name}</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            Komerční odběratel se fakturuje po akcích: jedna akce = jeden doklad.
            Vyber, za kterou akci se má doklad vystavit. Řádek „rezervace bez akce"
            je souhrnný doklad za zobrazené období — a protože se vystavuje po
            měsících, jde jen v měsíčním pohledu.
          </p>
          <div className="space-y-2">
            {akce?.polozky.map((a) => (
              <div key={a.event_id ?? 'bez-akce'} className="flex items-center justify-between gap-3 rounded-md border p-3">
                <div>
                  <div className="font-medium">{a.nazev}</div>
                  <div className="text-xs text-muted-foreground">
                    {format(denZDb(a.den) ?? new Date(), 'd. M. yyyy', { locale: cs })} · {a.rezervaci} rezervací · {fmtKc(Number(a.castka))}
                  </div>
                </div>
                <Button
                  size="sm"
                  disabled={vystavuje || (a.event_id === null && !klubovaJde)}
                  title={a.event_id === null && !klubovaJde
                    ? 'Souhrn za období se vystavuje za celý měsíc — přepni nahoře na „Měsíc".'
                    : undefined}
                  onClick={() => chystejZaAkci(a)}
                >
                  Vystavit
                </Button>
              </div>
            ))}
          </div>
        </DialogContent>
      </Dialog>

      {/* POTVRZENÍ PŘED VYSTAVENÍM.
          Je to poslední místo, kde jde couvnout: doklad u Fakturoidu vzniká
          rovnou ostrý (stav „koncept" Fakturoid nezná) a smazat se nedá. */}
      <Dialog open={!!potvrzeni} onOpenChange={(o) => { if (!o && !vystavuje) setPotvrzeni(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Vystavit doklad ve Fakturoidu?</DialogTitle>
          </DialogHeader>
          {potvrzeni && (
            <div className="space-y-4">
              <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-sm">
                <dt className="text-muted-foreground">Odběratel</dt>
                <dd className="font-medium">{potvrzeni.odberatel}</dd>
                <dt className="text-muted-foreground">Fakturuje se</dt>
                <dd className="font-medium">{potvrzeni.cemu}</dd>
                {potvrzeni.rezervaci != null && (<>
                  <dt className="text-muted-foreground">Rezervací</dt>
                  <dd>{potvrzeni.rezervaci}</dd>
                </>)}
                {potvrzeni.castka != null && (<>
                  <dt className="text-muted-foreground">Částka</dt>
                  <dd className="font-semibold">
                    {fmtKc(potvrzeni.castka)}
                    {!potvrzeni.presna && <span className="ml-1 font-normal text-muted-foreground">(odhad)</span>}
                  </dd>
                </>)}
              </dl>

              {/* U KLUBOVÉ CESTY MUSÍ BÝT VIDĚT ROZSAH, NE JEN ČÁSTKA.
                  Souhrnný měsíční doklad zahrne i rezervace patřící ke KONKRÉTNÍM
                  AKCÍM, které jsou v předchozím dialogu vypsané zvlášť — server
                  se na `event_id` neptá. Bez téhle věty by admin čekal doklad
                  „na zbytek" a dostal doklad na celý měsíc. */}
              {potvrzeni.pozadavek.druh === 'klub' && (
                <p className="text-xs text-muted-foreground">
                  Souhrnný doklad za měsíc zahrne <b>všechny</b> schválené a dosud
                  nevyfakturované rezervace odběratele za toto období — <b>včetně těch,
                  které patří ke konkrétním akcím</b>. Ty se pak už samostatně vyfakturovat
                  nedají. Částka výš je za všechny zpoplatněné rezervace období, takže
                  výsledek může být nižší.
                </p>
              )}

              {/* Znění schválil PM 15. 9. 2026. NEZKRACOVAT: každá z těch čtyř
                  vět odpovídá jedné vlastnosti Fakturoidu, kterou by si člověk
                  jinak domyslel špatně. */}
              <div className="rounded-md border border-amber-500/50 bg-amber-500/10 p-3 text-sm">
                Doklad se vystaví <b>naostro</b> a dostane číslo v ostré řadě, e-mail se
                neodešle, pošleš ho z Fakturoidu, oprava jen stornem/dobropisem.
              </div>
            </div>
          )}
          <div className="flex justify-end gap-2">
            <Button variant="outline" disabled={vystavuje} onClick={() => setPotvrzeni(null)}>Zrušit</Button>
            {/* `disabled={vystavuje}` je ochrana proti DVOJKLIKU. Server by druhý
                klik zachytil až zámkem 3 a vrátil `preskoceno` — duplicita by
                nevznikla, ale admin by dostal matoucí hlášku na vlastní akci. */}
            <Button disabled={vystavuje} onClick={potvrdAVystav}>
              {vystavuje ? 'Vystavuji…' : 'Vystavit ve Fakturoidu'}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      {/* KONTROLNÍ SOUČET — přestěhováno ze stránky Faktury 16. 9. 2026.
          Akceptační kritérium Etapy 2 na obrazovce; po vyřazení interního
          enginu je tohle jediné místo v aplikaci, kde je vidět. */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between gap-3 space-y-0">
          <CardTitle className="text-base flex items-center gap-2">
            <Scale className="h-4 w-4" aria-hidden="true" /> Kontrolní součet
          </CardTitle>
          {/* Vlastní přepínač měsíce — viz komentář u `mesic`. Schválně NEsdílí
              období s přehledem výš: tohle je kontrola účetního období. */}
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
          {/* Verdikt je schválně první věc, kterou je vidět: rozpad po subjektech
              je až vysvětlení, proč zrovna nesedí. */}
          {soucetLoading ? (
            <div className="text-muted-foreground">Načítám…</div>
          ) : soucet.length === 0 ? (
            <div className="text-muted-foreground text-sm">V tomto měsíci nejsou žádné účtovatelné rezervace.</div>
          ) : nesediSoucet.length === 0 ? (
            <div className="flex items-center gap-2 rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-900">
              <Check className="h-4 w-4 shrink-0" aria-hidden="true" />
              <span>
                Sedí to. Suma vystavených faktur odpovídá tomu, co ukazuje „Po subjektech",
                u všech {soucet.length} subjektů.
              </span>
            </div>
          ) : (
            <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
              <span>
                <b>Nesedí u {nesediSoucet.length} {nesediSoucet.length === 1 ? 'subjektu' : 'subjektů'}.</b>{' '}
                Buď se doklad rozešel s rezervacemi, nebo sahá mimo zobrazený měsíc —
                nefakturuj dál a nejdřív to dohledej.
              </span>
            </div>
          )}

          {soucet.length > 0 && (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Subjekt</TableHead>
                    <TableHead className="text-right">Fakturováno</TableHead>
                    <TableHead className="text-right">V konceptu</TableHead>
                    <TableHead className="text-right">Fakturoid</TableHead>
                    <TableHead className="text-right">Rozdíl dokladů</TableHead>
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
                      <TableCell className="text-right">{fmtKc(Number(r.fakturoid))}</TableCell>
                      {/* Zvýrazňuje se stejně jako „Rozdíl" — obojí znamená „nefakturuj dál". */}
                      <TableCell className={`text-right ${Number(r.fakturoid_rozdil) !== 0 ? 'font-bold text-destructive' : ''}`}>
                        {fmtKc(Number(r.fakturoid_rozdil))}
                      </TableCell>
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
            </div>
          )}
          <p className="text-xs text-muted-foreground">
            Neschválené rezervace se nefakturují (rozhodnutí PM), proto jsou ve „Dluží"
            a zároveň mimo „Fakturováno" — rozdíl to ale dělat nesmí.
            {' '}<b>Fakturoid</b> je částka, kterou za subjekt drží doklady vystavené ve
            Fakturoidu; <b>Rozdíl dokladů</b> porovnává částku na dokladu s rezervacemi,
            které nese. Nenulový „Rozdíl dokladů" má dvě možné příčiny a obě se musí
            dohledat: buď se doklad rozešel se svým podkladem, nebo doklad pokrývá
            i rezervace mimo zobrazený měsíc (sečte se celý doklad, ale jen ty
            rezervace, které do měsíce spadnou). Druhý případ poznáš tak, že
            v sestavě za delší období rozdíl zmizí.
          </p>
        </CardContent>
      </Card>

      {/* KROK 4 — co už do Fakturoidu odešlo.
          Bez tohohle seznamu nemá admin po zavření toastu kde zjistit, co
          vystavil. Pohled ukazuje jen DOKONČENÉ doklady (`provider_invoice_id`
          není NULL), takže rozpracovaný claim se tu neobjeví. */}
      <Card>
        <CardHeader><CardTitle className="text-base">Vystaveno ve Fakturoidu</CardTitle></CardHeader>
        <CardContent>
          {nacitamDoklady ? <div className="text-muted-foreground">Načítám…</div> : chybaDokladu ? (
            /* TŘETÍ VĚTEV JE NUTNOST, NE PEČLIVOST. Bez ní by se selhání SELECTu
               (RLS, výpadek sítě) zobrazilo jako „Zatím nebyl vystaven žádný
               doklad." — tedy jako tvrzení o ostré číselné řadě, které nikdo
               neověřil. Radši přiznat, že nevíme. */
            <div role="alert" className="text-sm text-destructive">
              Seznam vystavených dokladů se nepodařilo načíst, takže <b>nevíme</b>, co už odešlo.
              Načti stránku prosím znovu — nebo se podívej přímo do Fakturoidu.
            </div>
          ) : doklady.length === 0 ? (
            <div className="text-muted-foreground text-sm">Zatím nebyl vystaven žádný doklad.</div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader><TableRow>
                  <TableHead>Číslo</TableHead><TableHead>Odběratel</TableHead>
                  <TableHead>Vystaveno</TableHead><TableHead className="text-right">Rezervací</TableHead>
                  <TableHead className="text-right">Částka</TableHead><TableHead className="text-right">Rozdíl</TableHead>
                  <TableHead />
                </TableRow></TableHeader>
                <TableBody>
                  {doklady.map((d) => (
                    <TableRow key={d.id}>
                      <TableCell className="font-medium">{d.cislo ?? '—'}</TableCell>
                      <TableCell>{d.subjekt}</TableCell>
                      <TableCell>{d.vystaveno_at ? format(new Date(d.vystaveno_at), 'd. M. yyyy', { locale: cs }) : '—'}</TableCell>
                      <TableCell className="text-right">{d.rezervaci ?? 0}</TableCell>
                      <TableCell className="text-right">{fmtKc(Number(d.provider_total ?? 0))}</TableCell>
                      {/* `rozdil` je kontrolní součet: co jsme poslali vs. co Fakturoid
                          vytiskl. Nenula se musí poznat na první pohled, ne až v exportu. */}
                      <TableCell className={`text-right ${Number(d.rozdil ?? 0) !== 0 ? 'font-bold text-destructive' : ''}`}>
                        {fmtKc(Number(d.rozdil ?? 0))}
                      </TableCell>
                      <TableCell className="text-right">
                        {/* Jen `https://`. Hodnotu sice zapisuje výhradně
                            `fakturoid_zapis_vazbu` (zavřená přes `fakturoid_smi_volat`),
                            takže se k ní z aplikace nikdo nedostane — ale React 18
                            `javascript:` v `href` propustí s pouhým varováním
                            a tohle je jednořádková pojistka. */}
                        {d.public_url?.startsWith('https://') && (
                          <Button variant="outline" size="sm" asChild>
                            <a href={d.public_url} target="_blank" rel="noopener noreferrer">
                              <ExternalLink className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Otevřít
                            </a>
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
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
