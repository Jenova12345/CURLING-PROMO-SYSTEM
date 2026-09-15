import { describe, expect, it } from 'vitest';
import {
  spoctiObsazenost, obsazenostPodleAkci, volnoProRoli, smenaPatriRoli,
  popisObsazenosti, popisVolnaProRoli, jeObsazeno, zarazSmenu,
} from './obsazenostAkce';

/**
 * Co tenhle soubor hlídá nejvíc: ŽE OBĚ OBRAZOVKY ČTOU TÝŽ VÝPOČET.
 *
 * Kalendář a obrazovka směn si do 15. 9. 2026 počítaly obsazenost každá po svém
 * a u akce Hyundai (5. 12. 2026) ukazovaly „0/3" a „2/3". Testy níž proto jdou
 * DVĚMA vstupními body — `obsazenostPodleAkci` (kudy chodí kalendář) a
 * `spoctiObsazenost` + `volnoProRoli` (kudy chodí nabídka směn) — nad jednou
 * a toutéž sadou dat, a trvají na tom, že hlavní metrika vyjde stejně.
 *
 * Mutační důkaz: rozbij cokoli v `spoctiObsazenost` nebo v `zarazSmenu` a
 * zčervenají OBĚ větve najednou. Kdyby některá měla vlastní výpočet, spadla by
 * jen jedna — a přesně to je ten stav, kterému se vyhýbáme.
 */

// Skutečná data z produkce, 15. 9. 2026: tři pozice, všechny volné,
// role 2× instruktor + 1× barman, nikdo nic nevzal.
const HYUNDAI = 'ev-hyundai';
const SMENY_HYUNDAI = [
  { event_id: HYUNDAI, status: 'open', required_role: 'instructor' },
  { event_id: HYUNDAI, status: 'open', required_role: 'instructor' },
  { event_id: HYUNDAI, status: 'open', required_role: 'bar_staff' },
];

const INSTRUKTOR = { role: ['hobby_player', 'instructor'], isAdmin: false };
const BARMAN = { role: ['hobby_player', 'bar_staff'], isAdmin: false };
const HOBBY = { role: ['hobby_player'], isAdmin: false };
const ADMIN = { role: ['admin', 'hobby_player'], isAdmin: true };

describe('akce Hyundai 5. 12. — ticket, kvůli kterému to vzniklo', () => {
  it('kalendář (obsazenostPodleAkci) hlásí Obsazeno 0/3', () => {
    const mapa = obsazenostPodleAkci(SMENY_HYUNDAI);
    expect(mapa[HYUNDAI].obsazeno).toBe(0);
    expect(mapa[HYUNDAI].total).toBe(3);
    expect(popisObsazenosti(mapa[HYUNDAI])).toBe('Obsazeno 0/3');
  });

  it('obrazovka směn (spoctiObsazenost) hlásí TOTÉŽ, ne 2/3', () => {
    const o = spoctiObsazenost(SMENY_HYUNDAI);
    expect(o.obsazeno).toBe(0);
    expect(o.total).toBe(3);
    expect(popisObsazenosti(o)).toBe('Obsazeno 0/3');
    // Původní chyba: čitatel profiltrovaný podle rolí proti nefiltrovanému
    // jmenovateli. Instruktor viděl „2/3". Tahle věta to zakazuje.
    expect(popisObsazenosti(o)).not.toBe('Obsazeno 2/3');
  });

  it('OBĚ CESTY VRACÍ STEJNÁ ČÍSLA (důkaz, že čtou týž zdroj)', () => {
    const kalendar = obsazenostPodleAkci(SMENY_HYUNDAI)[HYUNDAI];
    const smeny = spoctiObsazenost(SMENY_HYUNDAI);
    expect(kalendar).toEqual(smeny);
    expect(popisObsazenosti(kalendar)).toBe(popisObsazenosti(smeny));
  });

  it('role řeší až doplňkové „Volné pro tvoji roli", ne hlavní metrika', () => {
    const o = spoctiObsazenost(SMENY_HYUNDAI);
    expect(volnoProRoli(o, INSTRUKTOR)).toBe(2);
    expect(volnoProRoli(o, BARMAN)).toBe(1);
    expect(volnoProRoli(o, ADMIN)).toBe(3);
    expect(volnoProRoli(o, HOBBY)).toBe(0);
    // A jmenovatel se přitom nikomu nemění — to je ten rozdíl proti starému stavu.
    expect(o.total).toBe(3);
  });

  it('barmanská pozice nezmizí jen proto, že se na ni dívá instruktor', () => {
    const o = spoctiObsazenost(SMENY_HYUNDAI);
    const barmani = o.podleRoli.find((r) => r.role === 'bar_staff');
    expect(barmani?.volno).toBe(1);
    expect(popisVolnaProRoli(volnoProRoli(o, INSTRUKTOR))).toBe('Volné pro tvoji roli: 2');
  });
});

