// QR Platba — řetězec podle standardu SPAYD (Short Payment Descriptor, ČBA).
//
// Tenhle modul dělá JEN řetězec, ne obrázek. Je to schválně: text se dá otestovat
// znak po znaku proti standardu, kdežto vykreslení QR je zobrazovací vrstva, která
// se dá vyměnit (tisk z prohlížeče, pdf-lib v Edge funkci) bez sáhnutí na obsah.
//
// PROČ NA TOM ZÁLEŽÍ VÍC, NEŽ VYPADÁ: QR kód je jediné místo na dokladu, které
// zákazník nečte — jen naskenuje a potvrdí. Překlep v IBANu se v textu odhalí,
// v QR ne (riziko 4 v docs/etapa2-fakturace-plan.md). Proto tenhle modul radši
// odmítne řetězec sestavit, než by do něj dal něco, co neprošlo kontrolou.
//
// Reference: SPAYD 1.0 (Česká bankovní asociace).

import qrcode from 'qrcode-generator';

import { toSetiny } from '@/lib/money';

export interface SpaydPlatba {
  /** IBAN příjemce, bez mezer. */
  iban: string;
  /** Částka k úhradě v Kč. Do QR jde ta zaokrouhlená — je to, co se platí. */
  amount: number;
  /** Variabilní symbol (jen číslice, nejvýš 10). */
  variableSymbol?: string | null;
  /** Zpráva pro příjemce. */
  message?: string | null;
  /** Splatnost — v SPAYD jako DT:RRRRMMDD. */
  dueDate?: Date | null;
  /** Jméno příjemce. */
  recipientName?: string | null;
}

/**
 * Hodnoty v SPAYD se oddělují hvězdičkou a klíč od hodnoty dvojtečkou, takže
 * ani jeden z těch znaků nesmí projít do hodnoty — jinak se řetězec rozpadne
 * na jiná pole, než jsme zamýšleli.
 *
 * Standard navíc povoluje jen podmnožinu ASCII, takže se diakritika překládá.
 * Bez toho by „Pronájem ledové plochy" udělal ze zprávy pro příjemce nečitelný
 * shluk — a některé banky by QR odmítly celý.
 */
export function spaydText(value: string): string {
  return value
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')  // diakritika pryč, písmeno zůstane
    .replace(/[*:]/g, ' ')                             // oddělovače standardu
    .replace(/[^\x20-\x7E]/g, '')                      // zbytek mimo tisknutelné ASCII
    .replace(/\s+/g, ' ')
    .trim();
}

/** IBAN bez mezer a velkými písmeny. Nekontroluje se tu — na to je `iban.ts`. */
const normalizeIban = (iban: string) => iban.replace(/\s+/g, '').toUpperCase();

/**
 * Sestaví SPAYD řetězec.
 *
 * Vyhodí výjimku, když chybí IBAN nebo je částka nesmyslná. Tichý fallback
 * („vyrob QR bez částky") je tady nejhorší možná volba: zákazník by naskenoval
 * kód, banka by nabídla prázdnou částku a nikdo by nepoznal, že je něco špatně.
 */
export function buildSpayd(p: SpaydPlatba): string {
  const iban = normalizeIban(p.iban ?? '');
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/.test(iban)) {
    throw new Error('QR platbu nelze sestavit: IBAN nemá platný tvar.');
  }
  if (!Number.isFinite(p.amount) || p.amount < 0) {
    throw new Error('QR platbu nelze sestavit: neplatná částka.');
  }

  // Částka se do SPAYD píše s tečkou a nejvýš dvěma desetinnými místy. Jde přes
  // `toSetiny`, aby se použila táž kvantizace jako všude jinde — jinak by se
  // v QR mohlo objevit 1250.0000000001.
  const castka = (toSetiny(p.amount) / 100).toFixed(2);

  const pole: string[] = [`ACC:${iban}`, `AM:${castka}`, 'CC:CZK'];

  if (p.variableSymbol) {
    const vs = p.variableSymbol.replace(/\D/g, '');
    // Delší VS banka utne nebo platbu odmítne; tiše zkrátit číslo faktury by
    // znamenalo platbu, kterou nikdo nespáruje.
    if (vs.length > 10) throw new Error('QR platbu nelze sestavit: variabilní symbol je delší než 10 číslic.');
    if (vs) pole.push(`X-VS:${vs}`);
  }
  if (p.dueDate) {
    const d = p.dueDate;
    const dt = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
    pole.push(`DT:${dt}`);
  }
  if (p.recipientName) {
    const rn = spaydText(p.recipientName).slice(0, 35);
    if (rn) pole.push(`RN:${rn}`);
  }
  if (p.message) {
    const msg = spaydText(p.message).slice(0, 60);
    if (msg) pole.push(`MSG:${msg}`);
  }

  return `SPD*1.0*${pole.join('*')}`;
}

/**
 * QR platba jako SVG.
 *
 * Úroveň korekce **M** je to, co pro QR Platbu doporučuje ČBA: vyšší úroveň
 * zvětší kód (a na A4 pak konkuruje textu), nižší zhorší čitelnost z pomačkaného
 * papíru. Verze kódu se nechává na knihovně (`0` = zvol podle délky dat).
 *
 * Vrací SVG, ne PNG: v tisku se škáluje bez rozmazání a nepotřebuje canvas,
 * který v serverovém renderu (fáze C) k dispozici nebude.
 *
 * `margin` se udává ve stejných jednotkách jako `cellSize`, NE v modulech —
 * `margin: 4` při `cellSize: 4` je tedy jeden jediný modul, ne čtyři. Klidová
 * zóna přitom nulová ani úzká být nesmí: standard žádá 4 moduly a čtečky na
 * papíře na tom skutečně stojí. Proto `cellSize * 4`.
 */
export function spaydQrSvg(p: SpaydPlatba, cellSize = 4): string {
  const qr = qrcode(0, 'M');
  qr.addData(buildSpayd(p));
  qr.make();
  return qr.createSvgTag({ cellSize, margin: cellSize * 4 });
}
