// Které směny se smějí nabídnout brigádníkovi.
//
// Vytažené z `useShifts` do vlastního modulu schválně: je to pravidlo, na
// kterém stojí Jakubův nález z 3. 9. 2026 (zrušená akce dál nabízela směnu),
// a jediná část té cesty, která se dá otestovat bez prohlížeče i bez databáze.

/** Minimum ze `shifts`, které filtr potřebuje. Schválně jen `event_id`:
 *  na `status` se filtr neptá, a kdyby ho vyžadoval, nešel by použít nad
 *  jinak tvarovanými daty (např. v kalendáři). */
export interface NabidnutelnaSmena {
  event_id: string | null;
}

/**
 * Odfiltruje směny, jejichž akce je zrušená.
 *
 * PROČ SE ID ZRUŠENÝCH AKCÍ PŘEDÁVAJÍ ZVENČÍ a nepočítají se z rezervací:
 * brigádník na `reservations` nevidí (RLS `reservations_select` pouští jen
 * rezervace vlastního subjektu — změřeno, u zrušené akce vidí NULA řádků).
 * Kdyby si to frontend počítal sám z vnořených rezervací, vyšla by mu jako
 * zrušená každá cizí akce a zhasl by celý rozpis. Seznam proto chodí z RPC
 * `zrusene_akce_se_smenami()`, která je v databázi SECURITY DEFINER.
 *
 * Tohle je DRUHÁ pojistka, ne hlavní mechanismus. Hlavní je invariant
 * v databázi (migrace 20260903120000): směna na zrušené akci je `cancelled`,
 * takže by se sem stejně nedostala. Filtr tu je pro případ, že by se do UI
 * dostal starší řádek dřív, než ho invariant zavře.
 */
export function bezZrusenychAkci<T extends NabidnutelnaSmena>(
  smeny: T[],
  zruseneAkce: ReadonlySet<string>,
): T[] {
  if (zruseneAkce.size === 0) return smeny;
  return smeny.filter((s) => !(s.event_id && zruseneAkce.has(s.event_id)));
}
