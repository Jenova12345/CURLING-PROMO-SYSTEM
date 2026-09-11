/**
 * Barvy klubů v kalendáři.
 *
 * Admin zadává jednu hex barvu na klub (`subjects.barva`). Z ní se odvozují
 * všechny odstíny, které kalendář potřebuje — ne proto, aby to bylo chytré,
 * ale proto, aby text na bloku zůstal čitelný BEZ OHLEDU na to, jakou barvu
 * admin zvolí. Kdyby se plná barva použila jako podklad, tmavý text by na
 * tmavě modré zmizel a světlý zase na žluté.
 *
 * Řešení: podklad je barva zesvětlená na ~18 % na bílé, takže je vždy světlý
 * a výchozí tmavý text na něm projde s velkou rezervou. Plná barva se
 * používá jen tam, kde na ní žádný text neleží — levý pruh a tečka v legendě.
 */

/**
 * Nejvyšší přípustný jas barvy klubu (0–1, vnímaná luminance).
 *
 * Nativní výběr barvy pustí i bílou. Bílý klub = bílý pruh na bílé mřížce, tedy
 * blok, který není vidět — a admin nemá jak poznat proč. Cokoli světlejšího než
 * tahle mez se proto bere jako „nenastaveno" a spadne do neutrální šedé, která
 * aspoň má obrys. Spodní mez řešit netřeba: podklad se míchá na bílé, takže
 * i z černé vyjde světlý (#000000 → rgb(209 209 209)).
 */
const MAX_JAS = 0.86;

