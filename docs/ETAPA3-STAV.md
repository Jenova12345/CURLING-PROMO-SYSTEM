# Etapa 3 — Fakturoid · STAV

**Aktualizováno:** 2. 9. 2026 · **Větev:** `main`

> **Nasazeno na OSTROU produkci** (`fcwubbytqxubgptftnru`) a pushnuto.
> Od 31. 8. 2026 do systému zadává data klient, takže „lokální commit" už není
> bezpečné místo, kde nechat práci ležet — nasazuje se po dávkách, každá
> po čerstvé záloze přes `scripts/safe-deploy.sh`.
>
> **Ostrý Fakturoid je pořád VYPNUTÝ.** Klíče míří na testovací účet
> `tomastest`, cutover na ostrý účet je vědomý ruční krok — viz kapitola 8.

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
| **Blok C** | Životní cyklus účtu: registrace bez role, schvaluje i zástupce, „právo navíc", default-deny brána `ucet_aktivni()` |

**Kód žije v `billing/`, schválně MIMO `src/`.** Do `src/` sahá Vite bundle
a `FAKTUROID_CLIENT_SECRET` nesmí mít ani teoretickou cestu do prohlížeče.
Hlídá to `billing/hranice.test.ts` — `npm run lint` je v tomhle repu červený už
na HEADu, takže jako brána nefunguje a ESLint pravidlo by nikdo neuviděl.

---

## 2b. Vlna B — připravenost na cutover (2. 9. 2026)

Čtyři nálezy z předcutoverového review. Společný jmenovatel: **dvě fakturační
cesty se navzájem neviděly.** Interní engine zamyká rezervaci přes
`reservations.invoice_id`, fakturoidí přes vazební řádek — a ani jeden se
neptal na ten druhý.

| Nález | Co bylo | Čím je to zavřené |
|---|---|---|
| 5 | Rezervaci mohl zabrat interní i fakturoidí doklad zároveň. Mezi nimi stál jen `vat_mode`, tedy **nastavení, ne zámek**. | Dva zrcadlové triggery — `trg_reservations_jeden_doklad` (BEFORE UPDATE OF `invoice_id`) a `trg_fakturoid_vazba_jeden_doklad` (BEFORE INSERT na vazbu). Každý hlídá z jedné strany. |
| 6 | „Kdo kolik dluží" fakturoidí doklady **nepočítalo vůbec**. `rozdil = 0` vycházel, ale měřil jen půlku systému: vystavená rezervace zůstala navěky v `k_fakturaci`. | `billing_reconcile` má nově sloupce `fakturoid` (co drží fakturoidí doklad) a `fakturoid_rozdil` (Σ dokladů − Σ rezervací na nich, **musí být 0**). Zabrané rezervace z `k_fakturaci` vypadnou. |
| 7 | Prázdné `IS_VAT_PAYER` mlčky znamenalo „neplátce". Zapomenutý secret by poslal ostré doklady **bez 12 % DPH** — a to se opravuje dobropisem, ne přepnutím. | Prázdno je nově **chyba**. Před každým vystavením se režim navíc porovná s `billing_settings.vat_mode` (`overDanovyRezim`) — dva zdroje téže pravdy se přestaly moct rozejít. |
| 4 | `FAKTUROID_LIVE` se načítalo do configu a **nikdo ho nečetl** — gatovalo jen přeskakování integračních testů. Ostrý doklad šlo vystavit jedním příkazem, aniž by to kdokoli vědomě zapnul. | `overPovolenyUcet` chce **dvě nezávislá potvrzení**: `FAKTUROID_LIVE=true` **a** shodu `FAKTUROID_SLUG` s účtem vypsaným v `FAKTUROID_POVOLENY_UCET` (bez něj se bere `FAKTUROID_TEST_SLUG`). Volá se v Edge funkci i v `scripts/fakturoid-akce.ts`. |

Navíc: `fakturoid_smi_volat` **padalo** na prázdném `request.jwt.claims` (pooler
recykluje spojení) místo slušného odmítnutí — `NULLIF(..., '')` to srovnalo.

**Proč to samo o sobě nestačí a cutover je pořád ruční:** přepnutí
`FAKTUROID_SLUG` na ostrý účet teď skončí odmítnutím, dokud někdo ten účet
výslovně nevypíše do `FAKTUROID_POVOLENY_UCET`. To je záměr — překlep ve slugu
nesmí vystavit doklad cizímu účtu.

