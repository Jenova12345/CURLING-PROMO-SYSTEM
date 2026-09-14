import { describe, it, expect } from 'vitest';
import { popisChybySmeny } from './chybySmen';

/**
 * Co tenhle soubor hlídá nejvíc: že se hlášky v `HLASKY_NASICH_GUARDU`
 * NEROZEJDOU s tím, co databáze opravdu posílá. Přesně na tom se to už jednou
 * rozbilo — `useShifts.ts` hlídal text „již máte jinou směnu", databáze ho od
 * 1. 9. 2026 neposílala a větev byla dva týdny mrtvá, aniž si toho kdo všiml.
 *
 * Testy proto používají DOSLOVNÉ hlášky z `validate_shift_claim()` tak, jak je
 * vrací živé schéma. Když někdo příště změní znění v migraci a zapomene na
 * tenhle soubor, spadne to tady — ne až u uživatele.
 */
describe('popisChybySmeny', () => {
  describe('hlášky z unikátních indexů (anglické, musí se nahradit)', () => {
    const chybaIndexu =
      'duplicate key value violates unique constraint "shifts_jedna_role_na_akci"';

    it('u samoobsluhy mluví na žadatele', () => {
      expect(popisChybySmeny(chybaIndexu, 'záloha', 'sam'))
        .toBe('Na této akci už tuhle roli máte.');
    });

    it('u přiřazení adminem mluví o třetí osobě', () => {
      expect(popisChybySmeny(chybaIndexu, 'záloha', 'nekdoJiny'))
        .toBe('Tenhle člověk už na této akci tuhle roli má.');
    });

    it('bez uvedené perspektivy nepředpokládá, že jde o žadatele samotného', () => {
      // Výchozí `nekdoJiny` je schválně: zápis adminem je ta cesta, kde by
      // „máte" bylo přímo matoucí (týká se někoho jiného).
      expect(popisChybySmeny(chybaIndexu, 'záloha'))
        .toBe('Tenhle člověk už na této akci tuhle roli má.');
    });

    it('pozná i index na trenéra', () => {
      expect(popisChybySmeny(
        'duplicate key value violates unique constraint "shifts_jeden_trener_na_akci"',
        'záloha')).toBe('Na této akci už trenér je.');
    });

    it('syrovou hlášku Postgresu nikdy nepropustí ven', () => {
      const vysledek = popisChybySmeny(chybaIndexu, 'záloha');
      expect(vysledek).not.toContain('duplicate key');
      expect(vysledek).not.toContain('unique constraint');
    });
  });

  describe('hlášky z našich guardů (české, propouští se)', () => {
    // Doslovná znění z `validate_shift_claim()`.
    it.each([
      ['Na této akci už tuhle roli máte.'],
      ['Tuhle směnu už má někdo jiný.'],
      ['Akce je zrušená, směnu na ní vzít nelze.'],
      ['Nemůžete zrušit cizí směnu.'],
      ['Zrušenou směnu znovu otevírá jen správce haly.'],
      ['Do zrušené směny už zapisovat nelze.'],
      ['Uzavřenou směnu znovu otevírá jen správce haly.'],
      ['Roli na směně mění jen správce haly.'],
      ['Směnu nelze přesunout na jinou akci.'],
      ['Identitu ani datum založení směny přepsat nelze.'],
      ['Sazbu, hodiny, vazbu na výplatu ani poznámku si na směně nastavit nemůžete.'],
    ])('propustí %s', (hlaska) => {
      expect(popisChybySmeny(hlaska, 'ZÁLOHA')).toBe(hlaska);
    });

    it('doplní tečku hláškám, které ji v databázi nemají', () => {
      expect(popisChybySmeny('Směna již byla obsazena', 'ZÁLOHA'))
        .toBe('Směna již byla obsazena.');
      expect(popisChybySmeny('Pouze admin může schválit směnu', 'ZÁLOHA'))
        .toBe('Pouze admin může schválit směnu.');
    });

    it('chytí TÉŽ hlášku v obou podobách, s tečkou i bez ní', () => {
      // `validate_shift_claim` obsahuje živě OBĚ varianty téhle věty — jednu
      // ve větvi „zrušení schválené směny" (bez tečky) a druhou v guardu N3
      // (s tečkou). Whitelist je proto veden bez koncové tečky; kdyby ji někdo
      // doplnil, varianta bez tečky by přestala odpovídat a spadla by na zálohu.
      expect(popisChybySmeny('Nemůžete zrušit cizí směnu', 'ZÁLOHA'))
        .toBe('Nemůžete zrušit cizí směnu.');
      expect(popisChybySmeny('Nemůžete zrušit cizí směnu.', 'ZÁLOHA'))
        .toBe('Nemůžete zrušit cizí směnu.');
    });

    it('z hlášky obalené kontextem vrátí JEN tu větu, ne zbytek', () => {
      // PostgREST k hlášce přilepuje kontext s názvem funkce a číslem řádku.
      // To je pro uživatele šum a pro útočníka nápověda o tvaru schématu.
      const sKontextem =
        'Na této akci už tuhle roli máte.\nCONTEXT: PL/pgSQL function validate_shift_claim() line 364 at RAISE';
      const vysledek = popisChybySmeny(sKontextem, 'ZÁLOHA');
      expect(vysledek).toBe('Na této akci už tuhle roli máte.');
      expect(vysledek).not.toContain('validate_shift_claim');
      expect(vysledek).not.toContain('line 364');
    });
  });

  describe('co neznáme, spadne na zálohu', () => {
    it('technická hláška Postgresu se uživateli neukáže', () => {
      expect(popisChybySmeny('permission denied for table shifts', 'ZÁLOHA'))
        .toBe('ZÁLOHA');
      expect(popisChybySmeny('column "foo" does not exist', 'ZÁLOHA'))
        .toBe('ZÁLOHA');
    });

    it('prázdný vstup, undefined i null vrací zálohu a nespadnou', () => {
      expect(popisChybySmeny('', 'ZÁLOHA')).toBe('ZÁLOHA');
      expect(popisChybySmeny(undefined, 'ZÁLOHA')).toBe('ZÁLOHA');
      expect(popisChybySmeny(null, 'ZÁLOHA')).toBe('ZÁLOHA');
    });

    it('PGRST116 (0 řádků) ukáže českou větu, ne hlášku REST vrstvy', () => {
      // TOHLE JE TA NEJČASTĚJŠÍ CHYBOVÁ CESTA. Dotaz má `.eq('status','open')`
      // + `.single()`; když směnu mezitím někdo vzal, vrátí se 0 řádků a
      // supabase-js NASTAVÍ error. Dřívější zápis `shiftErr?.message || '…'`
      // proto českou větu nikdy nepoužil a adminovi vypadla anglická hláška
      // PostgRESTu — a to zrovna v situaci, pro kterou ta věta byla napsaná.
      // PostgREST má pro tenhle stav dvě znění podle verze, hlídáme obě.
      const zaloha = 'Směna již byla obsazena nebo není volná.';
      expect(popisChybySmeny(
        'JSON object requested, multiple (or no) rows returned', zaloha)).toBe(zaloha);
      expect(popisChybySmeny(
        'Cannot coerce the result to a single JSON object', zaloha)).toBe(zaloha);
    });

    it('hlášku o porušení RLS uživateli neukáže', () => {
      expect(popisChybySmeny(
        'new row violates row-level security policy for table "shifts"', 'ZÁLOHA'))
        .toBe('ZÁLOHA');
    });

    it('nepřepisuje zálohu ani u výpadku sítě', () => {
      expect(popisChybySmeny('TypeError: Failed to fetch', 'Nepodařilo se přiřadit směnu.'))
        .toBe('Nepodařilo se přiřadit směnu.');
    });
  });
});
