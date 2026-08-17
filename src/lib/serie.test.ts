import { describe, expect, it } from 'vitest';
import { nadpisSerie, souhrnSerie } from './serie';
import type { SeriesResult } from '@/hooks/useReservations';

// Tohle je věta, kterou uvidí klient po každém zadání pravidelného tréninku.
// Zadání ji chtělo doslova: „Vytvořeno 18 z 20. Přeskočeno kvůli kolizi: 15. 4., 24. 4."

const vysledek = (prepis: Partial<SeriesResult> = {}): SeriesResult => ({
  series_id: 'aaaa1111-0000-0000-0000-000000000001',
  celkem: 20,
  created: 18,
  skipped: [],
  ...prepis,
});

const preskoceny = (iso: string, duvod: SeriesResult['skipped'][number]['duvod']) => ({
  iso,
  date: iso.split('-').reverse().join('.'),
  duvod,
  reason: 'testovací důvod',
});

describe('nadpisSerie — „Vytvořeno 18 z 20"', () => {
  it('skládá se z toho, co vrátil server', () => {
    expect(nadpisSerie(vysledek())).toBe('Vytvořeno 18 z 20');
  });
});

describe('souhrnSerie — co uvidí klient', () => {
  it('bez přeskočených termínů řekne, že je série celá', () => {
    expect(souhrnSerie(vysledek({ created: 20 }))).toBe('Celá série je v kalendáři.');
  });

  it('kolizní termíny VYJMENUJE, ne jen spočítá', () => {
    // „Přeskočeno 2" se nedá vyřešit; podle data si uživatel shání náhradu.
    const s = souhrnSerie(vysledek({
      skipped: [preskoceny('2026-04-15', 'kolize'), preskoceny('2026-04-24', 'kolize')],
    }));
    expect(s).toBe('Přeskočeno kvůli kolizi: 15. 4., 24. 4.');
  });

  it('drží důvody oddělené — řeší se každý jinak', () => {
    // Kolizi vyřeší jiný čas, zavřenou halu nastavení otevírací doby. Slít to
    // do jedné věty znamená poslat admina hledat na špatné místo.
    const s = souhrnSerie(vysledek({
      skipped: [
        preskoceny('2026-04-15', 'kolize'),
        preskoceny('2026-04-22', 'mimo_otviraci_dobu'),
      ],
    }));
    expect(s).toContain('Přeskočeno kvůli kolizi: 15. 4.');
    expect(s).toContain('Mimo otevírací dobu: 22. 4.');
  });

  it('neexistující čas při posunu na letní čas má vlastní větu', () => {
    // „Kolize" ani „zavřeno" by tady lhaly a uživatel by marně hledal, kdo mu
    // dráhu zabral.
    const s = souhrnSerie(vysledek({
      skipped: [preskoceny('2026-03-29', 'neexistujici_cas')],
    }));
    expect(s).toContain('Čas v daný den neexistuje');
    expect(s).toContain('29. 3.');
    expect(s).not.toContain('kolizi');
  });

  it('u samých zavřených dnů nemluví o kolizi', () => {
    const s = souhrnSerie(vysledek({
      skipped: [preskoceny('2026-04-15', 'mimo_otviraci_dobu')],
    }));
    expect(s).not.toContain('kolizi');
    expect(s).toBe('Mimo otevírací dobu: 15. 4.');
  });

  it('datum formátuje z ISO, ne z předpřipraveného textu', () => {
    // Kdyby se bralo `date`, přišel by tvar „15.04.2026" — ne to, co chtěl klient.
    const s = souhrnSerie(vysledek({ skipped: [preskoceny('2026-01-05', 'kolize')] }));
    expect(s).toContain('5. 1.');
    expect(s).not.toContain('05.01.2026');
  });

  it('dlouhý seznam ořízne, ať toast nepřeteče přes obrazovku', () => {
    // Roční série v den, kdy je hala zavřená, umí vyrobit padesát dat a toast
    // nemá scroll — přetekl by, a to na dvanáct vteřin.
    const hodne = Array.from({ length: 20 }, (_, i) =>
      preskoceny(`2026-04-${String(i + 1).padStart(2, '0')}`, 'kolize'));
    const s = souhrnSerie(vysledek({ skipped: hodne }));
    expect(s).toContain('a další 12');
    expect(s.split(',').length).toBeLessThan(12);
  });

  it('když ISO chybí, spadne zpátky na text ze serveru místo na prázdno', () => {
    const s = souhrnSerie(vysledek({
      skipped: [{ iso: '', date: '15.04.2026', duvod: 'kolize', reason: 'x' }],
    }));
    expect(s).toContain('15.04.2026');
  });
});

describe('starší server (okno mezi nasazením frontendu a migrací)', () => {
  // Frontend se nasazuje z GitHubu sám, migrace se pouští ručně se souhlasem PM.
  // Mezi tím mluví nové UI se starou funkcí, která `celkem` ani `duvod` neposílá.
  const stary = {
    series_id: 'x',
    created: 18,
    skipped: [
      { date: '15.04.2026', reason: 'kolize' },
      { date: '24.04.2026', reason: 'kolize' },
    ],
  } as unknown as SeriesResult;

  it('nadpis nedopadne jako „z undefined"', () => {
    expect(nadpisSerie(stary)).toBe('Vytvořeno 18 z 20');
  });

  it('a přeskočené dny se pořád VYJMENUJÍ, i bez důvodu', () => {
    // Bez zálohy by oba filtry vyšly prázdné a uživatel by se nedozvěděl nic —
    // tedy míň, než uměla verze, kterou nahrazujeme.
    const s = souhrnSerie(stary);
    expect(s).toContain('15.04.2026');
    expect(s).toContain('24.04.2026');
    expect(s).not.toBe('');
  });
});