**Mutace, které to prokázaly:** bez zámku projde dvojí doklad; bez odečtu
fakturoidích dokladů zůstane `k_fakturaci` nenulové; se starou
`fakturoid_smi_volat` test padá na `invalid input syntax for type json`.

---

## 2c. Upozornění na změnu rezervace (2. 9. 2026)

KROK 0 ukázal, že se to nedělo **vůbec**: `reservation_cancelled` bylo od
začátku vypsané v komentáři u `notifications.type`, jako by existovalo, ale
nezakládalo ho nic. Správce mohl klubu posunout trénink nebo ho zrušit a klub
se to dozvěděl jen tím, že si toho v kalendáři sám všiml.

`trg_reservations_notify_change` teď upozorní **autora** rezervace, když s ní
hne někdo jiný — u přesunu nese zpráva původní i nový čas, u zrušení důvod.
Vlastní zásah a servisní zápisy (`auth.uid() IS NULL`) neupozorňují. Systém
e-maily dál neposílá; tohle je upozornění v aplikaci a zvonek ho zobrazí bez
změny frontendu (nerozlišuje typy).

> **Past, která z toho vylezla a stojí za zapamatování.** Dedup „jedna zpráva
> na akci" stál původně na `created_at >= now()`. V provozu to vychází (jedno
> RPC = jedna transakce), ale `now()` je čas **začátku transakce** — a testovací
> soubor je jedna dlouhá transakce, takže dedup umlčel i scénáře, které spolu
> nesouvisely, a **obě brány byly falešně zelené**. Teď to drží transakčně
> lokální značka (`set_config(..., true)`) a každý scénář má vlastní rezervaci.

---

## 2d. OTEVŘENÝ NÁLEZ — `cena_bez_dph` u ručně zadané sazby (2. 9. 2026)

**Neopraveno, čeká na rozhodnutí.** Našlo se to při přípravě cutoveru.

Cenová větev v `set_reservation_pricing` běží jen když `NEW.rate_per_hour IS NULL`.
Admin ale sazbu zadat MŮŽE (`create_booking(p_rate)`, úprava komerční akce) a jeho
hodnotu žádný guard nenuluje — ne-adminům ji `guard_reservation_rep_changes`
přepisuje na NULL, admin tou výjimkou projde. Když sazba přijde vyplněná, větev
se přeskočí a `cena_bez_dph` zůstane na DEFAULTU sloupce, tedy `false`.

Reprodukováno lokálně dvěma jinak identickými komerčními rezervacemi:

```
A) bez sazby ... cena_bez_dph = t   (sazba 5000, částka 10000)
B) se sazbou ... cena_bez_dph = f   (sazba 5000, částka 10000)   ← špatně
funkce cena_je_bez_dph říká pro obě: t
```

**Proč to jsou peníze.** Pod `vat_mode = platce` znamená `cena_bez_dph = false`,
že `amount` je částka VČETNĚ daně. U komerční akce je to naopak základ. Dluh
se tím podhodnotí o celou sazbu: místo 10 000 + 12 % = 11 200 Kč systém tvrdí,
že zákazník dluží 10 000 Kč.

**Rozsah na produkci k 2. 9. 2026:** 4 rezervace, 22 000 Kč základu,
**2 640 Kč nezapočítané DPH** (Deloitte, Hybridní vzdělávání, 2× ZŠ Bulharská).

