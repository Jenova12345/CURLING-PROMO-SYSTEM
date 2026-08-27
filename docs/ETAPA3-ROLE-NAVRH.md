# Etapa 3 — role a oprávnění · NÁVRH + ROZHODNUTÍ PM

**Zapsáno:** 25. 8. 2026 · **Rozhodnuto PM:** 27. 8. 2026
**Stav:** 🟢 struktura schválena; **staví se body 1 a 4** z pořadí prací (kap. 10)

> Původně podklad k rozhodnutí. PM 27. 8. 2026 strukturu schválil a odpověděl na
> tři blokující otázky, takže se z části dokumentu stalo zadání — co platí a co
> pořád čeká, říká kapitola 0.
> Souvisí s `docs/ETAPA3-POZADAVKY.md` (potvrzovací dialog) — viz kapitola 11.

---

## 0. Rozhodnutí PM (27. 8. 2026)

Tahle kapitola je **závazná**. Kde si odporuje s doporučením v původním textu
níž, platí ona; u dotčených kapitol je odkaz zpátky sem.

### 0.1 Struktura rolí — schválena beze změny enumu

| # | Rozhodnutí | Kde se to projeví |
|---|---|---|
| **R1** | **`app_role` se nemění.** Žádná nová hodnota, žádné přejmenování. | kap. 1, 2 |
| **R2** | **„Zástupce klubu" zůstává vztahem ke klubu** (`subject_reps.level = 'rep'`), **ne globální rolí.** Člověk může být zástupcem jednoho klubu a řadovým hráčem jiného. | kap. 1a, 2 |
| **R3** | **`hobby_player` se NEPŘEJMENOVÁVÁ.** Mění se jen popisek v UI na **„Hráč klubu"**. Hodnota v databázi zůstává. | kap. 2 |
| **R4** | **Životní cyklus účtu:** registrace → stav `ceka` (bez role) → schválení **přidělí roli i klub najednou**. | kap. 3 |
| **R5** | **Schvalovat smí admin i zástupce** cílového klubu (dnes jen admin). | kap. 3, 9 |
| **R6** | **RLS default-deny explicitně.** Účet mimo stav `aktivni` nesmí projít proto, že mu náhodou nesedí žádná politika — musí ho zavřít brána, která je vidět. | kap. 3, 9 |

### 0.2 Odpovědi na tři blokující otázky

| # | Otázka | Rozhodnutí PM |
|---|---|---|
| **R7** | Trenér: kdo ho vybírá? (kap. 6) | **Varianta D** — hráč vyplní **nezávazné přání**, přiřazuje admin/zástupce. **Kalendář dostupnosti trenérů je mimo tuhle etapu.** |
| **R8** | Instruktoři vs. dráhy (kap. 7) | **Default 1 instruktor na dráhu, ale vědomé přebití je povolené — varování, ne zákaz.** |
| **R9** | Sazby rolí (kap. 5) | **Jednotné per role pro celou halu** (ne per klub). U směny se ukládají jako **snapshot** a jdou **ručně přepsat** — týž vzor jako ceny u rezervací. |

### 0.3 Kdo smí potvrdit — dvě různé brány

| # | Rozhodnutí |
|---|---|
| **R10** | **Potvrzení PO akci** (spouští fakturaci **i výplaty**) smí **jen admin a zástupce klubu**. Hráči se nedává nikdy. |
| **R11** | **„Právo navíc"** (`subject_reps.muze_potvrzovat`) se týká **výhradně potvrzení rezervace PŘED akcí**. |

To potvrzuje doporučení z kapitoly 11a. Rozdíl je zásadní a nesmí se slít:
potvrzení po akci posílá firmě fakturu a brigádníkům peníze.

### 0.4 „Double potvrzení" — vysvětleno

| # | Rozhodnutí |
|---|---|
| **R12** | **„Double potvrzení" = potvrzovací krok „opravdu?" při udělení práva navíc členovi.** Není to dvoustupňové schvalování rezervací. **Priorita: nízká.** |

