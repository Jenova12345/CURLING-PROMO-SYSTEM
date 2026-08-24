import { describe, expect, it, vi } from 'vitest';

import { PDF_POKUSU, dobirPdf, stahniPdf, vystavDoklad } from './pipeline.ts';
import { PametovyStore } from './store.ts';
import { MockProvider } from './providers/mock.ts';
import {
  mapujKlubMesicne, mapujKomercniAkci, soucetRadku,
  type BillableReservation, type SubjectForBilling,
} from './mapping.ts';
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

/**
 * Provider poskládaný po metodách.
 *
 * SCHVÁLNĚ NE `{ ...new MockProvider(), … }`: spread kopíruje jen vlastní
 * vlastnosti, ne metody z prototypu. TypeScript to přesto typuje jako úplný
 * `InvoiceProvider`, takže až rozhraní povyroste o pátou metodu, typecheck
 * projde a test spadne až za běhu na TypeError.
 */
const fakeProvider = (prepis: Partial<InvoiceProvider>): InvoiceProvider => ({
  ensureSubject: async () => ({ providerSubjectId: 's' }),
  findExistingInvoice: async () => null,
  createInvoice: async () => { throw new Error('createInvoice se v tomhle testu volat nemá'); },
  downloadPdf: async () => null,
  ...prepis,
});

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
    const uloz = vi.fn(async (klic: string) => ({ cesta: `invoices/${klic}.pdf` }));

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
    const uloz = vi.fn(async () => ({ cesta: 'nikdy' }));

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

    const provider: InvoiceProvider = fakeProvider({
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => null,
      createInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
        status: 'open', providerTotal: 2400,
      }),
      downloadPdf: async () => {
        poradi.push('pdf');
        return new Uint8Array([1]);
      },
    });

    const puvodni = store.zapisVazbu.bind(store);
    store.zapisVazbu = async (d, r, m) => { poradi.push('vazba'); return puvodni(d, r, m); };

    await vystavDoklad({
      draft: draftKlubu(), provider, store, cekej: hnedCekej,
      pdfUloziste: { uloz: async () => ({ cesta: 'p' }) },
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
    const padajici: InvoiceProvider = fakeProvider({
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => null,
      createInvoice: async () => { throw new Error('Fakturoid je mimo'); },
    });

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
    // Kontrola řádků běží dřív než kontrola částky, takže důvod mluví o řádcích.
    expect(v.duvod).toMatch(/1 řádků.*podklad dává 2/);
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
    const bezCastky: InvoiceProvider = fakeProvider({
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001', status: 'open',
      }),
    });

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

describe('kontrola nalezeného dokladu je podle ŘÁDKŮ, ne podle částky', () => {
  // TOHLE je scénář, na kterém kontrola pouhým součtem selže — a není okrajový,
  // je to normální provoz: klub trénuje týdně za stejnou sazbu, takže doklad
  // na rezervaci „a" a doklad na rezervaci „b" mají TUTÉŽ částku.
  //
  // Běh 1: podklad {a} → doklad vystaven, ale vazba se nezapsala (spadlo spojení).
  // Běh 2: volající posílá jen nevyfakturované, tedy {b} — přesně jak to dělají
  //        RPC v repu. Klíč je týž (klub-…-202608), takže zámek 2 najde doklad z {a}.
  // Bez kontroly řádků by se „b" označila za vyfakturovanou, ačkoli na dokladu
  // je „a" — a „b" by se nevyfakturovala NIKDY.
  it('stejná částka, jiná rezervace → nesedi, ne existoval', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();

    const jenA = mapujKlubMesicne({
      subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: [rezervace[0]],
    })!;
    const jenB = mapujKlubMesicne({
      subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: [rezervace[1]],
    })!;

    // Předpoklad testu: obě částky jsou opravdu stejné, jinak by test nic nedokazoval.
    expect(soucetRadku(jenA.lines)).toBe(soucetRadku(jenB.lines));
    expect(jenA.idempotencyKey).toBe(jenB.idempotencyKey);

    await provider.createInvoice(jenA, 's');          // běh 1, vazba se ztratila
    const v = await vystavDoklad({ draft: jenB, provider, store, cekej: hnedCekej });

    expect(v.stav).toBe('nesedi');
    expect(await store.jeVyfakturovana('b')).toBe(false);
  });

  it('shodné řádky projdou', async () => {
    const provider = new MockProvider();
    const store = new PametovyStore();
    await provider.createInvoice(draftKlubu()!, 's');

    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    expect(v.stav).toBe('existoval');
  });
});