Fakturaci to nepustí dál — daňová brána z vlny B tyhle podklady odmítá
(„Doklad za akci by míchal ceny s DPH a bez DPH"). To je brána dělající svou
práci, ne chyba v zadání: subjekty jsou správně typu `commercial` a **v aplikaci
to nejde opravit**, protože chybná hodnota není nic, co by šlo přepsat formulářem.

**Navržená oprava** (dvě části, obojí měřit mutací):
1. `cena_bez_dph` počítat i tehdy, když sazba přijde zvenčí — je to odvozená
   hodnota z `cena_je_bez_dph(typ subjektu, typ akce, sazba subjektu)`
   a na tom, kdo vyplnil `rate_per_hour`, nezávisí.
2. Jednorázová náprava těch 4 řádků, aby dluh seděl.

Hlídat by to měl invariant: `cena_bez_dph` se nikdy nesmí rozejít s tím, co
vrací `cena_je_bez_dph` pro týž subjekt a typ akce.

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

## 6c. Blok C — životní cyklus účtu (31. 8. 2026)

Migrace `20260831140000_zivotni_cyklus_uctu.sql`, testy
`supabase/tests/zivotni_cyklus_test.sql`. Staví bod 2 z `docs/ETAPA3-ROLE-NAVRH.md`.

**Registrace už nedává roli.** Účet vzniká ve stavu `ceka` a dovnitř ho pustí
teprve schválení žádosti o klub, které jedním krokem přidělí členství, roli
`hobby_player` i stav `aktivni`. Schvalovat smí **admin i zástupce cílového
klubu** (R5) — zástupce ale jen do svého klubu a **úroveň „zástupce" smí udělit
jen admin**, jinak by si zástupce vyrobil druhého a obešel správce haly.

**Default-deny je vidět (R6).** Brána je `ucet_aktivni()` a je zapojená do tří
funkcí, na kterých stojí všechny politiky: `has_role`, `is_subject_member`,
`is_subject_rep`. Účet ve stavu `ceka` by neprošel i bez ní (nemá roli ani
členství), ale **deaktivovaný účet roli má** — a právě ten se tím zavírá.
Zavřít člověka jde díky tomu na jednom místě, změnou `profiles.stav`.

**„Právo navíc" je úzké (R11).** `subject_reps.muze_potvrzovat` dovolí hráči
potvrdit **jen jeho vlastní** rezervaci před akcí; cizí nepotvrdí ani s ním.
Potvrzení PO akci, které spouští fakturaci a výplaty, hráč nedostane nikdy (R10).

### Dvě pasti, na které tenhle blok narazil

- **Frontend si roli domýšlel.** `AuthContext` při prázdném seznamu rolí
  nastavoval `hobby_player`. Od bloku C je „bez role" normální stav (čekající
  účet), takže by se takový uživatel tvářil jako vpuštěný a koukal na prázdnou
  aplikaci místo věty „čeká se na potvrzení". Fallback je pryč; zastavuje to
  `AppLayout` na jednom místě nad všemi stránkami.
- **`profiles_self` neměl `stav`.** Aplikace profil čte z pohledu, ne z tabulky,
  a pohled vznikl dřív než sloupec. Bez jeho doplnění by se přihlašovací
  obrazovka neměla podle čeho rozhodnout.

### Co ještě nemá brány

⚠️ **Kompletní bezpečnostní brána na blok C neproběhla** — pouští se až před
nasazením do produkce (rozhodnutí PM z 31. 8. 2026). Odzkoušené to je (20 SQL
suit, testy práv pod `SET LOCAL ROLE authenticated`, typecheck, build), ale
nezávislé review to zatím nevidělo. **Do produkce ne, dokud brána neproběhne.**

---

## 6d. Nápravy z brány (ultra review, 31. 8. 2026)

Multiagentní review dnešní práce našla 15 nálezů, z toho 6 označených jako
MUST-FIX před tím, než se do systému přihlásí členové klubů. Všech 15 je
opravených v pěti migracích a čtyřech souborech frontendu; **nasazuje se to
jako jeden celek**, protože nálezy se navzájem drží (daňová brána potřebuje
snapshot, snapshot potřebuje backfill).

| Migrace | Co řeší |
|---|---|
| `20260831230000_ucet_nelze_odbanovat` | Zavřený účet se nesmí otevřít přes žádost o klub |
| `20260831231000_dph_jedno_misto` | `cena_bez_dph` — jedno kritérium pro daňový význam `amount` |
| `20260831232000_uprava_akce_naprava` | Pásmová dráha, zámek vyfakturované akce, instruktor, trenérská směna |
| `20260831233000_trener_prava` | Zástupce trenéra vidí; přání se nedá podstrčit; jednoznačný klub |
| `20260831234000_cenik_pokryva_provoz` | Ceník musí pokrýt otevírací dobu; hláška, která nelže |

### Nejdražší dva nálezy

**1) Zástupce klubu uměl odbanovat účet.** `approve_subject_request` přepínala
`stav` na `aktivni` bezpodmínečně a `request_subject_membership` se stavu
neptala vůbec. Deaktivovaný uživatel si tedy podal žádost do libovolného jiného
klubu, jeho zástupce ji v dobré víře schválil — a protože `ucet_aktivni()` je
brána pod `has_role`, `is_subject_member` i `is_subject_rep`, otevřelo se tím
úplně všechno, co blok C zavřel. Zavřeno dvěma vrstvami (žádost se nepodá +
schválení neotevře), obojí ověřeno mutací.

