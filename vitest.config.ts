import { defineConfig } from 'vitest/config';
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
    include: ['src/**/*.test.{ts,tsx}'],
  },
});
