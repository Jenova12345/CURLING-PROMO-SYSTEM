// Peníze a hodiny na jednom místě.
//
// PROČ TENHLE MODUL VZNIKL: zaokrouhlování bylo rozeseté na třech místech a každé
// počítalo jinak — „Kdo kolik dluží" sčítalo surové částky a zaokrouhlilo až součet,
// podklad k fakturaci sčítal zaokrouhlené řádky. Tři rezervace po 1 250,50 Kč pak
// daly na obrazovce 3 752 Kč a na dokladu z ní 3 753 Kč. Akceptační kritérium
// „suma faktur == Kdo kolik dluží" tím neprošlo už samo se sebou.
//
// KANONICKÉ PRAVIDLO (Etapa 2, rozhodnutí R3) — zaokrouhluje se STUPŇOVITĚ:
//   • řádek dokladu    → kvantizace na haléře, round(hodiny × sazba, 2)
//   • mezisoučet       → PŘESNÝ součet už kvantizovaných řádků (sám dvoudesetinný)
//   • základ a daň     → každé zvlášť kvantizované na haléře (až přijde DPH)
//   • částka k úhradě  → zaokrouhlení na celé koruny AŽ TADY, a to z už
//                        kvantizované hodnoty, ne ze surové; viditelným řádkem
//
// Na celé koruny se NIKDY nezaokrouhluje surová hodnota. Ekvivalent v SQL je
// `round(round(v, 2), 0)`, ne `round(v, 0)` — a obě strany to musí dělat stejně.
// Důvod je účetní, ne estetický: základ daně je právně významné dvoudesetinné
// číslo, ne mezivýsledek, který se smí přeskočit. Podrobně u `roundCzk` níž.
//
// Kontrolní součet porovnává přesný součet, ne zaokrouhlenou částku k úhradě —
// jinak by se po deseti fakturách nasčítalo až ±5 Kč z per-fakturového zaokrouhlení.

/**
 * Hodnota ve stotinách (u peněz haléře, u hodin setiny hodiny). Sčítat desetinná
 * čísla v pohyblivé řádové čárce plave (3 × 2000.66 vyjde 6001.979999999999),
 * a u peněz se to pozná.
 *
 * Zaokrouhluje se půlka nahoru v ABSOLUTNÍ hodnotě, stejně jako `roundCzk` níž —
 * jinak by modul, který má být jediná politika zaokrouhlování, měl politiky dvě.
 * (Holé Math.round(-1250.5) dá -1250, Postgres round(-12.505, 2) dá -12.51.)
 * Dnes to nikdo netrefí, protože všechny vstupy jsou numeric(x,2) z DB — ale DPH
 * (`základ × 0,21`) a záporné dobropisy jsou už v plánu.
 *
 * PROČ `toPrecision(15)`: násobení stem samo o sobě NESTAČÍ. `1.005 * 100` vyjde
 * v pohyblivé řádové čárce 100.49999999999999, takže holé `Math.round` dá 100
 * (tj. 1,00 Kč), kdežto Postgres `round(1.005, 2)` dá 1.01 — numeric je přesná
 * desetinná aritmetika, double ne. Změřeno: postihuje to ~4,6 % hodnot s třetím
 * desetinným místem 5 a ~10 % výpočtů typu `základ × 0,21`. Zaokrouhlení na 15
 * platných číslic smaže binární šum a desetinnou hodnotu obnoví dřív, než se
 * rozhodne o hranici.
 *
 * MEZ TÉHLE OPRAVY není magnituda, ale POČET PLATNÝCH ČÍSLIC vstupu. Hodnota,
 * která má 16+ platných číslic a leží doopravdy těsně pod půlhranicí (řádově
 * 1e-14 relativně, např. 1.0049999999999986), se vytáhne nahoru a vyjde o haléř
 * jinak než v numeric. Takový vstup ale `numeric(x,2)` ani součin sazby s hodinami
 * vyrobit neumí — ověřeno na milionech hodnot ve třech scénářích (třídesetinné
 * částky, `základ × 0,21`, sazba × hodiny): nula rozdílů proti numeric, kdežto
 * naivní varianta chybuje v desetitisících případů.
 *
 * Na dnešních dvoudesetinných vstupech je to ověřený no-op (test „nemění dnešní
 * vstupy" projede celý rozsah −5 000 … +5 000 Kč po haléři).
 */
export const toSetiny = (value: number): number => {
  const abs = Math.round(Number((Math.abs(value) * 100).toPrecision(15)));
  return value < 0 ? -abs : abs;
};

export const zeSetin = (setiny: number): number => setiny / 100;

/** Aliasy pro peníze — ať je na volajícím místě vidět, že jde o haléře. */
export const toHal = toSetiny;
export const fromHal = zeSetin;

/** Přesný součet částek — sčítá se v haléřích, ne v korunách. */
export const sumKc = (values: number[]): number =>
  zeSetin(values.reduce((sum, v) => sum + toSetiny(v), 0));

