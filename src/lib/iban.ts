// České číslo účtu ↔ IBAN.
//
// PROČ TENHLE MODUL VZNIKL: na doklad se tiskne české číslo účtu, ale do QR platby
// patří IBAN. Admin zadá jedno a druhé se dopočítá — jenže dopočet, kterému nikdo
// nekouká pod ruce, je nebezpečná věc: špatný IBAN pošle peníze na cizí účet
// a přijde se na to po týdnech, až se nikdo neozve s platbou.
//
// Modul proto dělá dvě oddělené věci:
//   1. spočítá IBAN,
//   2. řekne, jak moc si je jistý — tedy jestli číslo účtu prošlo kontrolou mod-11.
// Formulář (A4) na základě toho vyžaduje potvrzení adminem. Modul sám nikdy nic
// „neopraví“ potichu.
//
// Zdroje algoritmů:
//   • mod-11 s vahami — vyhláška ČNB o způsobu tvorby čísel účtů
//   • mod-97 kontrolní číslice IBANu — ISO 13616 / ISO 7064

/**
 * Znaky, které se před zpracováním strhávají: mezery, nedělitelná mezera a celá
 * rodina NEVIDITELNÝCH — zero-width space, RTL/LTR značky, měkký spojovník.
 *
 * Proč to není přehnaná pečlivost: IBAN zkopírovaný z webové stránky často nese
 * U+200B uvnitř. Bez tohohle by admin koukal na opticky bezvadný IBAN a systém
 * mu tvrdil „kontrolní číslice nesedí, je v něm překlep" — tedy ho tlačil, aby
 * ho přepsal ručně, což je právě ta situace, kdy překlep opravdu vznikne.
 */
const NEVIDITELNE = /[\s\u00a0\u200b-\u200f\u202a-\u202e\u2060\u00ad\ufeff]/g;

/** Rozložené české číslo účtu. Předčíslí smí chybět, pak je prázdné. */
export type CeskyUcet = {
  predcisli: string;   // 0–6 číslic
  cislo: string;       // 2–10 číslic
  kodBanky: string;    // právě 4 číslice
};

export type VysledekUctu = { ucet: CeskyUcet | null; chyba?: string };

export type VysledekIbanu = {
  iban: string | null;
  chyba?: string;
  /** Číslo je tvarem v pořádku, ale neprošlo kontrolou mod-11 — IBAN je spočítaný, ale podezřelý. */
  varovani?: string;
};

// Váhy podle vyhlášky ČNB, zprava doleva.
const VAHY_PREDCISLI = [10, 5, 8, 4, 2, 1];
const VAHY_CISLA = [6, 3, 7, 9, 10, 5, 8, 4, 2, 1];

const TVAR_UCTU = /^(?:(\d{1,6})-)?(\d{2,10})\/(\d{4})$/;

/**
 * Rozloží české číslo účtu na části. Přijímá „19-2000145399/0800" i „2000145399/0800",
 * mezery a nedělitelné mezery ignoruje (lidé je z internetbankingu kopírují běžně).
 */
export function parseCeskyUcet(vstup: string): VysledekUctu {
  const text = vstup.replace(NEVIDITELNE, '');
  if (!text) return { ucet: null };

  const shoda = TVAR_UCTU.exec(text);
  if (!shoda) {
    return {
      ucet: null,
      chyba: 'Očekávám české číslo účtu ve tvaru [předčíslí-]číslo/kód banky, například 19-2000145399/0800.',
    };
  }

  return {
    ucet: { predcisli: shoda[1] ?? '', cislo: shoda[2], kodBanky: shoda[3] },
  };
}

/** Vážený součet dělitelný jedenácti — kontrola, kterou předepisuje ČNB. */
function projdeModulo11(cast: string, vahy: number[]): boolean {
  if (!cast) return true; // prázdné předčíslí se nekontroluje
  const cislice = cast.padStart(vahy.length, '0').split('').map(Number);
  const soucet = cislice.reduce((acc, c, i) => acc + c * vahy[i], 0);
  return soucet % 11 === 0;
}

/**
 * Ověří obě části čísla účtu zvlášť. Vrací, která z nich neprošla — hláška
 * „číslo účtu je neplatné" člověku neřekne, kde má hledat překlep.
 */
