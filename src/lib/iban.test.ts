import { describe, expect, it } from 'vitest';
import { formatujIban, ibanZUctu, overIban, overModulo11, parseCeskyUcet } from './iban';

// Dopočtený IBAN rozhoduje o tom, kam půjdou peníze. Modul proto nesmí být
// „skoro správně" — a testy musí být ověřitelné z venku, ne opsané z implementace.
//
// Referenční hodnoty: IBAN se dá zkontrolovat nezávisle mod-97 kontrolou
// (ISO 7064), takže každý dopočtený IBAN se tu ověřuje i tou.

describe('parseCeskyUcet', () => {
  it('rozloží číslo s předčíslím i bez něj', () => {
    expect(parseCeskyUcet('19-2000145399/0800').ucet)
      .toEqual({ predcisli: '19', cislo: '2000145399', kodBanky: '0800' });
    expect(parseCeskyUcet('2000145399/0800').ucet)
      .toEqual({ predcisli: '', cislo: '2000145399', kodBanky: '0800' });
  });

  it('ignoruje mezery, včetně nedělitelných', () => {
    // Z internetbankingu se čísla kopírují i s mezerami; odmítnout je by bylo
    // otravné a uživatel by je mazal ručně, což je další příležitost k překlepu.
    expect(parseCeskyUcet(' 19 - 2000145399 / 0800 ').ucet?.cislo).toBe('2000145399');
    expect(parseCeskyUcet('19-2000145399 /0800').ucet?.kodBanky).toBe('0800');
  });

  it('prázdný vstup není chyba (pole je nepovinné)', () => {
    expect(parseCeskyUcet('')).toEqual({ ucet: null });
    expect(parseCeskyUcet('   ')).toEqual({ ucet: null });
  });

  it('odmítne, co číslo účtu není', () => {
    for (const vstup of ['2000145399', '2000145399/080', 'abc/0800', '1/0800', '19-2000145399/08000']) {
      expect(parseCeskyUcet(vstup).chyba).toBeTruthy();
      expect(parseCeskyUcet(vstup).ucet).toBeNull();
    }
  });
});

describe('overModulo11', () => {
  it('pustí platné číslo účtu', () => {
    expect(overModulo11({ predcisli: '19', cislo: '2000145399', kodBanky: '0800' }).ok).toBe(true);
    expect(overModulo11({ predcisli: '', cislo: '2000145399', kodBanky: '0800' }).ok).toBe(true);
  });

  it('pozná, KTERÁ část neprošla', () => {
    // „Číslo účtu je neplatné" člověku neřekne, kde má hledat překlep.
    const spatneCislo = overModulo11({ predcisli: '19', cislo: '2000145398', kodBanky: '0800' });
    expect(spatneCislo.ok).toBe(false);
    expect(spatneCislo.kde).toBe('číslo účtu');

    const spatnePredcisli = overModulo11({ predcisli: '18', cislo: '2000145399', kodBanky: '0800' });
    expect(spatnePredcisli.ok).toBe(false);
    expect(spatnePredcisli.kde).toBe('předčíslí');
  });

  it('prázdné předčíslí se nekontroluje', () => {
    expect(overModulo11({ predcisli: '', cislo: '2000145399', kodBanky: '0800' }).ok).toBe(true);
  });

  it('váhy odpovídají pravidlu ČNB — odvozeno, ne opsáno z modulu', () => {
    // Váhy jsou podle vyhlášky ČNB mocniny dvojky modulo 11, brané zprava.
    // Test si je proto ODVODÍ a postaví vlastní kontrolu; kdyby se v modulu
    // dvě váhy prohodily, tahle smyčka to pozná. Porovnávat proti opsanému poli
    // by nechytilo nic — potvrzovalo by to samo sebe.
    const vaha = (pozicZprava: number) => (2 ** pozicZprava) % 11;
    const referencniKontrola = (cast: string, delka: number): boolean => {
      const doplneno = cast.padStart(delka, '0');
      let soucet = 0;
      for (let i = 0; i < delka; i++) {
        soucet += Number(doplneno[delka - 1 - i]) * vaha(i);
      }
      return soucet % 11 === 0;
    };

    let porovnano = 0;
    for (let seed = 1; seed <= 4000; seed++) {
      // Deterministicky „náhodná" čísla — bez Math.random, ať je běh opakovatelný.
      const cislo = String((seed * 2654435761) % 10_000_000_000).padStart(10, '0');
      const predcisli = String((seed * 40503) % 1_000_000).padStart(6, '0');

      const ocekavano =
        referencniKontrola(predcisli, 6) &&
        referencniKontrola(cislo, 10) &&
        cislo.replace(/0/g, '').length >= 2;

      expect(overModulo11({ predcisli, cislo, kodBanky: '0800' }).ok).toBe(ocekavano);
      porovnano++;
    }
    expect(porovnano).toBe(4000);
  });

  it('zachytí každý překlep v jediné číslici', () => {
    // To je celý smysl kontrolního součtu. Váhy jsou navzájem různé modulo 11,
    // takže změna jedné číslice musí kontrolu vždy shodit.
    const platne = '2000145399';
    let chyceno = 0, zkouseno = 0;
    for (let poz = 0; poz < platne.length; poz++) {
      for (let c = 0; c <= 9; c++) {
        if (String(c) === platne[poz]) continue;
        const prehmat = platne.slice(0, poz) + c + platne.slice(poz + 1);
        zkouseno++;
        if (!overModulo11({ predcisli: '19', cislo: prehmat, kodBanky: '0800' }).ok) chyceno++;
      }
    }
    expect(zkouseno).toBe(90);
    expect(chyceno).toBe(90);
  });
});

