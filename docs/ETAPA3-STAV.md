# Etapa 3 — Fakturoid · STAV

**Aktualizováno:** 24. 8. 2026 · **Větev:** `main`

> **Nepushnuto.** Commity leží lokálně, push a merge zůstávají na vyžádání
> (pravidlo repa). Frontend se z GitHubu nasazuje sám, takže push je rozhodnutí,
> ne rutina.

Předávací dokument. Kdo přebírá práci, ať čte tohle první — pak
`billing/README.md` (pravidla vrstvy) a `docs/ETAPA2-STAV.md` (interní fakturace,
kterou tahle etapa nahrazuje).

---

## 0. Kam to celé míří

**Ostrý doklad vystavuje Fakturoid, ne my.** Náš systém do něj posílá jen
podklady z rezervací. Číselná řada, PDF, QR platba, DPH režim, storno i evidence
úhrad jsou od téhle chvíle věc Fakturoidu.

Rozhraní je **provider-agnostické**: iDoklad nebo cokoli dalšího přibude jako
nová implementace `InvoiceProvider`, aniž se sáhne na jádro.

---

## 1. Rozhodnutí PM — platná, nepřerozhodovat

| Věc | Rozhodnutí | Kdy |
|---|---|---|
| **S2, ne S1** | Fakturoid vystavuje ostrý doklad. Interní engine (`invoice_counter`, PDF, QR, storno) se na ostré doklady **přestává používat**, zůstává max. jako interní přehled. | 24. 8. 2026 |
| **Vyřazení interního enginu** | Samostatný **pozdější ticket**. Na existující fakturaci a na guard `app.trusted_booking` se teď NESAHÁ. | 24. 8. 2026 |
| **Zámek 1 pod S2** | Ptá se **výhradně** na vazbu k provideru (`fakturoid_invoices`), nezávisle na `reservations.invoice_id`. Rezervace může mít interní doklad a **stejně jde do Fakturoidu**. | 24. 8. 2026 |
| **Fakturoid path nepíše do `reservations`** | Vůbec nic. Tím odpadá konflikt s guardem. | 24. 8. 2026 |
| **Režim vystavení** | Default **`koncept`** (rozjezd ~týden), přepínač `odeslat`. | 24. 8. 2026 |
| **D2 — klíč akce** | `akce-{eventId}`, ne `akce-{reservationId}`. Jedna akce má běžně obě dráhy. | 24. 8. 2026 |
| **D3 — adresa** | Interim: celý `subjects.address` do `street`, `city`/`zip` prázdné. | 24. 8. 2026 |
| Splatnost | 14 dní (`BILLING_DUE_DAYS`) | dřívější |
| Režim DPH | Neplátce — řádky bez `vat_rate`, DIČ se neposílá | dřívější |

---

## 2. Hotovo

| PR | Co přineslo |
|---|---|
| **PR 1** `8c6df48` | Jádro: `InvoiceProvider`, mapování, idempotence, pipeline, port `InvoiceLinkStore` |
| **PR 2** `34b255e` | `FakturoidProvider`: OAuth, hlavičky, rate limit, mapování |
| **PR 3** `ea10d53` | Integrační testy proti testovacímu účtu + měření zaokrouhlení |
| — `8dcee24` | Nálezy code review: kontrola řádků místo částky, izolace PDF, síťové chyby |
| — `0e7eb29` | Druhé kolo review: zavření okna mezi zámkem 2 a claimem |
| **PR 4** | Migrace `fakturoid_invoices`, `SupabaseStore`, Edge funkce, režim vystavení, oddělení chyb |
| **Ceník ledu** | Pásmový klubový ceník (`cenik_pasma`), rozpis na rezervaci, řádky dokladu po sazbách, komerční 5 000 Kč/h |

**Kód žije v `billing/`, schválně MIMO `src/`.** Do `src/` sahá Vite bundle
a `FAKTUROID_CLIENT_SECRET` nesmí mít ani teoretickou cestu do prohlížeče.
Hlídá to `billing/hranice.test.ts` — `npm run lint` je v tomhle repu červený už
na HEADu, takže jako brána nefunguje a ESLint pravidlo by nikdo neuviděl.

---

## 3. Jak to funguje