describe('kontrolní součet po vystavení', () => {
  it('rozpor proti providerovi se vrátí jako varování, ne mlčky', async () => {
    const store = new PametovyStore();
    const lzivy: InvoiceProvider = fakeProvider({
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => null,
      createInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
        status: 'open', providerTotal: 9999,        // my posíláme 2 400 Kč
      }),
    });

    const v = await vystavDoklad({ draft: draftKlubu(), provider: lzivy, store, cekej: hnedCekej });
    expect(v.stav).toBe('vystaveno');
    if (v.stav !== 'vystaveno') return;
    expect(v.varovani?.map((x) => x.kod)).toEqual(['kontrolni_soucet']);
    expect(v.varovani?.[0].zprava).toMatch(/KONTROLNÍ SOUČET NESEDÍ/);
    // Doklad existuje, takže se vazba zapsat MUSÍ — jinak by ho nikdo neevidoval.
    expect(await store.jeVyfakturovana('a')).toBe(true);
  });

  it('když sedí, varování není', async () => {
    const v = await vystavDoklad({
      draft: draftKlubu(), provider: new MockProvider(), store: new PametovyStore(), cekej: hnedCekej,
    });
    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');
    expect(v.varovani).toBeUndefined();
  });
});

describe('PDF nesmí shodit vystavení', () => {
  it('výjimka při stahování PDF nechá doklad vystavený', async () => {
    // Vazba je v tu chvíli UŽ zapsaná, takže by příští běh doklad podle zámku 1
    // přeskočil a PDF by nedobral nikdo. Doklad má číslo a platí i bez PDF.
    const store = new PametovyStore();
    const provider: InvoiceProvider = fakeProvider({
      ensureSubject: async () => ({ providerSubjectId: 's' }),
      findExistingInvoice: async () => null,
      createInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
        status: 'open', providerTotal: 2400,
      }),
      downloadPdf: async () => { throw new Error('Fakturoid nás přibrzdil'); },
    });

    const v = await vystavDoklad({
      draft: draftKlubu(), provider, store, cekej: hnedCekej,
      pdfUloziste: { uloz: async () => ({ cesta: 'nikdy' }) },
    });

    expect(v.stav).toBe('vystaveno');
    if (v.stav !== 'vystaveno') return;
    expect(v.link.pdfPath).toBeUndefined();
    expect(await store.jeVyfakturovana('a')).toBe(true);
  });

  it('selhání úložiště taky ne', async () => {
    const v = await vystavDoklad({
      draft: draftKlubu(), provider: new MockProvider(), store: new PametovyStore(),
      cekej: hnedCekej,
      pdfUloziste: { uloz: async () => { throw new Error('plné úložiště'); } },
    });
    expect(v.stav).toBe('vystaveno');
  });
});

describe('doklad na nula korun', () => {
  it('se nevystavuje, i když má řádky', async () => {
    const provider = new MockProvider();
    const zdarma = mapujKlubMesicne({
      subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false,
      rezervace: rezervace.map((r) => ({ ...r, sazba: 0, castka: 0 })),
    });

    const v = await vystavDoklad({ draft: zdarma, provider, store: new PametovyStore(), cekej: hnedCekej });
    expect(v.stav).toBe('prazdne');
    expect(provider.volani.createInvoice).toBe(0);
  });
});