describe('ibanZUctu', () => {
  it('spočítá IBAN, který projde nezávislou mod-97 kontrolou', () => {
    // Nezávislost je tu podstatná: kdyby se výsledek porovnával jen s konstantou
    // opsanou z téže implementace, test by potvrzoval sám sebe.
    const vzorky = [
      '19-2000145399/0800',
      '2000145399/0800',
      '000019-2000145399/0800',
      '35-1234567891/0100',
    ];
    for (const ucet of vzorky) {
      const { iban, chyba } = ibanZUctu(ucet);
      expect(chyba).toBeUndefined();
      expect(iban).toMatch(/^CZ\d{22}$/);
      expect(overIban(iban as string)).toBe(true);
    }
  });

  it('sedí na známý referenční IBAN', () => {
    // Účet 19-2000145399/0800 je veřejně uváděný vzorový český IBAN.
    expect(ibanZUctu('19-2000145399/0800').iban).toBe('CZ6508000000192000145399');
  });

  it('doplní vedoucí nulu u jednociferných kontrolních číslic', () => {
    // Tohle je díra, kterou měla sada dřív: žádný ze vzorků neměl kontrolní
    // číslici pod 10, takže odstranění `padStart(2, '0')` prošlo bez povšimnutí —
    // a výsledkem je 23znakový IBAN, který odmítne každá banka.
    const sVedouciNulou = [
      ['35-5609555113/0800', 'CZ0308000000355609555113'],
      ['78-7591177319/0800', 'CZ0508000000787591177319'],
    ] as const;
    for (const [ucet, ocekavany] of sVedouciNulou) {
      const { iban } = ibanZUctu(ucet);
      expect(iban).toBe(ocekavany);
      expect(iban).toHaveLength(24);
      expect(iban?.slice(2, 4)).toMatch(/^0\d$/);
    }
  });

  it('předčíslí i číslo doplní nulami na správnou délku', () => {
    // BBAN musí mít vždy 20 číslic: 4 banka + 6 předčíslí + 10 číslo.
    const { iban } = ibanZUctu('19-2000145399/0800');
    expect(iban?.slice(4)).toBe('0800' + '000019' + '2000145399');
    expect(iban?.slice(4)).toHaveLength(20);
  });

  it('IBAN spočítá i u čísla, které neprojde mod-11 — ale s varováním', () => {
    // Odmítnout ho by bylo horší: historické účty existují a admin je musí umět
    // použít vědomě. Varování je informace, ne blok.
    const { iban, varovani, chyba } = ibanZUctu('19-2000145398/0800');
    expect(chyba).toBeUndefined();
    expect(iban).toMatch(/^CZ\d{22}$/);
    expect(overIban(iban as string)).toBe(true);
    expect(varovani).toContain('číslo účtu');
  });

  it('u platného čísla nevaruje', () => {
    expect(ibanZUctu('19-2000145399/0800').varovani).toBeUndefined();
  });

  it('varuje u účtu ze samých nul', () => {
    // Vážený součet nul je nula, tedy dělitelná jedenácti — mod-11 to pustí.
    // Vyhláška ČNB ale chce v základní části aspoň dvě nenulové číslice a jako
    // placeholder, který někdo zapomene přepsat, je to realistické.
    expect(ibanZUctu('00-0000000000/0800').varovani).toContain('číslo účtu');
    expect(ibanZUctu('0000000010/0800').varovani).toContain('číslo účtu');
  });

  it('nesmyslný vstup nedá IBAN', () => {
    expect(ibanZUctu('nesmysl').iban).toBeNull();
    expect(ibanZUctu('nesmysl').chyba).toBeTruthy();
    expect(ibanZUctu('')).toEqual({ iban: null });
  });

  it('různé účty dají různé IBANy (kontrolní číslice nejsou konstanta)', () => {
    const a = ibanZUctu('19-2000145399/0800').iban;
    const b = ibanZUctu('19-2000145399/0100').iban;
    const c = ibanZUctu('2000145399/0800').iban;
    expect(new Set([a, b, c]).size).toBe(3);
  });
});

