// HTTP vrstva pro Fakturoid — hlavičky, rate limit, překlad chyb.
//
// PROČ VLASTNÍ TYPY MÍSTO `Response`/`RequestInit`: `billing/` se typuje pod
// `tsconfig.node.json`, kde není DOM lib — a přidávat ji kvůli serverové vrstvě
// by znamenalo vpustit sem `window` a `document`. Vlastní minimální rozhraní je
// navíc strukturálně kompatibilní s `globalThis.fetch` v Denu i v Node, takže
// se `fetch` dá injektovat a testovat bez sítě.

import {
  BillingAuthError, BillingProviderError, BillingRateLimitError,
} from '../../errors.ts';

export interface HttpOdpoved {
  status: number;
  headers: { get(nazev: string): string | null };
  text(): Promise<string>;
  arrayBuffer(): Promise<ArrayBuffer>;
}

export interface HttpPozadavek {
  method?: string;
  headers?: Record<string, string>;
  body?: string;
}

/** Injektovatelný `fetch`. `globalThis.fetch` tomuhle tvaru vyhovuje. */
export type FetchFn = (url: string, init?: HttpPozadavek) => Promise<HttpOdpoved>;

/** Kolikrát se zopakuje požadavek, který se opakovat smí (429, 5xx). */
export const POKUSU = 4;
/** Základ exponenciálního backoffu, ms: 500, 1000, 2000… */
export const BACKOFF_MS = 500;

const spat = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/**
 * Jak dlouho čekat po 429.
 *
 * Fakturoid posílá `X-RateLimit-Reset` (vteřiny do resetu okna). Když hlavičku
 * nepošle, použije se exponenciální backoff — čekat naslepo je pořád lepší než
 * bušit dál, protože další požadavky okno jen prodlužují.
 */
export const prodlevaPoLimitu = (odpoved: HttpOdpoved, pokus: number): number => {
  const retryAfter = odpoved.headers.get('Retry-After');
  const reset = odpoved.headers.get('X-RateLimit-Reset');
  const vteriny = Number(retryAfter ?? reset);

  // Strop 60 s: rozbitá hlavička („9999") nesmí uspat Edge funkci na čtvrt hodiny.
  if (Number.isFinite(vteriny) && vteriny > 0) return Math.min(vteriny * 1000, 60_000);
  return BACKOFF_MS * 2 ** (pokus - 1);
};

/**
 * Tělo chyby do zprávy — zkrácené a začerněné.
 *
 * PROČ ZAČERNĚNÍ: u 422 na `POST /subjects.json` Fakturoid vrací zpátky to, co
 * jsme poslali — tedy název, IČO, DIČ a sídlo odběratele. Tělo přitom končí
 * v logu Edge funkce, který podle `errors.ts` čte víc lidí než ten, kdo klíč
 * nastavoval. Diagnostická hodnota je v tom, KTERÉ pole vadí, ne jakou má
 * hodnotu — proto se klíče nechávají a hodnoty zakrývají.
 */
const CITLIVE_KLICE = [
  'registration_no', 'vat_no', 'street', 'city', 'zip', 'name',
  'access_token', 'refresh_token', 'client_secret',
];

export const zkrat = (telo: string): string => {
  let vysledek = telo;
  for (const klic of CITLIVE_KLICE) {
    // Nahrazuje jen hodnotu za klíčem, samotný klíč zůstane vidět.
    vysledek = vysledek.replace(
      new RegExp(`("${klic}"\\s*:\\s*)"[^"]*"`, 'g'),
      '$1"‹skryto›"',
    );
  }
  return vysledek.length > 300 ? `${vysledek.slice(0, 300)}…` : vysledek;
};

export interface KlientVolby {
  fetch: FetchFn;
  /** POVINNÁ hlavička. Bez ní Fakturoid odpoví 400. */
  userAgent: string;
  cekej?: (ms: number) => Promise<void>;
  pokusu?: number;
  /**
   * Smí se požadavek po 5xx zopakovat?
   *
   * Default se odvozuje z metody: GET a HEAD ano, POST NE. Viz `smiSeOpakovat` níž —
   * je to rozdíl mezi „zbytečný request" a „druhý doklad pro klienta".
   */
  opakovatNa5xx?: boolean;
}

