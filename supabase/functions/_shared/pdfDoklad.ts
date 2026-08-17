// C4 — vysázení dokladu do PDF.
//
// Běží ve dvou prostředích a to je záměr: v Edge funkci (Deno) na serveru
// a v testech (Node/vitest). Proto je to čistá funkce bez sítě, bez databáze
// a bez hodin — všechno, co na doklad patří, přijde v DTO.
//
// TŘI VĚCI, KTERÉ TU JSOU NOSNÉ
//
// 1) DETERMINISMUS. `renderInvoice(fixture)` dvakrát musí dát bajt po bajtu týž
//    soubor, protože se z něj počítá `pdf_sha256` uložený k dokladu. Kdyby se
//    render lišil běh od běhu, otisk by přestal být důkazem o obsahu a stal by
//    se náhodným číslem. `pdf-lib` do dokumentu jinak píše aktuální čas — proto
//    se data nastavují na pevnou hodnotu odvozenou z dokladu, ne z `Date.now()`.
//
// 2) SNAPSHOT, NE ŽIVÁ DATA. Vysází se to, co je v hlavičce faktury (dodavatel,
//    odběratel, sazby), ne to, co je dneska v nastavení. Vystavený doklad je
//    neměnný; kdyby se PDF regenerovalo z dnešního stavu, dokument by se rozešel
//    s tím, co klient dostal.
//
// 3) DVĚ VĚTVE DPH. Neplátce nemá na dokladu žádnou daň a musí mít doložku;
//    plátce má u položek základ, sazbu a daň, a navíc rekapitulaci po sazbách.
//    Vysázet plátcovský doklad bez daně by byl doklad, který o svém režimu mlčí.

import { PDFDocument, PDFFont, PDFPage, rgb } from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import qrcode from 'qrcode-generator';

import { NOTO_REGULAR_BASE64, NOTO_BOLD_BASE64 } from './font-noto.ts';

// ---------------------------------------------------------------------------
// DTO — přesně to, co se tiskne. Nic víc; renderer si nic nedopočítává z DB.
// ---------------------------------------------------------------------------
export interface DokladPolozka {
  popis: string;
  datum: string | null;
  hodiny: number;
  sazba: number;
  line_total: number;
  /** Vyplněné jen v plátcovském režimu. */
  vat_rate: number | null;
  vat_base: number | null;
  vat_amount: number | null;
}

export interface DokladDTO {
  cislo: string;
  /** Vyplněné = jde o opravný doklad, který ruší doklad s tímhle číslem. */
  opravuje_cislo: string | null;
  storno_duvod: string | null;

  vat_mode: 'neplatce' | 'identifikovana_osoba' | 'platce';
  datum_vystaveni: string;
  datum_splatnosti: string;
  datum_uhrady: string | null;
  obdobi_od: string;
  obdobi_do: string;
  variabilni_symbol: string | null;

  dodavatel_nazev: string;
  dodavatel_adresa: string | null;
  dodavatel_ico: string | null;
  dodavatel_dic: string | null;
  dodavatel_rejstrik: string | null;
  dodavatel_ucet: string | null;
  dodavatel_iban: string | null;
  dodavatel_zprava: string | null;

  odberatel_nazev: string;
  odberatel_adresa: string | null;
  odberatel_ico: string | null;
  odberatel_dic: string | null;

  polozky: DokladPolozka[];
  subtotal: number;
  total: number;
  total_rounded: number;
  rounding_amount: number;
}

// ---------------------------------------------------------------------------
// Formátování. Vlastní, ne `Intl`: `Intl` se chová podle locale dostupných
// v běhovém prostředí, takže by se výstup mohl lišit mezi Denem a Nodem — a tím
// by padl determinismus. Tohle je pár řádků a je jednoznačné.
// ---------------------------------------------------------------------------
const MEZERA = ' ';   // nezlomitelná — „22 600 Kč" se nesmí zalomit

