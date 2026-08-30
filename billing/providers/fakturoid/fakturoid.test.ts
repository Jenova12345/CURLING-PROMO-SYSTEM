import { describe, expect, it, vi } from 'vitest';

import { FakturoidProvider } from './index.ts';
import { nactiConfig, zakladUrl } from './config.ts';
import { basicHlavicka, TOKEN_URL, TokenCache } from './auth.ts';
import {
  prodlevaPoLimitu, smiSeOpakovat, zkrat,
  type FetchFn, type HttpOdpoved, type HttpPozadavek,
} from './http.ts';
import {
  BillingAuthError, BillingNetworkError, BillingProviderError, BillingRateLimitError,
  BillingValidationError, jeZapisNejisty, lzeOpakovat,
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

  it('přečte subtotal jako providerSubtotal — bez něj nejde ověřit komerční doklad', async () => {
    const { fn } = mockFetch([
      TOKEN_OK,
      () => odpoved(201, {
        id: 556, number: '20260013', variable_symbol: '20260013', status: 'open',
        custom_id: DRAFT.idempotencyKey, total: '1400.00', subtotal: '1250.00',
      }),
    ]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    const v = await p.createInvoice(DRAFT, '42');
    expect(v.providerTotal).toBe(1400);
    expect(v.providerSubtotal).toBe(1250);
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

  // ---------------------------------------------------------------------------
  // DPH
  //
  // Provider o DPH SÁM NEROZHODUJE — jen přeloží, co má v draftu. Rozhodnutí,
  // že klubový doklad má ceny s daní a komerční bez ní, patří mapovací vrstvě
  // (`billing/mapping.ts`), a tyhle testy hlídají, že se provider do toho
  // rozhodování neplete a zároveň ho nezahodí.
  // ---------------------------------------------------------------------------
  it('u plátce pošle vat_rate na řádku', async () => {
    const { telo } = await vytvor({
      ...DRAFT,
      lines: [{ ...DRAFT.lines[0], vatRate: 12 }],
      pricesIncludeVat: true,
    });
    expect(telo.lines[0].vat_rate).toBe(12);
  });

  it('KLUBOVÝ doklad → vat_price_mode = from_total_with_vat (ceny s daní)', async () => {
    const { telo } = await vytvor({
      ...DRAFT,
      lines: [{ ...DRAFT.lines[0], vatRate: 12 }],
      pricesIncludeVat: true,
    });
    // Kdyby tenhle režim chyběl, Fakturoid by klubovou cenu (vedenou včetně DPH)
    // pochopil jako základ a daň přidal navrch — klub by dostal fakturu o 12 %
    // vyšší, než jakou mu hala slíbila.
    expect(telo.vat_price_mode).toBe('from_total_with_vat');
  });

  it('KOMERČNÍ doklad → vat_price_mode = without_vat (ceny bez daně)', async () => {
    const { telo } = await vytvor({
      ...DRAFT,
      type: 'commercial_event',
      lines: [{ ...DRAFT.lines[0], vatRate: 12 }],
      pricesIncludeVat: false,
    });
    expect(telo.vat_price_mode).toBe('without_vat');
  });

  it('u neplátce nepošle ani vat_rate, ani vat_price_mode', async () => {
    const { telo } = await vytvor();
    expect('vat_price_mode' in telo).toBe(false);
    expect(Object.keys(telo.lines[0])).not.toContain('vat_rate');
  });

  it('DIČ dodavatele se neposílá — bere si ho Fakturoid z nastavení účtu', async () => {
    const { telo } = await vytvor({
      ...DRAFT,
      lines: [{ ...DRAFT.lines[0], vatRate: 12 }],
      pricesIncludeVat: true,
    });
    // Kdyby se posílalo odsud, bylo by na dvou místech a rozešlo by se.
    expect(Object.keys(telo)).not.toContain('supplier_vat_no');
    expect(Object.keys(telo)).not.toContain('vat_no');
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

describe('rozpoznání prodlevy po 429', () => {
  // Přesný tvar hlavičky u Fakturoidu v3 NENÍ ověřený proti živé odpovědi, proto
  // se čte víc podob a spadá se na backoff. Tenhle test necertifikuje, KTEROU
  // hlavičku Fakturoid posílá — ověřuje, že parser zvládne všechny tři a nespoléhá
  // se na jednu domněnku.
  it('zvládne Retry-After, X-RateLimit-Reset i parametrický tvar', () => {
    expect(prodlevaPoLimitu(odpoved(429, '', { 'Retry-After': '3' }), 1)).toBe(3000);
    expect(prodlevaPoLimitu(odpoved(429, '', { 'X-RateLimit-Reset': '7' }), 1)).toBe(7000);
    expect(prodlevaPoLimitu(odpoved(429, '', { 'X-RateLimit': 'limit=100; remaining=0; t=42' }), 1)).toBe(42_000);
  });

  // SKUTEČNÝ tvar, odchycený z živé odpovědi Fakturoidu 25. 8. 2026:
  //   x-ratelimit: default;r=387;t=44
  //   x-ratelimit-policy: default;q=400;w=60
  // `r` je zbývající počet, `t` vteřiny do resetu, `q` kvóta, `w` okno.
  // Dřív to byla domněnka — teď je to změřené.
  it('zvládne SKUTEČNÝ tvar hlavičky Fakturoidu', () => {
    expect(prodlevaPoLimitu(odpoved(429, '', { 'X-RateLimit': 'default;r=387;t=44' }), 1)).toBe(44_000);
    expect(prodlevaPoLimitu(odpoved(429, '', { 'X-RateLimit': 'default;r=0;t=1' }), 1)).toBe(1000);
    // `r=387` se nesmí splést s `t` — parser bere jen parametr `t`.
    expect(prodlevaPoLimitu(odpoved(429, '', { 'X-RateLimit': 'default;r=387;t=44' }), 3)).toBe(44_000);
  });

  it('bez použitelné hlavičky spadne na backoff, ne na nulu', () => {
    expect(prodlevaPoLimitu(odpoved(429, ''), 1)).toBe(500);
    expect(prodlevaPoLimitu(odpoved(429, '', { 'Retry-After': 'Wed, 21 Oct 2026 07:28:00 GMT' }), 2)).toBe(1000);
    expect(prodlevaPoLimitu(odpoved(429, '', { 'X-RateLimit': 'limit=100; remaining=0' }), 3)).toBe(2000);
  });

  it('rozbitá hodnota neuspí Edge funkci na čtvrt hodiny', () => {
    expect(prodlevaPoLimitu(odpoved(429, '', { 'Retry-After': '9999' }), 1)).toBe(60_000);
  });
});

describe('síťová chyba (odmítnutý fetch)', () => {
  const padajiciFetch = (kolikrat: number): { fn: FetchFn; pocet: () => number } => {
    let n = 0;
    const fn: FetchFn = async (url) => {
      if (url === TOKEN_URL) return TOKEN_OK();
      n++;
      if (n <= kolikrat) throw new TypeError('fetch failed: ECONNRESET');
      return odpoved(200, [{ id: 7, custom_id: 'subj-abc' }]);
    };
    return { fn, pocet: () => n };
  };

  it('u ČTENÍ se zopakuje — přechodný výpadek nesmí trvale shodit doklad', async () => {
    const { fn, pocet } = padajiciFetch(2);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    expect(await p.ensureSubject(DRAFT.party)).toEqual({ providerSubjectId: '7' });
    expect(pocet()).toBe(3);
  });

  it('u ZÁPISU se nezopakuje — nevíme, jestli požadavek doletěl', async () => {
    let post = 0;
    const fn: FetchFn = async (url, init) => {
      if (url === TOKEN_URL) return TOKEN_OK();
      if (init?.method === 'POST') { post++; throw new TypeError('fetch failed'); }
      return odpoved(200, []);
    };
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.createInvoice(DRAFT, '7')).rejects.toBeInstanceOf(BillingNetworkError);
    expect(post).toBe(1);
  });

  it('je klasifikovaná jako opakovatelná na úrovni celého vystavení', () => {
    // Bez vlastní třídy vyletěl TypeError, `lzeOpakovat` řekla „ne"
    // a přechodný výpadek sítě znamenal trvale selhaný doklad.
    expect(lzeOpakovat(new BillingNetworkError('x'))).toBe(true);
    expect(lzeOpakovat(new BillingValidationError('x'))).toBe(false);
    expect(lzeOpakovat(new BillingAuthError('x'))).toBe(false);
  });
});

describe('401 u zápisu', () => {
  it('POST se po 401 NEOPAKUJE, i když je 401 „nezpracováno"', async () => {
    let post = 0;
    const fn: FetchFn = async (url, init) => {
      if (url === TOKEN_URL) return TOKEN_OK();
      if (init?.method === 'POST') { post++; return odpoved(401, ''); }
      return odpoved(200, []);
    };
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.createInvoice(DRAFT, '7')).rejects.toBeInstanceOf(BillingAuthError);
    expect(post).toBe(1);
  });

  it('zneplatni() zahodí i rozpracovanou obnovu, ne jen uložený token', async () => {
    // Bez toho by retry po 401 dostal TÝŽ token a skončil hláškou
    // „zkontroluj klíče" u klíčů, které jsou v pořádku.
    let vydano = 0;
    const fn: FetchFn = async () => odpoved(200, {
      access_token: `tok-${++vydano}`, token_type: 'Bearer', expires_in: 7200,
    });
    const cache = new TokenCache({ ...CONFIG, fetch: fn, userAgent: CONFIG.userAgent, cekej: hnedCekej });

    const prvni = cache.token();
    cache.zneplatni();
    const druhy = await cache.token();
    await prvni;
    expect(druhy).not.toBe('tok-1');
  });
});

describe('parsování částek a řádků od providera', () => {
  const sTotalem = async (total: unknown, lines: unknown = null) => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(200, [{
      id: 5, number: '20260001', variable_symbol: '20260001', public_html_url: null,
      status: 'open', custom_id: 'klub-abc-202608', total, lines,
    }])]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    return p.findExistingInvoice('klub-abc-202608');
  };

  it('řetězcovou částku převede', async () => {
    expect((await sTotalem('3752.00'))?.providerTotal).toBe(3752);
  });

  // Number('') je 0 — doklad na nula korun. Number('3 752,00') je NaN
  // a JSON.stringify(NaN) je null, takže by hodnota beze stopy zmizela.
  it('prázdnou ani neparsovatelnou částku nevydává za číslo', async () => {
    expect((await sTotalem(''))?.providerTotal).toBeUndefined();
    expect((await sTotalem('3 752,00'))?.providerTotal).toBeUndefined();
    expect((await sTotalem(null))?.providerTotal).toBeUndefined();
    expect((await sTotalem('0.00'))?.providerTotal).toBe(0);
  });

  it('řádky převede na náš tvar', async () => {
    const v = await sTotalem('1200.00', [
      { name: '04.08. 18:00–19:00 · Trénink', quantity: '1.0', unit_name: 'h', unit_price: '1200.0' },
    ]);
    expect(v?.providerLines).toEqual([
      { name: '04.08. 18:00–19:00 · Trénink', quantity: 1, unitName: 'h', unitPrice: 1200 },
    ]);
  });
});

describe('odolnost proti nečekanému tvaru odpovědi', () => {
  it('odpověď, která není seznam, je chyba — ne TypeError z .find', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(200, { chyba: 'neco' })]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.ensureSubject(DRAFT.party)).rejects.toBeInstanceOf(BillingProviderError);
  });

  it('odpověď, která není JSON, je čitelná chyba', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(200, '<html>502 Bad Gateway</html>')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.findExistingInvoice('klub-abc-202608')).rejects.toThrow(/není JSON/);
  });

  it('hláška neuvádí víc pokusů, než kolik jich doopravdy bylo', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(500, 'oops')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej, pokusu: 4 });
    // POST se neopakuje, takže požadavek byl jeden — hláška „i po 4 pokusech"
    // by ladění posílala špatným směrem.
    await expect(p.createInvoice(DRAFT, '7')).rejects.toThrow(/^Fakturoid odpověděl 500\.$/);
  });
});

