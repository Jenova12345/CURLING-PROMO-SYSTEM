// Značka systému na jednom místě — případný další rebrand se dělá tady
// (+ ručně v index.html a public/manifest.json, které jsou mimo React).
export const BRAND = {
  /** Název organizace / systému (hlavička, přihlášení, portál). */
  name: 'Curling Promo Ostrava',
  /** Krátký podtitulek pod názvem. */
  tagline: 'Curlingová hala',
  /** Titulek portálu a stránky s přihlášením. */
  portalTitle: 'Curling Promo Ostrava — rezervační systém',
  /** Popis pro meta tagy a nápovědu. */
  description: 'Systém pro správu curlingové haly Curling Promo Ostrava — kalendář ledu, směny, komunikace',
} as const;
