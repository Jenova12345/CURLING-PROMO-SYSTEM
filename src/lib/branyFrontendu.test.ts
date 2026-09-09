// Testy HRANICE, ne logiky — stejný žánr jako `billing/hranice.test.ts`.
//
// Dvě věci z brány (ultra review, 31. 8. 2026) se odehrávají v komponentách,
// a tenhle repo nemá jsdom ani testing-library, takže se nedají „kliknout".
// Obojí je ale POŘADÍ / VĚTEV, kterou jde spolehlivě přečíst ze zdrojáku —
// a přečíst ji je nekonečně lepší než na ni nemít nic.
//
// Kdyby sem někdo přidal komponentové testy, tyhle můžou zmizet. Do té doby
// jsou to jediné pojistky, které ty dvě opravy drží.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const KOREN = join(import.meta.dirname!, '..', '..');
const cti = (relativni: string) => readFileSync(join(KOREN, relativni), 'utf8');

describe('ReservationDialog: typ akce se mění PŘED sazbou', () => {
  // `zmen_typ_akce` nastaví `rate_per_hour = NULL` a nechá trigger ocenit
  // z ceníku. Když se tedy nejdřív uloží ruční sazba a teprve pak změní typ,
  // sazba se TIŠE ZAHODÍ — uživatel vidí „Rezervace upravena" a svoje číslo
  // ve formuláři, ale fakturuje se ceníková cena.
  it('zmenTypAkce je v ukládání dřív než upravSazbuAkce', () => {
    const zdroj = cti('src/components/reservations/ReservationDialog.tsx');

    const typ = zdroj.indexOf('api.zmenTypAkce(');
    const sazba = zdroj.indexOf('api.upravSazbuAkce(');

    expect(typ, 'volání api.zmenTypAkce v dialogu zmizelo').toBeGreaterThan(-1);
    expect(sazba, 'volání api.upravSazbuAkce v dialogu zmizelo').toBeGreaterThan(-1);
    expect(typ,
      'upravSazbuAkce se volá PŘED zmenTypAkce. Změna typu přecení akci z ceníku, ' +
      'takže ručně zadaná sazba se tím zahodí — a nikde to není vidět.',
    ).toBeLessThan(sazba);
  });
});

describe('Přihlášení: nenačtený profil = zavřeno', () => {
  const auth = cti('src/contexts/AuthContext.tsx');

  it('AuthContext hlásí nedostupný profil, když ho nedostal', () => {
    // Dřív se v téhle větvi nedělo nic, takže `profile` zůstal null,
    // `cekaNaSchvaleni` vyšlo false a uživatel prošel do aplikace, ve které
    // mu RLS nic nevydá — prázdný kalendář a prázdné menu.
    expect(auth).toContain('profilNedostupny');
    expect(auth.match(/setProfilOk\(false\)/g)?.length ?? 0,
      'chybí větev, která po neúspěšném načtení profilu zavře přístup',
    ).toBeGreaterThanOrEqual(2);   // prázdná odpověď + catch
  });

  it('AppLayout na nedostupný profil reaguje vlastní obrazovkou', () => {
    const layout = cti('src/components/layout/AppLayout.tsx');
    expect(layout).toContain('profilNedostupny');
    // Musí to být větev, která vrací UI, ne jen přečtená proměnná.
    expect(layout).toMatch(/if\s*\(profilNedostupny\)/);
  });
});

