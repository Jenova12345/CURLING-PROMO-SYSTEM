# CLAUDE.md — Curling Ostrava systém

Kontext projektu pro Claude Code. Přečti si to na začátku každé session.

---

## ⛔ NEPODKROČITELNÁ PRAVIDLA — přečti dřív, než na cokoli sáhneš

Od 31. 8. 2026 zadává do systému data **klient, na ostré produkci**. Každé
z těchhle pravidel tu je proto, že jeho porušení už jednou něco stálo — ne
jako opatrnost do zásoby.

1. **Čerstvá záloha před KAŽDÝM `db push`.** Ne „před dnešní dávkou", ale před
   každým jednotlivým pushem. Používej na to **`scripts/safe-deploy.sh <popisek>`**
   — dump si sám ověří velikost i celistvost a při chybě migraci vůbec nespustí.
   Ruční `supabase db push` znamená, že jsi zálohu obešel.

2. **KROK 0 u každého úkolu: nejdřív zjisti, jak to je dnes.** Ne odhadem,
   dotazem do živého schématu. Půlka „chyb" v tomhle repu byla funkce, která
   už existovala, nebo naopak komentář slibující něco, co nikdy nevzniklo
   (`reservation_cancelled` byl vypsaný v komentáři u tabulky roky a nezakládalo
   ho nic). Když KROK 0 ukáže, že je to jinak, než zní zadání — napiš to
   a nestav to podruhé.

3. **Peníze a přístupy ověřuj reálným tokenem, ne jako `postgres`.**
   Testy práv patří pod `SET LOCAL ROLE authenticated`. Jako `postgres` projde
   všechno (obchází granty i RLS), takže test tvrdí, že jsou dveře zavřené,
   a nevidí otevřené okno vedle. Dvakrát to takhle propustilo blokér.

4. **Ke každé opravě mutační test.** Vypni tu opravu a přesvědč se, že test
   opravdu zčervená. Test, který projde i bez opravy, nehlídá nic — a už se to
   tady stalo pětkrát, včetně případu, kdy dedup notifikací umlčel obě brány,
   které měl test měřit.

5. **Secrets nikdy do chatu ani do gitu.** Heslo k produkční DB žije
   v `.env.local` (gitignorováno, bez prefixu `VITE_`). Do příkazové řádky
   nepatří (je vidět v `ps`), do commitu ani do zprávy pro uživatele taky ne.

6. **Migrace jsou dopředné, po jedné.** Žádné přepisování historie, žádný
   `db reset --linked`, žádné mazání natvrdo. Na ostré produkci by reset smazal
   klientova data — viz `docs/PRODUKCE-PRAVIDLA.md`.

   **Každou migraci piš idempotentně** (`IF NOT EXISTS`, `CREATE OR REPLACE`,
   `DROP … IF EXISTS` před `CREATE`). Ne proto, že by jeden soubor mohl zůstat
   rozpůlený — proti tomu obálka drží —, ale kvůli těmhle třem věcem. Změřeno
   14. 9. 2026 na odhozeném `postgres:17`, CLI 2.104.0, třemi pokusy:

   - **Jeden soubor migrace JE atomický.** CLI ho posílá jako jednu transakci.
     Test: soubor `CREATE TABLE pulka_pred; SELECT 1/0; CREATE TABLE pulka_po;`
     → po pádu neexistuje **ani** `pulka_pred`. Celý soubor se vrátil.
     (Dřívější znění tohohle zadání tvrdilo opak — neplatí to.)
   - **Dávka souborů atomická NENÍ.** To je ta skutečná díra. Push tří migrací,
     kde spadne druhá → první zůstala nasazená **a zapsaná** v
     `schema_migrations`, třetí se vůbec nespustila. Opravený push tedy dojede
     na databázi, kde část změn už je. Přesně to popisuje `docs/PRODUKCE-PRAVIDLA.md`
     (P2) jako důvod pro čerstvý dump před **každým** pushem.
   - **Explicitní `COMMIT;` nebo `BEGIN;` v těle migrace tu obálku rozbije** —
     a je to nejhorší z možných výsledků. Test: `CREATE TABLE pred_commitem;
     COMMIT; CREATE TABLE po_commitu; SELECT 1/0;` → `pred_commitem` **přežila**,
     ale do `schema_migrations` se nezapsalo **nic**. Migrace tedy visí jako
     nenasazená, a opakovaný push spadne na „už existuje". Bez idempotence
     z toho není cesta ven jinou než ruční. **Do migrací se `BEGIN`/`COMMIT`
     nepíše** — obálku dodá CLI.

   Vedlejší zjištění z téhož měření: `CREATE INDEX CONCURRENTLY` uvnitř migrace
   neprojde nikdy (`SQLSTATE 25001`, „cannot be executed within a pipeline“) —
   spadne ale čistě, takže škodu nenadělá. Index v migraci dělej normálně.

