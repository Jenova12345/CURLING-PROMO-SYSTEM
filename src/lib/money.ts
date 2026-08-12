// Peníze a hodiny na jednom místě.
//
// PROČ TENHLE MODUL VZNIKL: zaokrouhlování bylo rozeseté na třech místech a každé
// počítalo jinak — „Kdo kolik dluží" sčítalo surové částky a zaokrouhlilo až součet,
// podklad k fakturaci sčítal zaokrouhlené řádky. Tři rezervace po 1 250,50 Kč pak
// daly na obrazovce 3 752 Kč a na dokladu z ní 3 753 Kč. Akceptační kritérium
// „suma faktur == Kdo kolik dluží" tím neprošlo už samo se sebou.
//
// PRAVIDLO (Etapa 2, rozhodnutí R3):
//   • řádek dokladu    → přesně na 2 desetinná místa (tak to počítá i DB)
//   • součet           → PŘESNÝ součet řádků, žádné průběžné zaokrouhlování
//   • částka k úhradě  → zaokrouhlení na celé koruny AŽ TADY, viditelným řádkem
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
 * Zaokrouhlení na celé koruny; půlka nahoru v ABSOLUTNÍ hodnotě.
 *
 * Pozor na rozdíl proti holému Math.round: ten zaokrouhluje k +∞, takže
 * Math.round(-1250.5) === -1250, kdežto Postgres round(-1250.5) = -1251.
 * U dobropisů (záporné částky) by z toho byl další rozdíl 1 Kč.
 */
export function roundCzk(value: number): number {
  // Zaokrouhluje se JEDNÍM krokem z původní hodnoty, ne přes haléře.
  // Dvojí zaokrouhlení (0,495 → 0,50 → 1 Kč) se rozchází s Postgresem, který
  // `round(0.495)` vyhodnotí jako 0. Změřeno na 21 717 hodnotách proti živé DB:
  // přes haléře 120 rozdílů, jedním krokem nula.
  //
  // Pro hodnoty, které dnešní cesta umí vyrobit, je to no-op: `total` i `subtotal`
  // jsou podle rozhodnutí R3 dvoudesetinné a `sumKc` vrací nejvýš dvě desetinná
  // místa, takže se obě varianty na 7,7 milionu dvoudesetinných vstupů shodly do
  // jedné hodnoty. Jednokrokovost je tu proto, že `roundCzk` je politika nad
  // SUROVOU hodnotou — ne nad tím, co je zrovna uložené ve sloupci.
  const koruny = Math.round(Number(Math.abs(value).toPrecision(15)));
  // „+ 0" zabíjí zápornou nulu: bez něj vrátí roundCzk(-0.4) hodnotu -0.
  // Postgres numeric zápornou nulu nezná (round(-0.4) je 0), a JSON.stringify(-0)
  // je „0", takže by se takový rozdíl projevil až někde daleko.
  //
  // Schválně NE „|| 0": to je pravdivostní test, takže by spolklo i NaN a udělalo
  // z něj 0 Kč. NaN je hlasitá porucha, nula je tichá — a doklad, který místo
  // rozbitého součtu vytiskne „K úhradě 0 Kč", je nejhorší možný výstup.
  return (value < 0 ? -koruny : koruny) + 0;
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

export const fmtHodin = (value: number): string =>
  `${value.toLocaleString('cs-CZ', { maximumFractionDigits: 2 })} h`;

/** Hodiny se sčítají po setinách ze stejného důvodu jako částky. */
export const sumHodin = (values: number[]): number =>
  zeSetin(values.reduce((sum, v) => sum + toSetiny(v), 0));
