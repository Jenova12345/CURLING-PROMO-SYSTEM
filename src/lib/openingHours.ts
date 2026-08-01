// Otevírací doba haly na jednom místě — formulář, mřížka kalendáře i kontrola
// při přetažení musí počítat stejně jako databáze (trigger validate_reservation_slot).

export type OpeningHours = Record<string, { open?: string; close?: string }>;
export type DayHours = { open: number; close: number };

/** Když nastavení chybí nebo je rozbité: led 7:00–22:00. */
export const DEFAULT_HOURS: DayHours = { open: 7, close: 22 };

function hourOf(value: string | undefined): number {
  // Pozor na prázdný řetězec: Number('') je 0, takže napůl vyplněný den
  // („od" smazané, „do" vyplněné) by jinak znamenal otevřeno od půlnoci.
  if (!value) return NaN;
  return Number(value.split(':')[0]);
}

/** Otevírací doba konkrétního dne (1 = pondělí … 7 = neděle, jako v databázi). */
export function hoursForDay(openingHours: unknown, day: Date | string | null | undefined): DayHours {
  const date = typeof day === 'string' ? new Date(`${day}T00:00`) : day;
  if (!openingHours || typeof openingHours !== 'object' || !date || isNaN(date.getTime())) {
    return DEFAULT_HOURS;
  }
  const isoDay = date.getDay() === 0 ? 7 : date.getDay();
  const entry = (openingHours as OpeningHours)[String(isoDay)];
  const open = hourOf(entry?.open);
  const close = hourOf(entry?.close);
  if (Number.isNaN(open) || Number.isNaN(close) || open >= close) return DEFAULT_HOURS;
  return { open, close };
}

/**
 * Obálka přes všechny dny — jen pro vykreslení mřížky, ať je vidět celý týden
 * v jedné škále. Na validaci se nepoužívá; tam patří hoursForDay konkrétního dne.
 */
export function openingHoursEnvelope(openingHours: unknown): DayHours {
  if (!openingHours || typeof openingHours !== 'object') return DEFAULT_HOURS;
  let open = 24;
  let close = 0;
  let seen = false;
  for (const value of Object.values(openingHours as OpeningHours)) {
    const o = hourOf(value?.open);
    const c = hourOf(value?.close);
    if (Number.isNaN(o) || Number.isNaN(c)) continue;
    open = Math.min(open, o);
    close = Math.max(close, c);
    seen = true;
  }
  if (!seen || open >= close) return DEFAULT_HOURS;
  return { open, close };
}