describe('overIban', () => {
  it('pozná platný IBAN', () => {
    expect(overIban('CZ6508000000192000145399')).toBe(true);
    expect(overIban('CZ65 0800 0000 1920 0014 5399')).toBe(true); // s mezerami
    expect(overIban('cz6508000000192000145399')).toBe(true);      // malými písmeny
  });

  it('sedí na veřejně publikované vzorové IBANy jiných zemí', () => {
    // KOTVA PRO mod-97, NEZÁVISLÁ NA NAŠEM VÝPOČTU. `overIban` sdílí s `ibanZUctu`
    // funkce `modulo97` i `pismenaNaCisla`, takže „spočítaný IBAN projde kontrolou"
    // o správnosti toho sdíleného jádra nevypovídá nic — potvrzuje jen sám sebe.
    // Tyhle hodnoty jsou z veřejné dokumentace ISO 13616 a náš kód je nevyrobil.
    expect(overIban('GB82WEST12345698765432')).toBe(true);
    expect(overIban('DE89370400440532013000')).toBe(true);
    expect(overIban('SK3112000000198742637541')).toBe(true);
    expect(overIban('AT611904300234573201')).toBe(true);

    // A tytéž s jedinou změněnou číslicí musí padnout.
    expect(overIban('GB82WEST12345698765433')).toBe(false);
    expect(overIban('DE89370400440532013001')).toBe(false);
  });

  it('hlídá délku podle země, ne jen kontrolní číslice', () => {
    // Samotné mod-97 propustí i kratší řetězec — kontrolní číslice si sednou
    // na cokoli. Banka takový IBAN odmítne, my bychom ho pustili do QR platby.
    expect(overIban('CZ340800000019200014539')).toBe(false);   // 23 znaků
    expect(overIban('CZ41080000001920001453997')).toBe(false); // 25 znaků
    expect(overIban('CZ72ABCDEFGHIJ0800000019')).toBe(false);  // písmena v českém BBANu
    expect(overIban('CZ790')).toBe(false);
  });

  it('pozná IBAN s překlepem', () => {
    // Změna jediné číslice musí kontrolu shodit — to je celý smysl mod-97.
    expect(overIban('CZ6508000000192000145398')).toBe(false);
    expect(overIban('CZ6608000000192000145399')).toBe(false);
  });

  it('odmítne, co IBAN není', () => {
    for (const vstup of ['', 'CZ', 'CZ65', '6508000000192000145399', 'CZ65080000001920001453991234567890123']) {
      expect(overIban(vstup)).toBe(false);
    }
  });

  it('chytí prohozené číslice, na což by pouhá délka nestačila', () => {
    const spravny = 'CZ6508000000192000145399';
    const prohozeny = 'CZ6508000000192000145939'; // poslední dvě číslice prohozené
    expect(overIban(spravny)).toBe(true);
    expect(overIban(prohozeny)).toBe(false);
  });
});

describe('formatujIban', () => {
  it('rozdělí po čtveřicích, ať se dá zkontrolovat okem', () => {
    expect(formatujIban('CZ6508000000192000145399')).toBe('CZ65 0800 0000 1920 0014 5399');
  });

  it('je idempotentní — formátovat už zformátovaný nic nezkazí', () => {
    const jednou = formatujIban('CZ6508000000192000145399');
    expect(formatujIban(jednou)).toBe(jednou);
  });
});
