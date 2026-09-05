// Kdo smí rozhodnout o konkrétní žádosti o členství.
//
// PROČ VLASTNÍ MODUL: je to totéž pravidlo, které hlídá databáze v
// `approve_subject_request` (přesná brána R5: `has_role(admin) OR
// is_subject_rep(_z.subject_id)`). Frontend ho musí umět taky — ne kvůli
// bezpečnosti, tu drží databáze, ale aby nenabízel tlačítko, které nemůže
// uspět. Vytažené zvlášť, ať se to dá otestovat bez prohlížeče i bez DB.
//
// POZOR na past, kvůli které to vzniklo: RLS pouští správci klubu i jeho
// VLASTNÍ žádost do cizího klubu (`user_id = auth.uid()` v politice
// `subject_requests_select`). Takový řádek tedy v seznamu legitimně je,
// ale rozhodnout o něm ten člověk nesmí — od toho je zástupce toho klubu.

/** Minimum ze `subject_requests_list`, které se k rozhodnutí potřebuje. */
export interface ZadostKRozhodnuti {
  subject_id: string | null;
}

/**
 * Smí přihlášený rozhodnout o téhle žádosti (schválit / zamítnout)?
 *
 * @param jeAdmin       správce haly — smí všechno
 * @param mojeKluby     id klubů, kde je přihlášený `subject_reps.level = 'rep'`
 */
export const smiRozhodnout = (
  zadost: ZadostKRozhodnuti,
  jeAdmin: boolean,
  mojeKluby: readonly string[],
): boolean => {
  if (jeAdmin) return true;
  // Žádost bez klubu (klub mezitím zmizel) nemá kdo posoudit než správce haly.
  if (!zadost.subject_id) return false;
  return mojeKluby.includes(zadost.subject_id);
};
