// E3 — sestavení měsíčního exportu dokladů.
//
// Čistá část: hranice měsíce, jména souborů v archivu a přehledová tabulka.
// Stahování ze Storage a balení do ZIPu dělá Edge funkce kolem toho — tohle jde
// otestovat z Node bez sítě a bez databáze.
//
// PROČ PŘEHLED V ARCHIVU: ZIP s třiceti PDF a bez rozcestníku je pro účetní
// hromada. `prehled.csv` je jeden pohled na to, co v archivu je, kolik to dělá
// a co v něm CHYBÍ — protože doklad bez vygenerovaného PDF se do archivu dostat
// nemůže a mlčky vynechaný doklad je horší než chybějící soubor.

export interface DokladProExport {
  cislo: string | null;
  odberatel: string | null;
  datum_vystaveni: string | null;
  datum_splatnosti: string | null;
  datum_uhrady: string | null;
  status: string;
  total_rounded: number | string;
  pdf_status: string | null;
  pdf_path: string | null;
  opravuje_cislo?: string | null;
}

/** Hranice měsíce podle pražského kalendáře, ve tvaru `RRRR-MM-DD`. */
export function hraniceMesice(rok: number, mesic: number): { od: string; do: string } {
  if (!Number.isInteger(rok) || rok < 2000 || rok > 2100) {
    throw new Error(`Neplatný rok: ${rok}`);
  }
  if (!Number.isInteger(mesic) || mesic < 1 || mesic > 12) {
    throw new Error(`Neplatný měsíc: ${mesic}`);
  }
  const dva = (n: number) => String(n).padStart(2, '0');
  // Poslední den měsíce: nultý den měsíce následujícího. `Date.UTC` schválně —
  // počítá se s kalendářem, ne s časovým pásmem běhu.
  const posledni = new Date(Date.UTC(rok, mesic, 0)).getUTCDate();
  return { od: `${rok}-${dva(mesic)}-01`, do: `${rok}-${dva(mesic)}-${dva(posledni)}` };
}

/** Název archivu: `doklady-2026-08.zip`. ASCII, řaditelné. */
export function nazevArchivu(rok: number, mesic: number): string {
  return `doklady-${rok}-${String(mesic).padStart(2, '0')}.zip`;
}

/**
 * Jméno souboru uvnitř archivu.
 *
 * Číslo dokladu jde NAPŘED, aby se archiv řadil podle číselné řady — účetní
 * v něm hledá podle čísla, ne podle klubu. Diakritika pryč: ZIP ji sice unese,
 * ale ne každý rozbalovač na Windows.
 */
export function nazevVArchivu(d: DokladProExport): string {
  const cislo = (d.cislo ?? 'bez-cisla').replace(/[^A-Za-z0-9-]/g, '');
  const kdo = (d.odberatel ?? '')
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
    .slice(0, 40) || 'odberatel';
  const opravny = d.opravuje_cislo ? 'opravny-' : '';
  return `${cislo}_${opravny}${kdo}.pdf`;
}

const csvPole = (v: unknown): string => {
  const s = v === null || v === undefined ? '' : String(v);
  // Středník je oddělovač (Excel v české lokalizaci), takže se musí uvozovkovat
  // spolu s uvozovkami a zalomeními.
  return /[";\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/**
 * Přehledová tabulka do archivu.
 *
 * Obsahuje i doklady, které se do ZIPu NEDOSTALY (PDF se nevygenerovalo) —
 * se sloupcem `v_archivu`. Kdyby se jen vynechaly, účetní by dostala archiv,
 * který vypadá úplně, a chybějící doklad by se našel až při kontrole.
 */
export function prehledCsv(doklady: DokladProExport[]): string {
  const hlavicka = [
    'cislo', 'odberatel', 'datum_vystaveni', 'datum_splatnosti', 'datum_uhrady',
    'stav', 'castka_kc', 'opravny_k_dokladu', 'v_archivu', 'soubor',
  ];
  const radky = doklady.map((d) => [
    d.cislo, d.odberatel, d.datum_vystaveni, d.datum_splatnosti, d.datum_uhrady,
    d.status, d.total_rounded, d.opravuje_cislo ?? '',
    d.pdf_status === 'ready' && d.pdf_path ? 'ano' : 'NE',
    d.pdf_status === 'ready' && d.pdf_path ? nazevVArchivu(d) : '',
  ].map(csvPole).join(';'));

  const celkem = doklady
    .filter((d) => d.status !== 'stornovano' && !d.opravuje_cislo)
    .reduce((s, d) => s + Number(d.total_rounded ?? 0), 0);
  const dobropisy = doklady
    .filter((d) => d.opravuje_cislo)
    .reduce((s, d) => s + Number(d.total_rounded ?? 0), 0);

  // Souhrn na konci, ne v hlavičce: CSV se tak dá načíst jako tabulka a součet
  // je pod ní, kde ho člověk čeká.
  const souhrn = [
    '',
    `Vystaveno celkem;${celkem.toFixed(2)}`,
    `Z toho vráceno opravnými doklady;${dobropisy.toFixed(2)}`,
    `Dokladů v archivu;${doklady.filter((d) => d.pdf_status === 'ready' && d.pdf_path).length}`,
    `Dokladů bez PDF;${doklady.filter((d) => !(d.pdf_status === 'ready' && d.pdf_path)).length}`,
  ];

  // BOM: bez něj Excel čeština v CSV rozsype.
  return '\ufeff' + [hlavicka.join(';'), ...radky, ...souhrn].join('\r\n') + '\r\n';
}
