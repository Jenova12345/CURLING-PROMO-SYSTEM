# Etapa 2 — Fakturační modul · Implementační plán

**Verze:** návrh k odsouhlasení · **Datum:** 11. 8. 2026 · **Větev:** `dev`
**Podklad:** `docs/etapa2-fakturace-spec.md` + pět nezávislých analytických bran
(datový model, bezpečnost/RLS, PDF+QR+číselná řada, idempotentní automatika, účetní správnost).

> Tenhle dokument je plán, ne hotová věc. Nic z něj zatím není naprogramované.

---

## 0. Shrnutí pro netrpělivé

- **Fakturace se nedá postavit rovnou.** Pět nálezů v existujícím kódu způsobuje, že
  akceptační kritérium „suma faktur == Kdo kolik dluží" nemůže projít, ať bude
  fakturační modul jakkoli dobrý. Musí se opravit **první** (Fáze A).
- **Bez jediné odpovědi od klienta jde postavit celý modul** včetně automatiky, PDF, QR
  a kontrolního součtu. Blokované je jen **odeslání první ostré faktury** (chybí IČO
  a bankovní účet haly) a dvě věci mimo rozsah (Google Drive, párování plateb z banky).
- **Rozsah je větší, než spec předpokládá** — hlavně kvůli DPH modelu, immutabilitě
  dokladu a serverovému renderu PDF. Odhad je v kapitole 7.

---

## 1. Prostředí — co je jinak, než se čekalo

Zjištěno průzkumem, ne ze spec. Má to přímý dopad na nasazení.

| Věc | Skutečnost |
|---|---|
| ⚠️ Kde aplikace běží | **NEOVĚŘENO — musí potvrdit PM v Netlify.** `.env.production.local` míří na `ltrazktulfxvzlvkxdsb` (curling-demo), ale to je **lokální soubor, ne důkaz o produkčním buildu**. `docs/STAV.md:28` uvádí jako potvrzené k 16. 7. 2026, že Netlify env `VITE_SUPABASE_URL` míří na `fareavttiwkamrukpfqk`; demo vzniklo až 4. 8. Dokud to někdo neuvidí v Netlify, **nevíme, nad kterou databází ostrá appka běží** |
| Stav linku Supabase CLI | **NEOVĚŘENO.** V pracovní kopii není `supabase/.temp/project-ref` (jen `linked-project.json`), takže pravděpodobně není nalinkované nic. Ověřovat jen pro čtení — `supabase projects list`, nikdy `db push --dry-run` |
| Legacy projekt `fareavttiwkamrukpfqk` | Stará Lovable DB. **Nemá vůbec** `reservations`, `subjects`, `sheets`, `settings` — jen směnový systém |
| `supabase/config.toml` | `project_id` je jen **lokální jméno Docker kontejnerů** — cíl `db push` neurčuje. (Dřív tu stál ref legacy projektu, což vedlo k mylné představě, že push míří tam.) Cílem pushe je **nalinkovaný** projekt z `supabase/.temp/project-ref` |
| Migrační historie v cloudu | **Prázdná** (`list_migrations` nevrací nic) — migrace se pouští ručně přes `scripts/build-demo-sql.sh` |
| `pg_cron`, `pg_net` | Dostupné, ale **nenainstalované** na žádném projektu |
| Supabase Storage | **Žádný bucket neexistuje** |

**Důsledek:** `scripts/build-demo-sql.sh` začíná resetem schématu. Jakmile v systému budou
ostré faktury, tenhle nasazovací postup **přestane být použitelný** — potřebuje nahradit
přírůstkovým během migrací. Řeší PR-22.

---

## 2. Pět nálezů v existujícím kódu (Fáze A)

Všechny ověřeny přímo ve zdrojích. Bez jejich opravy je fakturace postavená na písku.

### N1 — Částky se přepočítávají i po vystavení faktury
`supabase/migrations/20260731110000_booking_core.sql:420-424`

Snapshot je **jen u sazby** (`IF TG_OP = 'INSERT'`, ř. 384). Řádky s výpočtem `hours`
a `amount` jsou mimo tuhle podmínku, takže se přepočítají při **každém** UPDATE.
Admin posune vyfakturovanou rezervaci přes `move_booking` na delší slot → `amount`
se změní a faktura na ni už nesedí. Tiše, bez stopy v dokladu.

**Řeší:** plný snapshot v `invoice_items` + zámek vyfakturované rezervace (PR-8).

### N2 — Tři různé politiky zaokrouhlování
`src/hooks/useDues.ts:78` (sčítá surové) vs. `src/pages/Dues.tsx:18` (zaokrouhlí až součet)
vs. `src/lib/invoiceDraft.ts:60` (sčítá zaokrouhlené řádky).

Tři rezervace po sazbě 1 250,50 Kč/h: obrazovka **3 752 Kč**, podklad k fakturaci
**3 753 Kč**. Akceptační kritérium neprojde už dnes, samo se sebou.

**Řeší:** PR-1.

### N3 — Tištěná sazba nesedí na tištěný řádek
`src/pages/Dues.tsx:64` počítá `rate = částka / hodiny`, `invoiceDraft.ts:86` ji tiskne
zaokrouhlenou. Při 1 250,50 Kč/h a 2 h vyjde `Sazba 1 251 Kč × 2 h = 2 501 Kč`.
Řádek si neodpovídá sám se sebou.