**2) Kontrolní součet se rozešel o 12 %.** Daňový význam `amount` si každá
vrstva odvozovala z něčeho jiného — ocenění z **typu akce**, „Kdo kolik dluží"
z **typu subjektu**, doklad z **druhu dokladu**. Dokud typ akce a typ subjektu
chodily spolu, sedělo to; rozejít je umělo jedno kliknutí (`zmen_typ_akce` na
klubové akci). Řeší to snapshot `reservations.cena_bez_dph`, pořízený ve chvíli,
kdy se sazba vybírá — a **daňová brána** v obou podkladových funkcích, která
nepustí na jeden doklad ceny se dvěma významy. Radši nevystavit než vystavit
špatně.

### Co se vědomě NEŘEŠILO

- **Editor pásmového ceníku v UI.** Zadání znělo „zatím jen zabezpeč".
  Migrace proto brání vzniku díry mezi otevírací dobou a ceníkem (dva odložené
  constraint triggery) a opravuje hlášku, která posílala na obrazovku, jež
  neexistuje. Editor je samostatný follow-up — bez něj se ceník pořád mění
  jen ručním SQL.
- **Sazba ranního pásma (800 Kč/h)** pořád čeká na potvrzení klienta. Migrace
  ji NEMĚNÍ (vymyslet cenu není oprava), jen z popisku pásma odstranila
  placeholder. Test ji přišpendluje, aby se změnila vědomě.
- **Obnovení zavřeného účtu z aplikace.** Dnes je to `UPDATE profiles` pod
  adminem, RPC ani obrazovka na to nejsou. Nová brána to nezhoršuje (dřív tam
  taky nic nebylo), ale je to teď jediná cesta zpátky — patří k follow-upu
  o správě uživatelů.
- **Rozplétání akce, která už je na dokladu.** Nová brána `over_neni_vyfakturovano`
  úpravu zastaví a odkáže na storno/dobropis. Rezervace na STORNOVANÉM dokladu
  drží zámek dál — je to vědomé, ale znamená to, že cesta „stornovat a přecenit"
  dnes končí u dobropisu.

### Otázka na PM

**Má klub, který si objedná komerční akci, platit komerčních 5 000 Kč/h?**
Dnes ano (rozhoduje typ akce, ne typ odběratele) — a nově se mu k tomu správně
připočte DPH. Kdyby měl platit klubový ceník, je to jednořádková změna ve výběru
sazby, ne v mechanismu.

### Testy

```bash
docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/ucet_odbanovani_test.sql      # 11 tvrzení, práva pod authenticated
docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/dph_jedno_misto_test.sql      # 20 tvrzení včetně kontrolního součtu
docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/trener_prava_test.sql         # 19 tvrzení, práva pod authenticated
docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/cenik_pokryti_test.sql        # 8 tvrzení
docker exec -i supabase_db_<project> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/uprava_akce_test.sql          # 48 tvrzení: + pásmová dráha, zámek, PRÁVA
npm run test:run                                 # 405 (přibyl src/lib/branyFrontendu.test.ts)
```

**Ověřeno mutací** (test zčervená, když se oprava vrátí zpátky): odbanování
přes frontu, dluh podle typu subjektu, kopírování průměrné sazby do nové dráhy,
chybějící zámek vyfakturované akce.

**Kontrolní součet:** `billing_reconcile` = 0 za 6–10/2026 na čerstvém seedu,
`billing_health` má všechny počty nulové. Celá sada 28 SQL souborů + 405 unit
testů + `npm run typecheck` + `deno check` je zelená po `supabase db reset`.

### Past, kterou tyhle opravy odhalily

**Sloupcový `REVOKE` na `reservations` nic nezmůže.** Tabulka má tabulkový
`GRANT UPDATE` pro `authenticated`, takže `information_schema.column_privileges`
ukáže UPDATE u KAŽDÉHO sloupce a odebrat právo k jednomu z nich nejde. Skutečná
brána je whitelist v `guard_reservation_rep_changes` — kdo přidává sloupec, musí
myslet na něj, ne na granty. (První verze opravy přání trenéra tudy šla a
kontrola v migraci ji rovnou usvědčila.)

---

## 6e. Čekající účet neviděl nic? Viděl. (31. 8. 2026)

Před vypnutím potvrzování e-mailu jsem změřil, co doopravdy vidí účet, který se
zaregistroval a čeká na schválení. Ne úvahou nad politikami — dotazem pod
`SET LOCAL ROLE authenticated` s tokenem účtu, který v databázi nemá ani profil,
**na ostrých datech** (transakce se vrátila zpět):

