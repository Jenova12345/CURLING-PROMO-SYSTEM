// Port pro vazbu „naše rezervace ↔ doklad u providera".
//
// PROČ PORT A NE ROVNOU SUPABASE: kam se ta vazba zapíše, závisí na dosud
// nepotvrzeném rozhodnutí D1 (S1 = Fakturoid jako výstupní kanál / S2 = Fakturoid
// jako jediný doklad / S3 = přepínač). `reservations.invoice_id` je cizí klíč na
// naše `public.invoices` a chrání ho guard (`app.trusted_booking`), takže tam
// Fakturoidí doklad prostě nepatří — a vymyslet si schéma dopředu by znamenalo
// zafixovat D1 mimo pořadí. Port to odděluje: jádro i testy jsou hotové a zelené,
// a doplnit zbývá jen implementaci nad databází (PR 4, až bude S1 potvrzené).
//
// ⚠️ JEDINÉ MÍSTO, KDE SE D1 PROJEVÍ, je význam `jeVyfakturovana`:
//   • S1 — naše doklady zůstávají zdroj pravdy a Fakturoid dostává kopii, takže
//     „už má `reservations.invoice_id`" NEZNAMENÁ „nemá jít do Fakturoidu".
//     Odpověď se musí ptát na vazbu k PROVIDEROVI, ne na interní doklad.
//   • S2 — interní a providerská vazba splývají, ptát se dá na obojí.
// Paměťová implementace níž odpovídá „tahle fakturační cesta už to poslala",
// což je pravda ve všech třech variantách — proto na D1 nesahá.

import type { InvoiceDraft, InvoiceResult } from './types.ts';

/** Zapsaná vazba jednoho dokladu. */
export interface InvoiceLink {
  idempotencyKey: string;
  reservationIds: string[];
  result: InvoiceResult;
  /** Kde v našem úložišti leží kopie PDF. Doplní se, až se PDF podaří stáhnout. */
  pdfPath?: string;
  /** Kdy se doklad odeslal odběrateli. `undefined` = neodeslaný. */
  odeslanoAt?: string;
  /** Uložený rozpor kontrolního součtu. */
  varovani?: string;
}

/** Co si evidence potřebuje zapsat v okamžiku claimu, kromě samotného draftu. */
export interface ClaimMeta {
  /** Náš součet zaokrouhlený na koruny — druhá strana kontrolního součtu. */
  nasSoucet: number;
  /** `koncept` | `odeslat` — v jakém režimu se doklad zakládá. */
  rezim: string;
}

/** Co se zapisuje spolu s odpovědí providera. */
export interface ZapisMeta extends ClaimMeta {
  providerSubjectId?: string;
  /** Rozpor kontrolního součtu. Ukládá se, aby nezůstal jen v HTTP odpovědi. */
  varovani?: string;
}

export interface InvoiceLinkStore {
  /** ZÁMEK 1 — nese už tahle rezervace doklad? */
  jeVyfakturovana(reservationId: string): Promise<boolean>;

  /**
   * ZÁMEK 3 — atomický claim před vystavením. `true` = zabráno námi.
   *
   * PROČ NESTAČÍ ZÁMKY 1 A 2: oba jsou jen ČTENÍ. Když cron (`billing_runs`)
   * běží ve stejnou vteřinu, kdy admin klikne „faktura na klik", projdou oba
   * běhy zámkem 1 i 2 (v tu chvíli opravdu nic neexistuje) a oba zavolají
   * `createInvoice`. `custom_id` u Fakturoidu není unikátní klíč, takže vzniknou
   * DVA doklady a klient dostane dvakrát poštu za totéž.
   *
   * Implementace nad databází to musí udělat jedním atomickým příkazem —
   * ne „SELECT, a když nic, tak INSERT". Vzor je v repu:
   * `UPDATE … WHERE invoice_id IS NULL RETURNING` v `create_invoice_draft_club`.
   */
  zkusZabrat(draft: InvoiceDraft, meta: ClaimMeta): Promise<boolean>;

