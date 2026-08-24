import { describe, expect, it, vi } from 'vitest';

import { FakturoidProvider } from './index.ts';
import { nactiConfig, zakladUrl } from './config.ts';
import { basicHlavicka, TOKEN_URL, TokenCache } from './auth.ts';
import {
  prodlevaPoLimitu, smiSeOpakovat, type FetchFn, type HttpOdpoved, type HttpPozadavek,
} from './http.ts';
import {
  BillingAuthError, BillingProviderError, BillingRateLimitError, BillingValidationError,
} from '../../errors.ts';
import type { InvoiceDraft } from '../../types.ts';

const ENV = {
  FAKTUROID_SLUG: 'curling-promo',
  FAKTUROID_CLIENT_ID: 'id123',
  FAKTUROID_CLIENT_SECRET: 'secret456',
  FAKTUROID_USER_AGENT: 'CurlingPromo (kontakt@curling.cz)',
  BILLING_DUE_DAYS: '14',
  IS_VAT_PAYER: 'false',
  FAKTUROID_LIVE: 'false',
};

const CONFIG = nactiConfig(ENV);

/** Odpověď pro mock fetch. */
const odpoved = (
  status: number,
  telo: unknown = null,
  hlavicky: Record<string, string> = {},
): HttpOdpoved => ({
  status,
  headers: { get: (n) => hlavicky[n] ?? hlavicky[n.toLowerCase()] ?? null },
  text: async () => (typeof telo === 'string' ? telo : JSON.stringify(telo)),
  arrayBuffer: async () => new TextEncoder().encode(String(telo)).buffer as ArrayBuffer,
});

/** Mock fetch, který odpovídá podle pořadí zadaných obsluh. */
const mockFetch = (obsluhy: Array<(url: string, init?: HttpPozadavek) => HttpOdpoved>) => {
  const volani: Array<{ url: string; init?: HttpPozadavek }> = [];
  let i = 0;
  const fn: FetchFn = async (url, init) => {
    volani.push({ url, init });
    const obsluha = obsluhy[Math.min(i++, obsluhy.length - 1)];
    return obsluha(url, init);
  };
  return { fn, volani };
};

const TOKEN_OK = () => odpoved(200, { access_token: 'tok-1', token_type: 'Bearer', expires_in: 7200 });
const hnedCekej = async () => {};

const DRAFT: InvoiceDraft = {
  type: 'club_monthly',
  idempotencyKey: 'klub-abc-202608',
  party: { ourSubjectId: 'abc', name: 'SK Curling Ostrava', registrationNo: '26512345', country: 'CZ' },
  lines: [{ name: '22.08. 18:00–19:00 · Trénink', quantity: 1.5, unitName: 'h', unitPrice: 833.67 }],
  dueInDays: 14,
  sourceReservationIds: ['r1'],
};

describe('config', () => {
  it('vyjmenuje, co chybí — a NEvypisuje hodnoty tajemství', () => {
    try {
      nactiConfig({ FAKTUROID_SLUG: 'x', FAKTUROID_CLIENT_SECRET: 'tajne' });
      throw new Error('mělo to spadnout');
    } catch (e) {
      expect(e).toBeInstanceOf(BillingValidationError);
      const zprava = (e as Error).message;
      expect(zprava).toContain('FAKTUROID_CLIENT_ID');
      expect(zprava).toContain('FAKTUROID_USER_AGENT');
      expect(zprava).not.toContain('tajne');
    }
  });

  it('odmítne nesmyslnou splatnost', () => {
    expect(() => nactiConfig({ ...ENV, BILLING_DUE_DAYS: '0' })).toThrow(BillingValidationError);
    expect(() => nactiConfig({ ...ENV, BILLING_DUE_DAYS: '-5' })).toThrow(BillingValidationError);
    expect(() => nactiConfig({ ...ENV, BILLING_DUE_DAYS: 'čtrnáct' })).toThrow(BillingValidationError);
  });

  it('FAKTUROID_LIVE a IS_VAT_PAYER jsou default vypnuté', () => {
    const c = nactiConfig({ ...ENV, FAKTUROID_LIVE: undefined, IS_VAT_PAYER: undefined });
    expect(c.live).toBe(false);
    expect(c.jePlatceDph).toBe(false);
  });

  it('slug se do URL escapuje', () => {
    expect(zakladUrl('a b')).toBe('https://app.fakturoid.cz/api/v3/accounts/a%20b');
  });
});

