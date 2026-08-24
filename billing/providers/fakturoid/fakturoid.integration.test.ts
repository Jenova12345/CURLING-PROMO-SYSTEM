// Integrační testy proti ŽIVÉMU testovacímu účtu Fakturoidu.
//
// BĚŽÍ JEN S `FAKTUROID_LIVE=true` v necommitovaném `.env`. Bez něj se celý
// soubor PŘESKOČÍ — ne spadne. Rozdíl je podstatný: vývojář bez klíčů má mít
// zelenou sadu, ne červenou, kterou se naučí ignorovat.
//
// CO TYHLE TESTY ZAKLÁDAJÍ NA ÚČTU: jednoho odběratele a jeden doklad na běh,
// s `custom_id` začínajícím `test-`. Nejsou to smyšlené doklady vydávané za
// pravé — je to testovací účet Fakturoidu a data jsou zjevně testovací.
//
// Spuštění:
//   FAKTUROID_LIVE=true npx vitest run billing/providers/fakturoid/fakturoid.integration
//   (nebo FAKTUROID_LIVE=true v .env)

import { loadEnv } from 'vite';
import { describe, expect, it } from 'vitest';

import { FakturoidProvider } from './index.ts';
import { nactiConfig } from './config.ts';
import { stahniPdf, vystavDoklad } from '../../pipeline.ts';
import { PametovyStore } from '../../store.ts';
import { mapujKlubMesicne, soucetRadku, type BillableReservation } from '../../mapping.ts';
import { roundCzk } from '../../../src/lib/money.ts';

// `loadEnv` čte `.env` stejně, jako to dělá aplikace — bez další závislosti.
// Prázdný prefix znamená „všechno", ne jen `VITE_`.
const env = { ...loadEnv('', process.cwd(), ''), ...process.env };
const jeAno = (v: string | undefined) => ['true', '1', 'yes', 'ano'].includes((v ?? '').toLowerCase());

/**
 * DVOJITÁ POJISTKA PROTI OSTRÉMU ÚČTU.
 *
 * `FAKTUROID_LIVE=true` samo NESTAČÍ. Kdo v `.env` nechá produkční slug z minulého
 * týdne a zapne LIVE, vystaví tímhle souborem tři REÁLNÉ doklady v ostré číselné
 * řadě — a ty nejdou smazat, jen dobropisovat. Číslo v řadě zůstane navždy.
 *
 * Proto se musí NAVÍC vypsat jméno účtu, na který se smí psát, a musí se shodovat
 * s `FAKTUROID_SLUG`. Opsat slug je vědomý úkon; zapomenout přepnout `LIVE` zpátky
 * na false je nehoda.
 */
const povolenyUcet = (env.FAKTUROID_TEST_SLUG ?? '').trim();
const slug = (env.FAKTUROID_SLUG ?? '').trim();
const potvrzeno = povolenyUcet !== '' && povolenyUcet === slug;
const live = jeAno(env.FAKTUROID_LIVE) && potvrzeno;

/**
 * Identifikátor běhu. Musí být STABILNÍ uvnitř běhu (jinak by se netestovala
 * idempotence) a JINÝ mezi běhy (jinak by druhý běh narazil na doklad z prvního
 * a netestoval by vystavení).
 */
const BEH = new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '');
const TEST_KLUB_ID = `test-klub-${BEH}`;

const rezervace: BillableReservation[] = [
  { id: `r1-${BEH}`, start_at: '2026-08-04T16:00:00Z', end_at: '2026-08-04T17:30:00Z', sheet_name: 'Dráha 1', event_title: 'Integrační test', hodiny: 1.5, sazba: 833.67, castka: 1250.51 },
  { id: `r2-${BEH}`, start_at: '2026-08-11T16:00:00Z', end_at: '2026-08-11T17:30:00Z', sheet_name: 'Dráha 1', event_title: 'Integrační test', hodiny: 1.5, sazba: 833.67, castka: 1250.51 },
  { id: `r3-${BEH}`, start_at: '2026-08-18T16:00:00Z', end_at: '2026-08-18T17:30:00Z', sheet_name: 'Dráha 1', event_title: 'Integrační test', hodiny: 1.5, sazba: 833.67, castka: 1250.51 },
];

const draft = () => mapujKlubMesicne({
  subjekt: {
    id: TEST_KLUB_ID,
    name: `TEST Curling Ostrava ${BEH}`,
    ico: '26512345',
    dic: null,
    address: 'Sportovní 12, 702 00 Ostrava',
  },
  obdobiOd: '2026-08-01',
  jePlatceDph: false,
  rezervace,
});

