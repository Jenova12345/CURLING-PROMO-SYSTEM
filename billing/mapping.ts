// Mapovací vrstva: naše rezervace → `InvoiceDraft`.
//
// ZÁSADNÍ PRAVIDLO, KTERÉ TENHLE SOUBOR DRŽÍ: mapování si NEVYMÝŠLÍ vlastní filtr
// „co je zpoplatněné". Jediná definice v repu je `public.fakturovatelne_rezervace`
// a používá ji jak obě RPC, tak kontrolní součet `billing_reconcile`. Kdyby si
// tahle vrstva opsala vlastní podmínku (třeba „vynech údržbu"), porovnával by
// kontrolní součet dvě různá čísla a vypadalo by to jako chyba ve fakturaci —
// přesně před tím varuje komentář v `20260813140000_faktury_rpc.sql`.
//
// Interní tréninky a údržba ledu tím pádem vypadnou tam, kde vypadávají dnes:
// nemají `subject_id`, takže je `fakturovatelne_rezervace` vůbec nevrátí.
// Tady se jen mapuje to, co dorazilo.
//
// PROČ SE POSÍLÁ SAZBA A HODINY, NE HOTOVÁ ČÁSTKA: provider si `quantity × unitPrice`
// přepočítá sám. Naše `castka` je `round(hodiny × sazba, 2)` (trigger v `booking_core`
// i CHECK `invoice_items_radek_sedi`), takže obojí musí vyjít nastejno — a `overRadek`
// níž to ověřuje, ať se případný rozchod ozve u nás, ne až na dokladu u klienta.

import { sumKc, toSetiny, zeSetin } from '../src/lib/money.ts';
import { BillingValidationError } from './errors.ts';
import { klicAkce, klicKlubu } from './idempotency.ts';
import { cas, datumProApi, denMesic, rozsahCasu } from './format.ts';
import type { InvoiceDraft, InvoiceLine, InvoiceParty } from './types.ts';

/** Splatnost, když ji volající neurčí. Rozhodnutí PM: 14 dní (`BILLING_DUE_DAYS`). */
export const SPLATNOST_DNI = 14;

/**
 * Sazba DPH za pronájem ledové plochy, v PROCENTECH.
 *
 * 12 % je snížená sazba. Použití sportovních zařízení do ní patří (příloha č. 2
 * ZDPH); od konsolidace k 1. 1. 2024 jsou obě dřívější snížené sazby sloučené
 * do jedné dvanáctiprocentní.
 *
 * PROČ KONSTANTA A NE POLOŽKA V NASTAVENÍ: sazba se nemění provozním
 * rozhodnutím, ale zákonem. Změna proto má být commit, který projde branami
 * a je vidět v historii — ne hodnota, kterou někdo přepíše ve formuláři
 * a nikdo se to nedozví. Až se sazba změní, mění se i doklady vystavené od
 * účinnosti, takže to stejně chce vědomý zásah.
 *
 * ⚠️ PLATÍ JEN PRO LED. Až přibudou volitelné položky (salonek, občerstvení —
 * požadavek B z ETAPA3-POZADAVKY), budou mít sazbu vlastní: občerstvení není
 * sportovní služba. Proto se konstanta jmenuje `LED`, ne `SAZBA_DPH`.
 */
export const SAZBA_DPH_LED = 12;

/** Jednotka na řádku. Pronájem ledu se účtuje po hodinách, vždy. */
export const JEDNOTKA = 'h';

/**
 * Rezervace k fakturaci — tvar 1:1 s výstupem `public.fakturovatelne_rezervace`.
 *
 * `hodiny` a `castka` už mají v sobě zanesenou admin korekci (`COALESCE(corrected_*, *)`),
 * protože to tak dělá ta funkce. Nesmí se to tady dělat podruhé ani jinak: „Kdo kolik
 * dluží" (`useDues`) používá týž fallback a kontrolní součet obě strany porovnává.
 */
export interface BillableReservation {
  id: string;
  /** ISO timestamptz. */
  start_at: string;
  end_at: string;
  sheet_name: string | null;
  event_title: string | null;
  hodiny: number;
  sazba: number;
  castka: number;
  /** Volitelné — kdo objednal. Dnešní RPC ho nevrací, doplní se, až bude potřeba. */
  objednal?: string | null;
}

/** Odběratel z `public.subjects`. */
export interface SubjectForBilling {
  id: string;
  name: string;
  ico: string | null;
  dic: string | null;
  /** Jeden textový řádek — ARES vrací `sidlo.textovaAdresa`, nic strukturovaného. */
  address: string | null;
  /**
   * Volitelný — `public.subjects` sloupec pro e-mail dnes NEMÁ.
   * Je tu proto, aby se dal doplnit jednou migrací, až bude potřeba automatické
   * odesílání; do té doby zůstává `undefined` a doklad rozesílá člověk.
   */
  email?: string | null;
}