Tím padá blokace, kterou kapitola 4 dávala bodům 2 a 3 z pořadí prací — žádné
z těch tří čtení, kterých se text bál, neplatí. Je to jen ochrana proti překliku
v UI, ne prvek datového modelu.

### 0.5 Co se staví teď

**Body 1 a 4 z kapitoly 10**, každý jako samostatný commit přes brány:

1. **Ceník rolí** — `sazby_roli` + snapshot sazby do směny (R9).
2. **Dorovnání štábu** — trigger, který směny dopočítá i při ÚPRAVĚ akce, ne jen
   při vzniku (R8).

**Body 2, 3 a 5 se zatím NESTAVÍ** (rozhodnutí PM): životní cyklus účtu je zásah
do RLS napříč aplikací a potvrzovací dialog čeká na přepis schůzky. Jdou na řadu
až po 1 a 4.

---

## 1. Co je dnes v repu (ověřeno, ne z paměti)

| Věc | Skutečnost |
|---|---|
| `app_role` enum | `admin, trainer, part_time_staff, pro_player, hobby_player, instructor, bar_staff, manager` |
| Přiřazení rolí | `user_roles (user_id, role)`, UNIQUE — člověk může mít **víc rolí** |
| Členství v klubu | `subject_reps (subject_id, user_id, level)`, `level ∈ {rep, member}` |
| Žádost o klub | `subject_requests` — schvaluje **jen admin** (`zadosti_o_klub.sql:211`) |
| Po registraci | `handle_new_user()` přidělí **rovnou `hobby_player`** |
| Sazby směn | `shifts.hourly_rate DEFAULT 150`, rozsah 1–10 000. **Žádný ceník podle rolí neexistuje** — sazba se píše ručně při uzavírání směny |
| Směny na akci | `shifts.event_id` NOT NULL, `required_role`, `status ∈ {open, pending, claimed, completed, cancelled}` |

**Dvě věci, které je potřeba vidět správně, než se začne kreslit:**

**a) „Zástupce klubu" DNES NENÍ ROLE a nemá jí ani být.** Je to *vztah ke konkrétnímu
klubu* (`subject_reps.level = 'rep'`). Je to správně: člověk může být zástupcem
klubu CO a přitom řadovým hráčem v MK. Kdyby se „zástupce" dostal do `app_role`,
byla by to globální vlastnost a tenhle případ by nešel zapsat. **Návrh to
zachovává.**

**b) Enum nepotřebuje jedinou novou hodnotu.** Požadované role se na stávající
mapují 1:1:

| Požadavek | Dnešní hodnota | Poznámka |
|---|---|---|
| admin (správce) | `admin` | |
| zástupce klubu | *(není role)* | `subject_reps.level = 'rep'` |
| profi hráč | `pro_player` | |
| trenér | `trainer` | |
| instruktor | `instructor` | |
| obsluha baru | `bar_staff` | |
| provozní hospoda | `manager` | v UI už je popsaná takhle |
| hráč klubu | `hobby_player` | **jméno je zavádějící**, viz níž |
| „Linda" / 150 | `part_time_staff` | brigádník |

**Změna je tedy o životním cyklu a oprávněních, ne o chirurgii na enumu.** To je
dobrá zpráva pro rozsah.

---

## 2. Cílový model rolí

Dvě nezávislé osy, které se nesmí slít dohromady:

```
OSA 1 — CO ČLOVĚK DĚLÁ V HALE          OSA 2 — KE KTERÉMU KLUBU PATŘÍ
(user_roles, může jich mít víc)         (subject_reps, může jich mít víc)

  admin           správce hally            klub CO   · level=rep    (zástupce)
  trainer         trenér                   klub MK   · level=member (hráč)
  instructor      instruktor
  bar_staff       obsluha baru
  manager         provozní hospoda
  pro_player      profi hráč
  hobby_player    hráč klubu
  part_time_staff brigádník
```

