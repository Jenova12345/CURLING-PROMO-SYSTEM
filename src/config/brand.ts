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

  /**
   * Dodavatel na faktuře (hala jako provozovatel).
   * ⚠️ Zatím PLACEHOLDER — skutečné údaje dodá klient, pak přepsat tady.
   * Fakturace je v téhle fázi jen ukázka („NÁVRH – UKÁZKA"), ne daňový doklad.
   */
  billing: {
    name: 'Curling Promo Ostrava',
    address: 'Adresa haly — doplnit',
    ico: 'IČO — doplnit',
    dic: 'DIČ — doplnit',
    contact: 'Kontakt — doplnit',
  },
} as const;