/**
 * Částka k úhradě: zaokrouhlení na celé koruny STUPŇOVITĚ, přes haléře.
 *
 * Ekvivalent v SQL je `round(round(v, 2), 0)`, NE `round(v, 0)`. Rozdíl je
 * vidět na 0,495: stupňovitě 0,495 → 0,50 → 1 Kč, jednorázově 0 Kč.
 *
 * PROČ STUPŇOVITĚ (kanonické pravidlo R3):
 * Částka k úhradě se odvozuje z toho, co je na dokladu VYTIŠTĚNO, ne z abstraktní
 * reálné hodnoty. Vytištěný mezisoučet je dvoudesetinný, takže se z dvoudesetinné
 * hodnoty musí odvíjet i zaokrouhlení — jinak doklad ukáže „Mezisoučet 1 250,50 Kč"
 * a hned pod tím „K úhradě 1 250 Kč", což si odporuje.
 *
 * Účetně je to navíc jediná varianta, která přežije přechod na plátce DPH: základ
 * daně musí být určité dvoudesetinné číslo, ze kterého se daň počítá a které se
 * tiskne. Kvantizace na haléře tedy není artefakt výpočtu, ale právně významný
 * mezikrok — a zaokrouhlení na koruny se dělá až za ním.
 *
 * Půlka jde nahoru v ABSOLUTNÍ hodnotě. Holý Math.round zaokrouhluje k +∞, takže
 * Math.round(-1250.5) === -1250, kdežto Postgres round(-1250.5) = -1251; u dobropisů
 * by z toho byl rozdíl koruny.
 *
 * Shoda s Postgresem se dá kdykoli přeměřit: `npm run overit:zaokrouhleni`
 * (skript `scripts/overit-zaokrouhleni.ts` proti živé lokální DB). Poslední běh:
 * 25 718 hodnot, 0 rozdílů; 140 z nich (0,54 %) by dopadlo jinak jednorázově.
 *
 * POZOR NA CENU MEZE `toSetiny`: tím, že `roundCzk` prochází fází 1, se limit
 * 15 platných číslic promítá až do částky k úhradě — jeho cena tedy není haléř,
 * ale CELÁ KORUNA (`1.4949999999999999` vyjde 2 Kč místo 1 Kč). Nedosažitelné to
 * je jen díky tomu, že zdroj je `numeric(x,2)`: sazba i hodiny mají dvě desetinná
 * místa a `amount` je `round(…, 2)`. Tatáž záruka musí platit i pro budoucí
 * `invoices.total` — kdyby se do něj někdy dostala hodnota s 16+ platnými
 * číslicemi, je to koruna rozdílu proti dokladu.
 */
export function roundCzk(value: number): number {
  // Fáze 1 — kvantizace na haléře. Tatáž, kterou prošel každý řádek i mezisoučet.
  const hal = toSetiny(value);
  // Fáze 2 — z už kvantizované hodnoty na celé koruny. `hal` je celé číslo, takže
  // dělení stem trefí hranici .5 přesně a žádná další korekce šumu není potřeba.
  const koruny = Math.round(Math.abs(hal) / 100);
  // „+ 0" zabíjí zápornou nulu: bez něj vrátí roundCzk(-0.4) hodnotu -0.
  // Postgres numeric zápornou nulu nezná (round(-0.4) je 0), a JSON.stringify(-0)
  // je „0", takže by se takový rozdíl projevil až někde daleko.
  //
  // Schválně NE „|| 0": to je pravdivostní test, takže by spolklo i NaN a udělalo
  // z něj 0 Kč. NaN je hlasitá porucha, nula je tichá — a doklad, který místo
  // rozbitého součtu vytiskne „K úhradě 0 Kč", je nejhorší možný výstup.
  return (hal < 0 ? -koruny : koruny) + 0;
}

/** Zaokrouhlovací rozdíl, který se na dokladu tiskne vlastním řádkem. */
export const roundingDiff = (value: number): number =>
  zeSetin(toSetiny(roundCzk(value)) - toSetiny(value));

/**
 * Kč pro zobrazení. Haléře ukazuje jen tehdy, když nějaké jsou — zamlčet je
 * (což dělal starý `Math.round` uvnitř formátovače) je přesně ten způsob, jak
 * se součet na obrazovce rozejde se součtem na dokladu.
 */
export function fmtKc(value: number): string {
  const hal = toSetiny(value);
  const celeKoruny = hal % 100 === 0;
  // „+ 0“ zabíjí zápornou nulu: -0 by se vypsalo jako „-0 Kč“.
  const koruny = zeSetin(hal) + 0;
  return `${koruny.toLocaleString('cs-CZ', {
    minimumFractionDigits: celeKoruny ? 0 : 2,
    maximumFractionDigits: celeKoruny ? 0 : 2,
  })} Kč`;
}

/**
 * Sazba Kč/h. Jednotková cena je náležitost dokladu (§ 11 zákona o účetnictví),
 * takže se tiskne s haléři — na celé koruny ji nezaokrouhlujeme. Zobrazovací
 * mez jsou 2 desetinná místa, což dnes stačí: `rate_per_hour` je numeric(10,2).
 */