```
Edge funkce fakturoid-invoice
  ├─ ověří admina (anon klient + has_role)      ← 401 / 403
  ├─ fakturoid_podklady_klub / _akce            ← co se fakturuje
  ├─ mapujKlubMesicne / mapujKomercniAkci       ← InvoiceDraft
  └─ vystavDoklad(draft, FakturoidProvider, SupabaseStore)
       ├─ ZÁMEK 1  jeVyfakturovana              ← už má fakturoidí vazbu?
       ├─ ZÁMEK 2  findExistingInvoice          ← nevznikl už u providera?
       ├─ ZÁMEK 3  zkusZabrat                   ← atomický claim v DB
       ├─ ZÁMEK 2 PODRUHÉ                       ← zavírá okno mezi 2 a 3
       ├─ ensureSubject → createInvoice
       ├─ kontrolní součet proti providerovi    ← varovani
       ├─ PDF do Storage (selhání ≠ neúspěch)
       └─ režim `odeslat` → message.json
```

### Tři zámky, ne jeden

Zámky 1 a 2 jsou **jen čtení**, takže cron a admin, kteří kliknou ve stejnou
vteřinu, projdou oběma. Rozhodne až zámek 3 — a ten je **v databázi**, jedním
příkazem `INSERT … ON CONFLICT (idempotency_key) DO NOTHING RETURNING`.
Nikdy „SELECT, a když nic, tak INSERT": to je závod, ne zámek.

Idempotence stojí na **schématu**, ne na kódu:
- částečný UNIQUE na `idempotency_key` (WHERE `uvolneno_at IS NULL`),
- UNIQUE na `reservation_id` v `fakturoid_invoice_reservations`.

### Nalezenému dokladu se nevěří naslepo

Když zámek 2 doklad najde, porovnají se **řádky**, ne částka. Porovnávat součet
selže přesně v normálním provozu: klub trénuje týdně za stejnou sazbu, takže
doklad na rezervaci „a" a doklad na „b" mají **tutéž částku**. Rezervace „b" by
se označila za vyfakturovanou a **nevyfakturovala by se nikdy**.

Při rozdílu se vrací stav `nesedi` a **vazba se nezapíše** — rozdíl patří
člověku, ne automatice.

---

## 4. Poučení, které stálo nejvíc — čtyři cesty k duplicitní faktuře

Za tři kola bran se v téhle vrstvě našly **čtyři různé** cesty k duplicitnímu
dokladu. Kdo na ni sáhne, ať ví, o co jde:

| # | Cesta | Zavřeno čím |
|---|---|---|
| ① | Zámky 1 a 2 jsou jen čtení — dva souběžné běhy projdou oběma | zámek 3, atomický claim |
| ② | Retry POSTu po 5xx (doklad vznikl, provider spadl při skládání odpovědi) | 5xx se opakuje jen u GET/HEAD (`smiSeOpakovat`) |
| ③ | Nalezenému dokladu se věřilo podle **částky** — u klubu se stejnou sazbou nerozliší rezervace | porovnání **řádků** |
| ④ | Okno mezi zámkem 2 a claimem: A uvolní claim po selhaném POSTu, B ho dostane | zámek 2 se čte **i po claimu** |

**429 se naopak opakovat SMÍ i u POSTu** — znamená „odmítnuto, nezpracováno".

---

## 4b. Co chytily brány u PR 4

Migrační brána **nepustila napoprvé**. Stálo to za to:

| Závažnost | Nález |
|---|---|
| 🔴 | `fakturoid_je_vyfakturovana` a `fakturoid_najdi_podle_klice` byly `SECURITY DEFINER` s `GRANT` pro `authenticated` a **bez guardu**. `najdi_podle_klice` vrací `public_url` — veřejný odkaz Fakturoidu na PDF, který funguje **bez přihlášení** — a klíč se dá uhodnout (`klub-{subjectId}-{RRRRMM}`, `subjects.id` přečte přes RLS každý). Únik celého dokladu komukoli přihlášenému. |
| 🔴 | `fakturoid_zapis_pdf` měl `WHERE` jen na `idempotency_key`. Se stejným klíčem ale může existovat víc řádků (částečný UNIQUE pokrývá jen `uvolneno_at IS NULL`), takže by přepsal `pdf_path` na všech historických uvolněných claimech. |
| 🟡 | Vratnost měla **špatné signatury** — `DROP FUNCTION` se špatným seznamem typů je tichý no-op, takže by dvě funkce revert přežily. `DEFAULT` parametr signaturu nezkracuje. |
| 🟡 | Pohled `fakturoid_invoices_list` neměl `REVOKE`/`GRANT` → výchozí práva Supabase a rozbitý regresní test `security_hardening_test.sql`. |
| 🟡 | Soft delete hlavičky nechával vazby → rezervace **trvale nefakturovatelné** a nikde to nebylo vidět. |
| 🟡 | Chyběly audit triggery (CLAUDE.md §3, precedent u `invoices`). |