export function fmtKc(v: number): string {
  const zaokrouhlene = Math.round(v * 100) / 100;
  const zaporne = zaokrouhlene < 0;
  const abs = Math.abs(zaokrouhlene);
  const cele = Math.floor(abs);
  const desetiny = Math.round((abs - cele) * 100);
  const skupiny = String(cele).replace(/\B(?=(\d{3})+(?!\d))/g, MEZERA);
  const zbytek = desetiny > 0 ? ',' + String(desetiny).padStart(2, '0') : '';
  return `${zaporne ? '−' : ''}${skupiny}${zbytek}${MEZERA}Kč`;
}

export function fmtDatum(iso: string | null): string {
  if (!iso) return '—';
  const [r, m, d] = iso.split('-');
  if (!r || !m || !d) return iso;
  return `${Number(d)}.${MEZERA}${Number(m)}.${MEZERA}${r}`;
}

const fmtHodin = (v: number) => (Number.isInteger(v) ? String(v) : v.toFixed(2).replace('.', ','));

// ---------------------------------------------------------------------------
// QR platba jako SVG path
//
// Jeden `path` místo stovek obdélníků: menší soubor a hlavně jeden objekt v PDF
// místo ~700, což se na velikosti i na rychlosti renderu pozná.
//
// Kód se počítá z TÉHOŽ řetězce SPAYD, jaký používá tisk z obrazovky — jinak by
// vznikly dva QR, které se můžou rozejít. Řetězec připravuje volající.
// ---------------------------------------------------------------------------
export function qrSvgPath(spayd: string, velikost: number): { path: string; scale: number } {
  const qr = qrcode(0, 'M');
  qr.addData(spayd, 'Byte');
  qr.make();
  const pocet = qr.getModuleCount();
  const modul = velikost / pocet;

  let path = '';
  for (let r = 0; r < pocet; r++) {
    for (let c = 0; c < pocet; c++) {
      if (!qr.isDark(r, c)) continue;
      const x = c * modul;
      const y = r * modul;
      // Každý tmavý modul jako uzavřený čtverec ve společném path.
      path += `M ${x.toFixed(3)} ${y.toFixed(3)} h ${modul.toFixed(3)} v ${modul.toFixed(3)} h ${(-modul).toFixed(3)} Z `;
    }
  }
  return { path: path.trim(), scale: modul };
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------
const A4 = { w: 595.28, h: 841.89 };
const OKRAJ = 48;
const CERNA = rgb(0.06, 0.09, 0.16);
const SEDA = rgb(0.39, 0.45, 0.55);
const LINKA = rgb(0.85, 0.88, 0.92);

interface Pero {
  page: PDFPage;
  regular: PDFFont;
  bold: PDFFont;
  y: number;
}

function text(p: Pero, s: string, x: number, y: number, opts: {
  size?: number; bold?: boolean; barva?: typeof CERNA; vpravo?: number;
} = {}) {
  const size = opts.size ?? 9.5;
  const font = opts.bold ? p.bold : p.regular;
  const hodnota = s ?? '';
  const posun = opts.vpravo !== undefined
    ? opts.vpravo - font.widthOfTextAtSize(hodnota, size)
    : x;
  p.page.drawText(hodnota, { x: posun, y, size, font, color: opts.barva ?? CERNA });
}

function linka(p: Pero, y: number, od = OKRAJ, doX = A4.w - OKRAJ) {
  p.page.drawLine({ start: { x: od, y }, end: { x: doX, y }, thickness: 0.5, color: LINKA });
}

/** Ořízne text, aby nepřetekl ze sloupce. Radši useknout než sázet přes sebe. */
function zkrat(s: string, font: PDFFont, size: number, sirka: number): string {
  if (font.widthOfTextAtSize(s, size) <= sirka) return s;
  let v = s;
  while (v.length > 1 && font.widthOfTextAtSize(v + '…', size) > sirka) v = v.slice(0, -1);
  return v + '…';
}

/**
 * Vysází doklad. Vrací bajty PDF.
 *
 * `spayd` je hotový řetězec QR platby, nebo `null`, když se platit nemá
 * (uhrazený doklad, opravný doklad, chybějící IBAN). Rozhodnutí, jestli QR
 * patří na doklad, dělá volající — renderer jen kreslí.
 */
export async function renderInvoice(dto: DokladDTO, spayd: string | null): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);

  // DETERMINISMUS: bez tohohle si `pdf-lib` do metadat zapíše `new Date()`
  // a dva rendery téhož dokladu by daly různý sha256. Datum se bere z dokladu,
  // takže je pevné a zároveň pravdivé.
  const vystaveni = new Date(`${dto.datum_vystaveni}T00:00:00Z`);
  pdf.setCreationDate(vystaveni);
  pdf.setModificationDate(vystaveni);
  pdf.setProducer('Curling Promo Ostrava');
  pdf.setCreator('Curling Promo Ostrava');
  const opravny = !!dto.opravuje_cislo;
  const nazevDokladu = opravny ? 'Opravný doklad' : 'Faktura';
  pdf.setTitle(`${nazevDokladu} ${dto.cislo}`);

  const regular = await pdf.embedFont(Uint8Array.from(atob(NOTO_REGULAR_BASE64), (c) => c.charCodeAt(0)));
  const bold = await pdf.embedFont(Uint8Array.from(atob(NOTO_BOLD_BASE64), (c) => c.charCodeAt(0)));
  const p: Pero = { page: pdf.addPage([A4.w, A4.h]), regular, bold, y: A4.h - OKRAJ };
  // POZOR: níž se sází přes `p.page`, NIKDY přes odkaz na první stránku.
  // Dlouhý doklad se zalomí a `p.page` se přepne; kdo si drží první stránku,
  // nakreslí QR platbu doprostřed položek na straně jedna. (Stalo se; odhalil
  // to až vzorek z `scripts/render-vzorky.mjs`, ne testy — soubor byl platný.)

  const platce = dto.vat_mode === 'platce';

  // ---- hlavička ----
  text(p, nazevDokladu, OKRAJ, p.y - 6, { size: 20, bold: true });
  text(p, `č. ${dto.cislo}`, 0, p.y - 6, { size: 12, vpravo: A4.w - OKRAJ, barva: SEDA });
  p.y -= 28;

  if (opravny) {
    // Opravný doklad nese kladné částky jako originál (schéma záporný nepustí),
    // takže bez téhle věty vypadá jako druhá výzva zaplatit totéž.
    const veta = `Ruší fakturu č. ${dto.opravuje_cislo}` + (dto.storno_duvod ? ` — ${dto.storno_duvod}` : '');
    p.page.drawRectangle({ x: OKRAJ, y: p.y - 16, width: A4.w - 2 * OKRAJ, height: 20, color: rgb(0.95, 0.96, 0.98) });
    text(p, zkrat(veta, regular, 9.5, A4.w - 2 * OKRAJ - 12), OKRAJ + 6, p.y - 10);
    p.y -= 30;
  }

  // ---- strany ----
  const sloupec = (nadpis: string, x: number, radky: (string | null)[]) => {
    text(p, nadpis, x, p.y, { size: 8, bold: true, barva: SEDA });
    let yy = p.y - 14;
    for (const r of radky) {
      if (!r) continue;
      text(p, zkrat(r, regular, 9.5, 220), x, yy);
      yy -= 12;
    }
    return yy;
  };
  const yDod = sloupec('DODAVATEL', OKRAJ, [
    dto.dodavatel_nazev, dto.dodavatel_adresa,
    dto.dodavatel_ico ? `IČO: ${dto.dodavatel_ico}` : null,
    dto.dodavatel_dic ? `DIČ: ${dto.dodavatel_dic}` : null,
    dto.dodavatel_rejstrik,
  ]);
  const yOdb = sloupec('ODBĚRATEL', A4.w / 2 + 10, [
    dto.odberatel_nazev, dto.odberatel_adresa,
    dto.odberatel_ico ? `IČO: ${dto.odberatel_ico}` : null,
    dto.odberatel_dic ? `DIČ: ${dto.odberatel_dic}` : null,
  ]);
  p.y = Math.min(yDod, yOdb) - 10;

  // ---- údaje ----
  linka(p, p.y); p.y -= 16;
  const udaj = (popis: string, hodnota: string, x: number) => {
    text(p, popis, x, p.y, { size: 8, barva: SEDA });
    text(p, hodnota, x, p.y - 12, { size: 9.5, bold: true });
  };
  const krok = (A4.w - 2 * OKRAJ) / 4;
  udaj('Datum vystavení', fmtDatum(dto.datum_vystaveni), OKRAJ);
  udaj('Datum splatnosti', fmtDatum(dto.datum_splatnosti), OKRAJ + krok);
  udaj('Variabilní symbol', dto.variabilni_symbol ?? '—', OKRAJ + 2 * krok);
  udaj('Období plnění', `${fmtDatum(dto.obdobi_od)} – ${fmtDatum(dto.obdobi_do)}`, OKRAJ + 3 * krok);
  p.y -= 28;
  linka(p, p.y); p.y -= 18;

  // ---- položky ----
  // Sloupce se liší podle režimu DPH: plátce potřebuje základ, sazbu a daň,
  // neplátce by měl prázdné rubriky, což na dokladu vypadá jako chyba.
  // Jeden tvar pro obě větve (v neplátcovské jsou daňové sloupce nulové).
  // Dva různé tvary vypadaly úsporněji, jenže pak je `sirky.zaklad` „možná
  // undefined" a sazba se počítá z `NaN` — text by skončil mimo stránku.
  interface Sirky { popis: number; hodiny: number; sazba: number; zaklad: number; dph: number; dan: number }
  const sirky: Sirky = platce
    ? { popis: 176, hodiny: 44, sazba: 62, zaklad: 68, dph: 44, dan: 62 }
    : { popis: 300, hodiny: 60, sazba: 70, zaklad: 0, dph: 0, dan: 0 };
  const xPopis = OKRAJ;
  const xKonec = A4.w - OKRAJ;

  const hlavickaTabulky = () => {
    text(p, 'Popis', xPopis, p.y, { size: 8, bold: true, barva: SEDA });
    if (platce) {
      text(p, 'Hod.', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xPopis + sirky.popis + sirky.hodiny });
      text(p, 'Sazba', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xPopis + sirky.popis + sirky.hodiny + sirky.sazba });
      text(p, 'Základ', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xPopis + sirky.popis + sirky.hodiny + sirky.sazba + sirky.zaklad });
      text(p, 'DPH', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xPopis + sirky.popis + sirky.hodiny + sirky.sazba + sirky.zaklad + sirky.dph });
      text(p, 'Daň', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xPopis + sirky.popis + sirky.hodiny + sirky.sazba + sirky.zaklad + sirky.dph + sirky.dan });
    } else {
      text(p, 'Hodin', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xPopis + sirky.popis + sirky.hodiny });
      text(p, 'Sazba', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xPopis + sirky.popis + sirky.hodiny + sirky.sazba });
    }
    text(p, 'Celkem', 0, p.y, { size: 8, bold: true, barva: SEDA, vpravo: xKonec });
    p.y -= 6;
    linka(p, p.y);
    p.y -= 13;
  };
  hlavickaTabulky();

  for (const it of dto.polozky) {
    // Stránkování: doklad za měsíc může mít přes třicet řádků a spodní okraj
    // není místo, kam je tisknout přes sebe.
    if (p.y < 150) {
      const dalsi = pdf.addPage([A4.w, A4.h]);
      p.page = dalsi;
      p.y = A4.h - OKRAJ;
      text(p, `${nazevDokladu} č. ${dto.cislo} — pokračování`, OKRAJ, p.y, { size: 9, barva: SEDA });
      p.y -= 20;
      hlavickaTabulky();
    }

    const popis = it.datum ? `${it.popis} (${fmtDatum(it.datum)})` : it.popis;
    text(p, zkrat(popis, regular, 9, sirky.popis - 6), xPopis, p.y, { size: 9 });
    if (platce) {
      const x1 = xPopis + sirky.popis + sirky.hodiny;
      const x2 = x1 + sirky.sazba;
      const x3 = x2 + sirky.zaklad;
      const x4 = x3 + sirky.dph;
      const x5 = x4 + sirky.dan;
      text(p, fmtHodin(it.hodiny), 0, p.y, { size: 9, vpravo: x1 });
      text(p, fmtKc(it.sazba), 0, p.y, { size: 9, vpravo: x2 });
      text(p, fmtKc(it.vat_base ?? it.line_total), 0, p.y, { size: 9, vpravo: x3 });
      text(p, `${it.vat_rate ?? 0} %`, 0, p.y, { size: 9, vpravo: x4 });
      text(p, fmtKc(it.vat_amount ?? 0), 0, p.y, { size: 9, vpravo: x5 });
    } else {
      text(p, fmtHodin(it.hodiny), 0, p.y, { size: 9, vpravo: xPopis + sirky.popis + sirky.hodiny });
      text(p, fmtKc(it.sazba), 0, p.y, { size: 9, vpravo: xPopis + sirky.popis + sirky.hodiny + sirky.sazba });
    }
    text(p, fmtKc(it.line_total), 0, p.y, { size: 9, vpravo: xKonec });
    p.y -= 13;
  }

  p.y -= 4;
  linka(p, p.y);
  p.y -= 16;

  // ---- rekapitulace DPH (jen plátce) ----
  if (platce) {
    const dleSazby = new Map<number, { zaklad: number; dan: number }>();
    for (const it of dto.polozky) {
      const s = it.vat_rate ?? 0;
      const z = dleSazby.get(s) ?? { zaklad: 0, dan: 0 };
      z.zaklad += it.vat_base ?? it.line_total;
      z.dan += it.vat_amount ?? 0;
      dleSazby.set(s, z);
    }
    text(p, 'Rekapitulace DPH', OKRAJ, p.y, { size: 8, bold: true, barva: SEDA });
    p.y -= 14;
    // Seřazeno podle sazby, ne podle pořadí položek — jinak by se rekapitulace
    // lišila doklad od dokladu a nešla by porovnat (a padl by determinismus).
    for (const sazba of [...dleSazby.keys()].sort((a, b) => a - b)) {
      const z = dleSazby.get(sazba)!;
      text(p, `Základ ${sazba} %`, OKRAJ, p.y, { size: 9 });
      text(p, fmtKc(z.zaklad), 0, p.y, { size: 9, vpravo: xKonec - 120 });
      text(p, `Daň ${sazba} %`, xKonec - 110, p.y, { size: 9 });
      text(p, fmtKc(z.dan), 0, p.y, { size: 9, vpravo: xKonec });
      p.y -= 13;
    }
    p.y -= 6;
  }

  // ---- součty ----
  const soucet = (popis: string, hodnota: string, tucne = false) => {
    text(p, popis, 0, p.y, { size: tucne ? 11 : 9.5, bold: tucne, vpravo: xKonec - 110 });
    text(p, hodnota, 0, p.y, { size: tucne ? 11 : 9.5, bold: tucne, vpravo: xKonec });
    p.y -= tucne ? 18 : 14;
  };
  soucet('Mezisoučet', fmtKc(dto.subtotal));
  if (dto.rounding_amount !== 0) soucet('Zaokrouhlení', fmtKc(dto.rounding_amount));
  const popisCelkem = opravny ? 'Celkem (rušená částka)'
    : dto.datum_uhrady ? 'Celkem (uhrazeno)' : 'Celkem k úhradě';
  soucet(popisCelkem, fmtKc(dto.total_rounded), true);

  // ---- platební údaje + QR ----
  p.y -= 6;
  linka(p, p.y);
  p.y -= 16;

  // HORNÍ HRANA CELÉHO PLATEBNÍHO BLOKU. Drží se schválně v proměnné: QR se
  // kreslí vpravo a text vlevo, ale OBOJE musí začínat pod součty. Když se QR
  // umisťoval relativně k `p.y` až po vypsání textu, vylezl nahoru přes součty
  // a bílým podkladem PŘEMALOVAL částky — doklad pak neměl vidět, kolik se platí.
  // Odhalila to až vizuální kontrola vyrenderovaného PDF; bajtové testy o tom
  // nevědí, protože soubor je pořád platný a deterministický.
  const yBlok = p.y;
  const kresliQr = !!spayd && !dto.datum_uhrady && !opravny;
  const QR = 92;

  if (dto.datum_uhrady) {
    text(p, `✓ Uhrazeno dne ${fmtDatum(dto.datum_uhrady)} — doklad je vyrovnaný, neplaťte znovu.`,
      OKRAJ, p.y, { size: 9.5, bold: true });
    p.y -= 14;
  } else if (!opravny) {
    text(p, 'Platební údaje', OKRAJ, p.y, { size: 8, bold: true, barva: SEDA });
    p.y -= 13;
    // Text se drží vlevo od QR, ať se s ním nepotká ani u dlouhého IBANu.
    const sirkaTextu = xKonec - OKRAJ - (kresliQr ? QR + 24 : 0);
    for (const radek of [
      dto.dodavatel_ucet ? `Účet: ${dto.dodavatel_ucet}` : null,
      dto.dodavatel_iban ? `IBAN: ${dto.dodavatel_iban}` : null,
      dto.dodavatel_zprava ? `Zpráva: ${dto.dodavatel_zprava}` : null,
    ]) {
      if (!radek) continue;
      text(p, zkrat(radek, regular, 9.5, sirkaTextu), OKRAJ, p.y, { size: 9.5 });
      p.y -= 12;
    }
  }

  // QR se kreslí, jen když ho volající poslal. Na opravném dokladu a na
  // uhrazeném dokladu je naskenovatelný QR pozvánka zaplatit podruhé.
  if (kresliQr) {
    const { path } = qrSvgPath(spayd!, QR);
    const x = xKonec - QR;
    // `drawSvgPath` bere `y` jako HORNÍ hranu (kreslí v souřadnicích SVG, kde
    // y roste dolů), takže se kód vejde přesně pod `yBlok`.
    p.page.drawSvgPath(path, { x, y: yBlok, color: CERNA, scale: 1 });
    text(p, 'QR platba', 0, yBlok - QR - 10, { size: 8, barva: SEDA, vpravo: xKonec });
    // Doložka i patička musí jít pod to, co je NÍŽ — text i QR.
    p.y = Math.min(p.y, yBlok - QR - 22);
  }

  // ---- daňová doložka ----
  p.y -= 10;
  if (!platce) {
    // Neplátce MUSÍ doložku mít; bez ní doklad o svém režimu mlčí a vypadá jako
    // neúplný daňový doklad.
    const doložka = dto.vat_mode === 'identifikovana_osoba'
      ? 'Identifikovaná osoba. Plnění není předmětem DPH v tuzemsku.'
      : 'Neplátce DPH. Částky jsou konečné, daň se neúčtuje.';
    text(p, doložka, OKRAJ, p.y, { size: 8.5, barva: SEDA });
    p.y -= 12;
  }

  const bytes = await pdf.save({ useObjectStreams: false });
  return bytes;
}