/**
 * SMÍŠENÁ AKCE — tenhle blok je ten mutační důkaz.
 *
 * Každý stav z enumu `shift_status` je tu zastoupený a čte se PŘES OBA vstupní
 * body zároveň: `obsazenostPodleAkci` (kalendář) a `spoctiObsazenost`
 * (obrazovka směn). Ať v `zarazSmenu` nebo ve `spoctiObsazenost` rozbiješ
 * cokoli, spadnou obě věty najednou — to je to, co se tím dokazuje.
 */
describe('obě obrazovky nad jednou smíšenou akcí', () => {
  const AKCE = 'ev-smisena';
  const SMENY = [
    { event_id: AKCE, status: 'claimed', required_role: 'instructor' },
    { event_id: AKCE, status: 'completed', required_role: 'instructor' },
    { event_id: AKCE, status: 'pending', required_role: 'instructor' },
    { event_id: AKCE, status: 'open', required_role: 'instructor' },
    { event_id: AKCE, status: 'open', required_role: 'bar_staff' },
    { event_id: AKCE, status: 'cancelled', required_role: 'bar_staff' },
  ];

  it('kalendář: Obsazeno 2/5', () => {
    const o = obsazenostPodleAkci(SMENY)[AKCE];
    expect(o).toMatchObject({ total: 5, obsazeno: 2, ceka: 1, volno: 2 });
    expect(popisObsazenosti(o)).toBe('Obsazeno 2/5');
  });

  it('obrazovka směn: Obsazeno 2/5 a k tomu volná místa podle role', () => {
    const o = spoctiObsazenost(SMENY);
    expect(o).toMatchObject({ total: 5, obsazeno: 2, ceka: 1, volno: 2 });
    expect(popisObsazenosti(o)).toBe('Obsazeno 2/5');
    expect(volnoProRoli(o, INSTRUKTOR)).toBe(1);
    expect(volnoProRoli(o, BARMAN)).toBe(1);
    expect(volnoProRoli(o, ADMIN)).toBe(2);
    expect(volnoProRoli(o, HOBBY)).toBe(0);
  });

  it('a shodnou se do posledního pole', () => {
    expect(obsazenostPodleAkci(SMENY)[AKCE]).toEqual(spoctiObsazenost(SMENY));
  });
});

describe('překlad stavu směny na význam', () => {
  it.each([
    ['claimed', 'obsazeno'],
    ['completed', 'obsazeno'],
    ['pending', 'ceka'],
    ['open', 'volno'],
    ['cancelled', 'zruseno'],
  ] as const)('%s => %s', (status, ocekavano) => {
    expect(zarazSmenu(status)).toBe(ocekavano);
  });

  it('neznámý stav se NENABÍDNE jako volné místo (fail-closed)', () => {
    // Kdyby v enumu `shift_status` přibyla šestá hodnota, ať radši chybí
    // v nabídce, než aby se nabízela směna, která nabídka není.
    expect(zarazSmenu('neco_noveho')).toBe('jine');
    expect(zarazSmenu(null)).toBe('jine');
    expect(zarazSmenu(undefined)).toBe('jine');
    const o = spoctiObsazenost([{ status: 'neco_noveho', required_role: 'instructor' }]);
    expect(o.total).toBe(1);
    expect(o.volno).toBe(0);
    expect(volnoProRoli(o, INSTRUKTOR)).toBe(0);
  });
});

describe('zrušená směna není pozice', () => {
  // Na produkci mělo 15. 9. 2026 sedm akcí zrušené VŠECHNY směny a kalendář
  // u nich hlásil „0/1" nebo „0/2" — nesplnitelný úkol, který nešel odklidit.
  it('do jmenovatele se nepočítá', () => {
    const o = spoctiObsazenost([
      { status: 'claimed', required_role: 'instructor' },
      { status: 'cancelled', required_role: 'instructor' },
      { status: 'open', required_role: 'bar_staff' },
    ]);
    expect(o.total).toBe(2);
    expect(o.obsazeno).toBe(1);
    expect(o.volno).toBe(1);
    expect(popisObsazenosti(o)).toBe('Obsazeno 1/2');
  });

  it('akce, kde je zrušené všechno, nemá co vypisovat', () => {
    const o = spoctiObsazenost([
      { status: 'cancelled', required_role: 'instructor' },
      { status: 'cancelled', required_role: 'instructor' },
    ]);
    expect(o.total).toBe(0);
    expect(o.podleRoli).toEqual([]);
    // `total = 0` je ta podmínka, na kterou se obrazovky ptají, než čítač vykreslí.
    expect(jeObsazeno(o)).toBe(false);
  });
});

