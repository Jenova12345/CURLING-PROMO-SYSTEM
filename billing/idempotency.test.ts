import { describe, expect, it } from 'vitest';

import { jesteNevyfakturovane, klicAkce, klicKlubu } from './idempotency.ts';
import { BillingValidationError } from './errors.ts';

const KLUB = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
const AKCE = 'cccccccc-3333-4333-8333-cccccccccccc';

describe('klíč komerční akce', () => {
  it('má tvar akce-{eventId}', () => {
    expect(klicAkce(AKCE)).toBe(`akce-${AKCE}`);
  });

  it('je odvozený, ne náhodný — dvě volání dají týž klíč', () => {
    expect(klicAkce(AKCE)).toBe(klicAkce(AKCE));
  });
});

describe('klíč měsíčního souhrnu klubu', () => {
  it('má tvar klub-{clubId}-{RRRRMM}', () => {
    expect(klicKlubu(KLUB, '2026-08-01')).toBe(`klub-${KLUB}-202608`);
  });

  // Holé datum z `date` sloupce nemá časovou zónu. Kdyby se převádělo přes
  // `new Date()` (= UTC půlnoc), zářijový běh by mohl dostat srpnový klíč.
  it('holé datum se nepřevádí přes časovou zónu', () => {
    expect(klicKlubu(KLUB, '2026-09-01')).toBe(`klub-${KLUB}-202609`);
    expect(klicKlubu(KLUB, '2026-01-01')).toBe(`klub-${KLUB}-202601`);
  });

  // Naopak okamžik (timestamptz) se převést MUSÍ — a to do pražského času.
  // 31. 8. 22:30 UTC je v Praze už 1. 9., takže patří do zářijového dokladu.
  it('okamžik se převádí do pražského času', () => {
    expect(klicKlubu(KLUB, '2026-08-31T22:30:00Z')).toBe(`klub-${KLUB}-202609`);
    expect(klicKlubu(KLUB, '2026-08-31T20:30:00Z')).toBe(`klub-${KLUB}-202608`);
  });

  it('týž měsíc dá týž klíč bez ohledu na den v období', () => {
    expect(klicKlubu(KLUB, '2026-08-01')).toBe(klicKlubu(KLUB, '2026-08-31'));
  });
});

describe('tvar identifikátoru', () => {
  it('prázdné id je chyba, ne klíč „akce-“', () => {
    expect(() => klicAkce('')).toThrow(BillingValidationError);
    expect(() => klicAkce('   ')).toThrow(BillingValidationError);
  });

  // „klub--202608“ a „klub-x-202608“ se dají splést; navíc klíč jde do URL dotazu
  // u providera, takže lomítko nebo ampersand nejsou kosmetika.
  it('nepovolené znaky neprojdou', () => {
    expect(() => klicAkce('ev/1')).toThrow(BillingValidationError);
    expect(() => klicAkce('ev 1')).toThrow(BillingValidationError);
    expect(() => klicKlubu('a&b', '2026-08-01')).toThrow(BillingValidationError);
  });
});

describe('zámek 1 — jesteNevyfakturovane', () => {
  const rezervace = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];

  it('vyhodí ty, které už doklad nesou', () => {
    const uz = new Set(['b']);
    expect(jesteNevyfakturovane(rezervace, (id) => uz.has(id)).map((r) => r.id))
      .toEqual(['a', 'c']);
  });

  it('bez vyfakturovaných vrátí všechny', () => {
    expect(jesteNevyfakturovane(rezervace, () => false)).toHaveLength(3);
  });

  it('když jsou vyfakturované všechny, nezbyde nic (a doklad se pak nevystaví)', () => {
    expect(jesteNevyfakturovane(rezervace, () => true)).toHaveLength(0);
  });
});
