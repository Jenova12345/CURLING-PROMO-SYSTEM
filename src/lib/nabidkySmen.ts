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

/** Minimum pro filtr na čas. `event` chybět smí — viz `jenNeskoncene`. */
export interface CasovanaSmena {
  event?: { end_time?: string | null } | null;
}

/**
 * Odfiltruje směny akcí, které už SKONČILY.
 *
 * PROČ `end_time` A NE `start_time`: rozhoduje se podle toho, jestli se na tu
 * směnu ještě dá nastoupit, ne jestli akce začala. Akce, která právě běží, je
 * pořád obsaditelná — brigádník onemocní a admin shání náhradu na zbytek. Kdyby
 * se filtrovalo podle začátku, přišel by přesně o tenhle případ. Skryje se tedy
 * jen to, co je doopravdy pryč.
 *
 * Táž hranice, jakou už používá `shiftsToComplete` (`event.end_time < now`),
 * takže se „ještě k obsazení" a „už k dokončení" nemůžou překrývat ani minout.
 *
 * SMĚNA BEZ AKCE SE NESKRÝVÁ. Starší směny vedené přes `events.required_staff`
 * mají `event_id` NULL a k `event` se nemají jak dostat; stejně tak řádek,
 * kterému se vnořená akce nenačetla. „Nevím, kdy to je" není „už to bylo" —
 * zmizet by při výpadku mohl celý rozpis, což je horší než původní vada.
 */
export function jenNeskoncene<T extends CasovanaSmena>(
  smeny: T[],
  ted: Date = new Date(),
): T[] {
  return smeny.filter((s) => {
    const konec = s.event?.end_time;
    if (!konec) return true;
    const kdy = new Date(konec);
    if (Number.isNaN(kdy.getTime())) return true;
    return kdy > ted;
  });
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