| co | před | po |
|---|---|---|
| `reservations_calendar` | **80 řádků** — jména klubů i firem, názvy akcí, časy | 0 |
| `events` | **42 řádků** | 0 |
| `profiles`, `profiles_public`, `profiles_self` | **3 řádky** — jména všech lidí | 0 (vlastní řádek 1) |
| `settings_public` | 1 řádek | 0 |
| `reservations`, `subjects`, `cenik_pasma`, `shifts`, `reservations_billing`, `subjects_rates` | 0 | 0 |

**Peníze neunikaly** — částky jsou maskované, ceník i „Kdo dluží" vracely nulu
řádků. Unikal ROZVRH HALY VČETNĚ JMEN ZÁKAZNÍKŮ.

**Proč to blok C nechytil:** zavřel `has_role`, `is_subject_member`
a `is_subject_rep`, jenže tahle tři místa se RLS neptají — `events` a `profiles`
měly SELECT politiku `USING (true)` a čtyři pohledy běží se
`security_invoker = off`, tedy pod vlastníkem, kde RLS podkladových tabulek
nehraje roli.

**Proč to bylo naléhavé:** dokud Auth vyžaduje potvrzení e-mailu, musí útočník
aspoň ovládat schránku. Po vypnutí potvrzování znamená „kdokoli přihlášený"
doslova kdokoli — vyplní registrační formulář s vymyšleným e-mailem a čte.
Migrace `20260831235000_cekajici_ucet_nevidi_nic.sql` proto šla na produkci
**dřív, než se potvrzování vypne**.

**Co zůstává otevřené schválně:** `clubs_public` (id + název klubu) je čitelný
i nepřihlášeným — bez něj si člověk v registraci nevybere klub. A **vlastní
profil vidí i čekající účet**, jinak by `AuthContext` nezjistil `stav`
a místo věty „Čeká se na potvrzení" by naskočilo „Profil se nepodařilo načíst".

