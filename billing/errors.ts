// Typované chyby fakturační vrstvy.
//
// PROČ NE HOLÝ `Error`: volající se musí umět rozhodnout bez čtení textu zprávy.
// Rate limit se má zopakovat, chyba autentizace ne; neplatná data jsou naše vina
// a do fronty patřit nemají. Rozlišovat to podle `message.includes('429')` je
// přesně ten druh kódu, který se rozbije při první změně textu na straně providera.
//
// ZPRÁVY NESMÍ NÉST TAJEMSTVÍ. `client_secret` ani token se do `message` nedostane —
// chyby končí v logu Edge funkce, který čte víc lidí než ten, kdo klíč nastavoval.

/** Společný předek — ať se dá chytit celá vrstva jedním `catch`. */
export class BillingError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = new.target.name;
  }
}

/**
 * Data nesplňují to, co provider (nebo naše schéma) vyžaduje.
 * NEOPAKOVAT — druhý pokus dopadne stejně. Chce to člověka.
 */
export class BillingValidationError extends BillingError {
  constructor(message: string, readonly pole?: string) {
    super(message);
  }
}

/**
 * Autentizace u providera selhala (špatné `client_id`/`client_secret`, odebraný přístup).
 * NEOPAKOVAT automaticky: opakované pokusy s neplatnými údaji vedou k zablokování účtu.
 */
export class BillingAuthError extends BillingError {}

/**
 * Provider nás přibrzdil (HTTP 429).
 * OPAKOVAT po `retryAfterMs`. Pokud hlavičku neposlal, volající si zvolí backoff sám.
 */
export class BillingRateLimitError extends BillingError {
  constructor(message: string, readonly retryAfterMs?: number) {
    super(message);
  }
}

/**
 * Spojení vůbec nedošlo (odmítnutý fetch, DNS, reset).
 *
 * U ČTENÍ se opakovat smí. U ZÁPISU je to ten nejhorší stav: nevíme, jestli
 * požadavek doletěl — proto ho `http.ts` neopakuje a spoléhá se na zámek 2
 * v příštím běhu.
 */
export class BillingNetworkError extends BillingError {
  /** Šlo o ZÁPIS, u kterého nevíme, jestli doletěl. Nezpakovat napřímo. */
  readonly zapisNejisty: boolean;

  constructor(message: string, options?: { cause?: unknown; zapisNejisty?: boolean }) {
    super(message, options);
    this.zapisNejisty = options?.zapisNejisty ?? false;
  }
}

/**
 * Provider odpověděl chybou, kterou neumíme zařadit.
 * `status` rozhoduje o opakování: 5xx ano, 4xx ne.
 */
export class BillingProviderError extends BillingError {
  constructor(
    message: string,
    readonly status: number,
    /** Tělo odpovědi, zkrácené a začerněné. Pro diagnostiku — nikdy se z něj nerozhoduje. */
    readonly telo?: string,
    /**
     * Šlo o ZÁPIS, u kterého nevíme, jestli se provedl (5xx po POSTu).
     *
     * Doklad mohl vzniknout a provider spadnout až při skládání odpovědi.
     * Zopakovat se smí jen CELÉ `vystavDoklad` (kde to zachytí zámky 2 a 3),
     * NIKDY `createInvoice` napřímo.
     */
    readonly zapisNejisty: boolean = false,
  ) {
    super(message);
  }
}

/**
 * Smí se zopakovat CELÉ `vystavDoklad`? Jediné místo, kde se to rozhoduje.
 *
 * POZOR NA ROZSAH: tohle NENÍ povolení zopakovat `createInvoice` napřímo.
 * U `zapisNejisty` doklad mohl vzniknout, takže bezpečné je jen znovu projít
 * celým `vystavDoklad`, kde se nejdřív zeptají zámky 2 a 3. Fronta v PR 4,
 * která by opakovala jednotlivé volání provideru, vyrobí duplicitní fakturu.
 */
export const jeZapisNejisty = (chyba: unknown): boolean =>
  (chyba instanceof BillingProviderError || chyba instanceof BillingNetworkError)
    ? chyba.zapisNejisty
    : false;

export const lzeOpakovat = (chyba: unknown): boolean => {
  if (chyba instanceof BillingRateLimitError) return true;
  if (chyba instanceof BillingNetworkError) return true;
  // 5xx a výpadek sítě se opakují na úrovni CELÉHO vystavení, ne jednoho requestu.
  // Je to bezpečné jen díky zámkům 2 a 3: nový běh se nejdřív zeptá, jestli doklad
  // nevznikl (`findExistingInvoice`), a porovná jeho řádky s dnešním podkladem.
  // Kdyby některý z těch zámků padl, tahle „true" se změní v duplicitní fakturu.
  if (chyba instanceof BillingProviderError) return chyba.status >= 500;
  // Validace ani autentizace se neopakují — a neznámou chybu radši taky ne:
  // opakovat něco, čemu nerozumíme, znamená riskovat duplicitní doklad.
  return false;
};