  /**
   * Uvolní claim, když vystavení selhalo.
   *
   * Po selhaném POSTu NEVÍME, jestli doklad vznikl — proto se claim pouští
   * a rozhodnutí se nechá na příštím běhu, kde ho zámek 2 buď najde
   * (`findExistingInvoice`), nebo ne. Držet claim navždy by zablokovalo
   * fakturaci toho klubu, dokud by nepřišel člověk.
   */
  uvolniZabrani(idempotencyKey: string): Promise<void>;
  /** Lokální odpověď na klíč idempotence. Nenahrazuje dotaz k providerovi, předchází mu. */
  najdiPodleKlice(idempotencyKey: string): Promise<InvoiceLink | null>;
  /**
   * Zápis po vytvoření NEBO nalezení dokladu.
   *
   * Bere celý `draft`, ne jen hotovou vazbu, protože musí umět DVA stavy:
   * dorovnat živý claim (běžná cesta) a zapsat NÁLEZ, u kterého už žádný claim
   * neexistuje (zotavení po ztracené odpovědi — claim se tehdy správně uvolnil).
   * Ve druhém případě je potřeba celý kontext dokladu, protože se zakládá řádek
   * od začátku i s vazbami na rezervace.
   */
  zapisVazbu(draft: InvoiceDraft, result: InvoiceResult, meta: ZapisMeta): Promise<void>;
  /** Doplnění cesty k PDF, až se stáhne (u providera se generuje asynchronně). */
  zapisPdf(idempotencyKey: string, pdfPath: string, sha256?: string): Promise<void>;

  /**
   * Označí doklad za odeslaný odběrateli.
   *
   * Vrací `false`, když už odeslaný byl — volající pak e-mail neposílá znovu.
   * Dvakrát odeslaná faktura je pro klienta stejně matoucí jako dvakrát vystavená.
   */
  oznacOdeslano(idempotencyKey: string): Promise<boolean>;
}

/**
 * Paměťová implementace pro testy.
 *
 * Není to náhrada databáze a nikdy jí nebude: neumí souběh mezi procesy. Testům
 * stačí — ověřují rozhodovací logiku, ne zamykání. Souběh dvou běhů řeší v produkci
 * atomický claim v SQL, stejně jako to dělá `create_invoice_draft_club`
 * (`UPDATE … WHERE invoice_id IS NULL RETURNING`).
 */
export class PametovyStore implements InvoiceLinkStore {
  private podleKlice = new Map<string, InvoiceLink>();
  private podleRezervace = new Map<string, string>();
  private zabrane = new Set<string>();
  private zabraneRezervace = new Map<string, string>();

  async jeVyfakturovana(reservationId: string): Promise<boolean> {
    return this.podleRezervace.has(reservationId);
  }

  async zkusZabrat(draft: InvoiceDraft, _meta: ClaimMeta): Promise<boolean> {
    const idempotencyKey = draft.idempotencyKey;
    const reservationIds = draft.sourceReservationIds;
    if (this.zabrane.has(idempotencyKey)) return false;
    // Zabraná rezervace pod JINÝM klíčem znamená, že tytéž hodiny právě fakturuje
    // někdo jiný — typicky komerční akce (`akce-…`) proti měsíčnímu běhu (`klub-…`).
    for (const id of reservationIds) {
      const drzitel = this.zabraneRezervace.get(id);
      if (drzitel && drzitel !== idempotencyKey) return false;
    }
    this.zabrane.add(idempotencyKey);
    for (const id of reservationIds) this.zabraneRezervace.set(id, idempotencyKey);
    return true;
  }

  async uvolniZabrani(idempotencyKey: string): Promise<void> {
    this.zabrane.delete(idempotencyKey);
    for (const [id, drzitel] of this.zabraneRezervace) {
      if (drzitel === idempotencyKey) this.zabraneRezervace.delete(id);
    }
  }

  async najdiPodleKlice(idempotencyKey: string): Promise<InvoiceLink | null> {
    return this.podleKlice.get(idempotencyKey) ?? null;
  }

  async zapisVazbu(draft: InvoiceDraft, result: InvoiceResult, meta: ZapisMeta): Promise<void> {
    const { pdf: _pdf, ...bezPdf } = result;
    const vazba: InvoiceLink = {
      idempotencyKey: draft.idempotencyKey,
      reservationIds: [...draft.sourceReservationIds],
      result: bezPdf,
      ...(meta.varovani ? { varovani: meta.varovani } : {}),
    };
    this.podleKlice.set(vazba.idempotencyKey, vazba);
    for (const id of vazba.reservationIds) {
      this.podleRezervace.set(id, vazba.idempotencyKey);
    }
  }

  async zapisPdf(idempotencyKey: string, pdfPath: string): Promise<void> {
    const vazba = this.podleKlice.get(idempotencyKey);
    if (vazba) this.podleKlice.set(idempotencyKey, { ...vazba, pdfPath });
  }

  async oznacOdeslano(idempotencyKey: string): Promise<boolean> {
    const vazba = this.podleKlice.get(idempotencyKey);
    if (!vazba || vazba.odeslanoAt) return false;
    this.podleKlice.set(idempotencyKey, { ...vazba, odeslanoAt: new Date().toISOString() });
    return true;
  }

  /** Jen pro testy — kolik dokladů se doopravdy založilo. */
  get pocetDokladu(): number {
    return this.podleKlice.size;
  }
}