Bezpečnostní brána našla nezávisle týž blokér s guardem a přidala dvě střední:

- **`varovani` a fallback vracely surový cizí text.** `varovani` skládalo hlášky
  Postgresu a Storage, `return json(vysledek)` u stavu `nesedi` posílal celý
  `InvoiceResult` včetně `providerLines[].unitPrice`, tedy **sazbu**. Dosažitelné
  to bylo jen adminovi, ale tvar „vrať to celé" přežije i den, kdy se endpoint
  otevře víc lidem. `Varovani` má teď `zprava` (naše věta) a `interni` (jen log);
  odpověď se skládá pole po poli.
- **`sendInvoice` se volalo PŘED `oznacOdeslano`**, takže pojistka „podruhé se
  neposílá" se v té cestě neuplatnila — pád mezi odesláním a zápisem by poslal
  e-mail znovu. Pořadí obrácené; cenou je, že selhané odeslání nechá doklad
  označený, ale varování rovnou říká, že se má poslat ručně.

**Navíc tři věci, které jsem si našel sám:**
- Edge funkce předávala token volajícího do klienta se **servisním klíčem**.
  Když hlavička chybí, supabase-js spadne zpět na servisní klíč a požadavek
  projde s plnými právy **bez volajícího**. Vzor v `invoice-zip` to dělá správně:
  anon klient pro ověření role, servisní až pro práci.
- Režim šlo přebít polem v těle požadavku. Rozjezdový `koncept` má smysl jen
  tehdy, když ho nejde obejít jedním polem v JSONu — rozeslaná faktura se nedá
  vzít zpět. Jediný zdroj je teď `FAKTUROID_MODE`.
- Filtr varování psal `!== null`, jenže `dorovnej` bez úložiště `pdfChyba`
  nevrací vůbec — `undefined` tedy propadlo dál. Chytily to testy.

## 4c. Co našlo až SPUŠTĚNÍ migrace

Migrace prošla `supabase db reset` čistě napoprvé. **Ale spuštění testů nad ní
odhalilo díru, kterou tři brány čtením kódu nenašly** — a byla to ta nejhorší
v celém PR.

### Guard vracel NULL, ne false

`fakturoid_smi_volat()` měl tvar:

```sql
SELECT has_role(auth.uid(), 'admin')
    OR current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role'
    OR (auth.uid() IS NULL AND session_user IN ('postgres','supabase_admin'));
```

Mimo PostgREST není `request.jwt.claims` nastavené, takže `current_setting(…, true)`
vrátí NULL a porovnání je taky NULL. A pak:

```
false OR NULL OR false  →  NULL
NOT NULL                →  NULL
IF NULL THEN RAISE      →  NEPROVEDE SE
```

**Guard tedy tiše propustil.** Změřeno na živé databázi: pod rolí `authenticated`
vracel NULL, `fakturoid_je_vyfakturovana` odpověděla místo chyby a
`fakturoid_zkus_zabrat` se dostala až na cizí klíč — tedy **běžný přihlášený
uživatel by založil claim**.

Oprava: každá větev obalená `COALESCE(…, false)`, plus `IF NOT COALESCE(guard, false)`
jako pás i šle.

**Proč to brány nechytily:** čtou kód, a ten vypadá správně. Vidět to jde jen
během — a jen přes **věrný kanál**. Pod `psql -U postgres` projde větev pro cron
(`session_user` je `postgres`), takže test tvrdí zavřeno o dveřích, vedle kterých
je otevřené okno. Je to přesně pravidlo 8 v CLAUDE.md, jen o patro hlouběji.

### Týž vzorec je i v Etapě 2 — tam je zavřený granty

