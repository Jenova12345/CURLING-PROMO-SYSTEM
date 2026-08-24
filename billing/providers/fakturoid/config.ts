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
  /**
   * Co se má s dokladem stát po založení.
   *
   * `koncept` (DEFAULT) — doklad se u Fakturoidu jen založí, e-mail se NEPOSÍLÁ.
   *   Člověk si ho ve Fakturoidu prohlédne a odešle sám. Rozjezdový režim.
   * `odeslat` — po založení se rovnou volá `POST /invoices/{id}/message.json`.
   *
   * ⚠️ POZOR NA SLOVO „KONCEPT": Fakturoid API stav koncept NEZNÁ. Doklad
   * vytvořený přes `POST /invoices.json` je plnohodnotný a UŽ MÁ ČÍSLO v ostré
   * řadě. „Koncept" u nás tedy znamená „vystaveno, ale neodesláno".
   */
  rezim: FakturoidRezim;
}

export type FakturoidRezim = 'koncept' | 'odeslat';

const REZIMY: readonly string[] = ['koncept', 'odeslat'];

const POVINNE = [
  'FAKTUROID_SLUG', 'FAKTUROID_CLIENT_ID', 'FAKTUROID_CLIENT_SECRET', 'FAKTUROID_USER_AGENT',
] as const;

/** „true“/„1“/„yes“ ano, cokoli jiného (i prázdno) ne. */
const jeAno = (hodnota: string | undefined): boolean =>
  ['true', '1', 'yes', 'ano'].includes((hodnota ?? '').trim().toLowerCase());

export const nactiConfig = (env: Record<string, string | undefined>): FakturoidConfig => {
  const chybi = POVINNE.filter((k) => !(env[k] ?? '').trim());
  if (chybi.length > 0) {
    // `pole` je tu POVINNÉ: podle jeho prefixu pozná `kodChyby`, že jde
    // o konfiguraci, ne o vadný podklad. Bez něj by admin u nenastaveného
    // FAKTUROID_CLIENT_SECRET viděl „Podklad k fakturaci není v pořádku"
    // a hledal chybu v rezervacích.
    throw new BillingValidationError(
      `Chybí konfigurace Fakturoidu: ${chybi.join(', ')}. Viz billing/README.md.`,
      'FAKTUROID_KONFIGURACE',
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

  // Neznámá hodnota se NEPŘEKLÁDÁ na default. Překlep `FAKTUROID_MODE=odselat`
  // by tiše znamenal „koncept" a nikdo by se nedivil, proč se nic neodesílá —
  // ani naopak. Prázdno je default, nesmysl je chyba.
  const zadanyRezim = (env.FAKTUROID_MODE ?? '').trim().toLowerCase();
  if (zadanyRezim !== '' && !REZIMY.includes(zadanyRezim)) {
    throw new BillingValidationError(
      `FAKTUROID_MODE musí být „koncept" nebo „odeslat" (dostal jsem „${zadanyRezim}").`,
      'FAKTUROID_MODE',
    );
  }
  const rezim: FakturoidRezim = zadanyRezim === 'odeslat' ? 'odeslat' : 'koncept';

  return {
    slug: env.FAKTUROID_SLUG!.trim(),
    clientId: env.FAKTUROID_CLIENT_ID!.trim(),
    clientSecret: env.FAKTUROID_CLIENT_SECRET!.trim(),
    userAgent: env.FAKTUROID_USER_AGENT!.trim(),
    dueDays: dny,
    jePlatceDph: jeAno(env.IS_VAT_PAYER),
    live: jeAno(env.FAKTUROID_LIVE),
    rezim,
  };
};

/** Základ API pro daný účet. */
export const zakladUrl = (slug: string): string =>
  `https://app.fakturoid.cz/api/v3/accounts/${encodeURIComponent(slug)}`;
