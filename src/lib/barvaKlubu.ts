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
 * Barvu dostávají jen KLUBY. Komerční akce, údržba a rezervace bez subjektu
 * zůstávají neutrální — tak to chtěl klient, ať je na první pohled poznat,
 * co je klubový led a co ne.
 */
export function barvaProRezervaci(
  r: { subject_type?: string | null; subject_color?: string | null },
): string | undefined {
  if (r.subject_type !== 'club') return undefined;
  return pruhKlubu(r.subject_color);
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