`claim_invoice_pdf`, `finish_invoice_pdf` a `fail_invoice_pdf`
(`20260818090000_pdf_fronta.sql`) mají **stejnou konstrukci** a stejnou NULL díru.
Dosažitelná ale není: `authenticated` na ně nemá `EXECUTE`, takže se zastaví
o `permission denied` dřív, než se ke guardu dojde. Ověřeno spuštěním.

⚠️ **Kdyby jim někdo někdy udělil `EXECUTE` pro `authenticated`, díra se otevře.**
Fakturoidí funkce ten grant mají (admin je volá z webu) — proto tam byla živá.
Opravit i Etapu 2 je **samostatný ticket**; sem podle zadání sahat nemám.

## 5. „Koncept" u Fakturoidu není koncept

**Fakturoid API stav koncept NEZNÁ.** Doklad vytvořený přes `POST /invoices.json`
je plnohodnotný a **už má číslo v ostré řadě**.

`FAKTUROID_MODE=koncept` u nás proto znamená **„vystaveno, ale neodesláno"** —
doklad u Fakturoidu je, jen se neposlal e-mail; člověk si ho prohlédne a odešle
sám. Není to nezávazný návrh a **omyl nejde tiše smazat**.

Odesílá se přes **`POST /invoices/{id}/message.json`**, ne přes
`fire.json?event=deliver` — ten byl z API v3 **odstraněn** ve prospěch Invoice
Messages. `fire.json` dnes umí jen `mark_as_sent`, `cancel`, `undo_cancel`,
`lock`, `unlock`, `mark_as_uncollectible`. Kdo by sáhl po `mark_as_sent`, označí
doklad za odeslaný, **aniž by ho kdokoli dostal**.

---

## 6. Co zbývá

### Ověřeno proti živému testovacímu účtu (25. 8. 2026)

Účet `tomastest`, tarif Zdarma, `vat_mode: non_vat_payer`.

**Zaokrouhlení: Fakturoid nezaokrouhloval VŮBEC.** Nešlo o jiné pravidlo — o žádné.
Změřeno na fixtuře 3 × 1 250,505 Kč:

```
[ZAOKROUHLENÍ] přesný součet 3751.53 Kč · naše k úhradě 3752 Kč
               · Fakturoid 3751.53 Kč · DELTA -0,47 Kč
```

Doklad tedy zněl na 3 751,53 Kč, kdežto naše R3 dává 3 752 Kč.

> **ROZHODNUTÍ PM 25. 8. 2026: zapnout zaokrouhlení na celé koruny v nastavení
> Fakturoidu.** Je to nastavení ÚČTU, ne našeho kódu — kdo bude zakládat další
> účet (ostrý provoz), **musí ho zapnout znovu**, jinak se doklady rozejdou
> s „Kdo kolik dluží" až o 0,50 Kč na doklad, a to tiše.

**Po zapnutí ověřeno na téže fixtuře — kontrolní součet vychází na nulu:**

| | před zapnutím | po zapnutí |
|---|---|---|
| doklad | `2026-0001` | `2026-0003` |
| Fakturoid vrátil | 3 751,53 Kč | **3 752 Kč** |
| naše k úhradě (R3) | 3 752 Kč | 3 752 Kč |
| **rozdíl** | −0,47 Kč | **0 Kč** |

```
posíláme:  3 řádky à 1,5 h × 833,67 Kč
           přesný součet       3 751,53 Kč
           naše k úhradě (R3)      3 752 Kč
Fakturoid: 2026-0003, celkem      3 752 Kč
KONTROLNÍ SOUČET: 0 Kč      ·      varování z pipeline: žádné
```

**Fixtura je schválně ta nejnepříjemnější, jakou umíme.** Na 3 × 1 250,505 Kč se
tři pravidla rozcházejí: přesně 3 751,53 / stupňovitě 3 752 / po řádcích chybně
3 753. Kdyby Fakturoid zaokrouhloval **po řádcích**, vyšlo by 3 753, delta by
byla +1 Kč a test by spadl (tolerance je 0,50 Kč). Vyšlo 3 752, takže zaokrouhluje
**z mezisoučtu, ne po řádcích** — tedy stejně jako naše rozhodnutí R3.