/** Vnímaná luminance 0–1 (ITU-R BT.709 — zelená váží víc než modrá). */
function jas([r, g, b]: [number, number, number]): number {
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

/** Hex `#rrggbb` → `[r, g, b]`. Vrací null, když to hex není. */
function hexNaRgb(hex: string): [number, number, number] | null {
  const m = /^#([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

/**
 * Světlý podklad odvozený z barvy klubu.
 *
 * Míchá se na bílé, ne přes `rgba()`: průhledná barva by se na pruhovaném
 * podkladu druhé dráhy (`bg-muted/40`) chovala jinak než na první a dva
 * stejné kluby vedle sebe by měly různý odstín.
 */
export function podkladKlubu(hex: string | null | undefined, podil = 0.18): string | undefined {
  if (!hex) return undefined;
  const rgb = hexNaRgb(hex);
  if (!rgb || jas(rgb) > MAX_JAS) return undefined;
  const [r, g, b] = rgb.map((c) => Math.round(255 - (255 - c) * podil));
  return `rgb(${r} ${g} ${b})`;
}

/**
 * Plná barva klubu — jen pro pruhy a tečky, nikdy pod text.
 *
 * Vrací NORMALIZOVANOU hodnotu (`#rrggbb` malými písmeny), ne vstup: `hexNaRgb`
 * validuje ořezanou kopii, takže `"#ff0000\u00a0"` by prošlo validací a šlo do
 * `borderLeftColor` i s tou mezerou. Do databáze se taková hodnota nedostane
 * (CHECK je kotvený), ale nechat funkci vracet něco jiného, než co ověřila, je
 * zbytečná past. Malá písmena zároveň umožňují porovnávat barvy rovnou.
 */
export function pruhKlubu(hex: string | null | undefined): string | undefined {
  if (!hex) return undefined;
  const m = /^#([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return undefined;
  const rgb = hexNaRgb(hex);
  if (!rgb || jas(rgb) > MAX_JAS) return undefined;   // neviditelně světlá barva
  return `#${m[1].toLowerCase()}`;
}

/**
 * Barvu dostávají jen KLUBY. Údržba a rezervace bez subjektu zůstávají
 * neutrální, komerční akce má vlastní červenou (`BARVA_KOMERCE`) — tak to
 * chtěl klient, ať je na první pohled poznat, co je klubový led a co ne.
 *
 * POZOR NA POŘADÍ: tahle funkce o typu AKCE neví nic, dívá se jen na subjekt.
 * Kdo ji volá, musí se nejdřív zeptat `jeKomercni(event_type)` — komerce
 * přebíjí barvu klubu. Není to teorie: na produkci je (k 11. 9. 2026) jedna
 * rezervace, kde je `event_type = 'commercial'` a subjekt přitom klub. Bez
 * toho pořadí by se kreslila klubově a byla by to jediná komerční akce
 * v kalendáři, kterou by červená minula.
 */
export function barvaProRezervaci(
  r: { subject_type?: string | null; subject_color?: string | null },
): string | undefined {
  if (r.subject_type !== 'club') return undefined;
  return pruhKlubu(r.subject_color);
}

/**
 * Komerční akce = sytě červená, pro všechny role stejně.
 *
 * Liší se od klubů schválně: klub dostane SVĚTLÝ podklad z vlastní barvy
 * a tmavý text, komerce plnou červenou a text bílý. Kluby si totiž barvu
 * vybírají a musí být čitelné všechny; tahle jedna je daná, takže se k ní
 * dá napsat čitelný text napevno.
 *
 * `#c1121f` na bílém textu má kontrast 6,2 : 1 — nad hranicí WCAG AA (4,5 : 1)
 * pro běžný text, kterým popisky v bloku jsou (11–12 px). Hlídá to gate
 * v `barvaKlubu.test.ts`; kdo červenou zesvětlí, shodí ho.
 */
export const BARVA_KOMERCE = {
  /** Podklad bloku i chipu — a TÁŽ hodnota jde do tečky v legendě. */
  podklad: '#c1121f',
  /** Levý pruh bloku — tmavší, aby byl na červené vidět. */
  pruh: '#7a0a13',
} as const;
// Samostatné pole `tecka` tu schválně NENÍ. Bylo, se stejnou hodnotou jako
// `podklad`, a nic je nesvazovalo: změna jen `podklad` prošla celou sadou
// zeleně a legenda by pak ukazovala barvu, kterou v mřížce nikdo nemá.
// Jedna hodnota se rozejít nemůže — to je silnější než test, který by dvě
// hodnoty hlídal. (Nález brány code review, 11. 9. 2026.)

/**
 * Je to komerční akce?
 *
 * ZÁMĚRNĚ jen `'commercial'`, ne i `'recruitment'`. Náborová akce se jinde
 * v kalendáři s komercí v jedné podmínce potkává (obsazenost brigádníků,
 * `muzeMitBrigadniky`), ale zadání znělo na typ `commercial` — a nábor je pro
 * halu něco jiného než pronájem ledu firmě. Kdyby se to mělo sloučit, ať
 * je to vědomé rozhodnutí, ne vedlejší účinek barvy.
 *
 * ČERVENÁ JE O KOUSEK ŠIRŠÍ, NEŽ ZNÍ „typ commercial". `event_type` sem
 * neteče přímo z `events`: pohled `reservations_calendar` ho DOPOČÍTÁVÁ
 * (`20260909120000_barva_klubu.sql`, ř. 171) —
 *   `COALESCE(e.event_type, CASE WHEN s.type = 'commercial' THEN 'commercial'
 *                                ELSE 'training' END)`
 * — takže rezervace BEZ navázané akce, jejíž subjekt je firma, přijde jako
 * `commercial` a zčervená, i když v `events` žádné `commercial` uložené není.
 * Nejspíš přesně to chceme (firma na ledě je komerce), ale je to napsané,
 * ať se to neobjeví jako překvapení. Na produkci je k 11. 9. 2026 takových
 * rezervací nula, v lokálním seedu sedmnáct.
 *
 * OPAČNÝ OKRAJ je otázka na PM, ne na tuhle funkci: `event_type = 'training'`
 * se subjektem typu `commercial` zůstává NEUTRÁLNÍ (měří to
 * `barvaKlubu.test.ts`). Firma na tréninku tedy červená není.
 * (Nález brány code review, 11. 9. 2026.)
 */
export function jeKomercni(eventType: string | null | undefined): boolean {
  return eventType === 'commercial';
}

/**
 * JEDINÉ MÍSTO, kde se rozhoduje, jak rezervace v kalendáři vypadá.
 *
 * Týdenní mřížka i měsíční chipy si to dřív rozhodovaly každá sama a jednou
 * se kvůli tomu rozešly (údržba měla v jednom pohledu oranžový okraj a ve
 * druhém ne). Pořadí je tady, ne v komponentách, aby šlo změřit testem —
 * regex nad JSX měří, jak je kód napsaný, ne co dělá.
 *
 * Pořadí je závazné: KOMERCE > klub > neutrální.
 *
 * @param podil Jak světlý má být podklad klubu (0–1, viz `podkladKlubu`).
 *   Mřížka používá 0,18, měsíční chipy 0,22 — chip je menší, snese víc barvy.
 *   Komerce `podil` ignoruje: má plnou barvu, ne zesvětlenou.
 */
export function vzhledRezervace(
  r: {
    event_type?: string | null;
    subject_type?: string | null;
    subject_color?: string | null;
  },
  podil = 0.18,
): { podklad?: string; pruh?: string; bilyText: boolean } {
  if (jeKomercni(r.event_type)) {
    return { podklad: BARVA_KOMERCE.podklad, pruh: BARVA_KOMERCE.pruh, bilyText: true };
  }
  const barva = barvaProRezervaci(r);
  if (!barva) return { bilyText: false };
  return { podklad: podkladKlubu(barva, podil), pruh: barva, bilyText: false };
}

/** Paleta, ze které vybírá admin. Shoduje se s paletou v migraci barva_klubu. */
export const PALETA_KLUBU: readonly { hex: string; nazev: string }[] = [
  { hex: '#2563eb', nazev: 'Modrá' },
  { hex: '#7c3aed', nazev: 'Fialová' },
  { hex: '#059669', nazev: 'Zelená' },
  { hex: '#d97706', nazev: 'Jantarová' },
  { hex: '#db2777', nazev: 'Růžová' },
  { hex: '#0891b2', nazev: 'Tyrkysová' },
  { hex: '#4f46e5', nazev: 'Indigo' },
  { hex: '#b45309', nazev: 'Hnědá' },
];