/**
 * 5xx po POSTu se opakovat NESMÍ.
 *
 * 500 neříká „nestalo se nic" — říká „nevím, jak to dopadlo". Fakturoid mohl
 * doklad založit a teprve pak spadnout při skládání odpovědi; retry by pak
 * vystavil DRUHÝ doklad se stejným `custom_id`, protože `custom_id` u Fakturoidu
 * není unikátní klíč, jen naše značka.
 *
 * Správná cesta po selhaném POSTu je nechat ho spadnout a spolehnout se na zámek 2
 * (`findExistingInvoice`) v příštím běhu — ten doklad najde podle `custom_id`
 * a vazbu jen dorovná. Zopakovat se naopak vždycky smí 429: ten znamená
 * „odmítnuto, nezpracováno".
 */
export const smiSeOpakovat = (init: HttpPozadavek, volby: KlientVolby): boolean => {
  if (volby.opakovatNa5xx !== undefined) return volby.opakovatNa5xx;
  const metoda = (init.method ?? 'GET').toUpperCase();
  return metoda === 'GET' || metoda === 'HEAD';
};

/**
 * Jeden požadavek na Fakturoid, včetně opakování.
 *
 * Vrací syrovou odpověď — rozhodnout, co znamená 204 nebo 404, je věc volajícího:
 * u `download.pdf` je 204 „ještě se generuje", u `GET /subjects` by to byla chyba.
 * Tahle vrstva řeší jen to, co je stejné pro všechny cesty.
 */
export const pozadavek = async (
  url: string,
  init: HttpPozadavek,
  volby: KlientVolby,
): Promise<HttpOdpoved> => {
  const cekej = volby.cekej ?? spat;
  const pokusu = volby.pokusu ?? POKUSU;

  let posledni: HttpOdpoved | null = null;

  for (let pokus = 1; pokus <= pokusu; pokus++) {
    const odpoved = await volby.fetch(url, {
      ...init,
      headers: {
        // User-Agent je u Fakturoidu POVINNÝ. Bez něj přijde 400 a vypadá to
        // jako chyba v datech, ne v hlavičkách.
        'User-Agent': volby.userAgent,
        Accept: 'application/json',
        ...init.headers,
      },
    });
    posledni = odpoved;

    if (odpoved.status === 429) {
      if (pokus === pokusu) {
        throw new BillingRateLimitError(
          'Fakturoid nás přibrzdil (429) a opakování nepomohlo.',
          prodlevaPoLimitu(odpoved, pokus),
        );
      }
      await cekej(prodlevaPoLimitu(odpoved, pokus));
      continue;
    }

    // 5xx je na jejich straně a u čtení stojí za zopakování. U zápisu NE —
    // viz `smiSeOpakovat`. 4xx se neopakuje nikdy: druhý pokus se stejnými daty
    // dopadne stejně a jen spotřebuje rate limit.
    if (odpoved.status >= 500) {
      if (pokus === pokusu || !smiSeOpakovat(init, volby)) break;
      await cekej(BACKOFF_MS * 2 ** (pokus - 1));
      continue;
    }

    return odpoved;
  }

  const odpoved = posledni!;
  throw new BillingProviderError(
    `Fakturoid odpověděl ${odpoved.status} i po ${pokusu} pokusech.`,
    odpoved.status,
    zkrat(await odpoved.text().catch(() => '')),
  );
};

/**
 * Odpověď → JSON, s překladem chybových stavů na naše typy.
 *
 * 401/403 je `BillingAuthError` (neopakovat — opakované pokusy s neplatnými
 * údaji vedou k zablokování účtu), zbytek `BillingProviderError`.
 */
export const jakoJson = async <T>(
  odpoved: HttpOdpoved,
  volby: { bezTela?: boolean } = {},
): Promise<T> => {
  if (odpoved.status === 401 || odpoved.status === 403) {
    throw new BillingAuthError(
      `Fakturoid odmítl přihlášení (${odpoved.status}). Zkontroluj FAKTUROID_CLIENT_ID a FAKTUROID_CLIENT_SECRET.`,
    );
  }
  const telo = await odpoved.text();
  // U tokenového endpointu se tělo do chyby nedává vůbec: useknutý JSON
  // `{"access_token":"tok-abc…` by do logu propašoval kus živého tokenu.
  const doChyby = (t: string) => (volby.bezTela ? undefined : zkrat(t));

  if (odpoved.status < 200 || odpoved.status >= 300) {
    throw new BillingProviderError(
      `Fakturoid odpověděl ${odpoved.status}.`, odpoved.status, doChyby(telo),
    );
  }
  try {
    return JSON.parse(telo) as T;
  } catch {
    throw new BillingProviderError(
      'Fakturoid vrátil odpověď, která není JSON.', odpoved.status, doChyby(telo),
    );
  }
};
