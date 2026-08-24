// Orchestrace vystavení dokladu — oba zámky idempotence na jednom místě.
//
// Tenhle soubor NEVÍ, že existuje Fakturoid. Zná jen `InvoiceProvider`, takže až
// přibude iDoklad, sáhne se do `providers/`, ne sem.
//
// POŘADÍ KROKŮ NENÍ LIBOVOLNÉ:
//   1. zámek 1 (lokální)   — nesahá na síť, funguje i když je provider mimo
//   2. zámek 2 (vzdálený)  — chytí doklad, který vznikl, ale odpověď se ztratila
//   3. ensureSubject       — až teď; zakládat odběratele k dokladu, který se
//                            nakonec nevystaví, je zbytečná stopa v cizím systému
//   4. createInvoice
//   5. zápis vazby         — HNED po vytvoření, ještě před PDF
//   6. PDF (204 → čekej)   — smí selhat, doklad tím nepřestává platit
//
// PROČ JE ZÁPIS VAZBY PŘED PDF: PDF se u providera generuje asynchronně a stahování
// může trvat vteřiny. Kdyby se vazba psala až po něm, spadlý běh mezi tím by nechal
// doklad vystavený a nezaznamenaný — a příští běh by ho podle zámku 1 vystavil znovu.
// Doklad bez PDF je pořád platný doklad; doklad bez vazby je duplicita ve frontě.

import { roundCzk } from '../src/lib/money.ts';
import { BillingError, BillingValidationError } from './errors.ts';
import { soucetRadku } from './mapping.ts';
import type { InvoiceDraft, InvoiceProvider, InvoiceResult } from './types.ts';
import type { InvoiceLink, InvoiceLinkStore } from './store.ts';

/** Kam se ukládá kopie PDF (v provozu Supabase Storage). */
export interface PdfUloziste {
  /** Vrací cestu, pod kterou se soubor uložil. */
  uloz(idempotencyKey: string, pdf: Uint8Array): Promise<string>;
}

export type VysledekVystaveni =
  /** Zámek 1 zabral — některá rezervace už doklad nese. Nic se nedělo. */
  | { stav: 'preskoceno'; duvod: string }
  /** Není co fakturovat (0 řádků). Normální stav, ne chyba. */
  | { stav: 'prazdne' }
  /** Zámek 2 zabral — doklad u providera už byl. Vazba se jen dorovnala. */
  | { stav: 'existoval'; link: InvoiceLink }
  /**
   * Doklad u providera existuje, ale NEODPOVÍDÁ dnešnímu podkladu.
   * Vazba se záměrně NEZAPSALA — kouká na to člověk.
   */
  | { stav: 'nesedi'; duvod: string; result: InvoiceResult }
  /** Doklad vznikl teď. */
  | { stav: 'vystaveno'; link: InvoiceLink };

/**
 * O kolik smí celková částka u providera odskočit od naší, aby to ještě bylo
 * zaokrouhlení a ne jiný podklad. Půl koruny je strop rozdílu mezi dvěma
 * zaokrouhlovacími pravidly na celé koruny; cokoli víc je jiný počet řádků.
 */
export const TOLERANCE_KC = 0.5;

/** Kolikrát se zkusí stáhnout PDF, než se to vzdá (204 = ještě se generuje). */
export const PDF_POKUSU = 5;
/** Prodleva mezi pokusy o PDF, ms. Roste lineárně: 500, 1000, 1500… */
export const PDF_KROK_MS = 500;

const spat = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/**
 * Vystaví doklad, nebo řekne proč ne.
 *
 * `draft === null` je legitimní vstup — mapovací vrstva takhle hlásí „za tohle
 * období není co fakturovat" (klub v srpnu nehrál). Volající to nemusí ošetřovat
 * zvlášť; prázdný doklad se prostě nevystaví.
 */
