import { describe, expect, it } from 'vitest';
import {
  SAZBA_STROP,
  fmtHodin,
  fmtKc,
  fmtSazba,
  fromHal,
  parseSazba,
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

/**
 * Odstraní nedělitelné mezery, ať test nezávisí na tom, čím Node oddělí tisíce.
 * Zapsáno escapem `\u00a0`, ne doslovným znakem — neviditelná mezera v kódu je
 * past pro čtenáře i pro eslint (`no-irregular-whitespace`).
 */
const norm = (s: string) => s.replace(/\u00a0/g, ' ');

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
    //
    // Návrat k „|| 0" je chyba, kterou lze udělat omylem při úklidu, takže se
    // tady hlídá víc než jedním tvrzením — i na celé cestě, kudy jde doklad.
    expect(roundCzk(NaN)).toBeNaN();
    expect(roundCzk(Infinity)).toBe(Infinity);
    expect(roundCzk(-Infinity)).toBe(-Infinity);

    // Nula je legitimní výsledek, ale jen ze skutečné nuly — ne z poruchy.
    expect(roundCzk(0)).toBe(0);
    expect(roundCzk(0.4)).toBe(0);
    expect(Number.isNaN(roundCzk(NaN))).toBe(true);

    // Porucha se nesmí umlčet ani cestou přes mezisoučet a zaokrouhlovací řádek.
    expect(sumKc([1250.5, NaN])).toBeNaN();
    expect(roundingDiff(NaN)).toBeNaN();
    expect(roundCzk(sumKc([1250.5, NaN]))).toBeNaN();
    expect(fmtKc(NaN)).toContain('NaN');
  });

  it('zaokrouhluje STUPŇOVITĚ, přes haléře — kanonické pravidlo R3', () => {
    // Ekvivalent v SQL je round(round(v,2), 0), ne round(v, 0). Na 0,495 je
    // ten rozdíl vidět: stupňovitě 0,495 → 0,50 → 1 Kč, jednorázově 0 Kč.
    // Stupňovitě proto, že částka k úhradě se odvozuje z VYTIŠTĚNÉHO
    // dvoudesetinného mezisoučtu, a základ daně je dvoudesetinný ze zákona.
    expect(roundCzk(0.495)).toBe(1);
    expect(roundCzk(-0.495)).toBe(-1);
    expect(roundCzk(1.495)).toBe(2);
    expect(roundCzk(2.495)).toBe(3);
    expect(roundCzk(-2.495)).toBe(-3);
  });

  it('stupňovité zaokrouhlení odpovídá round(round(v,2),0), ne round(v,0)', () => {
    // NEZÁVISLÁ reference: exaktní desetinná aritmetika nad ZÁPISEM čísla, v BigInt.
    // Nesmí se dotknout ničeho z money.ts — jinak by test jen potvrzoval, že se
    // implementace shoduje sama se sebou, a prošel by i s fází 2, která dělí
    // tisícem místo stem. (Přesně tuhle díru našla brána v první verzi testu.)
    const referenceStupnovite = (zapis: string): number => {
      const zaporne = zapis.startsWith('-');
      const cislo = zaporne ? zapis.slice(1) : zapis;
      const [cela, des = ''] = cislo.split('.');

      // Fáze 1 — na haléře, půlka nahoru.
      let hal = BigInt(cela) * 100n + BigInt(des.slice(0, 2).padEnd(2, '0'));
      if (des.length > 2 && des[2] >= '5') hal += 1n;

      // Fáze 2 — na celé koruny, půlka nahoru. Dělení v BigInt zkracuje k nule,
      // takže „+ 50" před dělením je právě zaokrouhlení půlky nahoru.
      const koruny = Number((hal + 50n) / 100n);
      const vysledek = zaporne ? -koruny : koruny;
      // Postgres numeric zápornou nulu nezná, takže ji nesmí vyrábět ani reference.
      return Object.is(vysledek, -0) ? 0 : vysledek;
    };

    // Smyčku řídí desetinný ZÁPIS, ne double — jinak by se do reference protáhl
    // týž binární šum, který má test odhalovat.
    const zkontroluj = (tis: number) => {
      const zapis = (tis / 1000).toFixed(3);
      expect(roundCzk(Number(zapis))).toBe(referenceStupnovite(zapis));
    };

    // Hustě kolem nuly (±200 Kč po tisícině), kde jsou všechny zajímavé hranice.
    // Krok 3 padne i na .500 i na .495, takže obě rozhodovací situace nastanou.
    let lisiSeOdJednorazoveho = 0;
    for (let tis = -200_000; tis <= 200_000; tis += 3) {
      zkontroluj(tis);

      // Jednorázová varianta ze surové hodnoty — jen pro doložení, že se pravidla
      // opravdu liší. Kdyby se počet propadl na nulu, test by přestal cokoli určovat.
      const v = Number((tis / 1000).toFixed(3));
      if (roundCzk(v) !== Math.sign(v) * Math.round(Math.abs(v))) lisiSeOdJednorazoveho++;
    }

    // Přišpendleno přesně, ne jen „> 0": tichý posun v poměru je taky regrese.
    // Číslo platí pro hustý rozsah výš, proto se počítá jen v něm.
    expect(lisiSeOdJednorazoveho).toBe(667);

    // Řídce až do ±500 000 Kč. Reálné faktury jsou v tisících, tedy nad hustým
    // pásmem — shoda se nesmí opírat jen o okolí nuly.
    for (let tis = -500_000_000; tis <= 500_000_000; tis += 999_983) zkontroluj(tis);
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
    // Pozor na to, co invariant znamená: platí pro KVANTIZOVANÝ mezisoučet, tedy
    // pro číslo, které je na dokladu vytištěné — ne pro surovou hodnotu. To není
    // slabina, to je celý smysl stupňovitého pravidla: doklad sedí sám se sebou.
    for (let tis = -200_000; tis <= 200_000; tis += 3) {
      const surovy = tis / 1000;
      const vytisteny = zeSetin(toSetiny(surovy)); // to, co uvidí zákazník
      expect(sumKc([vytisteny, roundingDiff(surovy)])).toBe(roundCzk(surovy));
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
    // Mez roste s N, není to konstanta. Kdyby test tvrdil jen „≤ 1 Kč" pro dva
    // doklady, prošel by i tehdy, kdyby se zaokrouhlení začalo systematicky
    // vychylovat jedním směrem. Tohle je důvod, proč rozhodnutí R3 porovnává
    // kontrolní součet nad `total`, ne nad `total_rounded`.
    //
    // POZOR, jsou to DVĚ různé meze a záleží, proti čemu se měří:
    //   • proti KVANTIZOVANÉMU součtu (`sumKc`, tedy `total` z R3 — to, co
    //     porovnává kontrolní součet): nejvýš 0,50 Kč na doklad, tedy N/2;
    //   • proti SUROVÉ hodnotě s víc než dvěma desetinnými místy: až 0,505 Kč
    //     na doklad, protože k+0,495 se přes haléře vytáhne až na k+1.
    // Kontrolní součet Etapy 2 jede po první z nich.
    const N = 40;
    const doklady = Array.from({ length: N }, (_, i) => 1250.5 + i * 0.01);
    const celkemZdroj = sumKc(doklady);
    const soucetKUhrade = doklady.reduce((s, d) => s + roundCzk(d), 0);

    expect(Math.abs(soucetKUhrade - celkemZdroj)).toBeLessThanOrEqual(N / 2);
    // Naměřeno na téhle fixtuře; přišpendleno, ať je vidět, když se pohne.
    expect(Number(Math.abs(soucetKUhrade - celkemZdroj).toFixed(2))).toBe(12.2);

    // Nejhorší případ proti kvantizovanému součtu: okno .495, kde stupňovité
    // pravidlo tahá nahoru pokaždé. Mez N/2 se dotkne, ale nepřekročí.
    const nejhorsi = Array.from({ length: N }, (_, i) => i + 0.495);
    const driftNejhorsi = Math.abs(
      nejhorsi.reduce((s, d) => s + roundCzk(d), 0) - sumKc(nejhorsi),
    );
    expect(driftNejhorsi).toBe(N / 2);
  });

  it('proti SUROVÉ hodnotě umí zaokrouhlení překročit půl koruny', () => {
    // Doložení druhé meze z předchozího testu. Není to chyba — je to cena
    // za stupňovitost, kterou R3 vědomě platí kvůli základu daně. Důležité je,
    // že se to nikdy nesčítá do kontrolního součtu, protože ten jede přes `total`.
    //
    // Aby bylo jasné, co ta cena je: jednorázové pravidlo by mělo v téhle metrice
    // mez rovných 0,500. Stupňovité má 0,505 — o 5 haléřů horší v metrice, na které
    // nezáleží, a správné v té, na které záleží (doklad sedí sám se sebou a základ
    // daně je určité vytištěné číslo).
    expect(Math.abs(roundCzk(0.495) - 0.495)).toBeCloseTo(0.505, 10);
    expect(Math.abs(roundCzk(-0.495) - -0.495)).toBeCloseTo(0.505, 10);

    // A že 0,505 je opravdu strop, ne náhodná ukázka.
    let nejvetsi = 0;
    for (let tis = -200_000; tis <= 200_000; tis += 1) {
      const v = tis / 1000;
      nejvetsi = Math.max(nejvetsi, Math.abs(roundCzk(v) - v));
    }
    expect(Number(nejvetsi.toFixed(3))).toBe(0.505);
  });
});