**Obsluha baru a provozní hospoda jsou dvě různé role** — v enumu jsou oddělené
(`bar_staff`, `manager`) a zůstávají.

### Doporučení k `hobby_player`

Jméno teď znamená „hráč klubu", ale zní jako „hobík". Přejmenovat hodnotu enumu
jde (`ALTER TYPE ... RENAME VALUE`), ale sáhne to na **desítky míst** v kódu,
v typech i v seedu.

**Doporučuji hodnotu NEPŘEJMENOVÁVAT a změnit jen popisek v UI** na „Hráč klubu".
Přejmenování je kosmetika za cenu rizika v celém repu; popisek je to jediné, co
uživatel vidí. Kdyby PM trval na přejmenování, patří to do samostatného commitu
bez jiných změn, ať jde revertovat.

✅ **Rozhodnuto (R3):** hodnota zůstává, mění se jen popisek v UI na „Hráč klubu".

---

## 3. Životní cyklus účtu — tady je ta hlavní změna

### Dnes

```
registrace → handle_new_user() → hobby_player HNED → uživatel je uvnitř
                                                     (žádost o klub je zvlášť)
```

Uživatel má roli dřív, než ho kdokoli schválil. To je přesně ta „minimální role",
kterou klient nechce.

### Návrh

```
registrace → profil, ŽÁDNÁ role, stav „čeká"
                ↓
        žádost o klub (podá sám, nebo se ptá při registraci)
                ↓
   schválí ADMIN nebo ZÁSTUPCE cílového klubu
                ↓
    subject_reps (klub, level=member)  +  user_roles (hobby_player)
                ↓
             účet aktivní
```

**Co to znamená prakticky:**

- `handle_new_user()` přestane přidělovat roli. Založí jen profil.
- Přibude stav účtu — `profiles.stav ∈ {ceka, aktivni, zamitnut, deaktivovan}`.
- **Schvalovat smí i zástupce klubu**, ne jen admin (dnes `zadosti_o_klub.sql:211`
  pouští jen admina). Zástupce ale jen **do svého klubu**.
- Uživatel ve stavu `ceka` se přihlásí, ale uvidí jen obrazovku „čeká se na
  potvrzení". Nesmí vidět kalendář ani cokoli dalšího.

⚠️ **Tohle je zásah do RLS napříč celou aplikací**, ne jen do registrace. Dnešní
politiky se ptají `has_role(auth.uid(), 'admin')` nebo `is_subject_member(...)`.
Uživatel bez role a bez klubu jimi **projde jako „nic nevidí"** — což je náhodou
správně, ale spoléhat na náhodu se u přístupů nemá. Chce to explicitní bránu.

✅ **Rozhodnuto (R4, R5, R6):** cyklus schválen tak, jak je nakreslený výš;
schválení přiděluje roli i klub jedním krokem, schvalovat smí admin i zástupce
cílového klubu a **RLS brána má být default-deny a explicitní** — ne spoléhání
na to, že účtu bez role náhodou nesedí žádná politika.
**Nestaví se teď** (kap. 0.5) — je to bod 2 z pořadí prací.

### Migrace existujících účtů

Na demu i v provozu **už účty s `hobby_player` jsou**. Migrace je nesmí vyhodit.
Návrh: každý existující účet dostane `stav = 'aktivni'` a role mu zůstanou.
Nový stav se uplatní jen na nové registrace.

---

## 4. „Právo navíc" — zaškrtávátko od zástupce

Požadavek: zástupce může dát hráči právo potvrzovat si akce sám.

**Návrh:** `subject_reps.muze_potvrzovat boolean NOT NULL DEFAULT false`.

Dnešní `approve_reservation` pouští:

```sql
has_role(auth.uid(),'admin') OR is_subject_rep(_res.subject_id)
```