Doklad `2026-0001` na testovacím účtu **nech být**: vedle `2026-0003` je na téže
fixtuře vidět rozdíl 0,47 Kč, kde jediná změna je to nastavení.

**Tvar hlavičky rate limitu — už to není domněnka.** Odchyceno z živé odpovědi:

```
x-ratelimit:        default;r=387;t=44
x-ratelimit-policy: default;q=400;w=60
```

`r` = zbývající požadavky, `t` = vteřiny do resetu, `q` = kvóta, `w` = okno.
Limit je **400 požadavků za minutu**. Parser tenhle tvar zvládá a je na to test
se skutečnou hodnotou.

**403 vrací DVA různé tvary těla** a obě jsou k nezaplacení při ladění:

```
{"error":"quota_exhausted", …}                   — vyčerpaný limit tarifu
{"errors":{"bank_account":["Please set up …"]}}  — nedodělané nastavení účtu
```

Původně sem spadlo 401 i 403 se společnou hláškou „zkontroluj klíče" — a stálo to
hodinu hledání v klíčích, které byly celou dobu v pořádku. Teď: 401 = přihlášení,
403 = `BillingProviderError` s kódem chyby nebo jmény vadných polí a s větou, že
o heslo **nejde**.

**Bez bankovního účtu Fakturoid doklad nevystaví.** `POST /invoices.json` vrátí
403 s `bank_account`. Patří to do kroků nasazení.

**Konec s tvorbou odběratele na každý běh.** Integrační sada nesla razítko běhu
i v `custom_id` odběratele, takže každé spuštění sežralo jedno místo v limitu
tarifu. Odběratel je teď stabilní (`subj-test-klub-curling`); razítko zůstává jen
na dokladu. Navíc to testuje `ensureSubject` líp — druhý běh ho má NAJÍT.

### Ověřeno end-to-end na reálných datech

Klub CK Ostravské kameny, srpen 2026, 10 rezervací ze seedu → doklad **2026-0002**
na 19 200 Kč, `rozdil` 0,00, 10 navázaných rezervací, 12 auditních záznamů.
`reservations.invoice_id` zůstalo nedotčené u všech 36 rezervací.

**Idempotence naživo:** druhý běh nevystavil nic, protože `fakturoid_podklady_klub`
vrátí po vystavení nula podkladů — duplicita se nedá ani zkusit. Na účtu jsou
přesně dva doklady, ne tři.

### Testy

```bash
# funkční sada — 36 tvrzení
docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/fakturoid_test.sql

# sada PRÁV — 11 tvrzení, MUSÍ přes authenticator, jinak netestuje nic
docker exec -e PGPASSWORD=postgres -i supabase_db_<project> \
  psql -h 127.0.0.1 -U authenticator -d postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/fakturoid_prava_test.sql

# GUARD REŽIMU DPH — 5 tvrzení. Hlídá, že po přepnutí na plátce interní engine
# ani nezaloží koncept, ani nevystaví, a že automatika nic nevyrobí. Bez něj
# může guard vypadnout a celá sada zůstane zelená (ověřeno mutací).
docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/vat_mode_guard_test.sql

npm run test:run          # 390 unit testů (bez integračních, viz níž)
npm run typecheck
deno check --config supabase/functions/deno.json supabase/functions/fakturoid-invoice/index.ts

# ŽIVÉ testy proti Fakturoidu — zakládají doklady na testovacím účtu a po sobě
# je uklízejí. `npm run test:run` je ZÁMĚRNĚ nespustí (vyloučené ve
# vitest.config.ts), aby na cizí účet nesáhly omylem.
npm run test:fakturoid

# Co zbylo po bězích, které teardown nedoběhly (zabitý proces). Bez --smazat
# běží nanečisto.
npx vite-node scripts/fakturoid-uklid-testy.ts
```

Migrace ověřena `supabase db reset` — 29 migrací, čistý průběh, obě SQL sady zelené.

### Otevřené a vědomě odložené

- **E-mail odběratele.** `public.subjects` sloupec pro e-mail **nemá**, takže pro
  režim `odeslat` ho musí mít vyplněný Fakturoid — jinak vrátí 422. Buď ho tam
  doplní člověk, nebo přibude migrací sloupec. Pro `koncept` to nevadí.
