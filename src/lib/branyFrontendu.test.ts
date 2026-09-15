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

/**
 * Zdroják bez komentářů.
 *
 * Brána nesmí měřit vlastní vysvětlivky. Přesně na tom spadla 14. 9. 2026
 * kontrola uvnitř migrace: `position()` našla zakázaný tvar v komentáři nad
 * správným kódem a prohlásila migraci za rozbitou. Tady je to ještě zrádnější —
 * komentář, který VYSVĚTLUJE, co se sem nesmí vrátit, obsahuje ten zakázaný
 * název, takže by dobře okomentovaná oprava shodila vlastní bránu.
 *
 * `//` se nebere, když mu předchází dvojtečka, ať to nesežere `https://`.
 */
const bezKomentaru = (zdroj: string) =>
  zdroj.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/[^\n]*/gm, '$1');

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

describe('ReservationDialog: změna firmy u komerční akce', () => {
  const zdroj = cti('src/components/reservations/ReservationDialog.tsx');

  // Odemčení výběru firmy při úpravě stojí a padá s `lzeZmenitFirmu`. Kdyby
  // někdo tu podmínku zjednodušil na `isAdmin`, nabídl by dialog změnu
  // odběratele i u klubového tréninku — a tam se odběratel měnit nesmí
  // (server to odmítne, ale uživatel by dostal chybu místo zamčeného pole).
  it('výběr firmy se odemyká jen adminovi u KOMERČNÍ akce s event_id', () => {
    const podminka = zdroj.match(/const lzeZmenitFirmu = Boolean\(([\s\S]{0,300}?)\);/);
    expect(podminka, 'podmínka lzeZmenitFirmu v dialogu zmizela').not.toBeNull();

    const telo = podminka![1];
    expect(telo, 'lzeZmenitFirmu nekontroluje admina').toContain('isAdmin');
    expect(telo, 'lzeZmenitFirmu nekontroluje, že jde o úpravu').toContain('isEdit');
    expect(telo, 'lzeZmenitFirmu nekontroluje event_id').toContain('event_id');
    expect(telo,
      'lzeZmenitFirmu nekontroluje, že akce je KOMERČNÍ — u klubového tréninku ' +
      'se odběratel měnit nesmí, klub by se odpojil od členství i ceníku.',
    ).toContain("kindOf(editing) === 'commercial'");
    expect(telo,
      'lzeZmenitFirmu nekontroluje AKTUÁLNÍ `kind`. Bez toho zůstane výběr firmy ' +
      'odemčený i po přepnutí typu na trénink: zmenTypAkce se uloží, zmenFirmuAkce ' +
      'pak spadne na „jen u komerční akce" — a úprava zůstane z půlky aplikovaná.',
    ).toContain("kind === 'commercial'");
  });

  // Nová dráha vzniká v `uprav_drahy_akce` s firmou, kterou má akce V TU CHVÍLI.
  // Kdyby se firma měnila dřív než dráhy, přibyla by dráha se starým
  // odběratelem a akce by skončila se dvěma firmami — přesně tím, čemu
  // `zmen_firmu_akce` brání.
  it('zmenFirmuAkce se volá AŽ ZA upravDrahyAkce', () => {
    const drahy = zdroj.indexOf('api.upravDrahyAkce(');
    const firma = zdroj.indexOf('api.zmenFirmuAkce(');

    expect(drahy, 'volání api.upravDrahyAkce v dialogu zmizelo').toBeGreaterThan(-1);
    expect(firma, 'volání api.zmenFirmuAkce v dialogu zmizelo').toBeGreaterThan(-1);
    expect(firma,
      'zmenFirmuAkce se volá PŘED upravDrahyAkce. Nově přidaná dráha by pak ' +
      'zůstala na staré firmě a akce by měla dva odběratele.',
    ).toBeGreaterThan(drahy);
  });

  // Změna firmy nesmí sahat na cenu. V dialogu to drží tím, že se posílá
  // jen `event_id` a `subject_id` — žádná sazba.
  it('volání posílá jen akci a firmu, nic o ceně', () => {
    const volani = zdroj.match(/api\.zmenFirmuAkce\(\{([\s\S]{0,200}?)\}\)/);
    expect(volani, 'volání api.zmenFirmuAkce v dialogu zmizelo').not.toBeNull();
    expect(volani![1]).toContain('event_id');
    expect(volani![1]).toContain('subject_id');
    expect(volani![1], 'do změny firmy se přimíchala cena — to je přecenění, ne oprava adresáta')
      .not.toMatch(/rate|sazba|celkem|amount/i);
  });
});

