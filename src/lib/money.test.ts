import { describe, expect, it } from 'vitest';
import {
  fmtHodin,
  fmtKc,
  fmtSazba,
  fromHal,
  roundCzk,
  roundingDiff,
  sumHodin,
  sumKc,
  toHal,
  toSetiny,
  zeSetin,
} from './money';

// Testy k rozhodnutí R3 (docs/etapa2-fakturace-plan.md). Chrání jedinou věc:
// aby „suma vystavených faktur == Kdo kolik dluží" platilo doslova, ne přibližně.
//
// Referenční sémantika je Postgres `numeric` — přesná desetinná aritmetika,
// půlka nahoru v absolutní hodnotě. JS má double a půlku k +∞, takže shodu je
// potřeba držet testem; křížové ověření proti živému Postgresu dělá A1b
// (supabase/tests/zaokrouhleni_test.sql).

/** Odstraní nedělitelné mezery, ať test nezávisí na tom, čím Node oddělí tisíce. */
const norm = (s: string) => s.replace(/ /g, ' ');

describe('toSetiny — převod na haléře', () => {
  it('zaokrouhluje půlku nahoru v absolutní hodnotě, ne k +∞', () => {
    // Holé Math.round(-1250.5) dá -1250. Postgres round(-1250.5) dá -1251.
    expect(toSetiny(12.505)).toBe(1251);
    expect(toSetiny(-12.505)).toBe(-1251);
    expect(toSetiny(0.005)).toBe(1);
    expect(toSetiny(-0.005)).toBe(-1);
  });

  it('trefí hranici půlhaléře i tam, kde ji float posune pod ni', () => {
    // 1.005 * 100 === 100.49999999999999 → holé Math.round dá 100, tedy 1,00 Kč,
    // kdežto Postgres round(1.005, 2) = 1.01. Tohle je ta chyba, kterou modul řeší.
    expect(toSetiny(1.005)).toBe(101);
    expect(toSetiny(0.145)).toBe(15);
    expect(toSetiny(-1.005)).toBe(-101);
  });

  it('nemění dnešní vstupy: na celém rozsahu numeric(x,2) je to no-op', () => {
    // Kdyby oprava float šumu posunula byť jedinou existující částku, poznáme to tady.
    const rozdilne: number[] = [];
    for (let hal = -500_000; hal <= 500_000; hal++) {
      if (toSetiny(hal / 100) !== hal) rozdilne.push(hal);
    }
    expect(rozdilne).toEqual([]);
  });

  it('zápornou nulu vrací jako nulu', () => {
    expect(Object.is(toSetiny(-0), 0)).toBe(true);
    expect(Object.is(toSetiny(0), 0)).toBe(true);
  });

  it('sedí na DPH, kvůli které to celé vzniklo', () => {
    // Očekávané hodnoty vytažené z Postgresu (round(základ * 0.21, 2)), ne
    // vymyšlené — sémantika numeric je tady referencí, ne JS.
    const dph = (zaklad: number) => zeSetin(toSetiny(zaklad * 0.21));
    expect(dph(21.5)).toBe(4.52);   // 4.515
    expect(dph(29.5)).toBe(6.2);    // 6.195
    expect(dph(30.5)).toBe(6.41);   // 6.405
    expect(dph(1250.5)).toBe(262.61); // 262.6050
    expect(dph(100)).toBe(21);
    expect(dph(2500)).toBe(525);
  });

  it('poruchu propustí jako poruchu, neudělá z ní nulu', () => {
    // Tichá nula je na dokladu horší než hlasitý NaN: „K úhradě 0 Kč" nikoho
    // netrkne, kdežto „NaN Kč" ano.
    expect(toSetiny(NaN)).toBeNaN();
    expect(toSetiny(Infinity)).toBe(Infinity);
    expect(toSetiny(-Infinity)).toBe(-Infinity);
  });

  it('zeSetin je inverzní k toSetiny', () => {
    for (const v of [0, 1, 1250.5, -1250.5, 0.01, -0.01, 999999.99]) {
      expect(zeSetin(toSetiny(v))).toBeCloseTo(v, 10);
    }
    expect(toHal).toBe(toSetiny);
    expect(fromHal).toBe(zeSetin);
  });
});