describe('okno mezi zámkem 2 a claimem', () => {
  // Zámek 2 se čte PŘED claimem. Kdyby se po claimu neopakoval, projde tudy
  // duplicita:
  //   • běh A i B projdou zámkem 2 (oba null),
  //   • B se zdrží (429 se u Fakturoidu čeká podle X-RateLimit-Reset až minutu),
  //   • A zabere claim, POSTne doklad, Fakturoid ho ZALOŽÍ a spadne na 5xx →
  //     A claim v catch UVOLNÍ (správně: neví, jak to dopadlo),
  //   • B claim dostane a POSTne DRUHÝ doklad.
  it('doklad, který vznikl mezi prvním dotazem a claimem, se najde a nezdvojí', async () => {
    const store = new PametovyStore();
    let dotazu = 0;
    let vytvoreno = 0;

    const provider = fakeProvider({
      // První dotaz (zámek 2) nic nenajde, druhý (po claimu) už ANO —
      // to je přesně ten doklad, který mezitím založil běh A.
      findExistingInvoice: async () => {
        dotazu++;
        return dotazu === 1 ? null : {
          providerInvoiceId: 'i-od-A', number: '20260001', variableSymbol: '20260001',
          status: 'open', providerTotal: 2400,
          providerLines: draftKlubu()!.lines.map((l) => ({ ...l })),
        };
      },
      createInvoice: async () => { vytvoreno++; throw new Error('sem se to nesmí dostat'); },
    });

    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });

    expect(v.stav).toBe('existoval');
    expect(vytvoreno).toBe(0);        // ← bez druhého dotazu by tu byla duplicita
    expect(dotazu).toBe(2);
  });

  it('když se doklad po claimu najde a NESEDÍ, claim se uvolní', async () => {
    const store = new PametovyStore();
    let dotazu = 0;
    const provider = fakeProvider({
      findExistingInvoice: async () => {
        dotazu++;
        return dotazu === 1 ? null : {
          providerInvoiceId: 'i-cizi', number: '20260009', variableSymbol: '20260009',
          status: 'open', providerTotal: 99_999,
        };
      },
    });

    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    expect(v.stav).toBe('nesedi');

    // Claim nesmí zůstat viset — jinak by klub nešlo vyfakturovat ani po nápravě.
    // Claim musí být volný — kdyby zůstal viset, klub by nešlo vyfakturovat
    // ani po nápravě.
    expect(await store.zkusZabrat(draftKlubu()!, { nasSoucet: 2400, rezim: 'koncept' })).toBe(true);
  });

  it('chyba při druhém dotazu taky claim uvolní', async () => {
    const store = new PametovyStore();
    let dotazu = 0;
    const provider = fakeProvider({
      findExistingInvoice: async () => {
        if (++dotazu === 1) return null;
        throw new Error('Fakturoid je mimo');
      },
    });

    await expect(vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej }))
      .rejects.toThrow('Fakturoid je mimo');
    // Claim musí být volný — kdyby zůstal viset, klub by nešlo vyfakturovat
    // ani po nápravě.
    expect(await store.zkusZabrat(draftKlubu()!, { nasSoucet: 2400, rezim: 'koncept' })).toBe(true);
  });
});

describe('dobirPdf — skutečná cesta k chybějícímu PDF', () => {
  // Jakmile vazba existuje, `vystavDoklad` se zastaví na `najdiPodleKlice`
  // a k PDF se vůbec nedostane. Bez samostatného vstupního bodu by doklad
  // zůstal bez PDF natrvalo, ačkoli komentář sliboval opak.
  it('dobere PDF k vazbě, která ho nemá', async () => {
    const provider = new MockProvider({ pdfNeniKrat: 1 });
    const store = new PametovyStore();

    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');
    expect(v.link.pdfPath).toBeUndefined();       // bez úložiště se PDF neřešilo

    const cesta = await dobirPdf({
      link: v.link, provider, store, cekej: hnedCekej,
      pdfUloziste: { uloz: async (klic) => ({ cesta: `invoices/${klic}.pdf` }) },
    });

    expect(cesta).toBe(`invoices/klub-${KLUB.id}-202608.pdf`);
    expect((await store.najdiPodleKlice(v.link.idempotencyKey))?.pdfPath).toBe(cesta);
  });

  it('vrátí null, když se PDF pořád generuje', async () => {
    const provider = new MockProvider({ pdfNeniKrat: 99 });
    const store = new PametovyStore();
    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');

    expect(await dobirPdf({
      link: v.link, provider, store, cekej: hnedCekej,
      pdfUloziste: { uloz: async () => ({ cesta: 'nikdy' }) },
    })).toBeNull();
  });
});

