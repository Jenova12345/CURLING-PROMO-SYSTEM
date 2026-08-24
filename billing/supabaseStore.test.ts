import { describe, expect, it } from 'vitest';

import { SupabaseStore, type RpcKlient } from './supabaseStore.ts';
import { BillingProviderError } from './errors.ts';
import { mapujKlubMesicne, type BillableReservation } from './mapping.ts';

const KLUB = {
  id: 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
  name: 'SK Curling Ostrava', ico: '26512345', dic: null,
  address: 'Sportovní 12, 702 00 Ostrava',
};

const rezervace: BillableReservation[] = [
  { id: 'a', start_at: '2026-08-04T16:00:00Z', end_at: '2026-08-04T17:00:00Z', sheet_name: 'Dráha 1', event_title: 'Trénink', hodiny: 1, sazba: 1200, castka: 1200 },
  { id: 'b', start_at: '2026-08-11T16:00:00Z', end_at: '2026-08-11T17:00:00Z', sheet_name: 'Dráha 1', event_title: 'Trénink', hodiny: 1, sazba: 1200, castka: 1200 },
];

const draft = () => mapujKlubMesicne({
  subjekt: KLUB, obdobiOd: '2026-08-01', obdobiDo: '2026-08-31', jePlatceDph: false, rezervace,
})!;

/** Falešný klient — zaznamená volání a vrátí, co mu řekneme. */
const fakeDb = (odpovedi: Record<string, unknown>, chyba?: string) => {
  const volani: Array<{ nazev: string; args?: Record<string, unknown> }> = [];
  const db: RpcKlient = {
    rpc: async (nazev, args) => {
      volani.push({ nazev, args });
      if (chyba) return { data: null, error: { message: chyba } };
      return { data: odpovedi[nazev] ?? null, error: null };
    },
  };
  return { db, volani };
};

describe('zámek 1 — ptá se VÝHRADNĚ na fakturoidí vazbu', () => {
  // Pod S2 může mít rezervace interní `invoice_id` a STEJNĚ má jít do Fakturoidu.
  // Kdyby se tenhle dotaz ptal na reservations.invoice_id, nevyfakturovala by se
  // ani jedna rezervace, která už prošla interním enginem.
  it('volá fakturoid_je_vyfakturovana, ne nic nad reservations', async () => {
    const { db, volani } = fakeDb({ fakturoid_je_vyfakturovana: true });
    expect(await new SupabaseStore(db).jeVyfakturovana('r1')).toBe(true);
    expect(volani).toEqual([{ nazev: 'fakturoid_je_vyfakturovana', args: { _reservation: 'r1' } }]);
  });

  it('nic jiného než true neznamená vyfakturováno', async () => {
    const { db } = fakeDb({ fakturoid_je_vyfakturovana: null });
    expect(await new SupabaseStore(db).jeVyfakturovana('r1')).toBe(false);
  });
});

describe('zámek 3 — claim', () => {
  it('pošle celý kontext dokladu jedním voláním', async () => {
    const { db, volani } = fakeDb({ fakturoid_zkus_zabrat: true });
    const d = draft();

    expect(await new SupabaseStore(db).zkusZabrat(d, { nasSoucet: 2400, rezim: 'koncept' })).toBe(true);
    expect(volani[0].args).toEqual({
      _klic: `klub-${KLUB.id}-202608`,
      _druh: 'club_monthly',
      _subject: KLUB.id,
      _event: null,
      _od: '2026-08-01',
      _do: '2026-08-31',
      _nas_soucet: 2400,
      _radku: 2,
      _rezim: 'koncept',
      _rezervace: ['a', 'b'],
    });
  });

  it('false znamená „zabral někdo jiný“, ne chybu', async () => {
    const { db } = fakeDb({ fakturoid_zkus_zabrat: false });
    expect(await new SupabaseStore(db).zkusZabrat(draft(), { nasSoucet: 2400, rezim: 'koncept' })).toBe(false);
  });

  it('uvolnění nese důvod, ať je v evidenci vidět proč', async () => {
    const { db, volani } = fakeDb({ fakturoid_uvolni_zabrani: true });
    await new SupabaseStore(db).uvolniZabrani('klub-x-202608');
    expect(String(volani[0].args?._duvod)).toMatch(/nevíme/);
  });
});

