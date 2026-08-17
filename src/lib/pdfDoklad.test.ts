import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  fmtDatum, fmtKc, qrSvgPath, renderInvoice,
  type DokladDTO, type DokladPolozka,
} from '../../supabase/functions/_shared/pdfDoklad';

// Renderer dokladu. Testuje se odsud (Node), i když běží v Edge funkci (Deno) —
// je to čistá funkce bez sítě a bez databáze právě proto, aby to šlo.
//
// NEJDŮLEŽITĚJŠÍ TVRZENÍ V SOUBORU je determinismus: z výstupu se počítá
// `pdf_sha256`, který se ukládá k dokladu jako důkaz o jeho obsahu. Kdyby se
// render lišil běh od běhu, otisk by přestal být důkazem a stal by se náhodným
// číslem — a nikdo by si toho nevšiml, protože PDF by pořád vypadalo správně.

const polozka = (p: Partial<DokladPolozka> = {}): DokladPolozka => ({
  popis: 'Pronájem ledu — Dráha 1',
  datum: '2026-08-03',
  hodiny: 2,
  sazba: 1400,
  line_total: 2800,
  vat_rate: null,
  vat_base: null,
  vat_amount: null,
  ...p,
});

const doklad = (p: Partial<DokladDTO> = {}): DokladDTO => ({
  cislo: '20260001',
  opravuje_cislo: null,
  storno_duvod: null,
  vat_mode: 'neplatce',
  datum_vystaveni: '2026-08-14',
  datum_splatnosti: '2026-08-28',
  datum_uhrady: null,
  obdobi_od: '2026-08-01',
  obdobi_do: '2026-08-31',
  variabilni_symbol: '20260001',
  dodavatel_nazev: 'Curling Promo Ostrava z.s.',
  dodavatel_adresa: 'Ledová 1, 700 30 Ostrava',
  dodavatel_ico: '12345678',
  dodavatel_dic: null,
  dodavatel_rejstrik: 'Spolkový rejstřík, KS Ostrava',
  dodavatel_ucet: '19-2000145399/0800',
  dodavatel_iban: 'CZ6508000000192000145399',
  dodavatel_zprava: 'Pronájem ledu',
  odberatel_nazev: 'CK Ostravské kameny',
  odberatel_adresa: 'Kamenná 12, Ostrava',
  odberatel_ico: null,
  odberatel_dic: null,
  polozky: [polozka(), polozka({ datum: '2026-08-10', line_total: 2800 })],
  subtotal: 5600,
  total: 5600,
  total_rounded: 5600,
  rounding_amount: 0,
  ...p,
});

const SPAYD = 'SPD*1.0*ACC:CZ6508000000192000145399*AM:5600.00*CC:CZK*X-VS:20260001';
const otisk = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');

describe('renderInvoice — determinismus', () => {
  it('dvakrát vyrenderovaný týž doklad má týž sha256', async () => {
    const a = await renderInvoice(doklad(), SPAYD);
    const b = await renderInvoice(doklad(), SPAYD);
    expect(otisk(a)).toBe(otisk(b));
    expect(a.byteLength).toBe(b.byteLength);
  }, 30_000);

  it('sha256 se změní, když se změní obsah (test kontroly)', async () => {
    // Bez tohohle by „shodný otisk" mohl znamenat i to, že se otisk nepočítá
    // z obsahu vůbec.
    const a = await renderInvoice(doklad(), SPAYD);
    const b = await renderInvoice(doklad({ total_rounded: 9999 }), SPAYD);
    expect(otisk(a)).not.toBe(otisk(b));
  }, 30_000);

  it('vznikne platné PDF', async () => {
    const bytes = await renderInvoice(doklad(), SPAYD);
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe('%PDF-');
    expect(bytes.byteLength).toBeGreaterThan(1000);
  }, 30_000);
});

