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
 * Provider odpověděl chybou, kterou neumíme zařadit.
 * `status` rozhoduje o opakování: 5xx ano, 4xx ne.
 */
export class BillingProviderError extends BillingError {
  constructor(
    message: string,
    readonly status: number,
    /** Tělo odpovědi, zkrácené. Pro diagnostiku — NIKDY se z něj nedělá rozhodnutí. */
    readonly telo?: string,
  ) {
    super(message);
  }
}

/** Má se chyba zkusit znovu? Jediné místo, kde se to rozhoduje. */
export const lzeOpakovat = (chyba: unknown): boolean => {
  if (chyba instanceof BillingRateLimitError) return true;
  if (chyba instanceof BillingProviderError) return chyba.status >= 500;
  // Validace ani autentizace se neopakují — a neznámou chybu radši taky ne:
  // opakovat něco, čemu nerozumíme, znamená riskovat duplicitní doklad.
  return false;
};