describe('parseSazba — sazba z formulářového pole', () => {
  it('prázdné pole je platný vstup, ne chyba', () => {
    // Znamená „nemá vlastní sazbu, vezmi z ceníku". Kdyby to byla chyba,
    // nešlo by sazbu subjektu zrušit.
    expect(parseSazba('')).toEqual({ hodnota: null });
    expect(parseSazba('   ')).toEqual({ hodnota: null });
  });

  it('vezme celé koruny', () => {
    expect(parseSazba('600')).toEqual({ hodnota: 600 });
    expect(parseSazba(' 1500 ')).toEqual({ hodnota: 1500 });
    expect(parseSazba('1250,00')).toEqual({ hodnota: 1250 });
    expect(parseSazba('1250.00')).toEqual({ hodnota: 1250 });
  });

  it('bere čárku i tečku', () => {
    // Na české klávesnici padne na desetinnou čárku každý.
    expect(parseSazba('1250,50').chyba).toBeTruthy();
    expect(parseSazba('1250.50').chyba).toBeTruthy();
    expect(parseSazba('1250,50').chyba).toBe(parseSazba('1250.50').chyba);
  });

  it('odmítne haléře — to je celé A2 „navíc u zdroje"', () => {
    // Při celokorunové sazbě a čtvrthodinách je hodiny × sazba přesný součin,
    // takže zaokrouhlení nemá co řešit a nález N3 je nedosažitelný.
    for (const vstup of ['1250,50', '600.01', '0,5', '999,99']) {
      expect(parseSazba(vstup).chyba).toBe('Sazba se zadává v celých korunách, bez haléřů.');
      expect(parseSazba(vstup).hodnota).toBeNull();
    }
  });

  it('odmítne nečíslo a nekladné hodnoty', () => {
    expect(parseSazba('abc').chyba).toBeTruthy();
    expect(parseSazba('0').chyba).toBe('Sazba musí být kladná.');
    expect(parseSazba('-600').chyba).toBe('Sazba musí být kladná.');
    expect(parseSazba('Infinity').chyba).toBeTruthy();
    expect(parseSazba('NaN').chyba).toBeTruthy();
  });

  it('nenechá se zmást tím, co Number() bere navíc', () => {
    // Number('0x10') je 16 a Number('1e3') je 1000 — jako sazba by to prošlo
    // a nikdo by to nečekal. Proto vlastní tvar místo holého Number().
    expect(parseSazba('0x10').chyba).toBeTruthy();
    expect(parseSazba('1e3').chyba).toBeTruthy();
    expect(parseSazba('0b1010').chyba).toBeTruthy();
    expect(parseSazba('  ').hodnota).toBeNull();
  });

  it('poradí adminovi, který si sazbu zkopíroval z appky', () => {
    // fmtKc tiskne „1 250 Kč" s úzkou nezlomitelnou mezerou, takže vložit
    // oddělovač tisíců je snadný omyl. Hláška to musí říct rovnou.
    for (const vstup of ['1 250', '1\u00a0250', '1.250,00', '1 250,50']) {
      expect(parseSazba(vstup).chyba).toBeTruthy();
    }
    expect(parseSazba('1 250').chyba).toContain('oddělovač');
  });

  it('drží strop sazby 50 000 Kč/h', () => {
    // Strop je produktové rozhodnutí PM (drift 8g), ne mez datového typu.
    // Zrcadlí CHECK `reservations_rate_per_hour_strop` a spol. — kdyby se obě
    // strany rozešly, formulář by pustil hodnotu, kterou databáze odmítne
    // syrovou hláškou o porušení constraintu.
    expect(SAZBA_STROP).toBe(50_000);
    expect(parseSazba(String(SAZBA_STROP)).hodnota).toBe(SAZBA_STROP);
    expect(parseSazba(String(SAZBA_STROP + 1)).chyba).toContain('50 000');
    expect(parseSazba('100000000').chyba).toContain('50 000');
    // Reálné sazby (600–1 500 Kč/h) i překlep o řád nad nimi musí projít —
    // strop má chytat nesmysly, ne ceník.
    for (const vstup of ['600', '1500', '15000']) {
      expect(parseSazba(vstup).chyba).toBeUndefined();
    }
  });

  it('nepustí sub-haléřové hodnoty jako „celé koruny"', () => {
    // Kdyby se celokorunovost testovala přes toSetiny(x) % 100, zaokrouhlilo by
    // se dřív než rozhodlo — a kolem každé koruny by zůstalo okno ±0,005.
    for (const vstup of ['600.001', '1250,004', '600.0049']) {
      expect(parseSazba(vstup).chyba).toBe('Sazba se zadává v celých korunách, bez haléřů.');
      expect(parseSazba(vstup).hodnota).toBeNull();
    }
  });

  it('při chybě nikdy nevrátí hodnotu k uložení', () => {
    // Aby volající, který zapomene chybu ošetřit, neuložil nesmysl.
    for (const vstup of ['abc', '0', '-1', '1250,50', 'NaN']) {
      expect(parseSazba(vstup).hodnota).toBeNull();
    }
  });

  it('SMLOUVA: co projde validací, uloží databáze beze změny', () => {
    // Vlastnostní test, ne pár ukázek: přes široký vzorek různých tvarů vstupu
    // musí platit, že bez `chyba` je hodnota celé kladné číslo v rozsahu
    // numeric(10,2) a nepřesahuje strop sazby. Zrcadlí CHECKy z A2 a ze stropu
    // sazby (`settings_*_cele_koruny`, `*_strop`).
    const vstupy: string[] = [];
    for (let i = 0; i < 400; i++) {
      vstupy.push(String(i), `${i},00`, `${i}.5`, `${i},001`, `${i}e2`, ` ${i} `, `-${i}`);
    }
    vstupy.push('', '   ', 'abc', '0x10', '1 250', String(SAZBA_STROP), String(SAZBA_STROP + 1));

    let prijatych = 0;
    for (const vstup of vstupy) {
      const v = parseSazba(vstup);
      if (v.chyba) {
        // Při chybě se nikdy nesmí vrátit hodnota k uložení.
        expect(v.hodnota).toBeNull();
        continue;
      }
      if (v.hodnota === null) continue; // prázdné pole = „z ceníku"
      prijatych++;
      expect(Number.isInteger(v.hodnota)).toBe(true);
      expect(v.hodnota).toBeGreaterThan(0);
      expect(v.hodnota).toBeLessThanOrEqual(SAZBA_STROP);
      expect(v.hodnota).toBe(roundCzk(v.hodnota));
    }
    expect(prijatych).toBeGreaterThan(0); // ať test neprojde naprázdno
  });
});