export const vystavDoklad = async (vstup: {
  draft: InvoiceDraft | null;
  provider: InvoiceProvider;
  store: InvoiceLinkStore;
  /** Bez úložiště se PDF nestahuje vůbec — použitelné pro suchý běh. */
  pdfUloziste?: PdfUloziste;
  /** Injektovatelné čekání, ať testy neběží v reálném čase. */
  cekej?: (ms: number) => Promise<void>;
  pdfPokusu?: number;
}): Promise<VysledekVystaveni> => {
  const { draft, provider, store } = vstup;
  const cekej = vstup.cekej ?? spat;

  if (!draft || draft.lines.length === 0) return { stav: 'prazdne' };

  // Doklad bez zdrojových rezervací by neoznačil nic jako vyfakturované, takže
  // by tytéž hodiny prošly znovu pod jiným klíčem (`akce-…` vs. `klub-…`).
  // Je to jediná duplicita, kterou zámek 2 nechytá — klíč by byl jiný.
  if (draft.sourceReservationIds.length === 0) {
    throw new BillingValidationError(
      `Doklad ${draft.idempotencyKey} má řádky, ale žádné zdrojové rezervace — ` +
      'nešlo by označit, co se vyfakturovalo.', 'sourceReservationIds',
    );
  }

  // ---- ZÁMEK 1 — lokální --------------------------------------------------
  // Stačí JEDNA už vyfakturovaná rezervace, aby se celý doklad přeskočil. Vystavit
  // ho na zbytek by rozdělilo jednu akci na dva doklady a klient by dostal dvakrát
  // poštu za totéž. Rozdíl patří člověku, ne automatice.
  for (const id of draft.sourceReservationIds) {
    if (await store.jeVyfakturovana(id)) {
      return {
        stav: 'preskoceno',
        duvod: `Rezervace ${id} už nese doklad — ${draft.idempotencyKey} se nevystavuje znovu.`,
      };
    }
  }

  // ---- ZÁMEK 2 — vzdálený -------------------------------------------------
  // Nejdřív lokální odpověď (levná), pak teprve dotaz k providerovi.
  const znamy = await store.najdiPodleKlice(draft.idempotencyKey);
  if (znamy) return { stav: 'existoval', link: znamy };

  const uProvidera = await provider.findExistingInvoice(draft.idempotencyKey);
  if (uProvidera) {
    // Doklad vznikl při dřívějším běhu, jen se nestihla zapsat vazba.
    //
    // ALE NESMÍ SE MU VĚŘIT NASLEPO. Vazba by se zapsala na DNEŠNÍ
    // `sourceReservationIds`, jenže doklad vznikl z těch VČEREJŠÍCH. Když mezitím
    // přibyla rezervace, označili bychom ji za vyfakturovanou, ačkoli na dokladu
    // není — a už nikdy by se nevyfakturovala. Proto se porovnají částky.
    const nesedi = proc0Nesedi(draft, uProvidera);
    if (nesedi) return { stav: 'nesedi', duvod: nesedi, result: uProvidera };

    const link = await dorovnej(store, draft, uProvidera, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu);
    return { stav: 'existoval', link };
  }

  // ---- ZÁMEK 3 — atomický claim -------------------------------------------
  // Zámky 1 a 2 jsou jen ČTENÍ, takže dva souběžné běhy (cron a admin ve stejnou
  // vteřinu) jimi projdou oba. Teprve claim je rozhodne.
  if (!await store.zkusZabrat(draft.idempotencyKey, draft.sourceReservationIds)) {
    return {
      stav: 'preskoceno',
      duvod: `Doklad ${draft.idempotencyKey} právě vystavuje jiný běh.`,
    };
  }

  // ---- Vystavení ----------------------------------------------------------
  try {
    const { providerSubjectId } = await provider.ensureSubject(draft.party);
    const vysledek = await provider.createInvoice(draft, providerSubjectId);
    const link = await dorovnej(store, draft, vysledek, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu);
    return { stav: 'vystaveno', link };
  } catch (chyba) {
    // Claim se pouští: po selhaném POSTu NEVÍME, jestli doklad vznikl. Rozhodne
    // až příští běh — zámek 2 ho buď najde, nebo ne. Držet claim navždy by
    // fakturaci toho klubu zablokovalo, dokud by nepřišel člověk.
    await store.uvolniZabrani(draft.idempotencyKey);
    throw chyba;
  }
};

