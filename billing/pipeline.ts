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
  /**
   * Uloží soubor a vrátí, kam.
   *
   * `sha256` je volitelný — kdo ho spočítá, ať ho vrátí sem. Zapisuje se
   * JEDNÍM voláním spolu s cestou; dřív ho psala zvlášť Edge funkce a hned nato
   * ho druhý zápis z pipeline přepsal na NULL.
   */
  uloz(idempotencyKey: string, pdf: Uint8Array): Promise<{ cesta: string; sha256?: string }>;
}

export type RezimVystaveni = 'koncept' | 'odeslat';

/**
 * Varování k vystavenému dokladu.
 *
 * ROZDĚLENO NA DVĚ ČÁSTI SCHVÁLNĚ. `zprava` je naše vlastní věta a smí nést
 * částky — ty admin podle CLAUDE.md vidět může. `interni` může nést CIZÍ text
 * (hláška Postgresu, Storage, providera) a patří **jen do logu**: bývají v ní
 * názvy tabulek, cesty a vnitřnosti, které v prohlížeči nemají co dělat.
 */
export interface Varovani {
  kod: 'kontrolni_soucet' | 'zaokrouhleni' | 'pdf' | 'odeslani';
  zprava: string;
  interni?: string;
}

export type VysledekVystaveni =
  /** Zámek 1 zabral — některá rezervace už doklad nese. Nic se nedělo. */
  | { stav: 'preskoceno'; duvod: string }
  /** Není co fakturovat (0 řádků). Normální stav, ne chyba. */
  | { stav: 'prazdne' }
  /** Zámek 2 zabral — doklad u providera už byl. Vazba se jen dorovnala. */
  | { stav: 'existoval'; link: InvoiceLink; varovani?: Varovani[] }
  /**
   * Doklad u providera existuje, ale NEODPOVÍDÁ dnešnímu podkladu.
   * Vazba se záměrně NEZAPSALA — kouká na to člověk.
   */
  | { stav: 'nesedi'; duvod: string; result: InvoiceResult }
  /**
   * Doklad vznikl teď. `varovani` nese rozpor kontrolního součtu proti providerovi —
   * PR 4 ho MUSÍ někam vypsat, tichý rozpor u peněz je horší než hlasitý.
   */
  | { stav: 'vystaveno'; link: InvoiceLink; varovani?: Varovani[] };

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
  /**
   * `koncept` (default) — doklad se u providera jen založí, e-mail se NEPOSÍLÁ.
   * `odeslat` — po založení se doklad rovnou odešle odběrateli.
   *
   * Rozjezdový režim je `koncept`: člověk si doklady týden prohlíží, než se
   * pustí automatické odesílání.
   */
  rezim?: RezimVystaveni;
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

    const soucet = zkontrolujSoucet(draft, uProvidera);
    const { link, pdfChyba } = await dorovnej(
      store, draft, uProvidera, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu,
      { varovani: soucet },
    );
    const varovani = [soucet, pdfChyba].filter((v): v is Varovani => v != null);
    return { stav: 'existoval', link, ...(varovani.length ? { varovani } : {}) };
  }

  // ---- ZÁMEK 3 — atomický claim -------------------------------------------
  // Zámky 1 a 2 jsou jen ČTENÍ, takže dva souběžné běhy (cron a admin ve stejnou
  // vteřinu) jimi projdou oba. Teprve claim je rozhodne.
  const rezim = vstup.rezim ?? 'koncept';
  if (!await store.zkusZabrat(draft, { nasSoucet: roundCzk(soucetRadku(draft.lines)), rezim })) {
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
      const soucet = zkontrolujSoucet(draft, poClaimu);
      const { link, pdfChyba } = await dorovnej(
        store, draft, poClaimu, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu,
        { varovani: soucet, rezim },
      );
      const varovani = [soucet, pdfChyba].filter((v): v is Varovani => v != null);
      return { stav: 'existoval', link, ...(varovani.length ? { varovani } : {}) };
    }
  } catch (chyba) {
    await uvolniTise(store, draft.idempotencyKey);
    throw chyba;
  }

  // ---- Vystavení ----------------------------------------------------------
  try {
    const { providerSubjectId } = await provider.ensureSubject(draft.party);
    const vysledek = await provider.createInvoice(draft, providerSubjectId);
    // Kontrolní součet se počítá PŘED zápisem, ať ho jde uložit do evidence.
    const soucet = zkontrolujSoucet(draft, vysledek);
    const { link, pdfChyba } = await dorovnej(
      store, draft, vysledek, vstup.pdfUloziste, provider, cekej, vstup.pdfPokusu,
      { providerSubjectId, varovani: soucet, rezim },
    );
    const odeslaniChyba = await odesliPokudMa(provider, store, draft, vysledek, rezim);
    const varovani = [soucet, pdfChyba, odeslaniChyba]
      // `!= null` schválně (dvě rovnítka): `dorovnej` bez úložiště `pdfChyba`
      // vůbec nevrací, takže je `undefined` — a `!== null` by ho propustilo dál.
      .filter((v): v is Varovani => v != null);
    return { stav: 'vystaveno', link, ...(varovani.length ? { varovani } : {}) };
  } catch (chyba) {
    // Claim se pouští: po selhaném POSTu NEVÍME, jestli doklad vznikl. Rozhodne
    // až příští běh — zámek 2 ho buď najde, nebo ne. Držet claim navždy by
    // fakturaci toho klubu zablokovalo, dokud by nepřišel člověk.
    await uvolniTise(store, draft.idempotencyKey);
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
  // Porovnává se týmž pravidlem jako v `zkontrolujSoucet`: u dokladu s cenami
  // bez DPH proti základu daně, jinak proti celkové částce.
  const nase = roundCzk(soucetRadku(draft.lines));
  const castka = castkaKPorovnani(draft, u);
  if (castka === undefined) {
    return `Doklad ${oznaceni} existuje, ale provider nevrátil ani řádky, ani částku, se kterou ` +
      'se dá náš podklad porovnat, takže nejde ověřit, že mu odpovídá. Vazba se nezapsala.';
  }

  const rozdil = Math.abs(castka.hodnota - nase);
  if (rozdil > TOLERANCE_KC) {
    return `Doklad ${oznaceni} zní na ${castka.hodnota} Kč (${castka.popis}), ale dnešní podklad ` +
      `dává ${nase} Kč (rozdíl ${rozdil.toFixed(2)} Kč). Vazba se nezapsala.`;
  }
  return null;
};

