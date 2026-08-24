// HTTP vrstva pro Fakturoid — hlavičky, rate limit, překlad chyb.
//
// PROČ VLASTNÍ TYPY MÍSTO `Response`/`RequestInit`: `billing/` se typuje pod
// `tsconfig.node.json`, kde není DOM lib — a přidávat ji kvůli serverové vrstvě
// by znamenalo vpustit sem `window` a `document`. Vlastní minimální rozhraní je
// navíc strukturálně kompatibilní s `globalThis.fetch` v Denu i v Node, takže
// se `fetch` dá injektovat a testovat bez sítě.

import {
  BillingAuthError, BillingNetworkError, BillingProviderError, BillingRateLimitError,
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
  // ZÁMĚRNĚ TOLERANTNÍ. Přesný tvar hlaviček u Fakturoidu v3 NENÍ ověřený proti
  // živé odpovědi (viz billing/README.md, „Otevřené věci") a čte se víc podob:
  // `Retry-After: 30`, `X-RateLimit-Reset: 30` i `X-RateLimit: …; t=30`.
  // Když nesedí ani jedna, spadne se na exponenciální backoff — pořád lepší než
  // bušit dál, protože další požadavky okno jen prodlužují.
  const kandidati = [
    odpoved.headers.get('Retry-After'),
    odpoved.headers.get('X-RateLimit-Reset'),
    // Parametrický tvar: z „limit=100; remaining=0; t=42" vytáhne 42.
    /(?:^|[;,\s])t\s*=\s*(\d+)/.exec(odpoved.headers.get('X-RateLimit') ?? '')?.[1],
  ];

  for (const kandidat of kandidati) {
    const vteriny = Number((kandidat ?? '').trim());
    // Strop 60 s: rozbitá hlavička („9999") nesmí uspat Edge funkci na čtvrt hodiny.
    if (Number.isFinite(vteriny) && vteriny > 0) return Math.min(vteriny * 1000, 60_000);
  }
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
 *
 * PROČ NE REGEXEM: `"[^"]*"` neumí escapovanou uvozovku, takže na názvu
 * `Firma \"ABC\" s.r.o.` (a ty z ARESu reálně chodí) začerní jen první půlku,
 * do logu pustí `ABC" s.r.o.` a tělo přestane být validní JSON. Nekvotované
 * hodnoty (`{"zip":70800}`) by minul úplně. Proto se tělo PARSUJE a prochází
 * rekurzivně — a když se rozparsovat nedá, do chyby se nedává vůbec: neznámý
 * tvar nejde spolehlivě začernit.
 */
const CITLIVE_KLICE = new Set([
  'registration_no', 'vat_no', 'street', 'city', 'zip', 'name', 'full_name',
  'email', 'phone', 'access_token', 'refresh_token', 'client_secret', 'client_id',
]);

const SKRYTO = '‹skryto›';

const zacerni = (uzel: unknown): unknown => {
  if (Array.isArray(uzel)) return uzel.map(zacerni);
  if (uzel !== null && typeof uzel === 'object') {
    return Object.fromEntries(
      Object.entries(uzel as Record<string, unknown>).map(
        ([klic, hodnota]) => [klic, CITLIVE_KLICE.has(klic) ? SKRYTO : zacerni(hodnota)],
      ),
    );
  }
  return uzel;
};

export const zkrat = (telo: string): string | undefined => {
  let vycistene: string;
  try {
    vycistene = JSON.stringify(zacerni(JSON.parse(telo)));
  } catch {
    // Tělo, které není JSON (HTML chybovka, prostý text), se nedá spolehlivě
    // začernit. Radši nic než náhodný výřez cizích dat v logu.
    return undefined;
  }
  return vycistene.length > 300 ? `${vycistene.slice(0, 300)}…` : vycistene;
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
  if (!Number.isInteger(pokusu) || pokusu < 1) {
    throw new BillingProviderError(`Počet pokusů musí být aspoň 1 (dostal jsem ${pokusu}).`, 0);
  }
  const opakovatelny = smiSeOpakovat(init, volby);

  let posledni: HttpOdpoved | null = null;
  let pokusuSkutecne = 0;

  for (let pokus = 1; pokus <= pokusu; pokus++) {
    pokusuSkutecne = pokus;
    let odpoved: HttpOdpoved;
    try {
      odpoved = await volby.fetch(url, {
        ...init,
        headers: {
          // User-Agent je u Fakturoidu POVINNÝ. Bez něj přijde 400 a vypadá to
          // jako chyba v datech, ne v hlavičkách.
          'User-Agent': volby.userAgent,
          Accept: 'application/json',
          ...init.headers,
        },
      });
    } catch (chyba) {
      // ODMÍTNUTÝ FETCH NENÍ ODPOVĚĎ. `ECONNRESET` nebo DNS výpadek doteď neprošel
      // klasifikací vůbec a vyletěl jako `TypeError`, takže `lzeOpakovat` řekla
      // „neopakovat" — a přechodný výpadek sítě znamenal trvale selhaný doklad.
      if (opakovatelny && pokus < pokusu) {
        await cekej(BACKOFF_MS * 2 ** (pokus - 1));
        continue;
      }
      // U ZÁPISU je tohle nejhorší možný stav: nevíme, jestli požadavek doletěl.
      // Příznak nese informaci dál, ať ho fronta v PR 4 nezopakuje napřímo.
      throw new BillingNetworkError(
        `Spojení s Fakturoidem selhalo po ${pokus} ${pokus === 1 ? 'pokusu' : 'pokusech'}.`,
        { cause: chyba, zapisNejisty: !opakovatelny },
      );
    }
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
      if (pokus === pokusu || !opakovatelny) break;
      await cekej(BACKOFF_MS * 2 ** (pokus - 1));
      continue;
    }

    return odpoved;
  }

  const odpoved = posledni!;
  // Počet se bere ze SKUTEČNĚ provedených pokusů. Hláška „i po 4 pokusech"
  // u jediného requestu (neopakovatelný POST) by posílala ladění špatným směrem.
  throw new BillingProviderError(
    `Fakturoid odpověděl ${odpoved.status}${pokusuSkutecne > 1 ? ` i po ${pokusuSkutecne} pokusech` : ''}.`,
    odpoved.status,
    zkrat(await odpoved.text().catch(() => '')),
    !opakovatelny,
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
