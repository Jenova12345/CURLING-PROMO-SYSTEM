import { describe, it, expect } from 'vitest';
import { bezZrusenychAkci, jenNeskoncene } from './nabidkySmen';

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

const TED = new Date('2026-09-14T12:00:00Z');
const sEventem = (id: string, end_time: string | null) => ({
  id,
  event_id: 'a1',
  event: end_time === null ? null : { end_time },
});

describe('jenNeskoncene', () => {
  it('skryje směnu akce, která už skončila', () => {
    const vstup = [
      sEventem('s-stará', '2026-09-14T11:00:00Z'),
      sEventem('s-budoucí', '2026-09-20T18:00:00Z'),
    ];
    expect(jenNeskoncene(vstup, TED).map((s) => s.id)).toEqual(['s-budoucí']);
  });

  // Nejdůležitější rozlišení téhle funkce: hranice je KONEC akce, ne začátek.
  // Akce, která zrovna běží, se pořád dá obsadit (nemoc, náhrada na zbytek) —
  // filtr podle `start_time` by přesně tenhle případ zahodil.
  it('běžící akci nechá v nabídce', () => {
    const vstup = [sEventem('s-běží', '2026-09-14T14:00:00Z')];
    expect(jenNeskoncene(vstup, TED)).toHaveLength(1);
  });

  // Stejná úvaha jako u `bezZrusenychAkci`: „nevím, kdy to je" není „už to bylo".
  // Kdyby se nenačetla vnořená akce, nesmí zhasnout celý rozpis.
  it('směnu bez akce ani bez konce neskryje', () => {
    const vstup = [sEventem('s-bez-akce', null), sEventem('s-bez-konce', '')];
    expect(jenNeskoncene(vstup, TED)).toHaveLength(2);
  });

  it('nečitelné datum raději ukáže, než aby ho spolkl', () => {
    expect(jenNeskoncene([sEventem('s-rozbitá', 'nedatum')], TED)).toHaveLength(1);
  });
});