describe('prázdná splatnost není nula', () => {
  it('nevyplněné BILLING_DUE_DAYS znamená default 14, ne pád', () => {
    // Number('') je 0, takže odkomentovaný, ale nevyplněný řádek v .env
    // by jinak shodil start hláškou o splatnosti.
    expect(nactiConfig({ ...ENV, BILLING_DUE_DAYS: '' }).dueDays).toBe(14);
    expect(nactiConfig({ ...ENV, BILLING_DUE_DAYS: '  ' }).dueDays).toBe(14);
    expect(nactiConfig({ ...ENV, BILLING_DUE_DAYS: undefined }).dueDays).toBe(14);
  });
});

describe('začernění chybového těla', () => {
  const zacernene = (o: unknown) => zkrat(JSON.stringify(o));

  it('skryje hodnoty citlivých polí, klíče nechá vidět', () => {
    const v = zacernene({ errors: { registration_no: '26512345', street: 'Sportovní 12' } });
    expect(v).toContain('registration_no');
    expect(v).not.toContain('26512345');
    expect(v).not.toContain('Sportovní');
  });

  // Regexem `"[^"]*"` tohle nešlo: na názvu s uvozovkami začernil jen první
  // půlku, do logu pustil `ABC" s.r.o.` a tělo přestalo být validní JSON.
  // Názvy s uvozovkami z ARESu reálně chodí.
  it('zvládne uvozovku uvnitř hodnoty', () => {
    const v = zacernene({ errors: { name: 'Firma "ABC" s.r.o.', street: 'Ruská 101' } })!;
    expect(v).not.toContain('ABC');
    expect(() => JSON.parse(v.replace(/…$/, ''))).not.toThrow();
  });

  it('zvládne i nekvotované hodnoty a pole', () => {
    expect(zacernene({ zip: 70800 })).not.toContain('70800');
    expect(zacernene({ subjects: [{ name: 'Tajný klub' }] })).not.toContain('Tajný klub');
  });

  it('tělo, které není JSON, se do chyby nedává vůbec', () => {
    // Neznámý tvar nejde spolehlivě začernit — radši nic než náhodný výřez
    // cizích dat v logu.
    expect(zkrat('<html>502 Bad Gateway — user admin@klub.cz</html>')).toBeUndefined();
  });

  it('nezačerňuje, co začernit nemá — jinak by chyba nešla diagnostikovat', () => {
    expect(zacernene({ errors: { due: ['musí být číslo'] } })).toContain('musí být číslo');
  });
});