describe('OAuth client_credentials', () => {
  it('posílá Basic hlavičku a grant_type do /oauth/token', async () => {
    const { fn, volani } = mockFetch([TOKEN_OK]);
    const cache = new TokenCache({ ...CONFIG, fetch: fn, userAgent: CONFIG.userAgent, cekej: hnedCekej });

    expect(await cache.token()).toBe('tok-1');
    expect(volani[0].url).toBe(TOKEN_URL);
    expect(volani[0].init?.headers?.Authorization).toBe(basicHlavicka('id123', 'secret456'));
    expect(JSON.parse(volani[0].init?.body ?? '{}')).toEqual({ grant_type: 'client_credentials' });
  });

  it('token se cachuje — druhé volání už na síť nejde', async () => {
    const { fn, volani } = mockFetch([TOKEN_OK]);
    const cache = new TokenCache({ ...CONFIG, fetch: fn, userAgent: CONFIG.userAgent, cekej: hnedCekej });

    await cache.token();
    await cache.token();
    expect(volani).toHaveLength(1);
  });

  it('obnoví se PŘED vypršením, ne až po něm', async () => {
    let ted = 1_000_000;
    const { fn, volani } = mockFetch([TOKEN_OK]);
    const cache = new TokenCache({
      ...CONFIG, fetch: fn, userAgent: CONFIG.userAgent, cekej: hnedCekej, ted: () => ted,
    });

    await cache.token();
    // Token platí 2 h; rezerva je minuta. Ve 2 h mínus 30 s už musí být za neplatný —
    // jinak by vypršel cestou a chyba přišla uprostřed vystavování dokladu.
    ted += 7200_000 - 30_000;
    await cache.token();
    expect(volani).toHaveLength(2);
  });

  it('deset souběžných požadavků si vyžádá JEDEN token', async () => {
    const { fn, volani } = mockFetch([TOKEN_OK]);
    const cache = new TokenCache({ ...CONFIG, fetch: fn, userAgent: CONFIG.userAgent, cekej: hnedCekej });

    await Promise.all(Array.from({ length: 10 }, () => cache.token()));
    expect(volani).toHaveLength(1);
  });

  // Kontrola je na TISKNUTELNÉ ASCII, ne „mimo Latin-1". Nezlomitelný mezerník
  // (U+00A0) do Latin-1 patří, takže dřívější verze ho pustila — a přihlášení
  // pak selhalo na 401, což vypadá jako špatný klíč, ne jako překlep při kopírování.
  it('neviditelný znak v klíči odmítne, a to i nezlomitelný mezerník', () => {
    expect(() => basicHlavicka('id', 'secret\u00A0x')).toThrow(BillingAuthError);
    expect(() => basicHlavicka('id', 'secret\u2013x')).toThrow(BillingAuthError);
    expect(() => basicHlavicka('id', 'secret x')).toThrow(BillingAuthError);
    expect(() => basicHlavicka('id', 'secret\nx')).toThrow(BillingAuthError);
    expect(() => basicHlavicka('id123', 'abcDEF_-.~09')).not.toThrow();
  });

  it('chybová hláška NEVYPISUJE hodnotu klíče', () => {
    try {
      basicHlavicka('id', 'tajne\u00A0heslo');
      throw new Error('mělo to spadnout');
    } catch (e) {
      expect((e as Error).message).not.toContain('tajne');
    }
  });
});

