// Datum z databáze do JS Date.
//
// PROČ TENHLE MODUL VZNIKL: `new Date('2026-08-27')` je podle specifikace
// **půlnoc UTC**, kdežto `new Date('2026-08-27T10:00:00')` je půlnoc místní.
// Sloupce typu `date` (datum vystavení, splatnost, datum položky) přijdou
// z PostgRESTu jako holé `RRRR-MM-DD`, takže projdou tou první větví — a pak
// stačí, aby si je někdo přečetl přes `getDate()`, a v prohlížeči západně od
// Greenwiche vyjde o den míň.
//
// Na dokladu to není kosmetika: takhle se posune datum splatnosti v QR platbě
// (`DT:`), tedy údaj, který zákazník nečte a jen potvrdí.
//
// `timestamptz` (čas rezervace) tímhle NEPROCHÁZÍ a procházet nemá — ten nese
// zónu v sobě a `new Date()` ho přečte správně.

/** Je to holé datum z `date` sloupce, tedy `RRRR-MM-DD` bez času? */
const JEN_DATUM = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Přečte hodnotu z `date` sloupce jako MÍSTNÍ půlnoc.
 *
 * Hodnotu s časem nechá projít beze změny — ta zónu buď nese, nebo je to
 * vědomě místní čas. Vrací `null` pro prázdnou hodnotu, ať volající nemusí
 * rozlišovat mezi „nevyplněno" a „nesmysl".
 */
export function denZDb(hodnota: string | null | undefined): Date | null {
  if (!hodnota) return null;
  if (JEN_DATUM.test(hodnota)) {
    const [r, m, d] = hodnota.split('-').map(Number);
    // Měsíc je v konstruktoru od nuly. Tenhle tvar je jediný, který nezávisí
    // na časové zóně prohlížeče.
    return new Date(r, m - 1, d);
  }
  const datum = new Date(hodnota);
  return Number.isNaN(datum.getTime()) ? null : datum;
}

/**
 * Dnešek v PRAŽSKÉM dni, ve tvaru pro `<input type="date">` (RRRR-MM-DD).
 *
 * Ne `new Date()` v prohlížeči: databáze rozhoduje o „dnešku" podle Evropy/Praha
 * (`mark_invoice_paid`), takže admin v pásmu napřed by dostal předvyplněné
 * „zítra" a server by mu ho odmítl. Není to bezpečnostní vada — server rozhoduje
 * správně — ale slepá ulička pro člověka, který zrovna není doma.
 *
 * `sv-SE` schválně: je to jediná běžná locale, která formátuje rovnou jako
 * RRRR-MM-DD, tedy přesně to, co `<input type="date">` chce.
 */
export const dnesPrahaProInput = (): string =>
  new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Prague' }).format(new Date());
