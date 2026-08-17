import { describe, expect, it } from 'vitest';
import {
  hraniceMesice, nazevArchivu, nazevVArchivu, prehledCsv,
  type DokladProExport,
} from '../../supabase/functions/_shared/mesicniExport';

const d = (p: Partial<DokladProExport> = {}): DokladProExport => ({
  cislo: '20260001',
  odberatel: 'CK Ostravské kameny',
  datum_vystaveni: '2026-08-14',
  datum_splatnosti: '2026-08-28',
  datum_uhrady: null,
  status: 'vystaveno',
  total_rounded: 13750,
  pdf_status: 'ready',
  pdf_path: '2026/20260001/v1.pdf',
  opravuje_cislo: null,
  ...p,
});

describe('hranice měsíce', () => {
  it('sedí i u února a přestupného roku', () => {
    expect(hraniceMesice(2026, 2)).toEqual({ od: '2026-02-01', do: '2026-02-28' });
    expect(hraniceMesice(2028, 2)).toEqual({ od: '2028-02-01', do: '2028-02-29' });
  });

  it('a u prosince (přetečení do dalšího roku)', () => {
    expect(hraniceMesice(2026, 12)).toEqual({ od: '2026-12-01', do: '2026-12-31' });
  });

  it('nesmysl odmítne, ne že tiše vrátí divné období', () => {
    expect(() => hraniceMesice(2026, 13)).toThrow(/měsíc/i);
    expect(() => hraniceMesice(2026, 0)).toThrow(/měsíc/i);
    expect(() => hraniceMesice(1999, 5)).toThrow(/rok/i);
  });
});

describe('jména souborů', () => {
  it('archiv je řaditelný a bez diakritiky', () => {
    expect(nazevArchivu(2026, 8)).toBe('doklady-2026-08.zip');
  });

  it('soubor v archivu začíná číslem dokladu', () => {
    // Účetní hledá podle čísla, ne podle klubu — proto číslo napřed.
    expect(nazevVArchivu(d())).toBe('20260001_ck-ostravske-kameny.pdf');
  });

  it('diakritika jde pryč (ne každý rozbalovač na Windows ji unese)', () => {
    expect(nazevVArchivu(d({ odberatel: 'Příliš žluťoučký kůň' })))
      .toBe('20260001_prilis-zlutoucky-kun.pdf');
  });

  it('opravný doklad je poznat už z názvu', () => {
    expect(nazevVArchivu(d({ cislo: '20260002', opravuje_cislo: '20260001' })))
      .toContain('_opravny-');
  });

  it('chybějící odběratel nevyrobí soubor s prázdným jménem', () => {
    expect(nazevVArchivu(d({ odberatel: null }))).toBe('20260001_odberatel.pdf');
  });
});

describe('přehled v archivu', () => {
  it('vypíše i doklady, které se do archivu NEDOSTALY', () => {
    // Tohle je pointa celého souboru: mlčky vynechaný doklad je horší než
    // chybějící soubor, protože archiv pak vypadá úplně.
    const csv = prehledCsv([d(), d({ cislo: '20260002', pdf_status: 'failed', pdf_path: null })]);
    expect(csv).toContain('20260001');
    expect(csv).toContain('20260002');
    expect(csv).toContain(';NE;');
    expect(csv).toContain('Dokladů bez PDF;1');
  });

  it('má BOM, jinak Excel rozsype češtinu', () => {
    expect(prehledCsv([d()]).charCodeAt(0)).toBe(0xfeff);
  });

  it('uvozovkuje středník v názvu, ať se sloupce nerozjedou', () => {
    const csv = prehledCsv([d({ odberatel: 'Klub; s.r.o.' })]);
    expect(csv).toContain('"Klub; s.r.o."');
  });

  it('součet nepočítá storna ani opravné doklady jako tržbu', () => {
    const csv = prehledCsv([
      d({ total_rounded: 1000 }),
      d({ cislo: '20260002', total_rounded: 400, opravuje_cislo: '20260001' }),
      d({ cislo: '20260003', total_rounded: 700, status: 'stornovano' }),
    ]);
    expect(csv).toContain('Vystaveno celkem;1000.00');
    expect(csv).toContain('Z toho vráceno opravnými doklady;400.00');
  });
});
