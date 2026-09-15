import { describe, expect, it } from 'vitest';
import { nazevKeStazeni } from '../../supabase/functions/_shared/dokladDto';

// Jméno souboru, pod kterým se doklad stáhne. Testuje se odsud (Node), i když
// běží v Edge funkci (Deno) — je to čistá funkce bez sítě a bez databáze.
//
// PROČ NA TO TEST. Do 16. 9. 2026 to byla brána nad textem zdrojáku, a ta
// nechytila nic: mutace „vrať se ke slepému `slice(-4)`" prošla zeleně.
// Tahle funkce se přitom chová u DVOU RŮZNÝCH ČÍSELNÝCH ŘAD jinak, a právě
// ten rozdíl je to, co se dá rozbít.
describe('nazevKeStazeni — dvě číselné řady, dva tvary', () => {
  it('interní doklad: z RRRR+pořadí se bere poslední čtyřčíslí', () => {
    // `20260001` = rok 2026, pořadí 0001 (viz migrace 20260813090000).
    expect(nazevKeStazeni('20260001', 'CK Ostravské kameny', '2026-08-14'))
      .toBe('0001_ck_ostravske_kameny_140826.pdf');
  });

  it('fakturoidí doklad: číslo se bere CELÉ, ne poslední čtyři znaky', () => {
    // `2026-001`. Slepé `slice(-4)` by dalo `-001`, tedy jméno začínající
    // pomlčkou a bez roku — se souborem se pak špatně zachází a nejde poznat,
    // ze kterého roku je. Ověřeno na jediném reálném dokladu na produkci.
    expect(nazevKeStazeni('2026-001', 'Curling Brno, z.s.', '2026-09-16'))
      .toBe('2026001_curling_brno_z_s_160926.pdf');
  });

  it('cokoli mimo URL-bezpečné znaky z čísla vypadne', () => {
    // Název jde do query stringu podepsané URL přes `encodeURI`, který `&`
    // ani `=` neescapuje — jeden takový znak by přilepil parametr navíc.
    expect(nazevKeStazeni('2026&x=1', 'Klub', '2026-09-16'))
      .toBe('2026x1_klub_160926.pdf');
  });

  it('prázdné vstupy dají ošklivé jméno, ne pád', () => {
    // CHECK `fakturoid_vystaveny_ma_udaje` zaručuje, že u vystaveného dokladu
    // je číslo i datum vyplněné, takže sem se to dostat nemá. Kdyby přece,
    // je lepší stažený soubor s divným jménem než rozbitý odkaz.
    // Rok vypadne úplně: '' se rozpadne na jediný prvek, takže den i měsíc
    // spadnou na '00' a z roku se krájí od druhého znaku prázdno.
    expect(nazevKeStazeni('', '', '')).toBe('_odberatel_0000.pdf');
  });
});
