import { configDefaults, defineConfig } from 'vitest/config';
import path from 'path';

// Testy běží mimo vite.config.ts schválně: ten tahá react-swc a lovable-tagger,
// které pro čistě výpočetní moduly (money, později iban/spayd) nejsou k ničemu.
// Až budou testy sahat na komponenty, přibude sem jsdom environment.
export default defineConfig({
  resolve: {
    // Alias musí zůstat shodný s vite.config.ts — kdyby se rozešly, testy by
    // rozlišovaly jiné moduly než build a nikdo by si toho nevšiml.
    alias: { '@': path.resolve(__dirname, './src') },
  },
  test: {
    environment: 'node',
    // I .tsx, ať se komponentové testy jednou tiše nepřeskočí.
    //
    // `billing/` je schválně MIMO `src/`: do `src/` sahá Vite bundle a
    // FAKTUROID_CLIENT_SECRET nesmí mít ani teoretickou cestu do prohlížeče.
    // Bez téhle druhé položky by se testy fakturační vrstvy tiše nespouštěly —
    // ne červeně, ale vůbec, což je horší.
    include: ['src/**/*.test.{ts,tsx}', 'billing/**/*.test.ts'],

    // INTEGRAČNÍ TESTY SE DO BĚŽNÉHO BĚHU NEPOČÍTAJÍ.
    //
    // Sahají na ŽIVÝ účet Fakturoidu a zakládají tam doklady. Dosud je držel
    // jen `describe.skipIf(!live)` v tom souboru, tedy proměnná v `.env` —
    // a kdo měl `FAKTUROID_LIVE=true` (což je běžný stav při práci na fakturaci),
    // tomu `npm run test:run` mlčky vystavoval doklady. Narazily na to obě brány
    // nezávisle, každá si myslela, že to způsobila sama.
    //
    // Vyloučení je STRUKTURÁLNÍ pojistka, ne dohoda: běžný běh na Fakturoid
    // nesáhne, ať je v `.env` cokoli. Pouští se výhradně `npm run test:fakturoid`,
    // a i tam pořád platí dvojitá pojistka na slug uvnitř souboru.
    // `configDefaults.exclude` se ZACHOVÁVÁ. Vlastní `exclude` totiž vitest
    // defaulty NAHRAZUJE, ne doplňuje — vypsat jen node_modules a dist by tiše
    // zahodilo `**/cypress/**`, `**/.git/**` a další. Dnes by to nevadilo
    // (`include` je úzký), ale je to past na příští rozšíření.
    exclude: [...configDefaults.exclude, '**/*.integration.test.ts'],
  },
});