describe('selhání PDF se nespolkne', () => {
  it('důvod se vrátí ve varování, ne mlčky', async () => {
    const provider = fakeProvider({
      createInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
        status: 'open', providerTotal: 2400,
      }),
      downloadPdf: async () => { throw new Error('plné úložiště'); },
    });

    const v = await vystavDoklad({
      draft: draftKlubu(), provider, store: new PametovyStore(), cekej: hnedCekej,
      pdfUloziste: { uloz: async () => ({ cesta: 'nikdy' }) },
    });

    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');
    // Cizí text (Storage, Postgres) patří JEN do `interni` — v `zprava` je naše
    // věta, protože hlášky odjinud nesou cesty a názvy tabulek.
    expect(v.varovani?.[0].kod).toBe('pdf');
    expect(v.varovani?.[0].zprava).not.toMatch(/plné úložiště/);
    expect(v.varovani?.[0].interni).toMatch(/plné úložiště/);
  });
});

describe('režim vystavení', () => {
  const jenOdeslani = (poslano: string[], selze?: Error) => fakeProvider({
    createInvoice: async () => ({
      providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
      status: 'open', providerTotal: 2400,
    }),
    sendInvoice: async (id) => {
      if (selze) throw selze;
      poslano.push(id);
    },
  });

  it('DEFAULT je koncept — e-mail se NEPOSÍLÁ', async () => {
    // Rozjezdový režim: doklad se u Fakturoidu jen založí a člověk ho odklikne.
    const poslano: string[] = [];
    const v = await vystavDoklad({
      draft: draftKlubu(), provider: jenOdeslani(poslano),
      store: new PametovyStore(), cekej: hnedCekej,
    });

    expect(v.stav).toBe('vystaveno');
    expect(poslano).toEqual([]);
  });

  it('režim odeslat pošle e-mail a zapíše to', async () => {
    const poslano: string[] = [];
    const store = new PametovyStore();
    const v = await vystavDoklad({
      draft: draftKlubu(), provider: jenOdeslani(poslano), store,
      cekej: hnedCekej, rezim: 'odeslat',
    });

    expect(v.stav).toBe('vystaveno');
    expect(poslano).toEqual(['i1']);
    expect((await store.najdiPodleKlice(`klub-${KLUB.id}-202608`))?.odeslanoAt).toBeTruthy();
  });

  // Doklad v tu chvíli u providera EXISTUJE a má číslo. Kdyby selhání odeslání
  // shodilo vystavení, uvolnil by se claim a příští běh by se doklad pokusil
  // vystavit znovu.
  it('selhání odeslání NESHODÍ vystavení, jen varuje', async () => {
    const store = new PametovyStore();
    const v = await vystavDoklad({
      draft: draftKlubu(), provider: jenOdeslani([], new Error('chybí e-mail u odběratele')),
      store, cekej: hnedCekej, rezim: 'odeslat',
    });

    expect(v.stav).toBe('vystaveno');
    if (v.stav !== 'vystaveno') return;
    expect(v.varovani?.[0].kod).toBe('odeslani');
    expect(v.varovani?.[0].zprava).toMatch(/NEODESLAL/);
    expect(v.varovani?.[0].interni).toMatch(/chybí e-mail/);
    expect(await store.jeVyfakturovana('a')).toBe(true);
  });

  it('provider, který odesílat neumí, to řekne nahlas', async () => {
    const v = await vystavDoklad({
      draft: draftKlubu(),
      provider: fakeProvider({
        createInvoice: async () => ({
          providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
          status: 'open', providerTotal: 2400,
        }),
      }),
      store: new PametovyStore(), cekej: hnedCekej, rezim: 'odeslat',
    });

    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');
    expect(v.varovani?.[0].zprava).toMatch(/provider odesílání neumí/);
  });
});