/**
 * Která částka od providera odpovídá NAŠEMU součtu řádků.
 *
 * Tohle je celá podstata DPH v kontrolním součtu a stojí za to ji přečíst
 * pomalu. `soucetRadku` sečte to, co je na řádcích:
 *
 *   • klubová faktura (`pricesIncludeVat = true`) → částka VČETNĚ daně
 *     → protějšek je `providerTotal`
 *   • komerční faktura (`pricesIncludeVat = false`) → ZÁKLAD bez daně
 *     → protějšek je `providerSubtotal`
 *   • neplátce (`undefined`) → obě čísla jsou stejná, bere se `providerTotal`
 *
 * Kdyby se u komerčky porovnal základ s celkovou částkou, rozdíl by vyšel
 * PŘESNĚ ve výši DPH — u 12 % a dokladu za 5 000 Kč tedy 600 Kč. To by
 * neprošlo jako zaokrouhlení, spustilo by to poplach „kontrolní součet nesedí"
 * na každé komerční faktuře, a hledala by se chyba v mapování, která tam není.
 *
 * Vrací `undefined`, když provider potřebné číslo nedodal — volající to musí
 * ohlásit, ne mlčky přeskočit.
 */
const castkaKPorovnani = (
  draft: InvoiceDraft,
  u: InvoiceResult,
): { hodnota: number; popis: string } | undefined => {
  if (draft.pricesIncludeVat === false) {
    return u.providerSubtotal === undefined
      ? undefined
      : { hodnota: u.providerSubtotal, popis: 'základ bez DPH' };
  }
  return u.providerTotal === undefined
    ? undefined
    : { hodnota: u.providerTotal, popis: draft.pricesIncludeVat ? 'celkem s DPH' : 'celkem' };
};

/**
 * Kontrolní součet PO vystavení: sedí částka u providera na naši?
 *
 * Vrací text varování, nebo `null`. Doklad už existuje, takže se nedá vzít zpět —
 * ale rozpor se nesmí ztratit. Je to ta rovnice, kterou po fakturaci vyžaduje
 * CLAUDE.md, jen proti externímu systému: co jsme poslali == co vytiskl.
 */
