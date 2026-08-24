// Formátování data a času na řádek dokladu — vždy v pražském čase.
//
// PROČ VLASTNÍ HELPER A NE `toLocaleString`: rezervace jsou `timestamptz`, tedy
// okamžik. Popis řádku ale čte člověk, který stál u ledu — musí tam být pražská
// hodina bez ohledu na to, kde běží server (Edge funkce běží v UTC). Bez explicitní
// `timeZone` by se to na půl roku trefilo a v zimě rozešlo o hodinu.
//
// Tatáž past má v repu obdobu v SQL: `current_date` v databázi je UTC, takže
// fakturační kód počítá `(now() AT TIME ZONE 'Europe/Prague')::date`. Tady je to
// stejné rozhodnutí, jen v JS.

export const PRAHA = 'Europe/Prague';

type Casti = { rok: string; mesic: string; den: string; hodina: string; minuta: string };

/** Rozloží okamžik na pražské složky. Jediné místo, kde se sahá na Intl. */
const casti = (okamzik: Date): Casti => {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: PRAHA,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit',
    // `hourCycle: 'h23'`, ne `hour12: false`. To druhé umí v některých runtimech
    // vrátit „24:00" místo „00:00" — a oprava hodiny na „00" by pak seděla
    // k ŠPATNÉMU DATU (24:00 dne 4. je 00:00 dne 5.). `h23` vrací 0–23 rovnou
    // a datum k tomu sedí samo.
    hourCycle: 'h23',
  }).formatToParts(okamzik);

  const najdi = (typ: Intl.DateTimeFormatPartTypes): string =>
    parts.find((p) => p.type === typ)?.value ?? '';

  return {
    rok: najdi('year'), mesic: najdi('month'), den: najdi('day'),
    hodina: najdi('hour'),
    minuta: najdi('minute'),
  };
};

/**
 * Holé datum z `date` sloupce (`RRRR-MM-DD`) NEMÁ časovou zónu, takže ho převádět
 * je kategoriální chyba: `new Date('2026-08-01')` je UTC půlnoc a v jiném pásmu
 * by z toho vyšel jiný den. Stejný rozdíl hlídá `denZDb` v `src/lib/datum.ts`.
 */
const JEN_DATUM = /^(\d{4})-(\d{2})-(\d{2})$/;

const naDatum = (hodnota: string | Date): Date => {
  const d = hodnota instanceof Date ? hodnota : new Date(hodnota);
  if (Number.isNaN(d.getTime())) {
    throw new RangeError(`Neplatné datum: ${String(hodnota)}`);
  }
  return d;
};

/** „22.08." — den a měsíc, jak je zvykem na českém dokladu. */
export const denMesic = (okamzik: string | Date): string => {
  const c = casti(naDatum(okamzik));
  return `${c.den}.${c.mesic}.`;
};

/** „18:00" v pražském čase. */
export const cas = (okamzik: string | Date): string => {
  const c = casti(naDatum(okamzik));
  return `${c.hodina}:${c.minuta}`;
};

/**
 * „18:00–20:00". Pomlčka je EN DASH (U+2013), ne spojovník — je to rozsah.
 * Font v serverovém PDF ho umí (Noto), takže se to nikde nerozsype na obdélníček.
 */
export const rozsahCasu = (od: string | Date, doKdy: string | Date): string =>
  `${cas(od)}–${cas(doKdy)}`;

/** „RRRR-MM-DD" v pražském čase — tvar, který bere Fakturoid i naše `date` sloupce. */
export const datumProApi = (okamzik: string | Date): string => {
  if (typeof okamzik === 'string') {
    const holé = JEN_DATUM.exec(okamzik);
    if (holé) return okamzik;
  }
  const c = casti(naDatum(okamzik));
  return `${c.rok}-${c.mesic}-${c.den}`;
};

/** „RRRRMM" v pražském čase — do klíče idempotence měsíčního souhrnu. */
export const rokMesic = (okamzik: string | Date): string => {
  if (typeof okamzik === 'string') {
    const holé = JEN_DATUM.exec(okamzik);
    if (holé) return `${holé[1]}${holé[2]}`;
  }
  const c = casti(naDatum(okamzik));
  return `${c.rok}${c.mesic}`;
};
