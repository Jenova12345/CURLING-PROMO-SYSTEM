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
  /**
   * `IS_VAT_PAYER` — u neplátce se neposílá DIČ ani sazba DPH.
   *
   * Nesmyslná hodnota je CHYBA, ne default: překlep by tiše znamenal neplátce
   * a doklady by šly bez daně. To se nepozná v logu, ale u finančního úřadu.
   */
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

const ANO: readonly string[] = ['true', '1', 'yes', 'ano'];
const NE: readonly string[] = ['false', '0', 'no', 'ne'];

/** „true“/„1“/„yes“ ano, cokoli jiného (i prázdno) ne. */
const jeAno = (hodnota: string | undefined): boolean =>
  ANO.includes((hodnota ?? '').trim().toLowerCase());

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

  // Táž úvaha jako u FAKTUROID_MODE, a u daňového režimu platí SILNĚJI.
  // `jeAno` bere jen `true/1/yes/ano`, takže `IS_VAT_PAYER=ture` by mlčky
  // znamenalo NEPLÁTCE a doklady by šly bez DPH — a přišlo by se na to
  // u finančního úřadu, ne v logu. Prázdno je default (neplátce), nesmysl chyba.
  const zadanoDph = (env.IS_VAT_PAYER ?? '').trim().toLowerCase();
  if (zadanoDph !== '' && !ANO.includes(zadanoDph) && !NE.includes(zadanoDph)) {
    throw new BillingValidationError(
      `IS_VAT_PAYER musí být „true" nebo „false" (dostal jsem „${zadanoDph}").`,
      'IS_VAT_PAYER',
    );
  }
  // PRÁZDNO UŽ NENÍ „NEPLÁTCE", ALE CHYBA.
  //
  // Dřív chybějící proměnná mlčky znamenala neplátce — a zapomenutý secret
  // v Supabase by tak poslal doklady do ostré číselné řady BEZ 12 % DPH.
  // Přišlo by se na to u finančního úřadu, ne v logu, a opravit to jde jen
  // dobropisem. Daňový režim se proto musí říct nahlas.
  if (zadanoDph === '') {
    throw new BillingValidationError(
      'IS_VAT_PAYER musí být vyplněné („true" pro plátce, „false" pro neplátce). '
      + 'Prázdno se nebere jako neplátce — daňový režim se nehádá.',
      'IS_VAT_PAYER',
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
    rezim,
  };
};

/** Základ API pro daný účet. */
export const zakladUrl = (slug: string): string =>
  `https://app.fakturoid.cz/api/v3/accounts/${encodeURIComponent(slug)}`;

/**
 * Sedí náš daňový režim s tím, co má hala nastavené v databázi?
 *
 * `IS_VAT_PAYER` je proměnná prostředí, `billing_settings.vat_mode` je
 * nastavení v aplikaci. Jsou to dva zdroje téže pravdy a NIKDE se dosud
 * neporovnávaly — takže se mohly rozejít a poznalo by se to až na dokladu.
 *
 * Volá se před vystavením, ne při startu: `vat_mode` se dá přepnout kdykoli
 * za běhu.
 */
export const overDanovyRezim = (jePlatceDph: boolean, vatModeZDb: string | null | undefined): void => {
  const dbPlatce = (vatModeZDb ?? '').trim().toLowerCase() !== 'neplatce';
  if (dbPlatce !== jePlatceDph) {
    throw new BillingValidationError(
      `Daňový režim se rozchází: IS_VAT_PAYER říká ${jePlatceDph ? 'plátce' : 'neplátce'}, `
      + `ale billing_settings.vat_mode je „${vatModeZDb ?? '(nenastaveno)'}". `
      + 'Doklad by odešel v jiném režimu, než v jakém hala účtuje.',
      'IS_VAT_PAYER',
    );
  }
};

/**
 * Smí se na TENHLE účet Fakturoidu doopravdy zapisovat?
 *
 * `FAKTUROID_LIVE` se dosud načítalo do configu a NIKDO HO NEČETL — gatovalo
 * jen přeskakování integračních testů. Ostrý doklad se tedy dal vystavit
 * jedním příkazem, aniž by kdokoli cokoli vědomě zapnul.
 *
 * Zápis proto vyžaduje DVĚ nezávislá potvrzení:
 *   1. `FAKTUROID_LIVE=true` — vědomé zapnutí,
 *   2. shodu `FAKTUROID_SLUG` s účtem, který je výslovně povolený
 *      (`FAKTUROID_POVOLENY_UCET`, jinak `FAKTUROID_TEST_SLUG`).
 *
 * Druhá podmínka je ta důležitá: po přepnutí slugu na ostrý účet přestane
 * platit, dokud někdo ten ostrý účet výslovně nevypíše. Překlep ve slugu tím
 * pádem nevystaví doklad cizímu účtu, jen se odmítne.
 */
export const overPovolenyUcet = (
  cfg: { slug: string; live: boolean },
  env: Record<string, string | undefined>,
): void => {
  if (!cfg.live) {
    throw new BillingValidationError(
      'Zápis do Fakturoidu je vypnutý (FAKTUROID_LIVE není true). '
      + 'Zapni ho vědomě, až budeš chtít doklad opravdu vystavit.',
      'FAKTUROID_LIVE',
    );
  }
  const povoleny = (env.FAKTUROID_POVOLENY_UCET ?? env.FAKTUROID_TEST_SLUG ?? '').trim();
  if (povoleny === '') {
    throw new BillingValidationError(
      'Není řečeno, na který účet Fakturoidu se smí psát. '
      + 'Vyplň FAKTUROID_POVOLENY_UCET (nebo FAKTUROID_TEST_SLUG u testovacího účtu).',
      'FAKTUROID_POVOLENY_UCET',
    );
  }
  if (povoleny !== cfg.slug) {
    throw new BillingValidationError(
      `Účet „${cfg.slug}" není mezi povolenými (povolený je „${povoleny}"). `
      + 'Na ostrý účet se píše až po vědomém povolení — jinak by překlep ve slugu '
      + 'vystavil doklad cizímu účtu.',
      'FAKTUROID_SLUG',
    );
  }
};
