import { describe, expect, it } from 'vitest';
import { denZDb } from './datum';

// Chyba o jeden den se na dokladu pozná těžko a v QR platbě vůbec — proto se
// testuje tvar, který produkci skutečně přichází z PostgRESTu (holé `RRRR-MM-DD`),
// ne pohodlný `new Date(2026, 7, 27)`.

describe('denZDb — datum z `date` sloupce', () => {
  it('čte holé RRRR-MM-DD jako MÍSTNÍ půlnoc, ne UTC', () => {
    const d = denZDb('2026-08-27')!;
    expect(d.getFullYear()).toBe(2026);
    expect(d.getMonth()).toBe(7);   // srpen
    expect(d.getDate()).toBe(27);
    expect(d.getHours()).toBe(0);
  });

  it('nesklouzne o den u prvního dne měsíce', () => {
    // `new Date('2026-08-01')` je půlnoc UTC → v pásmu západně od Greenwiche
    // vyjde `getDate()` jako 31. července.
    const d = denZDb('2026-08-01')!;
    expect(d.getMonth()).toBe(7);
    expect(d.getDate()).toBe(1);
  });

  it('drží se přes celý rok, tedy i přes změnu letního času', () => {
    for (let m = 1; m <= 12; m++) {
      const zapis = `2026-${String(m).padStart(2, '0')}-01`;
      const d = denZDb(zapis)!;
      expect(d.getMonth()).toBe(m - 1);
      expect(d.getDate()).toBe(1);
    }
  });

  it('hodnotu s časem nechá projít beze změny', () => {
    const s = '2026-08-27T10:30:00+02:00';
    expect(denZDb(s)!.getTime()).toBe(new Date(s).getTime());
  });

  it('prázdnou hodnotu i nesmysl vrací jako null', () => {
    expect(denZDb(null)).toBeNull();
    expect(denZDb(undefined)).toBeNull();
    expect(denZDb('')).toBeNull();
    expect(denZDb('nedatum')).toBeNull();
  });
});
