import { describe, expect, it } from 'vitest';
import { sestavDoklad } from './invoicePrint';
import type { Invoice, InvoiceItem } from '@/hooks/useInvoices';

// Doklad je to, co jde ven ke klientovi. Testuje se hlavně to, co by na něm bylo
// nebezpečné: výzva k platbě u dokladu, který je už zaplacený, a QR platba.

const doklad = (prepis: Partial<Invoice> = {}): Invoice => ({
  id: 'aaaa1111-0000-0000-0000-000000000001',
  cislo: '20260001',
  variabilni_symbol: '20260001',
  kind: 'klub',
  status: 'vystaveno',
  subject_id: 'bbbb2222-0000-0000-0000-000000000001',
  event_id: null,
  obdobi_od: '2026-08-01',
  obdobi_do: '2026-08-31',
  datum_vystaveni: '2026-08-14',
  datum_splatnosti: '2026-08-28',
  datum_uhrady: null,
  paid_at: null,
  paid_by: null,
  subtotal: 3400,
  total: 3400,
  total_rounded: 3400,
  rounding_amount: 0,
  dodavatel_nazev: 'Curling Promo Ostrava z.s.',
  dodavatel_adresa: 'Ledová 1, 700 30 Ostrava',
  dodavatel_ico: '12345678',
  dodavatel_dic: null,
  dodavatel_rejstrik: null,
  dodavatel_ucet: '19-2000145399/0800',
  dodavatel_iban: 'CZ6508000000192000145399',
  dodavatel_zprava: 'Pronájem ledu',
  vat_mode: 'neplatce',
  odberatel_nazev: 'CK Ostravské kameny',
  odberatel_adresa: 'Kamenná 12, Ostrava',
  odberatel_ico: null,
  odberatel_dic: null,
  pdf_path: null,
  pdf_sha256: null,
  created_at: '2026-08-14T08:00:00+02:00',
  created_by: null,
  updated_at: '2026-08-14T08:00:00+02:00',
  updated_by: null,
  issued_at: '2026-08-14T08:00:00+02:00',
  issued_by: null,
  ...prepis,
} as Invoice);

const polozky: InvoiceItem[] = [{
  id: 'cccc3333-0000-0000-0000-000000000001',
  invoice_id: 'aaaa1111-0000-0000-0000-000000000001',
  reservation_id: null,
  popis: 'Pronájem ledové plochy — Dráha 1',
  datum: '2026-08-04',
  cas_od: '2026-08-04T08:00:00+02:00',
  cas_do: '2026-08-04T10:00:00+02:00',
  hodiny: 2,
  sazba: 1700,
  line_total: 3400,
  vat_rate: null,
  vat_base: null,
  vat_amount: null,
  poradi: 1,
  created_at: '2026-08-14T08:00:00+02:00',
} as InvoiceItem];

describe('doklad — nezaplacený vyzývá k platbě', () => {
  it('má QR, částku k úhradě i platební údaje', () => {
    const html = sestavDoklad(doklad(), polozky);
    expect(html).toContain('<svg');
    expect(html).toContain('Celkem k úhradě');
    expect(html).toContain('19-2000145399/0800');
    expect(html).not.toContain('UHRAZENO dne');
  });
});

describe('doklad — zaplacený už k platbě NEVYZÝVÁ', () => {
  // Nejdůležitější tvrzení souboru. Admin označí fakturu zaplacenou podle výpisu,
  // klub si za měsíc řekne o kopii — a kdyby na ní byla částka „k úhradě" a
  // naskenovatelné QR, je to pozvánka k dvojí platbě.
  const zaplaceny = doklad({ status: 'zaplaceno', datum_uhrady: '2026-08-20' });

  it('nevykreslí QR platbu', () => {
    expect(sestavDoklad(zaplaceny, polozky)).not.toContain('<svg');
  });

  it('nese razítko s datem úhrady a výslovné „neplaťte znovu"', () => {
    const html = sestavDoklad(zaplaceny, polozky);
    expect(html).toContain('UHRAZENO dne');
    expect(html).toContain('20. 8. 2026');
    expect(html).toContain('neplaťte znovu');
  });

  it('částku pojmenuje jako uhrazenou, ne jako „k úhradě"', () => {
    const html = sestavDoklad(zaplaceny, polozky);
    expect(html).toContain('Celkem (uhrazeno)');
    expect(html).not.toContain('Celkem k úhradě');
  });

  it('platební údaje zůstanou, ale označené jako doklad uhrazený', () => {
    // Číslo účtu na dokladu být má (je to náležitost), jen už není výzvou.
    const html = sestavDoklad(zaplaceny, polozky);
    expect(html).toContain('19-2000145399/0800');
    expect(html).toContain('doklad je uhrazený');
  });

  it('datum úhrady čte jako místní den, ne jako UTC půlnoc', () => {
    const html = sestavDoklad(doklad({ status: 'zaplaceno', datum_uhrady: '2026-08-01' }), polozky);
    expect(html).toContain('1. 8. 2026');
  });
});

describe('doklad — neplátce DPH', () => {
  it('tiskne doložku, ale nevyčísluje daň', () => {
    const html = sestavDoklad(doklad(), polozky);
    expect(html).toContain('Nejsme plátci DPH.');
    expect(html).not.toMatch(/Sazba DPH|Základ daně|DPH 21/);
  });
});

describe('opravný doklad', () => {
  // Rozhodnutí PM: u neplátce se to jmenuje „Opravný doklad", ne „dobropis".
  // Doklad nese KLADNÉ částky jako originál (schéma záporný nepustí), takže
  // nadpis a věta o tom, co ruší, jsou jediné, co ho odlišuje od druhé výzvy
  // k zaplacení téže částky.
  const opravny = (prepis: Partial<Invoice> = {}) => doklad({
    cislo: '20260002',
    opravuje_id: 'aaaa1111-0000-0000-0000-000000000001',
    opravuje_cislo: '20260001',
    storno_duvod: 'Klub akci odvolal.',
    ...prepis,
  });

  it('má nadpis „Opravný doklad", ne „Faktura"', () => {
    const html = sestavDoklad(opravny(), polozky);
    expect(html).toContain('<h1>Opravný doklad</h1>');
    expect(html).not.toContain('<h1>Faktura</h1>');
  });

  it('řekne, kterou fakturu ruší a proč', () => {
    const html = sestavDoklad(opravny(), polozky);
    expect(html).toContain('Ruší fakturu č. 20260001');
    expect(html).toContain('Klub akci odvolal.');
  });

  it('NEMÁ QR platbu — opravným dokladem se nic neplatí', () => {
    // Tohle je ta nebezpečná část: QR na opravném dokladu je pozvánka zaplatit
    // podruhé částku, která se právě ruší.
    expect(sestavDoklad(opravny(), polozky)).not.toContain('<svg');
    // Kontrola kontroly: běžná faktura se stejnými údaji QR MÁ, takže se
    // netvrdí „bez QR" o dokladu, který by ho nedostal tak jako tak.
    expect(sestavDoklad(doklad(), polozky)).toContain('<svg');
  });

  it('součet nepopisuje jako „k úhradě"', () => {
    const html = sestavDoklad(opravny(), polozky);
    expect(html).toContain('Celkem (rušená částka)');
    expect(html).not.toContain('Celkem k úhradě');
  });

  it('když se číslo rušené faktury nedotáhne, vytiskne pomlčku místo „undefined"', () => {
    const html = sestavDoklad(opravny({ opravuje_cislo: null }), polozky);
    expect(html).toContain('Ruší fakturu č. —');
    expect(html).not.toContain('undefined');
  });
});
