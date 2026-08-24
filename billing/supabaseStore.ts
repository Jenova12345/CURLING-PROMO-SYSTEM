// `InvoiceLinkStore` nad Postgresem — evidence dokladů odeslaných do Fakturoidu.
//
// VARIANTA S2 (rozhodnutí PM 24. 8. 2026): zámek 1 se ptá VÝHRADNĚ na fakturoidí
// vazbu, NIKDY na `reservations.invoice_id`. Rezervace může mít interní doklad
// a stejně má jít do Fakturoidu — o odeslání rozhoduje jen existence vazby
// v `fakturoid_invoices`. Tahle vrstva do `reservations` nezapisuje vůbec nic,
// takže se s guardem `app.trusted_booking` ani nepotká.
//
// VŠECHNO JDE PŘES RPC, ne přes přímý zápis do tabulky. Zápis do
// `fakturoid_invoices` je adminovi i servisnímu klíči odepřený (`REVOKE ALL`),
// protože claim se nesmí dát obejít: „SELECT, a když nic, tak INSERT" je závod,
// ne zámek. Poslední slovo má `ON CONFLICT DO NOTHING` v databázi.
//
// KLIENT SE INJEKTUJE jako minimální rozhraní, ne jako `SupabaseClient`. Díky
// tomu jde tahle vrstva otestovat bez sítě i bez SDK a nezatáhne do `billing/`
// závislost, kterou jádro nepotřebuje.

import { BillingProviderError } from './errors.ts';
import type { ClaimMeta, InvoiceLink, InvoiceLinkStore, ZapisMeta } from './store.ts';
import type { InvoiceDraft, InvoiceResult } from './types.ts';

/** Tvar, na který sedí `supabase.rpc()`. */
export interface RpcKlient {
  rpc(
    nazev: string,
    args?: Record<string, unknown>,
  ): Promise<{ data: unknown; error: { message: string } | null }>;
}

/** Řádek, jak ho vrací `fakturoid_najdi_podle_klice`. */
interface RadekVazby {
  idempotency_key: string;
  provider_invoice_id: string;
  provider_subject_id: string | null;
  cislo: string | null;
  variabilni_symbol: string | null;
  public_url: string | null;
  status: string | null;
  provider_total: string | number | null;
  pdf_path: string | null;
  rezim: string | null;
  odeslano_at: string | null;
  rezervace: string[] | null;
  varovani: string | null;
}

const cislo = (hodnota: string | number | null): number | undefined => {
  if (hodnota === null || hodnota === undefined) return undefined;
  const n = Number(String(hodnota).trim());
  return Number.isFinite(n) ? n : undefined;
};

export class SupabaseStore implements InvoiceLinkStore {
  #db: RpcKlient;

  constructor(db: RpcKlient) {
    this.#db = db;
  }

