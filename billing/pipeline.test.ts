import { describe, expect, it, vi } from 'vitest';

import { PDF_POKUSU, stahniPdf, vystavDoklad } from './pipeline.ts';
import { PametovyStore } from './store.ts';
import { MockProvider } from './providers/mock.ts';
import { mapujKlubMesicne, mapujKomercniAkci, type BillableReservation, type SubjectForBilling } from './mapping.ts';
import type { InvoiceProvider } from './types.ts';

const KLUB: SubjectForBilling = {
  id: 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
  name: 'SK Curling Ostrava', ico: '26512345', dic: null,
  address: 'Sportovní 12, 702 00 Ostrava',
};

const rezervace: BillableReservation[] = [
  { id: 'a', start_at: '2026-08-04T16:00:00Z', end_at: '2026-08-04T17:00:00Z', sheet_name: 'Dráha 1', event_title: 'Trénink', hodiny: 1, sazba: 1200, castka: 1200 },
  { id: 'b', start_at: '2026-08-11T16:00:00Z', end_at: '2026-08-11T17:00:00Z', sheet_name: 'Dráha 1', event_title: 'Trénink', hodiny: 1, sazba: 1200, castka: 1200 },
];

const draftKlubu = () => mapujKlubMesicne({
  subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace,
});

/** Testy nesmí čekat doopravdy — jinak by smyčka kolem 204 trvala vteřiny. */
const hnedCekej = async () => {};

describe('vystavDoklad — šťastná cesta', () => {
  it('vystaví doklad a zapíše vazbu na všechny zdrojové rezervace', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();

    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });

    expect(v.stav).toBe('vystaveno');
    if (v.stav !== 'vystaveno') return;
    expect(v.link.result.number).toBe('20260001');
    expect(v.link.reservationIds).toEqual(['a', 'b']);
    expect(await store.jeVyfakturovana('a')).toBe(true);
    expect(await store.jeVyfakturovana('b')).toBe(true);
  });

  it('číslo a variabilní symbol přiděluje PROVIDER — my je neposíláme', async () => {
    const provider = new MockProvider();
    const draft = draftKlubu()!;

    expect('number' in draft).toBe(false);
    expect('variableSymbol' in draft).toBe(false);

    const v = await vystavDoklad({ draft, provider, store: new PametovyStore(), cekej: hnedCekej });
    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');
    expect(v.link.result.variableSymbol).toBe('20260001');
  });
});

describe('idempotence — dva zámky', () => {
  it('ZÁMEK 1: druhé volání se stejným klíčem nevytvoří druhý doklad', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();

    const prvni = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    const druhe = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });

    expect(prvni.stav).toBe('vystaveno');
    expect(druhe.stav).toBe('preskoceno');
    expect(provider.volani.createInvoice).toBe(1);
    expect(store.pocetDokladu).toBe(1);
  });

  it('ZÁMEK 1 zabere i tehdy, když už doklad nese JEDINÁ z rezervací', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();

    // Rezervace „a“ se vyfakturovala samostatně dřív (třeba ručně).
    await vystavDoklad({
      draft: mapujKlubMesicne({ subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: [rezervace[0]] }),
      provider, store, cekej: hnedCekej,
    });
    provider.volani.createInvoice = 0;

    // Měsíční běh na obě rezervace se musí celý zastavit, ne vystavit doklad na „b“.
    // Rozdělit jednu akci na dva doklady je věc pro člověka, ne pro automatiku.
    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    expect(v.stav).toBe('preskoceno');
    expect(provider.volani.createInvoice).toBe(0);
  });

  it('ZÁMEK 2: doklad vznikl, ale odpověď se ztratila — druhý běh ho najde, ne vytvoří', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();
    const draft = draftKlubu()!;

    // První běh: provider doklad založil, ale zápis vazby spadl (timeout Edge funkce).
    await provider.ensureSubject(draft.party);
    await provider.createInvoice(draft, `subj-${KLUB.id}`);
    expect(store.pocetDokladu).toBe(0);          // vazba se opravdu nezapsala
    provider.volani.createInvoice = 0;

    const v = await vystavDoklad({ draft, provider, store, cekej: hnedCekej });

    expect(v.stav).toBe('existoval');
    expect(provider.volani.createInvoice).toBe(0);   // ← bez zámku 2 by tu byla duplicita
    expect(await store.jeVyfakturovana('a')).toBe(true);
  });

  it('odběratel se nezakládá, když se doklad nakonec nevystaví', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();
    await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    provider.volani.ensureSubject = 0;

    await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    expect(provider.volani.ensureSubject).toBe(0);
  });
});