const zkontrolujSoucet = (draft: InvoiceDraft, u: InvoiceResult): Varovani | null => {
  const oznaceni = u.number || u.providerInvoiceId;

  const uProvidera = castkaKPorovnani(draft, u);
  if (uProvidera === undefined) {
    return {
      kod: 'kontrolni_soucet',
      zprava: draft.pricesIncludeVat === false
        ? `Doklad ${oznaceni} vznikl, ale provider nevrátil základ daně — u dokladu ` +
          's cenami bez DPH se kontrolní součet nedá ověřit proti celkové částce.'
        : `Doklad ${oznaceni} vznikl, ale provider nevrátil celkovou částku — ` +
          'kontrolní součet se neověřil.',
    };
  }

  const nase = roundCzk(soucetRadku(draft.lines));
  const rozdil = Number((uProvidera.hodnota - nase).toFixed(2));

  if (Math.abs(rozdil) > TOLERANCE_KC) {
    return {
      kod: 'kontrolni_soucet',
      zprava: `KONTROLNÍ SOUČET NESEDÍ: doklad ${oznaceni} zní na ${uProvidera.hodnota} Kč ` +
        `(${uProvidera.popis}), my jsme poslali ${nase} Kč (rozdíl ${rozdil} Kč).`,
    };
  }
  // Do půl koruny je to rozdíl zaokrouhlovacích pravidel — čekaný, ale ne němý.
  if (rozdil !== 0) {
    return {
      kod: 'zaokrouhleni',
      zprava: `Zaokrouhlení se liší o ${rozdil} Kč (doklad ${uProvidera.hodnota} Kč ` +
        `${uProvidera.popis}, náš podklad ${nase} Kč). V mezích, ale stojí za zápis.`,
    };
  }
  return null;
};

/**
 * Uvolní claim, ale nikdy tím nepřebije původní chybu.
 *
 * `uvolniZabrani` sahá na síť a může selhat samo. Bez tohohle obalu by se pak
 * ven dostala chyba z uvolňování místo té od providera — a ta původní, kvůli
 * které se sem vůbec došlo, by zmizela.
 */