describe('povinné hlavičky a rate limit', () => {
  const provider = (obsluhy: Parameters<typeof mockFetch>[0], pokusu?: number) => {
    const { fn, volani } = mockFetch(obsluhy);
    return {
      p: new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej, pokusu }),
      volani,
    };
  };

  it('User-Agent jde v KAŽDÉM požadavku (bez něj Fakturoid vrací 400)', async () => {
    const { p, volani } = provider([
      TOKEN_OK,
      () => odpoved(200, [{ id: 7, custom_id: 'subj-abc' }]),
    ]);
    await p.ensureSubject(DRAFT.party);
    expect(volani).toHaveLength(2);
    for (const v of volani) {
      expect(v.init?.headers?.['User-Agent']).toBe('CurlingPromo (kontakt@curling.cz)');
    }
  });

  it('429 se zopakuje a napodruhé projde', async () => {
    const { p, volani } = provider([
      TOKEN_OK,
      () => odpoved(429, '', { 'X-RateLimit-Reset': '1' }),
      () => odpoved(200, [{ id: 7, custom_id: 'subj-abc' }]),
    ]);
    expect(await p.ensureSubject(DRAFT.party)).toEqual({ providerSubjectId: '7' });
    expect(volani).toHaveLength(3);
  });

  it('trvalé 429 skončí BillingRateLimitError, ne tichým selháním', async () => {
    const { p } = provider([TOKEN_OK, () => odpoved(429, '', { 'Retry-After': '2' })], 2);
    await expect(p.ensureSubject(DRAFT.party)).rejects.toBeInstanceOf(BillingRateLimitError);
  });

  it('prodleva se bere z hlavičky, ale se stropem — rozbitá hodnota neuspí Edge funkci', () => {
    expect(prodlevaPoLimitu(odpoved(429, '', { 'Retry-After': '3' }), 1)).toBe(3000);
    expect(prodlevaPoLimitu(odpoved(429, '', { 'X-RateLimit-Reset': '9999' }), 1)).toBe(60_000);
    expect(prodlevaPoLimitu(odpoved(429, ''), 3)).toBe(2000);   // backoff bez hlavičky
  });

  it('5xx se opakuje, 4xx ne', async () => {
    const { p, volani } = provider([TOKEN_OK, () => odpoved(500, 'nope')], 2);
    await expect(p.ensureSubject(DRAFT.party)).rejects.toBeInstanceOf(BillingProviderError);
    expect(volani).toHaveLength(3);          // token + dva pokusy

    const { p: p2, volani: v2 } = provider([TOKEN_OK, () => odpoved(422, '{"errors":{}}')], 3);
    await expect(p2.ensureSubject(DRAFT.party)).rejects.toBeInstanceOf(BillingProviderError);
    expect(v2).toHaveLength(2);              // token + jediný pokus
  });

  // 500 po POSTu neříká „nestalo se nic", ale „nevím, jak to dopadlo". Fakturoid
  // mohl doklad založit a spadnout až při skládání odpovědi — retry by vystavil
  // DRUHÝ doklad se stejným custom_id, protože custom_id není unikátní klíč.
  it('POST se po 5xx NEOPAKUJE — jinak by vznikl druhý doklad', async () => {
    const { p, volani } = provider([
      TOKEN_OK,
      () => odpoved(200, [{ id: 7, custom_id: 'subj-abc' }]),
      () => odpoved(500, 'oops'),
    ], 4);

    await expect(p.createInvoice(DRAFT, '7')).rejects.toBeInstanceOf(BillingProviderError);
    // token + jediný POST. Kdyby se opakoval, bylo by volání víc.
    expect(volani.filter((v) => v.init?.method === 'POST' && v.url.includes('/invoices.json')))
      .toHaveLength(1);
  });

  it('GET se po 5xx opakovat SMÍ — čtení nic nezakládá', async () => {
    const { p, volani } = provider([TOKEN_OK, () => odpoved(503, '')], 3);
    await expect(p.findExistingInvoice('klub-abc-202608')).rejects.toBeInstanceOf(BillingProviderError);
    expect(volani.filter((v) => v.url.includes('/invoices.json'))).toHaveLength(3);
  });

  it('429 se opakuje i u POSTu — „odmítnuto“ není „nevím, jak to dopadlo“', async () => {
    const { p, volani } = provider([
      TOKEN_OK,
      () => odpoved(429, '', { 'Retry-After': '1' }),
      () => odpoved(201, {
        id: 5, number: '20260001', variable_symbol: '20260001',
        public_html_url: null, status: 'open', custom_id: DRAFT.idempotencyKey, total: '1250.51',
      }),
    ]);
    expect((await p.createInvoice(DRAFT, '7')).providerInvoiceId).toBe('5');
    expect(volani).toHaveLength(3);
  });

  it('smiSeOpakovat: GET ano, POST ne, explicitní přepis vyhrává', () => {
    const zaklad = { fetch: (async () => odpoved(200)) as FetchFn, userAgent: 'x' };
    expect(smiSeOpakovat({}, zaklad)).toBe(true);                          // default GET
    expect(smiSeOpakovat({ method: 'GET' }, zaklad)).toBe(true);
    expect(smiSeOpakovat({ method: 'POST' }, zaklad)).toBe(false);
    expect(smiSeOpakovat({ method: 'post' }, zaklad)).toBe(false);         // nezávisle na velikosti písmen
    expect(smiSeOpakovat({ method: 'POST' }, { ...zaklad, opakovatNa5xx: true })).toBe(true);
  });

  it('401 zahodí token a zkusí to JEDNOU znovu; druhé 401 je chyba autentizace', async () => {
    let poradi = 0;
    const { fn, volani } = mockFetch([(url) => {
      if (url === TOKEN_URL) return TOKEN_OK();
      return ++poradi === 1
        ? odpoved(401, '')
        : odpoved(200, [{ id: 7, custom_id: 'subj-abc' }]);
    }]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    expect(await p.ensureSubject(DRAFT.party)).toEqual({ providerSubjectId: '7' });
    expect(volani.filter((v) => v.url === TOKEN_URL)).toHaveLength(2);   // token se obnovil

    const { fn: fn2 } = mockFetch([(url) => (url === TOKEN_URL ? TOKEN_OK() : odpoved(401, ''))]);
    const p2 = new FakturoidProvider({ config: CONFIG, fetch: fn2, cekej: hnedCekej });
    await expect(p2.ensureSubject(DRAFT.party)).rejects.toBeInstanceOf(BillingAuthError);
  });
});