- **Strukturovaná adresa z ARESu.** `ares-lookup` bere jen
  `sidlo.textovaAdresa` a `nazevUlice`/`nazevObce`/`psc` zahazuje.
- **Timeout požadavků** (`AbortController`) — `http.ts` nemá horní mez čekání.
- **Vyřazení interního enginu** — samostatný ticket (rozhodnutí PM).

### Pro PM, ne pro kód

**Fakturoid je nový zpracovatel osobních údajů** (název, IČO, DIČ, sídlo
odběratelů). Patří k tomu zpracovatelská smlouva a záznam o činnostech zpracování.

---

## 6b. Pásmový ceník ledu — co to rozbilo a co to drží

Klubová cena závisí na DENNÍ DOBĚ (`cenik_pasma`), rezervace přes hranici pásma
se počítá po hodinách: 16–19 = 1×1000 + 2×1200 = **3 400 Kč**.

**Tím přestalo platit `amount = hodiny × rate_per_hour`.** `rate_per_hour` je
u pásmové rezervace ODVOZENÝ PRŮMĚR (3 400 / 3 = 1 133,33), autoritativní je
`amount` + `reservations.cenove_pasma` (rozpis v jsonb). Kdo bude někdy počítat
částku ze sazby, dostane 3 399,99 — haléř vedle, na každé takové faktuře.

**Doklad má proto JEDEN ŘÁDEK NA SAZBU**, ne na rezervaci. Kvůli tomu musel
`fakturoid_radku_sedi` povolit víc řádků než rezervací (z rovnosti se stalo
minimum — míň pořád znamená, že rezervace na doklad nedoputovala).

### Co našly brány (a co to stálo)

Blok prošel bránami až napodruhé. Nálezy, které stojí za zapamatování:

- **Přepis dlouhé funkce zase ubral guard.** `check_reservation_money` se
  přepisovala ručně a ztratila stropy `rate_per_hour > 50000`,
  `corrected_hours > 24` i povinný `correction_reason`. CHECK constrainty držely,
  takže se nic špatného nevyfakturovalo — ale uživatel místo vysvětlení dostal
  jméno constraintu. **Pravidlo 7 z CLAUDE.md platí i pro funkce, které se
  „jen trochu" upravují.** (`set_reservation_pricing` generovaná z živého
  schématu byla čistá — diff to potvrdil.)
- **Snapshot ceny je snapshot ČASU.** Přesunutá rezervace držela starou částku:
  16–19 (3 400 Kč) přejelo na 9–12 a pořád stálo 3 400 místo 2 400. Prodloužená
  měla rozpis kratší než hodiny, což `mapping.ts` odmítne — doklad by nešel
  vystavit vůbec. Přesun i prodloužení dnes rezervaci přecení.
- **Ruční sazba u pásmové rezervace nepřepočítávala částku.** Admin nastavil
  900 Kč/h, UI ukázalo 900, systém fakturoval 3 400 místo 2 700. Dnes ruční
  sazba pásma přebije a rozpis se zahodí.
- **Rozpis se k dokladu vůbec nedostával.** `mapping.ts` ho uměl složit, ale
  `fakturoid_podklady_klub` ho nevracela — každá klubová faktura s rezervací
  přes dvě pásma by spadla na validaci. Každá vrstva zvlášť fungovala; chyběl
  test přes celou cestu. Ten je dnes v `cenik_pasma_test.sql`, sekce 5d.
- **`'null'::jsonb` NENÍ SQL NULL.** Podstrčením téhle hodnoty do
  `cenove_pasma` šlo vypnout pravidlo o celých korunách i dopočet `amount` —
  vznikla rezervace se sazbou 1 234,56 Kč/h a `amount = NULL`. Sloupec je
  odvozený, takže se dnes na vstupu zahazuje, a tvar i součet hlídá CHECK
  (`reservations_cenove_pasma_sedi`), ne jen trigger.
- **SECURITY DEFINER funkce obešla RLS nad ceníkem.** `cena_ledu` měla EXECUTE
  pro `authenticated`, takže si člen klubu mohl vyjet cenu hodinu po hodině
  a složit celý ceník, přestože mu `SELECT * FROM cenik_pasma` vrací nula řádků.
  Dnes má REVOKE pro všechny — volá ji jen SECURITY DEFINER trigger, který
  žádný grant nepotřebuje.