describe('pořadí: značka „odesláno" se staví PŘED odesláním', () => {
  // Opačné pořadí vyřadí pojistku „podruhé se neposílá" úplně: pád mezi
  // odesláním a zápisem nechá doklad neoznačený a příští běh pošle e-mail znovu.
  it('při druhém běhu se e-mail neposílá znovu', async () => {
    const poslano: string[] = [];
    const store = new PametovyStore();
    const provider = fakeProvider({
      createInvoice: async () => ({
        providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
        status: 'open', providerTotal: 2400,
      }),
      findExistingInvoice: async () => null,
      sendInvoice: async (id) => { poslano.push(id); },
    });

    await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej, rezim: 'odeslat' });
    // Druhý běh zastaví zámek 1, ale i kdyby se dostal dál, značka drží.
    await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej, rezim: 'odeslat' });

    expect(poslano).toEqual(['i1']);
  });

  it('když značka nešla postavit, e-mail se NEPOSÍLÁ vůbec', async () => {
    const poslano: string[] = [];
    const store = new PametovyStore();
    // Store, který tvrdí „už bylo odesláno".
    store.oznacOdeslano = async () => false;

    const v = await vystavDoklad({
      draft: draftKlubu(),
      provider: fakeProvider({
        createInvoice: async () => ({
          providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
          status: 'open', providerTotal: 2400,
        }),
        sendInvoice: async (id) => { poslano.push(id); },
      }),
      store, cekej: hnedCekej, rezim: 'odeslat',
    });

    expect(v.stav).toBe('vystaveno');
    expect(poslano).toEqual([]);
  });

  // Cena opačného okraje: doklad zůstane označený jako odeslaný, ačkoli nedorazil.
  // Musí to být HLASITÉ, jinak by se na to nikdy nepřišlo.
  it('selhání odeslání řekne, že se má poslat ručně', async () => {
    const v = await vystavDoklad({
      draft: draftKlubu(),
      provider: fakeProvider({
        createInvoice: async () => ({
          providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
          status: 'open', providerTotal: 2400,
        }),
        sendInvoice: async () => { throw new Error('403 kvóta vyčerpána'); },
      }),
      store: new PametovyStore(), cekej: hnedCekej, rezim: 'odeslat',
    });

    if (v.stav !== 'vystaveno') throw new Error('čekal jsem vystavení');
    expect(v.varovani?.[0].zprava).toMatch(/ručně z Fakturoidu/);
    expect(v.varovani?.[0].zprava).toMatch(/automaticky nezopakuje/);
  });
});

