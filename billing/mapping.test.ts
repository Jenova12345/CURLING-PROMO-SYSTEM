import { describe, expect, it } from 'vitest';

import {
  JEDNOTKA, SAZBA_DPH_LED, SPLATNOST_DNI, mapujKlubMesicne, mapujKomercniAkci, mapujSubjekt,
  popisAkce, popisKlubu, soucetRadku,
  type BillableReservation, type SubjectForBilling,
} from './mapping.ts';
import { BillingValidationError } from './errors.ts';
import { fromHal, roundCzk, toHal, toSetiny } from '../src/lib/money.ts';

const KLUB: SubjectForBilling = {
  id: 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
  name: 'SK Curling Ostrava',
  ico: '26512345',
  dic: 'CZ26512345',
  address: 'Sportovní 12, 702 00 Ostrava',
};

const FIRMA: SubjectForBilling = {
  id: 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',
  name: 'Vítkovice Steel a.s.',
  ico: '12345678',
  dic: 'CZ12345678',
  address: 'Ruská 2887/101, 706 02 Ostrava',
};

/** Rezervace držící invariant `castka = round(hodiny × sazba, 2)` — jako trigger v DB. */
const rez = (o: Partial<BillableReservation> & { id: string; start_at: string; end_at: string }): BillableReservation => {
  const hodiny = o.hodiny ?? 1;
  const sazba = o.sazba ?? 1200;
  return {
    sheet_name: 'Dráha 1',
    event_title: null,
    objednal: null,
    hodiny,
    sazba,
    castka: fromHal(toHal(hodiny * sazba)),
    ...o,
  };
};

describe('mapujSubjekt — odběratel', () => {
  it('u neplátce DPH neposílá DIČ', () => {
    const p = mapujSubjekt(KLUB, { jePlatceDph: false });
    expect(p.vatNo).toBeUndefined();
    expect(p.registrationNo).toBe('26512345');
    expect(p.ourSubjectId).toBe(KLUB.id);
    expect(p.country).toBe('CZ');
  });

  it('u plátce DPH DIČ pošle', () => {
    expect(mapujSubjekt(KLUB, { jePlatceDph: true }).vatNo).toBe('CZ26512345');
  });

  it('D3 — celá adresa jde do street, city a zip zůstávají prázdné', () => {
    const p = mapujSubjekt(KLUB, { jePlatceDph: false });
    expect(p.street).toBe('Sportovní 12, 702 00 Ostrava');
    expect(p.city).toBeUndefined();
    expect(p.zip).toBeUndefined();
  });

  it('prázdné IČO se neposílá jako prázdný řetězec', () => {
    const p = mapujSubjekt({ ...KLUB, ico: '  ', dic: null }, { jePlatceDph: true });
    expect(p.registrationNo).toBeUndefined();
    expect(p.vatNo).toBeUndefined();
  });

  it('subjekt bez názvu je tvrdá chyba, ne doklad na „undefined“', () => {
    expect(() => mapujSubjekt({ ...KLUB, name: '   ' }, { jePlatceDph: false }))
      .toThrow(BillingValidationError);
  });
});