- **Kontrola v migraci rozbíjela idempotenci.** Závěrečný blok měl natvrdo
  3 400 Kč, takže druhý běh na databázi s upraveným ceníkem hlásil rozbitý
  ceník. Dnes se strukturální invarianty ověřují vždycky a konkrétní částky jen
  na nedotčeném ceníku.
- **Revert nešel spustit.** Hlavička tvrdila, že rezervace s haléři projdou jako
  existující data. Neprojdou — `ADD CONSTRAINT` validuje okamžitě a revert se
  zastavil uprostřed. Dnes je tam `NOT VALID` a je vysvětleno proč.

### Rozhodnutí PM (31. 8. 2026) — na co pásma platí a na co ne

**Pásmový ceník platí na klubový led VČETNĚ TRÉNINKŮ.** To je celý smysl bloku:
klubový trénink je přesně ten led, kterého se odstupňování podle denní doby týká.

    klubový večerní trénink    dřív 600 Kč/h   →   nově 1 200 Kč/h

⚠️ **Zdražení večerního tréninku ještě potvrdí klient.** Do té doby platí, co je
v kódu; sazby jsou v `cenik_pasma` a jdou změnit bez migrace.

**Klubové turnaje mají PEVNOU cenu** — ne pásmovou a ne hodinovou:

| Turnaj | Cena |
|---|---|
| jednodenní | 14 000 Kč |
| víkendový | 26 000 Kč |

Je to **celková částka za akci** — nenásobí se hodinami ani počtem drah a na
dokladu má být jedním řádkem.

**`settings.training_rate` (600) a `tournament_rate` (800) jsou legacy.**
V Nastavení jsou skryté (`src/pages/Settings.tsx`), v databázi zůstávají — starší
rezervace se podle nich ocenily a bez nich by se nedalo dohledat proč. Formulář
ceníku je do payloadu neposílá, aby je neuložil jako NULL.

### ⚠️ Co z toho rozhodnutí ZATÍM NENÍ hotové

**Pevná cena turnajů není implementovaná.** Je to jiný model ceny než všechno
dosavadní: oceňuje se **akce**, ne rezervace — zatímco `reservations.amount`
i „Kdo kolik dluží" dnes sčítají rezervace, a `mapping.ts` skládá řádky dokladu
po rezervacích. Udělat z toho jeden řádek za akci znamená sáhnout na
`reservations_billing`, podkladové RPC i mapovací vrstvu, včetně kontrolního
součtu.

Do té doby se **klubové turnaje oceňují pásmově** (17–19 = 2 400 Kč místo
14 000) a rozdíl se doúčtovává ručně. Je to známá díra, ne přehlédnutí —
patří jí vlastní blok s vlastními bránami.

**Ranní pásmo 6–14 za 800 Kč/h** taky pořád čeká na potvrzení klienta, a ceník
zatím **nejde měnit z aplikace** — v `src/` na `cenik_pasma` není reference,
takže „admin si to upraví v Nastavení" dnes znamená ruční SQL.

---

## 7. Čemu nevěřit a co si ověřit

Kromě pastí z `docs/ETAPA2-STAV.md`, kapitola 5, přibylo tohle:

- **`deno check billing/…` bez `--config` v kořeni repa hlásí falešné chyby**
  (`setTimeout`, `TextEncoder`). Deno tam najde `package.json` a přepne se do
  Node-compat režimu bez webových API. Věrný běh:
  `deno check --config supabase/functions/deno.json billing/**/*.ts`
- **TypeScriptové `private` za běhu neexistuje.** `constructor(private volby)`
  vyrobí enumerable vlastnost, takže `JSON.stringify(provider)` vydá
  `client_secret`. Proto `#` pole a `toJSON()`; hlídají to testy.
- **Nepředávej token volajícího do klienta se servisním klíčem.** Když hlavička
  chybí, supabase-js spadne zpět na servisní klíč a požadavek projde s plnými
  právy bez volajícího. Vzor je v `invoice-zip`: anon klient pro ověření role,
  servisní až pro práci.
- **`lzeOpakovat` NENÍ povolení zopakovat `createInvoice` napřímo.** Chyby
  z neúspěšného zápisu nesou `zapisNejisty`; opakovat se smí jen celé
  `vystavDoklad`, kde to zachytí zámky.
