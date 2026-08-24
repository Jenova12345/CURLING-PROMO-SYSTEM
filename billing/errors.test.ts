import { describe, expect, it } from 'vitest';

import {
  BillingAuthError, BillingNetworkError, BillingProviderError, BillingRateLimitError,
  BillingValidationError, kodChyby, proUzivatele, uzivatelskaZprava,
} from './errors.ts';
import { mapujKomercniAkci } from './mapping.ts';
import { nactiConfig } from './providers/fakturoid/config.ts';

describe('zpráva pro uživatele nesmí nést, co nemá vidět', () => {
  // CLAUDE.md: částku a sazbu vidí jen admin a autor. Interní hlášky téhle
  // vrstvy je ale obsahují — `mapping.ts` je do nich dává schválně, aby šel
  // rozpor diagnostikovat. Poslat `err.message` do toastu je tichý únik.
  it('chyba z mapování nese sazbu interně, ale ne ven', () => {
    let chyba: unknown;
    try {
      mapujKomercniAkci({
        eventId: 'ev1',
        subjekt: { id: 's1', name: 'Firma', ico: null, dic: null, address: null },
        jePlatceDph: false,
        rezervace: [{
          id: 'r1', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T18:00:00Z',
          sheet_name: 'Dráha 1', event_title: null, hodiny: 2, sazba: 1200, castka: 9999,
        }],
      });
    } catch (e) { chyba = e; }

    const interni = (chyba as Error).message;
    expect(interni).toContain('1200');          // do logu ano
    expect(interni).toContain('9999');

    const ven = uzivatelskaZprava(chyba);
    expect(ven).not.toContain('1200');          // na obrazovku ne
    expect(ven).not.toContain('9999');
    expect(ven).toMatch(/Podklad k fakturaci/);
  });

  // Test si chybu SCHVÁLNĚ nekonstruuje ručně — jinak by ověřoval jen
  // klasifikátor, ne skutečné místo vzniku. `nactiConfig` dřív `pole` nevyplnil,
  // takže nenastavený klíč vypadal jako vadný podklad a admin hledal chybu
  // v rezervacích.
  it('chybějící konfigurace se hlásí jako konfigurace, ne jako vadný podklad', () => {
    let chyba: unknown;
    try {
      nactiConfig({ FAKTUROID_SLUG: 'x' });
    } catch (e) { chyba = e; }

    expect(kodChyby(chyba)).toBe('nastaveni');
    expect(uzivatelskaZprava(chyba)).toMatch(/není správně nastavené/);
    expect(uzivatelskaZprava(chyba)).not.toContain('FAKTUROID');
  });

  it('tělo odpovědi providera se ven nedostane', () => {
    const chyba = new BillingProviderError('Fakturoid odpověděl 422.', 422, '{"name":"Tajný klub"}');
    expect(uzivatelskaZprava(chyba)).not.toContain('Tajný klub');
  });
});

describe('kód chyby', () => {
  it('rozliší druhy, ať se UI umí zachovat bez čtení textu', () => {
    expect(kodChyby(new BillingAuthError('x'))).toBe('prihlaseni');
    expect(kodChyby(new BillingRateLimitError('x'))).toBe('zahlceno');
    expect(kodChyby(new BillingNetworkError('x'))).toBe('spojeni');
    expect(kodChyby(new BillingProviderError('x', 500))).toBe('provider');
    expect(kodChyby(new BillingValidationError('x', 'castka'))).toBe('podklad');
    expect(kodChyby(new Error('x'))).toBe('neznama');
  });

  it('přechodné chyby nabídnou „zkuste to za chvíli“, trvalé ne', () => {
    expect(uzivatelskaZprava(new BillingRateLimitError('x'))).toMatch(/za chvíli/);
    expect(uzivatelskaZprava(new BillingNetworkError('x'))).toMatch(/za chvíli/);
    expect(uzivatelskaZprava(new BillingAuthError('x'))).not.toMatch(/za chvíli/);
  });
});

describe('proUzivatele — dvojice pro volajícího', () => {
  it('vrací interní zprávu zvlášť od té ven', () => {
    const v = proUzivatele(new BillingProviderError('Fakturoid odpověděl 500.', 500));
    expect(v.interni).toBe('Fakturoid odpověděl 500.');
    expect(v.zprava).not.toBe(v.interni);
    expect(v.kod).toBe('provider');
  });

  it('zvládne i to, co není Error', () => {
    expect(proUzivatele('rozbité').interni).toBe('rozbité');
    expect(proUzivatele('rozbité').kod).toBe('neznama');
  });
});
