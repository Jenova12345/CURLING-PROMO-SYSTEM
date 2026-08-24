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
  | { stav: 'existoval'; link: InvoiceLink; varovani?: string }
  /**
   * Doklad u providera existuje, ale NEODPOVÍDÁ dnešnímu podkladu.
   * Vazba se záměrně NEZAPSALA — kouká na to člověk.
   */
  | { stav: 'nesedi'; duvod: string; result: InvoiceResult }
  /**
   * Doklad vznikl teď. `varovani` nese rozpor kontrolního součtu proti providerovi —
   * PR 4 ho MUSÍ někam vypsat, tichý rozpor u peněz je horší než hlasitý.
   */
  | { stav: 'vystaveno'; link: InvoiceLink; varovani?: string };

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
  // Doklad na nula korun se nevystavuje — sazba 0 je platná (hodina zdarma
  // uvnitř placeného dokladu), ale celý doklad na nulu je pro účetní horší
  // než žádný. Automatika v repu to má stejně (`amount > 0` v automatika.sql).
  if (roundCzk(soucetRadku(draft.lines)) <= 0) return { stav: 'prazdne' };

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

    const { link, pdfChyba } = await dorovnej(store, draft, uProvidera, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu);
    return { stav: 'existoval', link, ...(pdfChyba ? { varovani: pdfChyba } : {}) };
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

  // ---- ZÁMEK 2, PODRUHÉ — a není to opatrnost navíc -----------------------
  //
  // Mezi prvním dotazem a claimem je okno, kterým projde duplicita:
  //   • běh A i B projdou zámkem 2 (oba dostanou null),
  //   • B se zdrží — třeba na 429, kde se čeká podle X-RateLimit-Reset až minutu,
  //   • mezitím A zabere claim, POSTne doklad, Fakturoid ho ZALOŽÍ a spadne
  //     na 5xx při skládání odpovědi → A claim v catch UVOLNÍ (správně: nevíme,
  //     jak to dopadlo),
  //   • B teď claim dostane a POSTne DRUHÝ doklad. `custom_id` u Fakturoidu
  //     není unikátní klíč, takže vzniknou dvě faktury v ostré řadě.
  //
  // Jeden GET navíc to okno zavře celé.
  try {
    const poClaimu = await provider.findExistingInvoice(draft.idempotencyKey);
    if (poClaimu) {
      const nesedi = proc0Nesedi(draft, poClaimu);
      if (nesedi) {
        await store.uvolniZabrani(draft.idempotencyKey);
        return { stav: 'nesedi', duvod: nesedi, result: poClaimu };
      }
      const { link, pdfChyba } = await dorovnej(store, draft, poClaimu, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu);
      return { stav: 'existoval', link, ...(pdfChyba ? { varovani: pdfChyba } : {}) };
    }
  } catch (chyba) {
    await store.uvolniZabrani(draft.idempotencyKey);
    throw chyba;
  }

  // ---- Vystavení ----------------------------------------------------------
  try {
    const { providerSubjectId } = await provider.ensureSubject(draft.party);
    const vysledek = await provider.createInvoice(draft, providerSubjectId);
    const { link, pdfChyba } = await dorovnej(store, draft, vysledek, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu);
    const varovani = [zkontrolujSoucet(draft, vysledek), pdfChyba].filter(Boolean).join(' ');
    return { stav: 'vystaveno', link, ...(varovani ? { varovani } : {}) };
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
  const oznaceni = u.number || u.providerInvoiceId;

  // PRVNÍ A ROZHODUJÍCÍ KONTROLA JSOU ŘÁDKY, NE ČÁSTKA.
  //
  // Porovnávat jen součet je slabé přesně tam, kde na tom záleží: klub trénuje
  // týdně za stejnou sazbu, takže doklad na rezervaci „a" a doklad na rezervaci
  // „b" mají TUTÉŽ částku. Kontrola částkou by je prohlásila za shodné, „b" by
  // se označila za vyfakturovanou — a už nikdy by se nevyfakturovala.
  //
  // Popis řádku nese datum a čas, takže je mezi rezervacemi rozlišuje.
  if (u.providerLines) {
    const otisk = (l: { name: string; quantity: number; unitPrice: number }) =>
      `${l.name}|${l.quantity}|${l.unitPrice}`;
    const uProvidera = [...u.providerLines].map(otisk).sort();
    const nase = [...draft.lines].map(otisk).sort();

    if (uProvidera.length !== nase.length || uProvidera.some((r, i) => r !== nase[i])) {
      return `Doklad ${oznaceni} má ${uProvidera.length} řádků, ale dnešní podklad dává ` +
        `${nase.length} a neshodují se. Nejspíš mezitím přibyla nebo se změnila rezervace. ` +
        'Vazba se nezapsala.';
    }
    return null;
  }

  // Bez řádků zbývá jen částka — slabší, ale pořád lepší než nic.
  const nase = roundCzk(soucetRadku(draft.lines));
  if (u.providerTotal === undefined) {
    return `Doklad ${oznaceni} existuje, ale provider nevrátil ani řádky, ani celkovou částku, ` +
      'takže nejde ověřit, že odpovídá dnešnímu podkladu. Vazba se nezapsala.';
  }

  const rozdil = Math.abs(u.providerTotal - nase);
  if (rozdil > TOLERANCE_KC) {
    return `Doklad ${oznaceni} zní na ${u.providerTotal} Kč, ale dnešní podklad dává ${nase} Kč ` +
      `(rozdíl ${rozdil.toFixed(2)} Kč). Vazba se nezapsala.`;
  }
  return null;
};

