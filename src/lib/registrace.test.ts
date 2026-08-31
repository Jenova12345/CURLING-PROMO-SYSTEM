// Registrace bez klubu nesmí projít.
//
// Není to kosmetika formuláře: bez vybraného klubu nevznikne žádost
// o přiřazení, a účet bez žádosti se NIKOMU neobjeví ve frontě `/requests`.
// Nemá ho tedy kdo schválit — a sám si klub doplnit nemůže, protože čekající
// účet `AppLayout` zastaví na čekací obrazovce a na Profil se nedostane.
// Takový člověk uvázne mezi dveřmi a zjistí to leda telefonátem.
//
// Testuje se SCHÉMA, ne komponenta: `handleSignUp` se ptá `registerFormSchema`,
// takže tohle je totéž rozhodnutí, jen dosažitelné bez jsdom.

import { describe, expect, it } from 'vitest';
import { clubChoiceSchema, registerFormSchema } from './validation';
import { safeValidate } from './validation';

const PLATNY = {
  name: 'Jan Novák',
  email: 'jan@example.cz',
  password: 'DostatecneDlouhe1',
  subjectId: 'aaaa1111-0000-0000-0000-000000000001',
};

describe('registerFormSchema: klub je povinný', () => {
  it('kompletní formulář projde', () => {
    const v = safeValidate(registerFormSchema, PLATNY);
    expect(v.success).toBe(true);
  });

  it('bez klubu (prázdné rozbalovátko) NEPROJDE', () => {
    const v = safeValidate(registerFormSchema, { ...PLATNY, subjectId: '' });
    expect(v.success, 'registrace bez klubu prošla — účet by uvázl mimo frontu ke schválení').toBe(false);
    if (!v.success) expect(v.error).toContain('Vyberte klub');
  });

  it('chybějící pole klubu NEPROJDE (kdyby ho někdo přestal posílat)', () => {
    const { subjectId, ...bezKlubu } = PLATNY;
    expect(safeValidate(registerFormSchema, bezKlubu).success).toBe(false);
  });

  it('podstrčená hodnota, která není uuid, NEPROJDE', () => {
    const v = safeValidate(registerFormSchema, { ...PLATNY, subjectId: 'CK Ostravské kameny' });
    expect(v.success).toBe(false);
    if (!v.success) expect(v.error).toContain('neexistuje');
  });

  it('prázdno a nesmysl mají RŮZNOU hlášku', () => {
    // „Nevybral jsem" a „tohle není klub" jsou jiné chyby a uživatel s nimi
    // dělá něco jiného. Proto vlastní schéma místo holého uuidSchema.
    const prazdno = clubChoiceSchema.safeParse('');
    const nesmysl = clubChoiceSchema.safeParse('neco-jineho');
    expect(prazdno.success).toBe(false);
    expect(nesmysl.success).toBe(false);
    if (!prazdno.success && !nesmysl.success) {
      expect(prazdno.error.issues[0].message).not.toBe(nesmysl.error.issues[0].message);
    }
  });

  // Ostatní pravidla formuláře se přidáním klubu nesměla rozbít.
  it('krátké heslo pořád neprojde', () => {
    // Pod hranicí VALIDATION_LIMITS.PASSWORD_MIN (6). „krátké" má přesně 6
    // znaků, takže projde — proto tu stojí kratší řetězec, ne libovolný.
    expect(safeValidate(registerFormSchema, { ...PLATNY, password: 'ab1' }).success).toBe(false);
  });
  it('nesmyslný e-mail pořád neprojde', () => {
    expect(safeValidate(registerFormSchema, { ...PLATNY, email: 'tohle-není-mail' }).success).toBe(false);
  });
});