describe('ensureSubject', () => {
  it('najde odběratele podle custom_id a NEzakládá druhého', async () => {
    const { fn, volani } = mockFetch([TOKEN_OK, () => odpoved(200, [{ id: 42, custom_id: 'subj-abc' }])]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });

    expect(await p.ensureSubject(DRAFT.party)).toEqual({ providerSubjectId: '42' });
    expect(volani[1].url).toContain('/subjects.json?custom_id=subj-abc');
    expect(volani.some((v) => v.init?.method === 'POST' && v.url.includes('/subjects.json'))).toBe(false);
  });

  it('když neexistuje, založí ho z našich ARES dat', async () => {
    const { fn, volani } = mockFetch([
      TOKEN_OK,
      () => odpoved(200, []),
      () => odpoved(201, { id: 99, custom_id: 'subj-abc' }),
    ]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });

    expect(await p.ensureSubject({
      ourSubjectId: 'abc', name: 'SK Curling Ostrava', registrationNo: '26512345',
      street: 'Sportovní 12, 702 00 Ostrava', country: 'CZ',
    })).toEqual({ providerSubjectId: '99' });

    expect(JSON.parse(volani[2].init?.body ?? '{}')).toEqual({
      name: 'SK Curling Ostrava',
      custom_id: 'subj-abc',
      country: 'CZ',
      registration_no: '26512345',
      street: 'Sportovní 12, 702 00 Ostrava',
    });
  });

  it('prázdná pole se neposílají — nepřepíšou to, co tam vyplnil člověk', async () => {
    const { fn, volani } = mockFetch([TOKEN_OK, () => odpoved(200, []), () => odpoved(201, { id: 1, custom_id: 'subj-abc' })]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });

    await p.ensureSubject({ ourSubjectId: 'abc', name: 'Klub' });
    const telo = JSON.parse(volani[2].init?.body ?? '{}');
    expect(Object.keys(telo).sort()).toEqual(['country', 'custom_id', 'name']);
    expect('vat_no' in telo).toBe(false);
  });

  // Neprázdná odpověď BEZ hledaného custom_id znamená, že filtr neúčinkuje.
  // Založit dalšího odběratele by v takové situaci znamenalo zakládat duplicitu
  // při KAŽDÉM běhu — proto se stojí hlasitě, ne tiše.
  it('nefunkční filtr custom_id je chyba, ne důvod založit dalšího odběratele', async () => {
    const { fn, volani } = mockFetch([
      TOKEN_OK,
      () => odpoved(200, [{ id: 5, custom_id: 'subj-nekdo-jiny' }]),
      () => odpoved(201, { id: 77, custom_id: 'subj-abc' }),
    ]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.ensureSubject(DRAFT.party)).rejects.toThrow(/Filtr custom_id/);
    // Pozor: tokenový požadavek je taky POST, takže se musí ptát na CESTU.
    expect(volani.some((v) => v.init?.method === 'POST' && v.url.includes('/subjects.json')))
      .toBe(false);
  });

  it('tiché selhání zámku 2 se taky nepromlčí', async () => {
    // Kdyby /invoices.json přestalo filtrovat, `.find` by nenašel nic, vrátili
    // bychom null — a zámek 2 by tiše přestal platit. Duplicita by se objevila
    // až u klienta, takže je lepší spadnout.
    const { fn } = mockFetch([
      TOKEN_OK,
      () => odpoved(200, [{ id: 9, number: '20260099', variable_symbol: '20260099', public_html_url: null, status: 'open', custom_id: 'klub-nekdo-jiny-202608', total: '100.00' }]),
    ]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.findExistingInvoice('klub-abc-202608')).rejects.toThrow(/Filtr custom_id/);
  });
});