/**
 * Kontrolní součet PO vystavení: sedí částka u providera na naši?
 *
 * Vrací text varování, nebo `null`. Doklad už existuje, takže se nedá vzít zpět —
 * ale rozpor se nesmí ztratit. Je to ta rovnice, kterou po fakturaci vyžaduje
 * CLAUDE.md, jen proti externímu systému: co jsme poslali == co vytiskl.
 */
const zkontrolujSoucet = (draft: InvoiceDraft, u: InvoiceResult): string | null => {
  if (u.providerTotal === undefined) {
    return `Doklad ${u.number || u.providerInvoiceId} vznikl, ale provider nevrátil celkovou ` +
      'částku — kontrolní součet se neověřil.';
  }
  const nase = roundCzk(soucetRadku(draft.lines));
  const rozdil = Number((u.providerTotal - nase).toFixed(2));
  if (Math.abs(rozdil) > TOLERANCE_KC) {
    return `KONTROLNÍ SOUČET NESEDÍ: doklad ${u.number || u.providerInvoiceId} zní na ` +
      `${u.providerTotal} Kč, my jsme poslali ${nase} Kč (rozdíl ${rozdil} Kč).`;
  }
  // Do půl koruny je to rozdíl zaokrouhlovacích pravidel — čekaný, ale ne němý.
  if (rozdil !== 0) {
    return `Zaokrouhlení se liší o ${rozdil} Kč (doklad ${u.providerTotal} Kč, ` +
      `náš podklad ${nase} Kč). V mezích, ale stojí za zápis.`;
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
): Promise<{ link: InvoiceLink; pdfChyba?: string }> => {
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

  if (!uloziste) return { link };

  // PDF SE NESMÍ DOTKNOUT PLATNOSTI DOKLADU. Výjimka odsud (429, výpadek sítě,
  // plné úložiště) by shodila celé vystavení — vazba je přitom už zapsaná, takže
  // příští běh by doklad podle zámku 1 přeskočil a PDF by nedobral NIKDO.
  // Doklad má číslo a platí i bez PDF (R5); tohle je dobírání, ne vystavování.
  try {
    const pdf = result.pdf ?? await stahniPdf(provider, result.providerInvoiceId, cekej, pokusu);
    if (!pdf) {
      return { link, pdfChyba: `PDF dokladu ${result.number || result.providerInvoiceId} se zatím generuje.` };
    }

    const cesta = await uloziste.uloz(draft.idempotencyKey, pdf);
    await store.zapisPdf(draft.idempotencyKey, cesta);
    return { link: { ...link, pdfPath: cesta } };
  } catch (chyba) {
    // Důvod se NESMÍ spolknout: doklad je vystavený a bez PDF, což někdo musí
    // vidět. Dobrat ho pak jde přes `dobirPdf` — vystavování se tím nezdržuje.
    return {
      link,
      pdfChyba: `PDF dokladu ${result.number || result.providerInvoiceId} se nepodařilo stáhnout: ` +
        `${chyba instanceof Error ? chyba.message : String(chyba)}`,
    };
  }
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

/**
 * Dobere PDF k dokladu, který ho ještě nemá.
 *
 * PROČ SAMOSTATNÝ VSTUPNÍ BOD: jakmile vazba existuje, `vystavDoklad` se u ní
 * zastaví hned na `najdiPodleKlice` a k PDF se vůbec nedostane. Komentář, který
 * tvrdil „PDF dobere další běh fronty", tedy dřív nepopisoval žádnou existující
 * cestu — doklad zůstal bez PDF natrvalo. Tohle je ta cesta; PR 4 ji zavolá
 * pro vazby bez `pdfPath`.
 *
 * Vrací cestu k uloženému souboru, nebo `null`, když se PDF pořád generuje.
 */
export const dobirPdf = async (vstup: {
  link: InvoiceLink;
  provider: InvoiceProvider;
  store: InvoiceLinkStore;
  pdfUloziste: PdfUloziste;
  cekej?: (ms: number) => Promise<void>;
  pdfPokusu?: number;
}): Promise<string | null> => {
  const { link, provider, store, pdfUloziste } = vstup;
  if (link.pdfPath) return link.pdfPath;

  const pdf = await stahniPdf(
    provider, link.result.providerInvoiceId, vstup.cekej ?? spat, vstup.pdfPokusu,
  );
  if (!pdf) return null;

  const cesta = await pdfUloziste.uloz(link.idempotencyKey, pdf);
  await store.zapisPdf(link.idempotencyKey, cesta);
  return cesta;
};
