import { describe, expect, it } from 'vitest';
import { buildSpayd, spaydQrSvg, spaydText } from './spayd';

// QR kód je jediná část dokladu, kterou zákazník nečte — jen naskenuje a potvrdí.
// Chyba v něm se proto nepozná dřív než na výpisu z účtu, což je přesně důvod,
// proč se řetězec testuje znak po znaku, a ne „vypadá to rozumně".

const IBAN = 'CZ6508000000192000145399';

describe('spaydText — co smí projít do hodnoty', () => {
  it('odstraní diakritiku, ale nechá písmeno', () => {
    expect(spaydText('Pronájem ledové plochy')).toBe('Pronajem ledove plochy');
    expect(spaydText('Žluťoučký kůň')).toBe('Zlutoucky kun');
  });

  it('zabije oddělovače standardu — jinak by se řetězec rozpadl na jiná pole', () => {
    // Hvězdička odděluje pole, dvojtečka klíč od hodnoty. Kdyby prošly, dal by
    // se zprávou pro příjemce podvrhnout třeba jiný účet.
    expect(spaydText('platba*ACC:CZ99')).toBe('platba ACC CZ99');
    expect(spaydText('a*b')).not.toContain('*');
    expect(spaydText('a:b')).not.toContain(':');
  });

  it('vyhodí znaky mimo tisknutelné ASCII', () => {
    expect(spaydText('faktura \n2026')).toBe('faktura 2026');
    expect(spaydText('emoji 🎯 pryč')).toBe('emoji pryc');
  });

  it('smrskne mezery a ořízne kraje', () => {
    expect(spaydText('  hodně    mezer  ')).toBe('hodne mezer');
  });
});

describe('buildSpayd — řetězec QR platby', () => {
  it('sestaví minimální platbu ve tvaru podle standardu', () => {
    expect(buildSpayd({ iban: IBAN, amount: 3400 }))
      .toBe(`SPD*1.0*ACC:${IBAN}*AM:3400.00*CC:CZK`);
  });

  it('částka má vždy dvě desetinná místa a tečku', () => {
    expect(buildSpayd({ iban: IBAN, amount: 1250.5 })).toContain('AM:1250.50');
    expect(buildSpayd({ iban: IBAN, amount: 0 })).toContain('AM:0.00');
    expect(buildSpayd({ iban: IBAN, amount: 1 })).toContain('AM:1.00');
  });

  it('částka jde přes stejnou kvantizaci jako zbytek systému', () => {
    // Bez `toSetiny` by se v QR mohlo objevit 1250.0000000001 nebo o haléř míň,
    // než je na dokladu. Peněžní politika musí být jedna, i pro QR.
    expect(buildSpayd({ iban: IBAN, amount: 1.005 })).toContain('AM:1.01');
    expect(buildSpayd({ iban: IBAN, amount: 0.145 })).toContain('AM:0.15');
  });

  it('doplní variabilní symbol, splatnost, příjemce a zprávu', () => {
    const s = buildSpayd({
      iban: IBAN,
      amount: 3400,
      variableSymbol: '20260001',
      dueDate: new Date(2026, 7, 27),   // 27. 8. 2026
      recipientName: 'Curling Promo Ostrava z.s.',
      message: 'Pronájem ledové plochy',
    });
    expect(s).toContain('X-VS:20260001');
    expect(s).toContain('DT:20260827');
    expect(s).toContain('RN:Curling Promo Ostrava z.s.');
    expect(s).toContain('MSG:Pronajem ledove plochy');
    expect(s.startsWith('SPD*1.0*')).toBe(true);
  });

  it('datum splatnosti bere v místním čase, ne v UTC', () => {
    // `toISOString()` by u půlnoci 1. srpna vrátil 31. 7. — splatnost o den vedle.
    expect(buildSpayd({ iban: IBAN, amount: 1, dueDate: new Date(2026, 7, 1) }))
      .toContain('DT:20260801');
  });

  it('IBAN normalizuje: mezery pryč, velká písmena', () => {
    expect(buildSpayd({ iban: 'cz65 0800 0000 1920 0014 5399', amount: 1 }))
      .toContain(`ACC:${IBAN}`);
  });

  it('odmítne neplatný IBAN místo tichého QR na nikam', () => {
    for (const spatny of ['', 'CZ65', 'XX', '1234567890', 'CZ6508000000192000145399123456789012']) {
      expect(() => buildSpayd({ iban: spatny, amount: 100 })).toThrow(/IBAN/);
    }
  });

  it('odmítne i IBAN se SPRÁVNÝM TVAREM, ale špatným kontrolním součtem', () => {
    // Tohle je riziko 4 z plánu v čisté podobě: skutečný IBAN haly s jednou
    // přepsanou číslicí. Tvarem projde, mod-97 ne — a QR nikdo nečte, takže
    // by se to zjistilo až podle toho, že peníze nedorazily.
    expect(() => buildSpayd({ iban: 'CZ6508000000192000145398', amount: 100 }))
      .toThrow(/kontroln/i);
    expect(() => buildSpayd({ iban: 'CZ0000000000000000000000', amount: 100 }))
      .toThrow(/kontroln/i);
    // A platný projde dál.
    expect(buildSpayd({ iban: IBAN, amount: 100 })).toContain(`ACC:${IBAN}`);
  });

  it('odmítne nesmyslnou částku', () => {
    expect(() => buildSpayd({ iban: IBAN, amount: NaN })).toThrow(/částka/);
    expect(() => buildSpayd({ iban: IBAN, amount: -1 })).toThrow(/částka/);
  });

  it('odmítne příliš dlouhý variabilní symbol místo jeho zkrácení', () => {
    // Zkrácené číslo faktury = platba, kterou nikdo nespáruje.
    expect(() => buildSpayd({ iban: IBAN, amount: 1, variableSymbol: '12345678901' }))
      .toThrow(/variabilní symbol/);
  });

  it('z variabilního symbolu vytáhne jen číslice', () => {
    expect(buildSpayd({ iban: IBAN, amount: 1, variableSymbol: '2026-0001' })).toContain('X-VS:20260001');
  });

  it('prázdné nepovinné hodnoty pole vůbec nepřidají', () => {
    const s = buildSpayd({ iban: IBAN, amount: 1, variableSymbol: '', message: '   ', recipientName: null });
    expect(s).not.toContain('X-VS');
    expect(s).not.toContain('MSG');
    expect(s).not.toContain('RN');
  });

  it('uživatelský text nemůže podvrhnout další pole', () => {
    // Nejdůležitější tvrzení souboru: kdyby zpráva pro příjemce směla obsahovat
    // hvězdičku, dal by se do QR propašovat jiný účet.
    const s = buildSpayd({ iban: IBAN, amount: 100, message: 'test*ACC:CZ1111111111111111111111' });
    expect(s.split('*').filter((p) => p.startsWith('ACC:'))).toHaveLength(1);
    expect(s).toContain(`ACC:${IBAN}`);
  });
});

