# Etapa 3 — role: co zbývá po bloku C · PLÁN

**Zapsáno:** 31. 8. 2026 · **Aktualizováno:** 31. 8. 2026 (rozhodnutí PM — kap. 0a)
**Stav:** plán **odsouhlasený**, nic z toho není postavené
**Navazuje na:** `docs/ETAPA3-ROLE-NAVRH.md` (rozhodnutí PM R1–R12), `docs/ETAPA3-STAV.md` kap. 6c (blok C)

> Tenhle dokument je **plán, ne popis stavu**. Co už funguje, je v kapitole 1 —
> a je to ověřené čtením kódu a migrací, ne z paměti. Kde je něco jen navržené,
> je to označené jako návrh.

---

## 0. Shrnutí na jednu obrazovku

Zbývají čtyři kusy. Tři z nich jsou malé a jeden je velký:

| # | Kus | Velikost | Migrace? | Blokuje ho něco? |
|---|---|---|---|---|
| **A** | Správa zástupců a členů klubu | střední | ano (RLS) | ne |
| **B** | „Právo navíc" — UI + double potvrzení | **malý** | ne (jen RLS z A) | **ano — A** |
| **C** | Trenér u tréninku (varianta D) | střední | ano (1 sloupec + 2 RPC) | ne (Q8 neblokuje) |
| **D** | Instruktor–dráha: zbývá zobrazení varování | malý | **ano, malá** (náhled) | ne |

**Pořadí A → B → D → C — potvrzeno PM 31. 8. 2026** (P4). Zdůvodnění v kapitole 6.

Nejdůležitější věc z celého dokumentu: **bod C dává tréninku cenu, ale jen když
má trenéra.** Trénink bez trenéra nadále nestojí nic; placená směna 600 Kč/h
vzniká **až přiřazením konkrétního trenéra** (rozhodnutí PM Q14). Je to pořád
jediný z těch čtyř kusů, který se dotýká výplat.

---

## 0a. Rozhodnutí PM (31. 8. 2026)

Tahle kapitola je **závazná**. Kde si odporuje s návrhem níž, platí ona —
u dotčených míst je odkaz sem.

| # | Rozhodnutí | Kde se to projeví |
|---|---|---|
| **P1** (Q14) | **Trénink generuje placenou trenérskou směnu 600 Kč/h JEN při přiřazení trenéra.** Trénink bez trenéra negeneruje nic. C2 staví směnu **při přiřazení**, ne při založení rezervace. | kap. 4, C2 |
| **P2** (Q5) | **Přidělování pracovních (placených) rolí — trenér, instruktor, obsluha baru — smí JEN ADMIN.** Zástupce klubu schvaluje členství a uděluje „právo navíc"; role nerozdává. | kap. 2, 4 |
| **P3** (Q3) | **Odebírání členů zůstává zatím adminovi.** Bod A se staví **read-only** (zástupce členy vidí, nespravuje). Plná politika odchodu z klubu se dořeší později. | kap. 2 |
| **P4** | **Pořadí stavění A → B → D → C potvrzeno.** | kap. 6 |