Nově navíc: **autor rezervace, který má v tom klubu `muze_potvrzovat = true`.**

| kdo | smí potvrdit |
|---|---|
| admin | cokoli |
| zástupce klubu | cokoli ve **svém** klubu |
| hráč s právem navíc | **jen svoji** rezervaci ve svém klubu |
| hráč bez práva | nic — čeká na zástupce |

To sedí i na požadavek „hráč smí potvrdit/upravit/smazat jen SVOJI akci" —
editace a mazání už dnes takhle fungují (`membership_levels.sql`), potvrzení je
to, co chybí.

### ✅ „Double potvrzení" — vysvětleno (R12)

Původně tu stály tři možná čtení a text z nich nehádal. **Neplatí ani jedno:**
PM 27. 8. 2026 upřesnil, že jde o **potvrzovací krok „opravdu?" při udělení
práva navíc členovi** — tedy ochranu proti překliku v UI, ne prvek datového
modelu ani dvoustupňové schvalování rezervací.

**Priorita nízká.** Body 2 a 3 z pořadí prací tím přestávají být blokované;
odkládají se rozhodnutím PM (kap. 0.5), ne nejasností.

Pro pořádek, co se tím tedy NEMYSLÍ: dvoustupňové schválení rezervace, ani
souběh potvrzení hráčem a trenérem. A potvrzení rezervace × potvrzení akce po
skončení jsou dvě různé brány (kap. 11a, R10/R11) — to platí nezávisle.

---

## 5. Sazby podle rolí

Požadavek: trenér 600, instruktor 250, obsluha baru 200, provozní hospoda 200,
„Linda" 150.

**Dnes žádný ceník rolí neexistuje.** `shifts.hourly_rate` má default 150 a při
uzavírání směny se píše ručně. To je zdroj překlepů a nejde z toho dělat rozpočet.

**Návrh — nová tabulka:**

```
sazby_roli
  role         app_role  PK
  sazba        numeric(10,2)  CHECK (sazba > 0 AND sazba <= 10000)
  updated_at / updated_by
```

Editovatelná **jen adminem**, s auditem (jako `billing_settings`).

⚠️ **Sazba se do směny SNAPSHOTUJE při jejím vzniku**, nedohledává se při výplatě.
Je to tatáž zásada, na které stojí `reservations.rate_per_hour`: pozdější změna
ceníku nesmí přepsat minulé výplaty. `shifts.hourly_rate` už na to je připravený
— jen se přestane plnit defaultem a začne se plnit z ceníku.

Ruční přepsání sazby na konkrétní směně **zůstane možné** (dnes to jde a je to
občas potřeba), jen přestane být výchozí cestou.

✅ **Rozhodnuto (R9):** sazby platí **jednotně pro celou halu**, ne per klub.
Snapshot do směny a ruční přepsání potvrzeno. Hodnoty od PM:

