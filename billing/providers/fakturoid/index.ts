// FakturoidProvider — první implementace `InvoiceProvider`.
//
// CO SE ZÁMĚRNĚ NEPOSÍLÁ:
//   • `number` ani `variable_symbol` — přiděluje je Fakturoid. Poslat je znamená
//     vzít si zpátky odpovědnost za číselnou řadu, což je přesně to, čemu se
//     napojením vyhýbáme.
//   • `vat_rate` na řádku — hala je neplátce. Nula by nebyla totéž co „mimo režim“.
//
// PÁROVÁNÍ PŘES `custom_id`: u odběratele `subj-{ourSubjectId}`, u dokladu náš
// klíč idempotence. Díky tomu se dá po ztracené odpovědi zjistit, jestli doklad
// vznikl, aniž bychom si pamatovali cizí id.

import type {
  InvoiceDraft, InvoiceLine, InvoiceParty, InvoiceProvider, InvoiceResult,
} from '../../types.ts';
import { BillingProviderError, BillingValidationError } from '../../errors.ts';
import { TokenCache } from './auth.ts';
import { zakladUrl, type FakturoidConfig } from './config.ts';
import {
  jakoJson, pozadavek, smiSeOpakovat, type FetchFn, type HttpOdpoved, type HttpPozadavek,
} from './http.ts';

/** Tvar odběratele, jak ho vrací Fakturoid. Jen pole, která používáme. */
interface FSubject {
  id: number;
  custom_id: string | null;
}

/** Tvar dokladu, jak ho vrací Fakturoid. */
interface FInvoice {
  id: number;
  number: string | null;
  variable_symbol: string | null;
  public_html_url: string | null;
  status: string | null;
  custom_id: string | null;
  /** Fakturoid posílá částky jako řetězce („3752.00"). */
  total: string | number | null;
  lines: FLine[] | null;
}

/** Řádek dokladu u Fakturoidu. */
interface FLine {
  name: string | null;
  quantity: string | number | null;
  unit_name: string | null;
  unit_price: string | number | null;
}

/**
 * Číslo z hodnoty, kterou Fakturoid posílá jako řetězec.
 *
 * `Number()` je tu zrádné: `Number("")` je 0 (doklad na nula korun), `Number("3 752,00")`
 * je NaN — a `JSON.stringify(NaN)` je `null`, takže by ta hodnota beze stopy zmizela.
 * Co není konečné číslo, se proto vrací jako `undefined` a volající se zachová
 * opatrně, místo aby počítal s nesmyslem.
 */
const cislo = (hodnota: string | number | null | undefined): number | undefined => {
  if (hodnota === null || hodnota === undefined) return undefined;
  const text = String(hodnota).trim();
  if (text === '') return undefined;
  const n = Number(text);
  return Number.isFinite(n) ? n : undefined;
};

/** Odpověď, která měla být pole. Bez téhle kontroly by `.find` spadl na TypeError. */
const jakoPole = <T>(hodnota: unknown, cesta: string): T[] => {
  if (Array.isArray(hodnota)) return hodnota as T[];
  throw new BillingProviderError(
    `Fakturoid vrátil na ${cesta} něco jiného než seznam.`, 200,
  );
};

export interface FakturoidVolby {
  config: FakturoidConfig;
  fetch: FetchFn;
  cekej?: (ms: number) => Promise<void>;
  ted?: () => number;
  pokusu?: number;
}

/** Řádek od Fakturoidu → náš tvar. Nepřevoditelný řádek se zahodí, ne dohaduje. */
const naRadek = (l: FLine): InvoiceLine | null => {
  const quantity = cislo(l.quantity);
  const unitPrice = cislo(l.unit_price);
  if (quantity === undefined || unitPrice === undefined) return null;
  return { name: l.name ?? '', quantity, unitName: l.unit_name ?? '', unitPrice };
};

const jeRadek = (l: InvoiceLine | null): l is InvoiceLine => l !== null;

export class FakturoidProvider implements InvoiceProvider {
  // `#` pole, ne `private`. TypeScriptové `private` je jen kompilační značka —
  // za běhu zůstane enumerable vlastnost, takže `JSON.stringify(provider)` vydá
  // `config.clientSecret` a jedno `console.error('…', { provider })` v Edge funkci
  // pošle ostrý klíč do logu.
  #tokeny: TokenCache;
  #zaklad: string;
  #volby: FakturoidVolby;

