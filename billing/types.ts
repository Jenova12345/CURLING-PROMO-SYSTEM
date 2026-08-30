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
// DPH: OD BLOKU B JE HALA PLÁTCE. Přepíná to `IS_VAT_PAYER` v prostředí; když je
// zapnuté, řádky za led nesou `vatRate` (12 %, snížená sazba za sportovní služby)
// a doklad nese `pricesIncludeVat`. U NEPLÁTCE zůstává obojí nevyplněné — nula
// není totéž co „mimo režim DPH" a doklad by to popsal špatně.
//
// PROČ `pricesIncludeVat` A NE JEN SAZBA: klubové ceny jsou VČETNĚ DPH (klub vidí
// jedno číslo a to platí), komerční ceny jsou BEZ DPH (firma si DPH odečte).
// Je to rozdíl v tom, co znamená `unitPrice`, ne v sazbě — a rozhoduje o něm typ
// dokladu, tedy naše mapovací vrstva, ne provider.
//
// CO TO DĚLÁ S KONTROLNÍM SOUČTEM: `Σ quantity × unitPrice` je nově buď základ
// bez daně (komerční), nebo částka s daní (klubová). Porovnávat se proto musí
// LIKE S LIKE — viz `providerSubtotal` níž. Sečíst řádky bez DPH a porovnat je
// s celkovou částkou s DPH by dalo rozdíl přesně ve výši daně a vypadalo by to
// jako chyba mapování.

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
  /**
   * DIČ ODBĚRATELE. Posílá se JEN u plátce DPH a JEN když ho odběratel má —
   * tahá se z ARESu jako dosud a u spolku bez registrace k DPH prostě není.
   *
   * DIČ DODAVATELE (naše) se neposílá vůbec: bere si ho Fakturoid z nastavení
   * účtu. Poslat ho odsud by znamenalo mít ho na dvou místech a nechat je
   * rozejít se.
   */
  vatNo?: string;
  /**
   * E-mail, na který se doklad odesílá.
   *
   * ⚠️ `public.subjects` dnes sloupec pro e-mail NEMÁ, takže se sem reálně nic
   * nedostane a provider si vystačí s tím, co má u odběratele vyplněné sám.
   * Pro režim „koncept" to stačí (adresu doplní člověk), pro automatické
   * odeslání ne. Viz `billing/README.md`, sekce Otevřené věci.
   */
  email?: string;
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
  /**
   * Sazba DPH v PROCENTECH (12 = dvanáct procent), ne koeficient.
   *
   * Vyplňuje se JEN u plátce. U neplátce zůstává `undefined` — a je to schválně
   * `undefined`, ne nula: nulová sazba znamená „osvobozeno", což je něco jiného
   * než „mimo režim DPH" a na dokladu se to tiskne jinak.
   *
   * Jestli je `unitPrice` s daní, nebo bez ní, NEURČUJE tohle pole, ale
   * `InvoiceDraft.pricesIncludeVat` — sazba je u obou režimů táž.
   */
  vatRate?: number;
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
  /**
   * Jsou ceny na řádcích VČETNĚ DPH?
   *
   * `true`  — klubová faktura. Klub vidí jednu částku a tu platí; ceník klubů je
   *           vedený včetně daně.
   * `false` — komerční faktura. Firma si DPH odečte, takže na dokladu chce
   *           základ zvlášť a daň zvlášť.
   * `undefined` — neplátce, otázka nedává smysl.
   *
   * Rozhoduje o tom TYP DOKLADU, ne provider: nastavuje to mapovací vrstva
   * (`mapujKlubMesicne` / `mapujKomercniAkci`). Provider to jen přeloží do svého
   * tvaru — u Fakturoidu na `vat_price_mode`.
   */
  pricesIncludeVat?: boolean;
  /** Splatnost ve dnech. Default 14 (`BILLING_DUE_DAYS`, rozhodnutí PM). */
  dueInDays?: number;
  /** Datum vystavení `RRRR-MM-DD` v pražském čase. Nevyplněné = provider dosadí dnešek. */
  issuedOn?: string;
  /** Rezervace, ze kterých doklad vznikl. Po vystavení se na ně zapíše vazba. */
  sourceReservationIds: string[];

  // ---- Kontext dokladu (rozšíření nad původní zadání) ----------------------
  // Není to nic providerského — je to „co je tenhle doklad zač". Potřebuje to
  // naše evidence (`fakturoid_invoices`), aby šlo doklad dohledat podle akce
  // a období, a další provider by tytéž údaje chtěl taky.
  /** U komerční akce její `events.id`. */
  eventId?: string;
  /** Období, za které se fakturuje, `RRRR-MM-DD`. */
  obdobiOd?: string;
  obdobiDo?: string;
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
   * Základ daně, jak ho spočítal PROVIDER — tedy částka BEZ DPH.
   *
   * Bez tohohle pole by kontrolní součet u komerčních dokladů nešel udělat
   * poctivě: na nich jsou naše ceny bez daně, kdežto `providerTotal` je s daní,
   * takže by se strany rozešly přesně o částku DPH a vypadalo by to jako chyba
   * mapování. Porovnává se proto like s like — u komerčky proti `providerSubtotal`,
   * u klubové (ceny s daní) proti `providerTotal`.
   *
   * U neplátce jsou obě čísla stejná a je jedno, které se použije.
   */
  providerSubtotal?: number;
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

  /**
   * Odešle hotový doklad odběrateli e-mailem.
   *
   * VOLITELNÉ SCHVÁLNĚ: ne každý provider umí odesílat, a jádro musí fungovat
   * i bez toho — v režimu „koncept" se tahle metoda nezavolá vůbec.
   *
   * Selhání odeslání NESMÍ shodit vystavení: doklad v tu chvíli existuje a má
   * číslo. Volající to zachytí a vrátí jako varování.
   */
  sendInvoice?(providerInvoiceId: string, komu: { email?: string }): Promise<void>;
}