describe('roundCzk — zaokrouhlení na celé koruny', () => {
  it('zaokrouhluje půlku nahoru v absolutní hodnotě', () => {
    expect(roundCzk(1250.5)).toBe(1251);
    expect(roundCzk(-1250.5)).toBe(-1251); // Math.round by dal -1250 → koruna rozdílu na dobropisu
    expect(roundCzk(0.5)).toBe(1);
    expect(roundCzk(-0.5)).toBe(-1);
  });

  it('nezaokrouhluje, co zaokrouhlené je', () => {
    expect(roundCzk(1250)).toBe(1250);
    expect(roundCzk(-1250)).toBe(-1250);
    expect(roundCzk(0)).toBe(0);
  });

  it('drží se běžných směrů pod a nad půlkou', () => {
    expect(roundCzk(2.49)).toBe(2);
    expect(roundCzk(2.51)).toBe(3);
    expect(roundCzk(-2.49)).toBe(-2);
    expect(roundCzk(-2.51)).toBe(-3);
  });

  it('je symetrický: roundCzk(-x) === -roundCzk(x)', () => {
    // Schválně se neporovnává proti `-roundCzk(v) || 0`: ten výraz používá týž
    // trik jako implementace, takže by test v tomhle bodě neověřoval nic
    // nezávisle. Velikost a znaménko se proto kontrolují zvlášť.
    for (let hal = 0; hal <= 20_000; hal++) {
      const v = hal / 100;
      const kladny = roundCzk(v);
      const zaporny = roundCzk(-v);
      expect(Math.abs(zaporny)).toBe(kladny);
      expect(Object.is(zaporny, -0)).toBe(false);
    }
  });

  it('nevrací zápornou nulu (Postgres numeric ji nezná)', () => {
    expect(Object.is(roundCzk(-0.4), 0)).toBe(true);
    expect(Object.is(roundCzk(-0), 0)).toBe(true);
  });

  it('poruchu propustí jako poruchu, neudělá z ní 0 Kč', () => {
    // Pozor na „|| 0" místo „+ 0": to je pravdivostní test, takže by spolklo
    // i NaN. Doklad by pak měl mezisoučet „NaN Kč" a k úhradě „0 Kč" — jediné
    // číslo, na které se zákazník dívá, by bylo tiše nulové.
    expect(roundCzk(NaN)).toBeNaN();
    expect(roundCzk(Infinity)).toBe(Infinity);
    expect(roundCzk(-Infinity)).toBe(-Infinity);
  });

  it('zaokrouhluje jedním krokem, ne přes haléře', () => {
    // Dvojí zaokrouhlení dá 0,495 → 0,50 → 1 Kč. Postgres round(0.495) je 0.
    // Křížové ověření proti živé DB našlo na tomhle vzoru 120 rozdílů z 21 717
    // hodnot; po opravě nula. Viz supabase/tests/zaokrouhleni_test.sql.
    expect(roundCzk(0.495)).toBe(0);
    expect(roundCzk(-0.495)).toBe(0);
    expect(roundCzk(1.495)).toBe(1);
    expect(roundCzk(2.495)).toBe(2);
    expect(roundCzk(-2.495)).toBe(-2);
  });
});

