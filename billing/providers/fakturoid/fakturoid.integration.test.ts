// Integrační testy proti ŽIVÉMU testovacímu účtu Fakturoidu.
//
// BĚŽÍ JEN S `FAKTUROID_LIVE=true` v necommitovaném `.env`. Bez něj se celý
// soubor PŘESKOČÍ — ne spadne. Rozdíl je podstatný: vývojář bez klíčů má mít
// zelenou sadu, ne červenou, kterou se naučí ignorovat.
//
// CO TYHLE TESTY ZAKLÁDAJÍ NA ÚČTU: jednoho odběratele (stabilního napříč běhy)
// a DVA doklady na běh — jeden klubový (ceny včetně DPH) a jeden komerční (ceny
// bez DPH). Oba mají `custom_id` s razítkem běhu, takže se navzájem nepotkají.
// Nejsou to smyšlené doklady vydávané za pravé — je to testovací účet Fakturoidu
// a data jsou zjevně testovací.
//
// REŽIM DPH SE BERE Z `IS_VAT_PAYER`, tedy z téhož přepínače jako provoz.
// Testy běží v obou režimech a jen tvrdí něco jiného; přepnutím testovacího účtu
// na plátce se z nich stane ověření plátcovského dokladu naživo.
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
import {
  mapujKlubMesicne, mapujKomercniAkci, soucetRadku, SAZBA_DPH_LED, type BillableReservation,
} from '../../mapping.ts';
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
 *
 * Vteřiny jsou tu podstatné: s minutovým rozlišením by dva běhy do jedné minuty
 * dostaly týž identifikátor a druhý by spadl na „expected 'existoval' to be 'vystaveno'".
 */
const BEH = new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '');

/**
 * Odběratel je STABILNÍ napříč běhy, doklad ne.
 *
 * Dřív nesl razítko běhu i odběratel — a na free tarifu Fakturoidu, kde je
 * limit odběratelů, to znamenalo, že každý běh sady sežral jedno místo a po pár
 * spuštěních začalo `ensureSubject` padat na `quota_exhausted`. Ukázalo se to až
 * naživo. Stabilní `custom_id` navíc testuje `ensureSubject` líp: druhý běh ho
 * má NAJÍT, ne založit dalšího.
 */
const TEST_KLUB_ID = 'test-klub-curling';

const rezervace: BillableReservation[] = [
  { id: `r1-${BEH}`, start_at: '2026-08-04T16:00:00Z', end_at: '2026-08-04T17:30:00Z', sheet_name: 'Dráha 1', event_title: 'Integrační test', hodiny: 1.5, sazba: 833.67, castka: 1250.51 },
  { id: `r2-${BEH}`, start_at: '2026-08-11T16:00:00Z', end_at: '2026-08-11T17:30:00Z', sheet_name: 'Dráha 1', event_title: 'Integrační test', hodiny: 1.5, sazba: 833.67, castka: 1250.51 },
  { id: `r3-${BEH}`, start_at: '2026-08-18T16:00:00Z', end_at: '2026-08-18T17:30:00Z', sheet_name: 'Dráha 1', event_title: 'Integrační test', hodiny: 1.5, sazba: 833.67, castka: 1250.51 },
];

/**
 * Je testovací účet PLÁTCE DPH?
 *
 * Bere se z `IS_VAT_PAYER` — tedy z téhož přepínače, kterým se řídí provoz.
 * Testy níž se podle něj chovají jinak, ale běží v OBOU režimech: dokud je účet
 * neplátcovský, ověřují, že se DPH nikam neplete; jakmile ho někdo přepne na
 * plátce, ověří naživo i sazbu a `vat_price_mode`.
 */
const jePlatceDph = nactiConfig(env as Record<string, string | undefined>).jePlatceDph;

const subjekt = {
  id: TEST_KLUB_ID,
  name: 'TEST Curling Ostrava',
  ico: '26512345',
  dic: null,
  address: 'Sportovní 12, 702 00 Ostrava',
};

/**
 * KLUBOVÝ doklad — ceny VČETNĚ DPH (`vat_price_mode = from_total_with_vat`).
 *
 * ⚠️ KLÍČ SE TU PŘEPISUJE NA PER-BĚH, a je to podstatné.
 * `klicKlubu` skládá klíč z id klubu a MĚSÍCE (`klub-{id}-{RRRRMM}`), takže je
 * napříč běhy STABILNÍ — druhý běh by narazil na doklad z prvního a místo
 * vystavení by testoval jen „existoval". Přesně tohle se stalo: na testovacím
 * účtu zůstal doklad z dřívějška, někdo do něj ručně přidal řádek „občerstvení"
 * za 10 000 Kč a od té chvíle sada padala na „expected 'nesedi' to be
 * 'vystaveno'" a na deltě 9 999,53 Kč. Nebyla to chyba kódu ani DPH — byl to
 * cizí řádek v cizím dokladu, který si testy samy našly.
 *
 * Tvar klíče hlídá `idempotency.test.ts`; tady jde o providera, ne o klíč.
 */
const draftKlub = () => {
  const d = mapujKlubMesicne({
    subjekt,
    obdobiOd: '2026-08-01',
    jePlatceDph,
    rezervace,
  });
  return d ? { ...d, idempotencyKey: `klub-test-${BEH}` } : null;
};

/** KOMERČNÍ doklad — ceny BEZ DPH (`vat_price_mode = without_vat`). */
const draftAkce = () => mapujKomercniAkci({
  eventId: `test-${BEH}`,
  subjekt,
  jePlatceDph,
  rezervace,
});