Dopočet navíc není potřeba: `corrected_amount` je vždy `round(corrected_hours × rate_per_hour, 2)`,
takže `rate_per_hour` sedí i po korekci.

**Řeší:** PR-1.

### N4 — Pod automatikou vrátí `reservations_billing` nula řádků
`supabase/migrations/20260804090000_group_actions_and_billing.sql:180`

View končí `AND has_role(auth.uid(), 'admin')`. V cronu (i pod `service_role`) je
`auth.uid()` **NULL** → `has_role(NULL,'admin')` je false → **view nevrátí nic**.
Fakturační běh by tiše nevystavil nic, ohlásil úspěch a kontrolní součet by seděl
nula proti nule.

**Řeší:** běh čte základní tabulky, ne view (PR-9). View zůstává tím, čím je —
podkladem pro adminskou obrazovku.

### N5 — Guard trigger odmítne servisní zápis dřív, než se zeptá na důvěru
`supabase/migrations/20260731110000_booking_core.sql:64-81`

Pořadí kontrol: `postgres` → **`authenticator` → RAISE** → `app.trusted_booking`.
Kontrola `authenticator` vystřelí **dřív**, než se ke slovu dostane GUC. Fakturační
běh volaný přes Edge funkci se `service_role` klíčem tedy do rezervací nezapíše,
ani kdyby si GUC správně nastavil.

Pod `pg_cron` (`session_user = 'postgres'`) problém **není** — což je další argument
pro pg_cron. Prohození pořadí je nutné jen pro záložní cestu (PR-17b), a protože
uvolňuje bezpečnostní kontrolu, musí projít bezpečnostní bránou.

**Vedlejší nález (nižší priorita):** `reservations_billing` nefiltruje `approved_at`
a nevylučuje údržbu se subjektem. Přes `create_booking` údržba subjekt dostat nemůže
(`booking_api.sql:322-324` to odmítá), takže jde o obranu do hloubky, ne o aktivní chybu.
Filtr `approved_at` je ale **produktové rozhodnutí** — viz otázka Q4.

---

## 3. Rozhodnutí (technická, udělaná)

### R1 — Vazba rezervace ↔ faktura: obojí, s ostře oddělenou rolí

Brány se rozešly 2:2. Rozhodnutí:

- **`invoice_items.reservation_id`** = pravda a historie. Účetní invariant se počítá
  **odsud**: rezervace je k fakturaci, právě když `Σ line_total(r) ≠ částka(r)`.
- **`reservations.invoice_id`** = **zámek** proti souběhu. Umožňuje atomický claim
  (`UPDATE … WHERE invoice_id IS NULL RETURNING`), takže dva souběžné běhy nemohou
  jednu rezervaci vyfakturovat dvakrát.

Proč ne jen `invoice_items`: částečný unikátní index nad ní **nemůže** v `WHERE` sáhnout
na `invoices.status`, takže by potřeboval denormalizovaný sloupec + synchronizační
trigger — a jeho rozejití je tichá dvojí fakturace.

Proč ne jen `invoice_id`: jednohodnotový sloupec neunese částečný dobropis (rezervace
pak figuruje na faktuře i na dobropisu zároveň).

**Pravidlo pro částečný dobropis:** `invoice_id` se **neuvolňuje**. Zbytek se dofakturuje
výhradně ručně („doplňková faktura"), nikdy automatikou. Automatická cesta tak nikdy
nemůže znovu naúčtovat něco, co je částečně dobropisované. Plné storno a plný dobropis
`invoice_id` uvolňují.

**Autoritou pro „sedí to" je `billing_reconcile`, ne `invoice_id`.**

### R2 — DPH jako enum, ne boolean

Ne `is_vat_payer boolean`, ale **`vat_mode enum('neplatce','identifikovana_osoba','platce')`**,
a pole `vat_rate` / `vat_base` / `vat_amount` / `vat_exempt_reason` **na řádku**, ne globálně na faktuře.

Důvody: identifikovaná osoba **má DIČ, ale v tuzemsku fakturuje bez DPH** (§ 6g–6l ZDPH);
pronájem sportovišť má pravděpodobně sníženou sazbu, ne 21 %; a pokud halu provozuje
spolek, mohou být klubové tréninky osvobozené (§ 61 písm. d) ZDPH), zatímco komerční akce
zdanitelné — tedy **dva režimy na jedné hale**.

Postavit takhle hned = přechod na plátce je konfigurace. Postavit jako boolean = přepis modulu.
**Toto je nejdražší chyba, které se dá teď zadarmo vyhnout.**

### R3 — Stupňovitá kvantizace: jedno kanonické pravidlo pro obě strany

> Upřesněno 12. 8. 2026 (PR A1d). Původní znění říkalo „zaokrouhlení jednou, na konci",
> což šlo číst dvěma způsoby — a implementace se podle toho taky rozešly. Rozhodnutí PM:
> **kanonické je stupňovité (staged) pravidlo**, protože jediné přežije přechod na plátce
> DPH. Zapsáno takhle podrobně schválně: tichý rozdíl mezi jednokrokovou a dvoukrokovou
> cestou je přesně ten druh chyby, který se u peněz dědí roky.