describe('pending není ani obsazeno, ani volno', () => {
  it('má vlastní číslo a drží invariant total = obsazeno + ceka + volno', () => {
    const o = spoctiObsazenost([
      { status: 'claimed', required_role: 'instructor' },
      { status: 'pending', required_role: 'instructor' },
      { status: 'open', required_role: 'bar_staff' },
    ]);
    expect(o).toMatchObject({ total: 3, obsazeno: 1, ceka: 1, volno: 1 });
    expect(o.obsazeno + o.ceka + o.volno).toBe(o.total);
    // Přihláška čekající na schválení se NESMÍ nabízet jako volné místo.
    expect(volnoProRoli(o, INSTRUKTOR)).toBe(0);
  });
});

describe('kdo smí kterou směnu', () => {
  it('admin vidí všechno', () => {
    expect(smenaPatriRoli('bar_staff', ADMIN)).toBe(true);
  });
  it('bez požadované role je směna pro celý štáb (starší data)', () => {
    expect(smenaPatriRoli(null, HOBBY)).toBe(true);
    expect(smenaPatriRoli(undefined, HOBBY)).toBe(true);
  });
  it('cizí roli si nikdo nevezme', () => {
    expect(smenaPatriRoli('bar_staff', INSTRUKTOR)).toBe(false);
    expect(smenaPatriRoli('instructor', BARMAN)).toBe(false);
  });
  it('směna bez role se počítá do „volné pro tvoji roli" každému', () => {
    const o = spoctiObsazenost([{ status: 'open', required_role: null }]);
    expect(volnoProRoli(o, HOBBY)).toBe(1);
  });
});

describe('rozpad po rolích', () => {
  it('je stabilně seřazený, směny bez role poslední', () => {
    const o = spoctiObsazenost([
      { status: 'open', required_role: null },
      { status: 'open', required_role: 'instructor' },
      { status: 'open', required_role: 'bar_staff' },
    ]);
    expect(o.podleRoli.map((r) => r.role)).toEqual(['bar_staff', 'instructor', null]);
  });

  it('čísla v koších sedí se součtem', () => {
    const o = spoctiObsazenost([
      { status: 'claimed', required_role: 'instructor' },
      { status: 'open', required_role: 'instructor' },
      { status: 'open', required_role: 'bar_staff' },
      { status: 'cancelled', required_role: 'bar_staff' },
    ]);
    expect(o.podleRoli.reduce((n, r) => n + r.total, 0)).toBe(o.total);
    expect(o.podleRoli.reduce((n, r) => n + r.volno, 0)).toBe(o.volno);
    expect(o.podleRoli.find((r) => r.role === 'bar_staff')).toMatchObject({ total: 1, volno: 1 });
  });
});

describe('popisky — jedno znění pro celou aplikaci', () => {
  it('hlavní metrika', () => {
    expect(popisObsazenosti({ total: 3, obsazeno: 2, ceka: 0, volno: 1, podleRoli: [] }))
      .toBe('Obsazeno 2/3');
  });
  it('doplněk pro brigádníka', () => {
    expect(popisVolnaProRoli(0)).toBe('Volné pro tvoji roli: 0');
    expect(popisVolnaProRoli(2)).toBe('Volné pro tvoji roli: 2');
  });
});

describe('jeObsazeno', () => {
  it('plná akce ano, nedoobsazená ne', () => {
    expect(jeObsazeno({ total: 2, obsazeno: 2, ceka: 0, volno: 0, podleRoli: [] })).toBe(true);
    expect(jeObsazeno({ total: 2, obsazeno: 1, ceka: 1, volno: 0, podleRoli: [] })).toBe(false);
  });
  it('akce bez pozic obsazená NENÍ — nemá co obsazovat', () => {
    expect(jeObsazeno({ total: 0, obsazeno: 0, ceka: 0, volno: 0, podleRoli: [] })).toBe(false);
  });
});

describe('okrajové vstupy nespadnou', () => {
  it('prázdno, null i undefined', () => {
    expect(spoctiObsazenost([])).toMatchObject({ total: 0, podleRoli: [] });
    expect(spoctiObsazenost(null)).toMatchObject({ total: 0 });
    expect(spoctiObsazenost(undefined)).toMatchObject({ total: 0 });
    expect(obsazenostPodleAkci(null)).toEqual({});
  });
  it('směna bez akce se do žádné akce nezapočítá', () => {
    expect(obsazenostPodleAkci([{ event_id: null, status: 'open' }])).toEqual({});
  });
  it('akce se seskupí odděleně', () => {
    const mapa = obsazenostPodleAkci([
      { event_id: 'a', status: 'open' },
      { event_id: 'b', status: 'claimed' },
      { event_id: 'a', status: 'claimed' },
    ]);
    expect(popisObsazenosti(mapa.a)).toBe('Obsazeno 1/2');
    expect(popisObsazenosti(mapa.b)).toBe('Obsazeno 1/1');
  });
});