/** Zpětná kompatibilita pro testy, kterým je typ dokladu jedno. */
const draft = draftKlub;

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
          return { cesta: `test/${klic}.pdf` };
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
    const d = draftKlub()!;
    const doklad = await provider().findExistingInvoice(d.idempotencyKey);
    expect(doklad).not.toBeNull();

    const nasPresny = soucetRadku(d.lines);
    const nasKUhrade = roundCzk(nasPresny);

    // LIKE S LIKE. Klubový doklad má ceny VČETNĚ DPH, takže náš součet řádků je
    // částka s daní a protějšek je `total`. U komerčního dokladu (ceny bez daně)
    // by to byl `subtotal` — porovnat základ s celkovou částkou by dalo rozdíl
    // přesně ve výši DPH a vypadalo by to jako chyba mapování.
    const fakturoid = doklad!.providerTotal;

    if (fakturoid === undefined) {
      console.warn('[ZAOKROUHLENÍ] Fakturoid nevrátil celkovou částku — odchylka se nezměřila.');
      return;
    }

    const delta = Number((fakturoid - nasKUhrade).toFixed(2));
    console.info(
      `[ZAOKROUHLENÍ] režim ${jePlatceDph ? 'PLÁTCE (ceny s DPH)' : 'neplátce'} · ` +
      `přesný součet ${nasPresny} Kč · naše k úhradě ${nasKUhrade} Kč · ` +
      `Fakturoid ${fakturoid} Kč · DELTA ${delta > 0 ? '+' : ''}${delta} Kč na doklad`,
    );

    // Do 0,50 Kč je to rozdíl zaokrouhlovacího pravidla — čekaná odchylka, o které
    // se rozhodne (nastavit zaokrouhlení na účtu / zapsat jako známou). Nad 0,50 Kč
    // je špatně něco jiného: mapování, sazba, nebo počet řádků.
    expect(Math.abs(delta)).toBeLessThanOrEqual(0.5);
  });

  // ---------------------------------------------------------------------------
  // DPH NA ŽIVÉM DOKLADU
  //
  // Běží v OBOU režimech, jen tvrdí něco jiného. Dokud je testovací účet
  // neplátcovský, hlídá, že se DPH nikam nepřimíchá; jakmile ho někdo přepne na
  // plátce, ověří naživo sazbu i to, že `vat_price_mode` opravdu rozhoduje
  // o významu `unit_price`.
  //
  // Ta druhá půlka je důvod, proč se testovací účet vyplatí přepnout: `subtotal`
  // vs. `total` je jediné místo, kde se dá zvenčí ověřit, že Fakturoid pochopil
  // klubovou cenu jako částku S DANÍ, a ne jako základ, ke kterému daň přidá.
  // ---------------------------------------------------------------------------
  it('KOMERČNÍ doklad: ceny bez DPH, základ = náš součet', { timeout: 60_000 }, async () => {
    const d = draftAkce()!;
    const vysledek = await vystavDoklad({
      draft: d, provider: provider(), store: new PametovyStore(),
    });
    expect(vysledek.stav).toBe('vystaveno');
    if (vysledek.stav !== 'vystaveno') return;

    const u = vysledek.link.result;
    const nase = roundCzk(soucetRadku(d.lines));

    console.info(
      `[DPH · komerční] pricesIncludeVat=${d.pricesIncludeVat} · náš součet ${nase} Kč · ` +
      `subtotal ${u.providerSubtotal} Kč · total ${u.providerTotal} Kč`,
    );

    expect(u.providerSubtotal).toBeDefined();

    if (!jePlatceDph) {
      // Neplátce: základ a celkem je totéž číslo a rovná se našemu součtu.
      expect(u.providerSubtotal).toBeCloseTo(nase, 2);
      expect(u.providerTotal).toBeCloseTo(nase, 2);
      return;
    }

    // Plátce, ceny BEZ DPH: náš součet je ZÁKLAD, celkem je o daň vyšší.
    expect(Math.abs(u.providerSubtotal! - nase)).toBeLessThanOrEqual(0.5);
    expect(u.providerTotal!).toBeGreaterThan(u.providerSubtotal!);

    const dan = u.providerTotal! - u.providerSubtotal!;
    const cekana = u.providerSubtotal! * (SAZBA_DPH_LED / 100);
    expect(Math.abs(dan - cekana)).toBeLessThanOrEqual(0.5);
  });

  it('KLUBOVÝ doklad: ceny včetně DPH, celkem = náš součet', { timeout: 30_000 }, async () => {
    const d = draftKlub()!;
    const doklad = await provider().findExistingInvoice(d.idempotencyKey);
    expect(doklad).not.toBeNull();

    const nase = roundCzk(soucetRadku(d.lines));
    console.info(
      `[DPH · klubový] pricesIncludeVat=${d.pricesIncludeVat} · náš součet ${nase} Kč · ` +
      `subtotal ${doklad!.providerSubtotal} Kč · total ${doklad!.providerTotal} Kč`,
    );

    // TOHLE JE TO PODSTATNÉ TVRZENÍ: u klubu se náš součet rovná ČÁSTCE S DANÍ,
    // ne základu. Kdyby Fakturoid pochopil klubovou cenu jako základ, vyšla by
    // faktura o 12 % vyšší, než jakou hala klubu slíbila.
    expect(Math.abs(doklad!.providerTotal! - nase)).toBeLessThanOrEqual(0.5);

    if (jePlatceDph) {
      expect(doklad!.providerSubtotal!).toBeLessThan(doklad!.providerTotal!);
    } else {
      expect(doklad!.providerSubtotal).toBeCloseTo(nase, 2);
    }
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