**Pravidlo.** Každá peněžní veličina se kvantizuje **na haléře ve své vlastní fázi**,
půlka nahoru v absolutní hodnotě. Na celé koruny se zaokrouhluje **jen jednou, a to
z hodnoty, která už kvantizací prošla** — nikdy ze surové.

| # | Veličina | Přesnost | Výpočet |
|---|---|---|---|
| — | sazba (jednotková cena) | 2 des. místa | `rate_per_hour`, **nikdy** se nedopočítává z částky |
| 1 | `invoice_items.line_total` | 2 des. místa | `round(hodiny × sazba, 2)` |
| 2 | `invoices.subtotal` | 2 des. místa | `SUM(line_total)` — přesný součet už kvantizovaných řádků |
| 3 | `invoice_items.vat_base` / `vat_amount` | 2 des. místa | každé zvlášť `round(…, 2)`; daň se počítá z kvantizovaného základu — **agregace viz Q7** |
| 4 | `invoices.total` | 2 des. místa | `subtotal + Σ vat_amount` — **veličina pro kontrolní součet** |
| 5 | `invoices.total_rounded` | celé Kč | `round(round(total, 2), 0)` — **zákazník platí tohle, tohle je v QR** |
| 6 | `invoices.rounding_amount` | 2 des. místa | `total_rounded − total`; tiskne se vlastním řádkem a **stojí mimo základ daně** |