describe('roundingDiff — řádek „zaokrouhlení" na dokladu', () => {
  it('dá přesně rozdíl mezi částkou k úhradě a mezisoučtem', () => {
    expect(roundingDiff(3751.5)).toBe(0.5);
    expect(roundingDiff(3751.4)).toBe(-0.4);
    expect(roundingDiff(-3751.5)).toBe(-0.5);
    expect(roundingDiff(1250)).toBe(0);
  });

  it('platí invariant mezisoučet + zaokrouhlení === k úhradě', () => {
    // Tohle je celý smysl toho řádku: doklad musí sedět sám se sebou.
    for (let hal = -300_000; hal <= 300_000; hal += 7) {
      const mezisoucet = hal / 100;
      expect(sumKc([mezisoucet, roundingDiff(mezisoucet)])).toBe(roundCzk(mezisoucet));
    }
  });

  it('invariant drží i na TŘECH desetinných místech', () => {
    // roundingDiff míchá roundCzk (jednokrokový) s toSetiny (přes haléře), takže
    // právě u třídesetinných hodnot by se dvojí zaokrouhlení mohlo schovat.
    // Algebraicky se toSetiny vykrátí, ale u peněz se na algebru nespoléhá.
    for (let tis = -200_000; tis <= 200_000; tis += 3) {
      const mezisoucet = tis / 1000;
      expect(sumKc([mezisoucet, roundingDiff(mezisoucet)])).toBe(roundCzk(mezisoucet));
    }
  });

  it('rozdíl nikdy nepřesáhne půl koruny', () => {
    for (let hal = -100_000; hal <= 100_000; hal += 3) {
      expect(Math.abs(roundingDiff(hal / 100))).toBeLessThanOrEqual(0.5);
    }
  });
});

describe('sumKc — přesný součet částek', () => {
  it('nenechá se rozhodit plovoucí čárkou', () => {
    // Naivní reduce dá 6001.9800000000005 a ten se pak zaokrouhlí jinam.
    expect(sumKc([2000.66, 2000.66, 2000.66])).toBe(6001.98);
    expect(sumKc([0.1, 0.2])).toBe(0.3);
  });

  it('reprodukuje nález N2: tři rezervace po 1 250,50 Kč', () => {
    // Před opravou: obrazovka 3 752 Kč (zaokrouhlen až součet),
    // podklad k fakturaci 3 753 Kč (sečtené zaokrouhlené řádky).
    const radky = [1250.5, 1250.5, 1250.5];
    const mezisoucet = sumKc(radky);
    expect(mezisoucet).toBe(3751.5);

    const stareChovaniDokladu = radky.reduce((s, r) => s + Math.round(r), 0);
    expect(stareChovaniDokladu).toBe(3753); // ← chyba, kterou modul odstranil
    expect(roundCzk(mezisoucet)).toBe(3752); // ← jediná pravda pro obě strany
  });

  it('prázdný součet je nula, ne NaN', () => {
    expect(sumKc([])).toBe(0);
  });

  it('sečte kladné i záporné řádky (dobropis v rámci dokladu)', () => {
    expect(sumKc([1250.5, -1250.5])).toBe(0);
    expect(sumKc([3000, -1250.55])).toBe(1749.45);
  });

  it('nedriftuje ani na dlouhém seznamu', () => {
    const radky = Array.from({ length: 1000 }, () => 0.07);
    expect(sumKc(radky)).toBe(70);
  });
});

describe('sumHodin — přesný součet hodin', () => {
  it('sečte čtvrthodiny bez driftu', () => {
    expect(sumHodin([1.25, 1.25, 1.5])).toBe(4);
    expect(sumHodin(Array.from({ length: 12 }, () => 0.25))).toBe(3);
  });

  it('prázdný součet je nula', () => {
    expect(sumHodin([])).toBe(0);
  });
});

describe('fmtKc — zobrazení částky', () => {
  it('u celých korun haléře netiskne', () => {
    expect(norm(fmtKc(1250))).toBe('1 250 Kč');
    expect(norm(fmtKc(0))).toBe('0 Kč');
  });

  it('haléře NEZAMLČÍ, když nějaké jsou', () => {
    // Starý formátovač měl uvnitř Math.round, takže 3 751,50 ukázal jako 3 752 Kč
    // a tichý rozdíl proti dokladu se nedal na obrazovce vůbec zahlédnout.
    expect(norm(fmtKc(3751.5))).toBe('3 751,50 Kč');
    expect(norm(fmtKc(1250.05))).toBe('1 250,05 Kč');
  });

  it('netiskne zápornou nulu', () => {
    expect(norm(fmtKc(-0))).toBe('0 Kč');
    expect(norm(fmtKc(-0.001))).toBe('0 Kč');
  });

  it('u záporných částek drží znaménko (dobropis)', () => {
    expect(norm(fmtKc(-1250.5))).toBe('-1 250,50 Kč');
  });
});

