import { Coins, Clock, Info } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useSettings, type OpeningHours } from '@/hooks/useSettings';
import { useCenik, type CenikPasmo } from '@/hooks/useCenik';
import { fmtSazba } from '@/lib/money';

// Pořadí i názvy dnů jsou shodné s Nastavením (`Settings.tsx`) — klíč je ISO
// den v týdnu (1 = pondělí), tak je uložená i `settings.opening_hours`.
const DNY: Array<[string, string]> = [
  ['1', 'Pondělí'], ['2', 'Úterý'], ['3', 'Středa'], ['4', 'Čtvrtek'],
  ['5', 'Pátek'], ['6', 'Sobota'], ['7', 'Neděle'],
];

const SKUPINY: Array<{ typ: CenikPasmo['den_typ']; nadpis: string; popis: string }> = [
  { typ: 'vsedni', nadpis: 'Všední dny', popis: 'Pondělí až pátek' },
  { typ: 'vikend', nadpis: 'Víkend', popis: 'Sobota a neděle' },
];

/** „06:00 – 14:00": pásma jsou v databázi celé hodiny (smallint), minuty ani
 *  sekundy se nezadávají, takže se dopisují natvrdo. Nula vepředu schválně —
 *  ve sloupci pod sebou se čtou zarovnané časy líp než „6:00" a „14:00". */
const pasmoText = (od: number, doH: number) =>
  `${String(od).padStart(2, '0')}:00 – ${String(doH).padStart(2, '0')}:00`;

/**
 * Ceník ledu — stránka JEN KE ČTENÍ pro všechny přihlášené role.
 *
 * Ukazuje dvě věci, obojí veřejné: otevírací dobu (`settings_public.opening_hours`,
 * čitelnou všem odjakživa) a standardní pásmový ceník (`cenik_pasma_public`,
 * otevřený migrací 20260914140000).
 *
 * CO SEM NEPATŘÍ a proč: komerční sazba, klubové výchozí sazby ani individuálně
 * sjednané sazby klubů. Rozhodnutí klienta z 31. 7. 2026 („částku vidí jen admin
 * a autor") zůstává v platnosti — vyjmul se z něj vědomě jen vyvěšený ceník,
 * tedy cena, kterou by hala napsala na dveře. Kdo sem bude přidávat další číslo,
 * ať si napřed přečte hlavičku migrace 20260812140000 (A2b).
 *
 * Editor ceníku tu SCHVÁLNĚ NENÍ. Pásma se dnes mění migrací nebo v databázi;
 * stránka tenhle stav jen zviditelňuje, nemění ho.
 */
const Cenik = () => {
  const { settings, isLoading: nacitamNastaveni, error: chybaNastaveni } = useSettings();
  const { pasma, isLoading: nacitamCenik, error: chybaCeniku } = useCenik();

  const hodiny = (settings?.opening_hours as OpeningHours | null) ?? null;

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div>
        <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2">
          <Coins className="h-6 w-6" aria-hidden="true" /> Ceník ledu
        </h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          Provozní doba haly a standardní sazby za hodinu ledu. Stránka je jen
          k nahlédnutí — ceník mění správce haly.
        </p>
      </div>

      <div className="grid gap-4 md:gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <Clock className="h-4 w-4" aria-hidden="true" /> Otevírací doba
            </CardTitle>
            <CardDescription>Kdy se dá led rezervovat</CardDescription>
          </CardHeader>
          <CardContent>
            {nacitamNastaveni ? (
              <div className="text-sm text-muted-foreground">Načítám…</div>
            ) : chybaNastaveni ? (
              // Výpadek se NESMÍ tvářit jako nevyplněná otevírací doba. Rada
              // „napiš správci haly" by poslala člověka řešit něco, co je
              // nastavené — a správce by hledal chybu na svém konci.
              <div className="text-sm text-destructive">
                Otevírací dobu se nepodařilo načíst. Zkus stránku znovu načíst.
              </div>
            ) : !hodiny || Object.keys(hodiny).length === 0 ? (
              // Nevyplněná otevírací doba není totéž co „zavřeno" — kalendář na ní
              // stojí, takže prázdno znamená, že ji správce ještě nenastavil.
              <div className="text-sm text-muted-foreground">
                Otevírací doba zatím není nastavená. Napiš správci haly.
              </div>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow><TableHead>Den</TableHead><TableHead className="text-right">Otevřeno</TableHead></TableRow>
                </TableHeader>
                <TableBody>
                  {DNY.map(([klic, nazev]) => {
                    const den = hodiny[klic];
                    return (
                      <TableRow key={klic}>
                        <TableCell className="font-medium">{nazev}</TableCell>
                        <TableCell className="text-right tabular-nums">
                          {den?.open && den?.close
                            ? `${den.open} – ${den.close}`
                            : <span className="text-muted-foreground">zavřeno</span>}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <Coins className="h-4 w-4" aria-hidden="true" /> Sazby za hodinu ledu
            </CardTitle>
            <CardDescription>Podle dne a denní doby, za jednu dráhu</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {nacitamCenik ? (
              <div className="text-sm text-muted-foreground">Načítám…</div>
            ) : chybaCeniku ? (
              // Výpadek se schválně NEtváří jako prázdný ceník: „ceník není
              // vyplněný" a „ceník se nenačetl" vedou k úplně jinému kroku.
              <div className="text-sm text-destructive">
                Ceník se nepodařilo načíst. Zkus stránku znovu načíst.
              </div>
            ) : pasma.length === 0 ? (
              <div className="text-sm text-muted-foreground">
                Ceník zatím není vyplněný. Cenu ti řekne správce haly.
              </div>
            ) : (
              SKUPINY.map(({ typ, nadpis, popis }) => {
                const radky = pasma.filter((p) => p.den_typ === typ);
                if (radky.length === 0) return null;
                return (
                  <div key={typ}>
                    <div className="mb-1 font-medium">{nadpis}</div>
                    <div className="mb-2 text-xs text-muted-foreground">{popis}</div>
                    <Table>
                      <TableHeader>
                        <TableRow><TableHead>Čas</TableHead><TableHead className="text-right">Sazba</TableHead></TableRow>
                      </TableHeader>
                      <TableBody>
                        {radky.map((p) => (
                          <TableRow key={p.id}>
                            <TableCell className="tabular-nums">{pasmoText(p.od_hodina, p.do_hodina)}</TableCell>
                            <TableCell className="text-right font-semibold tabular-nums">{fmtSazba(p.sazba)}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </div>
                );
              })
            )}
          </CardContent>
        </Card>
      </div>

      {/* Bez téhle věty je ceník past: rezervace přes hranici pásma se počítá
          po hodinách, takže 16:00–19:00 nestojí 3× ranní sazbu. A hlavně —
          komerční akce a individuálně sjednané klubové sazby tu nejsou vůbec,
          což musí být řečeno, ne jen vynecháno. */}
      <Card>
        <CardContent className="pt-6">
          <div className="flex gap-3">
            <Info className="mt-0.5 h-4 w-4 flex-shrink-0 text-muted-foreground" aria-hidden="true" />
            <div className="space-y-1 text-sm text-muted-foreground">
              <p>
                Rezervace přes hranici pásma se počítá <b>po hodinách</b> — například
                16:00–19:00 je jedna hodina v odpoledním pásmu a dvě ve večerním,
                ne tři hodiny za jednu sazbu.
              </p>
              <p>
                Ceník platí pro <b>klubový led a tréninky</b>. Turnaje, komerční akce
                a individuálně sjednané sazby se domlouvají se správcem haly.
              </p>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
};

export default Cenik;