| role (`app_role`) | popis | sazba |
|---|---|---|
| `trainer` | trenér | **600** |
| `instructor` | instruktor | **250** |
| `bar_staff` | obsluha baru | **200** |
| `manager` | provozní hospoda | **200** |
| `part_time_staff` | brigádník („Linda") | **150** |

---

## 6. Otázka 1 — trenér: smí si ho vybrat hráč?

### Nejdřív fakt, který mění zadání

**Dnes tréninky NEMAJÍ ŽÁDNÉ SMĚNY.** `book_ice` vkládá `role_reqs` jen pro
komerční akce:

```sql
CASE WHEN p_kind = 'commercial' THEN p_role_reqs ELSE '{}'::jsonb END
```
*(`booking_api.sql:413`)*

Takže **přiřazení trenéra k tréninku dnes neexistuje v žádné podobě** — ani ručně.
Ať se zvolí kterákoli varianta, staví se od nuly.

### Varianty

**A — Přiřazuje jen admin/zástupce.** Hráč založí trénink, admin/zástupce k němu
přiřadí trenéra. Trenér ho vidí ve svých směnách.
*Pro:* nejjednodušší, žádné riziko kolize. *Proti:* zástupce musí obvolávat, kdo
koho chce.

**B — Hráč vybere, trenér (nebo zástupce) potvrdí.** Dvoukrokové.
*Pro:* hráč má vliv, trenér má poslední slovo. *Proti:* potřebuje **dostupnost
trenérů**, která v systému **vůbec není** — jinak si hráč vybere trenéra, co má
zrovna jiný trénink, a zjistí se to až při zamítnutí.

**C — Hráč vybere a je to závazné.** *Proti:* dvojité obsazení trenéra bez
jakékoli pojistky. **Nedoporučuji.**

**D — Hráč vyplní PŘÁNÍ, rozhoduje admin/zástupce.** Na rezervaci volitelné pole
„preferovaný trenér", které je nezávazné; přiřazení dělá pořád admin/zástupce.

### 🟢 Doporučuji D

Tři důvody:

1. **B a C potřebují kalendář dostupnosti trenérů, který neexistuje.** Postavit ho
   pořádně (dostupnost, kolize, dovolené) je samo o sobě etapa. D tenhle problém
   nemá.
2. **Zachytí to hráčovo přání**, takže zástupce nemusí nikoho obvolávat — což je
   ta praktická bolest, kterou má výběr řešit.
3. **Je to upgrade path k B.** Až dostupnost vznikne, z „přání" se stane „výběr"
   bez zahození čehokoli.

Kdyby PM chtěl B hned, je potřeba přiznat, že se tím do zakázky přidává
dostupnost trenérů, a rozhodnout, jestli se to vejde.

✅ **Rozhodnuto (R7): varianta D.** PM navíc výslovně řekl, že **kalendář
dostupnosti trenérů je mimo tuhle etapu** — tedy že se do zakázky nepřidává
a upgrade na B je pozdější rozhodnutí, ne odložený závazek.

---

## 7. Otázka 2 — instruktor: co funguje a co chybí

### Co funguje ✅

| | Kde |
|---|---|
| Dialog **předvyplní** instruktory podle počtu drah: `max(1, počet drah)` | `ReservationDialog.tsx:210–216` |
| Přestane přepisovat, jakmile do toho člověk sáhne (`instructorsTouched`) | tamtéž |
| Server **vynutí aspoň jednoho** instruktora u komerčky | `booking_api.sql:328` |
| DB trigger založí **jednu směnu na každou jednotku** z `role_reqs`, `status='open'`, `required_role` | `handle_new_commercial_event()` |
| „Volná místa" fungují implicitně — volné = počet směn se `status='open'` | |
| Dvojí zabrání směny **nehrozí**: claim jede `UPDATE … WHERE status='open'`, tedy atomicky | `useShifts.ts:113–117` |

### Co chybí ❌

**1. Vazba na dráhy je jen frontendový default, ne pravidlo.** Admin může u akce
na dvě dráhy nechat jednoho instruktora a nic ho nezastaví — server hlídá jen
`>= 1`. Že to není teorie, je vidět v seedu: akce **„Firemní teambuilding Demo"
má jednu dráhu a tři směny**, „Teambuilding Demo Firma s.r.o." dvě dráhy a tři
směny. Počet plyne z toho, co kdo naklikal, ne z drah.

**2. Trigger je `AFTER INSERT`, ne `INSERT OR UPDATE`.** Ověřeno v `pg_trigger`.
Důsledky:
- **přidání dráhy k existující akci NEPŘIDÁ směnu pro instruktora**,
- **změna `role_reqs` na existující akci se v směnách vůbec neprojeví**,
- ubrání dráhy nechá směnu viset.

Tohle je podle mě **největší reálná díra** z celé otázky 2: akce se běžně upravují
a štáb se tiše rozejde se skutečností.

**3. Předvyplnění se při editaci vůbec nespustí** (`if (isEdit …) return`), takže
ani UI na rozdíl neupozorní.

**4. Série násobí štáb.** `book_ice` volá `create_booking` pro **každý termín**,
takže každý termín je vlastní akce s vlastními směnami. Série komerčních akcí na
20 termínů založí 20× štáb. Je to nejspíš správně (každý termín se odpracuje
zvlášť), ale nikdo to nikde nepotvrdil a strop je 200 termínů.

### Návrh

- Trigger na `INSERT OR UPDATE OF role_reqs` s **dorovnáním**, ne přemazáním:
  chybějící směny doplnit, přebývající **`open`** zrušit, **`claimed`/`completed`
  nechat být** a nahlásit rozdíl. Zrušit směnu, kterou už někdo má zabranou, by
  bylo horší než nesoulad.
- Server-side kontrola „instruktorů ≥ počet drah" — jako **varování s vědomým
  přebitím** (vzor: přebití kolize u rezervací, které smí jen admin a vědomě),
  ne jako tvrdý zákaz. Můžou existovat akce, kde jeden instruktor obslouží obě dráhy.
- Při editaci rezervace ukázat, kolik směn se dorovná, **než** se to uloží.

✅ **Rozhodnuto (R8): varování, ne zákaz.** Default zůstává 1 instruktor na dráhu,
vědomé přebití je povolené.

### Co z R8 plyne pro dorovnání — a proč dráha sama směnu nepřidá

Tohle je jediné místo, kde se rozhodnutí PM a doslovné znění zadání („směny se
dopočítají i při přidání dráhy") potkávají, takže je potřeba to říct přesně:

**Zdrojem pravdy pro počet směn je `events.role_reqs`, ne počet drah.** Kdyby
přidaná dráha sama zakládala směnu, nešlo by vědomé přebití vůbec zapsat —
akce s dvěma dráhami a jedním instruktorem by si druhou směnu pokaždé sama
vyrobila zpátky. To je přesně to, co R8 zakazuje.

Dorovnání se proto dělí na dvě věci:

| | co to dělá | čím se spustí |
|---|---|---|
| **dorovnání směn** | drží `shifts` v souladu s `role_reqs` | změna `role_reqs` / `required_staff` na akci |
| **varování o dráhách** | řekne „akce má 2 dráhy a 1 instruktora" | změna počtu rezervací (drah) u akce |

Přidání dráhy tedy vede ke směně navíc **přes člověka**: varování je vidět,
člověk zvedne počet instruktorů, trigger směnu založí. Automaticky se nikdy
nezaloží ani nezruší směna kvůli dráze.

**Ubrání dráhy štáb NIKDY nesnižuje automaticky.** Snížit počet lidí, se kterými
někdo počítá, je horší chyba než přebytek — a přebytek je vidět v témž varování.
Snížení je vědomý krok admina přes `role_reqs`.

---

## 8. Návrh schématu

Všechno přírůstkové; nic se nemaže.

```sql
-- 1) stav účtu
ALTER TABLE profiles ADD COLUMN stav ucet_stav NOT NULL DEFAULT 'ceka';
--    existující účty → 'aktivni' (datová část migrace)

-- 2) právo navíc
ALTER TABLE subject_reps ADD COLUMN muze_potvrzovat boolean NOT NULL DEFAULT false;

-- 3) ceník rolí
CREATE TABLE sazby_roli (role app_role PRIMARY KEY, sazba numeric(10,2), …);

-- 4) preferovaný trenér (varianta D)
ALTER TABLE reservations ADD COLUMN preferovany_trener uuid REFERENCES profiles(user_id);

-- 5) přiřazený trenér — přes SMĚNY, ne přes sloupec na rezervaci
--    (trénink dostane role_reqs {'trainer': 1} a jede stejnou cestou jako štáb komerčky)
```

**Bod 5 stojí za komentář:** nabízí se `reservations.trener_id`, ale trenér je
z pohledu systému **týž případ jako instruktor** — někdo, kdo si odpracuje hodiny
a dostane zaplaceno. Když půjde přes `shifts`, dostane zadarmo výplaty, výkazy
i uzavírání hodin. Vlastní sloupec by znamenal druhou, paralelní cestu k témuž.

---

## 9. Dopad na stávající kód

| Soubor / objekt | Co se mění |
|---|---|
| `handle_new_user()` | přestane přidělovat `hobby_player`, založí profil ve stavu `ceka` |
| `zadosti_o_klub.sql` → schvalovací RPC | povolit i zástupci **svého** klubu; schválení nově přidělí i roli |
| `approve_reservation()` | přidat větev pro autora s `muze_potvrzovat` |
| RLS napříč (`reservations`, `subjects`, `shifts`, …) | explicitní brána na `stav = 'aktivni'` |
| `handle_new_commercial_event()` | `AFTER INSERT` → `INSERT OR UPDATE`, s dorovnáním |
| `book_ice` / `create_booking` | `role_reqs` i pro tréninky (kvůli trenérovi) |
| `ReservationDialog.tsx` | preferovaný trenér, dorovnání štábu při editaci |
| `useShifts.ts` | sazba z ceníku místo natvrdo `150` |
| Registrace / `Auth.tsx` | obrazovka „čeká se na potvrzení" |
| `navigation.ts` | položky podle stavu účtu, ne jen podle role |

**Riziko:** dotýká se to RLS, tedy toho, co CLAUDE.md hlídá nejpřísněji. Testy
práv se **musí** psát přes `authenticator` — jak se ukázalo u fakturace, `SET ROLE`
pod `psql -U postgres` propustí věci, které v provozu neprojdou (a naopak).

---

## 10. Návrh pořadí prací

Po samostatných kusech, každý přes brány:

1. **Ceník rolí** (`sazby_roli` + snapshot do směny). Nezávislé, malé, hned užitečné.
2. **Životní cyklus účtu** (stav + schvalování zástupcem + RLS brána). Největší kus.
3. **Právo navíc** (`muze_potvrzovat` + `approve_reservation`). Navazuje na 2.
4. **Dorovnání štábu** (trigger `INSERT OR UPDATE`). Nezávislé na 1–3.
5. **Trenér** podle rozhodnutí u otázky 1.

**1 a 4 jdou udělat hned** a nečekají na přepis schůzky. **2 a 3 čekají**, protože
se jich týká „double potvrzení". **5 čeká** na rozhodnutí.

✅ **Aktualizace 27. 8. 2026:** staví se **1 a 4**. Body **2 a 3** už neblokuje
nejasnost kolem „double potvrzení" (R12 ji vysvětlil) — odkládá je **rozhodnutí
PM**, protože životní cyklus účtu je zásah do RLS napříč aplikací a chce vlastní
kolo bran. Bod **5** je rozhodnutý (R7 = varianta D), ale staví se až po 1 a 4.

---

## 11. Souvislost s potvrzovacím dialogem fakturace

Z `docs/ETAPA3-POZADAVKY.md` (požadavek A) plyne, že **potvrzení akce je společný
spouštěč fakturace i směn**. Tenhle návrh se s tím potkává na třech místech:

**a) Kdo smí potvrdit akci.** Požadavek A mluví o Jakubovi (admin). Tenhle návrh
zavádí „právo navíc" pro hráče. **Je potřeba říct, jestli se to týká i potvrzení
po akci, nebo jen potvrzení rezervace.** Rozdíl je zásadní: potvrzení po akci
spouští **fakturaci firmě a výplaty brigádníkům**. Dát to hráči klubu je něco
úplně jiného než dovolit mu potvrdit si vlastní trénink.
→ **Doporučuji: potvrzení po akci zůstane adminovi a zástupci.** „Právo navíc"
ať se týká jen potvrzení rezervace.
→ ✅ **Rozhodnuto přesně takhle (R10, R11).**

**b) Uzavření směn v tom dialogu.** Potvrzovací dialog má odemknout směny. Sazby
z ceníku (kapitola 5) jsou přesně to, co se v něm předvyplní — bez ceníku by
Jakub psal 600/250/200 ručně u každé směny.
→ **Ceník rolí je předpokladem potvrzovacího dialogu**, ne nezávislý úkol.