7. **Když se cokoli neověří čistě → zastav a napiš to.** Neřeš to sám, nehrň
   to dál. Rozdíl v kontrolním součtu, test, který projde i po mutaci, dump
   podezřelé velikosti — to všechno je důvod přestat, ne obejít.

---

## O co jde

Přebíráme existující webovou aplikaci pro **curlingovou halu v Ostravě** z nástroje
Lovable do normálního repozitáře, který spravujeme přes Claude Code. Nad stávající
funkcí (správa směn a brigádníků) budeme stavět velký nový modul: **rezervační systém ledu**.

## Rozdělení rolí

- **PM (Claude v Cowork appce):** drží plán a roadmapu, píše zadání (briefy), kontroluje
  výstupy, řeší produktová rozhodnutí se zákazníkem (Tomáš).
- **Claude Code (ty, v terminálu):** „ruce" projektu — klonuješ repo, píšeš kód, spouštíš,
  migruješ databázi, nasazuješ. Řídíš se briefy od PM a hlásíš zpět zjištění.
- **Tomáš:** majitel projektu, schvaluje rozhodnutí, předává přístupy.

Když narazíš na produktové rozhodnutí (co má systém dělat, jak se má chovat), **nevymýšlej
si** — sepiš otázku a nech ji Tomášovi / PM. U technických rozhodnutí (jak to udělat) jednej.

## Tech stack (stávající — zachováváme)

- **Frontend:** React + Vite + TypeScript (vygenerováno Lovable, Tailwind + shadcn-ui).
- **Backend + DB:** Supabase (Postgres, Auth, RLS). Napojeno přes Supabase MCP.
- **Hosting:** Netlify, nasazuje se automaticky z GitHubu.
- **Lovable: opouštíme.** Od teď se needituje v Lovable — jediný zdroj pravdy je tento repozitář.

## Zásady

1. **Jeden zdroj pravdy = repo.** Databázové schéma drž v migracích v repu
   (supabase/migrations), ne jen v cloudu. Konec rozjíždění frontendu a DB.
2. **Nic nemazat natvrdo.** Používej „soft delete" (sloupec deleted_at), ať se data nedají
   omylem ztratit.
3. **Auditovatelnost.** U záznamů drž created_by, created_at, updated_by, updated_at.
   U klíčových tabulek historii změn (audit log / triggery). Požadavek zákazníka: „musí být
   vidět, kdo co zadával."
4. **Zabezpečení přes RLS.** Přístup jen pro přihlášené (Supabase Auth), práva podle rolí.
5. **Malé, srozumitelné commity.** Piš čitelný kód, komentuj netriviální věci česky/anglicky.
6. **Než něco velkého předěláš, zeptej se PM.**

## Architektonické rozhodnutí: zachovat a čistit (varianta B)

**Rozhodnuto:** stávající databázi a reálná data **NEbudujeme znovu od nuly**.

- **Varianta A (zamítnuto):** postavit čistou DB na zelené louce a data přemigrovat.
- **Varianta B (zvoleno):** **zachováváme** produkční databázi i reálná data
  (brigádníci, směny, výplaty, chaty) a **čistíme je za pochodu** — nekonzistence
  řešíme postupně migracemi, ne velkým třeskem.

**Rezervační systém ledu se staví jako nový, čistý kód _nad_ stávajícím základem** —
nové tabulky/moduly navrhneme pořádně od začátku, ale napojíme je na existující
`profiles` / `user_roles` / brigádnický systém, který nepřepisujeme. Důvod: data jsou
živá a v provozu, přepis od nuly by znamenal riziko ztráty a zbytečný výpadek.