describe('příznak „nevíme, jak zápis dopadl“', () => {
  // Selhaný POST skončí BillingProviderError(500), což lzeOpakovat klasifikuje
  // jako „opakovat“. Přes celé vystavDoklad je to bezpečné (zámky 2 a 3), ale
  // fronta, která by zopakovala createInvoice NAPŘÍMO, vyrobí duplicitu.
  it('5xx po POSTu ho nese, 5xx po GETu ne', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(500, '{}')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej, pokusu: 2 });
    await p.createInvoice(DRAFT, '7').catch((e) => {
      expect(jeZapisNejisty(e)).toBe(true);
    });

    const { fn: fn2 } = mockFetch([TOKEN_OK, () => odpoved(500, '{}')]);
    const p2 = new FakturoidProvider({ config: CONFIG, fetch: fn2, cekej: hnedCekej, pokusu: 2 });
    await p2.findExistingInvoice('klub-abc-202608').catch((e) => {
      expect(jeZapisNejisty(e)).toBe(false);
    });
  });

  it('nese ho i síťová chyba u zápisu', async () => {
    const fn: FetchFn = async (url, init) => {
      if (url === TOKEN_URL) return TOKEN_OK();
      if (init?.method === 'POST') throw new TypeError('fetch failed');
      return odpoved(200, []);
    };
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await p.createInvoice(DRAFT, '7').catch((e) => {
      expect(e).toBeInstanceOf(BillingNetworkError);
      expect(jeZapisNejisty(e)).toBe(true);
    });
  });

  it('u chyby, která zápis netrápí, je false', () => {
    expect(jeZapisNejisty(new BillingValidationError('x'))).toBe(false);
    expect(jeZapisNejisty(new Error('x'))).toBe(false);
  });
});

