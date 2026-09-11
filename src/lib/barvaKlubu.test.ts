import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  podkladKlubu, pruhKlubu, barvaProRezervaci, PALETA_KLUBU,
  BARVA_KOMERCE, jeKomercni, vzhledRezervace,
} from './barvaKlubu';

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

// -----------------------------------------------------------------------------
// KOMERČNÍ AKCE = SYTĚ ČERVENÁ (zadání 11. 9. 2026)
// -----------------------------------------------------------------------------

/**
 * Kontrast podle WCAG 2.1 — počítá se TADY, ne importem z `barvaKlubu.ts`.
 *
 * Kdyby se sdílel helper, dala by se zesvětlením červené i „opravou" helperu
 * shodit obě strany najednou a test by pořád svítil zeleně. Takhle měří
 * konstantu nezávislým výpočtem.
 */
function kontrastNaBile(hex: string): number {
  const n = parseInt(hex.slice(1), 16);
  const kanaly = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  const L = 0.2126 * kanaly[0] + 0.7152 * kanaly[1] + 0.0722 * kanaly[2];
  return 1.05 / (L + 0.05);            // bílá má relativní luminanci 1
}

describe('BARVA_KOMERCE', () => {
  it('bílý text na ní projde WCAG AA (4,5 : 1 pro běžný text)', () => {
    // Popisky v bloku mají 11–12 px, takže platí hranice pro BĚŽNÝ text,
    // ne pro velký (3 : 1). Kdo červenou zesvětlí, shodí tohle.
    expect(kontrastNaBile(BARVA_KOMERCE.podklad)).toBeGreaterThanOrEqual(4.5);
  });

  it('je opravdu sytá, ne růžová ani bordó', () => {
    // Zadání znělo „sytě červená". Bez tohohle by kontrastní test prošel
    // i černé, i tmavě modré — ty mají kontrastu dost taky.
    const n = parseInt(BARVA_KOMERCE.podklad.slice(1), 16);
    const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    expect(r).toBeGreaterThan(150);          // červený kanál dominuje
    expect(g).toBeLessThan(80);
    expect(b).toBeLessThan(80);
  });

  it('levý pruh je tmavší než podklad, jinak by na něm nebyl vidět', () => {
    expect(kontrastNaBile(BARVA_KOMERCE.pruh))
      .toBeGreaterThan(kontrastNaBile(BARVA_KOMERCE.podklad));
  });

  it('netluče se s žádnou barvou z palety klubů', () => {
    // Zadání tvrdí „žádná kolize". Tvrzení, ne domněnka: palety se nesmí
    // dotknout ani po zaokrouhlení, jinak by uživatel nepoznal komerci
    // od klubu té barvy.
    const hexy = PALETA_KLUBU.map((b) => b.hex);
    expect(hexy).not.toContain(BARVA_KOMERCE.podklad);
    expect(hexy).not.toContain(BARVA_KOMERCE.pruh);
  });
});

describe('jeKomercni', () => {
  it('bere jen typ commercial', () => {
    expect(jeKomercni('commercial')).toBe(true);
  });

  it('NEbere nábor, trénink, turnaj ani údržbu', () => {
    // `recruitment` je schválně mimo: jinde v kalendáři jede s komercí
    // v jedné podmínce (`isCommercial`), ale zadání znělo na `commercial`.
    for (const t of ['recruitment', 'training', 'tournament', 'maintenance', null, undefined, '']) {
      expect(jeKomercni(t)).toBe(false);
    }
  });
});

describe('vzhledRezervace — pořadí KOMERCE > klub > neutrální', () => {
  it('komerční akce je červená s bílým textem', () => {
    const v = vzhledRezervace({ event_type: 'commercial', subject_type: 'commercial' });
    expect(v.podklad).toBe(BARVA_KOMERCE.podklad);
    expect(v.pruh).toBe(BARVA_KOMERCE.pruh);
    expect(v.bilyText).toBe(true);
  });

  it('KOMERCE PŘEBÍJÍ KLUB, i když je subjektem klub s vlastní barvou', () => {
    // Tohle není hypotetický tvar: na produkci je k 11. 9. 2026 jedna
    // rezervace `event_type = 'commercial'` se subjektem typu `club`.
    // Kdyby se ptalo obráceně, byla by to jediná komerční akce v kalendáři,
    // kterou by červená minula — a nikdo by si toho nevšiml.
    const v = vzhledRezervace({
      event_type: 'commercial', subject_type: 'club', subject_color: '#2563eb',
    });
    expect(v.podklad).toBe(BARVA_KOMERCE.podklad);
    expect(v.bilyText).toBe(true);
  });

  it('klubová akce si drží světlý podklad a TMAVÝ text', () => {
    const v = vzhledRezervace({
      event_type: 'training', subject_type: 'club', subject_color: '#2563eb',
    });
    expect(v.podklad).toBe(podkladKlubu('#2563eb'));
    expect(v.pruh).toBe('#2563eb');
    expect(v.bilyText).toBe(false);
  });

  it('podíl zesvětlení se propisuje — chip je sytější než blok v mřížce', () => {
    const blok = vzhledRezervace({ subject_type: 'club', subject_color: '#2563eb' }, 0.18);
    const chip = vzhledRezervace({ subject_type: 'club', subject_color: '#2563eb' }, 0.22);
    expect(blok.podklad).not.toBe(chip.podklad);
    expect(chip.podklad).toBe(podkladKlubu('#2563eb', 0.22));
  });

  it('komerce podíl IGNORUJE — plná barva se zesvětlovat nemá', () => {
    expect(vzhledRezervace({ event_type: 'commercial' }, 0.18).podklad)
      .toBe(vzhledRezervace({ event_type: 'commercial' }, 0.9).podklad);
  });

  it('údržba a rezervace bez klubu zůstávají neutrální', () => {
    for (const r of [
      { event_type: 'maintenance', subject_type: 'club', subject_color: null },
      { event_type: 'training', subject_type: null, subject_color: null },
      { event_type: 'training', subject_type: 'commercial', subject_color: '#2563eb' },
    ]) {
      const v = vzhledRezervace(r);
      expect(v.podklad).toBeUndefined();
      expect(v.bilyText).toBe(false);
    }
  });
});
