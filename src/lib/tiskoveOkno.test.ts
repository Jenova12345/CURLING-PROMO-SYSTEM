import { beforeEach, describe, expect, it, vi } from 'vitest';
import { otevriTiskovouStranku, zapomenPosledniOkno, type TiskoveOkno } from './tiskoveOkno';

// Regresní testy k P0 ze 14. 8. 2026: druhé generování podkladu v jedné session
// zamrzlo hlavní vlákno appky. Sešly se dvě příčiny — `print()` volaný ze stacku
// hlavního okna (modální dialog blokuje sdílený renderer proces) a nezavírané
// předchozí okno. Obojí se dá otestovat bez prohlížeče, protože otevírač je
// vstříknutelný.

/** Falešné okno, které si pamatuje, co se s ním dělo. */
function fakeOkno() {
  const zapsano: string[] = [];
  const okno = {
    zapsano,
    zavreno: false,
    zavolanoFocus: 0,
    document: {
      write: (html: string) => { zapsano.push(html); },
      close: vi.fn(),
    },
    focus() { okno.zavolanoFocus += 1; },
    close() { okno.zavreno = true; },
    get closed() { return okno.zavreno; },
  };
  return okno;
}

function otevirac() {
  const okna: ReturnType<typeof fakeOkno>[] = [];
  const fn = vi.fn(() => {
    const o = fakeOkno();
    okna.push(o);
    return o as unknown as TiskoveOkno;
  });
  return { fn, okna };
}

beforeEach(() => zapomenPosledniOkno());

describe('otevriTiskovouStranku — dvě generování po sobě (P0)', () => {
  it('druhé generování projde a ZAVŘE okno z prvního', () => {
    const { fn, okna } = otevirac();

    expect(otevriTiskovouStranku('<html><body>první</body></html>', fn)).toBe(true);
    expect(otevriTiskovouStranku('<html><body>druhé</body></html>', fn)).toBe(true);

    expect(okna).toHaveLength(2);
    // Tohle je jádro chyby: bez zavření se popupy hromadily a druhý tisk se zasekl.
    expect(okna[0].zavreno).toBe(true);
    expect(okna[1].zavreno).toBe(false);
    expect(okna[1].zapsano[0]).toContain('druhé');
  });

  it('vydrží i pět generování za sebou a nechá otevřené vždycky jen poslední', () => {
    const { fn, okna } = otevirac();
    for (let i = 0; i < 5; i++) {
      expect(otevriTiskovouStranku(`<html><body>${i}</body></html>`, fn)).toBe(true);
    }
    expect(okna).toHaveLength(5);
    expect(okna.slice(0, 4).every((o) => o.zavreno)).toBe(true);
    expect(okna[4].zavreno).toBe(false);
  });

  it('okno zavřené uživatelem se znovu zavírat nepokouší', () => {
    const { fn, okna } = otevirac();
    otevriTiskovouStranku('<html><body>první</body></html>', fn);

    okna[0].zavreno = true;                       // uživatel ho zavřel sám
    const spy = vi.spyOn(okna[0], 'close');
    expect(otevriTiskovouStranku('<html><body>druhé</body></html>', fn)).toBe(true);
    expect(spy).not.toHaveBeenCalled();
  });

  it('výjimka při zavírání předchozího okna další generování nezastaví', () => {
    // Přístup na `closed` u okna z cizího kontextu může vyhodit — a kdyby to
    // shodilo celé volání, uživatel by po jednom zavřeném okně nevytiskl nic.
    const { fn, okna } = otevirac();
    otevriTiskovouStranku('<html><body>první</body></html>', fn);
    Object.defineProperty(okna[0], 'closed', {
      get() { throw new Error('cross-origin'); },
    });

    expect(otevriTiskovouStranku('<html><body>druhé</body></html>', fn)).toBe(true);
    expect(okna).toHaveLength(2);
  });
});

describe('otevriTiskovouStranku — tisk spouští stránka, ne appka', () => {
  it('do stránky vloží spouštěč tisku a appka print() sama nevolá', () => {
    const { fn, okna } = otevirac();
    otevriTiskovouStranku('<html><body>obsah</body></html>', fn);

    const html = okna[0].zapsano[0];
    expect(html).toContain('window.print()');
    expect(html).toContain("addEventListener('load'");
    // Okno nemá `print` vůbec — kdyby ho appka volala, test spadne na undefined.
    expect((okna[0] as unknown as { print?: unknown }).print).toBeUndefined();
  });

  it('spouštěč se vloží PŘED </body>, ať se stihne navázat na load', () => {
    const { fn, okna } = otevirac();
    otevriTiskovouStranku('<html><body>obsah</body></html>', fn);
    const html = okna[0].zapsano[0];
    expect(html.indexOf('window.print()')).toBeLessThan(html.indexOf('</body>'));
    expect(html.endsWith('</body></html>')).toBe(true);
  });

  it('po vytištění se stránka zavře sama', () => {
    const { fn, okna } = otevirac();
    otevriTiskovouStranku('<html><body>obsah</body></html>', fn);
    expect(okna[0].zapsano[0]).toContain("addEventListener('afterprint'");
    expect(okna[0].zapsano[0]).toContain('window.close()');
  });
});

describe('otevriTiskovouStranku — okrajové případy', () => {
  it('zablokovaný popup vrátí false, ne výjimku', () => {
    expect(otevriTiskovouStranku('<html><body>x</body></html>', () => null)).toBe(false);
  });

  it('po zablokovaném popupu funguje další pokus', () => {
    const { fn, okna } = otevirac();
    expect(otevriTiskovouStranku('<html><body>x</body></html>', () => null)).toBe(false);
    expect(otevriTiskovouStranku('<html><body>y</body></html>', fn)).toBe(true);
    expect(okna).toHaveLength(1);
  });

  it('když zápis do okna selže, nenechá po sobě viset prázdný popup', () => {
    const rozbite = {
      document: {
        write: () => { throw new Error('write selhal'); },
        close: vi.fn(),
      },
      focus: vi.fn(),
      zavreno: false,
      close() { rozbite.zavreno = true; },
      get closed() { return rozbite.zavreno; },
    };
    expect(otevriTiskovouStranku('<html><body>x</body></html>',
      () => rozbite as unknown as TiskoveOkno)).toBe(false);
    expect(rozbite.zavreno).toBe(true);
  });

  it('spouštěč se vloží i do stránky bez </body>, ať tisk tiše nezmizí', () => {
    const { fn, okna } = otevirac();
    otevriTiskovouStranku('<html>bez body</html>', fn);
    expect(okna[0].zapsano[0]).toContain('window.print()');
  });

  it('nahrazuje přes funkci — „$&" v HTML nesmí sežrat kus stránky', () => {
    // Řetězcová náhrada by `$&` v okolním HTML rozvinula na shodu a stránku
    // tiše poškodila. Test hlídá, že se obsah přenese doslova.
    const { fn, okna } = otevirac();
    otevriTiskovouStranku('<html><body>cena $&amp; poplatek $1</body></html>', fn);
    expect(okna[0].zapsano[0]).toContain('cena $&amp; poplatek $1');
  });

  it('okno se otevírá bez noopener — s ním by window.open vrátil null', () => {
    const { fn } = otevirac();
    otevriTiskovouStranku('<html><body>x</body></html>', fn);
    expect(fn).toHaveBeenCalledWith('', '_blank', expect.not.stringContaining('noopener'));
  });
});