/**
 * Subjekt → odběratel u providera.
 *
 * ADRESA (rozhodnutí D3, interim): `subjects.address` je jeden textový řádek, kdežto
 * Fakturoid chce ulici, město a PSČ zvlášť. Celý řetězec se proto mapuje do `street`
 * a `city`/`zip` zůstávají prázdné. Rozparsovat český adresní řádek regulárem je
 * spolehlivé asi tak do prvního „č. p. 12/3a, Ostrava-Poruba" — radši prázdné pole
 * než tiše špatné. Follow-up: rozšířit `ares-lookup`, ať si drží `nazevUlice`,
 * `nazevObce` a `psc` z ARESu (viz `billing/README.md`, sekce Follow-up).
 *
 * DIČ ODBĚRATELE se posílá JEN u plátce DPH a jen když ho subjekt má; u spolku
 * bez registrace k dani prostě není a to je běžný stav, ne chyba.
 *
 * ⚠️ ROZHODUJE O TOM `IS_VAT_PAYER`, NE `billing_settings.vat_mode`. To druhé
 * řídí interní engine (PDF dokladu) a je to samostatné nastavení téže věci —
 * viz `billing/README.md`, sekce o dvou zdrojích pravdy. Dřívější znění téhle
 * poznámky ukazovalo na `vat_mode` a tvrdilo, že hala je neplátce; obojí je od
 * přechodu na plátce nepravda.
 */
export const mapujSubjekt = (
  subjekt: SubjectForBilling,
  volby: { jePlatceDph: boolean },
): InvoiceParty => {
  const nazev = (subjekt.name ?? '').trim();
  if (!nazev) {
    throw new BillingValidationError(
      `Subjekt ${subjekt.id} nemá název — doklad bez odběratele nejde vystavit.`, 'name',
    );
  }

  const party: InvoiceParty = {
    ourSubjectId: subjekt.id,
    name: nazev,
    country: 'CZ',
  };

  const ico = (subjekt.ico ?? '').trim();
  if (ico) party.registrationNo = ico;

  const dic = (subjekt.dic ?? '').trim();
  if (volby.jePlatceDph && dic) party.vatNo = dic;

  const adresa = (subjekt.address ?? '').trim();
  if (adresa) party.street = adresa;

  const email = (subjekt.email ?? '').trim();
  if (email) party.email = email;

  return party;
};

/**
 * Popis řádku u komerční akce:
 *   „Pronájem ledové plochy — Dráha 1, 22.08. 18:00–20:00"
 */
export const popisAkce = (r: BillableReservation): string => {
  const draha = (r.sheet_name ?? '').trim();
  const kdy = `${denMesic(r.start_at)} ${rozsahCasu(r.start_at, r.end_at)}`;
  return draha
    ? `Pronájem ledové plochy — ${draha}, ${kdy}`
    : `Pronájem ledové plochy — ${kdy}`;
};

/**
 * Popis řádku v měsíčním souhrnu klubu:
 *   „22.08. 18:00–19:00 · Trénink přípravky"
 *
 * Za oddělovačem je název akce; když ho rezervace nemá, zkusí se „kdo objednal"
 * a teprve pak dráha. Úplně bez ocasu by měsíční doklad vypadal jako výpis časů —
 * klub podle něj má poznat, za co platí.
 */
export const popisKlubu = (r: BillableReservation): string => {
  const kdy = `${denMesic(r.start_at)} ${cas(r.start_at)}–${cas(r.end_at)}`;
  const co = [r.event_title, r.objednal, r.sheet_name]
    .map((v) => (v ?? '').trim())
    .find((v) => v.length > 0);
  return co ? `${kdy} · ${co}` : kdy;
};

/**
 * Ověří, že řádek sedí sám se sebou, ještě než opustí náš systém.
 *
 * Jsou to tytéž invarianty, jaké má schéma na `invoice_items`
 * (`hodiny > 0`, `sazba >= 0`, `line_total = round(hodiny × sazba, 2)`).
 * Provider je nezkontroluje — jen spočítá `quantity × unitPrice` a vytiskne,
 * takže rozchod by se projevil až rozdílem v kontrolním součtu, o měsíc později.
 */