describe('prázdný doklad', () => {
  it('klub s 0 zpoplatněnými rezervacemi — nevolá se provider vůbec', async () => {
    const provider = new MockProvider();
    const draft = mapujKlubMesicne({ subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: [] });

    const v = await vystavDoklad({ draft, provider, store: new PametovyStore(), cekej: hnedCekej });

    expect(v.stav).toBe('prazdne');
    expect(provider.volani).toEqual({ ensureSubject: 0, findExistingInvoice: 0, createInvoice: 0, downloadPdf: 0 });
  });

  it('komerční akce bez rezervací taky nevznikne', async () => {
    const draft = mapujKomercniAkci({ eventId: 'ev1', subjekt: KLUB, jePlatceDph: false, rezervace: [] });
    const v = await vystavDoklad({ draft, provider: new MockProvider(), store: new PametovyStore(), cekej: hnedCekej });
    expect(v.stav).toBe('prazdne');
  });
});

describe('PDF — 204 znamená „ještě se generuje“, ne chybu', () => {
  it('opakuje, dokud PDF nepřijde, a uloží ho', async () => {
    const provider = new MockProvider({ pdfNeniKrat: 2 });
    const store = new PametovyStore();
    const uloz = vi.fn(async (klic: string) => `invoices/${klic}.pdf`);

    const v = await vystavDoklad({
      draft: draftKlubu(), provider, store, cekej: hnedCekej,
      pdfUloziste: { uloz },
    });

    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');
    expect(provider.volani.downloadPdf).toBe(3);     // 204, 204, teprve pak bytes
    expect(uloz).toHaveBeenCalledOnce();
    expect(v.link.pdfPath).toBe(`invoices/klub-${KLUB.id}-202608.pdf`);
  });

  it('když se PDF nestihne, doklad PŘESTO platí a vazba je zapsaná', async () => {
    // Doklad má číslo a je vystavený — PDF si dobere další běh fronty.
    const provider = new MockProvider({ pdfNeniKrat: 99 });
    const store = new PametovyStore();
    const uloz = vi.fn(async () => 'nikdy');

    const v = await vystavDoklad({
      draft: draftKlubu(), provider, store, cekej: hnedCekej, pdfUloziste: { uloz },
    });

    expect(v.stav).toBe('vystaveno');
    expect(uloz).not.toHaveBeenCalled();
    expect(await store.jeVyfakturovana('a')).toBe(true);
    expect(provider.volani.downloadPdf).toBe(PDF_POKUSU);
  });

  it('stahniPdf vrátí null místo výjimky, když to nestihne', async () => {
    const provider = new MockProvider({ pdfNeniKrat: 99 });
    expect(await stahniPdf(provider, 'x', hnedCekej, 2)).toBeNull();
  });

  it('mezi pokusy se čeká rostoucí prodlevu', async () => {
    // Typovaný parametr schválně: bez něj je `calls` prázdná n-tice a `c[0]`
    // neprojde typecheckem — což testy samy nepoznají, běží zeleně.
    const cekej = vi.fn(async (_ms: number) => {});
    await stahniPdf(new MockProvider({ pdfNeniKrat: 99 }), 'x', cekej, 3);
    expect(cekej.mock.calls.map((c) => c[0])).toEqual([500, 1000]);
  });
});

describe('pořadí kroků', () => {
  it('vazba se zapíše DŘÍV, než se sáhne na PDF', async () => {
    // Kdyby se psala až po PDF, spadlý běh mezi tím by nechal doklad vystavený
    // a nezaznamenaný — a příští běh by ho podle zámku 1 vystavil znovu.
    const store = new PametovyStore();
    const poradi: string[] = [];

    const provider: InvoiceProvider = {
      ...new MockProvider(),
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => null,
      createInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001', status: 'open',
      }),
      downloadPdf: async () => {
        poradi.push('pdf');
        return new Uint8Array([1]);
      },
    };

    const puvodni = store.zapisVazbu.bind(store);
    store.zapisVazbu = async (v) => { poradi.push('vazba'); return puvodni(v); };

    await vystavDoklad({
      draft: draftKlubu(), provider, store, cekej: hnedCekej,
      pdfUloziste: { uloz: async () => 'p' },
    });

    expect(poradi).toEqual(['vazba', 'pdf']);
  });
});

