# Etapa 3 — nové požadavky ze schůzky s klientem

**Zapsáno:** 25. 8. 2026 · **Stav:** ⏸ jen zápis a rozbor, **nic se neimplementuje**

> **Čeká se na kompletní přepis schůzky.** Tenhle dokument je zápis toho, co
> zaznělo v shrnutí, plus rozbor dopadu na existující kód. Otázky níž nejsou
> řečnické — bez odpovědí se to nemá začínat stavět, protože požadavek B sahá
> na invariant, kterým je celá fakturace držená pohromadě.
>
> Stav kódu, na který se to nabaluje, je v `docs/ETAPA3-STAV.md`.

---

## Provizorní odpovědi PM na blokující otázky

**Zapsáno 25. 8. 2026. ⚠️ PROVIZORNÍ — k finálnímu potvrzení po přepisu schůzky.**
Dokud to nebude potvrzené, neslouží to jako podklad k implementaci, jen jako směr.

| # | Otázka | Odpověď PM |
|---|---|---|
| 1 | Extra položky v „Kdo dluží" | **Vyjmout.** Rovnice zůstává **jen za led**. Extra položky se evidují zvlášť — na faktuře i v evidenci — a kontrolní součet porovnává **jen led-řádky**. |
| 2 | Je „potvrzeno" stav akce, nebo rezervace? | **Stav AKCE.** Nový životní cyklus `events`. |
| 3 | Hned, nebo večerní dávka? | **Hned při potvrzení, synchronně.** Pro komerční cestu **odpadá pg_cron**. Měsíční klubový souhrn zůstává na plánované dávce. |
| 4 | Zahrnuje C vyřazení interního enginu? | **Ano, jeden ticket** — včetně přesměrování `billing_reconcile` na `fakturoid_invoices`. |
| **5** | Jak se drží součty, když je na dokladu led i extra? | **Dvě čísla zvlášť.** `nas_soucet_led` (== „Kdo dluží") a `nas_soucet_total` = led + extra (== `provider_total`). Kontrola proti provideru jede na **total**, rovnice „Kdo dluží" jen na **led**. |
| **6** | Co když je při potvrzení Fakturoid nedostupný? | **Potvrzení a vystavení se ODDĚLÍ.** Akce se potvrdí **vždy** a směny/výplaty projdou i bez Fakturoidu. Vystavení je **retryovatelný pokus**. |

*(5 a 6 doplněny 25. 8. 2026 — vyplynuly z rozboru odpovědí 1 a 3 a PM je potvrdil
jako rozhodnutí, ne jako otevřené otázky.)*

### Rozhodnutí 5 — dvě čísla, ne jedno

Dnes drží evidence jediné `fakturoid_invoices.nas_soucet` a `zkontrolujSoucet`
ho porovnává proti `provider_total`. S extra položkami by to přestalo sedět
**a to tiše**: `provider_total` od Fakturoidu bude `led + extra`, kdežto rovnice
z CLAUDE.md má být jen za led, takže by rozdíl vypadal jako zaokrouhlení nebo
jako chyba mapování.

Proto se drží obě čísla:

| sloupec | co obsahuje | s čím se porovnává |
|---|---|---|
| `nas_soucet_led` | jen řádky odvozené z rezervací | **„Kdo kolik dluží"** (rovnice z CLAUDE.md) |
| `nas_soucet_total` | led + extra položky | **`provider_total`** od Fakturoidu |

Dopady, které z toho plynou:

- `fakturoid_invoices.nas_soucet` se **rozpadne na dva sloupce** (migrace).
- **`fakturoid_radku_sedi` se PŘEPÍŠE, ne zruší.** Dnes zní
  `CHECK (radku = cardinality(rezervace))`; nově musí počítat **jen led-řádky**.
  Extra položky do něj nevstupují, takže je evidence musí umět rozlišit.
- `zkontrolujSoucet` v `billing/pipeline.ts` porovnává **total**, ne led.
- Rovnice „suma faktur == Kdo dluží" se počítá **z led-sloupce**.

### Rozhodnutí 6 — potvrzení akce nesmí viset na cizí službě

Potvrzení je podle požadavku A společný spouštěč pro fakturaci **i pro směny**.
Kdyby bylo vystavení synchronní a nedělitelné, znamenal by výpadek Fakturoidu,
že brigádníci nedostanou proplacené směny. **Provoz haly nesmí viset na
dostupnosti cizí služby.**

Proto dva oddělené kroky:

1. **Akce se potvrdí vždy** — zapíše se stav, odemknou se směny a výplaty.
   Tenhle krok je čistě náš a nesmí selhat kvůli síti.
2. **Vystavení dokladu je pokus**, který smí selhat a jde zopakovat.

Pipeline je na to připravená: po selhaném pokusu se claim uvolní a příští běh
doklad buď najde (zámek 2), nebo vystaví. **Chybí ale cesta, jak ten příští běh
spustit** — dnes žádná není. Patří k tomu tedy:

- tlačítko „zkusit znovu" u potvrzené akce bez dokladu, **nebo** fronta
  (analogie `pdf_fronta` z Etapy 2, která tenhle vzor už v repu má),
- a **viditelný stav** „potvrzeno, ale nevyfakturováno", ať se na to nezapomene.

Tohle je součást rozhodnutí 3 (synchronní vystavení), ne samostatný úkol —
synchronní vystavení bez cesty pro opakování by znamenalo, že jeden výpadek sítě
nechá akci trvale nevyfakturovanou.

---

## Přehled

| | Požadavek | Jádro věci |
|---|---|---|
| **A** | Potvrzení komerční akce po skončení | Nový stav akce, který spouští fakturaci **i** směny |
| **B** | Volitelné položky navíc (salonek, občerstvení) | Doklad přestává být odvozený **jen** z rezervací |
| **C** | Sekce Faktury = proklik do Fakturoidu | Dokončení přechodu na S2 v UI |

**A a B jsou jedna obrazovka** (potvrzovací dialog s volitelnými položkami).
**B je architektonicky nejdražší** — rozbíjí databázový CHECK i kontrolní součet.
**C je nejlevnější, ale odkrývá otázku, co s interním enginem.**

---

## Požadavek A — Potvrzení komerční akce (post-event)

### Co zaznělo

- Jakub každou komerční akci po skončení **potvrdí** („proběhla takto").
- Potvrzení je **společný spouštěč pro dvě věci**:
  1. odeslání podkladů do Fakturoidu (ten večer → faktura → odejde firmě),
  2. směny brigádníků (payroll).
- Teprve po potvrzení se ten večer pustí podklady do Fakturoidu.

### Dopad na stávající kód

**`events` NEMÁ žádný stav.** Ověřeno proti schématu — sloupce jsou
`title, description, event_type, start_time, end_time, required_staff,
created_by, role_reqs` a nic víc. Akce dnes nemá životní cyklus; existuje, nebo
neexistuje. Požadavek A ten cyklus zavádí a je to **nová migrace** (např.
`events.potvrzeno_at`, `potvrzeno_by`, případně `potvrzeni_poznamka`).

**„Potvrzeno" NENÍ dnešní „Schválit".** Tohle je nejdůležitější zjištění rozboru
a je snadné to splést:

| | dnešní `approve_reservation` | nové „potvrzeno" |
|---|---|---|
| kdy | **před** akcí | **po** akci |
| co říká | „rezervace je platná, počítá se" | „akce proběhla takhle" |
| kdo smí | admin **nebo zástupce klubu** | podle zadání Jakub → admin |
| na čem visí | `reservations.approved_at` | na **akci**, ne na rezervaci |
| co odemyká | vstup do fakturačních podkladů (`invoice_only_approved`) | vlastní vystavení + směny |

Jsou to **dvě brány za sebou**, ne jedna přejmenovaná. `approve_reservation`
navíc potvrzuje celou skupinu rezervací jedné akce najednou (viz jeho tělo), což
je logika, kterou nové potvrzení může použít jako vzor.

**Vazba na `corrected_hours` / `corrected_amount`.** Potvrzení je *přirozený*
okamžik pro korekci — „klub zůstal o půl hodiny dýl". Dnes se korekce zadává
zvlášť na rezervaci, má **tvrdý strop 24 h** a povinný `correction_reason`
(rozhodnutí PM). Nabízí se korekci přesunout do potvrzovacího dialogu; obojí
zůstává, jen se to zadává na jednom místě.

**Vazba na směny.** `shifts.event_id` je NOT NULL, takže směny na akci visí už
teď. Dnes je uzavírá admin **po jedné** (`status='completed'`, `hours_worked`,
`completed_at` — `useShifts.ts`), je i hromadná varianta, ale pořád po směnách.
Potvrzení akce by se stalo tím spouštěčem — a tady je potřeba rozhodnout, jestli
směny **dokončí**, nebo jen **odemkne / vyzve k dokončení**.

**Časování „ten večer".** „Po potvrzení se **ten večer** pustí podklady" má dvě
možná čtení a jsou to dva různé návrhy:
- *hned při potvrzení* — jednoduché, žádný plánovač, ale „ten večer" pak závisí
  na tom, kdy Jakub klikne;
- *dávka večer* — potřebuje pg_cron a frontu, zato je to jedno místo, kde se dá
  den zkontrolovat před odesláním.

### Otevřené otázky — A

1. **Je „potvrzeno" stav akce, nebo stav rezervací?** ✅ **PM (provizorně): stav
   AKCE** — nový životní cyklus `events`. Fakturuje se pořád z rezervací, ale
   brána je na akci.
2. **Co s akcí, která se nepotvrdí?** Zůstane nevyfakturovaná navždy? Připomínka?
   Má se po N dnech potvrdit sama?
3. **Jde potvrzení vzít zpět?** Když ano, co s už vystavenou fakturou — dobropis?
   (Ve Fakturoidu doklad **nejde smazat**, jen dobropisovat.)
4. **Potvrzení směn a fakturace: opravdu jeden klik?** Nebo jeden dialog se dvěma
   sekcemi, kde jde každou odbavit zvlášť? Co když se ledová plocha odbaví
   správně, ale u směn si Jakub není jistý hodinami?
5. **Zadávají se v potvrzení korekce hodin?** (Doporučuji ano — je to jediný
   okamžik, kdy člověk ví, jak to doopravdy proběhlo.)
6. **Hned, nebo večerní dávka?** ✅ **PM (provizorně): hned při potvrzení,
   synchronně.** Pro komerční cestu odpadá pg_cron; měsíční klubový souhrn
   zůstává na plánované dávce. Potvrzení a vystavení jsou přitom **oddělené
   kroky** — viz rozhodnutí 6. Součástí je i cesta pro opakování.
7. **Kdo smí potvrdit?** Jen admin, nebo i provozní/manažer?
8. **Platí to i pro turnaje a tréninky?** Zadání mluví o komerčních akcích;
   klubové rezervace se fakturují měsíčně a potvrzení nemají.

---

## Požadavek B — Volitelné položky navíc při potvrzení

### Co zaznělo

- Při potvrzování dialog: „Přidat do faktury i pronájem salonku a občerstvení?"
- ANO → Jakub vybere položky a **zadá ceny** → přidají se do **téže** faktury
  vedle pronájmu ledu.
- Když firma chce doklady odděleně → druhou fakturu si Jakub udělá **ručně přímo
  ve Fakturoidu**, mimo systém.

### Dopad na stávající kód

Tenhle požadavek je architektonicky nejdražší, protože mění premisu, na které
fakturační vrstva stojí: **doklad dnes není nic než obraz rezervací.**

**1. Rozbije databázový CHECK.** V migraci `20260824120000_fakturoid_vazba.sql`:

```sql
CONSTRAINT fakturoid_radku_sedi CHECK (radku = cardinality(rezervace))
```

Doklad se třemi řádky ledu a jedním řádkem občerstvení má `radku = 4`, ale
`cardinality(rezervace) = 3` → **claim spadne**. Navíc je to `check_violation`,
který blok `EXCEPTION WHEN unique_violation` v `fakturoid_zkus_zabrat`
**nezachytí**, takže to nespadne hezky. Code review tenhle scénář předpověděla
ještě než požadavek vznikl.

Constraint tam je schválně — dokumentuje invariant, který dnes platí. Teď platit
přestane a musí se **vědomě uvolnit**, ne obejít.

**2. Rozbije kontrolní součet — a to je ta vážnější půlka.** CLAUDE.md má u
fakturace povinnou rovnici:

> suma vystavených faktur za období **==** „Kdo kolik dluží" za totéž období

„Kdo kolik dluží" počítá z rezervací. Ad-hoc řádky žádnou rezervaci nemají,
takže se strany rozejdou přesně o částku občerstvení. Interní engine s tím
částečně počítá — `billing_health` má počítadlo `radky_bez_rezervace` — ale pro
fakturoidí cestu je potřeba **rozhodnout, co je vlastně správně**: buď se extra
položky z rovnice vyjmou, nebo se „Kdo dluží" naučí je zahrnout.

**3. `InvoiceLine` je naopak připravený.** Kontrakt (`billing/types.ts`) má
`name / quantity / unitName / unitPrice` a nic o rezervacích neví. Přidat řádek
je z pohledu providera triviální — problém je *evidence a rovnice*, ne odeslání.

**4. `mapujKomercniAkci` bere řádky 1:1 z rezervací** a `sourceReservationIds`
odvozuje z týchž dat. Potřebuje druhý vstup (`extraRadky`), a musí zůstat
zřejmé, které řádky mají rezervaci a které ne.

**5. Kde se ty položky a ceny berou?** Zadání říká „zadá jejich ceny", tedy ručně
při každém potvrzení. Stojí za zvážení číselník v Nastavení (jako ceník ledu) —
ruční zadávání ceny u každé akce je zdroj překlepů a nejde z něj dělat statistika.

**6. Mina do budoucna: DPH.** Pronájem ledu a občerstvení mají v plátcovském
režimu **různé sazby**. Dnes je hala neplátce, takže to nebolí, ale až přejde na
plátce, tohle je přesně to místo, kde se to zlomí. Souvisí s otevřenou otázkou Q7
z Etapy 2 (agregace DPH), která pořád čeká na účetní klienta.

### Otevřené otázky — B

1. **Číselník, nebo volný text?** Pevný seznam („salonek", „občerstvení",
   „zapůjčení výstroje") s výchozí cenou, nebo pokaždé ručně?
2. **Vstupuje množství?** Občerstvení pro 12 lidí × cena, nebo jedna paušální částka?
3. **Jak se extra položky chovají v „Kdo kolik dluží"?** ✅ **PM (provizorně):
   vyjmout — rovnice zůstává jen za led.** Evidence drží dvě čísla
   (`nas_soucet_led` a `nas_soucet_total`), viz rozhodnutí 5.
4. **Můžou se přidat i ke klubové měsíční faktuře**, nebo jen ke komerční akci?
5. **Jde je po vystavení opravit?** Doklad ve Fakturoidu je po vystavení hotový —
   oprava = dobropis.
6. **Chce klient tyhle položky vidět v přehledech a statistikách**, nebo jen na
   dokladu? (Rozhoduje o tom, jestli se ukládají strukturovaně, nebo jen odešlou.)

---

## Požadavek C — Sekce Faktury = proklik do Fakturoidu

### Co zaznělo

- Sekce „Faktury" má vést rovnou na přihlášení/přehled ve Fakturoidu.
- Zvážit, jestli vlastní sekci Faktury vůbec mít, když je vše ve Fakturoidu (S2).
- Dnešní obrazovka míří na opuštěný interní engine — sjednotit.

### Dopad na stávající kód

**Dnešní `/invoices` není odkaz, je to plnohodnotná aplikace.** `src/pages/Invoices.tsx`
+ `useInvoices.ts` umí: seznam a detail dokladu, vystavení, zahození konceptu,
storno a dobropis, označení zaplaceno, stažení PDF, regeneraci PDF, měsíční ZIP
pro účetní a kontrolní součet. Nahradit ji odkazem znamená **všechno tohle
z aplikace odstřihnout**.

Pod S2 je to obhajitelné — je to UI opuštěného enginu. Ale je to **širší zásah
než „změnit odkaz v menu"** a naráží na to, že vyřazení interního enginu je podle
rozhodnutí PM samostatný pozdější ticket.

**Proklik nebude bezešvý.** Fakturoid nemá SSO pro cizí aplikace; odkaz povede na
`https://app.fakturoid.cz/<slug>/` a Jakub se přihlásí **svým** účtem. Když
očekává „kliknu a jsem uvnitř", je lepší mu to říct předem než ho tím překvapit
na demu.

**Doklady na jednotlivé akce prolinkovat umíme.** `fakturoid_invoices.public_url`
držíme, takže „otevřít doklad k téhle akci" jde udělat přesně. To je použitelnější
než odkaz na přehled — a mimochodem to řeší i to, co má Jakub vidět hned po
potvrzení akce (požadavek A).

⚠️ **`public_url` je veřejný odkaz, který funguje bez přihlášení.** Kvůli tomu
byla v migraci díra, kterou našly brány. Kamkoli se ten odkaz v UI dá, musí být
za admin kontrolou.

**Co s doklady, které už v interním enginu jsou?** Na demu (a případně v provozu)
existují vystavené interní faktury. Když stránka zmizí, stanou se nedosažitelnými
— potřebují archivní, jen-pro-čtení pohled, nebo export.

**`billing_reconcile` a `billing_health` čtou interní `invoices`.** Pod S2 měří
špatnou věc: kontrolní součet povinný podle CLAUDE.md se bude počítat proti
tabulce, do které se přestalo psát. **Tohle je tichá porucha** — nespadne, jen
bude tvrdit nesmysl. Patří to k témuž ticketu jako vyřazení enginu.

### Otevřené otázky — C

1. **Zmizí sekce Faktury úplně, nebo zůstane jako přehled** dokladů odeslaných do
   Fakturoidu (z `fakturoid_invoices_list`) s prokliky na jednotlivé doklady?
   *Doporučuji druhé* — Jakub uvidí, co systém odeslal, aniž by opustil aplikaci,
   a proklik ho vezme na konkrétní doklad, ne na login. **Zůstává otevřené**;
   PM zatím potvrdil jen to, že C zahrnuje vyřazení interního enginu.
2. **Co s existujícími interními doklady?** Archiv, export, nebo se nechá stránka
   viset jen pro ně?
3. **Kdy se přepíše `billing_reconcile` na fakturoidí data?** ✅ **PM (provizorně):
   je to součást TÉHOŽ ticketu jako vyřazení interního enginu.** Nesmí se
   rozdělit — kontrolní součet měřící opuštěnou tabulku je tichá porucha.
4. **Má se odstranit i tlačítko „Vygenerovat fakturu" v „Kdo dluží"?** Dnes míří
   na interní engine — **dvě fakturační cesty vedle sebe je provozní riziko**,
   někdo klikne na tu špatnou.

---

## Co spolu souvisí

**A + B jsou jedna obrazovka.** Potvrzovací dialog: proběhlo takto → korekce
hodin? → přidat položky navíc? → potvrdit. Nemá smysl je stavět odděleně.

**A + C se potkávají hned po potvrzení.** Přirozené pokračování je „a tady je ten
doklad" — tedy proklik na `public_url` konkrétní faktury, ne na přehled.

**B + kontrolní součet je největší architektonická položka celé dávky.** Není to
o řádku navíc na dokladu; je to o tom, že doklad přestává být obrazem rezervací.
Rovnice z CLAUDE.md se tím mění a musí se rozhodnout jak, **než** se to začne
stavět — jinak se to zjistí až v okamžiku, kdy se součty rozejdou a nikdo nebude
vědět, jestli je to chyba, nebo občerstvení.

**C + vyřazení interního enginu je jeden ticket, ne dva.** Sjednotit UI a nechat
`billing_reconcile` číst opuštěnou tabulku by znamenalo mít kontrolní součet,
který nic nekontroluje.

---

## Co to znamená pro rozpracovaný stav

Nic z toho **neruší** hotovou práci: `InvoiceProvider`, tři zámky idempotence,
evidence `fakturoid_invoices` i ověření proti živému Fakturoidu platí dál.

Mění se dvě věci:
- **spouštěč** (dnes ruční příkaz / tlačítko → nově potvrzení akce),
- **obsah dokladu** (dnes jen rezervace → nově i ad-hoc položky).

Rozpracované tlačítko „Vystavit do Fakturoidu" (varianta B z 25. 8.) se
požadavkem A **nezahazuje**, jen se přesouvá: z „vystavit teď" se stane součást
„potvrdit akci". Do demoverze zítra to nesahá — tam pojede
`npm run fakturoid:akce`.

---

## Než se to začne stavět

1. **Kompletní přepis schůzky** — tenhle dokument stojí na shrnutí, ne na zdroji.
2. **Potvrdit čtyři provizorní odpovědi PM** (viz nahoře). Jsou zapsané jako směr,
   ne jako zadání.
3. **Dořešit, co zbývá otevřené i po nich:**
   - číselník extra položek vs. volný text, a jestli vstupuje množství (B1, B2),
   - jestli sekce Faktury zmizí, nebo zůstane jako přehled odeslaných dokladů (C1),
   - co s existujícími interními doklady (C2),
   - jde-li potvrzení akce vzít zpět a co pak s vystavenou fakturou (A3),
   - kdo smí potvrdit a co s akcí, která se nepotvrdí (A2, A7).
4. **Navrhnout migraci pro rozhodnutí 5** — rozpad `nas_soucet` na dva sloupce
   a přepis `fakturoid_radku_sedi` tak, aby počítal jen led-řádky.
5. **Navrhnout cestu pro opakování vystavení** (rozhodnutí 6) — tlačítko, nebo
   fronta po vzoru `pdf_fronta`.
