import { describe, it, expect } from 'vitest';
import { nadchazejiciAkce } from './nadchazejiciAkce';

const TED = new Date('2026-09-14T12:00:00Z');
const akce = (id: string, start_time: string) => ({ id, start_time });

const BUDOUCI = akce('a-budouci', '2026-09-20T15:00:00Z');
const MINULA = akce('a-minula', '2026-09-01T15:00:00Z');

describe('nadchazejiciAkce', () => {
  it('skryje zrušenou akci, i když teprve bude', () => {
    const vstup = [BUDOUCI, akce('a-zrušená', '2026-09-21T15:00:00Z')];
    const vysledek = nadchazejiciAkce(vstup, new Set(['a-zrušená']), TED);
    expect(vysledek.map((a) => a.id)).toEqual(['a-budouci']);
  });

  it('skryje minulou akci', () => {
    expect(nadchazejiciAkce([BUDOUCI, MINULA], new Set(), TED).map((a) => a.id))
      .toEqual(['a-budouci']);
  });

  // Nejdůležitější případ, stejný jako u `bezZrusenychAkci`. Kdyby RPC selhala
  // nebo se ještě nenačetla, přijde prázdná množina — a Přehled musí zůstat
  // celý. Filtr, který v tu chvíli schová všechno, by z opravy udělal větší
  // škodu než původní bug.
  it('při prázdné množině zrušených neskryje nic budoucího', () => {
    const vstup = [BUDOUCI, akce('a2', '2026-09-22T15:00:00Z')];
    expect(nadchazejiciAkce(vstup, new Set(), TED)).toHaveLength(2);
  });

  it('nečitelné datum raději ukáže, než aby ho spolkl', () => {
    const vstup = [akce('a-rozbitá', 'nedatum')];
    expect(nadchazejiciAkce(vstup, new Set(), TED)).toHaveLength(1);
  });

  // Pořadí drží volající (`useEvents` řadí podle `start_time` v SQL). Filtr ho
  // nesmí přeházet, jinak by „nejbližší akce" nebyly nejbližší.
  it('zachová pořadí vstupu', () => {
    const vstup = [
      akce('a1', '2026-09-15T10:00:00Z'),
      akce('a2', '2026-09-16T10:00:00Z'),
      akce('a3', '2026-09-17T10:00:00Z'),
    ];
    expect(nadchazejiciAkce(vstup, new Set(['a2']), TED).map((a) => a.id))
      .toEqual(['a1', 'a3']);
  });
});