describe('renderInvoice — větve DPH', () => {
  it('neplátci se doklad vysází a nespadne na chybějících sazbách', async () => {
    const bytes = await renderInvoice(doklad(), SPAYD);
    expect(bytes.byteLength).toBeGreaterThan(1000);
  }, 30_000);

  it('plátci se vysází položky s daní i rekapitulace', async () => {
    // Plátcovský režim zatím `issue_invoice` nepustí (čeká na Q7), takže tenhle
    // doklad je syntetický. Větev ale existovat musí — až se Q7 rozhodne,
    // nesmí se PDF dodělávat pod tlakem.
    const platce = doklad({
      vat_mode: 'platce',
      dodavatel_dic: 'CZ12345678',
      polozky: [
        polozka({ vat_rate: 21, vat_base: 2800, vat_amount: 588, line_total: 3388 }),
        polozka({ vat_rate: 12, vat_base: 1000, vat_amount: 120, line_total: 1120 }),
      ],
      subtotal: 3800, total: 4508, total_rounded: 4508, rounding_amount: 0,
    });
    const bytes = await renderInvoice(platce, SPAYD);
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe('%PDF-');
    // Plátcovský doklad je širší o sloupce daně, takže bývá větší než neplátcovský.
    expect(bytes.byteLength).toBeGreaterThan(1000);
  }, 30_000);

  it('plátcovská větev je deterministická taky', async () => {
    const platce = doklad({
      vat_mode: 'platce',
      polozky: [polozka({ vat_rate: 21, vat_base: 2800, vat_amount: 588, line_total: 3388 })],
    });
    const a = await renderInvoice(platce, SPAYD);
    const b = await renderInvoice(platce, SPAYD);
    expect(otisk(a)).toBe(otisk(b));
  }, 30_000);
});

describe('renderInvoice — co se na doklad nesmí dostat', () => {
  it('uhrazený doklad nemá QR (jinak je to výzva zaplatit podruhé)', async () => {
    const uhrazeny = doklad({ datum_uhrady: '2026-08-20' });
    const s = await renderInvoice(uhrazeny, SPAYD);
    const bez = await renderInvoice(uhrazeny, null);
    // Když se QR nekreslí, je jedno, jestli řetězec přišel — výstup je týž.
    expect(otisk(s)).toBe(otisk(bez));
  }, 30_000);

  it('opravný doklad nemá QR ani u nezaplaceného dokladu', async () => {
    const opravny = doklad({ opravuje_cislo: '20260001', cislo: '20260002', storno_duvod: 'Klub akci odvolal.' });
    const s = await renderInvoice(opravny, SPAYD);
    const bez = await renderInvoice(opravny, null);
    expect(otisk(s)).toBe(otisk(bez));
  }, 30_000);

  it('běžná nezaplacená faktura QR naopak MÁ (kontrola kontroly)', async () => {
    const s = await renderInvoice(doklad(), SPAYD);
    const bez = await renderInvoice(doklad(), null);
    expect(otisk(s)).not.toBe(otisk(bez));
  }, 30_000);
});

describe('formátování — vlastní, ať se nerozejde mezi Denem a Nodem', () => {
  it('částky mají nezlomitelné mezery a čárku', () => {
    expect(fmtKc(22600)).toBe('22 600 Kč');
    expect(fmtKc(1234.5)).toBe('1 234,50 Kč');
    expect(fmtKc(0)).toBe('0 Kč');
  });

  it('záporná částka se pozná (dobropis, zaokrouhlení dolů)', () => {
    expect(fmtKc(-0.4)).toBe('−0,40 Kč');
  });

  it('datum je české a bez nul na začátku', () => {
    expect(fmtDatum('2026-08-03')).toBe('3. 8. 2026');
    expect(fmtDatum(null)).toBe('—');
  });
});

describe('QR jako SVG path', () => {
  it('vyrobí neprázdný path se čtverci', () => {
    const { path } = qrSvgPath(SPAYD, 92);
    expect(path.startsWith('M ')).toBe(true);
    expect(path).toContain('Z');
    expect(path.length).toBeGreaterThan(500);
  });

  it('je deterministický — týž vstup, týž path', () => {
    expect(qrSvgPath(SPAYD, 92).path).toBe(qrSvgPath(SPAYD, 92).path);
  });

  it('jiná data dají jiný kód', () => {
    expect(qrSvgPath(SPAYD, 92).path).not.toBe(qrSvgPath(SPAYD + '*X-KS:0308', 92).path);
  });
});