describe('createInvoice', () => {
  const vytvor = async (draft = DRAFT) => {
    const { fn, volani } = mockFetch([
      TOKEN_OK,
      () => odpoved(201, {
        id: 555, number: '20260012', variable_symbol: '20260012',
        public_html_url: 'https://app.fakturoid.cz/x/555', status: 'open', custom_id: draft.idempotencyKey,
      }),
    ]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    const vysledek = await p.createInvoice(draft, '42');
    return { vysledek, telo: JSON.parse(volani[1].init?.body ?? '{}') };
  };

  it('NEPOSÍLÁ number ani variable_symbol — přiděluje je Fakturoid', async () => {
    const { telo, vysledek } = await vytvor();
    expect('number' in telo).toBe(false);
    expect('variable_symbol' in telo).toBe(false);
    expect(vysledek.number).toBe('20260012');
    expect(vysledek.variableSymbol).toBe('20260012');
  });

  it('řádek nese name/quantity/unit_name/unit_price a ŽÁDNÉ vat_rate (neplátce)', async () => {
    const { telo } = await vytvor();
    expect(telo.lines).toEqual([{
      name: '22.08. 18:00–19:00 · Trénink', quantity: 1.5, unit_name: 'h', unit_price: 833.67,
    }]);
    expect(Object.keys(telo.lines[0])).not.toContain('vat_rate');
  });

  it('posílá custom_id (klíč idempotence) a splatnost ve dnech', async () => {
    const { telo } = await vytvor();
    expect(telo.custom_id).toBe('klub-abc-202608');
    expect(telo.due).toBe(14);
    expect(telo.subject_id).toBe(42);
  });

  it('issued_on se pošle jen tehdy, když ho draft má', async () => {
    expect('issued_on' in (await vytvor()).telo).toBe(false);
    const { telo } = await vytvor({ ...DRAFT, issuedOn: '2026-08-24' });
    expect(telo.issued_on).toBe('2026-08-24');
  });

  it('nečíselné id odběratele je chyba u nás, ne request na Fakturoid', async () => {
    const { fn, volani } = mockFetch([TOKEN_OK]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.createInvoice(DRAFT, 'subj-abc')).rejects.toBeInstanceOf(BillingValidationError);
    expect(volani).toHaveLength(0);
  });
});

describe('findExistingInvoice — zámek 2', () => {
  it('najde doklad podle klíče idempotence', async () => {
    const { fn, volani } = mockFetch([
      TOKEN_OK,
      () => odpoved(200, [{
        id: 555, number: '20260012', variable_symbol: '20260012',
        public_html_url: null, status: 'open', custom_id: 'klub-abc-202608',
      }]),
    ]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });

    const v = await p.findExistingInvoice('klub-abc-202608');
    expect(v?.providerInvoiceId).toBe('555');
    expect(v?.publicUrl).toBeUndefined();
    expect(volani[1].url).toContain('/invoices.json?custom_id=klub-abc-202608');
  });

  it('když doklad není, vrátí null (ne výjimku)', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(200, [])]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    expect(await p.findExistingInvoice('klub-abc-202608')).toBeNull();
  });
});