**Co tím padá:** Q14, Q5 a Q3 přestávají být blokující (kap. 7). Zbývá jediná
neblokující otázka s dopadem na návrh — **Q8** (kdo vidí „přání trenéra").

**Co se tím naopak zjednodušilo:** P1 mění mechanismus C2 natolik, že **odpadá
zásah do `create_booking` i do `dorovnej_stab`**, kterého se původní verze
tohohle plánu bála. Podrobně v kapitole 4.

---

## 1. Kde jsme (ověřeno v kódu, ne z paměti)

### Co už funguje

| Věc | Kde to je | Poznámka |
|---|---|---|
| Ceník rolí `sazby_roli` (trenér 600, instruktor 250, …) | `20260827090000_sazby_roli.sql` | bod 1 z pořadí prací — **hotovo** |
| Dorovnání štábu při ÚPRAVĚ akce | `20260827100000_dorovnani_stabu.sql` | bod 4 — **serverová část hotová** |
| Pohled `stab_kontrola` (varování „2 dráhy, 1 instruktor") | tamtéž | **v UI se nikde nepoužívá** — viz bod D |
| Životní cyklus účtu, `profiles.stav`, brána `ucet_aktivni()` | `20260831140000_zivotni_cyklus_uctu.sql` | blok C — hotovo |
| Schvalování žádostí zástupcem (jen do svého klubu) | `approve_subject_request` | blok C |
| Jmenovat zástupce smí **jen admin** | tamtéž, větev `_level = 'rep'` | blok C |
| `subject_reps.muze_potvrzovat` + `ma_pravo_navic()` + `nastav_pravo_navic()` | blok C | **backend hotový, UI chybí** |
| Hráč s právem navíc potvrdí **jen svoji** rezervaci | `approve_reservation`, větev `_jen_svoje` | blok C |
| Správa zástupců pro admina | `src/pages/Subjects.tsx` + `useSubjectsAdmin` | píše do `subject_reps` napřímo přes PostgREST |
| Audit změn členství a zmocnění | `trg_subject_reps_audit` (INSERT/UPDATE/DELETE) | platí i na `muze_potvrzovat` |

### Tři fakta, na kterých celý zbytek stojí

**1. Zástupce NEVIDÍ členy svého klubu.** Politika `subject_reps_select`
(`20260716140000_etapa1_rls.sql:49`) zní:

```sql
USING (has_role(auth.uid(), 'admin') OR user_id = auth.uid())
```

Od Etapy 1 se nezměnila — ověřeno grepem přes všechny migrace. Zástupce si tedy
přečte **jen svůj vlastní řádek**. Že mu přesto funguje schvalování žádostí, je
tím, že `approve_subject_request` je SECURITY DEFINER a frontu mu otevřela
vlastní politika na `subject_requests` (blok C).

> **Tohle je ta věc, která blokuje bod B.** „Právo navíc" se uděluje konkrétnímu
> členovi, a zástupce si dnes seznam členů nenačte. Backend by ho udělil
> (`nastav_pravo_navic` je SECURITY DEFINER), ale UI nemá co zobrazit.

**2. Tréninky nemají žádné směny — a je to hlídané na DVOU místech.**

| Kde | Co dělá |
|---|---|
| `create_booking` (`20260731120000_booking_api.sql:413`) | `CASE WHEN p_kind = 'commercial' THEN p_role_reqs ELSE '{}' END` |
| `dorovnej_stab` (`20260827100000_dorovnani_stabu.sql:340,358`) | `AND _ev.event_type IN ('commercial','recruitment')` |

Migrace dorovnání si na to sama nechala vzkaz:

> ⚠️ AŽ SE BUDE STAVĚT R7 (trenér k tréninku), musí se to povolit VĚDOMĚ
> a na obou místech naráz — tady i v `create_booking`.

A hned vedle stojí, proč to tam vůbec je: než se to zavřelo, přepnutí komerční
akce na `training` jí založilo **placené směny** (4 × 250 Kč/h), na které se
mohli brigádníci přihlásit — a z UI je nešlo odebrat, protože sekce štábu je pro
trénink skrytá.

**3. `reservations.preferovany_trener` neexistuje.** Ověřeno grepem přes
migrace i `src/`. Kapitola 8 návrhu ho navrhuje, postavený není.

---

## 2. Bod A — správa zástupců a členů klubu

### Co se staví

Dvě oddělené věci, které se pletou dohromady:

| | kdo to smí dnes | kdo to má smět |
|---|---|---|
| **jmenovat zástupce** klubu | jen admin | **jen admin** (beze změny, R2) |
| **vidět členy** svého klubu | jen admin | **admin + zástupce toho klubu** |
| **spravovat členy** svého klubu (odebrat) | jen admin | **zůstává adminovi** (P3) — bod A je read-only |

Jmenování zástupce **zůstává adminovi** a už je to vynucené na dvou místech:
politikou `subject_reps_insert_admin` a větví v `approve_subject_request`
(„Zástupce klubu smí jmenovat jen správce haly"). **Tady se nic neměří ani
nemění** — bod A je o tom, aby zástupce vůbec viděl, s kým pracuje.

**Bod A je tím pádem READ-ONLY** (rozhodnutí P3). Zástupce dostane seznam členů
svého klubu a nic víc; jediná zapisovací věc, kterou bude mít, je „právo navíc"
z bodu B — a ta jde přes vlastní RPC, ne přes tabulku. Odebírání členů zůstává
adminovi, dokud se nedořeší politika odchodu z klubu (co se stane s rolí,
s historií směn a s výplatami).

To má i příjemný důsledek pro rozsah: bod A je **jedna SELECT politika a jedna
obrazovka**. Žádné nové zapisovací RPC, žádná další práva.

### Co se dotkne

- **Migrace/RLS:** rozšířit `subject_reps_select` o `is_subject_rep(subject_id)`.
  Je to jednořádková změna politiky, ale je to **rozšíření viditelnosti osobních
  údajů** — zástupce uvidí jména členů svého klubu. To je přesně to, co role
  „zástupce klubu" znamená (rezervuje za celý klub, potvrzuje jejich rezervace),
  takže je to v souladu s rozhodnutím klienta z 31. 7.
- **Pozor na jméno:** `subject_reps` drží jen `user_id`. Jména se tahají
  z `profiles_public` (`useSubjectsAdmin.ts:46`). Ověřit, že `profiles_public`
  pustí jména i zástupci — jinak se rozšíří jedna politika a UI ukáže samá
  „(neznámý uživatel)".
- **Frontend:** `useSubjectsAdmin` je dnes celý admin-only (`enabled: isAdmin`).
  Pro zástupce potřebuje buď vlastní hook, nebo přepínač rozsahu. Doporučuji
  **nový hook `useMujKlub`** místo rozšiřování admin hooku — ten píše do
  `subjects` a `subject_reps` napřímo a zástupci by se ta práva neměla ani
  omylem nabídnout.
- **Nová stránka nebo sekce:** „Můj klub" pro zástupce (seznam členů, u každého
  přepínač práva navíc — to už je bod B). `Subjects.tsx` nechat adminovi.

### Migrace / RLS dopad

```sql
-- rozšíření viditelnosti, ne zápisu
DROP POLICY IF EXISTS subject_reps_select ON public.subject_reps;
CREATE POLICY subject_reps_select ON public.subject_reps
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin')
         OR user_id = auth.uid()
         OR public.is_subject_rep(subject_id));
```

Zápisové politiky (`insert/update/delete_admin`) se **nemění**. Cokoli, co má
smět zástupce, jde přes SECURITY DEFINER RPC — tak to už dělá
`nastav_pravo_navic` z bloku C a je to správný vzor: tabulka zůstane zavřená
a povolené výjimky jsou vyjmenované a auditovatelné.

`is_subject_rep` má od bloku C v sobě bránu `ucet_aktivni()`, takže deaktivovaný
zástupce touhle politikou neprojde. To je zadarmo a je dobře to vědět.

### Testy

- `subject_reps_select` pod `SET LOCAL ROLE authenticated` (pravidlo 8): zástupce
  vidí členy svého klubu, **nevidí** členy cizího, řadový člen vidí jen sebe.
- Deaktivovaný zástupce nevidí nic.

---

## 3. Bod B — „právo navíc": UI + double potvrzení

### Co se staví

Backend je **hotový z bloku C** a nic se v něm nemění:

- `nastav_pravo_navic(_subject, _user, _hodnota)` — smí admin nebo zástupce
  toho klubu, nastavuje jen řádkům s `level = 'member'`,
- `ma_pravo_navic(_subject)` — čte `approve_reservation`,
- `approve_reservation` má větev `_jen_svoje` (hráč potvrdí jen to, co sám
  založil).

Chybí **jen UI**. Konkrétně: v seznamu členů klubu (bod A) u každého člena
přepínač „smí si sám potvrdit rezervaci", který volá `nastav_pravo_navic`.

### Double potvrzení (R12)

R12 říká, že „double potvrzení" je **krok „opravdu?" při udělení práva navíc** —
ochrana proti překliku, ne prvek datového modelu.

Návrh chování, ať je to symetrické s tím, co dělá `Requests.tsx` u jmenování
zástupce:

- **udělení** práva → potvrzovací dialog se jménem člena a klubem
  („Dát členovi *Jan Novák* právo potvrzovat si vlastní rezervace v klubu
  *CK Ostravské kameny*?"),
- **odebrání** práva → **bez dialogu**. Odebrání oprávnění je bezpečný směr;
  ptát se na něj jen učí lidi odklikávat dialogy bez čtení.

`Requests.tsx` dnes používá `window.confirm`. Pro nové UI doporučuji `AlertDialog`
ze shadcn (v repu je), protože `window.confirm` blokuje vlákno a nejde
ostylovat — ale **je to kosmetika, ne blokující rozhodnutí**. Když se sáhne po
`window.confirm`, aspoň to bude konzistentní se stávajícím kódem.

### Co se dotkne

- **Migrace:** žádná. Bod B nepotřebuje ani jednu — celý backend stojí.
- **RLS:** jen ta z bodu A (jinak není koho zobrazit).
- **Frontend:** seznam členů z bodu A + přepínač + potvrzovací dialog + toast.
- **Audit:** není potřeba nic dodělávat — `trg_subject_reps_audit` je na
  INSERT/UPDATE/DELETE, takže se změna `muze_potvrzovat` zapíše sama.

### Testy

Serverové testy už jsou (`zivotni_cyklus_test.sql`, sekce 5 a 6). Dopsat se má
jen to, co přibude v UI — a to jsou ve skutečnosti dvě tvrzení, která jdou
otestovat i v SQL:

- řadový člen **nemůže** `nastav_pravo_navic` zavolat (už otestováno),
- zástupce ho **nemůže** nastavit členovi cizího klubu ← **tohle v testech chybí**,
  `nastav_pravo_navic` se dnes ptá `is_subject_rep(_subject)`, takže by to mělo
  projít správně, ale netvrdí to žádný test.

---

## 4. Bod C — trenér u tréninku (varianta D)

**Jediný kus, který se dotýká výplat** — a po rozhodnutí P1 menší, než to
vypadalo. Rozpadá se na dvě části, které jdou postavit odděleně a v tomhle
pořadí.

### C1 — „přání trenéra" na rezervaci (malé, bez rizika)

```sql
ALTER TABLE public.reservations
  ADD COLUMN preferovany_trener uuid REFERENCES public.profiles(user_id);
```

- **Nezávazné pole**, jak říká R7. Nic nespouští, nikoho nepřiřazuje.
- **Jen u tréninků** — u komerční akce nedává smysl. Vynutit CHECKem
  (`preferovany_trener IS NULL OR event_type = 'training'`) nejde, protože typ
  akce je na `events`, ne na `reservations`. Řešit v UI a v `create_booking`,
  a **nepředstírat, že to drží databáze**.
- **Kdo se nabízí ve výběru:** lidé s rolí `trainer`. Pozor: `has_role` má od
  bloku C v sobě `ucet_aktivni()`, takže deaktivovaný trenér ze seznamu vypadne
  sám.
- **Kdo přání vidí:** otevřená otázka **Q8** — viz kapitola 7. Do rozhodnutí
  navrhuji **admin, zástupce klubu a autor rezervace**, tedy stejný okruh jako
  u částky. Je to nejmenší možný rozsah a jde ho kdykoli rozšířit.

Dopad na `create_booking`: přidat parametr a uložit ho. **RLS beze změny** —
sloupec jede na existujících politikách `reservations`.

### C2 — trenér jako SMĚNA, vzniklá PŘIŘAZENÍM (rozhodnutí P1)

R7 i kapitola 8 návrhu říkají, že přiřazený trenér má jít **přes `shifts`**, ne
přes sloupec na rezervaci — dostane tím zadarmo výplaty, výkazy i uzavírání
hodin. To platí dál. **Rozhodnutí P1 ale mění okamžik, kdy směna vzniká:**

> Trénink generuje placenou trenérskou směnu 600 Kč/h **jen při přiřazení
> trenéra**. Trénink bez trenéra negeneruje nic.

### Tím odpadá past, které se původní verze plánu bála

Původně tu stálo, že se tréninkům musí pustit `role_reqs = {"trainer": 1}`,
a že se to musí povolit **na dvou místech naráz** — v `create_booking:413`
a ve filtru `event_type` v `dorovnej_stab`. **S P1 se nic z toho nedělá.**

Důvod: `role_reqs` je *poptávka* („chceme jednoho trenéra, ať se přihlásí"),
kdežto přiřazení je *adresné* („tenhle trenér to povede"). Kdyby přiřazení šlo
přes `role_reqs`, vznikla by směna se `status = 'open'`, kterou si může zabrat
**kdokoli jiný** s rolí `trainer` — tedy přesný opak přiřazení.

**Tréninky proto zůstanou mimo `role_reqs` i mimo dorovnání** a směnu zakládá
přímo přiřazovací RPC. `create_booking:413` i filtr v `dorovnej_stab` zůstávají
**beze změny**.

### Jedna věc, kterou to vyžaduje: směna musí vzniknout rovnou obsazená

Ověřeno v `dorovnej_stab` (`20260827100000_dorovnani_stabu.sql`): funkce
**nemá pro tréninky předčasný návrat**. Sestaví `pozadavek` (pro trénink prázdný,
protože ho odfiltruje `event_type IN ('commercial','recruitment')`) a udělá
`FULL JOIN` s `existujici`, tedy se všemi nezrušenými směnami akce. Pro trénink
s jednou trenérskou směnou tak vyjde `chceme = 0 < mame = 1` — tedy přebytek.

Zruší ho ale **jen když je `status = 'open'`** (`AND status = 'open'` ve větvi
`ke_zruseni`). Z toho plyne pravidlo, které se musí dodržet:

> **Trenérská směna se zakládá rovnou jako obsazená** (`claimed_by` = trenér,
> `claimed_at`, odpovídající status), **nikdy jako `open`.** Kdyby vznikla
> otevřená, sebral by ji buď cizí trenér, nebo dorovnání při nejbližší změně
> `event_type` / `role_reqs` na té akci.

Trigger dorovnání se navíc spouští jen na `UPDATE OF role_reqs, required_staff,
event_type`, takže běžná úprava tréninku ho vůbec nevzbudí. Obsazená směna je
v bezpečí tak jako tak — ale spoléhat na to, že se ta tři pole nikdy nezmění,
by bylo přesně to „spoléhání na náhodu", které si repo jinde zakazuje.

### Sazba se nepíše ručně

`dorovnej_stab` `hourly_rate` schválně nevyplňuje — doplní ho trigger
`set_shift_rate` z `sazby_roli` (migrace `20260827090000`). **Přiřazovací RPC
má udělat totéž: sazbu nevyplňovat.** 600 Kč/h se tím vezme z ceníku a nevznikne
druhá, tišší cesta k sazbě. (Ruční přepsání na konkrétní směně zůstává možné,
jak říká R9.)

### Co se dotkne

| Vrstva | Zásah |
|---|---|
| **Migrace** | `assign_trainer(_reservation_id, _user_id)` a `unassign_trainer(...)` — SECURITY DEFINER, `SET search_path`, EXECUTE jen pro `authenticated`. Žádná změna `create_booking` ani `dorovnej_stab`. |
| **RLS** | Přiřadit smí **admin nebo zástupce klubu** té rezervace (R7). Uvnitř RPC, ne politikou — tabulka `shifts` zůstane zavřená. |
| **Role** | Přiřadit lze jen člověka, který **už roli `trainer` má**. Udělit tu roli smí **jen admin** (P2) — přiřazení role a přiřazení k tréninku jsou dvě různé věci a nesmí se slít. |
| **Odebrání** | **Soft**: `status = 'cancelled'` + `cancelled_at`/`cancelled_by`, nikdy DELETE (zásada 2). Už odpracovanou (`completed`) směnu neodebírat vůbec — jsou to peníze. |
| **Frontend** | V detailu tréninku „Trenér: — / přiřadit". Sekce štábu (rozpis rolí) zůstane pro trénink **skrytá** — trénink nemá štáb, má trenéra. |

### Co pohlídat

1. **Přiřazení musí být idempotentní** a nesmí jít přiřadit dva trenéry na týž
   trénink, aniž by to někdo chtěl. Přepsání přiřazení = zrušit starou směnu
   (soft) a založit novou.
2. **Pravidlo „aspoň 1 instruktor" se nesmí rozlít na tréninky.**
   `create_booking:328` ho vynucuje u komerčky; trénink instruktora mít nemusí.
3. **`stab_kontrola`** počítá dráhy proti instruktorům. Ověřit, že trénink
   s trenérskou směnou v něm nezačne svítit jako podstavený.
4. **Série tréninků.** `book_ice` zakládá akci na každý termín. Přiřazení se
   dělá na jednotlivý trénink, takže série 20 tréninků znamená 20 přiřazení —
   **to je hodně klikání.** Buď to přiznat jako vědomé omezení první verze,
   nebo rovnou přidat „přiřadit na celou sérii". Doporučuji přiznat a nechat
   na provoz, jestli to bude vadit.
5. **Kontrolní součet výplat.** Trenérské směny vstupují do výplat stejně jako
   instruktorské. Ověřit, že se `Payouts` a měsíční výkazy chovají správně —
   je to první případ, kdy směna vznikla mimo komerční akci.

### Pořadí uvnitř bodu C

**C1 postavit a nasadit samostatně.** Je to nezávazné pole, dá se ukázat
klientovi a nic nerozbije. **C2 až potom**, jako vlastní kus s vlastními bránami
— dotýká se výplat, což je stejná kategorie jako fakturace.

---

## 5. Bod D — instruktor vs. dráha: zbývá zobrazit varování

### Co je hotové

Celá serverová část, z bloku „dorovnání štábu":

- trigger na `INSERT OR UPDATE OF role_reqs, required_staff, event_type`,
- dorovnání **doplní chybějící / zruší jen `open` / nesahá na zabrané**,
- soft-cancel (`status='cancelled'` + razítka), ne DELETE,
- CHECK na tvar `role_reqs` včetně stropu,
- **pohled `stab_kontrola`** = to samotné varování „akce má 2 dráhy a 1 instruktora".

R8 („varování, ne zákaz") je tím na serveru **splněné**.

### Co zbývá

**Jen zobrazit to varování člověku.** `stab_kontrola` se v `src/` nevyskytuje
ani jednou — ověřeno grepem. Pohled tedy existuje a nikdo se ho neptá.

Konkrétně:

1. **Varování u akce**, kde je vidět kalendář / detail obsazení: „Akce má
   2 dráhy a 1 instruktora." Ne blokující, jen viditelné.
2. **Náhled dorovnání před uložením** (kapitola 7 návrhu): při editaci akce
   ukázat „uloží se 1 směna navíc / zruší se 1 volná směna" **dřív**, než se
   uloží.

   ⚠️ **Tady jsem se při psaní tohohle plánu spletl a stojí to za zaznamenání.**
   Nabízelo se použít `dorovnej_stab(uuid, boolean)` s druhým parametrem jako
   „běh nanečisto". **Není to běh nanečisto.** `_jen_doplnit = true` znamená
   „směny se JEN DOPLŇUJÍ, nic se neruší" — pořád zapisuje. Náhled by tím
   rovnou založil směny, které měl jen předpovědět.

   Navíc má `dorovnej_stab` **odebrané `EXECUTE` pro `authenticated`** (vědomě,
   je to SECURITY DEFINER nad směnami), takže ji frontend zavolat ani nemůže.

   Náhled tedy potřebuje **novou read-only funkci** — něco jako
   `stab_nahled(_event_id, _role_reqs) RETURNS TABLE(role, doplni_se, zrusi_se, nesaha_se)`,
   STABLE, bez zápisu, s `EXECUTE` pro `authenticated`. **To je malá migrace,
   ne „žádná".**
3. **Předvyplnění při editaci.** `ReservationDialog` se při editaci vůbec
   nepřepočítá (`if (isEdit …) return`), takže na rozdíl neupozorní. Nechat
   předvyplnění vypnuté (přepisovat člověku ruční počty by bylo horší), ale
   ukázat vedle něj varování z bodu 1.

### Co se dotkne

- **Migrace: malá, a je potřeba.** Samotné varování (bod 1) migraci nechce —
  `stab_kontrola` existuje a stačí se ho zeptat. **Náhled (bod 2) migraci chce**,
  protože `dorovnej_stab` zapisuje a frontend na ni stejně nemá právo (viz výš).
  Když se náhled odloží, bod D je opravdu bez migrace — ale ať je to vědomé.
- **RLS:** ověřit, že `stab_kontrola` je čitelný pro admina a zástupce a že
  nevydává víc, než má (je to pohled nad `events`/`shifts`).
- **Frontend:** `ReservationDialog` + detail akce.

---

## 6. Pořadí stavění (potvrzeno PM — P4)

```
A (RLS: zástupce vidí svůj klub)
      ↓  odemyká
B (právo navíc: UI + double potvrzení)      ← rychlá výhra, backend stojí
      ↓
D (UI k varování o dráhách)                 ← bez migrace, nezávislé
      ↓
C1 (přání trenéra — pole na rezervaci)
      ↓
C2 (trenér jako směna)                      ← dotýká se výplat, vlastní brány
```

**Proč takhle:**

- **A první**, protože bez něj bod B nemá co zobrazit. Je to jedna politika.
- **B hned po A**, protože backend už stojí — je to nejlepší poměr práce
  k výsledku z celého seznamu a klientovi se to dobře ukazuje.
- **D kdykoli**, je nezávislé. (Samotné varování je bez migrace, náhled s malou.) Návrh (kap. 11c) chtěl bod 4
  hotový **před potvrzovacím dialogem fakturace** — serverově hotový je, takže
  tohle pořadí nikoho neblokuje.
- **C až nakonec** a rozdělené: C1 je nezávazné pole, C2 sahá na peníze.

**Co lze dělat souběžně:** D nezávisí na A/B ani na C. Když bude potřeba ukázat
rychle víc věcí, jde D postavit vedle B.

---

## 7. Otevřené otázky

### Vyřešené v tomhle plánu (technická rozhodnutí, nepotřebují PM)

| # | Otázka | Rozhodnutí |
|---|---|---|
| — | Kde se udělí právo navíc? | V seznamu členů klubu (bod A), přepínač u člena. |
| — | Double potvrzení i při odebrání práva? | **Ne.** Jen při udělení; odebrání je bezpečný směr. |
| — | Rozšířit `useSubjectsAdmin`, nebo nový hook? | **Nový hook** `useMujKlub`. Admin hook píše do `subjects` napřímo a zástupci se ta práva nemají nabídnout ani omylem. |
| — | Přiřazený trenér: sloupec, nebo směna? | **Směna** (R7, kap. 8) — jinak vzniká druhá cesta k výplatám. |
| — | Vynutit „přání trenéra jen u tréninku" CHECKem? | **Nejde** (typ akce je na `events`). Řešit v UI a `create_booking` a nepředstírat, že to drží DB. |

### Vyřešeno PM 31. 8. 2026 — už nic neblokuje

| # | Otázka | Rozhodnutí | Dopad na plán |
|---|---|---|---|
| **Q14** | Má trénink stát peníze? | **Ano, ale jen s trenérem.** Placená směna 600 Kč/h vzniká **při přiřazení** trenéra; trénink bez trenéra negeneruje nic. | Přepsalo C2 (kap. 4). Odpadl zásah do `create_booking` i `dorovnej_stab`; přibylo pravidlo „směna vzniká rovnou obsazená". |
| **Q5** | Kdo přiděluje pracovní (placené) role — trenér, instruktor, bar? | **Jen admin.** Zástupce schvaluje členství a uděluje „právo navíc", role nerozdává. | Potvrzuje dnešní stav (`Members.tsx` je admin-only). V C2 se musí odlišit *udělení role* `trainer` (admin) od *přiřazení k tréninku* (admin i zástupce). |
| **Q3** | Co když člověk odejde z klubu? | **Zatím se neřeší** — odebírání členů zůstává adminovi. Plná politika odchodu (role, historie směn, výplaty) přijde později. | Bod A je **read-only**: jedna SELECT politika a jedna obrazovka, žádné nové zapisovací RPC. |

> Q3 je odložená, ne zodpovězená. Až se bude řešit, začíná se u věty z původního
> návrhu: **historie směn a výplat musí zůstat — jsou to peníze.**

### Otevřené, ale neblokující

| # | Otázka | Návrh do rozhodnutí |
|---|---|---|
| **Q8** | Je „preferovaný trenér" vidět jen zástupci, nebo i ostatním hráčům klubu? | **Jediná otázka, která ještě má dopad na návrh** — ale neblokuje: staví se C1 v nejmenším rozsahu (**admin, zástupce, autor rezervace**) a rozšířit jde kdykoli. Zúžit později by bylo horší. |
| **Q2** | Může být účet v `ceka` navždy? Připomínka zástupci? Automatické zamítnutí? | Blok C nechává `ceka` bez expirace. Navrhuji **připomínku ve frontě** („čeká 14 dní"), ne automatické zamítnutí. |
| **Q4** | Smí být člověk ve dvou klubech? | Schéma to umožňuje (`subject_reps` je UNIQUE na dvojici) a blok C to nijak neomezil. **Fakticky to tedy dnes jde** — otázka je, jestli to klient chce vidět v UI. |
| **Q6** | Vidí uživatel důvod zamítnutí? `subject_requests.decision_reason` existuje a plní se. | Obrazovka „Žádost byla zamítnuta" z bloku C ho **dnes nezobrazuje**. Doplnit je pár řádků. |
| **Q10** | Zabraná směna při ubrání dráhy — chce provoz notifikaci brigádníkovi? | Postavené řešení ji nechává být a rozdíl hlásí. Notifikace je nadstavba. |
| **Q11** | Série komerčních akcí: opravdu má každý termín vlastní štáb? | Nejspíš ano. U **tréninků (C2)** platí totéž a je to tam ještě zřejmější. |

---

## 8. Co tenhle plán vědomě NEŘEŠÍ

- **Kalendář dostupnosti trenérů.** R7 ho výslovně staví mimo etapu. Bez něj je
  varianta D strop — hráč vysloví přání, člověk rozhodne. Upgrade na variantu B
  je pozdější rozhodnutí, ne odložený závazek.
- **Potvrzovací dialog fakturace** (`docs/ETAPA3-POZADAVKY.md`, požadavek A).
  Souvisí přes R10/R11, ale je to vlastní kus.
- **Pevná cena klubových turnajů** (14 000 / 26 000 Kč). Rozhodnuto 31. 8. 2026,
  neimplementováno — viz `docs/ETAPA3-STAV.md` kap. 6b. S rolemi nesouvisí, ale
  čeká ve stejné frontě.