const uvolniTise = async (store: InvoiceLinkStore, klic: string): Promise<void> => {
  try {
    await store.uvolniZabrani(klic);
  } catch {
    // Claim zůstane držený do zásahu člověka. Je to lepší než ztratit důvod.
  }
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
  meta?: { providerSubjectId?: string; varovani?: Varovani | null; rezim?: RezimVystaveni },
): Promise<{ link: InvoiceLink; pdfChyba?: Varovani }> => {
  // `pdf` se z výsledku VYHAZUJE, než se vazba uloží. Bajty patří do úložiště
  // souborů, ne do řádku v databázi — `JSON.stringify(Uint8Array)` z nich udělá
  // objekt číslovaných klíčů („{"0":37,"1":80,…}") a nafoukne záznam o stovky kB.
  const { pdf: _pdf, ...bezPdf } = result;
  const link: InvoiceLink = {
    idempotencyKey: draft.idempotencyKey,
    reservationIds: [...draft.sourceReservationIds],
    result: bezPdf,
  };
  await store.zapisVazbu(draft, bezPdf, {
    nasSoucet: roundCzk(soucetRadku(draft.lines)),
    rezim: meta?.rezim ?? 'koncept',
    providerSubjectId: meta?.providerSubjectId,
    // Rozpor kontrolního součtu se ukládá DO EVIDENCE, ne jen do HTTP odpovědi.
    // Admin zavře záložku a „KONTROLNÍ SOUČET NESEDÍ" by byl navždy pryč.
    varovani: meta?.varovani?.zprava,
  });

  if (!uloziste) return { link };

  // PDF SE NESMÍ DOTKNOUT PLATNOSTI DOKLADU. Výjimka odsud (429, výpadek sítě,
  // plné úložiště) by shodila celé vystavení — vazba je přitom už zapsaná, takže
  // příští běh by doklad podle zámku 1 přeskočil a PDF by nedobral NIKDO.
  // Doklad má číslo a platí i bez PDF (R5); tohle je dobírání, ne vystavování.
  try {
    const pdf = result.pdf ?? await stahniPdf(provider, result.providerInvoiceId, cekej, pokusu);
    if (!pdf) {
      return {
        link,
        pdfChyba: {
          kod: 'pdf',
          zprava: `PDF dokladu ${result.number || result.providerInvoiceId} se zatím generuje.`,
        },
      };
    }

    const { cesta, sha256 } = await uloziste.uloz(draft.idempotencyKey, pdf);
    await store.zapisPdf(draft.idempotencyKey, cesta, sha256);
    return { link: { ...link, pdfPath: cesta } };
  } catch (chyba) {
    // Důvod se NESMÍ spolknout: doklad je vystavený a bez PDF, což někdo musí
    // vidět. Dobrat ho pak jde přes `dobirPdf` — vystavování se tím nezdržuje.
    //
    // Cizí text (Storage, Postgres, provider) jde JEN do `interni`. Do `zprava`
    // patří naše věta: hlášky odjinud nesou názvy tabulek, cesty a vnitřnosti,
    // které v prohlížeči nemají co dělat.
    return {
      link,
      pdfChyba: {
        kod: 'pdf',
        zprava: `PDF dokladu ${result.number || result.providerInvoiceId} se nepodařilo stáhnout. ` +
          'Doklad platí i bez něj, PDF se dobere později.',
        interni: chyba instanceof Error ? chyba.message : String(chyba),
      },
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

  const { cesta, sha256 } = await pdfUloziste.uloz(link.idempotencyKey, pdf);
  await store.zapisPdf(link.idempotencyKey, cesta, sha256);
  return cesta;
};

/**
 * Odešle doklad odběrateli, pokud je zapnutý režim `odeslat`.
 *
 * Vrací text varování, nebo `null`. SELHÁNÍ ODESLÁNÍ NESMÍ SHODIT VYSTAVENÍ —
 * doklad v tu chvíli u providera existuje a má číslo. Kdyby se odsud vyhodila
 * výjimka, `vystavDoklad` by v `catch` uvolnil claim a příští běh by se pokusil
 * vystavit doklad znovu; zámek 2 by ho sice našel, ale celá cesta by se
 * zbytečně tvářila jako neúspěch.
 *
 * Podruhé se neodesílá: `oznacOdeslano` vrátí `false`, když už datum odeslání
 * je, a e-mail se v tom případě vůbec nevolá.
 */
const odesliPokudMa = async (
  provider: InvoiceProvider,
  store: InvoiceLinkStore,
  draft: InvoiceDraft,
  result: InvoiceResult,
  rezim: RezimVystaveni,
): Promise<Varovani | null> => {
  if (rezim !== 'odeslat') return null;

  if (!provider.sendInvoice) {
    return {
      kod: 'odeslani',
      zprava: `Režim „odeslat" je zapnutý, ale provider odesílání neumí — ` +
        `doklad ${result.number} zůstal neodeslaný.`,
    };
  }

  // ZNAČKA SE STAVÍ PŘED ODESLÁNÍM, ne po něm. Opačné pořadí by pojistku
  // „podruhé se neposílá" vyřadilo úplně: pád mezi odesláním a zápisem by nechal
  // doklad neoznačený a příští běh by e-mail poslal znovu. Dvakrát doručená
  // faktura je pro klienta stejně matoucí jako dvakrát vystavená.
  //
  // Cena je opačný okraj: když odeslání selže, doklad zůstane označený jako
  // odeslaný, ačkoli nedorazil. Je to ale HLASITÉ — varování níž říká rovnou,
  // že se má poslat ručně z Fakturoidu. Tichá duplicita by byla horší než
  // hlasitý neúspěch.
  if (!await store.oznacOdeslano(draft.idempotencyKey)) {
    return null;   // už byl odeslaný dřív — nic se neděje
  }

  try {
    await provider.sendInvoice(result.providerInvoiceId, { email: draft.party.email });
    return null;
  } catch (chyba) {
    return {
      kod: 'odeslani',
      zprava: `Doklad ${result.number} se vystavil, ale NEODESLAL. ` +
        'Je označený jako odeslaný, takže se automaticky nezopakuje — ' +
        'pošlete ho prosím ručně z Fakturoidu.',
      interni: chyba instanceof Error ? chyba.message : String(chyba),
    };
  }
};