Praktický dopad: baseline migrace = skutečný (i „nehezký") stav produkce; opravy schématu
jdou jako další migrace nad baseline, ne přepisem historie.

## Kalibrace úsilí podle rizika

**Rozsah kontrol odpovídá RIZIKOVÉ PLOŠE změny, ne tématu.**

- **Změna s reálnou plochou** — migrace, RLS a oprávnění, ceny / fakturace /
  peníze, auth. **Beze změny proti tomu, co je níž: všechny brány GREEN,
  mutační testy, ověření na produkci.** Tady se nešetří.
- **Čistě kosmetická / frontend-only změna** bez DB, migrace, oprávnění
  a peněz (barvy, texty hlášek, popisky) → **lehká cesta:** `npm run typecheck`,
  build, **jedno** ověření (hash bundlu nebo proklik), commit, push.
  **Nespouštět vícekolové adversariální brány.**
- **Když si nejsi jistý kategorií, ber změnu jako rizikovou.**

Cíl: neutopit hodinu v branách nad jednořádkovou změnou barvy.

Proč to tu je: 11. 9. 2026 spolkla změna barvy komerčních akcí (CSS třída
a jeden hex) přes hodinu na třech kolech adversariálních bran, které si mezi
sebou navíc přepisovaly pracovní strom. Nálezy byly věcné a některé i cenné,
ale cena neodpovídala ploše — žádná migrace, žádná práva, žádné peníze. Brány
tu jsou proto, aby chytily drahé chyby, ne aby zdražily levné.

**Platí to i obráceně:** „je to jen jeden řádek" NENÍ důvod zkrátit kontroly
u migrace, RLS ani u fakturace. Viz kapitola o Etapě 2 níž — u peněz „malá
změna" neexistuje.

## Pracovní postup (povinný pro každou změnu)
1. Plánuj první. U každého netriviálního úkolu nejdřív připrav plán a nech si ho schválit, než začneš měnit kód nebo databázi.
2. Agenti jako kontrolní brány. Před dokončením každé změny ji nech zkontrolovat příslušnými specializovanými agenty. Povinné brány: (a) Bezpečnost/RLS u čehokoli kolem přístupů, auth, RLS a klíčů; (b) Databáze/migrace u každé migrace (bezpečná, vratná, bez ztráty dat); (c) Code review u implementace před commitem. **Kolik kol jich pustit, řídí kapitola „Kalibrace úsilí podle rizika" výš** — u čistě kosmetické frontendové změny se adversariální kola nespouštějí.
3. Záloha před zásahem do produkce. Nikdy neaplikuj změnu na produkční DB bez čerstvé
   zálohy a odsouhlasení PM. Na obojí je **`scripts/safe-deploy.sh <popisek>`** — udělá dump,
   ověří, že není useknutý, vypíše, na který projekt míří, a teprve pak pustí `db push`.
   Zálohu z něj nejde přeskočit; ruční `db push` znamená, že jsi ji obešel.
   - **Supabase CLI proti živé databázi = zakázáno bez výslovného souhlasu PM a čerstvé zálohy.** NIKDY nespouštěj `supabase db push` ani `supabase link` sám od sebe. Lokální vývoj (`supabase start`, `supabase db reset`) je bezpečný a míří jen na lokální Docker.
   - **Kam `db push` doopravdy míří:** na **nalinkovaný** projekt, ne na to, co je v `config.toml`. `project_id` v `supabase/config.toml` je jen lokální jméno Docker kontejnerů a cíl pushe neurčuje (dřívější znění téhle poznámky tvrdilo opak). Link žije v `supabase/.temp/`, což je v `.gitignore` — po čerstvém klonu tam nic není, takže **stav linku si vždycky ověř a nikdy ho nehádej**. Ověřuj **jen pro čtení**: `supabase projects list` (má sloupec `LINKED`) nebo `cat supabase/.temp/linked-project.json`. (Ověřeno 2. 9. 2026: soubor `project-ref` tenhle CLI **zakládá** — dřívější znění tvrdilo opak. Rozhodující je stejně `linked-project.json`: nese i jméno projektu, takže je z něj vidět, jestli míříš na produkci, nebo na demo.) **Nikdy ne `supabase db push --dry-run`** — je to zakázaný příkaz jeden flag od ostrého běhu, na ověřování se nehodí.
   - **TŘI projekty, ať se nepletou** (od 31. 8. 2026):
     - `fcwubbytqxubgptftnru` = **curling-promo-prod — OSTRÁ PRODUKCE.** Sem od
       31. 8. 2026 zadává data klient. Web: https://curling-ostrava-system.netlify.app
       **Platí pro ni `docs/PRODUKCE-PRAVIDLA.md` — přečti si je, než na ni sáhneš.**
       Nejdůležitější: **NIKDY `db reset --linked`**, jen dopředné migrace,
       a před **každým** `db push` čerstvý dump.
     - `ltrazktulfxvzlvkxdsb` = curling-demo, kde běžel vývoj Etapy 1 a části 2.
     - `fareavttiwkamrukpfqk` = stará Lovable DB „MladeKameny" (jen směny
       a brigádníci, **rezervační tabulky tam vůbec nejsou**). Má **reálné
       uživatelské účty, které chce klient zachovat — NEMIGROVAT, NERESETOVAT.**
       Dřívější znění tohohle odstavce ji uvádělo jako produkci; to už neplatí.