Řádek 5 je schválně zapsaný v kanonické formě, i když je vnější `round` nad dvoudesetinným
`total` no-op. Implementátor si opisuje tabulku, ne prózu pod ní — a právě ten implicitní
úsudek („vždyť je to dvoudesetinné, tak stačí `round(total, 0)`") je důvod, proč tenhle PR vznikl.

**Kanonický zápis:** `částka k úhradě = round(round(v, 2), 0)`, **ne** `round(v, 0)`.
Rozdíl je vidět na 0,495 → stupňovitě 1 Kč, jednorázově 0 Kč. Na vzorku ze skriptu
`scripts/overit-zaokrouhleni.ts` se obě cesty liší ve **140 z 25 718** hodnot (0,54 %),
takže nejde o kosmetiku. Čísla se dají kdykoli přeměřit: `npm run overit:zaokrouhleni`.

**Proč stupňovitě, a ne jednorázově:**

1. **Účetní důvod (rozhodující).** Základ daně musí být určité dvoudesetinné číslo, ze
   kterého se daň počítá a které se tiskne — není to mezivýsledek, který se smí přeskočit.
   Jednorázové zaokrouhlení ze surové hodnoty by po registraci k DPH počítalo daň z čísla,
   které na dokladu nikde nestojí.
2. **Doklad musí sedět sám se sebou.** Částka k úhradě se odvozuje z **vytištěného**
   mezisoučtu. Kdyby se zaokrouhlovalo ze surové hodnoty, mohl by doklad ukázat
   „Mezisoučet 1 250,50 Kč" a hned pod tím „K úhradě 1 250 Kč".
3. **Zaokrouhlení po řádcích je pořád zakázané.** Stupňovitost znamená kvantizaci na
   haléře, ne zaokrouhlování řádků na celé koruny — to by základ daně zkreslilo.

**Kontrolní součet** porovnává **`total`**, ne `total_rounded` — jinak by se drift
z per-fakturového zaokrouhlení nasčítal. Meze jsou **dvě a je potřeba je nezaměnit:**

| Proti čemu se měří | Mez na doklad | Pro N dokladů |
|---|---|---|
| kvantizovanému `total` (**tudy jde kontrolní součet**) | 0,50 Kč | ±N/2 |
| surové hodnotě s víc než 2 des. místy | 0,505 Kč | ±0,505·N |

Těch 0,005 navíc je cena za stupňovitost: `k+0,495` se přes haléře vytáhne až na `k+1`.
Jednorázové pravidlo by v téhle metrice mělo mez rovných 0,500 — stupňovité je tedy
o 5 haléřů horší **v metrice, na které nezáleží**, a správné v té, na které záleží.
Do kontrolního součtu se to nepromítá, protože ten jede přes už kvantizované `total`.
Teoretické meze výše nejsou totéž co naměřená hodnota — na fixtuře v `money.test.ts`
(40 dokladů) vychází drift **12,20 Kč** proti mezi 20 Kč.

**Kde `roundCzk` je a kde není.** Volá ho **jediné místo**: `src/lib/invoiceDraft.ts`,
tedy generátor dokladu. `useDues` a `Dues.tsx` na celé koruny nezaokrouhlují vůbec
a je to tak správně — „Kdo kolik dluží" má ukazovat přesnou dvoudesetinnou částku.
**Důsledek: `roundCzk` neleží na cestě kontrolního součtu**, takže změna pravidla
zaokrouhlení na celé koruny akceptační kritérium Etapy 2 ohrozit nemůže.

**Shoda obou stran je ověřená, ne tvrzená.** `scripts/overit-zaokrouhleni.ts` porovnává
`src/lib/money.ts` proti živému Postgresu: 25 718 hodnot (celý rozsah po haléři, hranice
`.xx5`, čtyři desetinná místa, `základ × 0,21`, záporné protějšky) — **0 rozdílů**.
Pozn.: SQL strana zatím neexistuje (tabulka `invoices` není v migracích) — `round(round(v, 2), 0)`
je pro ni **závazné zadání**, ne popis stavu. Testy drží obě strany: `src/lib/money.test.ts`
(nezávislá reference v `BigInt` nad desetinným zápisem, ne přes `money.ts`)
a `supabase/tests/zaokrouhleni_test.sql`.

**Tři pasti, všechny už zaplacené:**
- `Math.round(-1250.5) === -1250` v JS, ale `round(-1250.5) = -1251` v Postgresu.
  `roundCzk` proto musí být `sign(x) · round(abs(x))`.
- Zápornou nulu nesmí zabíjet `|| 0` — je to pravdivostní test, takže spolkne i `NaN`
  a vyrobí doklad „K úhradě 0 Kč". Správně je `+ 0`.
- **Mez přesnosti `toSetiny` stojí korunu, ne haléř.** `roundCzk` prochází fází 1,
  takže se limit 15 platných číslic promítá až do částky k úhradě
  (`1.4949999999999999` → 2 Kč místo 1 Kč). Nedosažitelné to je jen díky tomu, že
  zdroj je `numeric(x,2)`. **Tatáž záruka musí platit i pro `invoices.total`** — jakmile
  by do něj šla hodnota s 16+ platnými číslicemi, je to koruna rozdílu proti dokladu.

**Navíc u zdroje** (aby zaokrouhlení skoro nikdy nemuselo nic dělat): sazby v celých
korunách (validace + CHECK), `corrected_hours` na čtvrthodiny a nezáporné.

**Otevřeno pro B2 — bez rozhodnutí se tabulka `invoices` psát nemá.** Kanonické pravidlo
řeší poslední fázi, ne agregaci DPH. Ta je vlastní otázka a **rozhoduje o odvedené dani**,
takže patří účetní klienta, ne nám — viz Q7 v kapitole 6.

### R11 — Každá SECURITY DEFINER funkce nad `billing_settings` musí dusit chyby constraintů

> Doplněno 12. 8. 2026 (bezpečnostní brána A3). **Není to dnes zneužitelné — je to past,
> kterou si A3 sama nastražila na fázi B.**

Uvnitř `SECURITY DEFINER` funkce neplatí RLS, takže je řádek viditelný a Postgres při
porušení CHECKu vysype jeho obsah do `DETAIL`. PostgREST ten DETAIL u **RPC** přeposílá
klientovi. Ověřeno útokem: člen, který z přímého `SELECT` dostane `[]`, dostal z RPC

```
"details": "Failing row contains (…, 27074358, CZ27074358, 192000145399/0800,
            CZ6508000000192000145399, …)"
```

tedy **IBAN, číslo účtu, IČO i DIČ**. Dnes na `billing_settings` žádná taková funkce
nesahá — ale A3 v hlavičce sama plánuje, že kontrola úplnosti údajů bude „ve funkci,
která doklad vystavuje (fáze B)". Jakmile ji B1/B2 přidá, díra se otevře sama.

**Pravidlo pro B:** každá `SECURITY DEFINER` funkce sahající na `billing_settings`
(a) začne kontrolou `has_role(auth.uid(), 'admin')` a (b) odchytí porušení constraintů:

```sql
EXCEPTION WHEN check_violation OR unique_violation THEN
  RAISE EXCEPTION 'Neplatná hodnota fakturačního nastavení.' USING ERRCODE = '22023';
```

Je to táž třída jako nález 8b v `SCHEMA_DRIFT` (RPC nad `reservations`), který řeší A5.

### R4 — PDF serverově, `pdf-lib` v Edge funkci

Headless Chromium v Supabase Edge Functions **není** a spouštět podprocesy nejde →
Puppeteer je vyloučený. Klientské generování je vyloučené taky, protože automatika
musí umět vystavit doklad, když nikdo nesedí u počítače.

`pdf-lib` + `@pdf-lib/fontkit` + předsubsetovaný Noto Sans (~35 kB) jako base64 modul.
**Nula nových npm závislostí ve frontendu.** Cena: ruční layout, odhadem 350–450 řádků.

Limit 2 s CPU na požadavek → **render je fronta, ne dávka** (`pdf_status: pending →
generating → ready`), přesně podle vzoru `email_outbox`, který v repu už je.

### R5 — Pořadí operací při vystavení

```
1. přidělit číslo (atomicky, v transakci)   ← invoice_counter, NE sekvence
2. commit                                    ← faktura teď existuje a je vystavená
3. render PDF                                ← smí selhat
4. upload do Storage
5. zapsat cestu + sha256
```

Číslo je **vytištěné v PDF**, takže nemůže vzniknout až po renderu. A protože je
přidělené řádku, který v DB zůstane, selhání kroků 3–5 **nedělá díru v řadě, dělá frontu**.
Faktura bez PDF je platný doklad se štítkem „PDF se generuje".

**Sekvence jsou vyloučené** — `nextval` je netransakční, rollback číslo nevrátí a v řadě
vznikne díra, kterou spec zakazuje.

### R6 — Plánovač: pg_cron, hodinový tik

Fakturační běh je čistý SQL zápis — HTTP nepotřebuje, takže `pg_net` není nutný.
Pod `pg_cron` běží jako `postgres`, čímž **obchází celý problém N5** a nepotřebuje
žádný servisní klíč navíc.

Rozvrh je **hodinový tik `7 * * * *`**, ne „poslední den ve 2:00" — pg_cron vyhodnocuje
výrazy v UTC a přes letní/zimní čas by to ujelo. Rozhodnutí „má se něco stát?" dělá
sama funkce podle pražského času. Bonus: automatický dohon po výpadku a levný „mrtvý muž".

Vypínač je v datech (`billing_settings.automation_enabled`, default `false`), ne v migraci —
plánovač se dá nasadit a **týdny sledovat, jestli tiká, dřív než smí cokoli vystavit**.

Záloha: Netlify Scheduled Function volající tutéž RPC (pak je nutná oprava N5).

### R7 — Storage: privátní bucket, strojový klíč, hezký název až při stažení

Klíč objektu `invoices/{rok}/{číslo}/v{n}.pdf` — ASCII, bez identity, bez diakritiky.
Lidský název (`001_hybridni_curling_220826.pdf`) se nastaví až v parametru `download`
podepsané URL s platností ≤ 5 minut.

Tím zmizí únik identity přes cestu, diakritika v klíči i kolize názvů naráz. Pořadové
číslo v názvu se **odvozuje z čísla faktury** (poslední 4 číslice), takže nevznikají
dvě nezávislé číslovací soustavy.

### R8 — Immutabilita platí i pro admina

Guard na `invoices` **nesmí** začínat `IF has_role(auth.uid(),'admin') THEN RETURN NEW`,
jak to (správně) dělá guard u rezervací. U vystaveného dokladu je neměnnost zákonná,
ne provozní. Whitelist povoluje jen `status`, platební a PDF sloupce; `DELETE` je zakázaný
úplně. Úniková cesta pro opravné migrace je jmenovitý auditovaný GUC `app.invoice_repair`.

Druhá vrstva: `invoices` a `invoice_items` nemají **žádnou** INSERT/UPDATE/DELETE RLS
politiku — veškerý zápis jde přes SECURITY DEFINER RPC. `PATCH /rest/v1/invoices` skončí
na `permission denied` bez ohledu na roli.

### R9 — `billing_settings` je samostatná tabulka

**Nikdy ne sloupce v `public.settings`.** Ta má `settings_select … USING (true)`
(`etapa1_rls.sql:85`), takže celý řádek čte **každý přihlášený**. Přidat tam IBAN nebo
IČO dodavatele by znamenalo zveřejnit bankovní účet každému uživateli.

### R10 — `verify_jwt = true` není autorizace

Anon klíč je veřejný a je to platný JWT. Každá fakturační Edge funkce si musí uvnitř
ověřit uživatele **jeho vlastním tokenem** a roli admin. Potvrdily nezávisle dvě brány.

---

## 4. Plán po krocích

Legenda bran: **CR** = code review · **SEC** = bezpečnost/RLS · **DB** = kontrola migrací.
Podle pravidla Etapy 2 v `CLAUDE.md` neprojde nic bez svých bran.

### Fáze A — Zpevnění základu (nefakturuje, ale bez toho nic nesedí)

| PR | Obsah | Migrace | Riziko | Brány |
|---|---|---|---|---|
| **A1** | Jednotné zaokrouhlování: sdílený `roundCzk()`, `useDues` bere `rate_per_hour` místo dopočtu, `Dues.tsx` i `invoiceDraft.ts` na stejné pravidlo. Řeší **N2 + N3** | ne | nízké | CR |
| **A2** | CHECK na `corrected_hours` (nezáporné, čtvrthodiny) + sazby v celých Kč (`settings`, `subjects.default_rate`) + validace ve formuláři | ano, malá | nízké — může narazit na existující data, migrace to musí ohlásit, ne opravit | CR, DB |
| **A3** | `billing_settings` (singleton, vše NULLABLE), RLS **admin-only na SELECT i UPDATE**, audit trigger, `set_updated_fields` | ano | nízké | CR, SEC, DB |
| **A4** | UI Nastavení → Fakturace: formulář, dopočet IBANu z českého čísla účtu (mod-11 + mod-97) s **povinným potvrzením adminem**, náhled | ne | nízké | CR |
| **A5** | **Bezpečnostní zpevnění — MUSÍ být hotové, než B1 sáhne na peněžní tabulky.** (1) `EXCEPTION WHEN check_violation` ve všech SECURITY DEFINER RPC — bez něj posílá PostgREST klientovi `Failing row contains` i s částkou; (2) `deleted_at IS NULL` do politiky `reservations_update`; (3) horní mez `corrected_hours` — **tvrdý strop 24 h** (rozhodnutí PM 12. 8. 2026, NEvázat na délku rezervace) + povinný `correction_reason`; (4) `REVOKE TRUNCATE, DELETE` od anon/authenticated na peněžních tabulkách; (5) **citlivá pole `profiles` jen vlastník + admin** — dnes si člen přes REST přečte cizí bankovní účty brigádníků (drift 8f), projít stejnou logikou i telefon a další citlivá pole | ano | střední | CR, SEC, DB |

> **Fáze A se za pochodu rozrostla** o PR, které plán původně neměl. Pro dohledatelnost:
> **A1b** (SQL testy zaokrouhlení proti živému Postgresu), **A1c** (Vitest + `money.test.ts`),
> **A1d** (sjednocení R3 na stupňovitou kvantizaci), **A2b** (ceník a sazby subjektů jen
> adminovi — dodržení klientova „částku vidí admin a autor"), **A5** (výše).
> Nálezy, které do A5 patří, jsou rozepsané v `docs/SCHEMA_DRIFT.md`, kapitola 8.

> A4 je místo, kde se od klienta poprvé sbírají reálné údaje — ale formulář se dá
> postavit a otestovat prázdný.

### Fáze B — Doklad

| PR | Obsah | Migrace | Riziko | Brány |
|---|---|---|---|---|
| **B1** | `invoice_counter` + `next_invoice_number()` (upsert `RETURNING`) + `invoice_series_for()` + `set_invoice_counter()` pro navázání na ručně vystavené doklady. RLS **bez jediné politiky** | ano | nízké | CR, SEC, DB |
| **B2** | Enumy (`invoice_status`, `invoice_doc_type`, `invoice_kind`; **`vat_mode` už existuje — založila ho A3, nezakládat znovu**), `invoices`, `invoice_items`, indexy, CHECKy, audit + updated triggery, RLS v **téže** migraci | ano | nízké | CR, SEC, DB |
| **B3** | Immutability guardy (faktura i položky) + `recalc_invoice_totals()` | ano | střední — logika stavového automatu | CR, SEC, DB |
| **B4** | `reservations.invoice_id` + `invoiced_at`, 2 indexy, **doplnění INSERT větve guardu** (`NEW.invoice_id := NULL`), `guard_invoiced_reservation` jako `trg_reservations_z_invoiced` | ano | **vysoké — jediná migrace sahající na živou tabulku** | CR, SEC, DB |
| **B5** | RPC: `create_invoice_draft_commercial/club`, `issue_invoice`, `mark_invoice_paid`, `cancel_invoice`, `create_credit_note`, `delete_invoice_draft` + view `invoices_list` (`security_invoker = on`) | ano | střední | CR, SEC, DB |
| **B6** | `billing_reconcile()` + `billing_health` view + `supabase/tests/fakturace_test.sql` ve stylu `rezervace_test.sql` | ano | nízké | CR, DB |

> **B4 vyžaduje zvláštní pozornost.** `ADD COLUMN` bez DEFAULT je jen metadata, ale
> `CREATE OR REPLACE` guard funkce se projeví okamžitě pro všechny běžící sessions —
> musí být v **jedné transakci** s `ADD COLUMN`, jinak vzniká okno, kdy sloupec existuje
> a INSERT větev ho nevynuluje. Revert `DROP COLUMN` = ztráta zámků „už fakturováno".

> **B6 musí přijít hned po B5, ne až nakonec.** Bez kontrolního součtu nemá smysl
> pouštět nic dalšího — je to jediný způsob, jak poznat, že modul počítá správně.

### Fáze C — PDF a QR

| PR | Obsah | Migrace | Riziko | Brány |
|---|---|---|---|---|
| **C1** | Privátní bucket `invoices` (idempotentně) + RLS na `storage.objects` + `[storage.buckets.invoices]` v `config.toml` | ano | nízké | CR, SEC, DB |
| **C2** | Moduly `spayd.ts` + `iban.ts` (parser, mod-11, mod-97) + jednotkové testy. Čistý kód, žádná DB | ne | nízké | CR |
| **C3** | Subset fontu (skript `scripts/build-font-module.mjs`) + generovaný base64 modul | ne | nízké | CR |
| **C4** | Edge funkce `invoice-pdf`: DTO ze snapshotu, dvě větve DPH, deterministický render, QR jako SVG path, upload, sha256 | ne | **vysoké — nejvíc nového kódu** | CR, SEC |
| **C5** | Fronta `pdf_status` + worker s atomickým claimem + retry (5 pokusů) + UI štítek „PDF se generuje / selhalo" | ano | střední | CR, SEC, DB |

> **Test proti nejdražší chybě:** vyrenderovat neplátcovskou fakturu, vytáhnout z PDF
> text a assertovat, že neobsahuje `/DPH|zdanitel|daňov/i`. Neplátce, který na dokladu
> vyčíslí daň, ji musí odvést (§ 108 ZDPH).
>
> **Test determinismu:** `renderInvoice(fixture)` 2× → shodný sha256. Verze `pdf-lib`
> připnutá přesně, ne `^`.

### Fáze D — Automatika

| PR | Obsah | Migrace | Riziko | Brány |
|---|---|---|---|---|
| **D1** | `billing_job_runs` + `billing_job_run_items` + RLS admin-only | ano | nízké | CR, SEC, DB |
| **D2** | `billing_tick()` / `billing_run_daily()` / `billing_run_monthly()` — čtou **základní tabulky** (N4), pražské hranice období, subtransakce na fakturu, přeskočení subjektu bez IČO **bez zabrání rezervací** | ano | vysoké | CR, SEC, DB |
| **D3** | `CREATE EXTENSION pg_cron` + `cron.schedule('billing-tick', '7 * * * *')` + úklid `cron.job_run_details` | ano | **vyžaduje souhlas PM + zálohu** | SEC, DB |
| **D4** | UI panel „Fakturace → Automatika": poslední běh, mrtvý muž, „K vyřešení", ruční spuštění, dry-run, backfill s dvoukrokovým potvrzením | ne | střední | CR |

> **Režim náběhu:** `billing_settings.auto_issue = false`. První měsíc automat vytváří
> jen **koncepty**, admin je po kontrole vystaví jedním klikem. Koncepty se do kontrolního
> součtu nezapočítávají, takže se nic nerozbije. Teprve po měsíci bez rozdílů se přepne.

### Fáze E — UI a dokončení

| PR | Obsah | Migrace | Riziko | Brány |
|---|---|---|---|---|
| **E1** | Stránka Faktury: seznam, filtry, detail, stažení, storno, dobropis, označit zaplaceno | ne | střední | CR |
| **E2** | `invoice_payments` (tabulka, ne dvě pole) — částečné úhrady, přeplatky, odvozený stav | ano | střední | CR, SEC, DB |
| **E3** | Měsíční ZIP export v Edge funkci (`fflate`, `level: 0`) | ne | nízké | CR, SEC |
| **E4** | Kalendář českých svátků + `due_date_effective` (§ 607 ObčZ — splatnost padající na víkend se posouvá) | ano | nízké | CR, DB |
| **E5** | CSP a bezpečnostní hlavičky v `netlify.toml`, zúžení CORS u Edge funkcí | ne | nízké | CR, SEC |
| **E6** | Nahrazení `scripts/build-demo-sql.sh` přírůstkovým nasazením (reset schématu přestane být použitelný, jakmile budou ostré faktury) | ne | střední | CR, DB |

---

## 5. Co jde hned vs. co čeká

### Postavíme bez jediné odpovědi klienta

Celé fáze A–E. Všechny „jak často / kdy / jak se to jmenuje" odpovědi jsou v návrhu
**hodnoty v `billing_settings`**, ne kód — odpověď klienta bude `UPDATE`, ne nová migrace.

Defaulty podle zadání: neplátce DPH, splatnost 14 dní, číslo `20260001`, prefix `curling`,
jedna společná řada, ruční evidence plateb, bez kopie do Drive.

### Blokuje odeslání první ostré faktury (ne vývoj)

| # | Co | Proč to nejde vymyslet |
|---|---|---|
| **B1** | Přesný název, právní forma, sídlo, IČO a **údaj o zápisu do rejstříku** (soud, oddíl, vložka) | § 435 ObčZ. Právní forma navíc rozhoduje o možném osvobození sportovních služeb |
| **B2** | Číslo účtu / IBAN | Není kam platit ani z čeho generovat QR |

### Mimo rozsah Etapy 2 (jak zadáno)

- kopie faktur do Google Drive
- párování plateb z bankovního výpisu

### Otázky pro účetní klienta (ne pro Jakuba)

1. Je pronájem ledu službou se sníženou sazbou podle přílohy č. 2 ZDPH? Liší se to
   u komerčního teambuildingu?
2. Pokud halu provozuje spolek — uplatní se osvobození podle § 61 písm. d) ZDPH
   na klubové tréninky? (Znamenalo by **dva daňové režimy na jedné hale**.)
3. Dobropis: záporné částky, nebo kladné s označením? Stejná řada, nebo vlastní?
4. Označení opravného dokladu u neplátce: „Opravný doklad", nebo „Dobropis"?
4b. **Počítá se DPH po řádcích, nebo z mezisoučtu za sazbu?** (viz Q7 — měřitelný
   rozdíl v odvedené dani, potřebujeme jednu závaznou odpověď)
5. Existuje s kluby písemná smlouva o pronájmu ledu? Bez ní je souhrnná měsíční faktura
   po registraci k DPH problém (§ 21 odst. 4 písm. b) — dílčí plnění).