Rozhodnutí klienta z 31. 7. („obsazenost a název klubu vidí všichni přihlášení")
platí dál — jen se upřesnilo, že „přihlášený" znamená vpuštěný dovnitř, ne
kdokoli, kdo prošel registračním formulářem.

Testy: `supabase/tests/cekajici_ucet_test.sql` (34 tvrzení, celé pod
`SET LOCAL ROLE authenticated`). Ověřeno mutací: bez brány v pohledu čte
čekající účet 36 řádků kalendáře a test zčervená.

### Past, na kterou to narazilo

`settings_public` se čte i **bez přihlášeného uživatele** (pg_cron, Edge funkce
sahající na pohled). Holá brána `WHERE ucet_aktivni()` mu vrátila nula řádků
místo řádku s maskovanými sazbami a shodila `cenik_viditelnost_test.sql`.
Řeší to výjimka pro běh pod databázovou rolí — týž vzorec, jaký má
`billing_reconcile`: `auth.uid() IS NULL AND session_user IN ('postgres',
'supabase_admin')`, ne holé `auth.uid() IS NULL` (to by z chybějícího `sub`
v tokenu udělalo klíč).

### Dvě věci pro PM

1. **Potvrzování e-mailu je pořád ZAPNUTÉ** (`mailer_autoconfirm: false`)
   a z Claude Code se vypnout nedá: platformní API vrací pro
   `fcwubbytqxubgptftnru` `403 „Your account does not have the necessary
   privileges"` (pro demo tentýž příkaz projde) a nastavení žije v konfiguraci
   GoTrue, ne v databázi. Musí to cvaknout Tomáš v dashboardu.
2. **Na produkci leží OSIŘELÝ profil** `ed63db05…` ve stavu `ceka`: nemá
   `full_name`, nemá žádost o klub a hlavně **nemá záznam v `auth.users`**
   (ověřeno `LEFT JOIN` oběma směry — v `auth.users` jsou jen dva účty, oba
   `aktivni` a s potvrzeným e-mailem). Není to tedy čekající člověk, ale zbytek
   po smazaném účtu nebo po ručním vložení. Přihlásit se pod ním nejde a ve
   frontě `/requests` se neobjeví. Škodí jen tím, že kazí počty — smazat ho
   smí jen člověk, který ví, odkud je.

   ⚠️ Až se potvrzování e-mailu vypne, hlídej první REÁLNOU registraci: člověk,
   který se zaregistruje **bez vybraného klubu**, žádost nevytvoří, takže se
   nikomu neobjeví ve frontě — a doplnit si klub sám nemůže, protože na Profil
   se čekající účet nedostane. Dnes to rozsekne jen admin ručně. Jestli se to
   má stávat běžně, patří na čekací obrazovku výběr klubu; to je ale
   rozhodnutí, ne oprava.

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

1. **Záloha produkční DB** — `scripts/safe-deploy.sh <popisek>`. Dump si sám ověří
   velikost i celistvost a při chybě `db push` vůbec nepustí. Ruční `db push`
   znamená, že jsi zálohu obešel.
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

### Jak se ostrá fakturace SKUTEČNĚ zapne (2. 9. 2026)

Až skončí první komerční akce. Do té doby není co fakturovat — k 2. 9. 2026 jsou
všechny akce na produkci v budoucnu.

**1. Klíče patří do Supabase secrets, ne do `.env`.** Ostrý doklad vystavuje
**Edge funkce `fakturoid-invoice`**, protože jediná čte produkční databázi.
`scripts/fakturoid-akce.ts` čte přes `supabase status` z **lokálního Dockeru** —
spustit ho s ostrými klíči znamená poslat na účet haly seedová testovací data.
Lokální `.env` je proto na vývoj, ne na cutover.

```
supabase secrets set --project-ref fcwubbytqxubgptftnru \
  FAKTUROID_SLUG=<ostrý účet> \
  FAKTUROID_POVOLENY_UCET=<týž ostrý účet> \
  FAKTUROID_CLIENT_ID=… FAKTUROID_CLIENT_SECRET=… \
  FAKTUROID_USER_AGENT='CurlingPromo (kontakt@email)' \
  IS_VAT_PAYER=true FAKTUROID_MODE=koncept FAKTUROID_LIVE=true
```

`FAKTUROID_POVOLENY_UCET` se musí rovnat `FAKTUROID_SLUG` — je to schválně
opisování podruhé, aby překlep ve slugu doklad neposlal cizímu účtu.
`IS_VAT_PAYER` musí sedět s `billing_settings.vat_mode` (dnes `platce`), jinak
se doklad nevystaví. Prázdno je chyba, ne „neplátce".

**2. Doklad je ve Fakturoidu rovnou OSTRÝ.** Fakturoid stav „koncept" nezná
(kapitola 5) — `POST /invoices.json` založí plnohodnotný doklad s číslem
v ostré řadě. Náš `FAKTUROID_MODE=koncept` znamená jen „neposílat e-mail".
**Vystavení je tedy vědomý úkon, ne náhled.** Omyl se neopravuje smazáním, ale
stornem nebo dobropisem. Kdo si chce jen prohlédnout, jak doklad vypadá, ať to
udělá na testovacím účtu — mapování, řádky i zaokrouhlení jsou tytéž.

**3. Pořadí.** Jedna skončená komerční akce → zkontrolovat odběratele, řádky
a součet → teprve pak další. Po prvním dokladu ověřit, že
`billing_reconcile(…)` má `fakturoid_rozdil = 0` a že se rezervace odečetly
z `k_fakturaci`. `FAKTUROID_MODE=odeslat` až po týdnu a až budou mít subjekty
vyplněný e-mail (jinak Fakturoid vrátí 422).

**4. Netlify env s tím nemá nic společného** — to je jen pro frontend
(`VITE_*`). Fakturoidí tajemství tam nepatří.

### Co se od vlny B (2. 9. 2026) změnilo na samotném cutoveru

Přepnout `FAKTUROID_SLUG` na ostrý účet **už nestačí** — zápis skončí
odmítnutím. Ostrý účet se musí navíc výslovně vypsat:

```
FAKTUROID_LIVE=true
FAKTUROID_SLUG=<ostrý účet>
FAKTUROID_POVOLENY_UCET=<týž ostrý účet>   # druhé, nezávislé potvrzení
IS_VAT_PAYER=true                          # prázdno je nově CHYBA, ne „neplátce"
```

`IS_VAT_PAYER` se před každým vystavením porovná s `billing_settings.vat_mode`;
když se rozejdou, doklad se nevystaví. To je pojistka proti tomu, aby se ta
„TŘI MÍSTA, JEDEN OKAMŽIK" z bodu 4 rozpadla na dvě a jedno.

**Cutover dělá člověk, ne skript** — klíče do Supabase secrets, kontrola, že
účet ve Fakturoidu je veden jako plátce, a teprve pak první doklad v režimu
`koncept`.
