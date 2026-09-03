import { describe, it, expect } from 'vitest';
import { bezZrusenychAkci } from './nabidkySmen';

const smena = (id: string, event_id: string | null, status = 'open') => ({
  id,
  event_id,
  status,
});

describe('bezZrusenychAkci', () => {
  it('skryje směnu zrušené akce', () => {
    const vstup = [smena('s1', 'a-zivá'), smena('s2', 'a-zrušená')];
    const vysledek = bezZrusenychAkci(vstup, new Set(['a-zrušená']));
    expect(vysledek.map((s) => s.id)).toEqual(['s1']);
  });

  it('nechá nabídky živých akcí být', () => {
    const vstup = [smena('s1', 'a1'), smena('s2', 'a2')];
    expect(bezZrusenychAkci(vstup, new Set(['a3']))).toHaveLength(2);
  });

  // Nejdůležitější případ. Kdyby RPC selhala nebo se ještě nenačetla, přijde
  // prázdná množina — a rozpis musí zůstat celý. Filtr, který v tu chvíli
  // schová všechno, by z opravy udělal větší škodu než původní bug.
  it('při prázdné množině neskryje nic', () => {
    const vstup = [smena('s1', 'a1'), smena('s2', 'a2')];
    expect(bezZrusenychAkci(vstup, new Set())).toHaveLength(2);
  });

  // Starší směny vedené přes `events.required_staff` mají event_id NULL.
  // Nemají se k čemu vztáhnout, takže se skrývat nesmějí.
  it('směnu bez akce neskryje', () => {
    const vstup = [smena('s1', null)];
    expect(bezZrusenychAkci(vstup, new Set(['a1']))).toHaveLength(1);
  });
});