**c) Instruktoři a dorovnání štábu.** Když se akce mezi založením a konáním upraví
(přibude dráha), dnes se štáb nedorovná — a v potvrzovacím dialogu by pak seděl
špatný počet směn. **Bod 4 z pořadí prací by měl být hotový dřív** než potvrzovací
dialog.

---

## 12. Otevřené otázky

> Zodpovězené jsou přeškrtnuté a mají odkaz na rozhodnutí z kapitoly 0.
> Zbytek pořád čeká — a body 2, 3 a 5 z pořadí prací se bez něj nemají začínat.

**K rolím a účtům**

1. ~~**Co znamená „double potvrzení"?**~~ ✅ **R12** — potvrzovací krok „opravdu?"
   při udělení práva navíc. Nízká priorita. Body 2 a 3 už neblokuje.
2. **Může být uživatel v `ceka` navždy?** Připomínka zástupci? Automatické zamítnutí?
3. **Co když člověk odejde z klubu?** Ztratí roli? Zůstane historie směn a výplat?
   (Musí — jsou to peníze.)
4. **Smí být člověk ve dvou klubech?** Schéma to umožňuje. Chce to klient?
5. **Kdo přiděluje pracovní role** (trenér, instruktor, bar, provozní)? Admin, nebo
   i zástupce? Zástupce klubu, který si udělá z hráče instruktora, tím vytváří
   náklad hale.