const overRadek = (r: BillableReservation): void => {
  const hodiny = Number(r.hodiny);
  const sazba = Number(r.sazba);
  const castka = Number(r.castka);

  // `Number.isFinite` schválně místo `> 0`: v Postgresu je `'NaN'::numeric >= 0`
  // TRUE, takže NaN prošla kdysi úplně všemi peněžními kontrolami (viz strop sazby,
  // drift 8g). Sem se dostat nesmí — z NaN by byl doklad na „NaN Kč".
  if (!Number.isFinite(hodiny) || hodiny <= 0) {
    throw new BillingValidationError(
      `Rezervace ${r.id}: hodiny musí být kladné číslo (dostal jsem ${String(r.hodiny)}).`, 'hodiny',
    );
  }
  if (!Number.isFinite(sazba) || sazba < 0) {
    throw new BillingValidationError(
      `Rezervace ${r.id}: sazba musí být nezáporné číslo (dostal jsem ${String(r.sazba)}).`, 'sazba',
    );
  }
  if (!Number.isFinite(castka)) {
    throw new BillingValidationError(
      `Rezervace ${r.id}: částka není číslo (dostal jsem ${String(r.castka)}).`, 'castka',
    );
  }

  // round(hodiny × sazba, 2) přes haléře — tatáž kvantizace, jakou dělá `money.ts`
  // i Postgres. Porovnává se v celých haléřích, aby to nepadalo na binární zlomky.
  // (`toSetiny` sama kvantizuje na setiny, takže druhý průchod by byl no-op.)
  const ocekavano = toSetiny(hodiny * sazba);
  if (toSetiny(castka) !== ocekavano) {
    throw new BillingValidationError(
      `Rezervace ${r.id}: částka ${castka} Kč nesedí na ${hodiny} h × ${sazba} Kč/h ` +
      `(čekal jsem ${zeSetin(ocekavano)} Kč). Doklad by ukázal jinou částku než „Kdo kolik dluží".`,
      'castka',
    );
  }
};

const naRadek = (
  r: BillableReservation,
  popis: (r: BillableReservation) => string,
  jePlatceDph: boolean,
): InvoiceLine => {
  overRadek(r);
  return {
    name: popis(r),
    quantity: Number(r.hodiny),
    unitName: JEDNOTKA,
    unitPrice: Number(r.sazba),
    // U NEPLÁTCE se pole vůbec nepřidá. `vatRate: 0` by znamenalo „osvobozeno",
    // což je jiný daňový režim než „neplátce" a doklad by to popsal špatně.
    ...(jePlatceDph ? { vatRate: SAZBA_DPH_LED } : {}),
  };
};

/**
 * Tatáž rezervace dvakrát na vstupu = dvojnásobná částka na dokladu.
 *
 * Zámek 1 to nechytí — ptá se, jestli rezervace UŽ nese doklad, ne jestli je
 * v tomhle podkladu dvakrát. A `sourceReservationIds` by ji obsahovaly dvakrát,
 * takže by to prošlo i dál. Je to chyba volajícího, ale zaplatil by ji klient.
 */
const overBezDuplicit = (rezervace: readonly BillableReservation[]): void => {
  const videne = new Set<string>();
  for (const r of rezervace) {
    if (videne.has(r.id)) {
      throw new BillingValidationError(
        `Rezervace ${r.id} je v podkladu dvakrát — doklad by na ni zněl dvojnásobně.`, 'rezervace',
      );
    }
    videne.add(r.id);
  }
};

/** Rezervace jdou na doklad chronologicky; při shodě času rozhoduje id, ať je pořadí stabilní. */
const chronologicky = (a: BillableReservation, b: BillableReservation): number =>
  a.start_at === b.start_at ? a.id.localeCompare(b.id) : a.start_at.localeCompare(b.start_at);

/**
 * TYP A — komerční akce (firma, fakturuje se po skončení akce).
 *
 * Klíč idempotence je `akce-{eventId}`, ne `akce-{reservationId}`: jedna akce má
 * běžně rezervace na obě dráhy a firma má dostat JEDEN doklad (rozhodnutí D2).
 * Řádek je pak za každou rezervaci uvnitř akce.
 *
 * Vrací `null`, když po zámcích nezbyl žádný řádek — prázdný doklad se nevystavuje.
 */