4. Nic nemazat natvrdo, vše auditovat.
5. Změna je hotová, teprve až projde svými bránami.
6. **Commit po každém PR, který prošel bránami.** Neschovávej odbraněnou práci
   v pracovním stromu „než bude celek hotový" — necommitnutá práce má stejnou
   expozici na pád session jako nezaverzovaný dokument. Jeden PR = jeden commit,
   hned jak projde. (Push a merge zůstávají na vyžádání, tohle je o commitu.)
7. **Dlouhé SQL funkce nikdy nepřepisuj ručně.** `CREATE OR REPLACE FUNCTION`
   vyžaduje celé tělo, takže je vygeneruj z `pg_get_functiondef` živého schématu
   a vlož do nich jen ten zásah, který děláš — pak ověř diffem, že nic nezmizelo.
   Přepis z paměti už jednou utnul půlku bezpečnostního guardu (commit `87b1f78`).
8. **Žádné RPC nesmí přijmout název GUC ani stavět SQL z uživatelského vstupu.**
   Bezpečnostní brány u směn se opírají o transakční markery (`app.uklid_trenera`
   v `prirad_trenera`/`odeber_trenera`, `app.preceneni` v `zmen_typ_akce`).
   `authenticated` **i `anon` mají EXECUTE na `pg_catalog.set_config`** a `app.*`
   je volný namespace — takže marker drží jedině tím, že se ke `set_config`
   z API nedá dostat. Dnes se nedá: v `public` není ani jedna funkce
   s dynamickým SQL grantovaná `authenticated` a jediný `set_config`
   s proměnným názvem (`notify_reservation_changed`) si klíč skládá jako
   `'app.zmena_' || <uuid bez pomlček>`, kam se cizí jméno nevejde.
   První RPC, které vezme jméno GUC parametrem nebo poskládá SQL z uživatelského
   vstupu, tuhle podmínku zruší a otevře obchvat brány N3 (zavření cizí obsazené
   směny). Ověřeno bezpečnostní bránou 4. 9. 2026.

9. **Testy práv piš pod `SET LOCAL ROLE authenticated`.** Jako `postgres` projde
   všechno (obchází granty i RLS), takže test tvrdí zavřeno o dveřích, vedle
   kterých je otevřené okno. Dvakrát to takhle propustilo blokér.

## Čemu v tomhle repu nevěřit

- **`npx tsc --noEmit` netypuje nic** — kořenový `tsconfig.json` má `"files": []`
  a jen reference na podprojekty. Používej **`npm run typecheck`** (`tsc -b`).
- **`npm run lint` je červený už na HEADu** (66 errors z Etapy 1), takže jako brána
  nefunguje — nový error od šumu nikdo nerozezná.
- Úplný seznam takových pastí je v `docs/ETAPA2-STAV.md`, kapitola 5.

## Pravidlo pro Etapu 2 (fakturace) — povinné

**Po každé smysluplné změně, PŘED commitem/mergem, pusť review agenty jako bránu:**
code review + bezpečnost/RLS + kontrola migrací. **Nic se nemerguje bez projití těchto
tří gatů.** Platí i pro drobné úpravy — u peněz není „malá změna".

**Navíc u fakturace vždy ověř kontrolní součet:**
> suma vystavených faktur za období **==** „Kdo kolik dluží" za totéž období

Když se součty rozejdou, změna neprochází — bez ohledu na to, jak dobře vypadá kód.

## DAŇOVÝ REŽIM HALY — OVĚŘENÝ FAKT, NEHÁDAT SE O NĚM ZNOVU

**Curling promo Ostrava s.r.o., IČO 29796717 = NEPLÁTCE DPH.**
Ověřeno 14. 9. 2026 ve čtyřech nezávislých registrech, všechny se shodly:

| zdroj | co vrátil |
|---|---|
| ARES, základní záznam | `"dic": null` |
| ARES, `seznamRegistraci` | `"stavZdrojeDph": "NEEXISTUJICI"` (přitom `stavZdrojeVr`/`Res` = `AKTIVNI`, takže subjekt zná) |
| ARES, endpoint DPH | `GET /ekonomicke-subjekty-dph/29796717` → **404 Not Found** |
| Registr plátců DPH (MFČR ADIS) | `statusCode="0" statusText="OK"`, `typSubjektu="NENALEZEN"` |
| VIES (EU) | `"isValid": false, "userError": "INVALID"` |

`typSubjektu` u MFČR je právě to pole, které by řeklo `PLATCE` nebo
`IDENTIFIKOVANA_OSOBA` — vrací `NENALEZEN`. Není to tedy ani identifikovaná
osoba. Firma vznikla **16. 7. 2026**, na povinnou registraci (obrat 2 mil. Kč
za 12 měsíců) nemohla mít čas a dobrovolně registrovaná podle registrů není.

**DIČ „CZ29796717" nikde neexistuje.** Tvarem se shoduje s IČO, jak to
u českých právnických osob bývá, ale to platí jen když registrace existuje.
Tady neexistuje — nepoužívat ho a neodvozovat z IČO.

**Účet ve Fakturoidu je nastavený SPRÁVNĚ** (`vat_mode: non_vat_payer`,
ověřeno čtením přes API 14. 9. 2026).

✅ **SROVNÁNO 15. 9. 2026 — systém je na neplátci.**
Migrace `20260915090000_danovy_rezim_neplatce.sql` přepnula
`billing_settings.vat_mode` na `neplatce`, secret `IS_VAT_PAYER` je `false`.
Brána `overDanovyRezim` tedy porovnává dva zdroje, které se shodují **a jsou
správně**. Dřív se shodovaly taky — jenže oba byly vedle, což je přesně ten
stav, kvůli kterému brána sama o sobě nestačí. **Třetí zdroj (účet u Fakturoidu,
`vat_mode: non_vat_payer`) nekontroluje v kódu pořád nikdo** — ověřuje se ručně
čtením přes API. Naposledy **15. 9. 2026**, a shodoval se: účet je
„Curling promo Ostrava s.r.o.", `vat_mode: non_vat_payer`. Postup je
v kapitole „KROK 5" níž.

⚠️ **Credentials Fakturoidu v lokálním `.env` NEJSOU produkční.** Ověřeno
15. 9. 2026 porovnáním digestů proti `supabase secrets list`:
`FAKTUROID_CLIENT_ID`, `CLIENT_SECRET`, `USER_AGENT`, `FAKTUROID_LIVE`
a `IS_VAT_PAYER` se liší (`SLUG`, `POVOLENY_UCET`, `MODE` sedí). Lokální pár
vrací z OAuth **401 `invalid_client`**, takže účet u Fakturoidu se z téhle
mašiny přečíst nedá — jde to jedině přes nasazenou Edge funkci, která běží
s produkčními secrets. Nepokládej lokální `.env` za obraz produkce.

Změřený dopad přepnutí na neplátce (14. 9. 2026, na produkci v transakci
s ROLLBACKem):
- **„Kdo kolik dluží" se NEHNE.** Všech 18 řádků `billing_reconcile` je
  před i po identických — funkce o DPH vůbec neví, `dluzi` je hodiny × sazba.
- **Mění se jen doklady za komerční akce.** 34 rezervací za 581 100 Kč je
  vedeno v cenách BEZ daně (`cena_bez_dph = true`); tam by Fakturoid jako
  plátci přidal 12 % navrch (`vat_price_mode: without_vat`), jako neplátci
  nepřidá nic. Rozdíl ≈ **69 732 Kč**, o které by zákazníci byli
  naúčtováni víc.
- **Klubové doklady se nemění.** 173 rezervací za 821 400 Kč má ceny
  VČETNĚ daně (`pricesIncludeVat: true`), takže částka k úhradě je stejná
  v obou režimech; liší se jen rozpis daně na dokladu.

### ⏳ ČEKAJÍCÍ ÚKOL: hala se stane plátcem DPH

**Ví se, že to přijde; neví se kdy.** Hala podle klienta během několika
měsíců plátcem DPH bude. Datum zatím nikdo nezná — závisí na rozhodnutí
finančního úřadu.

**Spouštěč:** až přijde **rozhodnutí FÚ** s přiděleným **DIČ** a **datem
účinnosti registrace**. Do té doby se NIC nepřepíná — dnešní stav
(neplátce) je ten správný a doložený čtyřmi registry.

**Co se pak musí udělat, a v tomhle pořadí:**

