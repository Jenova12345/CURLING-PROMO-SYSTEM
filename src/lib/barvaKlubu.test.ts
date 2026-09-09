import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { podkladKlubu, pruhKlubu, barvaProRezervaci, PALETA_KLUBU } from './barvaKlubu';

describe('podkladKlubu', () => {
  it('míchá barvu na bílé, takže podklad je vždy světlý', () => {
    // #2563eb = rgb(37,99,235); při 18 % → 255-(255-37)*0.18 = 215.76 → 216
    expect(podkladKlubu('#2563eb')).toBe('rgb(216 227 251)');
  });

  it('i z úplně černé udělá světlý podklad (text na něm musí jít přečíst)', () => {
    // nejtemnější možný vstup dá pořád podklad na 209/255 — tmavý text projde
    expect(podkladKlubu('#000000')).toBe('rgb(209 209 209)');
  });

  it('příliš světlou barvu odmítne — bílý blok na bílé mřížce není vidět', () => {
    expect(podkladKlubu('#ffffff')).toBeUndefined();
    expect(podkladKlubu('#fffffe')).toBeUndefined();   // ani „skoro bílá"
    expect(pruhKlubu('#ffffff')).toBeUndefined();
  });

  it('světlou, ale ještě rozeznatelnou barvu pustí', () => {
    // #d97706 (jantarová z palety) má jas ~0.55 — daleko pod stropem
    expect(podkladKlubu('#d97706')).toBeDefined();
  });

  it('bez barvy nevrací nic — blok si nechá neutrální vzhled', () => {
    expect(podkladKlubu(null)).toBeUndefined();
    expect(podkladKlubu(undefined)).toBeUndefined();
    expect(podkladKlubu('')).toBeUndefined();
  });

  it('nesmyslnou hodnotu zahodí, místo aby ji pustila do CSS', () => {
    // Kdyby prošla, `background: zelena` je neplatné CSS a blok by zůstal
    // průhledný — tiše, bez chyby. Radši výchozí barva.
    expect(podkladKlubu('zelena')).toBeUndefined();
    expect(podkladKlubu('#12345')).toBeUndefined();
    expect(podkladKlubu('#gggggg')).toBeUndefined();
    expect(podkladKlubu('red; background: url(x)')).toBeUndefined();
  });

  it('velká písmena v hexu bere (CHECK v databázi je taky pouští)', () => {
    expect(podkladKlubu('#2563EB')).toBe('rgb(216 227 251)');
  });
});

describe('pruhKlubu', () => {
  it('vrací plnou barvu pro pruh a tečku v legendě', () => {
    expect(pruhKlubu('#059669')).toBe('#059669');
  });

  it('nesmysl nepustí do stylu', () => {
    expect(pruhKlubu('url(javascript:alert(1))')).toBeUndefined();
    expect(pruhKlubu(null)).toBeUndefined();
  });

  it('vrací normalizovanou hodnotu, ne vstup', () => {
    // Kdyby vracel vstup, šla by do `borderLeftColor` i ta mezera na konci —
    // funkce by pustila dál něco jiného, než co ověřila.
    expect(pruhKlubu('  #059669  ')).toBe('#059669');
    expect(pruhKlubu('#059669\u00a0')).toBe('#059669');
    expect(pruhKlubu('#059EEB')).toBe('#059eeb');
  });
});

describe('barvaProRezervaci', () => {
  it('klub dostane svou barvu', () => {
    expect(barvaProRezervaci({ subject_type: 'club', subject_color: '#7c3aed' })).toBe('#7c3aed');
  });

  it('komerční akce zůstává neutrální, i kdyby firma barvu měla', () => {
    // Barvy jsou podle zadání jen pro kluby; komerce se má poznat tím,
    // že barevná NENÍ.
    expect(barvaProRezervaci({ subject_type: 'commercial', subject_color: '#db2777' })).toBeUndefined();
  });

  it('rezervace bez subjektu (údržba) je neutrální', () => {
    expect(barvaProRezervaci({ subject_type: null, subject_color: null })).toBeUndefined();
  });

  it('klub bez nastavené barvy je neutrální, ne rozbitý', () => {
    expect(barvaProRezervaci({ subject_type: 'club', subject_color: null })).toBeUndefined();
  });
});

describe('PALETA_KLUBU', () => {
  it('všechny nabízené barvy jsou platný hex', () => {
    for (const b of PALETA_KLUBU) expect(b.hex).toMatch(/^#[0-9a-f]{6}$/);
  });

  it('žádná se v NABÍDCE neopakuje', () => {
    // Pozor na dosah: tohle hlídá jen paletu, ne přiřazení. Že dva kluby
    // nemají stejnou barvu, si hlídá migrace vlastní kontrolou nad `subjects`
    // (backfill točí paletu `% 6`, takže od sedmého klubu by kolize vznikla).
    expect(new Set(PALETA_KLUBU.map((b) => b.hex)).size).toBe(PALETA_KLUBU.length);
  });

  it('žádná není tak světlá, aby v kalendáři zmizela', () => {
    for (const b of PALETA_KLUBU) expect(pruhKlubu(b.hex)).toBe(b.hex);
  });

  it('prvních šest se shoduje s paletou v MIGRACI (čte se ze SQL, ne z kopie)', () => {
    // Dřív tu stál seznam hexů opsaný ručně. Takový test zůstane zelený i poté,
    // co někdo změní paletu v SQL — tvrdil by shodu, kterou neměří. Proto se
    // čísla tahají z migrace samotné: rozejít se pak nemůžou.
    const sql = readFileSync(
      resolve(__dirname, '../../supabase/migrations/20260909120000_barva_klubu.sql'),
      'utf8',
    );
    // Blok `VALUES (1, '#2563eb'), (2, …)` z definice palety v backfillu.
    const zBackfillu = [...sql.matchAll(/\(\s*\d+\s*,\s*'(#[0-9a-f]{6})'\s*\)/gi)]
      .map((m) => m[1].toLowerCase());
    const prvnichSest = zBackfillu.slice(0, 6);

    expect(prvnichSest).toHaveLength(6);                       // migrace paletu opravdu obsahuje
    expect(PALETA_KLUBU.slice(0, 6).map((b) => b.hex)).toEqual(prvnichSest);
  });
});