> Paragrafy uvádí analytická brána jako vodítko pro účetní, ne jako právní stanovisko.
> Přesná znění a čísla odstavců ať potvrdí ona.

---

## 6. Otázky, které potřebuji rozhodnout před kódem

| # | Otázka | Doporučení |
|---|---|---|
| **Q1** ✅ | **ROZHODNUTO PM 12. 8. 2026, zavedeno v A3: 1. den následujícího v 06:00** (`billing_settings.monthly_run_day = 1`, `monthly_run_hour = 6`). Klientova původní varianta „poslední den" zůstala vyjádřitelná jako `monthly_run_day = 0`, takže návrat k ní je UPDATE, ne migrace. Původní znění otázky: **Měsíční běh: poslední den, nebo 1. den následujícího?** Zadání říká poslední den, ale běh 31. 8. ve 2:00 **nezachytí rezervace z 31. srpna večer**. Dvě brány nezávisle doporučily 1. den následujícího | **1. den následujícího v 06:00.** Je to hodnota v `billing_settings`, takže změna je jednořádková — ale default by měl být ten, který neztrácí data |
| **Q2** | **Instalovat `pg_cron`** na projekt `curling-demo`? Je to zásah do DB → podle CLAUDE.md záloha + souhlas PM | Ano. Alternativa (Netlify/GitHub Actions) přidává servisní klíč mimo Supabase a vyžaduje navíc opravu N5 |
| **Q3** | **Účtuje hala storno poplatky? Dává slevy?** Obojí je teď jedno slovo ve schématu (`reservation_id` nullable, slevový řádek), potom migrace nad ostrými daty | Připravit obojí i při odpovědi „ne" — je to zadarmo |
| **Q4** ✅ | **ROZHODNUTO PM 12. 8. 2026, zavedeno v A3: fakturují se JEN schválené** (`billing_settings.invoice_only_approved = true`). Pozor, je to OPAK doporučení níže — to zůstává jen jako zápis úvahy. Původní znění otázky: **Fakturují se nepotvrzené rezervace členů?** Dnes do „Kdo dluží" spadnou. Drží led, takže logika pro fakturaci je — ale klub dostane fakturu za něco, co jeho zástupce neschválil | Fakturovat, ale na obrazovce rozlišit. **Jediná defaultovaná otázka, kde špatná odpověď znamená chybně vystavené doklady** — zeptat se dřív než na ostatní |
| **Q5** | **Význam „hybridní" v názvu souboru** (`001_hybridní_curling_220826`) | Nejspíš `{pořadí}_{název akce}_{datum}`, kde „hybridní curling" je jeden dvouslovný **název akce** (je to reálná varianta hry) a `curling` je jen fallback. Stojí za to se zeptat přesně takhle |
| **Q6** | **Formát čísla faktury musí dát ≤ 10 číslic** (limit variabilního symbolu) a být jednoznačný napříč řadami | `RRRRNNNN` vyhovuje. Kdyby klient chtěl oddělené řady, navrhnout `RRRR{1\|2}NNN` — 8 číslic, jednoznačné |
| **Q7** | **Agreguje se DPH po řádcích, nebo z mezisoučtu za sazbu?** Kanonické pravidlo R3 řeší poslední fázi, tuhle otázku ne — a přitom **rozhoduje o odvedené dani**. Změřeno na 40 000 modelových dokladech po 8 řádcích: obě varianty se liší u **54,5 %** dokladů (až 0,03 Kč na dani) a u **0,6 %** se liší i částka k úhradě o celou korunu | **Rozhodnout před B2, ať se to nemusí migrovat nad ostrými doklady.** Doporučení k potvrzení účetní: daň počítat **z agregovaného základu za každou sazbu zvlášť** (`vat_amount = round(Σ vat_base za sazbu × sazba, 2)`), s invariantem `Σ vat_base = subtotal`. Rekapitulace po sazbách je náležitost daňového dokladu, takže rozpad podle sazeb potřebujeme tak jako tak — a R2 počítá s **dvěma režimy na jedné hale**. `rounding_amount` stojí **mimo základ daně** |

