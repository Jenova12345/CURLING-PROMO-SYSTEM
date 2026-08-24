// Konfigurace Fakturoidu z prostředí.
//
// `env` se předává jako parametr, ne čte z globálu — v Denu je to `Deno.env.toObject()`,
// v Node `process.env`, v testech obyčejný objekt. Kdyby si tenhle modul sahal na
// globál sám, nešel by otestovat bez špinění procesu.
//
// CHYBOVÉ HLÁŠKY NIKDY NEVYPISUJÍ HODNOTY. Chybí-li `FAKTUROID_CLIENT_SECRET`,
// řekne se „chybí", ne „dostal jsem ''“ — tyhle zprávy končí v logu Edge funkce.

import { BillingValidationError } from '../../errors.ts';

export interface FakturoidConfig {
  slug: string;
  clientId: string;
  clientSecret: string;
  userAgent: string;
  /** Splatnost ve dnech (`BILLING_DUE_DAYS`). */
  dueDays: number;
  /** `IS_VAT_PAYER` — u neplátce se neposílá DIČ ani sazba DPH. */
  jePlatceDph: boolean;
  /** `FAKTUROID_LIVE` — dokud je false, integrační testy se přeskočí. */
  live: boolean;
}

const POVINNE = [
  'FAKTUROID_SLUG', 'FAKTUROID_CLIENT_ID', 'FAKTUROID_CLIENT_SECRET', 'FAKTUROID_USER_AGENT',
] as const;

/** „true“/„1“/„yes“ ano, cokoli jiného (i prázdno) ne. */
const jeAno = (hodnota: string | undefined): boolean =>
  ['true', '1', 'yes', 'ano'].includes((hodnota ?? '').trim().toLowerCase());

export const nactiConfig = (env: Record<string, string | undefined>): FakturoidConfig => {
  const chybi = POVINNE.filter((k) => !(env[k] ?? '').trim());
  if (chybi.length > 0) {
    throw new BillingValidationError(
      `Chybí konfigurace Fakturoidu: ${chybi.join(', ')}. Viz billing/README.md.`,
    );
  }

  // Splatnost mimo rozsah je překlep, ne záměr — „0“ by znamenalo splatnost dnes
  // a záporná hodnota doklad splatný v minulosti.
  // Prázdný řetězec je „nevyplněno", ne nula: `Number('')` je 0, takže by
  // odkomentovaný, ale nevyplněný řádek v .env shodil start s hláškou o splatnosti.
  const zadano = (env.BILLING_DUE_DAYS ?? '').trim();
  const dny = zadano === '' ? 14 : Number(zadano);
  if (!Number.isInteger(dny) || dny < 1 || dny > 365) {
    // Hodnota se ZÁMĚRNĚ nevypisuje, ačkoli by to tady bylo neškodné: kdo si
    // v `supabase secrets set` prohodí pořadí, dostane do téhle proměnné klíč —
    // a chybová hláška by ho poslala do logu. Hlavička tohohle souboru to slibuje,
    // tak ať to platí i tady.
    throw new BillingValidationError(
      'BILLING_DUE_DAYS musí být celé číslo 1–365. Hodnotu sem záměrně nevypisuju.',
      'BILLING_DUE_DAYS',
    );
  }

  return {
    slug: env.FAKTUROID_SLUG!.trim(),
    clientId: env.FAKTUROID_CLIENT_ID!.trim(),
    clientSecret: env.FAKTUROID_CLIENT_SECRET!.trim(),
    userAgent: env.FAKTUROID_USER_AGENT!.trim(),
    dueDays: dny,
    jePlatceDph: jeAno(env.IS_VAT_PAYER),
    live: jeAno(env.FAKTUROID_LIVE),
  };
};

/** Základ API pro daný účet. */
export const zakladUrl = (slug: string): string =>
  `https://app.fakturoid.cz/api/v3/accounts/${encodeURIComponent(slug)}`;