export const fmtSazba = (value: number): string => `${fmtKc(value)}/h`;

/**
 * Hodiny pro zobrazení. Jde přes `toSetiny` schválně: byla to jediná cesta
 * v modulu, která obcházela společnou kvantizaci a spoléhala na zaokrouhlení
 * uvnitř `toLocaleString`. Na dnešních datech se to shoduje, ale rozejde se to
 * na hodnotách jako 2.9749999999999996 („2,97 h" místo 2,98) — a modul, který
 * se prohlašuje za jedinou politiku zaokrouhlování, nesmí mít výjimku.
 */
export const fmtHodin = (value: number): string =>
  `${zeSetin(toSetiny(value)).toLocaleString('cs-CZ', { maximumFractionDigits: 2 })} h`;

/** Hodiny se sčítají po setinách ze stejného důvodu jako částky. */
export const sumHodin = (values: number[]): number =>
  zeSetin(values.reduce((sum, v) => sum + toSetiny(v), 0));

/**
 * Výsledek čtení sazby. Schválně NE diskriminované sjednocení přes `ok: true|false`:
 * projekt má `strict: false`, kde se takové sjednocení spolehlivě nezužuje a TypeScript
 * na `if (!v.ok) v.chyba` hlásí, že vlastnost neexistuje. Prostý nepovinný `chyba`
 * funguje v obou režimech stejně.
 */
export type VysledekSazby = { hodnota: number | null; chyba?: string };

/**
 * Přečte sazbu z formulářového pole. Prázdné pole je platný vstup a znamená
 * „nemá vlastní sazbu, vezmi z ceníku" — proto `hodnota: null`, ne chyba.
 *
 * PROČ SPOLEČNĚ: tohle se dřív psalo zvlášť na čtyřech místech (ceník
 * v Nastavení, sazba subjektu při založení, táž při úpravě, adminská sazba
 * v dialogu rezervace) a všechna čtyři kontrolovala jen `isNaN || <= 0`.
 * Rozhodnutí R3 „sazby v celých korunách" by tak zůstalo jen v databázi
 * a uživatel by se o něm dozvěděl až syrovou chybou CHECK constraintu.
 *
 * Celé koruny jsou tu proto, aby zaokrouhlení skoro nikdy nemuselo nic řešit:
 * při celokorunové sazbě a čtvrthodinách je `hodiny × sazba` přesný součin.
 *
 * Funkce je smlouva: **když nevrátí `chyba`, je `hodnota` celé kladné číslo
 * v rozsahu, který databáze uloží beze změny.** Volající se na to smí spolehnout.
 */

/** Horní mez sazby. Sloupce jsou `numeric(10,2)`, tedy |x| < 10^8. */
export const SAZBA_MAX = 99_999_999;

// Vlastní tvar místo holého `Number()`. To je totiž mnohem velkorysejší, než
// se u sazby hodí: `Number('0x10')` je 16 a `Number('1e3')` je 1000, což by
// prošlo jako „platná sazba" a nikdo by to nečekal.
const SAZBA_TVAR = /^-?\d+([.,]\d+)?$/;

export function parseSazba(vstup: string): VysledekSazby {
  const text = vstup.trim();
  if (!text) return { hodnota: null };

  if (!SAZBA_TVAR.test(text)) {
    // Sem spadne i „1 250" zkopírované z appky: `fmtKc` tiskne úzkou nezlomitelnou
    // mezeru jako oddělovač tisíců, takže je to snadný omyl. Hláška to říká rovnou.
    return { hodnota: null, chyba: 'Sazba musí být číslo, bez mezer a oddělovače tisíců.' };
  }

  // Čárka i tečka — na české klávesnici padne na desetinnou čárku každý.
  const cislo = Number(text.replace(',', '.'));

  if (!Number.isFinite(cislo)) return { hodnota: null, chyba: 'Sazba musí být číslo.' };
  if (cislo <= 0) return { hodnota: null, chyba: 'Sazba musí být kladná.' };
  // Schválně `Number.isInteger`, ne `toSetiny(x) % 100`: to druhé nejdřív zaokrouhlí,
  // takže by kolem každé koruny nechalo toleranční okno ±0,005 a „600,001" by prošlo
  // jako celokorunová sazba — a vrátilo by se nezaokrouhlené dál do výpočtů.
  if (!Number.isInteger(cislo)) {
    return { hodnota: null, chyba: 'Sazba se zadává v celých korunách, bez haléřů.' };
  }
  if (cislo > SAZBA_MAX) {
    // Bez téhle meze by uživatel dostal syrové „numeric field overflow" z Postgresu,
    // což je přesně ta chyba, které má tahle funkce předcházet.
    return { hodnota: null, chyba: `Sazba je mimo rozsah (nejvýš ${SAZBA_MAX} Kč).` };
  }
  return { hodnota: cislo };
}
