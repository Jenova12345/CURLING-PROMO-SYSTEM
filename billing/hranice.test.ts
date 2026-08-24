// Testy HRANICE, ne logiky.
//
// Celá premisa `billing/` stojí na tom, že se tenhle kód nedostane do prohlížeče
// a že tajemství neopustí paměť. Obojí je dnes pravda, ale nic to nevynucuje:
// `npm run lint` je v tomhle repu červený už na HEADu (66 errors z Etapy 1),
// takže jako brána nefunguje a ESLint pravidlo by nikdo neuviděl.
//
// Tyhle testy jsou proto ta jediná fungující pojistka. Když někdo v budoucnu
// napíše `import { vystavDoklad } from '../../billing/pipeline'` v komponentě,
// spadne mu build sady — ne až audit za půl roku.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const KOREN = join(import.meta.dirname!, '..');

const vsechnySoubory = (adresar: string, pripony: string[]): string[] => {
  const nalezene: string[] = [];
  for (const polozka of readdirSync(adresar)) {
    const cesta = join(adresar, polozka);
    if (statSync(cesta).isDirectory()) {
      nalezene.push(...vsechnySoubory(cesta, pripony));
    } else if (pripony.some((p) => polozka.endsWith(p))) {
      nalezene.push(cesta);
    }
  }
  return nalezene;
};

describe('billing/ se nesmí dostat do frontendu', () => {
  it('žádný soubor v src/ neimportuje z billing/', () => {
    const hresici: string[] = [];

    for (const soubor of vsechnySoubory(join(KOREN, 'src'), ['.ts', '.tsx'])) {
      const obsah = readFileSync(soubor, 'utf8');
      // Chytá `from '../billing/x'`, `from '@/../billing/x'` i `import('…/billing/x')`.
      if (/from\s+['"][^'"]*\bbilling\//.test(obsah) || /import\(\s*['"][^'"]*\bbilling\//.test(obsah)) {
        hresici.push(soubor.replace(`${KOREN}/`, ''));
      }
    }

    expect(hresici,
      'Soubor v src/ importuje z billing/. Tím se serverová fakturační vrstva ' +
      'dostane do Vite bundlu a FAKTUROID_CLIENT_SECRET má cestu do prohlížeče.',
    ).toEqual([]);
  });

  it('billing/ nečte žádnou VITE_ proměnnou', () => {
    // Vite vystavuje `VITE_*` klientovi. Kdyby si sem někdo přitáhl klíč přes
    // `import.meta.env.VITE_FAKTUROID_CLIENT_SECRET`, byl by v bundlu u každého
    // návštěvníka — a vypadalo by to jako normální konfigurace.
    const hresici: string[] = [];

    for (const soubor of vsechnySoubory(join(KOREN, 'billing'), ['.ts'])) {
      if (soubor.includes('.test.')) continue;
      const obsah = readFileSync(soubor, 'utf8');
      if (/import\.meta\.env|VITE_[A-Z_]+/.test(obsah)) {
        hresici.push(soubor.replace(`${KOREN}/`, ''));
      }
    }

    expect(hresici).toEqual([]);
  });
});