export const mapujKomercniAkci = (vstup: {
  eventId: string;
  subjekt: SubjectForBilling;
  rezervace: readonly BillableReservation[];
  jePlatceDph: boolean;
  dueInDays?: number;
  issuedOn?: string | Date;
}): InvoiceDraft | null => {
  overBezDuplicit(vstup.rezervace);
  const rezervace = [...vstup.rezervace].sort(chronologicky);
  if (rezervace.length === 0) return null;

  return {
    type: 'commercial_event',
    idempotencyKey: klicAkce(vstup.eventId),
    party: mapujSubjekt(vstup.subjekt, { jePlatceDph: vstup.jePlatceDph }),
    lines: rezervace.map((r) => naRadek(r, popisAkce, vstup.jePlatceDph)),
    // KOMERČNÍ DOKLAD MÁ CENY BEZ DPH. Firma si daň odečte, takže na dokladu
    // chce vidět základ zvlášť a daň zvlášť — a komerční ceník je proto vedený
    // bez daně. U neplátce zůstává pole nevyplněné, otázka tam nedává smysl.
    ...(vstup.jePlatceDph ? { pricesIncludeVat: false } : {}),
    dueInDays: vstup.dueInDays ?? SPLATNOST_DNI,
    ...(vstup.issuedOn ? { issuedOn: datumProApi(vstup.issuedOn) } : {}),
    sourceReservationIds: rezervace.map((r) => r.id),
    eventId: vstup.eventId,
    // U akce je „období" její den — od prvního začátku po poslední konec.
    obdobiOd: datumProApi(rezervace[0].start_at),
    obdobiDo: datumProApi(rezervace[rezervace.length - 1].start_at),
  };
};

/**
 * TYP B — měsíční souhrn klubu. Řádek = jedna rezervace.
 *
 * Vrací `null`, když klub za měsíc nemá ani jednu zpoplatněnou rezervaci. Je to
 * normální stav (klub v srpnu nehrál), ne chyba — a doklad na nula korun je pro
 * účetní horší než žádný.
 */
export const mapujKlubMesicne = (vstup: {
  subjekt: SubjectForBilling;
  /** První den fakturovaného měsíce, `RRRR-MM-DD`. Z něj se bere `RRRRMM` do klíče. */
  obdobiOd: string;
  /** Konec období. Nevyplněné = poslední fakturovaná rezervace. */
  obdobiDo?: string;
  rezervace: readonly BillableReservation[];
  jePlatceDph: boolean;
  dueInDays?: number;
  issuedOn?: string | Date;
}): InvoiceDraft | null => {
  overBezDuplicit(vstup.rezervace);
  const rezervace = [...vstup.rezervace].sort(chronologicky);
  if (rezervace.length === 0) return null;

  return {
    type: 'club_monthly',
    idempotencyKey: klicKlubu(vstup.subjekt.id, vstup.obdobiOd),
    party: mapujSubjekt(vstup.subjekt, { jePlatceDph: vstup.jePlatceDph }),
    lines: rezervace.map((r) => naRadek(r, popisKlubu, vstup.jePlatceDph)),
    // KLUBOVÝ DOKLAD MÁ CENY VČETNĚ DPH. Klub vidí jedno číslo za hodinu ledu
    // a to platí; klubový ceník je vedený s daní. Tohle je jediné místo, kde se
    // klubová a komerční faktura rozcházejí v tom, CO `unitPrice` znamená —
    // sazba je u obou táž.
    ...(vstup.jePlatceDph ? { pricesIncludeVat: true } : {}),
    dueInDays: vstup.dueInDays ?? SPLATNOST_DNI,
    ...(vstup.issuedOn ? { issuedOn: datumProApi(vstup.issuedOn) } : {}),
    sourceReservationIds: rezervace.map((r) => r.id),
    obdobiOd: vstup.obdobiOd,
    obdobiDo: vstup.obdobiDo ?? datumProApi(rezervace[rezervace.length - 1].start_at),
  };
};

/**
 * Přesný součet řádků dokladu v korunách.
 *
 * Sčítá se v haléřích a NIC se průběžně nezaokrouhluje — kanonické pravidlo R3.
 * Tohle je veličina pro KONTROLNÍ SOUČET (protějšek `invoices.total`), ne částka
 * k úhradě: zaokrouhlení na koruny dělá až provider na svém dokladu.
 *
 * POD DPH SE MĚNÍ VÝZNAM, NE VÝPOČET. Funkce sečte to, co je na řádcích —
 * u klubové faktury tedy částku VČETNĚ daně, u komerční ZÁKLAD bez daně.
 * Proti provideru se to musí porovnávat like s like (`providerTotal` vs.
 * `providerSubtotal`); dělá to `zkontrolujSoucet` v `pipeline.ts`. Kdyby se
 * základ bez daně porovnal s celkovou částkou s daní, rozdíl by vyšel přesně
 * ve výši DPH a vypadal by jako chyba mapování.
 */
export const soucetRadku = (lines: readonly InvoiceLine[]): number =>
  sumKc(lines.map((l) => l.quantity * l.unitPrice));