describe('spaydQrSvg — obrázek QR platby', () => {
  it('vyrobí SVG s klidovou zónou 4 modulů', () => {
    const cellSize = 4;
    const svg = spaydQrSvg({ iban: IBAN, amount: 3400, variableSymbol: '20260001' }, cellSize);
    expect(svg).toContain('<svg');
    expect(svg).toContain('</svg>');

    // Klidová zóna není kosmetika: bez ní čtečka kód z papíru nenajde. Standard
    // žádá 4 moduly, a protože `margin` se knihovně udává ve stejných jednotkách
    // jako `cellSize` (ne v modulech), dá se to splést o čtyřnásobek. Test to
    // proto MĚŘÍ: šířka plátna musí být počet modulů + 8 (čtyři na každé straně).
    const viewBox = svg.match(/viewBox="0 0 (\d+) (\d+)"/);
    expect(viewBox).not.toBeNull();
    const sirka = Number(viewBox![1]);
    expect(Number(viewBox![2])).toBe(sirka);            // čtverec

    const modulu = (svg.match(/<rect/g) ?? []).length;  // jen orientačně, ať test nespoléhá na jediný údaj
    expect(modulu).toBeGreaterThan(0);
    expect(sirka % cellSize).toBe(0);
    const modulyCelkem = sirka / cellSize;
    // QR verze 1–10 má 21–57 modulů; s okrajem 2×4 je to 29–65.
    expect(modulyCelkem).toBeGreaterThanOrEqual(21 + 8);
    expect((modulyCelkem - 8) % 4).toBe(1);             // 21, 25, 29 … = 4n+1
  });

  it('delší data znamenají větší kód, ne chybu', () => {
    const maly = spaydQrSvg({ iban: IBAN, amount: 1 });
    const velky = spaydQrSvg({
      iban: IBAN, amount: 1, variableSymbol: '20260001',
      recipientName: 'Curling Promo Ostrava z.s.',
      message: 'Pronajem ledove plochy za mesic srpen 2026',
      dueDate: new Date(2026, 7, 27),
    });
    expect(velky.length).toBeGreaterThan(maly.length);
  });

  it('neplatný vstup neprojde ani sem — QR na nikam je horší než žádné QR', () => {
    expect(() => spaydQrSvg({ iban: 'nesmysl', amount: 100 })).toThrow(/IBAN/);
  });
});
