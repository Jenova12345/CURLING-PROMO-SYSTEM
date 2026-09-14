/**
 * Převod chyby z databáze na větu, kterou má uživatel opravdu číst.
 *
 * PROČ TO JE NA JEDNOM MÍSTĚ A NE U KAŽDÉHO VOLÁNÍ ZVLÁŠŤ
 * ------------------------------------------------------------------
 * Do `shifts` zapisuje frontend ze ČTYŘ míst (`requestShift`, `approveShift`,
 * `assignShift` v useShifts.ts a `approveApplication` v useShiftApplications.ts)
 * a každé si obsluhu chyb psalo samo. Výsledek k 14. 9. 2026:
 *
 *   * `assignShift` zahazoval hlášku z databáze úplně a vždycky ukázal
 *     „Nepodařilo se přiřadit směnu." — tedy „něco se pokazilo" i tam, kde
 *     databáze přesně řekla, co je špatně.
 *   * `requestShift` hlídal text „již máte jinou směnu", jenže tak ta hláška
 *     zněla naposled před 1. 9. 2026. Od té doby databáze říká „Na této akci
 *     už tuhle roli máte." — ta větev byla přes dva týdny MRTVÁ a uživatel
 *     dostával obecné „Nepodařilo se přihlásit na směnu.".
 *
 * Je to týž vzorec, kvůli kterému vznikla migrace 20260914200000: hlídaná
 * cesta a vedle ní nehlídaná. Proto jedno místo — páté volání ho použije taky.
 *
 * PROČ WHITELIST A NE „PROPUSŤ, CO PŘIJDE"
 * ------------------------------------------------------------------
 * Hlášky z našich guardů jsou psané pro uživatele a propustit se MAJÍ.
 * Hlášky z Postgresu samotného (`permission denied for table shifts`,
 * `duplicate key value violates unique constraint "…"`) jsou pro vývojáře,
 * prozrazují tvar schématu a uživateli neřeknou nic. Proto se propouští jen
 * to, co je tu vyjmenované, a všechno ostatní spadne na záložní větu.
 */

/**
 * Z čí strany se na směnu koukáme. Rozhoduje jen u hlášky z unikátního indexu —
 * ten na rozdíl od triggeru neví, kdo zápis dělá, takže větu musí dodat volající.
 */
export type PerspektivaSmeny = 'sam' | 'nekdoJiny';

/**
 * Hlášky z `validate_shift_claim()`, které se propouští beze změny.
 * Jsou to věty psané pro uživatele — přepsat je tady by znamenalo udržovat
 * je na dvou místech a čekat, až se rozejdou (viz „již máte jinou směnu" výš).
 *
 * VŠECHNY BEZ KONCOVÉ TEČKY, tečku doplní až výstup. Databáze totiž není
 * jednotná: `validate_shift_claim` má „Nemůžete zrušit cizí směnu" (bez tečky)
 * i „Nemůžete zrušit cizí směnu." (s tečkou), obojí živě. Kdyby tu byl zápis
 * s tečkou, `includes` by variantu bez tečky NENAŠEL a uživatel by místo
 * důvodu dostal záložní větu — přesně ten tichý výpadek, kvůli kterému tenhle
 * soubor vznikl. Zkontrolováno proti `pg_get_functiondef` produkce 14. 9. 2026.
 */
const HLASKY_NASICH_GUARDU = [
  'Směna již byla obsazena',
  'Tuhle směnu už má někdo jiný',
  'Na této akci už tuhle roli máte',
  'Tenhle člověk už na této akci tuhle roli má',
  'Akce je zrušená, směnu na ní vzít nelze',
  'Nemůžete zrušit cizí směnu',
  'Nemůžete zrušit cizí přihlášku',
  'Zrušenou směnu znovu otevírá jen správce haly',
  'Do zrušené směny už zapisovat nelze',
  'Uzavřenou směnu znovu otevírá jen správce haly',
  'Roli na směně mění jen správce haly',
  'Směnu nelze přesunout na jinou akci',
  'Identitu ani datum založení směny přepsat nelze',
  'Sazbu, hodiny, vazbu na výplatu ani poznámku si na směně nastavit nemůžete',
  'Pouze admin může schválit směnu',
  'Pouze admin může dokončit směnu',
  'Musíte zadat odpracované hodiny',
  'Hodiny musí být mezi 0.1 a 24',
  'Hodinová sazba musí být mezi 1 a 10000 Kč',
] as const;

/**
 * Unikátní indexy na `shifts`. Sem se dostaneme jen tehdy, když guard v triggeru
 * nestihl promluvit — typicky při souběhu dvou zápisů nebo u `INSERT`, kam
 * `BEFORE UPDATE` trigger vůbec nevidí. Hlášku z Postgresu proto musíme nahradit.
 */
const HLASKY_INDEXU: Record<string, { sam: string; nekdoJiny: string }> = {
  shifts_jedna_role_na_akci: {
    sam: 'Na této akci už tuhle roli máte.',
    nekdoJiny: 'Tenhle člověk už na této akci tuhle roli má.',
  },
  shifts_jeden_trener_na_akci: {
    sam: 'Na této akci už trenér je.',
    nekdoJiny: 'Na této akci už trenér je.',
  },
};

/**
 * @param zprava      `error.message` ze Supabase (klidně undefined/null)
 * @param zaloha      věta pro případ, že hlášce nerozumíme (např. výpadek sítě)
 * @param perspektiva kdo směnu bere — `'sam'` u samoobsluhy, `'nekdoJiny'`,
 *                    když admin přiřazuje někoho dalšího
 */
export function popisChybySmeny(
  zprava: string | null | undefined,
  zaloha: string,
  perspektiva: PerspektivaSmeny = 'nekdoJiny',
): string {
  const text = typeof zprava === 'string' ? zprava : '';
  if (text === '') return zaloha;

  // Indexy první: jejich hláška je anglická a uživateli by neřekla nic.
  for (const [index, veta] of Object.entries(HLASKY_INDEXU)) {
    if (text.includes(index)) return veta[perspektiva];
  }

  // Naše vlastní věty se propouští tak, jak je databáze napsala.
  const nase = HLASKY_NASICH_GUARDU.find(h => text.includes(h));
  if (nase) {
    // `includes` schválně, ne rovnost: PostgREST k hlášce občas přilepí kontext.
    // Vracíme ale JEN tu známou větu, ne celý text — v tom zbytku bývá název
    // funkce a číslo řádku, což je pro uživatele šum a pro útočníka nápověda.
    return `${nase}.`;
  }

  return zaloha;
}