1. **Zapsat DIČ** do `billing_settings.supplier_dic` (dnes je prázdné,
   protože DIČ `CZ29796717` NEEXISTUJE — viz výš; po registraci bude mít
   skutečnou hodnotu z rozhodnutí, neodvozovat ji z IČO).
2. **Přepnout účet u Fakturoidu** na plátce (`vat_mode`) — ručně v jejich
   aplikaci, my do toho nepíšeme.
3. **Secret `IS_VAT_PAYER` na `true`** v Supabase (dělá Tomáš, secrets jsou
   write-only).
4. **Migrace `vat_mode = 'platce'`** — dopředná, idempotentní, jako každá jiná.
   POZOR: `vat_mode` se přepíná i z obrazovky Nastavení → Fakturace
   (`authenticated` má na ten sloupec UPDATE), takže se to dá udělat omylem
   jedním kliknutím. Migrace je proto jen polovina práce; druhá je ověřit
   reálným tokenem, že se všechna tři místa shodla.
5. **ROZHODNOUT O DATU ÚČINNOSTI.** Registrace platí od data v rozhodnutí,
   ne ode dne, kdy to někdo přepne. Doklady za období PŘED tím datem musí
   zůstat bez DPH. Dnešní `billing_settings.vat_mode` je JEDNA hodnota bez
   časové osy — neumí „do 30. 6. neplátce, od 1. 7. plátce". Než se přepne,
   je potřeba vědět, jestli v té době bude existovat nevyfakturované období
   před datem účinnosti; pokud ano, je to samostatný úkol (datum účinnosti
   do nastavení, nebo dofakturovat všechno staré ještě jako neplátce).

**Co se tím NEODEMKNE:** interní fakturační engine. Ten má od 15. 9. 2026
vlastní zámek (`billing_settings.interni_engine_povolen`, výchozí `false`),
nezávislý na daňovém režimu — viz migrace
`20260915100000_zamek_interniho_enginu.sql`. Ostré doklady vystavuje
Fakturoid a přepnutím na plátce se na tom nic nemění.

**Co bude dál chybět:** `vat_*` sloupce na `invoice_items` jsou pořád prázdné
místo (otázka Q7 na účetní). To je důvod, proč interní engine v režimu plátce
odmítá vystavit — ta zábrana zůstává a je správná.