describe('zotavení po ztracené odpovědi — zápis NÁLEZU bez claimu', () => {
  /**
   * Store, který se chová jako databáze, ne jako všeprijímající paměť.
   *
   * PROČ TENHLE TEST EXISTUJE: `PametovyStore.zapisVazbu` zapíše bezpodmínečně,
   * takže scénář zotavení procházel zeleně i tehdy, když ostrá cesta padala.
   * RPC `fakturoid_zapis_vazbu` totiž v základní větvi vyžaduje ŽIVÝ NEVYSTAVENÝ
   * CLAIM — a ten v týhle cestě neexistuje, protože ho předchozí běh po selhaném
   * POSTu správně uvolnil. Bez druhé větve („zapiš nález") by doklad zůstal
   * u Fakturoidu navždy nezaevidovaný a KAŽDÝ další běh by skončil stejně.
   */
  class PrisnyStore extends PametovyStore {
    zapisy: Array<{ klic: string; rezervace: string[]; nasSoucet: number }> = [];

    async zapisVazbu(draft: typeof DRAFT_T, result: never, meta: never): Promise<void> {
      const m = meta as unknown as { nasSoucet: number };
      // Databáze bez kontextu řádek založit NEMŮŽE — sloupce jsou NOT NULL.
      if (!draft.type || !draft.party.ourSubjectId || draft.sourceReservationIds.length === 0) {
        throw new Error('Nešlo zapsat do evidence: chybí kontext dokladu.');
      }
      this.zapisy.push({
        klic: draft.idempotencyKey,
        rezervace: [...draft.sourceReservationIds],
        nasSoucet: m.nasSoucet,
      });
      return super.zapisVazbu(draft, result, meta);
    }
  }
  const DRAFT_T = draftKlubu()!;

  it('nález se zapíše i s kontextem a vazbami na rezervace', async () => {
    const store = new PrisnyStore();
    const provider = fakeProvider({
      // Doklad u providera JE, ale u nás po něm není ani stopa: claim se uvolnil.
      findExistingInvoice: async () => ({
        providerInvoiceId: 'i-ztracene', number: '20260001', variableSymbol: '20260001',
        status: 'open', providerTotal: 2400,
        providerLines: draftKlubu()!.lines.map((l) => ({ ...l })),
      }),
    });

    const v = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });

    expect(v.stav).toBe('existoval');
    expect(store.zapisy).toHaveLength(1);
    // TOHLE je pointa: bez rezervací by po zotavení zůstal zámek 1 mrtvý
    // a příští běh by vystavil DRUHÝ doklad.
    expect(store.zapisy[0].rezervace).toEqual(['a', 'b']);
    expect(store.zapisy[0].nasSoucet).toBe(2400);
    expect(await store.jeVyfakturovana('a')).toBe(true);
    expect(await store.jeVyfakturovana('b')).toBe(true);
  });

  it('po zotavení už druhý běh doklad nevystaví', async () => {
    const store = new PrisnyStore();
    let vytvoreno = 0;
    const provider = fakeProvider({
      findExistingInvoice: async () => ({
        providerInvoiceId: 'i-ztracene', number: '20260001', variableSymbol: '20260001',
        status: 'open', providerTotal: 2400,
        providerLines: draftKlubu()!.lines.map((l) => ({ ...l })),
      }),
      createInvoice: async () => { vytvoreno++; throw new Error('sem se to nesmí dostat'); },
    });

    await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });
    const druhy = await vystavDoklad({ draft: draftKlubu(), provider, store, cekej: hnedCekej });

    expect(druhy.stav).toBe('preskoceno');   // zámek 1 už drží
    expect(vytvoreno).toBe(0);
  });
});

describe('rozpor kontrolního součtu se ukládá, ne jen vrací', () => {
  it('varování jde i do evidence', async () => {
    let ulozeneVarovani: string | undefined;
    const store = new PametovyStore();
    const puvodni = store.zapisVazbu.bind(store);
    store.zapisVazbu = async (d, r, m) => {
      ulozeneVarovani = (m as { varovani?: string }).varovani;
      return puvodni(d, r, m);
    };

    await vystavDoklad({
      draft: draftKlubu(),
      provider: fakeProvider({
        createInvoice: async () => ({
          providerInvoiceId: 'i1', number: '20260001', variableSymbol: '20260001',
          status: 'open', providerTotal: 9999,      // my posíláme 2 400 Kč
        }),
      }),
      store, cekej: hnedCekej,
    });

    // Bez tohohle by „KONTROLNÍ SOUČET NESEDÍ" žilo jen v HTTP odpovědi —
    // admin zavře záložku a je pryč.
    expect(ulozeneVarovani).toMatch(/KONTROLNÍ SOUČET NESEDÍ/);
  });
});
