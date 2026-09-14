// Mutační pojistka k opravě „v Subjektech nejde přidat člověka do jiného klubu"
// (14. 9. 2026). Ta oprava byla celá v UI, takže SQL test databázové poloviny
// ji nedrží — projde stejně zeleně před opravou i po ní. Viz hlavička
// `stavSubjektu.ts`.
//
// Každý test níž odpovídá jedné konkrétní lži, kterou stránka uměla vyslovit.

import { describe, expect, it } from 'vitest';
import { stavSeznamuLidi, stavUlozeniUdaju } from './stavSubjektu';

const zaklad = { nacitaSe: false, chyba: null, pocetProfilu: 3, pocetDostupnych: 2 };

describe('stavSeznamuLidi — rozbalovátko „Přidat člověka…"', () => {
  it('normálně nabídne seznam', () => {
    expect(stavSeznamuLidi(zaklad)).toBe('seznam');
  });

  it('když jsou všichni přiřazení, řekne to — a neplete to s prázdnotou', () => {
    expect(stavSeznamuLidi({ ...zaklad, pocetDostupnych: 0 })).toBe('vse-prirazeno');
  });

  it('prázdný systém po ÚSPĚŠNÉM dotazu není selhání', () => {
    // Bez téhle větve tvrdila stránka „Seznam lidí se nenačetl." o dotazu,
    // který doběhl v pořádku (čistá databáze).
    expect(stavSeznamuLidi({ ...zaklad, pocetProfilu: 0, pocetDostupnych: 0 }))
      .toBe('nikdo-v-systemu');
  });

  it('selhání dotazu se nesmí tvářit jako „nikdo tu není"', () => {
    // Při chybě zůstane pole prázdné, takže `pocetProfilu === 0` platí taky.
    // Rozhoduje pořadí: `chyba` musí být dřív.
    expect(stavSeznamuLidi({ ...zaklad, chyba: new Error('síť'), pocetProfilu: 0, pocetDostupnych: 0 }))
      .toBe('chyba');
  });

  it('POŘADÍ: dokud se načítá, není to ani chyba, ani prázdno', () => {
    // Tohle je jádro nálezu N2. `retry: 3` znamená, že `chyba` naskočí až po
    // několika sekundách — a celou tu dobu dotaz BĚŽÍ. Kdyby `nacitaSe`
    // nepřebíjelo, tvrdilo by rozbalovátko „nenačetlo se" o živém dotazu.
    expect(stavSeznamuLidi({ nacitaSe: true, chyba: null, pocetProfilu: 0, pocetDostupnych: 0 }))
      .toBe('nacita');
    expect(stavSeznamuLidi({ nacitaSe: true, chyba: new Error('síť'), pocetProfilu: 0, pocetDostupnych: 0 }))
      .toBe('nacita');
  });

  it('POŘADÍ: chyba přebíjí prázdnotu i dostupnost', () => {
    expect(stavSeznamuLidi({ nacitaSe: false, chyba: new Error('síť'), pocetProfilu: 5, pocetDostupnych: 0 }))
      .toBe('chyba');
  });
});

describe('stavUlozeniUdaju — tlačítko „Uložit údaje"', () => {
  it('bez vybraného člověka je prosté „uloženo" pravda', () => {
    expect(stavUlozeniUdaju({ vybranyClovek: '' })).toBe('ulozeno');
  });

  it('JÁDRO HLÁŠENÍ: s vybraným člověkem se nesmí hlásit prostý úspěch', () => {
    // Uživatel vybral člověka a stiskl jediné tlačítko, které vypadá jako
    // uložení. Přiřazení se tím NEULOŽÍ — a systém dřív řekl „Uloženo".
    expect(stavUlozeniUdaju({ vybranyClovek: 'nejake-uuid' })).toBe('ulozeno-ale-clovek-ne');
  });
});
