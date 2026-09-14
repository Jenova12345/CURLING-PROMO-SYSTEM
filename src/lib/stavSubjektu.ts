/**
 * Rozhodování o hláškách na stránce Subjekty, vytažené z JSX do čistých funkcí.
 *
 * PROČ TO TU JE: oprava hlášení „v Subjektech nejde přidat člověka do jiného
 * klubu" (14. 9. 2026) byla celá v UI — databáze nic neblokovala. Držel ji tedy
 * jen SQL test databázové poloviny, který projde stejně zeleně před opravou
 * i po ní. To je v rozporu s nepodkročitelným pravidlem 4 v CLAUDE.md: oprava
 * bez mutačního testu nehlídá nic. (Nález code-review brány.)
 *
 * Repo nemá jsdom ani testing-library, takže komponenta se „kliknout" nedá.
 * Textové brány nad zdrojákem (`branyFrontendu.test.ts`) čtou hodnoty, ne
 * polaritu podmínek, takže by `=== 0` od `> 0` nerozeznaly. Rozhodnutí proto
 * bydlí tady, kde se dá otestovat normálně — a v JSX zůstane jen mapování
 * výsledku na text.
 */

/** V jakém stavu je rozbalovátko „Přidat člověka…". */
export type StavSeznamuLidi =
  | 'nacita'            // dotaz na profily ještě běží
  | 'chyba'             // dotaz na profily selhal
  | 'nikdo-v-systemu'   // dotaz uspěl, ale v systému nikdo není
  | 'vse-prirazeno'     // lidé existují, ale všichni už u subjektu jsou
  | 'seznam';           // je koho nabídnout

/**
 * POŘADÍ VĚTVÍ JE TU TO PODSTATNÉ, ne jejich existence.
 *
 * `nacitaSe` musí přebít `chyba` i prázdnotu: `QueryClient` je bez konfigurace,
 * takže platí default `retry: 3` a chyba se objeví až po několika sekundách.
 * Kdyby se nejdřív ptalo na prázdnotu, tvrdilo by rozbalovátko „nenačetlo se"
 * o dotazu, který ještě běží.
 *
 * A `chyba` musí přebít `pocetProfilu === 0`: při selhání zůstane pole prázdné,
 * takže by se selhání tvářilo jako „v systému nikdo není". Obojí je táž třída
 * lži — stav, který se popíše jinak, než jaký doopravdy je.
 */
export const stavSeznamuLidi = (v: {
  nacitaSe: boolean;
  chyba: unknown;
  pocetProfilu: number;
  pocetDostupnych: number;
}): StavSeznamuLidi =>
  v.nacitaSe ? 'nacita'
    : v.chyba ? 'chyba'
      : v.pocetProfilu === 0 ? 'nikdo-v-systemu'
        : v.pocetDostupnych === 0 ? 'vse-prirazeno'
          : 'seznam';

/** Co doopravdy uložilo tlačítko „Uložit údaje". */
export type StavUlozeni = 'ulozeno' | 'ulozeno-ale-clovek-ne';

/**
 * JÁDRO PŮVODNÍHO HLÁŠENÍ. Tlačítko „Uložit" ukládá jen název, sazbu a barvu —
 * přiřazení lidí NE. Přesto hlásilo prosté „Uloženo", takže kdo si vybral
 * člověka v rozbalovátku a stiskl jediné tlačítko, které vypadá jako uložení,
 * dostal potvrzení úspěchu za krok, který vůbec neproběhl.
 *
 * Proto se to rozhoduje tady a ne v JSX: tohle je ta věta, která lhala.
 */
export const stavUlozeniUdaju = (v: { vybranyClovek: string }): StavUlozeni =>
  v.vybranyClovek ? 'ulozeno-ale-clovek-ne' : 'ulozeno';
