import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { denZDb } from '@/lib/datum';
import type { SeriesResult } from '@/hooks/useReservations';

// Souhrn série opakovaných tréninků.
//
// Vytažené z dialogu do vlastního modulu schválně: je to věta, kterou uvidí
// klient po každém zadání pravidelného tréninku, a jediná část celé té cesty,
// která se dá otestovat bez prohlížeče i bez databáze.

/**
 * Věta pod nadpisem „Vytvořeno 18 z 20".
 *
 * Přeskočené termíny se VYJMENUJÍ, ne jen spočítají: „přeskočeno 2" se nedá
 * vyřešit, kdežto „15. 4., 24. 4." si uživatel rovnou najde v kalendáři a shání
 * náhradu. Důvody zůstávají oddělené, protože se řeší jinak — kolizi jiný čas,
 * zavřenou halu nastavení otevírací doby.
 */
/** Nejvýš tolik dat se vypíše v CELÉM souhrnu; zbytek se sečte. */
const MAX_DNU = 8;

/** Kolik dat ještě smí do souhrnu. Sdílí se mezi všemi důvody. */
type Rozpocet = { zbyva: number };

/** „3 termíny" — české skloňování, ať se klientovi neukazuje „3 termínů". */
function pocetTerminu(n: number): string {
  if (n === 1) return '1 termín';
  if (n >= 2 && n <= 4) return `${n} termíny`;
  return `${n} termínů`;
}

function seznamDnu(polozky: SeriesResult['skipped'], rozpocet: Rozpocet): string {
  const dny = polozky.map((s) => {
    const d = denZDb(s.iso);
    return d ? format(d, 'd. M.', { locale: cs }) : s.date;
  });
  if (!dny.length) return '';

  // Roční série v den, kdy je hala zavřená, umí vyrobit padesát dat. Toast nemá
  // scroll, takže by přetekl přes obrazovku — a to na dvanáct vteřin.
  //
  // Rozpočet je SPOLEČNÝ pro celý souhrn, ne pro každý důvod zvlášť. Se stropem
  // na skupinu totiž tři důvody vyrobily 8 + 8 + 8 = 24 dat a strop nechránil
  // před ničím — přesně před tím, co měl hlídat.
  const kolik = Math.min(dny.length, Math.max(rozpocet.zbyva, 0));
  rozpocet.zbyva -= kolik;

  if (kolik === dny.length) return dny.join(', ');
  // Rozpočet došel ještě před tímhle důvodem: aspoň počet, ať se neztratí.
  if (kolik === 0) return pocetTerminu(dny.length);
  return `${dny.slice(0, kolik).join(', ')} a další ${dny.length - kolik}`;
}

export function souhrnSerie(res: SeriesResult): string {
  if (!res.skipped?.length) return 'Celá série je v kalendáři.';

  const rozpocet: Rozpocet = { zbyva: MAX_DNU };
  const kolize = seznamDnu(res.skipped.filter((s) => s.duvod === 'kolize'), rozpocet);
  const zavreno = seznamDnu(res.skipped.filter((s) => s.duvod === 'mimo_otviraci_dobu'), rozpocet);
  const neexistuje = seznamDnu(res.skipped.filter((s) => s.duvod === 'neexistujici_cas'), rozpocet);

  // ZÁLOHA PRO STARŠÍ SERVER. Frontend se nasazuje z GitHubu sám, kdežto migrace
  // se pouští ručně se souhlasem PM — mezi tím je okno, kdy nové UI mluví se
  // starou funkcí, která `duvod` neposílá vůbec. Bez tohohle by oba filtry
  // vyšly prázdné a uživatel by se nedozvěděl NIC, tedy míň než předtím.
  if (!kolize && !zavreno && !neexistuje) {
    return `Přeskočené termíny: ${seznamDnu(res.skipped, { zbyva: MAX_DNU })}`;
  }

  // Bez tečky na konci: český tvar data „15. 4." si ji nese sám a druhá by
  // udělala „15. 4..". Právě na tomhle stojí test — je to věta pro klienta.
  return [
    kolize && `Přeskočeno kvůli kolizi: ${kolize}`,
    zavreno && `Mimo otevírací dobu: ${zavreno}`,
    // Vlastní věta schválně: „kolize" ani „zavřeno" by tady lhaly a uživatel by
    // marně hledal, kdo mu dráhu zabral.
    neexistuje && `Čas v daný den neexistuje (posun na letní čas): ${neexistuje}`,
  ].filter(Boolean).join(' ');
}

/**
 * „Vytvořeno 18 z 20". Starší server `celkem` neposílá, takže se dopočítá —
 * jinak by v okně mezi nasazením frontendu a migrací svítilo „z undefined".
 */
export function nadpisSerie(res: SeriesResult): string {
  const celkem = res.celkem ?? res.created + (res.skipped?.length ?? 0);
  return `Vytvořeno ${res.created} z ${celkem}`;
}