/**
 * Odpovídá doklad u providera tomu, co bychom fakturovali dnes?
 *
 * Vrací důvod rozporu, nebo `null`, když sedí. Porovnává se ČÁSTKA, protože
 * počet řádků u providera nemusí být vidět a částka rozdíl stejně odhalí:
 * chybějící nebo přebývající rezervace je stovky korun, kdežto rozdíl
 * zaokrouhlovacích pravidel nanejvýš půl koruny.
 */
const proc0Nesedi = (draft: InvoiceDraft, u: InvoiceResult): string | null => {
  const nase = roundCzk(soucetRadku(draft.lines));

  if (u.providerTotal === undefined) {
    return `Doklad ${u.number || u.providerInvoiceId} existuje, ale provider nevrátil celkovou ` +
      'částku, takže nejde ověřit, že odpovídá dnešnímu podkladu. Vazba se nezapsala.';
  }

  const rozdil = Math.abs(u.providerTotal - nase);
  if (rozdil > TOLERANCE_KC) {
    return `Doklad ${u.number || u.providerInvoiceId} zní na ${u.providerTotal} Kč, ` +
      `ale dnešní podklad dává ${nase} Kč (rozdíl ${rozdil.toFixed(2)} Kč). ` +
      'Nejspíš mezitím přibyla nebo se změnila rezervace. Vazba se nezapsala.';
  }
  return null;
};

/** Zapíše vazbu a pokusí se doplnit PDF. Zápis vazby má přednost před PDF. */
const dorovnej = async (
  store: InvoiceLinkStore,
  draft: InvoiceDraft,
  result: InvoiceResult,
  uloziste: PdfUloziste | undefined,
  provider: InvoiceProvider,
  cekej: (ms: number) => Promise<void>,
  pokusu?: number,
): Promise<InvoiceLink> => {
  // `pdf` se z výsledku VYHAZUJE, než se vazba uloží. Bajty patří do úložiště
  // souborů, ne do řádku v databázi — `JSON.stringify(Uint8Array)` z nich udělá
  // objekt číslovaných klíčů („{"0":37,"1":80,…}") a nafoukne záznam o stovky kB.
  const { pdf: _pdf, ...bezPdf } = result;
  const link: InvoiceLink = {
    idempotencyKey: draft.idempotencyKey,
    reservationIds: [...draft.sourceReservationIds],
    result: bezPdf,
  };
  await store.zapisVazbu(link);

  if (!uloziste) return link;

  const pdf = result.pdf ?? await stahniPdf(provider, result.providerInvoiceId, cekej, pokusu);
  if (!pdf) return link;   // pořád se generuje — doklad platí, PDF dobere další běh

  const cesta = await uloziste.uloz(draft.idempotencyKey, pdf);
  await store.zapisPdf(draft.idempotencyKey, cesta);
  return { ...link, pdfPath: cesta };
};

/**
 * Stáhne PDF s opakováním na 204.
 *
 * 204 NENÍ chyba — provider tím říká „ještě se generuje". Kdo si ho přeloží jako
 * selhání, dostane doklad označený jako rozbitý pár set milisekund předtím, než
 * by byl v pořádku.
 *
 * Vrací `null`, když se to do `pokusu` pokusů nestihlo. Taky ne chyba: doklad má
 * číslo a platí, PDF si dobere další běh fronty.
 */
export const stahniPdf = async (
  provider: InvoiceProvider,
  providerInvoiceId: string,
  cekej: (ms: number) => Promise<void> = spat,
  pokusu: number = PDF_POKUSU,
): Promise<Uint8Array | null> => {
  if (pokusu < 1) throw new BillingError('Počet pokusů o PDF musí být aspoň 1.');

  for (let pokus = 1; pokus <= pokusu; pokus++) {
    const pdf = await provider.downloadPdf(providerInvoiceId);
    if (pdf) return pdf;
    if (pokus < pokusu) await cekej(PDF_KROK_MS * pokus);
  }
  return null;
};