6. **Zamítnutí žádosti** — vidí uživatel důvod? (`subject_requests.decision_reason` existuje.)

**K trenérovi**

7. ~~Varianta A/B/C/D~~ ✅ **R7 — varianta D.** Kalendář dostupnosti mimo etapu.
8. Když D: je „preferovaný trenér" vidět jen zástupci, nebo i ostatním hráčům klubu?

**K instruktorům**

9. ~~Má být „instruktorů ≥ počet drah" tvrdé pravidlo, nebo varování?~~
   ✅ **R8 — varování s vědomým přebitím.**
10. Co se má stát se **zabranou** směnou, když se akci ubere dráha?
    *(Postavené řešení ji nechává být a rozdíl hlásí — viz kap. 7. Zůstává
    otevřené, jestli má provoz chtít něco navíc, třeba notifikaci brigádníkovi.)*
11. Série komerčních akcí: opravdu má každý termín vlastní štáb? (Nejspíš ano, ale potvrdit.)

**K sazbám**

12. ~~Je „Linda" role, nebo konkrétní člověk?~~ ✅ Potvrzeno jako `part_time_staff`
    (brigádník, 150) — viz tabulka u R9.
13. ~~Mají se sazby lišit podle klubu, nebo platí pro celou halu jednotně?~~
    ✅ **R9 — jednotně pro celou halu.**

---

## 13. Co bylo potřeba rozhodnout, aby se dalo začít

Všechny tři odpovědi dorazily 27. 8. 2026 (kap. 0.2):

1. **Trenér: varianta D** — přání hráče, rozhoduje admin/zástupce. ✅
2. **Instruktoři vs. dráhy: varování, ne zákaz.** ✅
3. **Sazby platí pro celou halu jednotně.** ✅

S nimi se staví **body 1 a 4** z pořadí prací (ceník rolí a dorovnání štábu) —
obojí je nezávislé na přepisu schůzky a obojí je předpokladem potvrzovacího
dialogu. Body 2, 3 a 5 čekají, viz kap. 0.5.
