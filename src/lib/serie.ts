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
/** Nejvýš tolik dat se vypíše; zbytek se sečte. */
const MAX_DNU = 8;

function seznamDnu(polozky: SeriesResult['skipped']): string {
  const dny = polozky.map((s) => {
    const d = denZDb(s.iso);
    return d ? format(d, 'd. M.', { locale: cs }) : s.date;
  });
  // Roční série v den, kdy je hala zavřená, umí vyrobit padesát dat. Toast nemá
  // scroll, takže by přetekl přes obrazovku — a to na dvanáct vteřin.
  if (dny.length <= MAX_DNU) return dny.join(', ');
  return `${dny.slice(0, MAX_DNU).join(', ')} a další ${dny.length - MAX_DNU}`;
}

export function souhrnSerie(res: SeriesResult): string {
  if (!res.skipped?.length) return 'Celá série je v kalendáři.';

  const kolize = seznamDnu(res.skipped.filter((s) => s.duvod === 'kolize'));
  const zavreno = seznamDnu(res.skipped.filter((s) => s.duvod === 'mimo_otviraci_dobu'));

  // ZÁLOHA PRO STARŠÍ SERVER. Frontend se nasazuje z GitHubu sám, kdežto migrace
  // se pouští ručně se souhlasem PM — mezi tím je okno, kdy nové UI mluví se
  // starou funkcí, která `duvod` neposílá vůbec. Bez tohohle by oba filtry
  // vyšly prázdné a uživatel by se nedozvěděl NIC, tedy míň než předtím.
  if (!kolize && !zavreno) {
    return `Přeskočené termíny: ${seznamDnu(res.skipped)}`;
  }

  // Bez tečky na konci: český tvar data „15. 4." si ji nese sám a druhá by
  // udělala „15. 4..". Právě na tomhle stojí test — je to věta pro klienta.
  return [
    kolize && `Přeskočeno kvůli kolizi: ${kolize}`,
    zavreno && `Mimo otevírací dobu: ${zavreno}`,
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
