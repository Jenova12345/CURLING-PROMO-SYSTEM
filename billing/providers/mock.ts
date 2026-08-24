// Paměťový provider — pro unit testy a pro vývoj bez klíčů.
//
// Chová se jako Fakturoid v tom, na čem záleží: přiděluje si číslo a variabilní
// symbol sám (my je NEPOSÍLÁME), páruje odběratele podle `custom_id` a PDF vrací
// až po pár dotazech, aby se dala vyzkoušet smyčka kolem 204.
//
// NENÍ to simulátor Fakturoidu. Nekontroluje tvar JSONu ani limity a nikdy nebude —
// od toho jsou integrační testy proti testovacímu účtu (`FAKTUROID_LIVE=true`).
// Co ověřuje mock, je NAŠE rozhodovací logika.

import { roundCzk } from '../../src/lib/money.ts';
import { soucetRadku } from '../mapping.ts';
import type {
  InvoiceDraft, InvoiceParty, InvoiceProvider, InvoiceResult,
} from '../types.ts';

export interface MockVolby {
  /** Kolikrát po sobě vrátí `downloadPdf` null (tedy „204 — ještě se generuje"). */
  pdfNeniKrat?: number;
  /** Rok v čísle dokladu. Fixní, ať jsou testy deterministické. */
  rok?: number;
}

export class MockProvider implements InvoiceProvider {
  /** Doklady podle `custom_id` (= náš klíč idempotence). */
  readonly doklady = new Map<string, InvoiceResult>();
  /** Odběratelé podle `custom_id` (= `subj-{ourSubjectId}`). */
  readonly subjekty = new Map<string, InvoiceParty>();

  /** Počítadla volání — testy podle nich poznají, že se něco NEstalo. */
  volani = { ensureSubject: 0, findExistingInvoice: 0, createInvoice: 0, downloadPdf: 0 };

  private poradi = 0;
  private pdfDotazy = new Map<string, number>();

  constructor(private volby: MockVolby = {}) {}

  async ensureSubject(party: InvoiceParty): Promise<{ providerSubjectId: string }> {
    this.volani.ensureSubject++;
    const customId = `subj-${party.ourSubjectId}`;
    if (!this.subjekty.has(customId)) this.subjekty.set(customId, party);
    return { providerSubjectId: customId };
  }

  async findExistingInvoice(idempotencyKey: string): Promise<InvoiceResult | null> {
    this.volani.findExistingInvoice++;
    return this.doklady.get(idempotencyKey) ?? null;
  }

  async createInvoice(draft: InvoiceDraft, providerSubjectId: string): Promise<InvoiceResult> {
    this.volani.createInvoice++;

    // Provider si číslo přiděluje SÁM — kdyby ho draft nesl, byla by to chyba u nás.
    const rok = this.volby.rok ?? 2026;
    const cislo = `${rok}${String(++this.poradi).padStart(4, '0')}`;

    const vysledek: InvoiceResult = {
      providerInvoiceId: `mock-${cislo}`,
      number: cislo,
      variableSymbol: cislo,
      publicUrl: `https://mock.invalid/${providerSubjectId}/${cislo}`,
      status: 'open',
      // Skutečný Fakturoid celkovou částku vrací a jádro se na ni spoléhá
      // (větev „nesedi" v pipeline). Mock, který ji neposílá, by tu větev
      // spouštěl pořád a vypadalo by to jako chyba v jádře.
      providerTotal: roundCzk(soucetRadku(draft.lines)),
      // Skutečný Fakturoid řádky vrací a jádro je porovnává — bez nich by se
      // testovala jen slabší varianta kontroly (podle částky).
      providerLines: draft.lines.map((l) => ({ ...l })),
    };
    this.doklady.set(draft.idempotencyKey, vysledek);
    return vysledek;
  }

  async downloadPdf(providerInvoiceId: string): Promise<Uint8Array | null> {
    this.volani.downloadPdf++;
    const dosud = this.pdfDotazy.get(providerInvoiceId) ?? 0;
    this.pdfDotazy.set(providerInvoiceId, dosud + 1);
    if (dosud < (this.volby.pdfNeniKrat ?? 0)) return null;   // ekvivalent HTTP 204
    return new TextEncoder().encode(`%PDF-1.4 mock ${providerInvoiceId}`);
  }
}