**Nic se zatím nenaúčtovalo špatně.** K 14. 9. 2026 je v produkci
`invoices` = 0, `invoice_items` = 0, `fakturoid_invoices` = 0, žádná
rezervace nemá `invoice_id` ani `invoiced_at`. Interní engine navíc
v té době v režimu `platce` odmítal vystavit cokoli („Doklad umí zatím jen
režim neplátce DPH"), takže doklad s DPH jím vzniknout ani nemohl. **Od
15. 9. 2026 už engine nedrží zavřený daňový režim, ale vlastní zámek**
(`interni_engine_povolen = false`) — na režimu nezávislý, fail-closed. Jediný
historický záznam v auditu (1. 9. 2026) bylo testovací zabrání
`zavod2-…` bez `provider_invoice_id` i `cislo`, smazané po 27 sekundách.

---

## Kde právě jsme (aktualizováno 24. 8. 2026)

**Etapa 3 — napojení na Fakturoid (varianta S2).** Ostrý doklad vystavuje
Fakturoid, náš systém do něj posílá jen podklady. Interní fakturační engine se
na ostré doklady už nepoužívá a **od 15. 9. 2026 je zamčený**
(`billing_settings.interni_engine_povolen = false`, migrace
`20260915100000_zamek_interniho_enginu.sql`) — zavřených je všech pět funkcí,
které umí založit doklad, a z aplikace se to nedá zapnout. Úplné vyřazení
(smazání kódu a obrazovek) zůstává samostatný pozdější ticket.

> **Než začneš cokoli kolem fakturace, přečti `docs/ETAPA3-STAV.md`.**
> Pak `billing/README.md` (pravidla vrstvy). `docs/ETAPA2-STAV.md` níž popisuje
> interní engine, který Etapa 3 nahrazuje — je pořád platný jako popis toho,
> co v databázi je, ne jako popis toho, kam se jde.

### KROK 5 — tlačítko „Vystavit ve Fakturoidu" (15. 9. 2026, NASAZENO)

Vystavení dokladu je od téhle chvíle **v aplikaci**: Přehled fakturace →
„Vystavit ve Fakturoidu". Klub se fakturuje za měsíc, komerční odběratel po
akcích. Interní engine z téhle obrazovky zmizel úplně.

**Ostrý účet je ověřený, a to všemi třemi zdroji** (15. 9. 2026, jednorázovou
diagnostickou funkcí, která `GET /account.json` přečetla produkčními secrets
a hned se smazala):

| zdroj | hodnota |
|---|---|
| Fakturoid, `account.json` | **„Curling promo Ostrava s.r.o."**, `subdomain: curlingpromoostrava`, `vat_mode: non_vat_payer` |
| `FAKTUROID_SLUG` == `FAKTUROID_POVOLENY_UCET` | `curlingpromoostrava` |
| `billing_settings.vat_mode` / `IS_VAT_PAYER` | `neplatce` / `false` |

Tím padla poznámka z kapitoly o daňovém režimu, že třetí zdroj (účet
u Fakturoidu) nikdo nekontroluje — zkontrolovaný je. **V kódu ho pořád
nekontroluje nic**, ověřuje se ručně takhle.

`FAKTUROID_LIVE=true`, `FAKTUROID_MODE=koncept`. **První kliknutí vystaví ostrý
doklad v ostré číselné řadě** — Fakturoid stav „koncept" nezná, `koncept`
u nás znamená jen „neposlal se e-mail". Omyl se řeší stornem nebo dobropisem,
ne smazáním.

#### ⏳ TŘI ODLOŽENÉ TIKETY — vědomě neuděláno, ne přehlédnuto

**T1 — Měsíční invariant klubového dokladu drží JEN prohlížeč.**
Klíč idempotence je `klub-{subjectId}-{RRRRMM}` a měsíc se bere z `obdobiOd`.
Nikde se ale neověřuje, že `obdobiOd..obdobiDo` je celý kalendářní měsíc:
Edge funkce ta dvě data přebírá z těla požadavku bez kontroly, `mapujKlubMesicne`
z nich jen odvodí `RRRRMM` a na `fakturoid_invoices` je jen CHECK
`obdobi_do >= obdobi_od`. Jedinou zábranou je `disabled` na dvou tlačítkách
(`klubovaJde = view === 'month'` v `src/pages/Dues.tsx`).
**Důsledek:** kdo pošle týdenní období (devtools, budoucí cron, skript), vystaví
doklad na týden a spálí klíč na celý měsíc. Zbytek měsíce pak vrací
`existoval`/`preskoceno` a nevyfakturuje se jinak než dobropisem.
**Oprava patří na server**, ne do UI: buď do `mapujKlubMesicne`
(`billing/mapping.ts`) jako `BillingValidationError`, nebo jako CHECK
u `druh = 'club_monthly'`. Vyžaduje redeploy Edge funkce.

**T2 — Edge funkce balí hlášky databázových guardů do holého `Error`.**
`supabase/functions/fakturoid-invoice/index.ts` dělá u obou podkladových RPC
`throw new Error('fakturoid_podklady_…: ' + error.message)`. Holý `Error` není
`BillingError`, takže `kodChyby()` vrátí `'neznama'` a adminovi dojde pevná věta
„Doklad se nepodařilo vystavit. Detail je v provozním logu."
**Co se tím ztratí:** české hlášky psané pro člověka — guard A5 („nedorazili"),
`over_danovy_rezim_podkladu` („míchal by ceny s DPH a bez DPH"), „čeká na
schválení". Do logu Edge funkce se admin z aplikace nedostane, takže je to
slepá ulička. Starý kód je vypisoval schválně.
**Není to únik** (ven jde pevný text, což je správně), je to regrese
provozuschopnosti. Oprava: házet je jako `BillingValidationError` s vlastním
kódem a pro ten jeden kód pustit text ven — endpoint je admin-only a ty hlášky
sazbu nenesou. Vyžaduje redeploy Edge funkce.

**T3 — Stornovaný doklad zamkne rezervaci natrvalo, a nově ani není vidět.**
Vazby v `fakturoid_invoice_reservations` maže jedině `fakturoid_uvolni_zabrani`,
a ta odmítne doklad, který má `provider_invoice_id`. Rezervace na vystaveném
a pak stornovaném dokladu tedy zůstane zamčená napořád.
**Co se změnilo 15. 9. 2026:** po migraci `20260915110000` taková rezervace
zmizí i z náhledu „nevyfakturované akce", kde byla dosud aspoň vidět (byť
zavádějícím způsobem — server ji stejně odmítal). Chování to nezavádí, jen
schovává.
**Backstop zůstává** `billing_reconcile` (sloupce `fakturoid`,
`fakturoid_rozdil`), takže systémově neviditelné to není. Cesta ven dnes
neexistuje jinak než servisním zásahem do databáze.

---

## Kde jsme byli (Etapa 2, aktualizováno 13. 8. 2026)

**Etapa 2 — fakturační modul.** Fáze A je hotová (A1–A5), z fáze B je hotové
B1+B2 (základ dokladu) a B5+B6 (RPC „faktura na klik" a **kontrolní součet**),
plus strop sazby (drift 8g) a E1-lite (stránka Faktury). Zbývá QR a serverové PDF.

> **Než začneš cokoli dělat, přečti `docs/ETAPA2-STAV.md`.**
> Je to předávací dokument: co je hotové s commit hashi, co se dělá dál a v jakém
> pořadí, jaká rozhodnutí PM platí, stav dema a seznam věcí, které se v téhle
> codebase tváří jinak, než jsou.
>
> Pak `docs/etapa2-fakturace-plan.md` (rozhodnutí R1–R11, otázky Q1–Q7)
> a `docs/etapa2-fakturace-spec.md` (zadání od klienta).

Aktuální cíl: **ruční „faktura na klik"** — jedna svislá funkční věc na demo,
v režimu neplátce DPH. Bez automatiky, dobropisů a evidence plateb.

## Roadmapa (fáze)

- **Fáze 0 — Převzetí kódu:** ✅ hotovo.
- **Fáze 1 — Zmapování:** ✅ hotovo (schéma v migracích, drift v `docs/SCHEMA_DRIFT.md`).
- **Fáze 2 — Návrh rezervace ledu:** ✅ hotovo.
- **Fáze 3 — Implementace rezervace ledu:** ✅ hotovo (Etapa 1).
- **Fáze 4 — Testy, zálohy, nasazení:** průběžně.
- **Etapa 2 — fakturace:** ⏳ probíhá, viz `docs/ETAPA2-STAV.md`.

## Požadavky na rezervační systém (od zákazníka)

- Přístup jen pro lidi s heslem (role: admin / brigádník / člen / …).
- Musí být vidět, kdo co zadával (audit).
- Záloha a garance, že se data nesmažou.
- Načítání IČO a údajů z adresy → ARES (oficiální registr, REST API zdarma).
- Tvorba faktur podle rezervovaných hodin (zvažuje se napojení na Fakturoid / iDoklad).
- Brigádníci už v systému nějak jsou — napojit, nepřepisovat.
- Systém = jeden „portál", odkaz na něj vede z nového webu, starého webu i odjinud.

## Rozhodnuto (feedback klienta, 31. 7. 2026 — detaily v docs/E2-ZMENY.md)

- **Název systému: Curling Promo Ostrava** (dřív „Mladé kameny"). Logo zatím placeholder.
- **Terminologie: „dráha"**, ne „plátno" (Dráha 1 / Dráha 2).
- **Struktura ledu:** 2 dráhy, rezervace po **celých hodinách**, otevírací doba **7:00–22:00**
  (nastavitelná adminem po dnech).
- **Typy akcí:** trénink / turnaj / komerční akce / údržba ledu; každá má název.
  Priorita při kolizi: údržba > komerční > turnaj > trénink; přebít smí jen admin a jen vědomě.
- **Kdo co smí:** hobby hráč (jen kouká) → člen klubu (rezervuje, edituje svoje) →
  zástupce klubu (celý klub, potvrzuje rezervace členů, může jich být víc) → admin.
- **Cena:** obsazenost i název klubu/akce vidí všichni přihlášení, **částku jen admin a autor**.
- **Ceník:** sazby podle typu akce vyplňuje admin v Nastavení (migrace je nechává prázdné).

## Otevřené otázky (řeší PM se zákazníkem)

- Fakturace: vlastní generování vs Fakturoid/iDoklad?
- E-maily k notifikacím: který poskytovatel (Resend / SMTP) a z jaké domény?
  (v aplikaci notifikace fungují a **e-mailová fronta je ZAPNUTÁ** —
  `settings.email_notifications_enabled = true`, ověřeno na produkci 14. 9. 2026.
  Dřívější znění tvrdilo, že je vypnutá; neplatí to. Řádky se tedy do
  `email_outbox` opravdu zakládají a čekají na odesílatele.)
- Platby: jen faktura, nebo i online platby/zálohy?
- Finální logo a barevnost.