describe('Trenér se nečte ze `shifts`', () => {
  // `shifts` nemá SELECT politiku pro zástupce klubu, takže mu přímý dotaz
  // vrací nula řádků BEZ CHYBY — UI pak tvrdí „trenér nepřiřazen" i po
  // úspěšném přiřazení a zástupce přiřadí znovu (druhá placená směna).
  it('useReservations čte trenéra přes RPC trener_akce', () => {
    const hook = cti('src/hooks/useReservations.ts');
    expect(hook).toContain("supabase.rpc('trener_akce'");
    // Obsazenost štábu (`shiftFill`) ze `shifts` číst SMÍ — je vypnutá pro
    // kohokoli mimo admina a staff (`enabled`). Zakázaná je jen ta cesta,
    // která hledá TRENÉRA: ta se zástupci klubu tiše rozbije.
    expect(hook,
      'hook zase hledá trenérskou směnu přímo v tabulce shifts — zástupci ' +
      'klubu se tím trenér stane neviditelným.',
    ).not.toContain("required_role");
  });

  it('přání trenéra se ukládá přes RPC, ne přímým UPDATE sloupce', () => {
    const hook = cti('src/hooks/useReservations.ts');
    expect(hook).toContain("supabase.rpc('nastav_prani_trenera'");
    expect(hook).not.toMatch(/update\(\{\s*preferovany_trener/);
  });
});

describe('Registrace: klub se nedá přeskočit', () => {
  const auth = cti('src/pages/Auth.tsx');

  it('rozbalovátko klubu je required a nemá volbu „žádný"', () => {
    // Volba s prázdnou hodnotou smí být jen ta úvodní výzva; kdyby se vrátila
    // možnost „Zatím žádný / nevím", vznikl by účet bez žádosti — a ten se
    // nikomu neobjeví ve frontě ke schválení.
    expect(auth).not.toContain('Zatím žádný');
    expect(auth).not.toContain('Klub (nepovinné)');
    // Vyříznu si celý blok <select>, ať test nestojí na tom, jak dlouhý je
    // className — ten má přes 300 znaků a jakékoli okno {0,N} je hádání.
    const zacatek = auth.indexOf('id="register-club"');
    const konec = auth.indexOf('</select>', zacatek);
    expect(zacatek, 'rozbalovátko klubu z formuláře zmizelo').toBeGreaterThan(-1);
    const vyber = auth.slice(zacatek, konec);
    expect(vyber, 'select klubu není required — formulář by šel odeslat prázdný').toContain('required');
  });

  it('klub jde do validace, ne rovnou do signUp', () => {
    // `registerClub || undefined` znamenalo „prázdno je taky odpověď".
    expect(auth).toContain('subjectId: registerClub');
    expect(auth).not.toContain('registerClub || undefined');
  });
});

describe('Edge funkce: frontu obsluhuje jen server', () => {
  // `verify_jwt` na platformě propustí i PUBLISHABLE klíč, který jede v každém
  // prohlížeči — takže „přihlášený uživatel" není závora. Funkce, které jedou
  // pod servisním klíčem (a obcházejí tím RLS), si musí volajícího ověřit samy.
  const FUNKCE = ['send-emails', 'invoice-pdf'];

  it.each(FUNKCE)('%s porovnává Authorization se servisním klíčem', (jmeno) => {
    const zdroj = cti(`supabase/functions/${jmeno}/index.ts`);
    expect(zdroj, `${jmeno} nečte hlavičku Authorization`).toMatch(/headers\.get\(['"]Authorization['"]\)/);
    expect(zdroj,
      `${jmeno} neporovnává Authorization se servisním klíčem — pak ji zavolá ` +
      'kdokoli s veřejným klíčem z bundlu.',
    ).toMatch(/auth\.includes\(/);
  });
});

describe('Registrace: heslo se zadává dvakrát a jde zobrazit', () => {
  const auth = cti('src/pages/Auth.tsx');

  it('formulář má druhé pole na heslo', () => {
    expect(auth).toContain('id="register-password-again"');
    expect(auth).toContain('passwordAgain: registerPasswordAgain');
  });

  it('obě pole poslouchají jeden přepínač zobrazení', () => {
    // Dvě nezávislá očička jsou klikání navíc: kdo si heslo kontroluje,
    // chce vidět obě pole naráz.
    const kolik = (auth.match(/type=\{heslaVidet \? 'text' : 'password'\}/g) ?? []).length;
    expect(kolik, 'přepínač zobrazení nepokrývá obě pole').toBe(2);
  });
});

describe('ReservationDialog: „Celková cena" nepošle nic, co admin nenapsal', () => {
  const zdroj = cti('src/components/reservations/ReservationDialog.tsx');
  const hook = cti('src/hooks/useReservations.ts');

  // Dialog je v kalendáři mountnutý trvale (`open` jen přepíná Radix), takže
  // `useState` přežije zavření. Bez vynulování zůstala v poli částka z minulé
  // rezervace a odešla s další — cizí akce dostala napevno cizí cenu.
  // Totéž při přepnutí typu, kde částka navíc mění význam (kalkulačka × pevná).
  it('částka se nuluje při otevření dialogu i při změně typu akce', () => {
    // Kotvíme na EFEKT a jeho deps, ne na jména refů `rezimMinule` /
    // `otevreniMinule`. Ty dnes chování nemění (jsou to pojistky proti budoucí
    // úpravě), takže kdo je odstraní a chování nechá správné, nemá dostat
    // červený test znějící jako regrese. Podstatné je, že se efekt pustí na
    // změnu režimu i otevření a že vynuluje obojí.
    const zac = zdroj.indexOf('const celkemVysledek');
    const konec = zdroj.indexOf('}, [rezimCeny, open]);');
    expect(konec, 'efekt, který nuluje částku, v dialogu chybí nebo má jiné deps').toBeGreaterThan(-1);
    const telo = zdroj.slice(zdroj.lastIndexOf('useEffect(', konec), konec);
    expect(telo, 'nevynuluje zadanou částku').toContain("setCelkem('')");
    expect(telo, 'nevynuluje příznak celkemTouched').toContain('setCelkemTouched(false)');
  });

  // U pevné ceny je `rate_per_hour` odvozený průměr `amount / hodiny`, tedy
  // 538,46 u 7 000 na 13 h. Pole Sazba se předvyplňuje z rezervace, takže
  // `parseSazba` na něm hlásil „v celých korunách, bez haléřů" a `validate()`
  // odmítl uložit i pouhou opravu překlepu v názvu — u akce, kterou databáze
  // schválně nechává upravitelnou. Validovat se smí jen sazba, na kterou admin
  // doopravdy sáhl.
  it('nedotčená odvozená sazba s haléři nebrání uložení', () => {
    expect(zdroj, 'původní sazba z databáze se nepamatuje, nejde poznat dotčení')
      .toContain('setPuvodniRate(rateZDb)');
    const validate = zdroj.slice(zdroj.indexOf('const validate ='), zdroj.indexOf('const pevnaCena'));
    expect(validate, 'validace sazby běží i na nedotčené pole — u paušálu zablokuje i opravu názvu')
      .toContain('sazba.chyba && rate !== puvodniRate');
  });

  // Pojistka patří DOVNITŘ dopočtu, ne na volající místo: jinak stačí přidat
  // třetí volání a díra se vrátí. Bez ní napsání sazby 900 v pevném režimu
  // nasypalo do pole 5 400 a odeslalo je jako PEVNOU částku.
  it('dopočet sazba ⇄ částka běží jen v režimu kalkulačky', () => {
    for (const fn of ['prepocitejCelkem', 'prepocitejSazbu']) {
      const zac = zdroj.indexOf(`const ${fn} = `);
      expect(zac, `funkce ${fn} zmizela`).toBeGreaterThan(-1);
      const telo = zdroj.slice(zac, zdroj.indexOf('};', zac));
      expect(telo, `${fn} nemá pojistku na režim — v pevném režimu rozbíjí zadanou částku`)
        .toContain("if (rezimCeny !== 'kalkulacka') return;");
    }
  });

  // `celkemTouched` je druhá pojistka vedle vynulování: co do pole nasypal
  // dopočet nebo zbytek z minula, není rozhodnutí admina.
  it('posílá se jen částka, kterou admin doopravdy napsal', () => {
    expect(zdroj).toMatch(/const pevnaCena = isAdmin && rezimCeny === 'pevna' && celkemTouched \? celkemNum : null/);
    // a obě větve se rozhodují podle TÉŽE hodnoty, ne každá podle své podmínky
    expect(zdroj).toContain('rate_per_hour: pevnaCena != null');
    expect(zdroj).toContain('celkova_cena: pevnaCena');
  });

  // `parseSazba` je parser HODINOVÉ sazby (celé koruny, strop 50 000 Kč/h).
  // Na cenu akce se nehodí a chyba se navíc ztrácela — 60 000 za víkendový
  // turnaj se tiše zahodilo a rezervace vznikla za ceník.
  it('částka se čte vlastním parserem a jeho chyba zastaví uložení', () => {
    expect(zdroj, 'pevná cena se pořád čte parserem hodinové sazby')
      .toContain('parseCelkovouCenu(celkem, jednotek)');
    const validate = zdroj.slice(zdroj.indexOf('const validate ='), zdroj.indexOf('const pevnaCena'));
    expect(validate, 'validate() chybu v celkové ceně ignoruje — částka se tiše zahodí')
      .toContain('celkemVysledek.chyba');
  });

  // `create_booking_series` parametr `p_celkem` nemá a PostgREST hledá funkci
  // podle jmen parametrů → klíč navíc znamená PGRST202 a série se nezaloží.
  it('p_celkem nejde do sdíleného rpcArgs, jen do create_booking', () => {
    const args = hook.slice(hook.indexOf('const rpcArgs'), hook.indexOf('const createBooking'));
    expect(args, 'p_celkem je ve sdíleném rpcArgs — série s pevnou cenou spadne na PGRST202')
      .not.toContain('p_celkem');
    // Kotvíme na KÓD, ne na výskyt slova: `p_celkem` je v tom řezu třikrát
    // v komentáři, takže `toContain('p_celkem')` zůstalo zelené i po smazání
    // samotného řádku. Test, který nezčervená po vypnutí opravy, nehlídá nic.
    const create = hook.slice(hook.indexOf('const createBooking'), hook.indexOf('const createSeries'));
    expect(create, 'create_booking pevnou cenu neposílá vůbec')
      .toContain('p_celkem: input.celkova_cena');
  });

  // Editace pevný paušál neumí — větev `isEdit` `celkova_cena` nikam neposílá.
  // Zapsatelné pole by tam znamenalo „Rezervace upravena" a nezměněnou cenu.
  it('v editaci je pevná cena zamčená, ne tiše zahozená', () => {
    expect(zdroj).toContain("const pevnaVEditaci = isEdit && rezimCeny === 'pevna'");
    expect(zdroj, 'pole s pevnou cenou jde v editaci přepsat, ale uložit ne')
      .toContain('readOnly={!isAdmin || pevnaVEditaci}');
    const validate = zdroj.slice(zdroj.indexOf('const validate ='), zdroj.indexOf('const pevnaCena'));
    expect(validate, 'validate() editaci pevné ceny propustí — částka se tiše zahodí')
      .toContain('pevnaVEditaci && celkemTouched && celkemNum != null');
  });

  // Náhled z ceníku a zadaná pevná cena jsou dvě různá čísla. Vedle sebe na
  // jedné obrazovce ve chvíli potvrzení je to past: uloží se to zadané.
  it('náhled ceny z ceníku se u zadané pevné ceny nezobrazuje', () => {
    expect(zdroj, 'pod formulářem svítí pásmová cena, i když je vyplněný paušál')
      .toContain("!(rezimCeny === 'pevna' && celkem.trim())");
  });

  it('kombinace opakování + pevná cena se v UI nenabízí', () => {
    const validate = zdroj.slice(zdroj.indexOf('const validate ='), zdroj.indexOf('const pevnaCena'));
    expect(validate, 'opakovaná akce s pevnou cenou projde až na nesrozumitelnou chybu ze serveru')
      .toContain("repeat && rezimCeny === 'pevna'");
  });
});