- **Chybová hlášení téhle vrstvy nesou sazby a částky.** Ven jde
  `uzivatelskaZprava()` / `proUzivatele()`, nikdy `err.message`.
- **`fakturovatelne_rezervace` má EXECUTE odebrané i `service_role`** — volá se
  jen z jiné SECURITY DEFINER funkce (`fakturoid_podklady_klub` / `_akce`).
- **`amount = hodiny × rate_per_hour` UŽ NEPLATÍ.** U pásmové rezervace je
  sazba odvozený průměr a součin dá o haléř míň. Autoritativní je `amount`
  a `cenove_pasma`.
- **`'null'::jsonb` projde každým testem na `IS NULL`.** V jsonb sloupci to není
  prázdná hodnota, ale hodnota „null" — a podmínky typu
  `IF NEW.sloupec IS NULL` se na ni chytnou obráceně, než čekáš. Testuj
  `jsonb_typeof(...)`, ne `IS NULL`.

---

## 8. Nasazení — pořadí

1. **Záloha produkční DB** (pravidlo repa, bez ní se nic neaplikuje).
2. Migrace `20260824120000_fakturoid_vazba.sql` — **nejdřív lokálně**.
3. Tajemství do **Supabase secrets**, ne do Netlify env (to je pro frontend):
   ```
   supabase secrets set --project-ref <ref> \
     FAKTUROID_SLUG=… FAKTUROID_CLIENT_ID=… FAKTUROID_CLIENT_SECRET=… \
     FAKTUROID_USER_AGENT='CurlingPromo (kontakt@email)' FAKTUROID_MODE=koncept \
     IS_VAT_PAYER=true
   ```
4. **DPH: TŘI MÍSTA, JEDEN OKAMŽIK.** Hala je od bloku B plátce (12 % za led)
   a přepnout se musí všechno naráz, k datu účinnosti registrace:
   - `IS_VAT_PAYER=true` v secrets (výš) — řídí fakturoidí cestu,
   - migrace `20260830140000_vat_mode_platce.sql` — přepne
     `billing_settings.vat_mode` a tím ZAVŘE interní engine (záměr, ne škoda),
   - **účet ve Fakturoidu** musí být vedený jako plátce.

   Kterékoli z těch tří pozadu znamená doklad v jiném režimu, než v jakém ho
   hala vystavit chtěla — a to se opravuje dobropisem, ne přepnutím zpátky.
   Automatiku přitom NEZAPÍNAT, dokud interní engine nevypadne (podrobnosti
   v hlavičce té migrace).

   **Před migrací zahoď otevřené koncepty.** Koncept založený před přepnutím
   drží rezervace zamčené a už nepůjde vystavit — `k_fakturaci` u toho subjektu
   spadne na nulu, zatímco fakturoidí cesta ty rezervace vidí dál. Migrace je
   sama neruší (zahodit rozpracovaný doklad je rozhodnutí provozu), jen na ně
   upozorní `WARNING`em. Cesta ven je `delete_invoice_draft` a funguje i pod
   plátcem.
   ```sql
   SELECT i.cislo, i.subjekt_nazev, count(r.id) AS zamcenych_rezervaci
     FROM public.invoices i LEFT JOIN public.reservations r ON r.invoice_id = i.id
    WHERE i.status = 'koncept' GROUP BY 1, 2;
   ```

   **Co se přepnutím NEZAVŘE:** `storno_invoice` a `dobropis_invoice` guard
   nemají a mít nemají — staré neplátcovské doklady musí jít opravit a opravný
   doklad si režim dědí z opravovaného. Interní číselná řada tedy může po
   přepnutí dál růst, jen o storna a dobropisy k dokladům z doby předtím.
5. Deploy funkce `fakturoid-invoice`.
6. **Týden v režimu `koncept`** — doklady se zakládají, e-maily se neposílají.
   Teprve pak `FAKTUROID_MODE=odeslat`.

**Integrační testy nikdy nepouštěj s produkčním slugem.** Kromě
`FAKTUROID_LIVE=true` se musí do `FAKTUROID_TEST_SLUG` opsat jméno účtu, na který
se smí psát. Doklad v ostré řadě **nejde smazat, jen dobropisovat**.
