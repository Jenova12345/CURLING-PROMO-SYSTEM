import { defineConfig } from 'vitest/config';
import path from 'path';

// Konfigurace JEN pro integrační testy, které sahají na ŽIVÝ účet Fakturoidu.
//
// PROČ VLASTNÍ SOUBOR: `vitest.config.ts` integrační testy VYLUČUJE, aby na ně
// běžný `npm run test:run` nemohl sáhnout ani omylem. Přepsat to z příkazové
// řádky nejde — `--exclude` se k existujícímu seznamu přidává, nenahrazuje ho
// (ověřeno: „No test files found"). Druhá konfigurace je tedy jediný poctivý
// způsob, jak nechat běžný běh strukturálně bezpečný a přitom mít cestu, jak
// integrační testy pustit vědomě.
//
// Pouští se `npm run test:fakturoid`. Uvnitř souboru pořád platí dvojitá
// pojistka: `FAKTUROID_LIVE=true` A shoda `FAKTUROID_TEST_SLUG` s `FAKTUROID_SLUG`.
// Bez obojího se testy přeskočí.
export default defineConfig({
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
  test: {
    environment: 'node',
    // Široce, ne jen `billing/**`: hlavní konfigurace vylučuje
    // `**/*.integration.test.ts` GLOBÁLNĚ, takže integrační test kdekoli jinde
    // (třeba v `src/`) by se nespustil ani jedním během — a to je zrovna ta
    // „tiše nespouštěná sada", proti které argumentuje komentář v té hlavní.
    include: ['**/*.integration.test.ts'],
  },
});