describe('downloadPdf', () => {
  it('204 znamená „ještě se generuje“ → null, ne chyba', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(204, '')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    expect(await p.downloadPdf('555')).toBeNull();
  });

  it('200 vrátí bajty', async () => {
    const { fn, volani } = mockFetch([TOKEN_OK, () => odpoved(200, '%PDF-1.4')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });

    const pdf = await p.downloadPdf('555');
    expect(pdf).toBeInstanceOf(Uint8Array);
    expect(new TextDecoder().decode(pdf!)).toBe('%PDF-1.4');
    expect(volani[1].url).toContain('/invoices/555/download.pdf');
  });

  it('404 je chyba — na rozdíl od 204', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(404, '')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.downloadPdf('555')).rejects.toBeInstanceOf(BillingProviderError);
  });
});

describe('tajemství nesmí jít serializovat', () => {
  const TAJNY = nactiConfig({ ...ENV, FAKTUROID_CLIENT_SECRET: 'SUPERTAJNE' });
  const mrtvyFetch = (async () => { throw new Error('sem se to nesmí dostat'); }) as never;

  // TypeScriptové `private` je JEN kompilační značka. Za běhu je to obyčejná
  // enumerable vlastnost, takže `constructor(private volby)` vydá secret přes
  // JSON.stringify — a jedno `console.error('…', { provider, err })` v Edge
  // funkci ho pošle do logu, který čte víc lidí než ten, kdo klíč nastavoval.
  it('JSON.stringify provideru nevydá client_secret', () => {
    const p = new FakturoidProvider({ config: TAJNY, fetch: mrtvyFetch });
    const serializovany = JSON.stringify(p);
    expect(serializovany).not.toContain('SUPERTAJNE');
    expect(serializovany).not.toContain('secret456');
  });

  it('JSON.stringify cache tokenu nevydá token ani secret', () => {
    const cache = new TokenCache({ ...TAJNY, fetch: mrtvyFetch, userAgent: TAJNY.userAgent });
    const serializovany = JSON.stringify(cache);
    expect(serializovany).not.toContain('SUPERTAJNE');
  });

  it('ani Object.keys nevydá vnitřek', () => {
    const p = new FakturoidProvider({ config: TAJNY, fetch: mrtvyFetch });
    expect(Object.keys(p)).toEqual([]);
  });
});