describe.skipIf(!live)('Fakturoid — živý testovací účet', () => {
  const provider = () => new FakturoidProvider({
    config: nactiConfig(env as Record<string, string | undefined>),
    fetch: globalThis.fetch as never,
  });

  it('založí odběratele a podruhé ho jen najde', { timeout: 30_000 }, async () => {
    const p = provider();
    const party = draft()!.party;

    const prvni = await p.ensureSubject(party);
    const druhe = await p.ensureSubject(party);

    expect(prvni.providerSubjectId).toBeTruthy();
    expect(druhe.providerSubjectId).toBe(prvni.providerSubjectId);
  });

  it('vystaví doklad, stáhne PDF (204 → opakuj) a při druhém běhu NEvytvoří duplicitu',
    { timeout: 60_000 }, async () => {
      const p = provider();
      const store = new PametovyStore();
      const ulozene: string[] = [];
      const pdfUloziste = {
        uloz: async (klic: string, pdf: Uint8Array) => {
          // Kontrola, že to je opravdu PDF, ne chybová stránka s HTTP 200.
          expect(new TextDecoder().decode(pdf.slice(0, 5))).toBe('%PDF-');
          ulozene.push(klic);
          return `test/${klic}.pdf`;
        },
      };

      const prvni = await vystavDoklad({ draft: draft(), provider: p, store, pdfUloziste });
      expect(prvni.stav).toBe('vystaveno');
      if (prvni.stav !== 'vystaveno') return;

      // Číslo i variabilní symbol přidělil Fakturoid — my jsme je neposlali.
      expect(prvni.link.result.number).toBeTruthy();
      expect(prvni.link.result.variableSymbol).toBeTruthy();
      expect(ulozene).toEqual([prvni.link.idempotencyKey]);

      // Druhý běh s ČISTÝM úložištěm: zámek 1 nezabere (nic si nepamatuje),
      // takže se testuje výhradně zámek 2 — dotaz k providerovi před POSTem.
      const druhy = await vystavDoklad({ draft: draft(), provider: p, store: new PametovyStore() });
      expect(druhy.stav).toBe('existoval');
      if (druhy.stav !== 'existoval') return;
      expect(druhy.link.result.providerInvoiceId).toBe(prvni.link.result.providerInvoiceId);
    });

  it('stažení PDF snese 204 a dobere se k bajtům', { timeout: 60_000 }, async () => {
    const p = provider();
    const doklad = await p.findExistingInvoice(draft()!.idempotencyKey);
    expect(doklad).not.toBeNull();

    const pdf = await stahniPdf(p, doklad!.providerInvoiceId);
    expect(pdf).not.toBeNull();
    expect(new TextDecoder().decode(pdf!.slice(0, 5))).toBe('%PDF-');
  });

  // ---------------------------------------------------------------------------
  // MĚŘENÍ ZAOKROUHLOVACÍ ODCHYLKY
  //
  // Fakturoid si celkovou částku zaokrouhluje sám a jeho pravidlo nemusí být naše
  // `round(round(v, 2), 0)` (rozhodnutí R3). Tenhle test odchylku NEPŘEKRÝVÁ —
  // změří ji, vypíše na doklad a propustí jen to, co ještě může být zaokrouhlením.
  //
  // Fixtura je schválně ta, na které se to má projevit: 3 × 1 250,505 Kč.
  //   přesný součet          3 751,53 Kč
  //   naše částka k úhradě   3 752 Kč   (round(round(3751.53, 2), 0))
  //   po řádcích             3 753 Kč   (chyba, které se vyhýbáme)
  // ---------------------------------------------------------------------------
  it('změří rozdíl mezi naším zaokrouhlením a Fakturoidovým', { timeout: 30_000 }, async () => {
    const d = draft()!;
    const doklad = await provider().findExistingInvoice(d.idempotencyKey);
    expect(doklad).not.toBeNull();

    const nasPresny = soucetRadku(d.lines);
    const nasKUhrade = roundCzk(nasPresny);
    const fakturoid = doklad!.providerTotal;

    if (fakturoid === undefined) {
      console.warn('[ZAOKROUHLENÍ] Fakturoid nevrátil celkovou částku — odchylka se nezměřila.');
      return;
    }

    const delta = Number((fakturoid - nasKUhrade).toFixed(2));
    console.info(
      `[ZAOKROUHLENÍ] přesný součet ${nasPresny} Kč · naše k úhradě ${nasKUhrade} Kč · ` +
      `Fakturoid ${fakturoid} Kč · DELTA ${delta > 0 ? '+' : ''}${delta} Kč na doklad`,
    );

    // Do 0,50 Kč je to rozdíl zaokrouhlovacího pravidla — čekaná odchylka, o které
    // se rozhodne (nastavit zaokrouhlení na účtu / zapsat jako známou). Nad 0,50 Kč
    // je špatně něco jiného: mapování, sazba, nebo počet řádků.
    expect(Math.abs(delta)).toBeLessThanOrEqual(0.5);
  });
});

describe.skipIf(live)('Fakturoid — integrační testy přeskočeny', () => {
  it('bez FAKTUROID_LIVE=true se nikam nevolá', () => {
    expect(live).toBe(false);
  });

  // Tichý skip při zapnutém LIVE by vypadal jako „testy prošly". Musí být hlasitý:
  // buď je pojistka správně vyplněná, nebo se nikdo nedozví, že se netestovalo.
  it('zapnuté FAKTUROID_LIVE bez potvrzeného účtu je chyba, ne tichý skip', () => {
    if (!jeAno(env.FAKTUROID_LIVE)) return;
    expect(potvrzeno,
      `FAKTUROID_LIVE=true, ale FAKTUROID_TEST_SLUG („${povolenyUcet}") se neshoduje ` +
      `s FAKTUROID_SLUG („${slug}"). Integrační testy zakládají REÁLNÉ doklady — ` +
      'vypiš do FAKTUROID_TEST_SLUG jméno testovacího účtu, na který se smí psát. ' +
      'Doklad v ostré řadě nejde smazat, jen dobropisovat.',
    ).toBe(true);
  });
});