describe('Přejmenování série: dvě větve, které se musí lišit', () => {
  const zdroj = cti('src/components/reservations/ReservationDialog.tsx');

  // Kdyby se výchozí hodnota překlopila na 'serie', hromadná změna by se dala
  // udělat omylem — uživatel otevře termín, opraví překlep a přepíše jím celou
  // sérii, aniž by o to požádal.
  it('výchozí rozsah je „jen tato akce", ne celá série', () => {
    const stav = zdroj.match(/useState<'tato' \| 'serie'>\('(\w+)'\)/);
    expect(stav, 'stav rozsahNazvu v dialogu zmizel').not.toBeNull();
    expect(stav![1],
      'výchozí rozsah je „serie" — hromadné přejmenování se musí zvolit vědomě.',
    ).toBe('tato');
  });

  // Volba se smí nabídnout jen tam, kde ji server umí splnit.
  it('volba rozsahu se ukazuje jen u akce, která do série patří', () => {
    const podminka = zdroj.match(/const jeSerie = Boolean\(([\s\S]{0,160}?)\);/);
    expect(podminka, 'podmínka jeSerie v dialogu zmizela').not.toBeNull();
    expect(podminka![1], 'jeSerie nekontroluje, že jde o úpravu').toContain('isEdit');
    expect(podminka![1],
      'jeSerie nekontroluje series_id — volba by se nabídla i u akce bez série ' +
      'a server by ji odmítl hláškou „není součástí opakované série".',
    ).toContain('series_id');
  });

  // TOHLE JE TA BRÁNA, KVŮLI KTERÉ TENHLE BLOK EXISTUJE.
  //
  // `update_booking` sáhne na JEDNU akci. Kdyby se u rozsahu „celá série"
  // poslal název i tudy, zapsal by se nejdřív na ten jeden termín a hromadná
  // změna by ho pak přepsala — což dnes vyjde stejně, ale je to náhoda: stačí,
  // aby se pořadí volání obrátilo, a série skončí se dvěma názvy.
  it('u rozsahu „celá série" se název ani poznámka neposílají přes updateBooking', () => {
    const volani = zdroj.match(/api\.updateBooking\(\{([\s\S]{0,900}?)\}\)/);
    expect(volani, 'volání api.updateBooking v dialogu zmizelo').not.toBeNull();
    expect(volani![1], 'updateBooking posílá název bez ohledu na zvolený rozsah')
      .toMatch(/title:\s*rozsahSerie \?/);
    expect(volani![1], 'updateBooking posílá poznámku bez ohledu na zvolený rozsah')
      .toMatch(/note:\s*rozsahSerie \?/);
  });

  // Hromadná změna platí JEN na název a poznámku. Čas, dráhy, sazba ani
  // odběratel se hromadně měnit nemají a server to neumí — kdyby se sem
  // připletly, slibovalo by UI něco, co neproběhne.
  it('volání série posílá jen název a poznámku, nic o čase, drahách ani ceně', () => {
    const volani = zdroj.match(/api\.prejmenujSerii\(\{([\s\S]{0,240}?)\}\)/);
    expect(volani, 'volání api.prejmenujSerii v dialogu zmizelo').not.toBeNull();
    expect(volani![1]).toContain('title');
    expect(volani![1]).toContain('note');
    expect(volani![1],
      'do hromadného přejmenování se přimíchal čas, dráha nebo cena — ' +
      'hromadný přesun série se vědomě nestaví.',
    ).not.toMatch(/start|end|sheet|rate|sazba|amount|subject/i);
  });

  // `''` je na serveru „smaž poznámku". Kdyby se posílalo vždycky, stačilo by
  // otevřít termín s prázdnou poznámkou, opravit překlep v názvu a zvolit
  // „celá série" — a poznámky by zmizely všem ostatním budoucím termínům.
  it('nezměněná poznámka se u série NEPOSÍLÁ (jinak by ji smazala všem)', () => {
    const volani = zdroj.match(/api\.prejmenujSerii\(\{([\s\S]{0,240}?)\}\)/);
    expect(volani, 'volání api.prejmenujSerii v dialogu zmizelo').not.toBeNull();
    expect(volani![1],
      'poznámka se posílá bezpodmínečně — u termínu s prázdnou poznámkou by se ' +
      'poslalo „" a server by ji smazal celé sérii.',
    ).toMatch(/poznamkaZmenena \?/);
    expect(zdroj, 'chybí porovnání poznámky proti uloženému stavu')
      .toMatch(/poznamkaZmenena = [\s\S]{0,80}?editing\.note/);
  });

  // POČET V HLÁŠCE MUSÍ BÝT `akci`, NE `terminu`.
  //
  // `terminu` počítá REZERVACE (řádky na drahách), `akci` počítá AKCE — tedy
  // termíny tak, jak je uživatel vidí v kalendáři. U série o 27 termínech na
  // dvou drahách je to 54 proti 27. Dokud se do hlášky posílalo `terminu`,
  // tvrdila po přejmenování dvojnásobek toho, co je vidět (změřeno
  // v prohlížeči 11. 9. 2026 na sérii „MBL mix boomer liga").
  it('hláška o přejmenování série počítá akce, ne rezervace', () => {
    // Řez se ohraničuje AŽ PO kontrole obou kotev. `indexOf` vrací -1, takže
    // `slice(start, -1)` by po zmizení druhé kotvy mlčky vzal zbytek souboru
    // a brána by zůstala zelená z nepravého důvodu.
    const od = zdroj.indexOf("title: 'Série přejmenována'");
    const do_ = zdroj.indexOf("{ title: 'Rezervace upravena' }", od);
    expect(od, "větev s hláškou „Série přejmenována\" v dialogu zmizela").toBeGreaterThan(-1);
    expect(do_, 'konec větve s hláškou v dialogu zmizel — řez by vzal zbytek souboru')
      .toBeGreaterThan(od);
    const hlaska = zdroj.slice(od, do_);
    expect(hlaska,
      'hláška bere počet z `terminu`, což jsou rezervace — u termínu na dvou ' +
      'drahách ukáže dvojnásobek toho, co má uživatel v kalendáři.',
    ).not.toMatch(/zmenaSerie[?!]?\.terminu/);
    // Tvrdí se POZITIVNĚ to, co se opravdu vypisuje: samotné `zmenaSerie.akci`
    // kdekoli v řezu by uspokojila i podmínka ternárního výrazu, která by pak
    // vypsala `terminu`. Zároveň to fixuje skloňování přes `pocetTerminu`.
    expect(hlaska,
      'hláška nevypisuje `pocetTerminu(zmenaSerie.akci)` — buď nebere počet ' +
      'z akcí, nebo obchází české skloňování.',
    ).toMatch(/pocetTerminu\(\s*zmenaSerie\.akci\s*\)/);
  });

  // Hláška počítá hodnotu, kterou do dialogu posílá hook — ta se musí měřit
  // na obou koncích zvlášť. TypeScript hlídá jen konec v dialogu (anotace
  // `zmenaSerie` je odvozená z `ReservationApi`); kdyby `akci` zmizelo z hooku,
  // typecheck by mlčel (volitelná vlastnost, která chybí, je přiřaditelná) —
  // a uživatel by místo počtu termínů dostal `undefined`. Tohle je ten druhý
  // konec. (Změřeno mutací, brána code review 11. 9. 2026.)
  it('useReservations vrací z prejmenujSerii i počet akcí', () => {
    expect(cti('src/hooks/useReservations.ts'),
      'návratový typ prejmenujSerii nezná `akci` — hláška by neměla z čeho počítat termíny.',
    ).toMatch(/prejmenuj_serii[\s\S]{0,400}?akci\?: number/);
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
    const hook = bezKomentaru(cti('src/hooks/useReservations.ts'));
    expect(hook).toContain("supabase.rpc('trener_akce'");
    // Obsazenost štábu (`shiftFill`) ze `shifts` číst SMÍ — je vypnutá pro
    // kohokoli mimo admina a staff (`enabled`). Zakázaná je jen ta cesta,
    // která hledá TRENÉRA: ta se zástupci klubu tiše rozbije.
    //
    // DŘÍV TU STÁLO `.not.toContain("required_role")`. To bylo o jedno patro
    // hrubší, než je ta hrozba: od 15. 9. 2026 se `required_role` v tomhle
    // dotazu VYBÍRÁ (potřebuje ho sdílený výpočet obsazenosti na rozpad po
    // rolích), ale nikde se podle něj NEFILTRUJE. Nebezpečná je právě jen ta
    // druhá věc — hledání konkrétní role ve `shifts`. Hlídáme tedy ji.
    expect(hook,
      'hook zase hledá trenérskou směnu přímo v tabulce shifts — zástupci ' +
      'klubu se tím trenér stane neviditelným.',
    ).not.toMatch(/\.(eq|neq|in|filter|match)\(\s*['"`]?\{?\s*required_role/);
    expect(hook,
      'hook porovnává required_role s trainer — to je zase to hledání trenéra ' +
      've shifts, jen napsané jinak.',
    ).not.toMatch(/required_role[^\n]{0,40}trainer/);
    // A ta druhá půlka ochrany: dotaz na obsazenost musí zůstat vypnutý pro
    // kohokoli mimo admina a štáb. Bez toho by zástupci klubu vracel nula řádků
    // bez chyby a obsazenost by mu tiše lhala nulou.
    expect(hook).toMatch(/enabled:\s*!!user\s*&&\s*\(isAdmin \|\| isStaff\)/);
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

  it.each(FUNKCE)('%s si volajícího ověřuje samo', (jmeno) => {
    const zdroj = cti(`supabase/functions/${jmeno}/index.ts`);
    expect(zdroj, `${jmeno} nečte hlavičku Authorization`).toMatch(/headers\.get\(['"]Authorization['"]\)/);
  });

  // `send-emails` se od 12. 9. 2026 ptá na ROLI, ne na tvar klíče. Důvod:
  // produkce přešla na novou generaci klíčů (`sb_secret_…`) a porovnání
  // řetězce začalo odmítat legitimní volání serveru. Seznam přijímaných
  // tvarů klíče by tentýž problém jen odložil k další generaci nebo rotaci.
  it('send-emails ověřuje roli volajícího přes moje_role()', () => {
    const zdroj = cti('supabase/functions/send-emails/index.ts');
    expect(zdroj,
      'send-emails se neptá databáze na roli volajícího — pak závisí na tvaru ' +
      'klíče a rozbije se při rotaci nebo další generaci.',
    ).toMatch(/rpc\(['"]moje_role['"]\)/);
    expect(zdroj,
      'send-emails nepustí dál jen `service_role` — zkontroluj rozhodovací podmínku.',
    ).toMatch(/===\s*['"]service_role['"]/);
    // Ověření MUSÍ jet pod pověřením VOLAJÍCÍHO. Kdyby se zeptalo servisním
    // klíčem, vrátí `service_role` vždycky a brána propustí kohokoli — tichá,
    // plně zelená díra.
    expect(zdroj,
      'ověření role nejede s hlavičkou volajícího — pak by vrátilo service_role vždy.',
    ).toMatch(/Authorization:\s*`Bearer \$\{token\}`/);
  });

  // ⚠️ POZOR NA ZDÁNÍ, ŽE JE TAHLE BRÁNA UŽ ZBYTEČNÁ. Vznikla proto, že cron
  // token ležel v `net.http_request_queue` — tabulce bez RLS. Ta cesta padla:
  // `pg_net` se na produkci neinstaluje a plánovač běží zvenčí z Netlify,
  // takže `EMAIL_CRON_TOKEN` dnes na produkci NENÍ nastavený a je inertní.
  //
  // Brána tu přesto zůstává, a to schválně. Tvrzení „cron token umí jedinou
  // věc: vyprázdnit frontu" je pořád vypsané v komentářích i v migraci, takže
  // ho někdo dřív nebo později znovu použije. První, kdo tu proměnnou nastaví,
  // musí dostat token, který doopravdy umí jen odeslat — ne takový, kterým
  // jde poslat `{"dryRun":true}` a přečíst adresy a plná těla až 200 zpráv.
  // Přesně to bylo možné, než to 12. 9. 2026 změřila brána.
  it('cron token neumí číst frontu, jen ji odeslat', () => {
    const zdroj = cti('supabase/functions/send-emails/index.ts');
    expect(zdroj,
      'chybí rozlišení cron tokenu od servisního pověření (`jenOdeslat`) — ' +
      'pak token umí víc, než o něm tvrdí migrace i komentáře.',
    ).toMatch(/const jenOdeslat\s*=\s*jeCron\s*&&\s*!jeSluzba/);
    expect(zdroj,
      'náhled se cron tokenu neodmítá — s ním jde přečíst obsah fronty.',
    ).toMatch(/volba\.dryRun === true && jenOdeslat/);
    expect(zdroj,
      'obsah náhledu není podmíněný servisním pověřením — automatický náhled ' +
      'po výpadku RESEND_API_KEY by sypal adresy a těla do net._http_response.',
    ).toMatch(/const smiVidetObsah\s*=\s*volba\.dryRun === true && jeSluzba/);
  });

  // Vyprázdnit frontu je změna stavu. `GET` se na rozdíl od `POST` ocitá
  // v historii prohlížeče, v logu proxy a dá se vyvolat prostým odkazem.
  it('send-emails přijme jen POST', () => {
    const zdroj = cti('supabase/functions/send-emails/index.ts');
    expect(zdroj,
      'metoda se nekontroluje — GET se správným tokenem frontu odešle stejně jako POST.',
    ).toMatch(/req\.method !== "POST"/);
  });

  // `invoice-pdf` na produkci nasazená není a starý vzor v ní zůstává vědomě,
  // viz docs/ETAPA3-STAV.md. Až se bude nasazovat, musí projít touž opravou.
  it('invoice-pdf má zatím starý vzor (známý dluh)', () => {
    const zdroj = cti('supabase/functions/invoice-pdf/index.ts');
    expect(zdroj).toMatch(/auth\.includes\(/);
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

describe('Nastavení: jméno ledaře se opravdu ukládá', () => {
  // Uživatel si vybral, že jméno z hlášky „V okně 48 h … jen <jméno>" nesmí být
  // natvrdo v kódu — je to sloupec v databázi a pole v Nastavení. Pole, které se
  // vykreslí, ale hodnotu nikam nepošle, by vypadalo úplně stejně a admin by se
  // o tom dozvěděl až tím, že hláška pořád zní po starém.
  it('Settings.tsx posílá ledar_jmeno do updateSettings', () => {
    const zdroj = cti('src/pages/Settings.tsx');
    expect(zdroj,
      'v Nastavení se ukládá jméno ledaře voláním updateSettings({ ledar_jmeno: … }). ' +
      'Bez něj je pole jen ozdoba a hláška o okně 48 h se nezmění.',
    ).toContain('updateSettings({ ledar_jmeno: jmeno })');
  });

  it('useSettings ledar_jmeno v typu mutace připouští', () => {
    const zdroj = cti('src/hooks/useSettings.ts');
    expect(zdroj,
      'updateSettings musí `ledar_jmeno` přijímat, jinak ho TypeScript ze Settings.tsx nepustí.',
    ).toContain('ledar_jmeno?: string;');
  });
});

// BARVA REZERVACE SE POČÍTÁ NA JEDNOM MÍSTĚ.
//
// Týdenní mřížka a měsíční chipy si pravidlo dřív rozhodovaly každá sama
// a rozešly se (údržba měla v jednom pohledu oranžový okraj a ve druhém ne).
// Chování samo měří `barvaKlubu.test.ts` nad `vzhledRezervace`; tahle brána
// hlídá jen to, že se na ni oba pohledy opravdu ptají — jinak by se unit test
// tvářil zeleně nad funkcí, kterou UI přestalo volat.
describe('Barva v kalendáři: jedno pravidlo pro Týden i Měsíc', () => {
  const POHLEDY = [
    ['src/components/reservations/ReservationCalendar.tsx', 'Den/Týden'],
    ['src/pages/Calendar.tsx', 'Měsíc'],
  ] as const;

  for (const [soubor, popis] of POHLEDY) {
    it(`${popis} bere barvu z vzhledRezervace`, () => {
      expect(cti(soubor),
        `pohled ${popis} nevolá vzhledRezervace — pravidlo si počítá sám a může se rozejít`,
      ).toMatch(/vzhledRezervace\(/);
    });

    it(`${popis} si podklad nemíchá sám`, () => {
      // `podkladKlubu` je stavební kámen `vzhledRezervace`. Když se objeví
      // přímo v pohledu, znamená to, že si ten pohled staví vlastní větev
      // vedle společného pravidla — přesně ta cesta, kterou se to rozešlo.
      expect(cti(soubor),
        `pohled ${popis} volá podkladKlubu přímo; barva patří do vzhledRezervace`,
      ).not.toMatch(/podkladKlubu\(/);
    });
  }

  it('roztažený blok leží NAD podkladem další dráhy', () => {
    // Sloupce drah jsou sourozenci a druhý má `bg-muted/40`. Bez `z` na bloku
    // se ten průsvitný závoj kreslil PŘES jeho pravou polovinu: #c1121f pod ním
    // vyjde rgb(212 109 118) a bílý text spadne ze 6,2 : 1 na 3,4 : 1, tedy pod
    // WCAG AA. U bledě modrého klubu to nebylo vidět, u červené ano.
    const zdroj = cti('src/components/reservations/ReservationCalendar.tsx');
    // Vyžaduje se KLADNÉ `z`, ne jakékoli. `z-0` vypadá jako oprava, ale není:
    // sloupec dráhy je `position: relative` se `z-index: auto`, takže nevytváří
    // stacking context — blok s `z-0` spadne do téže vrstvy jako pozdější
    // sourozenec a pořadí v DOM rozhodne proti němu. Změřeno v prohlížeči na
    // repru té struktury: u `z-0` i bez `z` je v pravé polovině bloku nahoře
    // podklad dráhy, u `z-10` blok sám. (Nález brány bezpečnost, 11. 9. 2026.)
    const z = zdroj.match(/roztazeniDrah > 1 && 'z-(\d+)'/);
    expect(z, 'roztažený blok nemá z-index — podklad druhé dráhy mu zesvětlí pravou půlku')
      .not.toBeNull();
    expect(Number(z![1]),
      `roztažený blok má z-${z![1]}, což ho nad podklad druhé dráhy nezvedne`,
    ).toBeGreaterThan(0);
    // A zároveň nesmí přerůst tažený blok (`z-20`), jinak by se přetahovaná
    // rezervace schovala pod ten, přes který ji uživatel táhne.
    expect(Number(z![1]), 'roztažený blok přerostl tažený blok (z-20)').toBeLessThan(20);
  });

  // BÍLÝ TEXT NA ČERVENÉ NEHLÍDALO NIC.
  //
  // `barvaKlubu.test.ts` měří, že `vzhledRezervace` vrátí `bilyText: true` —
  // ale ne, jestli si toho někdo ve vykreslení všimne. Změřeno mutací (brána
  // code review, 11. 9. 2026): smazání jediného řádku `komercni && 'text-white'`
  // nechalo celou sadu 523/523 zelenou, přitom hlavní popisek na plné červené
  // spadne na tmavý foreground, tedy ~2,5 : 1 — hluboko pod WCAG AA.
  //
  // POZOR NA ROZSAH: tohle měří, že ta VAZBA je v kódu napsaná, ne že ji React
  // vykreslil. Render test by byl silnější, ale repo nemá jsdom ani
  // testing-library a kvůli jedné třídě se nová závislost netahá.
  it('blok v mřížce váže bílý text na komerční vzhled', () => {
    const zdroj = cti('src/components/reservations/ReservationCalendar.tsx');
    expect(zdroj,
      'blok nepřepíná text na bílý podle vzhledu — tmavý popisek na plné červené je pod AA',
    ).toMatch(/komercni && 'text-white'/);
    expect(zdroj, '`komercni` se přestalo brát z vzhledRezervace')
      .toMatch(/const komercni = vzhled\.bilyText/);
  });

  it('chip v Měsíci váže bílý text na komerční vzhled', () => {
    const zdroj = cti('src/pages/Calendar.tsx');
    expect(zdroj,
      'chip nepřepíná text na bílý podle `bilyText` — tmavý text na plné červené je pod AA',
    ).toMatch(/bilyText \? 'text-white'/);
  });

  // Potomci bloku mají VLASTNÍ `text-*` třídy, takže bílá na rodiči je nepřebije
  // a každý se musí přepnout zvlášť. Bez tohohle by stačilo zapomenout jeden
  // a zůstal by šedý čas nebo jantarové hodiny na sytě červené.
  it('potomci bloku se na červené přepínají taky', () => {
    const zdroj = cti('src/components/reservations/ReservationCalendar.tsx');
    for (const [co, vzor] of [
      ['čas a částka', /komercni \? 'text-white\/85'/],
      ['ikona spojených drah', /komercni \? 'text-white' : 'text-primary'/],
      ['hodiny „čeká na potvrzení"', /komercni \? 'text-amber-200'/],
      // `ring-primary/40` má na #c1121f kontrast 1,88 : 1 — u komerce přes dvě
      // dráhy, kde ten rám nese nejvíc informace, by nebyl vidět.
      ['rám u akce přes víc drah', /komercni \? 'ring-1 ring-inset ring-white\/70'/],
    ] as const) {
      expect(zdroj, `na červené se nepřepíná: ${co}`).toMatch(vzor);
    }
  });

  // PŘEHLED MUSÍ BARVIT KOMERCI STEJNĚ JAKO KALENDÁŘ.
  //
  // Do 11. 9. 2026 měl Dashboard vlastní mapu s `commercial: 'bg-green-500'`,
  // takže táž akce byla na Přehledu zelená a v kalendáři šedá. Tohle je třetí
  // plocha, která si barvu počítala sama — po Týdnu a Měsíci.
  it('Přehled bere barvu komerce z BARVA_KOMERCE, ne z vlastní třídy', () => {
    const zdroj = cti('src/pages/Dashboard.tsx');
    expect(zdroj, 'Přehled nebere barvu komerce ze sdílené konstanty')
      .toMatch(/backgroundColor:\s*BARVA_KOMERCE\.podklad/);
    expect(zdroj, 'Přehled se neptá `jeKomercni` — barví podle vlastního klíče v mapě')
      .toMatch(/jeKomercni\(event\.event_type\)/);
  });

  it('mapa barev na Přehledu už pro komerci vlastní hodnotu nemá', () => {
    // Kdyby v mapě zůstal klíč `commercial`, byla by vedle konstanty druhá
    // hodnota — a ta se rozejde, jakmile se změní jen jedna strana. Táž úvaha
    // jako u zrušeného pole `tecka`.
    const zdroj = cti('src/pages/Dashboard.tsx');
    const mapa = zdroj.slice(
      zdroj.indexOf('const eventTypeColors'),
      zdroj.indexOf('const eventTypeLabels'),
    );
    expect(mapa, 'mapa eventTypeColors na Přehledu zmizela').not.toBe('');
    expect(mapa, 'v mapě barev na Přehledu je zase klíč `commercial`')
      .not.toMatch(/^\s*commercial:/m);
  });

  it('legenda pojmenovává komerční akci a bere její barvu z konstanty', () => {
    const zdroj = cti('src/components/reservations/ReservationCalendar.tsx');
    expect(zdroj, 'v legendě chybí položka „Komerční akce"').toContain('Komerční akce');
    // Tečka musí brát TU SAMOU hodnotu jako podklad bloku, ne vlastní pole
    // se stejnou barvou — to se rozejde, jakmile se změní jen jedna strana.
    expect(zdroj,
      'tečka v legendě nebere barvu z BARVA_KOMERCE.podklad — rozejde se s bloky',
    ).toMatch(/backgroundColor:\s*BARVA_KOMERCE\.podklad/);
  });

  it('šedá položka legendy nevyjmenovává, co do ní spadá', () => {
    // Dokud byla komerce neutrální, stálo v legendě „Bez barvy klubu
    // (komerce, údržba)" — po zčervenání komerce by ta věta lhala. Náhrada
    // „(údržba, rezervace bez klubu)" lhala jinak: vydávala klub bez použitelné
    // barvy za rezervaci bez klubu. Do šedé spadají TŘI různé věci a žádný
    // výčet se sem zatím nevešel správně, tak se nevyjmenovává nic.
    const zdroj = cti('src/components/reservations/ReservationCalendar.tsx');
    // Kotví se na ŠEDOU TEČKU v JSX, ne na text popisku: tentýž text stojí
    // i v komentáři pár řádků výš a `indexOf` by našel jeho. (Na tomhle mi
    // tahle brána napoprvé spadla — což je lepší, než kdyby měřila komentář.)
    const tecka = zdroj.indexOf('rounded-full border bg-slate-300" />');
    expect(tecka, 'šedá položka legendy zmizela').toBeGreaterThan(-1);
    // Řez končí na konci toho textového uzlu, ne po pevném počtu znaků —
    // delší popisek by se jinak z měření vysunul.
    const od = tecka + 'rounded-full border bg-slate-300" />'.length;
    const popisek = zdroj.slice(od, zdroj.indexOf('<', od));
    expect(popisek.trim(),
      'šedá položka legendy zase něco vyjmenovává — každý dosavadní výčet ' +
      'jeden z těch tří případů vynechal nebo popsal špatně',
    ).toBe('Bez barvy klubu');
  });
});

describe('Subjekty: rozhodování o hláškách zůstává v čisté funkci', () => {
  // `src/lib/stavSubjektu.test.ts` hlídá, že se ty funkce rozhodují správně,
  // včetně pořadí větví. Co ale otestovat neumí, je jestli je komponenta vůbec
  // VOLÁ — kdyby si někdo ternární řetězec zkopíroval zpátky do JSX, čisté testy
  // by dál svítily zeleně nad kódem, který se nikde nepoužívá.
  //
  // Tohle je přesně ten případ, kdy textová brána dává smysl: měří se EXISTENCE
  // VOLÁNÍ, ne větev. Polaritu podmínek by ze zdrojáku číst nešlo, a taky se
  // o to nepokouší.
  it('Subjects.tsx volá stavSeznamuLidi i stavUlozeniUdaju', () => {
    const zdroj = cti('src/pages/Subjects.tsx');

    expect(zdroj,
      'stavSeznamuLidi se v Subjects.tsx nevolá — rozhodování se nejspíš vrátilo ' +
      'do JSX, kde ho testy z stavSubjektu.test.ts nehlídají',
    ).toContain('stavSeznamuLidi(');

    expect(zdroj,
      'stavUlozeniUdaju se v Subjects.tsx nevolá. Je to ta funkce, která brání ' +
      'hlášce „Uloženo" za krok, který neproběhl — tedy jádro původního hlášení.',
    ).toContain('stavUlozeniUdaju(');
  });
});

describe('Kontrolní součet: fakturoidí sloupce jsou vidět a křičí', () => {
  // Migrace 20260914210000 zviditelnila `fakturoid` a `fakturoid_rozdil`.
  // Do 14. 9. 2026 je `billing_reconcile` VRACELA, ale tabulka v Invoices.tsx
  // vykreslovala sedm sloupců a ani jeden z těch dvou mezi nimi nebyl — takže
  // se fakturoidí kontrolní součet počítal a nikdo ho neviděl.
  //
  // ŽÁNR A JEHO HRANICE — a proč je první verze téhle brány k ničemu.
  // Repo nemá jsdom, takže se tabulka nedá vykreslit a proklikat. První verze
  // těchhle testů se ptala jen na výskyt názvů (`toContain('fakturoid')`)
  // a code review bránu 14. 9. 2026 OBEŠLA na první pokus: stačilo zabalit obě
  // buňky do `{false && …}` a v `nesedi` přepsat `||` na `&&` — oprava mrtvá,
  // všechny tři testy zelené. Jedna aserce byla navíc TAUTOLOGIE:
  // `toContain('rozdil')` projde i bez `rozdil`, protože `'fakturoid_rozdil'`
  // ten podřetězec obsahuje.
  //
  // Proto se od té doby matchuje VŽDY CELÝ VÝRAZ VČETNĚ OPERÁTORŮ, ne názvy.
  // Textová brána nikdy nedokáže, že se něco vykreslilo; dokáže jen to, že
  // zdroják vypadá přesně takhle. To stačí, aby mutace musela být viditelná.
  const invoices = () => cti('src/pages/Invoices.tsx');

  it('obě buňky jsou v tabulce vykreslené bez podmínky', () => {
    const zdroj = invoices();

    // Celá buňka včetně tagů. `{false && …}` nebo jakýkoli jiný obal
    // tenhle řetězec rozbije, takže se mutace neschová.
    expect(zdroj,
      'buňka se sloupcem „Fakturoid" zmizela nebo se dostala pod podmínku — ' +
      'částka, kterou za subjekt drží fakturoidí doklady, by nebyla vidět',
    ).toContain('<TableCell className="text-right">{fmtKc(Number(r.fakturoid))}</TableCell>');

    expect(zdroj,
      'hodnota „Rozdíl dokladů" se přestala vykreslovat přímo z r.fakturoid_rozdil',
    ).toMatch(/<TableCell className=\{`text-right \$\{Number\(r\.fakturoid_rozdil\)[^}]*\}`\}>\s*\{fmtKc\(Number\(r\.fakturoid_rozdil\)\)\}/);

    // Hlavičky — bez nich by buňky visely pod cizím sloupcem.
    expect(zdroj, 'hlavička sloupce „Fakturoid" zmizela')
      .toContain('<TableHead className="text-right">Fakturoid</TableHead>');
    expect(zdroj, 'hlavička sloupce „Rozdíl dokladů" zmizela')
      .toContain('<TableHead className="text-right">Rozdíl dokladů</TableHead>');
  });

  it('nenulový fakturoid_rozdil se zvýrazňuje stejně jako rozdil', () => {
    const zdroj = invoices();

    // Celý ternár včetně podmínky a včetně toho, že destruktivní třída je
    // v PRAVDIVÉ větvi. Samotné `toContain('text-destructive')` by prošlo
    // i po obrácení podmínky.
    const zvyrazneni = (sloupec: string) =>
      new RegExp(
        `Number\\(r\\.${sloupec}\\) !== 0 \\? 'font-bold text-destructive' : ''`,
      );

    expect(zdroj,
      'zvýraznění nenulového „Rozdíl dokladů" zmizelo nebo se mu obrátila podmínka',
    ).toMatch(zvyrazneni('fakturoid_rozdil'));

    // Kontrolní vzorek: kdyby se tenhle rozbil, nezměnila se fakturoidí
    // oprava, ale celý způsob zvýrazňování — a regex výš měří něco jiného,
    // než si myslí.
    expect(zdroj,
      'zvýraznění nenulového „Rozdíl" zmizelo — vzor, podle kterého se řídí ' +
      'i fakturoidí sloupec, přestal platit',
    ).toMatch(zvyrazneni('rozdil'));
  });

  it('banner „Sedí to" reaguje na KTERÝKOLI z obou rozdílů', () => {
    const zdroj = invoices();

    // CELÝ výraz i s `||`. Kdyby se z něj stalo `&&`, banner by mlčel,
    // dokud se nerozejdou OBA rozdíly naráz — a právě tuhle mutaci
    // předchozí verze testu propustila.
    expect(zdroj,
      'filtr `nesedi` už není „rozdil NEBO fakturoid_rozdil". Při `&&` by nad ' +
      'červenou buňkou svítilo zelené „Sedí to."',
    ).toMatch(
      /\(r\) =>\s*Number\(r\.rozdil\) !== 0 \|\| Number\(r\.fakturoid_rozdil\) !== 0/,
    );

    // Samostatně a NE přes `toContain('rozdil')` — ten by prošel i bez
    // `rozdil`, protože `fakturoid_rozdil` ho obsahuje jako podřetězec.
    expect(zdroj, 'filtr `nesedi` přestal hlídat samotný rozdil')
      .toMatch(/Number\(r\.rozdil\) !== 0/);
  });

  it('nápověda i banner přiznávají DRUHOU příčinu nenulového rozdílu', () => {
    // Změřeno 14. 9. 2026 na replice: doklad, který kryje rezervace z 5. 9.
    // a z 1. 10., má v zářijové sestavě `fakturoid_rozdil` = 2000, přestože
    // je v pořádku — sečte se celý `nas_soucet`, ale jen zářijové rezervace.
    // Chová se tak i funkce PŘED migrací 20260914210000; ta to jen poprvé
    // ukáže na obrazovce. Dokud se porovnání neomezí na doklady, které se do
    // období vejdou celé (produktové rozhodnutí PM), musí to text říct —
    // jinak obrazovka tvrdí „doklad se rozešel s podkladem" o zdravém dokladu.
    const zdroj = invoices();

    expect(zdroj, 'nápověda u kontrolního součtu zamlčela příčinu „doklad přesahuje období"')
      .toMatch(/rezervace mimo zobrazený měsíc/);
    expect(zdroj, 'banner „Nesedí" zase tvrdí jen jednu příčinu ze dvou')
      .toMatch(/nebo sahá mimo zobrazený měsíc/);
  });
});

describe('Obsazenost akce: jeden výpočet, žádné druhé počítání', () => {
  // Ticket klienta 15. 9. 2026 (akce Hyundai 5. 12.): kalendář hlásil „0/3",
  // obrazovka směn „2/3". Čísla nebyla špatně — byly to dva různé výpočty,
  // každý v jiném souboru. Sjednotily se do `src/lib/obsazenostAkce.ts`.
  //
  // Chování toho výpočtu hlídá `obsazenostAkce.test.ts`. Tahle brána hlídá to
  // druhé: že si žádná obrazovka NEZALOŽÍ výpočet vlastní. To ze samotného
  // chování poznat nejde — nový `filter().length` v komponentě projde všemi
  // testy chování a rozpor se vrátí přesně tak, jak se objevil poprvé.

  it('kalendář nepočítá obsazenost sám, volá sdílený výpočet', () => {
    const hook = bezKomentaru(cti('src/hooks/useReservations.ts'));
    expect(hook).toContain('obsazenostPodleAkci(');
    // Vlastní klasifikace stavů směny v kalendáři = přesně ten rozchod zpátky.
    expect(hook,
      'useReservations si zase překládá stav směny na obsazenost sám — ' +
      'patří to do src/lib/obsazenostAkce.ts, ať se to nerozejde s nabídkou směn.',
    ).not.toMatch(/status === 'claimed'|status === 'completed'/);
    expect(hook).not.toContain('filled += 1');
  });

  it('obrazovka směn nepočítá obsazenost sama, volá sdílený výpočet', () => {
    const hook = bezKomentaru(cti('src/hooks/useShifts.ts'));
    expect(hook).toContain('spoctiObsazenost(');
    expect(hook).toContain('volnoProRoli(');
    // TOHLE BYLA TA CHYBA: čitatel profiltrovaný podle rolí proti jmenovateli
    // spočítanému bez filtru. Obě jména jsou pryč a zpátky se nesmí vrátit.
    expect(hook,
      'totalSlots je zpátky — to byl ten nefiltrovaný jmenovatel proti ' +
      'role-filtrovanému čitateli, kvůli kterému instruktor viděl 2/3.',
    ).not.toContain('totalSlots');
    expect(hook).not.toContain('openCount');
  });

  it('podmínku „smím tuhle roli vzít" má nabídka i čítač z jednoho místa', () => {
    const hook = bezKomentaru(cti('src/hooks/useShifts.ts'));
    expect(hook).toContain('smenaPatriRoli(');
    // Opsaná podmínka v hooku by se zase rozešla s tím, co počítá
    // „Volné pro tvoji roli".
    expect(hook,
      'filtr rolí je zase opsaný v useShifts — patří do obsazenostAkce.ts, ' +
      'protože týž predikát potřebuje i čítač volných míst.',
    ).not.toMatch(/roles\.includes\(requiredRole\)/);
  });

  it.each([
    ['src/pages/Calendar.tsx'],
    ['src/pages/Shifts.tsx'],
    ['src/components/reservations/ObsazeniDetail.tsx'],
  ])('%s bere text „Obsazeno X/Y" ze sdíleného popisku', (soubor) => {
    const zdroj = bezKomentaru(cti(soubor));
    expect(zdroj).toContain('popisObsazenosti(');
    // Natvrdo napsané znění je začátek rozcházení textů: jedna obrazovka se
    // přejmenuje, druhá ne, a uživatel zase srovnává dvě různé věty.
    expect(zdroj,
      `${soubor} si píše znění čítače natvrdo — má být z popisObsazenosti().`,
    ).not.toMatch(/['"`>]\s*Obsazeno \{/);
  });

  it('odznak v kalendáři bere i práh „hotovo" ze sdíleného výpočtu', () => {
    const zdroj = bezKomentaru(cti('src/components/reservations/ReservationCalendar.tsx'));
    expect(zdroj).toContain('jeObsazeno(');
    // `filled` byl starý tvar, který existoval jen v kalendáři.
    expect(zdroj).not.toContain('fill.filled');
    // Vlastní práh by se rozešel s tím, co za „obsazeno" považuje zbytek.
    expect(zdroj).not.toMatch(/fill\.obsazeno\s*>=/);
  });

  it('brigádník vidí navíc „Volné pro tvoji roli"', () => {
    const zdroj = bezKomentaru(cti('src/pages/Shifts.tsx'));
    expect(zdroj).toContain('popisVolnaProRoli(');
    expect(zdroj).toContain('volnoProMe');
    // Starý popisek sliboval „volná místa", a přitom jedno číslo míchalo
    // filtrované s nefiltrovaným.
    expect(zdroj).not.toContain('Volná místa celkem');
  });
});