describe('fmtSazba a fmtHodin', () => {
  it('sazbu tiskne s haléři jako jednotkovou cenu', () => {
    // Náležitost dokladu: sazba se nezaokrouhluje na celé koruny, jinak
    // „1 251 Kč × 2 h = 2 501 Kč" — řádek, který si neodpovídá sám se sebou.
    expect(norm(fmtSazba(1250.5))).toBe('1 250,50 Kč/h');
    expect(norm(fmtSazba(1200))).toBe('1 200 Kč/h');
  });

  it('řádek dokladu sedí: sazba × hodiny === částka', () => {
    const sazba = 1250.5;
    const hodiny = 2;
    expect(zeSetin(toSetiny(sazba * hodiny))).toBe(2501);
    expect(norm(fmtKc(sazba * hodiny))).toBe('2 501 Kč');
  });

  it('hodiny tiskne bez zbytečných nul', () => {
    expect(norm(fmtHodin(2))).toBe('2 h');
    expect(norm(fmtHodin(1.25))).toBe('1,25 h');
  });
});

describe('kontrolní součet od konce', () => {
  it('součet dokladů === součet rezervací, i s ošklivými sazbami', () => {
    // Akceptační kritérium Etapy 2 v malém: rozdělíme rezervace na dva doklady
    // a přesný součet dokladů musí sedět na přesný součet zdroje.
    const rezervace = [
      { hodiny: 1.5, sazba: 1250.5 },
      { hodiny: 2, sazba: 1250.5 },
      { hodiny: 0.75, sazba: 833.33 },
      { hodiny: 3.25, sazba: 999.99 },
      { hodiny: 1, sazba: 1200 },
    ];
    const radek = (r: { hodiny: number; sazba: number }) => zeSetin(toSetiny(r.hodiny * r.sazba));

    const celkemZdroj = sumKc(rezervace.map(radek));
    const doklad1 = sumKc(rezervace.slice(0, 2).map(radek));
    const doklad2 = sumKc(rezervace.slice(2).map(radek));

    expect(sumKc([doklad1, doklad2])).toBe(celkemZdroj);

    // A pozor: součet ZAOKROUHLENÝCH dokladů se od zdroje lišit SMÍ — proto
    // se kontrolní součet dělá nad přesnými částkami, ne nad částkami k úhradě.
    const soucetKUhrade = roundCzk(doklad1) + roundCzk(doklad2);
    expect(Math.abs(soucetKUhrade - celkemZdroj)).toBeLessThanOrEqual(1);
  });

  it('drift částek k úhradě roste s počtem dokladů — proto se nesčítají', () => {
    // Mez je N/2 Kč, ne konstanta. Kdyby test tvrdil jen „≤ 1 Kč" pro dva
    // doklady, prošel by i tehdy, kdyby se zaokrouhlení začalo systematicky
    // vychylovat jedním směrem. Tohle je důvod, proč rozhodnutí R3 porovnává
    // kontrolní součet nad `total`, ne nad `total_rounded`.
    const N = 40;
    const doklady = Array.from({ length: N }, (_, i) => 1250.5 + i * 0.01);
    const celkemZdroj = sumKc(doklady);
    const soucetKUhrade = doklady.reduce((s, d) => s + roundCzk(d), 0);

    expect(Math.abs(soucetKUhrade - celkemZdroj)).toBeLessThanOrEqual(N / 2);
    // A že drift opravdu vzniká — jinak by ta mez nic nehlídala.
    expect(soucetKUhrade).not.toBe(celkemZdroj);
  });
});