describe('čtení vazby', () => {
  const radek = {
    idempotency_key: 'klub-x-202608',
    provider_invoice_id: '555',
    provider_subject_id: '42',
    cislo: '20260012',
    variabilni_symbol: '20260012',
    public_url: 'https://app.fakturoid.cz/x/555',
    status: 'open',
    provider_total: '2400.00',
    pdf_path: null,
    rezim: 'koncept',
    odeslano_at: null,
    rezervace: ['a', 'b'],
    varovani: null,
  };

  it('převede řádek na InvoiceLink a částku ze řetězce na číslo', async () => {
    const { db } = fakeDb({ fakturoid_najdi_podle_klice: [radek] });
    const v = await new SupabaseStore(db).najdiPodleKlice('klub-x-202608');

    expect(v?.result.providerInvoiceId).toBe('555');
    expect(v?.result.providerTotal).toBe(2400);
    expect(v?.reservationIds).toEqual(['a', 'b']);
    expect(v?.pdfPath).toBeUndefined();
  });

  // Uložená kopie řádků by mohla zestárnout a kontrola shody by pak porovnávala
  // náš starý zápis místo toho, co doklad u providera opravdu má.
  it('NEdrží providerLines — ty musí přijít čerstvé od providera', async () => {
    const { db } = fakeDb({ fakturoid_najdi_podle_klice: [radek] });
    const v = await new SupabaseStore(db).najdiPodleKlice('klub-x-202608');
    expect(v?.result.providerLines).toBeUndefined();
  });

  it('prázdný výsledek je null', async () => {
    const { db } = fakeDb({ fakturoid_najdi_podle_klice: [] });
    expect(await new SupabaseStore(db).najdiPodleKlice('klub-x-202608')).toBeNull();
  });
});

describe('zápis vazby', () => {
  const VYSLEDEK = {
    providerInvoiceId: '555', number: '20260012', variableSymbol: '20260012',
    status: 'open', providerTotal: 2400,
  };
  const META = { nasSoucet: 2400, rezim: 'koncept', providerSubjectId: '42' };

  it('posílá odpověď providera I kontext dokladu', async () => {
    const { db, volani } = fakeDb({ fakturoid_zapis_vazbu: true });
    await new SupabaseStore(db).zapisVazbu(draft(), VYSLEDEK, META);

    const a = volani[0].args!;
    expect(a._cislo).toBe('20260012');
    expect(a._provider_subject_id).toBe('42');
    // Kontext je pro větev „zápis nálezu": tam se řádek zakládá od začátku,
    // protože žádný claim už neexistuje (předchozí běh ho po selhaném POSTu
    // správně uvolnil) — a bez `_rezervace` by po zotavení zůstal zámek 1 mrtvý.
    expect(a._druh).toBe('club_monthly');
    expect(a._subject).toBe(KLUB.id);
    expect(a._rezervace).toEqual(['a', 'b']);
    expect(a._nas_soucet).toBe(2400);
  });

  it('rozpor kontrolního součtu se ukládá DO EVIDENCE, ne jen do odpovědi', async () => {
    // Bez tohohle by „KONTROLNÍ SOUČET NESEDÍ" existoval jen v HTTP odpovědi —
    // admin zavře záložku a je pryč.
    const { db, volani } = fakeDb({ fakturoid_zapis_vazbu: true });
    await new SupabaseStore(db).zapisVazbu(draft(), VYSLEDEK, {
      ...META, varovani: 'KONTROLNÍ SOUČET NESEDÍ: …',
    });
    expect(volani[0].args?._varovani).toMatch(/NESEDÍ/);
  });

  // Doklad u providera v tu chvíli EXISTUJE. Kdyby se nezapsání přešlo mlčky,
  // nikdo by o něm nevěděl a příští běh by vystavil druhý.
  it('nezapsaná vazba je HLASITÁ chyba, ne tiché pokrčení rameny', async () => {
    const { db } = fakeDb({ fakturoid_zapis_vazbu: false });
    await expect(new SupabaseStore(db).zapisVazbu(draft(), VYSLEDEK, META))
      .rejects.toThrow(/nešlo ho zapsat do evidence/);
  });
});

describe('zápis PDF', () => {
  it('bez otisku pošle null — RPC ho pak coalescem NEPŘEPÍŠE', async () => {
    const { db, volani } = fakeDb({ fakturoid_zapis_pdf: true });
    await new SupabaseStore(db).zapisPdf('klub-x-202608', 'fakturoid/x.pdf');
    expect(volani[0].args?._sha).toBeNull();
  });

  it('s otiskem ho pošle', async () => {
    const { db, volani } = fakeDb({ fakturoid_zapis_pdf: true });
    await new SupabaseStore(db).zapisPdf('klub-x-202608', 'fakturoid/x.pdf', 'abc123');
    expect(volani[0].args?._sha).toBe('abc123');
  });
});

describe('označení odeslaného', () => {
  it('false znamená „už odeslaný“ — e-mail se podruhé neposílá', async () => {
    const { db } = fakeDb({ fakturoid_oznac_odeslano: false });
    expect(await new SupabaseStore(db).oznacOdeslano('klub-x-202608')).toBe(false);
  });
});

describe('chyba z databáze', () => {
  it('skončí BillingProviderError, ne nečitelným pádem', async () => {
    const { db } = fakeDb({}, 'permission denied for function fakturoid_zkus_zabrat');
    await expect(new SupabaseStore(db).jeVyfakturovana('r1'))
      .rejects.toBeInstanceOf(BillingProviderError);
  });
});