describe('popis řádku — pražský čas', () => {
  it('typ A: „Pronájem ledové plochy — Dráha 1, 22.08. 18:00–20:00“', () => {
    expect(popisAkce(rez({
      id: 'r1', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T18:00:00Z',
    }))).toBe('Pronájem ledové plochy — Dráha 1, 22.08. 18:00–20:00');
  });

  it('typ B: „22.08. 18:00–19:00 · <název akce>“', () => {
    expect(popisKlubu(rez({
      id: 'r1', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T17:00:00Z',
      event_title: 'Trénink přípravky',
    }))).toBe('22.08. 18:00–19:00 · Trénink přípravky');
  });

  it('typ B bez názvu akce spadne na „kdo objednal“ a pak na dráhu', () => {
    const zaklad = { id: 'r1', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T17:00:00Z' };
    expect(popisKlubu(rez({ ...zaklad, objednal: 'Novák' })))
      .toBe('22.08. 18:00–19:00 · Novák');
    expect(popisKlubu(rez({ ...zaklad, sheet_name: 'Dráha 2' })))
      .toBe('22.08. 18:00–19:00 · Dráha 2');
  });

  // Letní vs. zimní čas: kdyby se formátovalo v UTC, jeden z těch dvou by ukázal
  // o hodinu vedle — a všiml by si toho až klub v lednu.
  it('drží pražský čas v létě i v zimě', () => {
    expect(popisKlubu(rez({ id: 'l', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T17:00:00Z' })))
      .toContain('18:00–19:00');
    expect(popisKlubu(rez({ id: 'z', start_at: '2026-01-15T17:00:00Z', end_at: '2026-01-15T18:00:00Z' })))
      .toContain('18:00–19:00');
  });

  it('používá en dash, ne spojovník — je to rozsah', () => {
    const p = popisAkce(rez({ id: 'r1', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T18:00:00Z' }));
    expect(p).toContain('–');
    expect(p).not.toContain('18:00-20:00');
  });
});

describe('typ A — komerční akce', () => {
  const AKCE = 'cccccccc-3333-4333-8333-cccccccccccc';

  const vstup = {
    eventId: AKCE,
    subjekt: FIRMA,
    jePlatceDph: false,
    rezervace: [
      rez({ id: 'r-draha1', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T18:00:00Z', hodiny: 2, sazba: 2500, sheet_name: 'Dráha 1' }),
      rez({ id: 'r-draha2', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T18:00:00Z', hodiny: 2, sazba: 2500, sheet_name: 'Dráha 2' }),
    ],
  };

  it('D2 — klíč je akce-{eventId}, obě dráhy na JEDNOM dokladu', () => {
    const d = mapujKomercniAkci(vstup)!;
    expect(d.idempotencyKey).toBe(`akce-${AKCE}`);
    expect(d.lines).toHaveLength(2);
    expect(d.sourceReservationIds).toEqual(['r-draha1', 'r-draha2']);
  });

  it('řádek nese hodiny a SAZBU, ne předpočítanou částku', () => {
    const [radek] = mapujKomercniAkci(vstup)!.lines;
    expect(radek.quantity).toBe(2);
    expect(radek.unitPrice).toBe(2500);
    expect(radek.unitName).toBe(JEDNOTKA);
  });

  it('splatnost je 14 dní, pokud se neurčí jinak', () => {
    expect(mapujKomercniAkci(vstup)!.dueInDays).toBe(SPLATNOST_DNI);
    expect(mapujKomercniAkci({ ...vstup, dueInDays: 30 })!.dueInDays).toBe(30);
  });

  // Pozor na naivní verzi tohohle testu: hledat podřetězec „vat“ v celém JSONu
  // nejde, protože ho nese samo slovo `sourceReservationIds` (Reser-vat-ion).
  // Proto se kontrolují KLÍČE, ne text.
  it('neplátce — řádek nemá žádné pole kolem DPH a odběratel nemá DIČ', () => {
    const d = mapujKomercniAkci(vstup)!;
    for (const radek of d.lines) {
      expect(Object.keys(radek).sort()).toEqual(['name', 'quantity', 'unitName', 'unitPrice']);
    }
    expect('vatNo' in d.party).toBe(false);
  });

  it('bez rezervací nevznikne doklad', () => {
    expect(mapujKomercniAkci({ ...vstup, rezervace: [] })).toBeNull();
  });

  it('řádky jsou chronologické bez ohledu na pořadí na vstupu', () => {
    const d = mapujKomercniAkci({
      ...vstup,
      rezervace: [
        rez({ id: 'pozdni', start_at: '2026-08-22T18:00:00Z', end_at: '2026-08-22T19:00:00Z' }),
        rez({ id: 'rani', start_at: '2026-08-22T06:00:00Z', end_at: '2026-08-22T07:00:00Z' }),
      ],
    })!;
    expect(d.sourceReservationIds).toEqual(['rani', 'pozdni']);
  });
});

describe('typ B — měsíční souhrn klubu', () => {
  const vstup = {
    subjekt: KLUB,
    obdobiOd: '2026-08-01',
    jePlatceDph: false,
    rezervace: [
      rez({ id: 'a', start_at: '2026-08-04T16:00:00Z', end_at: '2026-08-04T17:00:00Z', event_title: 'Trénink A' }),
      rez({ id: 'b', start_at: '2026-08-11T16:00:00Z', end_at: '2026-08-11T17:00:00Z', event_title: 'Trénink B' }),
    ],
  };

  it('klíč je klub-{clubId}-{RRRRMM} a řádek je jedna rezervace', () => {
    const d = mapujKlubMesicne(vstup)!;
    expect(d.idempotencyKey).toBe(`klub-${KLUB.id}-202608`);
    expect(d.lines).toHaveLength(2);
    expect(d.type).toBe('club_monthly');
  });

  it('měsíc v klíči se bere z OBDOBÍ, ne z rezervací ani z „teď“', () => {
    // Přefakturování července v srpnu musí dát týž klíč jako původní běh.
    expect(mapujKlubMesicne({ ...vstup, obdobiOd: '2026-07-01' })!.idempotencyKey)
      .toBe(`klub-${KLUB.id}-202607`);
  });

  it('klub s 0 zpoplatněnými rezervacemi → ŽÁDNÝ doklad', () => {
    expect(mapujKlubMesicne({ ...vstup, rezervace: [] })).toBeNull();
  });
});

describe('overRadek — co se nesmí dostat na doklad', () => {
  const zaklad = { id: 'x', start_at: '2026-08-22T16:00:00Z', end_at: '2026-08-22T17:00:00Z' };
  const draft = (r: BillableReservation) =>
    mapujKomercniAkci({ eventId: 'ev1', subjekt: FIRMA, jePlatceDph: false, rezervace: [r] });

  it('nulové hodiny neprojdou (schéma má hodiny > 0)', () => {
    expect(() => draft({ ...rez(zaklad), hodiny: 0, castka: 0 })).toThrow(BillingValidationError);
  });

  it('záporná sazba neprojde', () => {
    expect(() => draft({ ...rez(zaklad), sazba: -1, castka: -1 })).toThrow(BillingValidationError);
  });

  // NaN prošla kdysi v Postgresu úplně všemi peněžními CHECKy ('NaN'::numeric >= 0
  // je TRUE). Tady musí skončit hlasitě, ne dokladem na „NaN Kč“.
  it('NaN v hodinách ani v sazbě neprojde', () => {
    expect(() => draft({ ...rez(zaklad), hodiny: NaN, castka: NaN })).toThrow(BillingValidationError);
    expect(() => draft({ ...rez(zaklad), sazba: NaN, castka: NaN })).toThrow(BillingValidationError);
  });

  it('částka, která nesedí na hodiny × sazbu, neprojde', () => {
    expect(() => draft({ ...rez(zaklad), hodiny: 2, sazba: 1000, castka: 1500 }))
      .toThrow(/nesedí na 2 h × 1000 Kč\/h/);
  });
});

describe('kontrolní součet — řádky dokladu vs. „Kdo kolik dluží“', () => {
  // Tři rezervace po 1 250,505 Kč. Přesně ten případ, na kterém se v Etapě 2
  // rozešla obrazovka s dokladem: po řádcích zaokrouhleno 3 753 Kč, správně 3 752 Kč.
  //
  // `castka` je tu LITERÁL, ne dopočet. Kdyby se počítala týmž `toSetiny`, kterým
  // jde `soucetRadku`, chyba v `toSetiny` by se v porovnání vykrátila a test by
  // zůstal zelený. Takhle je to hodnota, jakou by uložil Postgres
  // (`round(1.5 × 833.67, 2)` = 1250.51), tedy nezávislý bod.
  //
  // Co tenhle test NEDOKAZUJE: že je `toSetiny` samo o sobě správně — to je práce
  // `money.test.ts` a skriptu `overit:zaokrouhleni` proti živé DB. Tady se ověřuje,
  // že mapování žádný řádek nezahodí, nezdvojí ani nepřepočítá jinak než „Kdo dluží“.
  const rezervace = [
    rez({ id: 'a', start_at: '2026-08-04T16:00:00Z', end_at: '2026-08-04T17:30:00Z', hodiny: 1.5, sazba: 833.67, castka: 1250.51 }),
    rez({ id: 'b', start_at: '2026-08-11T16:00:00Z', end_at: '2026-08-11T17:30:00Z', hodiny: 1.5, sazba: 833.67, castka: 1250.51 }),
    rez({ id: 'c', start_at: '2026-08-18T16:00:00Z', end_at: '2026-08-18T17:30:00Z', hodiny: 1.5, sazba: 833.67, castka: 1250.51 }),
  ];

  const draft = mapujKlubMesicne({
    subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace,
  })!;

  /**
   * Dluh počítaný tak, jak ho počítá `useDues`: z `castka` (tedy z
   * `COALESCE(corrected_amount, amount)`), v haléřích, bez průběžného zaokrouhlení.
   *
   * Součet řádků naproti tomu jde z HODIN × SAZBY. Obě strany tedy vycházejí
   * z jiného sloupce, stejně jako to dělá `billing_reconcile` — kdyby braly
   * z téhož, sedělo by to vždycky a nezjistilo nic.
   */
  const dluziZaMesic = fromHal(rezervace.reduce((s, r) => s + toHal(r.castka), 0));

  it('součet řádků dokladu == „Kdo kolik dluží“ za tentýž měsíc a klub', () => {
    expect(soucetRadku(draft.lines)).toBe(dluziZaMesic);
  });

  it('drží to na pevné hodnotě, ne jen samo se sebou', () => {
    expect(dluziZaMesic).toBe(3751.53);
    expect(soucetRadku(draft.lines)).toBe(3751.53);
  });

  it('sčítá se přesně, ne po zaokrouhlených řádcích', () => {
    const poRadcich = draft.lines.reduce((s, l) => s + roundCzk(l.quantity * l.unitPrice), 0);
    expect(poRadcich).toBe(3753);        // ← chyba, které se vyhýbáme
    expect(roundCzk(soucetRadku(draft.lines))).toBe(3752);
  });

  it('vypadlý nebo zdvojený řádek se pozná', () => {
    // Pojistka, že test měří mapování, ne jen aritmetiku sám se sebou.
    const bezJednoho = mapujKlubMesicne({
      subjekt: KLUB, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: rezervace.slice(0, 2),
    })!;
    expect(soucetRadku(bezJednoho.lines)).not.toBe(dluziZaMesic);
  });
});

// =============================================================================
// DPH — MECHANISMUS
//
// Konkrétní částky ceníku (klub včetně daně, komerce bez ní) přijdou zvlášť.
// Tady se testuje jen to, CO mapování o dani tvrdí — ne kolik stojí hodina ledu.
// =============================================================================
describe('DPH — co mapování rozhoduje', () => {
  const rez: BillableReservation[] = [{
    id: 'r1', start_at: '2026-08-04T16:00:00Z', end_at: '2026-08-04T17:30:00Z',
    sheet_name: 'Dráha 1', event_title: 'Trénink', hodiny: 1.5, sazba: 1000, castka: 1500,
  }];
  const SUBJ = { id: 'k1', name: 'SK Curling', ico: '26512345', dic: 'CZ26512345', address: 'Ostrava' };

  describe('u NEPLÁTCE se DPH nikam nepřimíchá', () => {
    const klub = mapujKlubMesicne({ subjekt: SUBJ, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: rez })!;
    const akce = mapujKomercniAkci({ eventId: 'e1', subjekt: SUBJ, jePlatceDph: false, rezervace: rez })!;

    it('řádek nemá sazbu — a je to `undefined`, ne nula', () => {
      // Nula znamená „osvobozeno", což je jiný daňový režim než „neplátce"
      // a doklad by to popsal špatně.
      expect(klub.lines[0].vatRate).toBeUndefined();
      expect('vatRate' in klub.lines[0]).toBe(false);
      expect(akce.lines[0].vatRate).toBeUndefined();
    });

    it('doklad neříká, jestli jsou ceny s daní — u neplátce ta otázka nedává smysl', () => {
      expect(klub.pricesIncludeVat).toBeUndefined();
      expect(akce.pricesIncludeVat).toBeUndefined();
    });

    it('a DIČ odběratele se nepošle, i když ho subjekt má', () => {
      expect(klub.party.vatNo).toBeUndefined();
    });
  });

  describe('u PLÁTCE nese led sníženou sazbu 12 %', () => {
    const klub = mapujKlubMesicne({ subjekt: SUBJ, obdobiOd: '2026-08-01', jePlatceDph: true, rezervace: rez })!;
    const akce = mapujKomercniAkci({ eventId: 'e1', subjekt: SUBJ, jePlatceDph: true, rezervace: rez })!;

    it('sazba je 12 (procent, ne koeficient) na obou typech dokladu', () => {
      // ⚠️ TOHLE ČÍSLO ŽIJE NA DVOU MÍSTECH. Druhé je
      // `billing_settings.vat_rate_ice` v databázi — potřebuje ho „Kdo kolik
      // dluží", protože `src/` si `billing/` importovat nesmí (hranice.test.ts).
      // Protějšek tohohle tvrzení je v `supabase/tests/billing_settings_test.sql`;
      // změnit jedno bez druhého nejde tiše, jeden z těch dvou testů zčervená.
      expect(SAZBA_DPH_LED).toBe(12);
      expect(klub.lines[0].vatRate).toBe(12);
      expect(akce.lines[0].vatRate).toBe(12);
    });

    it('KLUBOVÝ doklad má ceny VČETNĚ daně', () => {
      expect(klub.pricesIncludeVat).toBe(true);
    });

    it('KOMERČNÍ doklad má ceny BEZ daně', () => {
      // Tohle je jediné místo, kde se oba typy rozcházejí v tom, co `unitPrice`
      // znamená. Sazba je u obou táž — kdyby se to spletlo, klub by dostal
      // fakturu o 12 % vyšší, než jakou mu hala slíbila.
      expect(akce.pricesIncludeVat).toBe(false);
    });

    it('DIČ odběratele se pošle, když ho subjekt má', () => {
      expect(klub.party.vatNo).toBe('CZ26512345');
    });

    it('… a nepošle, když ho nemá — spolek bez registrace k DPH je běžný případ', () => {
      const bezDic = mapujKlubMesicne({
        subjekt: { ...SUBJ, dic: null }, obdobiOd: '2026-08-01', jePlatceDph: true, rezervace: rez,
      })!;
      expect(bezDic.party.vatNo).toBeUndefined();
    });
  });

  describe('součet řádků a co znamená pod DPH', () => {
    it('sčítá to, co je NA ŘÁDCÍCH — u klubu tedy částku s daní', () => {
      const klub = mapujKlubMesicne({ subjekt: SUBJ, obdobiOd: '2026-08-01', jePlatceDph: true, rezervace: rez })!;
      expect(soucetRadku(klub.lines)).toBe(1500);
    });

    it('… a u komerčky ZÁKLAD bez daně, při TÉŽE sazbě za hodinu', () => {
      const akce = mapujKomercniAkci({ eventId: 'e1', subjekt: SUBJ, jePlatceDph: true, rezervace: rez })!;
      expect(soucetRadku(akce.lines)).toBe(1500);
    });

    it('zapnutí DPH NEMĚNÍ částku na řádku — mění jen její výklad', () => {
      // Pojistka proti implementaci, která by při přepnutí na plátce začala
      // sama něco přepočítávat. Sazba za hodinu je snapshot z rezervace
      // a mapování ji nesmí sáhnout ani o haléř.
      const neplatce = mapujKlubMesicne({ subjekt: SUBJ, obdobiOd: '2026-08-01', jePlatceDph: false, rezervace: rez })!;
      const platce = mapujKlubMesicne({ subjekt: SUBJ, obdobiOd: '2026-08-01', jePlatceDph: true, rezervace: rez })!;
      expect(platce.lines[0].unitPrice).toBe(neplatce.lines[0].unitPrice);
      expect(soucetRadku(platce.lines)).toBe(soucetRadku(neplatce.lines));
    });
  });
});

// =============================================================================
// PÁSMOVÝ CENÍK — ŘÁDKY DOKLADU
//
// Rezervace přes hranici pásma se NEDĚLÍ (rozhodnutí PM), ale na dokladu musí
// mít řádek na každou sazbu. Jinak by 3 h přes dvě pásma zněly „3 × 1 133,33"
// = 3 399,99 Kč — haléř vedle přesné částky 3 400, a to na každé takové faktuře.
// =============================================================================
describe('pásmový ceník na dokladu', () => {
  const preseDvePasma: BillableReservation = {
    id: 'p1', start_at: '2026-09-02T14:00:00Z', end_at: '2026-09-02T17:00:00Z',
    sheet_name: 'Dráha 1', event_title: 'Trénink', hodiny: 3, sazba: 1133.33, castka: 3400,
    cenove_pasma: [{ sazba: 1000, hodin: 1 }, { sazba: 1200, hodin: 2 }],
  };
  const SUBJ = { id: 'k1', name: 'SK Curling', ico: '26512345', dic: null, address: 'Ostrava' };
  const draft = (r: BillableReservation) => mapujKlubMesicne({
    subjekt: SUBJ, obdobiOd: '2026-09-01', jePlatceDph: true, rezervace: [r],
  })!;

  it('rezervace přes dvě pásma dá DVA řádky', () => {
    expect(draft(preseDvePasma).lines).toHaveLength(2);
  });

  it('a jejich součet je PŘESNĚ částka z rezervace, ne o haléř vedle', () => {
    // Tohle je celý důvod, proč se řádky rozepisují.
    expect(soucetRadku(draft(preseDvePasma).lines)).toBe(3400);
    // A takhle by to dopadlo bez rozpisu: 3 × 1 133,33 = 3 399,99, tedy o haléř
    // míň. Porovnává se v HALÉŘÍCH, ne v korunách — `roundCzk` by ten rozdíl
    // zaokrouhlil zpátky na 3 400 a test by neukazoval nic.
    expect(toSetiny(3 * 1133.33)).toBe(339999);
    expect(toSetiny(3400)).toBe(340000);
  });

  it('řádky nesou sazbu v popisu, ať nejsou dva stejné texty s jinou cenou', () => {
    const l = draft(preseDvePasma).lines;
    expect(l[0].name).toContain('1 000 Kč/h');
    expect(l[1].name).toContain('1 200 Kč/h');
    expect(l[0].unitPrice).toBe(1000);
    expect(l[1].unitPrice).toBe(1200);
    expect(l[0].quantity).toBe(1);
    expect(l[1].quantity).toBe(2);
  });

  it('každý řádek nese sazbu DPH', () => {
    expect(draft(preseDvePasma).lines.every((l) => l.vatRate === SAZBA_DPH_LED)).toBe(true);
  });

  it('JEDNO pásmo = jeden řádek a popis se nešpiní sazbou', () => {
    const jedno: BillableReservation = {
      ...preseDvePasma, id: 'p2', hodiny: 2, sazba: 1200, castka: 2400,
      cenove_pasma: [{ sazba: 1200, hodin: 2 }],
    };
    const l = draft(jedno).lines;
    expect(l).toHaveLength(1);
    expect(l[0].name).not.toContain('Kč/h');
    expect(soucetRadku(l)).toBe(2400);
  });

  it('bez rozpisu se nic nemění — komerční sazba jede jako dřív', () => {
    const bez: BillableReservation = {
      ...preseDvePasma, id: 'p3', hodiny: 2, sazba: 5000, castka: 10000, cenove_pasma: null,
    };
    const l = draft(bez).lines;
    expect(l).toHaveLength(1);
    expect(l[0].unitPrice).toBe(5000);
    expect(soucetRadku(l)).toBe(10000);
  });

  // ---------------------------------------------------------------------------
  // ZÁBRADLÍ. Rozpis chodí z databáze, takže „nemůže přijít rozbitý" platí jen
  // do první migrace, která to pokazí. Když nesedí, musí doklad SPADNOUT —
  // vystavit ho a rozejít se s „Kdo kolik dluží" je to horší z obou selhání.
  // ---------------------------------------------------------------------------
  it('rozpis, který nesedí na částku, doklad ZASTAVÍ', () => {
    const rozbity: BillableReservation = {
      ...preseDvePasma, cenove_pasma: [{ sazba: 1000, hodin: 1 }, { sazba: 1200, hodin: 1 }],
    };
    expect(() => draft(rozbity)).toThrow(BillingValidationError);
    expect(() => draft(rozbity)).toThrow(/nesedí na rozpis/);
  });

  it('rozpis, který nepokrývá všechny hodiny, doklad ZASTAVÍ', () => {
    // Součet sedí na 3 400, ale pokrývá jen 2 h ze 3 — hodina by se
    // nevyfakturovala a nikdo by si toho na dokladu nevšiml.
    const chybiHodina: BillableReservation = {
      ...preseDvePasma, cenove_pasma: [{ sazba: 1700, hodin: 2 }],
    };
    expect(() => draft(chybiHodina)).toThrow(/pokrývá 2 h, ale rezervace má 3 h/);
  });

  it('nepoužitelná položka v rozpisu doklad ZASTAVÍ', () => {
    for (const spatna of [{ sazba: 1000, hodin: 0 }, { sazba: -1000, hodin: 3 }]) {
      expect(() => draft({ ...preseDvePasma, cenove_pasma: [spatna] }))
        .toThrow(BillingValidationError);
    }
  });

  it('rozpis se promítne i do počtu řádků celého dokladu', () => {
    // Dvě rezervace, jedna přes dvě pásma → tři řádky. Kvůli tomuhle musel
    // povolit `fakturoid_radku_sedi` víc řádků než rezervací.
    const druha: BillableReservation = {
      ...preseDvePasma, id: 'p4', start_at: '2026-09-09T14:00:00Z', end_at: '2026-09-09T16:00:00Z',
      hodiny: 2, sazba: 1000, castka: 2000, cenove_pasma: [{ sazba: 1000, hodin: 2 }],
    };
    const d = mapujKlubMesicne({
      subjekt: SUBJ, obdobiOd: '2026-09-01', jePlatceDph: true,
      rezervace: [preseDvePasma, druha],
    })!;
    expect(d.lines).toHaveLength(3);
    expect(d.sourceReservationIds).toHaveLength(2);
    expect(soucetRadku(d.lines)).toBe(5400);
  });
});