describe('odeslání dokladu odběrateli', () => {
  const odesli = async (status: number, email?: string) => {
    const { fn, volani } = mockFetch([TOKEN_OK, () => odpoved(status, '')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    const vysledek = await p.sendInvoice('555', { email }).then(() => 'ok').catch((e) => e);
    return { vysledek, volani };
  };

  // NENÍ to fire.json?event=deliver — ten byl z API v3 ODSTRANĚN ve prospěch
  // Invoice Messages. Kdo by sáhl po `mark_as_sent`, označí doklad za odeslaný,
  // aniž by ho kdokoli dostal.
  it('volá message.json, ne fire.json', async () => {
    const { vysledek, volani } = await odesli(204);
    expect(vysledek).toBe('ok');
    expect(volani[1].url).toContain('/invoices/555/message.json');
    expect(volani[1].url).not.toContain('fire.json');
    expect(volani[1].init?.method).toBe('POST');
  });

  it('e-mail pošle jen tehdy, když ho máme — jinak si ho Fakturoid dosadí sám', async () => {
    expect(JSON.parse((await odesli(204)).volani[1].init?.body ?? '{}')).toEqual({});
    expect(JSON.parse((await odesli(204, 'klub@example.cz')).volani[1].init?.body ?? '{}'))
      .toEqual({ email: 'klub@example.cz' });
  });

  it('403 vysvětlí, že jde o tarif nebo kvótu', async () => {
    const { vysledek } = await odesli(403);
    expect(vysledek).toBeInstanceOf(BillingProviderError);
    expect((vysledek as Error).message).toMatch(/free tarif|kvóta/);
  });

  // 401 a 403 NEJSOU totéž. Fakturoid vrací 403 i na vyčerpaný limit tarifu,
  // a hláška „zkontroluj klíče" pak posílá hledat přesně opačným směrem.
  // Změřeno na živém účtu: token OK, GET OK, POST → 403 quota_exhausted.
  it('403 z API se NEhlásí jako špatné heslo a nese kód chyby', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(403,
      '{"error":"quota_exhausted","error_description":"You have reached the limit"}')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });

    const chyba = await p.findExistingInvoice('klub-abc-202608').catch((e) => e);
    expect(chyba).toBeInstanceOf(BillingProviderError);
    expect(chyba).not.toBeInstanceOf(BillingAuthError);
    expect((chyba as Error).message).toContain('quota_exhausted');
    expect((chyba as Error).message).toMatch(/NENÍ to špatné heslo/);
  });

  it('401 se naopak jako špatné heslo hlásí dál', async () => {
    const { fn } = mockFetch([TOKEN_OK, () => odpoved(401, '')]);
    const p = new FakturoidProvider({ config: CONFIG, fetch: fn, cekej: hnedCekej });
    await expect(p.findExistingInvoice('klub-abc-202608')).rejects.toBeInstanceOf(BillingAuthError);
  });

  // Tohle je nejpravděpodobnější selhání v provozu: `public.subjects` sloupec
  // pro e-mail nemá, takže ho musí mít vyplněný Fakturoid.
  it('422 řekne rovnou, že nejspíš chybí e-mail u odběratele', async () => {
    const { vysledek } = await odesli(422);
    expect((vysledek as Error).message).toMatch(/chybí\s+e-mail u odběratele/);
  });
});

describe('režim vystavení v konfiguraci', () => {
  it('default je koncept', () => {
    expect(nactiConfig(ENV).rezim).toBe('koncept');
    expect(nactiConfig({ ...ENV, FAKTUROID_MODE: '' }).rezim).toBe('koncept');
  });

  it('odeslat se dá zapnout', () => {
    expect(nactiConfig({ ...ENV, FAKTUROID_MODE: 'odeslat' }).rezim).toBe('odeslat');
    expect(nactiConfig({ ...ENV, FAKTUROID_MODE: 'ODESLAT' }).rezim).toBe('odeslat');
  });

  // Překlep se NESMÍ přeložit na default. „odselat" by tiše znamenalo koncept
  // a nikdo by se nedivil, proč se nic neodesílá.
  it('překlep je chyba, ne tichý default', () => {
    expect(() => nactiConfig({ ...ENV, FAKTUROID_MODE: 'odselat' })).toThrow(BillingValidationError);
    expect(() => nactiConfig({ ...ENV, FAKTUROID_MODE: 'auto' })).toThrow(/koncept.*odeslat/);
  });
});
