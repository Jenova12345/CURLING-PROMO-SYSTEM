// Které akce patří na Přehled mezi „nadcházející".
//
// Vytažené z `Dashboard.tsx` do vlastního modulu ze stejného důvodu jako
// `nabidkySmen.ts`: je to pravidlo, na kterém stojí oprava „Přehled ukazoval
// zrušené akce", a jediná část té cesty, která se dá otestovat bez prohlížeče
// i bez databáze.

/** Minimum z `events`, které filtr potřebuje. */
export interface MozneNadchazejici {
  id: string;
  start_time: string;
}

/**
 * Vrátí akce, které teprve budou a nejsou zrušené — v pořadí, v jakém přišly.
 *
 * PROČ SE ID ZRUŠENÝCH AKCÍ PŘEDÁVAJÍ ZVENČÍ a nepočítají se z rezervací:
 * `events` o zrušení neví vůbec nic (nemá `status`, `cancelled_at` ani
 * `deleted_at` — ověřeno na živém schématu), zrušení žije na `reservations`
 * a tam běžný člen vidí přes RLS jen rezervace vlastního subjektu. Kdyby si to
 * frontend počítal sám, vyšla by mu jako zrušená každá cizí akce a Přehled by
 * zhasl celý. Seznam proto chodí z RPC `zrusene_akce()`, která je v databázi
 * SECURITY DEFINER a stojí na témže `akce_je_zrusena` jako brány u směn —
 * Přehled se tak nemá jak rozejít s Kalendářem ani se Směnami.
 *
 * `ted` je parametr kvůli testu; v aplikaci se nepředává.
 */
export function nadchazejiciAkce<T extends MozneNadchazejici>(
  akce: T[],
  zruseneAkce: ReadonlySet<string>,
  ted: Date = new Date(),
): T[] {
  return akce.filter((a) => {
    if (zruseneAkce.has(a.id)) return false;
    const zacatek = new Date(a.start_time);
    // Nečitelné datum se NESKRÝVÁ: `NaN > cokoli` je false, což by akci tiše
    // spolklo. Přehled má v takovém případě raději ukázat řádek, na kterém je
    // vidět, že je něco špatně, než ho zamlčet.
    if (Number.isNaN(zacatek.getTime())) return true;
    return zacatek > ted;
  });
}