  constructor(volby: FakturoidVolby) {
    this.#volby = volby;
    this.#zaklad = zakladUrl(volby.config.slug);
    this.#tokeny = new TokenCache({
      fetch: volby.fetch,
      userAgent: volby.config.userAgent,
      cekej: volby.cekej,
      pokusu: volby.pokusu,
      clientId: volby.config.clientId,
      clientSecret: volby.config.clientSecret,
      ted: volby.ted,
    });
  }

  /**
   * Volání s tokenem. Po 401 token zahodí a zkusí to JEDNOU znovu.
   *
   * Proč jednou: 401 může znamenat „token vypršel dřív, než jsme čekali“ (pak
   * druhý pokus projde), nebo „klíče jsou špatné“ (pak neprojde nikdy a další
   * pokusy jen přibližují zablokování účtu).
   */
  async #volej(cesta: string, init: HttpPozadavek = {}): Promise<HttpOdpoved> {
    const poslat = async (token: string) => pozadavek(`${this.#zaklad}${cesta}`, {
      ...init,
      headers: { ...init.headers, Authorization: `Bearer ${token}` },
    }, {
      fetch: this.#volby.fetch,
      userAgent: this.#volby.config.userAgent,
      cekej: this.#volby.cekej,
      pokusu: this.#volby.pokusu,
    });

    const odpoved = await poslat(await this.#tokeny.token());
    if (odpoved.status !== 401) return odpoved;

    this.#tokeny.zneplatni();

    // ZOPAKOVAT SE SMÍ JEN ČTENÍ. 401 sice znamená „nezpracováno", takže by POST
    // bylo teoreticky bezpečné poslat znovu — ale je to tichý obchvat pravidla
    // „POST se neopakuje" a odesílal by druhé identické tělo. U dokladu se
    // nevyplácí spoléhat na to, že druhá strana odmítla dřív, než něco založila;
    // neúspěch tady vyřeší zámek 2 v příštím běhu.
    if (!smiSeOpakovat(init, { fetch: this.#volby.fetch, userAgent: this.#volby.config.userAgent })) {
      return odpoved;
    }
    return poslat(await this.#tokeny.token());
  }

  async #json<T>(cesta: string, init?: HttpPozadavek): Promise<T> {
    return jakoJson<T>(await this.#volej(cesta, init));
  }

  /** Pojistka pro případ, že instance přesto skončí v `JSON.stringify` nebo v logu. */
  toJSON(): string {
    return '[FakturoidProvider — obsah je záměrně neserializovatelný]';
  }

  // ---------------------------------------------------------------------------
  // Odběratel
  // ---------------------------------------------------------------------------

  async ensureSubject(party: InvoiceParty): Promise<{ providerSubjectId: string }> {
    const customId = `subj-${party.ourSubjectId}`;

    const nalezene = jakoPole<FSubject>(await this.#json<unknown>(
      `/subjects.json?custom_id=${encodeURIComponent(customId)}`,
    ), '/subjects.json');

    // Fakturoid filtruje serverově, ale spoléhat se na to naslepo by znamenalo
    // poslat doklad cizímu odběrateli, kdyby se chování filtru změnilo.
    const existujici = nalezene.find((s) => s.custom_id === customId);
    if (existujici) return { providerSubjectId: String(existujici.id) };

    // Neprázdná odpověď, ve které NENÍ hledané custom_id, znamená, že filtr
    // neúčinkuje. Založit dalšího odběratele by v takové situaci znamenalo
    // zakládat duplicitu při každém běhu — radši hlasitě stát.
    if (nalezene.length > 0) {
      throw new BillingProviderError(
        `Filtr custom_id u /subjects.json nefunguje: dostal jsem ${nalezene.length} odběratelů, ` +
        `ale žádný nemá custom_id „${customId}“. Nezakládám dalšího.`, 200,
      );
    }

    const vytvoreny = await this.#json<FSubject>('/subjects.json', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(this.#telSubjektu(party, customId)),
    });

    if (!vytvoreny?.id) {
      throw new BillingProviderError('Fakturoid nevrátil id nově založeného odběratele.', 200);
    }
    return { providerSubjectId: String(vytvoreny.id) };
  }

  #telSubjektu(party: InvoiceParty, customId: string): Record<string, unknown> {
    const telo: Record<string, unknown> = {
      name: party.name,
      custom_id: customId,
      country: party.country ?? 'CZ',
    };
    // Prázdná pole se neposílají vůbec — `""` by Fakturoid uložil jako prázdnou
    // hodnotu a přepsal tím to, co tam případně vyplnil člověk.
    if (party.registrationNo) telo.registration_no = party.registrationNo;
    if (party.vatNo) telo.vat_no = party.vatNo;
    if (party.street) telo.street = party.street;
    if (party.city) telo.city = party.city;
    if (party.zip) telo.zip = party.zip;
    return telo;
  }

  // ---------------------------------------------------------------------------
  // Doklad
  // ---------------------------------------------------------------------------

  async findExistingInvoice(idempotencyKey: string): Promise<InvoiceResult | null> {
    const nalezene = jakoPole<FInvoice>(await this.#json<unknown>(
      `/invoices.json?custom_id=${encodeURIComponent(idempotencyKey)}`,
    ), '/invoices.json');
    const doklad = nalezene.find((f) => f.custom_id === idempotencyKey);
    if (doklad) return this.#naVysledek(doklad);

    // TICHÁ DEGRADACE JE TU NEBEZPEČNĚJŠÍ NEŽ CHYBA. Kdyby Fakturoid přestal
    // `custom_id` filtrovat serverově, vrátil by první stránku cizích dokladů,
    // `.find` by nenašel nic, my bychom vrátili `null` — a zámek 2 by tiše
    // přestal fungovat. Duplicitní doklad by se objevil až u klienta.
    if (nalezene.length > 0) {
      throw new BillingProviderError(
        `Filtr custom_id u /invoices.json nefunguje: dostal jsem ${nalezene.length} dokladů, ` +
        `ale žádný nemá custom_id „${idempotencyKey}“. Zámek idempotence tím přestává platit.`, 200,
      );
    }
    return null;
  }

  async createInvoice(draft: InvoiceDraft, providerSubjectId: string): Promise<InvoiceResult> {
    const subjectId = Number(providerSubjectId);
    if (!Number.isInteger(subjectId) || subjectId <= 0) {
      throw new BillingValidationError(
        `Neplatné id odběratele u Fakturoidu: „${providerSubjectId}“.`, 'providerSubjectId',
      );
    }

    const telo: Record<string, unknown> = {
      subject_id: subjectId,
      custom_id: draft.idempotencyKey,
      due: draft.dueInDays ?? this.#volby.config.dueDays,
      lines: draft.lines.map((l) => ({
        name: l.name,
        quantity: l.quantity,
        unit_name: l.unitName,
        unit_price: l.unitPrice,
        // `vat_rate` tu ZÁMĚRNĚ není — u neplátce není nulová sazba totéž
        // co „mimo režim DPH“ a doklad by to popsal špatně.
      })),
    };
    if (draft.issuedOn) telo.issued_on = draft.issuedOn;

    const doklad = await this.#json<FInvoice>('/invoices.json', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(telo),
    });

    if (!doklad?.id) {
      throw new BillingProviderError('Fakturoid nevrátil id vytvořeného dokladu.', 200);
    }
    return this.#naVysledek(doklad);
  }

  #naVysledek(f: FInvoice): InvoiceResult {
    return {
      providerInvoiceId: String(f.id),
      // Doklad bez čísla by neměl vzniknout, ale kdyby přišel, je lepší prázdný
      // řetězec než „undefined“ vytištěné na faktuře.
      number: f.number ?? '',
      variableSymbol: f.variable_symbol ?? '',
      ...(f.public_html_url ? { publicUrl: f.public_html_url } : {}),
      status: f.status ?? 'unknown',
      ...(cislo(f.total) !== undefined ? { providerTotal: cislo(f.total) } : {}),
      ...(Array.isArray(f.lines) ? { providerLines: f.lines.map(naRadek).filter(jeRadek) } : {}),
    };
  }

  // ---------------------------------------------------------------------------
  // PDF
  // ---------------------------------------------------------------------------

  /**
   * `null` znamená „ještě se generuje“ (HTTP 204), ne chybu. Opakování řeší
   * `stahniPdf` v `billing/pipeline.ts`, ne tahle metoda — provider jen odpovídá.
   */
  async downloadPdf(providerInvoiceId: string): Promise<Uint8Array | null> {
    const odpoved = await this.#volej(
      `/invoices/${encodeURIComponent(providerInvoiceId)}/download.pdf`,
      { headers: { Accept: 'application/pdf' } },
    );

    if (odpoved.status === 204) return null;
    if (odpoved.status !== 200) {
      throw new BillingProviderError(
        `Stažení PDF dokladu ${providerInvoiceId} selhalo (${odpoved.status}).`,
        odpoved.status,
      );
    }
    return new Uint8Array(await odpoved.arrayBuffer());
  }
}