  async #volej(nazev: string, args: Record<string, unknown>): Promise<unknown> {
    const { data, error } = await this.#db.rpc(nazev, args);
    if (error) {
      // Chyba z databáze je provozní chyba, ne validace vstupu — a `message`
      // z ní patří do logu, ne uživateli (viz `uzivatelskaZprava` v errors.ts).
      throw new BillingProviderError(`RPC ${nazev} selhalo: ${error.message}`, 0);
    }
    return data;
  }

  // ---------------------------------------------------------------------------
  // ZÁMEK 1
  // ---------------------------------------------------------------------------

  async jeVyfakturovana(reservationId: string): Promise<boolean> {
    return await this.#volej('fakturoid_je_vyfakturovana', { _reservation: reservationId }) === true;
  }

  // ---------------------------------------------------------------------------
  // ZÁMEK 3 — atomický claim
  // ---------------------------------------------------------------------------

  /**
   * Jeden příkaz v databázi (`INSERT … ON CONFLICT (idempotency_key) DO NOTHING`),
   * ne čtení-pak-zápis. `false` znamená „klíč nebo některá rezervace už patří
   * jinému běhu" — nikdy „něco se pokazilo"; to skončí výjimkou.
   */
  async zkusZabrat(draft: InvoiceDraft, meta: ClaimMeta): Promise<boolean> {
    return await this.#volej('fakturoid_zkus_zabrat', {
      _klic: draft.idempotencyKey,
      _druh: draft.type,
      _subject: draft.party.ourSubjectId,
      _event: draft.eventId ?? null,
      _od: draft.obdobiOd ?? null,
      _do: draft.obdobiDo ?? null,
      _nas_soucet: meta.nasSoucet,
      _radku: draft.lines.length,
      _rezim: meta.rezim,
      _rezervace: draft.sourceReservationIds,
    }) === true;
  }

  async uvolniZabrani(idempotencyKey: string): Promise<void> {
    await this.#volej('fakturoid_uvolni_zabrani', {
      _klic: idempotencyKey,
      _duvod: 'vystavení selhalo — nevíme, jestli doklad u providera vznikl',
    });
  }

  // ---------------------------------------------------------------------------
  // ZÁMEK 2 (lokální část) a zápis
  // ---------------------------------------------------------------------------

  async najdiPodleKlice(idempotencyKey: string): Promise<InvoiceLink | null> {
    const data = await this.#volej('fakturoid_najdi_podle_klice', { _klic: idempotencyKey });
    const radky = Array.isArray(data) ? (data as RadekVazby[]) : [];
    const r = radky[0];
    if (!r) return null;

    return {
      idempotencyKey: r.idempotency_key,
      reservationIds: r.rezervace ?? [],
      result: {
        providerInvoiceId: r.provider_invoice_id,
        number: r.cislo ?? '',
        variableSymbol: r.variabilni_symbol ?? '',
        ...(r.public_url ? { publicUrl: r.public_url } : {}),
        status: r.status ?? 'unknown',
        ...(cislo(r.provider_total) !== undefined ? { providerTotal: cislo(r.provider_total) } : {}),
        // `providerLines` se ZÁMĚRNĚ nedrží: uložená kopie by mohla zestárnout
        // a kontrola shody by pak porovnávala náš starý zápis místo toho, co
        // doklad u providera opravdu má. Čerstvé řádky dodá `findExistingInvoice`.
      },
      ...(r.pdf_path ? { pdfPath: r.pdf_path } : {}),
      ...(r.odeslano_at ? { odeslanoAt: r.odeslano_at } : {}),
    };
  }

  /**
   * Zapíše odpověď providera. RPC umí DVA stavy a rozhoduje se sama:
   *
   *   A) dorovná ŽIVÝ CLAIM — běžná cesta po `zkusZabrat`,
   *   B) založí řádek pro NÁLEZ — cesta zotavení, kde už žádný claim není,
   *      protože ho předchozí běh po selhaném POSTu správně uvolnil.
   *
   * Proto se posílá celý kontext dokladu, ne jen odpověď: ve větvi B se řádek
   * zakládá od začátku, včetně vazeb na rezervace. Bez nich by po zotavení
   * zůstal zámek 1 mrtvý a příští běh by vystavil druhý doklad.
   */
  async zapisVazbu(draft: InvoiceDraft, result: InvoiceResult, meta: ZapisMeta): Promise<void> {
    const zapsano = await this.#volej('fakturoid_zapis_vazbu', {
      _klic: draft.idempotencyKey,
      _provider_invoice_id: result.providerInvoiceId,
      _provider_subject_id: meta.providerSubjectId ?? null,
      _cislo: result.number,
      _vs: result.variableSymbol,
      _public_url: result.publicUrl ?? null,
      _status: result.status,
      _provider_total: result.providerTotal ?? null,
      _varovani: meta.varovani ?? null,
      // Kontext pro větev B.
      _druh: draft.type,
      _subject: draft.party.ourSubjectId,
      _event: draft.eventId ?? null,
      _od: draft.obdobiOd ?? null,
      _do: draft.obdobiDo ?? null,
      _nas_soucet: meta.nasSoucet,
      _radku: draft.lines.length,
      _rezim: meta.rezim,
      _rezervace: draft.sourceReservationIds,
    });

    // `false` znamená, že se doklad nepodařilo zaevidovat ANI jednou z cest.
    // Doklad u providera přitom EXISTUJE, takže se to nesmí přejít mlčky —
    // jinak by o něm nikdo nevěděl a příští běh by vystavil druhý.
    if (zapsano !== true) {
      throw new BillingProviderError(
        `Doklad ${result.number} se u providera vystavil, ale nešlo ho zapsat ` +
        `do evidence (klíč ${draft.idempotencyKey}). Zkontrolujte fakturoid_invoices ručně.`, 0,
      );
    }
  }

  async zapisPdf(idempotencyKey: string, pdfPath: string, sha256?: string): Promise<void> {
    // `_sha: null` otisk NEPŘEPÍŠE (RPC dělá `coalesce`), takže tenhle zápis
    // nesmaže hodnotu, kterou o krok dřív uložila Edge funkce.
    await this.#volej('fakturoid_zapis_pdf', {
      _klic: idempotencyKey, _cesta: pdfPath, _sha: sha256 ?? null,
    });
  }

  async oznacOdeslano(idempotencyKey: string): Promise<boolean> {
    return await this.#volej('fakturoid_oznac_odeslano', { _klic: idempotencyKey }) === true;
  }
}
