// OAuth 2.0 client_credentials pro Fakturoid.
//
// TOKEN PLATÍ 2 HODINY A NEMÁ REFRESH. Obnovuje se tedy prostě dalším
// client_credentials požadavkem. Cachuje se v paměti procesu — v Edge funkci to
// znamená „po dobu života instance", což je přesně tak dlouho, jak to má smysl:
// do trvalého úložiště token nepatří (je to tajemství s krátkou platností)
// a bez cache by každý doklad platil dvěma requesty místo jednoho.
//
// OBNOVUJE SE S REZERVOU, ne až po vypršení. Token, kterému zbývá pět vteřin,
// je v praxi neplatný — než požadavek doletí, expiruje, a chyba přijde uprostřed
// vystavování dokladu.

import { BillingAuthError, BillingProviderError } from '../../errors.ts';
import { jakoJson, pozadavek, type KlientVolby } from './http.ts';

/** `btoa` je v Denu i v Node ≥ 16 globální; DOM lib tu není, tak se deklaruje ručně. */
declare const btoa: (data: string) => string;

export const TOKEN_URL = 'https://app.fakturoid.cz/api/v3/oauth/token';

/** O kolik dřív se token považuje za vypršelý. */
export const REZERVA_MS = 60_000;

interface TokenOdpoved {
  access_token: string;
  token_type: string;
  expires_in: number;
}

interface UlozenyToken {
  token: string;
  /** Absolutní čas vypršení v ms. */
  platiDo: number;
}

export interface AuthVolby extends KlientVolby {
  clientId: string;
  clientSecret: string;
  /** Injektovatelný zdroj času — testy nesmí záviset na reálných hodinách. */
  ted?: () => number;
}

/**
 * Basic hlavička z client_id a client_secret.
 *
 * KONTROLUJE SE TISKNUTELNÉ ASCII, ne „mimo Latin-1“. Dřívější verze pouštěla
 * nezlomitelný mezerník (U+00A0) — ten do Latin-1 patří, takže by prošel, ačkoli
 * je to přesně ten neviditelný znak, který se přenese při kopírování z webu.
 * Přihlášení by pak selhalo na 401 a vypadalo by to jako špatný klíč.
 *
 * Přihlašovací údaje OAuth jsou vždycky tisknutelné ASCII, takže tohle zúžení
 * nic legitimního neodmítne.
 */
export const basicHlavicka = (clientId: string, clientSecret: string): string => {
  const dvojice = `${clientId}:${clientSecret}`;
  if (/[^\x21-\x7E:]/.test(dvojice)) {
    throw new BillingAuthError(
      'FAKTUROID_CLIENT_ID nebo FAKTUROID_CLIENT_SECRET obsahuje jiný znak než tisknutelné ASCII — ' +
      'nejspíš se při kopírování přenesl neviditelný znak (mezera, nezlomitelný mezerník, nový řádek). ' +
      'Hodnotu sem záměrně nevypisuju.',
    );
  }
  return `Basic ${btoa(dvojice)}`;
};

/**
 * Držák tokenu.
 *
 * Jedna instance na provider. Souběžné požadavky sdílí jeden rozpracovaný
 * příslib (`rozpracovany`), takže deset paralelních dokladů si nevyžádá deset
 * tokenů — Fakturoid by to počítal do rate limitu.
 */
export class TokenCache {
  // `#` POLE, NE `private`. TypeScriptové `private` je jen kompilační značka —
  // za běhu je to obyčejná enumerable vlastnost, takže `JSON.stringify(cache)`
  // vydá živý access_token a `console.error('…', { cache })` ho pošle do logu
  // Edge funkce. `#` pole jsou skutečně soukromá: nevidí je ani `JSON.stringify`,
  // ani `Object.keys`, ani `util.inspect`.
  #ulozeny: UlozenyToken | null = null;
  #rozpracovany: Promise<string> | null = null;
  #volby: AuthVolby;

  constructor(volby: AuthVolby) {
    this.#volby = volby;
  }

  get #ted(): number {
    return (this.#volby.ted ?? Date.now)();
  }

  /** Vrátí platný token — z cache, nebo si o nový řekne. */
  async token(): Promise<string> {
    if (this.#ulozeny && this.#ted < this.#ulozeny.platiDo) return this.#ulozeny.token;
    if (this.#rozpracovany) return this.#rozpracovany;

    this.#rozpracovany = this.#obnov().finally(() => { this.#rozpracovany = null; });
    return this.#rozpracovany;
  }

  /**
   * Zahodí token — volá se po 401, ať se další pokus nevydá se stejným.
   *
   * Musí zahodit i ROZPRACOVANOU obnovu. Bez toho by `token()` hned nato vrátil
   * příslib, který právě dobíhá s TÝMŽ tokenem, retry po 401 by odešel se stejnou
   * hlavičkou a skončil hláškou „zkontroluj klíče" — u klíčů, které jsou v pořádku.
   */
  zneplatni(): void {
    this.#ulozeny = null;
    this.#rozpracovany = null;
  }

  /** Pojistka pro případ, že někdo instanci přesto předá do `JSON.stringify`. */
  toJSON(): string {
    return '[TokenCache — obsah je záměrně neserializovatelný]';
  }

  async #obnov(): Promise<string> {
    const odpoved = await pozadavek(TOKEN_URL, {
      method: 'POST',
      headers: {
        Authorization: basicHlavicka(this.#volby.clientId, this.#volby.clientSecret),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ grant_type: 'client_credentials' }),
      // Tenhle POST se opakovat SMÍ: vydání dalšího tokenu nic nezakládá ani
      // neúčtuje. Výjimka z pravidla „POST se neopakuje", a proto explicitně.
    }, { ...this.#volby, opakovatNa5xx: true });

    // `bezTela: true` — useknuté tělo tokenové odpovědi by mohlo skončit
    // v `BillingProviderError.telo` jako `{"access_token":"tok-abc…`, tedy
    // s částečným tokenem v logu.
    const data = await jakoJson<TokenOdpoved>(odpoved, { bezTela: true });
    if (!data.access_token) {
      throw new BillingProviderError(
        'Fakturoid nevrátil access_token.', odpoved.status,
      );
    }

    // `expires_in` je v sekundách. Když ho nepošle, počítá se dokumentovaná
    // platnost 2 h — radši kratší odhad než token, o kterém si myslíme, že žije.
    const platnostMs = (Number(data.expires_in) || 7200) * 1000;
    this.#ulozeny = {
      token: data.access_token,
      platiDo: this.#ted + Math.max(platnostMs - REZERVA_MS, 0),
    };
    return data.access_token;
  }
}
