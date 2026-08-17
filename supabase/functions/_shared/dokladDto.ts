// Převod řádku faktury z databáze na DTO pro render + rozhodnutí o QR platbě.
//
// Vytažené z Edge funkce schválně: tohle je ta část, kde se dá udělat chyba
// s následkem (QR na uhrazeném dokladu, částka z jiného pole, živá data místo
// snapshotu), a zároveň jediná část, která se dá otestovat bez Dena, bez sítě
// a bez databáze. Samotná Edge funkce kolem toho je jen HTTP a I/O.

import type { DokladDTO, DokladPolozka } from './pdfDoklad.ts';

/** Řádek `invoices` — jen sloupce, které doklad opravdu potřebuje. */
export interface FakturaRadek {
  cislo: string | null;
  vat_mode: string;
  datum_vystaveni: string | null;
  datum_splatnosti: string | null;
  datum_uhrady: string | null;
  obdobi_od: string;
  obdobi_do: string;
  variabilni_symbol: string | null;
  dodavatel_nazev: string | null;
  dodavatel_adresa: string | null;
  dodavatel_ico: string | null;
  dodavatel_dic: string | null;
  dodavatel_rejstrik: string | null;
  dodavatel_ucet: string | null;
  dodavatel_iban: string | null;
  dodavatel_zprava: string | null;
  odberatel_nazev: string | null;
  odberatel_adresa: string | null;
  odberatel_ico: string | null;
  odberatel_dic: string | null;
  subtotal: number | string;
  total: number | string;
  total_rounded: number | string;
  rounding_amount: number | string;
  opravuje_id: string | null;
  storno_duvod: string | null;
}

export interface PolozkaRadek {
  popis: string;
  datum: string | null;
  hodiny: number | string;
  sazba: number | string;
  line_total: number | string;
  vat_rate: number | string | null;
  vat_base: number | string | null;
  vat_amount: number | string | null;
  poradi: number;
}

/**
 * `numeric` chodí z PostgREST jako ŘETĚZEC, ne číslo. Bez tohohle by se
 * „22600.00" dostalo do formátování jako text a doklad by tvrdil `NaN Kč`.
 */
const cislo = (v: number | string | null | undefined): number => {
  if (v === null || v === undefined) return 0;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
};

export function sestavDto(
  f: FakturaRadek,
  polozky: PolozkaRadek[],
  opravujeCislo: string | null,
): DokladDTO {
  if (!f.cislo) {
    // Koncept nemá číslo a nemá se renderovat vůbec — kdyby se sem dostal,
    // vznikl by doklad bez čísla, tedy neplatný.
    throw new Error('Doklad bez čísla se nerenderuje (koncept není doklad).');
  }

  const vat_mode = (['neplatce', 'identifikovana_osoba', 'platce'].includes(f.vat_mode)
    ? f.vat_mode
    : 'neplatce') as DokladDTO['vat_mode'];

  const radky: DokladPolozka[] = [...polozky]
    // Pořadí je součást dokladu: bez seřazení by se PDF lišilo podle toho, jak
    // se databázi zrovna zachtělo řádky vrátit — a padl by determinismus.
    .sort((a, b) => (a.poradi - b.poradi) || (a.datum ?? '').localeCompare(b.datum ?? ''))
    .map((it) => ({
      popis: it.popis,
      datum: it.datum,
      hodiny: cislo(it.hodiny),
      sazba: cislo(it.sazba),
      line_total: cislo(it.line_total),
      vat_rate: it.vat_rate === null ? null : cislo(it.vat_rate),
      vat_base: it.vat_base === null ? null : cislo(it.vat_base),
      vat_amount: it.vat_amount === null ? null : cislo(it.vat_amount),
    }));

  return {
    cislo: f.cislo,
    opravuje_cislo: f.opravuje_id ? opravujeCislo : null,
    storno_duvod: f.storno_duvod,
    vat_mode,
    datum_vystaveni: f.datum_vystaveni ?? f.obdobi_do,
    datum_splatnosti: f.datum_splatnosti ?? f.obdobi_do,
    datum_uhrady: f.datum_uhrady,
    obdobi_od: f.obdobi_od,
    obdobi_do: f.obdobi_do,
    variabilni_symbol: f.variabilni_symbol,
    // Všechno níž je SNAPSHOT z hlavičky, ne dnešní stav nastavení: vystavený
    // doklad je neměnný a PDF se z něj musí dát vyrobit i po změně údajů haly.
    dodavatel_nazev: f.dodavatel_nazev ?? '',
    dodavatel_adresa: f.dodavatel_adresa,
    dodavatel_ico: f.dodavatel_ico,
    dodavatel_dic: f.dodavatel_dic,
    dodavatel_rejstrik: f.dodavatel_rejstrik,
    dodavatel_ucet: f.dodavatel_ucet,
    dodavatel_iban: f.dodavatel_iban,
    dodavatel_zprava: f.dodavatel_zprava,
    odberatel_nazev: f.odberatel_nazev ?? '',
    odberatel_adresa: f.odberatel_adresa,
    odberatel_ico: f.odberatel_ico,
    odberatel_dic: f.odberatel_dic,
    polozky: radky,
    subtotal: cislo(f.subtotal),
    total: cislo(f.total),
    total_rounded: cislo(f.total_rounded),
    rounding_amount: cislo(f.rounding_amount),
  };
}

/**
 * Patří na tenhle doklad QR platba?
 *
 * Vrací `null`, když ne — a je to rozhodnutí, ne technický detail: naskenovaný
 * QR na uhrazeném nebo opravném dokladu je pozvánka zaplatit podruhé. Chybějící
 * IBAN je taky `null`, protože QR bez čísla účtu neexistuje.
 */
export function maMitQr(dto: DokladDTO): boolean {
  return !!dto.dodavatel_iban && !dto.datum_uhrady && !dto.opravuje_cislo;
}

/** Klíč objektu ve Storage (R7): ASCII, bez identity odběratele, bez diakritiky. */
export function klicObjektu(cislo: string, datumVystaveni: string, verze = 1): string {
  const rok = (datumVystaveni ?? '').slice(0, 4) || String(new Date().getUTCFullYear());
  const bezpecne = cislo.replace(/[^A-Za-z0-9-]/g, '');
  return `${rok}/${bezpecne}/v${verze}.pdf`;
}

/**
 * Lidský název souboru — až do parametru `download` podepsané URL, ne do cesty.
 * Pořadové číslo se odvozuje z čísla faktury (poslední čtyřčíslí), aby
 * nevznikaly dvě nezávislé číslovací soustavy.
 */
export function nazevKeStazeni(cislo: string, odberatel: string, datum: string): string {
  const poradi = cislo.slice(-4);
  const kdo = (odberatel ?? '')
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')   // pryč s diakritikou
    .toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')
    .slice(0, 40) || 'odberatel';
  const [r, m, d] = (datum ?? '').split('-');
  return `${poradi}_${kdo}_${d ?? '00'}${m ?? '00'}${(r ?? '0000').slice(2)}.pdf`;
}
