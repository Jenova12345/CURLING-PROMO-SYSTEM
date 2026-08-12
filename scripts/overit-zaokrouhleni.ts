// Křížové ověření kanonického pravidla R3 proti ŽIVÉMU Postgresu.
//
// Spuštění (vyžaduje běžící lokální stack — `supabase start`):
//   npm run overit:zaokrouhleni
//
// PROČ TENHLE SKRIPT EXISTUJE:
// `src/lib/money.test.ts` ověřuje JS proti referenci napsané v JS. To chytí
// spoustu chyb, ale ne tu nejzákeřnější — že se celý modul shodne sám se sebou
// a přitom se rozejde s databází, která je pro peníze skutečnou autoritou.
// Jediné, co takový rozchod odhalí, je porovnání proti opravdovému `numeric`.
// Přesně takhle se našlo, že `roundCzk` zaokrouhloval dvakrát.
//
// Zároveň je tenhle skript zdrojem čísel citovaných v R3 (docs/etapa2-fakturace-plan.md).
// Když se čísla v dokumentaci mají o čem opřít, musí je jít přeměřit — proto skript,
// ne ručně opsaný výsledek.
//
// Vzorek je určený deterministicky (viz `VZOREK` níž), takže dvě spuštění dají
// tentýž počet hodnot.

import { execFileSync } from 'node:child_process';
import { roundCzk, toSetiny, zeSetin } from '../src/lib/money';

const KONTEJNER = 'supabase_db_ltrazktulfxvzlvkxdsb';

// Vzorek schválně míchá pět tvarů, protože každý testuje něco jiného:
//   1) dnešní reálné vstupy (dvoudesetinné částky),
//   2) hranice půlhaléře .xx5 — tam se láme fáze 1,
//   3) totéž záporně (dobropisy),
//   4) DPH `základ × 0,21` — vstupy, které teprve přijdou,
//   5) čtyři desetinná místa — chování hloub pod hranicí.
const VZOREK = `
WITH hodnoty AS (
  SELECT (g::numeric / 100) AS v FROM generate_series(-20000, 20000, 7) g
  UNION ALL
  SELECT (g::numeric * 10 + 5) / 1000 FROM generate_series(0, 4000) g
  UNION ALL
  SELECT -((g::numeric * 10 + 5) / 1000) FROM generate_series(0, 4000) g
  UNION ALL
  SELECT round((g::numeric / 2) * 0.21, 6) FROM generate_series(1, 4000) g
  UNION ALL
  SELECT -round((g::numeric / 2) * 0.21, 6) FROM generate_series(1, 4000) g
  UNION ALL
  SELECT (g::numeric * 5 + 25) / 10000 FROM generate_series(0, 4000) g
)
SELECT v, round(v, 2), round(round(v, 2), 0), round(v, 0) FROM hodnoty;
`;

function zeptejSeDatabaze(sql: string): string[] {
  try {
    return execFileSync(
      'docker',
      ['exec', '-i', KONTEJNER, 'psql', '-U', 'postgres', '-X', '-q', '-A', '-t', '-F', '|', '-v', 'ON_ERROR_STOP=1'],
      { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
    ).trim().split('\n');
  } catch {
    console.error(`Nepodařilo se dosáhnout na kontejner „${KONTEJNER}".`);
    console.error('Běží lokální stack? Zkus `supabase start` a `supabase status`.');
    process.exit(2);
  }
}

const radky = zeptejSeDatabaze(VZOREK);

let rozdilyHalere = 0;
let rozdilyKoruny = 0;
let stagedVsJednoraz = 0;
const ukazky: string[] = [];

for (const radek of radky) {
  const [vRaw, pgHalere, pgStaged, pgJednoraz] = radek.split('|');
  const v = Number(vRaw);

  // Fáze 1 — kvantizace na haléře.
  if (zeSetin(toSetiny(v)) !== Number(pgHalere)) {
    rozdilyHalere++;
    if (ukazky.length < 8) ukazky.push(`haléře: ${vRaw} → JS ${zeSetin(toSetiny(v))}, PG ${pgHalere}`);
  }

  // Fáze 2 — kanonické stupňovité zaokrouhlení na celé koruny.
  if (roundCzk(v) !== Number(pgStaged)) {
    rozdilyKoruny++;
    if (ukazky.length < 8) ukazky.push(`koruny: ${vRaw} → JS ${roundCzk(v)}, PG ${pgStaged}`);
  }

  // Kolik hodnot by dopadlo jinak, kdyby se zaokrouhlovalo jednorázově ze surové
  // hodnoty. Není to chyba — je to důkaz, že volba pravidla není kosmetická.
  if (Number(pgStaged) !== Number(pgJednoraz)) stagedVsJednoraz++;
}

const procenta = ((stagedVsJednoraz / radky.length) * 100).toFixed(2);

console.log(`vzorek: ${radky.length} hodnot`);
console.log(`rozdílů JS vs round(v, 2):              ${rozdilyHalere}`);
console.log(`rozdílů JS vs round(round(v, 2), 0):    ${rozdilyKoruny}`);
console.log(`stupňovitě ≠ jednorázově:               ${stagedVsJednoraz} (${procenta} %)`);
if (ukazky.length) {
  console.log('ukázky rozdílů:');
  ukazky.forEach((u) => console.log('  ' + u));
}

const sedi = rozdilyHalere + rozdilyKoruny === 0;
console.log(sedi ? '=== JS ODPOVÍDÁ KANONICKÉMU PRAVIDLU R3 ===' : '=== JS A POSTGRES SE ROZEŠLY ===');
process.exit(sedi ? 0 : 1);
