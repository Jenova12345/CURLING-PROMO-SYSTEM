#!/usr/bin/env node
/**
 * Vyrenderuje ukázkové doklady do PDF, aby se daly OČIMA zkontrolovat.
 *
 * PROČ TO EXISTUJE: layout se dá pokazit tak, že o tom testy nevědí. Přesně to
 * se stalo — QR platba se kreslila přes součty a bílým podkladem přemalovala
 * částky. Soubor byl pořád platné PDF, pořád deterministický, testy zelené,
 * a přitom to byla faktura BEZ ČÁSTKY. Chytlo to až podívání se na výsledek.
 *
 * Proto: kdo sáhne na rozvržení v `pdfDoklad.ts`, pustí tohle a podívá se.
 *
 *   node scripts/render-vzorky.mjs [výstupní-adresář]
 *
 * Na macOS jde PDF převést na obrázek bez dalších nástrojů:
 *   sips -s format png --out vzorky/faktura.png vzorky/faktura.pdf
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { register } = require('esbuild-register/dist/node');
register({ target: 'node18' });
const { renderInvoice } = require('../supabase/functions/_shared/pdfDoklad.ts');

const kam = process.argv[2] ?? 'vzorky';
mkdirSync(kam, { recursive: true });

// `line_total` se dopočítá, ale u plátce ho přebije součet základu a daně —
// jinak by vzorek ukazoval doklad, kde „Celkem" nesedí na „Základ + Daň",
// a při vizuální kontrole by se to četlo jako chyba rendereru.
const polozka = (popis, datum, hodiny, sazba, extra = {}) => {
  const zaklad = { popis, datum, hodiny, sazba, line_total: hodiny * sazba,
                   vat_rate: null, vat_base: null, vat_amount: null, ...extra };
  if (zaklad.vat_rate !== null && extra.line_total === undefined) {
    zaklad.line_total = (zaklad.vat_base ?? 0) + (zaklad.vat_amount ?? 0);
  }
  return zaklad;
};

const zaklad = {
  cislo: '20260001', opravuje_cislo: null, storno_duvod: null, vat_mode: 'neplatce',
  datum_vystaveni: '2026-08-14', datum_splatnosti: '2026-08-28', datum_uhrady: null,
  obdobi_od: '2026-08-01', obdobi_do: '2026-08-31', variabilni_symbol: '20260001',
  dodavatel_nazev: 'Curling Promo Ostrava z.s.', dodavatel_adresa: 'Ledová 1, 700 30 Ostrava',
  dodavatel_ico: '12345678', dodavatel_dic: null, dodavatel_rejstrik: 'Spolkový rejstřík, KS Ostrava',
  dodavatel_ucet: '19-2000145399/0800', dodavatel_iban: 'CZ6508000000192000145399',
  dodavatel_zprava: 'Pronájem ledu',
  odberatel_nazev: 'CK Ostravské kameny', odberatel_adresa: 'Kamenná 12, 700 30 Ostrava-Poruba',
  odberatel_ico: '87654321', odberatel_dic: null,
  polozky: [
    polozka('Pronájem ledu — Dráha 1', '2026-08-03', 2, 1400),
    polozka('Turnaj „Ostravský kámen" — Dráha 1 i 2', '2026-08-10', 4, 1600),
    polozka('Trénink mládeže — Dráha 1', '2026-08-17', 1.5, 900),
  ],
  subtotal: 10950, total: 10950, total_rounded: 10950, rounding_amount: 0,
};
const SPAYD = 'SPD*1.0*ACC:CZ6508000000192000145399*AM:10950.00*CC:CZK*X-VS:20260001';

const vzorky = {
  // Běžná faktura neplátce — nejčastější doklad.
  'faktura-neplatce': [zaklad, SPAYD],
  // Uhrazená: NESMÍ mít QR ani „k úhradě".
  'faktura-uhrazena': [{ ...zaklad, datum_uhrady: '2026-08-20' }, SPAYD],
  // Plátce: sloupce daně a rekapitulace. Zatím se nedá vystavit (čeká na Q7),
  // proto je vzorek jediné místo, kde se ta větev dá vidět.
  'faktura-platce': [{
    ...zaklad, vat_mode: 'platce', dodavatel_dic: 'CZ12345678', odberatel_dic: 'CZ87654321',
    polozky: [
      polozka('Pronájem ledu — Dráha 1', '2026-08-03', 2, 1400, { vat_rate: 21, vat_base: 2800, vat_amount: 588 }),
      polozka('Občerstvení — bar', '2026-08-03', 1, 1000, { vat_rate: 12, vat_base: 1000, vat_amount: 120 }),
    ],
    subtotal: 3800, total: 4508, total_rounded: 4508,
  }, SPAYD],
  // Opravný doklad: jiný nadpis, věta o rušení, bez QR.
  'opravny-doklad': [{
    ...zaklad, cislo: '20260002', opravuje_cislo: '20260001', storno_duvod: 'Klub akci odvolal.',
  }, SPAYD],
  // Dlouhý doklad: kontrola stránkování a hlavičky na druhé straně.
  'faktura-dlouha': [{
    ...zaklad,
    polozky: Array.from({ length: 42 }, (_, i) =>
      polozka(`Pronájem ledu — Dráha ${(i % 2) + 1}`, `2026-08-${String((i % 28) + 1).padStart(2, '0')}`, 2, 1400)),
    subtotal: 117600, total: 117600, total_rounded: 117600,
  }, SPAYD],
};

for (const [nazev, [dto, spayd]] of Object.entries(vzorky)) {
  const bytes = await renderInvoice(dto, spayd);
  const cesta = join(kam, `${nazev}.pdf`);
  writeFileSync(cesta, bytes);
  console.log(`${cesta} (${Math.round(bytes.byteLength / 1024)} kB)`);
}
console.log('\nPodívej se na ně. Layout je jediná část dokladu, kterou testy neuhlídají.');
