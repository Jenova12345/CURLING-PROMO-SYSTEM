// Které žádosti o klub patří přihlášenému člověku.
//
// Vytažené z `ClenstviVKlubu` do vlastního modulu schválně: je to pravidlo,
// na kterém stojí Jakubův nález ze 4. 9. 2026 (potvrzenému členovi karta
// tvrdila, že mu žádost čeká na vyřízení), a jediná část té cesty, která se
// dá otestovat bez prohlížeče i bez databáze.
//
// PROČ SE TO FILTRUJE AŽ TADY A NE V `useSubjectRequests`: ten hook zásobuje
// i stránku „Žádosti", která celou frontu POTŘEBUJE. Filtrovat v něm by
// opravilo kartu a rozbilo frontu.
//
// Co ten seznam obsahuje: RLS na `subject_requests` pouští vedle vlastních
// řádků i cizí, když je člověk admin nebo zástupce klubu
// (`(user_id = auth.uid()) OR has_role(auth.uid(),'admin') OR is_subject_rep(subject_id)`).
// Pro řadového žadatele je seznam jednoprvkový a filtr nedělá nic; pro admina
// a zástupce klubu je to rozdíl mezi „moje žádost" a „cizí fronta".

/** Minimum z `subject_requests_list`, které filtr potřebuje. */
export interface ZadostOKlub {
  user_id: string | null;
  status: 'ceka' | 'schvalena' | 'zamitnuta' | null;
  decided_at: string | null;
}

/**
 * Jen žádosti přihlášeného člověka.
 *
 * Bez známého `userId` vrací PRÁZDNO, ne všechno. Když nevíme, kdo jsme,
 * je správná odpověď „žádnou žádost ti nepřipisuju" — opačná výchozí hodnota
 * je přesně ta chyba, kterou tenhle modul zavírá.
 */
export const vlastniZadosti = <T extends ZadostOKlub>(
  zadosti: T[],
  userId: string | null | undefined,
): T[] => (userId ? zadosti.filter((z) => z.user_id === userId) : []);

/** Vlastní žádost, která čeká na vyřízení. Databáze pustí nejvýš jednu
 *  (unikátní index `idx_subject_requests_jedna_cekajici` na `user_id`). */
export const cekajiciVlastni = <T extends ZadostOKlub>(
  zadosti: T[],
  userId: string | null | undefined,
): T | undefined => vlastniZadosti(zadosti, userId).find((z) => z.status === 'ceka');

/** Poslední vyřízená vlastní žádost. Historie rozhodnutí patří adminovi,
 *  žadateli stačí ta poslední. */
export const posledniVyrizenaVlastni = <T extends ZadostOKlub>(
  zadosti: T[],
  userId: string | null | undefined,
): T | undefined =>
  vlastniZadosti(zadosti, userId)
    .filter((z) => z.status !== 'ceka')
    .sort((a, b) => (b.decided_at ?? '').localeCompare(a.decided_at ?? ''))[0];