> **Q7 není technické rozhodnutí.** Nesmí ho udělat CC ani PM od stolu — ať ho potvrdí
> účetní klienta. Do té doby je `invoices` blokovaná: jednou vystavené doklady se
> přepočítat nedají.

---

## 7. Rizika

| # | Riziko | Dopad | Mitigace |
|---|---|---|---|
| 1 | Vystavení právně vadného nebo duplicitního dokladu | právní následky, ztráta důvěry | koncepty první měsíc; unikátní indexy; counter místo sekvence; kontrolní součet po každém běhu |
| 2 | Neplátce s vyčíslenou DPH v šabloně | **povinnost odvést uvedenou daň** | oddělená větev v kódu + automatický test na absenci slov `DPH/daňov/zdanitel` |
| 3 | Běh tiše nevystaví nic (N4) | celý měsíc nevyfakturovaný | běh čte základní tabulky; test „pod rolí postgres najde N rezervací" |
| 4 | Špatný IBAN → QR posílá peníze jinam | zjistí se po týdnech | mod-11 validace + **povinné potvrzení dopočteného IBANu** + testovací sken |
| 5 | Změna `billing_settings` přepíše historii | staré faktury ukazují nové údaje | snapshot dodavatele na faktuře; `BRAND.billing` z fakturační cesty odstranit |
| 6 | Běh vůbec neproběhne (pauza projektu, restore) | zjištěno pozdě | mrtvý muž: `last_tick_at` + počet nevyfakturovaných starých rezervací, vyhodnocení **mimo** DB |
| 7 | `supabase db push` proti nesprávné databázi | migrace na cizí DB | zákaz CLI proti živé DB bez souhlasu PM + **read-only ověření stavu linku** (`supabase projects list`, `cat supabase/.temp/linked-project.json` — soubor `project-ref` tenhle CLI nezakládá) před každým zásahem. Pozor: editace `project_id` v `config.toml` riziko **nesnižuje** — cíl pushe se odtud nebere |
| 8 | Zálohy PDF | `pg_dump` bucket neobsahuje → doklady bez souborů | samostatná záloha Storage **musí být vyřešená, ne odložená** |
| 9 | `pdf-lib` je od 2021 zamrzlý | automatika stojí při změně Dena | verze připnutá přesně, smoke test v CI, fork `@cantoo/pdf-lib` jako připravená úniková cesta |

---

## 8. Odhad rozsahu

Spec počítá jádro na 20 000–30 000 Kč. Analýza ukázala tři věci, které tam nejsou započítané:

1. **Fáze A** — opravy existujícího základu (bez nich neprojde akceptační kritérium).
2. **DPH model podle R2** — dražší teď, ale řádově levnější než přepis po registraci k DPH.
3. **Serverový render PDF** — spec předpokládala, že „PDF se nějak vygeneruje";
   ve skutečnosti to je ruční layout, protože headless prohlížeč v Edge Functions není.

Fáze A–B + E1 je minimum, které umí vystavit právně korektní doklad ručně.
Fáze C přidá PDF a QR, fáze D automatiku. **Doporučuji nasazovat v tomhle pořadí** —
ruční vystavení pokryje provoz od prvního dne a automatika se pak zapíná do systému,
který už je ověřený na reálných dokladech.
