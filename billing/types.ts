// Smlouva mezi jádrem a fakturačními providery.
//
// PROČ TENHLE SOUBOR EXISTUJE: Fakturoid je první provider, ne jediný. Až přijde
// iDoklad (nebo se hala rozhodne fakturovat interně), přibude nová implementace
// `InvoiceProvider` a jádro se nesmí změnit ani o řádek. Všechno, co je specifické
// pro Fakturoid — `custom_id`, `registration_no`, OAuth, tvar JSONu — žije až
// v `providers/fakturoid/`, nikdy tady.
//
// PROČ JE `billing/` MIMO `src/`: do `src/` sahá Vite bundle. `FAKTUROID_CLIENT_SECRET`
// nesmí mít ani teoretickou cestu do prohlížeče, a mimo `src/` se na tenhle kód
// nedostane ani `@/` alias — takže ho do komponenty nejde omylem importovat.
//
// DPH ZÁMĚRNĚ NENÍ. Hala je neplátce (`billing_settings.vat_mode = 'neplatce'`,
// rozhodnutí PM) a řádky se posílají bez `vat_rate`. Až padne otázka Q7 (agregace
// po řádcích vs. z mezisoučtu za sazbu — patří účetní klienta), přibude sem pole
// vědomě a s rozhodnutím za zády. Prázdné místo je lepší než hádaná nula.

/**
 * Typ dokladu.
 *
 * `commercial_event` — firma, jedna komerční akce, fakturuje se po jejím skončení.
 * `club_monthly`     — klub, měsíční souhrn, řádek = jedna rezervace.
 */
export type InvoiceType = 'commercial_event' | 'club_monthly';

/** Odběratel. Plní se z našich dat, včetně toho, co přišlo z ARESu. */
export interface InvoiceParty {
  /** Naše interní `subjects.id` (uuid). Provider si podle něj drží párování. */
  ourSubjectId: string;
  name: string;
  /** IČO. U spolku i firmy osm číslic; u fyzické osoby bez IČO zůstane prázdné. */
  registrationNo?: string;
  /** DIČ. Posílá se JEN u plátce DPH — u neplátce nemá na dokladu co dělat. */
  vatNo?: string;
  street?: string;
  city?: string;
  zip?: string;
  /** ISO kód země, default „CZ". */
  country?: string;
}

/**
 * Řádek dokladu.
 *
 * `quantity` × `unitPrice` musí dát přesně naši částku za rezervaci. Drží to
 * schéma na naší straně (`invoice_items_radek_sedi`: `line_total = round(hodiny × sazba, 2)`)
 * a trigger, který `amount` i `corrected_amount` počítá týmž `round(…, 2)`.
 * Kdyby se sem posílala předpočítaná částka místo sazby, provider by si ji
 * přepočítal po svém a kontrolní součet by se rozešel.
 */
export interface InvoiceLine {
  name: string;
  /** Hodiny — po korekci, pokud nějaká je. Vždy > 0. */
  quantity: number;
  /** Jednotka. U pronájmu ledu vždy „h". */
  unitName: string;
  /** Sazba Kč/h ze snapshotu rezervace (`reservations.rate_per_hour`), ne dopočet z částky. */
  unitPrice: number;
}

/** Doklad připravený k odeslání. Provider ho přeloží do svého tvaru. */
export interface InvoiceDraft {
  type: InvoiceType;
  /**
   * Klíč idempotence. Druhé volání se stejným klíčem NESMÍ vystavit druhý doklad.
   * Tvar viz `idempotency.ts` — `akce-{eventId}` / `klub-{clubId}-{YYYYMM}`.
   */
  idempotencyKey: string;
  party: InvoiceParty;
  lines: InvoiceLine[];
  /** Splatnost ve dnech. Default 14 (`BILLING_DUE_DAYS`, rozhodnutí PM). */
  dueInDays?: number;
  /** Datum vystavení `RRRR-MM-DD` v pražském čase. Nevyplněné = provider dosadí dnešek. */
  issuedOn?: string;
  /** Rezervace, ze kterých doklad vznikl. Po vystavení se na ně zapíše vazba. */
  sourceReservationIds: string[];
}

/** Stav dokladu tak, jak ho hlásí provider. Úmyslně volný — každý ho pojmenuje po svém. */
export type InvoiceStatus = string;

/** Výsledek vystavení. `number` a `variableSymbol` přiděluje PROVIDER, ne my. */
export interface InvoiceResult {
  providerInvoiceId: string;
  number: string;
  variableSymbol: string;
  publicUrl?: string;
  status: InvoiceStatus;
  /**
   * Celková částka, jak ji spočítal PROVIDER.
   *
   * Není to duplicita našeho součtu — je to druhá strana kontrolního součtu.
   * Provider si zaokrouhluje po svém a jeho pravidlo nemusí být naše
   * `round(round(v, 2), 0)` (rozhodnutí R3), takže rozdíl může být do 0,50 Kč
   * na doklad. Bez tohohle pole by se ta odchylka nedala změřit, jen tušit.
   */
  providerTotal?: number;
  /**
   * Řádky, jak je má doklad U PROVIDERA.
   *
   * Bez nich se nedá bezpečně poznat, JESTLI nalezený doklad pokrývá dnešní
   * podklad. Porovnání pouhých částek tu nestačí: klub trénuje týdně za stejnou
   * sazbu, takže doklad na rezervaci „a" a doklad na rezervaci „b" mají tutéž
   * částku — a „b" by se označila za vyfakturovanou, ačkoli je na dokladu „a".
   */
  providerLines?: InvoiceLine[];
  /** PDF, pokud už bylo hotové v okamžiku vystavení. Jinak se dotáhne `downloadPdf`. */
  pdf?: Uint8Array;
}

/**
 * Fakturační provider.
 *
 * Implementace nesmí nic logovat s tajemstvími a nesmí si sama rozhodovat, CO se
 * fakturuje — to je věc mapovací vrstvy a databáze. Provider jen přeloží a odešle.
 */
export interface InvoiceProvider {
  /** Najde odběratele podle našeho `ourSubjectId`, nebo ho založí. */
  ensureSubject(party: InvoiceParty): Promise<{ providerSubjectId: string }>;
  /** Hledá už existující doklad podle klíče idempotence. `null` = žádný není. */
  findExistingInvoice(idempotencyKey: string): Promise<InvoiceResult | null>;
  createInvoice(draft: InvoiceDraft, providerSubjectId: string): Promise<InvoiceResult>;
  /** `null` znamená „ještě se generuje" (u Fakturoidu HTTP 204), ne chybu. */
  downloadPdf(providerInvoiceId: string): Promise<Uint8Array | null>;
}
