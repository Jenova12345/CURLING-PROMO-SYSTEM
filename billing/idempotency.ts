// Klíče idempotence a oba zámky proti duplicitnímu dokladu.
//
// PROČ DVA ZÁMKY A NE JEDEN:
//   1) LOKÁLNÍ — zdrojová rezervace už nese vazbu na doklad → přeskoč.
//      Chytí běžný souběh (dva adminové, cron a člověk zároveň) bez jediného
//      HTTP requestu, tedy i když je provider nedostupný.
//   2) VZDÁLENÝ — před POST se provider zeptá, jestli doklad s tímhle klíčem
//      nemá. Chytí případ, kdy první pokus doklad VYTVOŘIL, ale odpověď se
//      cestou ztratila (timeout, spadlá Edge funkce) a lokální vazba se proto
//      nezapsala. Sám zámek 1 by tady vystavil druhý doklad.
// Jeden bez druhého nechává díru. Oba dohromady ne.
//
// KLÍČ MUSÍ BÝT ODVOZENÝ, NE NÁHODNÝ. Kdyby se generoval (uuid, timestamp),
// druhý běh by dostal jiný klíč a zámek 2 by nikdy nic nenašel — což je přesně
// ten způsob, jak vypadá idempotence, dokud ji někdo nepotřebuje.

import { BillingValidationError } from './errors.ts';
import { rokMesic } from './format.ts';

/**
 * Klíč komerční akce: `akce-{eventId}`.
 *
 * NE `akce-{reservationId}` (rozhodnutí D2, potvrzeno 24. 8. 2026): jedna komerční
 * akce má běžně víc rezervací — typicky obě dráhy — a `invoices_komercni_ma_akci`
 * váže doklad na `event_id`. S klíčem přes rezervaci by firma dostala samostatný
 * doklad na každou dráhu.
 */
export const klicAkce = (eventId: string): string => `akce-${overId(eventId, 'eventId')}`;

/**
 * Klíč měsíčního souhrnu klubu: `klub-{clubId}-{RRRRMM}`.
 *
 * Měsíc se bere z období dokladu v pražském čase, ne z „teď" — přefakturování
 * července v srpnu musí dát týž klíč jako původní běh.
 */
export const klicKlubu = (clubId: string, obdobiOd: string | Date): string =>
  `klub-${overId(clubId, 'clubId')}-${rokMesic(obdobiOd)}`;

/**
 * Identifikátory jdou do `custom_id` u providera, tedy do URL dotazu. Prázdný
 * nebo pomlčkou promořený řetězec by udělal klíč, který se dá splést s jiným
 * („klub--202608" vs. „klub-x-202608"), takže se tvar hlídá tady, ne až u HTTP.
 */
const overId = (hodnota: string, pole: string): string => {
  const cisty = (hodnota ?? '').trim();
  if (!cisty) {
    throw new BillingValidationError(`Klíč idempotence nejde sestavit: ${pole} je prázdný.`, pole);
  }
  if (!/^[A-Za-z0-9_-]+$/.test(cisty)) {
    // Syrová hodnota se do zprávy NEDÁVÁ. `trim()` čistí jen konce, takže
    // "a\nSRPEN 2026: vystaveno v pořádku" by v logu Edge funkce vyrobilo
    // druhý, podvržený řádek. Do zprávy jde jen zneškodněný náhled.
    throw new BillingValidationError(
      `Klíč idempotence nejde sestavit: ${pole} obsahuje nepovolené znaky (${nahled(cisty)}).`, pole,
    );
  }
  return cisty;
};

/** Zneškodněný náhled hodnoty do chybové zprávy — bez řídicích znaků a zkrácený. */
const nahled = (hodnota: string): string => {
  const bezRidicich = hodnota.replace(/[\u0000-\u001F\u007F]/g, '·');
  return bezRidicich.length > 40 ? `${bezRidicich.slice(0, 40)}…` : bezRidicich;
};

/**
 * ZÁMEK 1 — vrátí rezervace, které se ještě nefakturovaly.
 *
 * `jeVyfakturovana` dodává volající (v testech paměťová implementace, v provozu
 * `InvoiceLinkStore` nad databází). Tady se jen rozhoduje, ne čte.
 */
export const jesteNevyfakturovane = <T extends { id: string }>(
  rezervace: readonly T[],
  jeVyfakturovana: (id: string) => boolean,
): T[] => rezervace.filter((r) => !jeVyfakturovana(r.id));