export function overModulo11(ucet: CeskyUcet): { ok: boolean; kde?: string } {
  if (!projdeModulo11(ucet.predcisli, VAHY_PREDCISLI)) return { ok: false, kde: 'předčíslí' };
  if (!projdeModulo11(ucet.cislo, VAHY_CISLA)) return { ok: false, kde: 'číslo účtu' };
  // Vyhláška ČNB chce v základní části aspoň dvě číslice různé od nuly. Samé nuly
  // váženým součtem projdou (0 je dělitelná jedenácti), takže je to jediný případ,
  // kdy mod-11 nestačí — a přitom je to realistický placeholder, který někdo
  // zapomene přepsat.
  if (ucet.cislo.replace(/0/g, '').length < 2) return { ok: false, kde: 'číslo účtu' };
  return { ok: true };
}

/**
 * Zbytek po dělení 97 pro libovolně dlouhý řetězec číslic.
 * Počítá se po znacích, protože 22místné číslo se do `number` nevejde přesně.
 */
function modulo97(cislice: string): number {
  let zbytek = 0;
  for (const znak of cislice) {
    zbytek = (zbytek * 10 + Number(znak)) % 97;
  }
  return zbytek;
}

/** Písmena na čísla podle ISO 13616: A = 10 … Z = 35. */
function pismenaNaCisla(text: string): string {
  return text.replace(/[A-Z]/g, (p) => String(p.charCodeAt(0) - 55));
}

/**
 * Dopočítá IBAN z českého čísla účtu.
 *
 * BBAN je pro ČR 20 číslic: kód banky (4) + předčíslí doplněné nulami (6)
 * + číslo účtu doplněné nulami (10). Kontrolní číslice se počítají tak, že se
 * „CZ00" přesune na konec, písmena se převedou na čísla a z výsledku se vezme
 * 98 − (zbytek po dělení 97).
 *
 * Když číslo neprojde kontrolou mod-11, IBAN se **přesto vrátí** — ale s varováním.
 * Odmítnout ho by bylo horší: existují historické účty, které mod-11 neprojdou,
 * a admin musí mít možnost je použít vědomě.
 */
export function ibanZUctu(vstup: string): VysledekIbanu {
  const { ucet, chyba } = parseCeskyUcet(vstup);
  if (chyba) return { iban: null, chyba };
  if (!ucet) return { iban: null };

  const bban = ucet.kodBanky + ucet.predcisli.padStart(6, '0') + ucet.cislo.padStart(10, '0');
  const kontrolni = String(98 - modulo97(pismenaNaCisla(bban + 'CZ00'))).padStart(2, '0');
  const iban = `CZ${kontrolni}${bban}`;

  const mod11 = overModulo11(ucet);
  if (!mod11.ok) {
    return {
      iban,
      varovani: `Neobvyklé ${mod11.kde} — neprošlo kontrolním součtem podle pravidel ČNB. `
        + 'Zkontroluj, jestli tam není překlep.',
    };
  }
  return { iban };
}

/**
 * Délky IBANu podle země (ISO 13616). Kompletní seznam sem nepatří — hala fakturuje
 * v Česku a případné zahraniční číslo si admin stejně ověřuje sám. Co tu není,
 * projde jen na obecný tvar a kontrolní číslice.
 */
const DELKY_IBANU: Record<string, number> = { CZ: 24, SK: 24, DE: 22, AT: 20, PL: 28 };

/**
 * Ověří existující IBAN: tvar, délku podle země a kontrolní číslice
 * (ISO 7064 — zbytek po dělení 97 musí být 1).
 *
 * Délka podle země je tu nutná, ne kosmetická: samotné mod-97 propustí i 23znakový
 * „CZ" řetězec, protože kontrolní číslice si sednou na cokoli. Banka takový IBAN
 * odmítne, ale my bychom ho pustili do QR platby.
 */
export function overIban(vstup: string): boolean {
  const text = vstup.replace(NEVIDITELNE, '').toUpperCase();
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/.test(text)) return false;

  const zeme = text.slice(0, 2);
  const ocekavana = DELKY_IBANU[zeme];
  if (ocekavana !== undefined && text.length !== ocekavana) return false;
  // Český BBAN je celý číselný; písmena v něm znamenají překlep, ne exotický formát.
  if (zeme === 'CZ' && !/^CZ\d{22}$/.test(text)) return false;

  const prehozeny = text.slice(4) + text.slice(0, 4);
  return modulo97(pismenaNaCisla(prehozeny)) === 1;
}

/** IBAN po čtveřicích, jak se běžně tiskne — snáz se kontroluje okem. */
export function formatujIban(iban: string): string {
  return iban.replace(NEVIDITELNE, '').replace(/(.{4})/g, '$1 ').trim();
}