describe('ZÁMEK 3 — atomický claim proti souběhu', () => {
  // Zámky 1 a 2 jsou jen ČTENÍ. Cron (billing_runs) a admin, který klikne
  // „faktura na klik" ve stejnou vteřinu, jimi projdou OBA — v tu chvíli
  // opravdu nic neexistuje. Bez claimu by oba zavolaly createInvoice
  // a klient by dostal dvě faktury, protože custom_id není u Fakturoidu
  // unikátní klíč.
  it('dva souběžné běhy vystaví JEDEN doklad, ne dva', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();

    const [a, b] = await Promise.all([
      vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej }),
      vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej }),
    ]);

    expect(provider.volani.createInvoice).toBe(1);
    expect(store.pocetDokladu).toBe(1);
    expect([a.stav, b.stav].sort()).toEqual(['preskoceno', 'vystaveno']);
  });

  it('claim drží i mezi RŮZNÝMI klíči nad týmiž rezervacemi', async () => {
    // Komerční akce („akce-…") proti měsíčnímu běhu klubu („klub-…"): jiný klíč,
    // tytéž hodiny. Zámek 2 tohle nechytá, protože se ptá na klíč.
    const provider = new MockProvider();
    const store = new PametovyStore();

    const [a, b] = await Promise.all([
      vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej }),
      vystavDoklad({
        draft: mapujKomercniAkci({ eventId: 'ev1', subjekt: KLUB, jePlatceDph: false, rezervace }),
        provider, store, cekej: hnedCekej,
      }),
    ]);

    expect(provider.volani.createInvoice).toBe(1);
    expect([a.stav, b.stav].sort()).toEqual(['preskoceno', 'vystaveno']);
  });

  it('po selhaném vystavení se claim UVOLNÍ, ať klub nezůstane zablokovaný', async () => {
    const store = new PametovyStore();
    const padajici: InvoiceProvider = {
      ...new MockProvider(),
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => null,
      createInvoice: async () => { throw new Error('Fakturoid je mimo'); },
      downloadPdf: async () => null,
    };

    await expect(vystavDoklad({ draft: draftKlubu(), provider: padajici, store, cekej: hnedCekej }))
      .rejects.toThrow('Fakturoid je mimo');

    // Druhý pokus musí projít — kdyby claim zůstal, fakturace toho klubu
    // by stála až do zásahu člověka.
    const provider = new MockProvider();
    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    expect(v.stav).toBe('vystaveno');
  });
});

describe('větev „nesedi" — doklad existuje, ale neodpovídá podkladu', () => {
  // Scénář: první běh vystavil doklad z rezervací a,b a spadl před zápisem vazby.
  // Mezitím přibyla c. Druhý běh by bez kontroly označil i c za vyfakturovanou —
  // jenže c na dokladu není a už by se nikdy nevyfakturovala.
  it('nezapíše vazbu, když částka u providera neodpovídá dnešnímu podkladu', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();

    // Doklad vznikl jen z „a" (odpověď se ztratila, vazba se nezapsala).
    const uzsi = mapujKlubMesicne({
      subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: [rezervace[0]],
    })!;
    await provider.createInvoice(uzsi, 's');

    // Druhý běh už vidí „a" i „b".
    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });

    expect(v.stav).toBe('nesedi');
    if (v.stav !== 'nesedi') return;
    expect(v.duvod).toMatch(/1200 Kč.*2400 Kč|rozdíl/);
    // TOHLE je pointa: „b" se nesmí označit za vyfakturovanou.
    expect(await store.jeVyfakturovana('b')).toBe(false);
    expect(store.pocetDokladu).toBe(0);
  });

  it('když částka sedí, vazba se dorovná normálně', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();
    await provider.createInvoice(draftKlubu()!, 's');

    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    expect(v.stav).toBe('existoval');
    expect(await store.jeVyfakturovana('b')).toBe(true);
  });

  it('bez celkové částky od providera se vazba radši nezapíše', async () => {
    const store = new PametovyStore();
    const bezCastky: InvoiceProvider = {
      ...new MockProvider(),
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001', status: 'open',
      }),
      createInvoice: async () => { throw new Error('sem se to nesmí dostat'); },
      downloadPdf: async () => null,
    };

    const v = await vystavDoklad({ draft: draftKlubu(), provider: bezCastky, store, cekej: hnedCekej });
    expect(v.stav).toBe('nesedi');
    expect(await store.jeVyfakturovana('a')).toBe(false);
  });
});

describe('doklad bez zdrojových rezervací', () => {
  it('neprojde — jinak by tytéž hodiny prošly znovu pod jiným klíčem', async () => {
    const draft = { ...draftKlubu()!, sourceReservationIds: [] };
    await expect(vystavDoklad({
      draft, provider: new MockProvider(), store: new PametovyStore(), cekej: hnedCekej,
    })).rejects.toThrow(/žádné zdrojové rezervace/);
  });
});
