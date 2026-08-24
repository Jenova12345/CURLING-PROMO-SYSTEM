# `billing/` — fakturační providery

Vrstva mezi našimi rezervacemi a externím fakturačním systémem. První (a zatím
jediný) provider je **Fakturoid**; iDoklad nebo cokoli dalšího přibude jako nová
implementace `InvoiceProvider`, aniž se sáhne na jádro.

## Proč je to mimo `src/`

Do `src/` sahá Vite bundle. `FAKTUROID_CLIENT_SECRET` nesmí mít ani teoretickou
cestu do prohlížeče, a mimo `src/` se na tenhle kód nedostane ani `@/` alias —
takže ho nejde omylem importovat do komponenty. Je to strukturální pojistka,
ne dohoda.

Praktický dopad: `billing/` se typuje pod `tsconfig.node.json` (strict) a testy
si ho berou přes druhou položku v `vitest.config.ts` → `include`. Kdyby ta
položka zmizela, testy fakturace se přestanou spouštět — a ne červeně, ale
vůbec, což je horší.

## Co je uvnitř

| Soubor | Co dělá |
|---|---|
| `types.ts` | Smlouva `InvoiceProvider` + `InvoiceDraft`/`InvoiceResult`. Nezná Fakturoid. |
| `mapping.ts` | Rezervace → `InvoiceDraft` pro typ A (komerční akce) i B (měsíc klubu). |
| `idempotency.ts` | Klíče `akce-{eventId}` / `klub-{clubId}-{RRRRMM}` a zámek 1. |
| `pipeline.ts` | Oba zámky, pořadí kroků, smyčka kolem PDF 204. |
| `store.ts` | Port `InvoiceLinkStore` (vazba rezervace ↔ doklad) + paměťová implementace. |
| `format.ts` | Datum a čas na řádku dokladu — vždy v pražském čase. |
| `errors.ts` | Typované chyby a jediné místo, kde se rozhoduje o opakování. |
| `providers/mock.ts` | Provider pro testy a vývoj bez klíčů. |
| `providers/fakturoid/config.ts` | Načtení a validace `FAKTUROID_*` z prostředí. |
| `providers/fakturoid/http.ts` | Hlavičky, rate limit, překlad chyb. Vlastní typy místo DOM. |
| `providers/fakturoid/auth.ts` | OAuth `client_credentials` + cache tokenu. |
| `providers/fakturoid/index.ts` | `FakturoidProvider` — implementace `InvoiceProvider`. |

## Nastavení `.env`

Šablona je v kořenovém `.env.example`, sekce **Fakturoid**. Zkopíruj do `.env`
a vyplň:

```
FAKTUROID_SLUG=            # z URL: https://app.fakturoid.cz/<slug>/…
FAKTUROID_CLIENT_ID=       # Nastavení → API, grant client_credentials
FAKTUROID_CLIENT_SECRET=
FAKTUROID_USER_AGENT=      # POVINNÉ, jinak 400. Tvar: "CurlingPromo (kontakt@email)"
BILLING_DUE_DAYS=14
IS_VAT_PAYER=false
FAKTUROID_LIVE=false
FAKTUROID_TEST_SLUG=      # druhá pojistka, viz níž
```

`.env` i `.env.*` drží `.gitignore` (výjimka je jen `.env.example`), takže se
klíč nedá commitnout omylem. Zkontrolovat se to dá `git check-ignore -v .env`.

## Kam přijdou ostré klíče

**Ne do repa a ne do Netlify env.** `billing/` běží serverově, v Edge funkci —
klíče proto patří do **Supabase secrets** toho projektu:

```
supabase secrets set --project-ref <ref> \
  FAKTUROID_SLUG=… FAKTUROID_CLIENT_ID=… FAKTUROID_CLIENT_SECRET=… \
  FAKTUROID_USER_AGENT='CurlingPromo (kontakt@email)'
```

Netlify env je pro frontend, tedy pro veřejné hodnoty (`VITE_*`). Kdyby se
`FAKTUROID_CLIENT_SECRET` dostal tam, byl by v bundlu u každého návštěvníka.

Ostré klíče nastavuje Tomáš. Dokud nejsou, běží unit testy s mockem — což je
většina hodnoty, protože ověřují naši rozhodovací logiku, ne cizí API.

## Spuštění testů

```bash
npx vitest run billing/          # jen fakturace (unit, bez sítě)
npx vitest run                   # celé repo (src/ + billing/)
npm run typecheck                # tsc -b (POZOR: `npx tsc --noEmit` netypuje nic)
```

Integrační testy proti testovacímu účtu:

```bash
FAKTUROID_LIVE=true npx vitest run billing/providers/fakturoid/fakturoid.integration
```

Bez `FAKTUROID_LIVE=true` se **přeskočí**, nespadnou — vývojář bez klíčů má mít
zelenou sadu, ne červenou, kterou se naučí ignorovat. Založí na testovacím účtu
jednoho odběratele a jeden doklad na běh, s `custom_id` začínajícím `test-`.

**`FAKTUROID_LIVE=true` samo nestačí.** Musí se navíc do `FAKTUROID_TEST_SLUG`
opsat slug účtu, na který se smí psát, a musí sedět s `FAKTUROID_SLUG`. Kdo tu
nechá produkční slug z minulého týdne a zapne `LIVE`, vystaví tímhle souborem
**reálné doklady v ostré číselné řadě** — ty nejdou smazat, jen dobropisovat,
a číslo v řadě zůstane navždy. Opsat slug je vědomý úkon; zapomenout vypnout
`LIVE` je nehoda. Když `LIVE` běží bez potvrzeného účtu, sada **spadne**,
netiše přeskočí — tichý skip by vypadal jako „testy prošly".

`billing/` má nakonec běžet v Edge funkci (PR 4), takže musí projít i Denem.
**Pozor na past:** v kořeni repa `deno check billing/…` spadne na třech falešných
chybách (`setTimeout`, `TextEncoder`), protože tam Deno najde `package.json`
a přepne se do Node-compat režimu bez webových API. Věrný běh je s konfigem
Edge funkcí:

```bash
deno check --config supabase/functions/deno.json billing/**/*.ts
```

Takhle je zelený. Kdo si to pustí bez `--config`, přečte si to jako rozbitý kód.

**`npm run lint` není brána** — je červený už na HEADu (66 errors z Etapy 1),
takže nový error od šumu nikdo nerozezná. Brána je `npm run typecheck`; chytil
mimo jiné špatně typovaný mock v `pipeline.test.ts`, který testy propustily zeleně.

## Pravidla, která tahle vrstva drží

**Číslo a variabilní symbol NEPOSÍLÁME.** Přiděluje je provider. `InvoiceDraft`
na ně nemá pole a je to schválně.

**Mapování si nevymýšlí vlastní filtr „co je zpoplatněné".** Jediná definice
v repu je `public.fakturovatelne_rezervace` a používá ji i kontrolní součet
`billing_reconcile`. Kdyby si tahle vrstva opsala vlastní podmínku, porovnával
by kontrolní součet dvě různá čísla a vypadalo by to jako chyba ve fakturaci.
Interní tréninky a údržba ledu vypadávají tam, kde vypadávají dnes — nemají
`subject_id`.

**Posílá se sazba a hodiny, ne hotová částka.** Provider si `quantity × unitPrice`
přepočítá sám; naše `castka` je `round(hodiny × sazba, 2)` (trigger v DB i CHECK
`invoice_items_radek_sedi`), takže obojí musí vyjít nastejno. `overRadek` to
ověřuje, aby se případný rozchod ozval u nás, ne až na dokladu u klienta.

**Prázdný doklad se nevystavuje.** Klub bez zpoplatněných rezervací za měsíc je
normální stav, ne chyba — a doklad na nula korun je pro účetní horší než žádný.

**Zápis se neopakuje nikdy — ani po 5xx, ani po 401, ani po výpadku sítě.** 500 neříká „nestalo se nic", ale „nevím, jak to
dopadlo" — Fakturoid mohl doklad založit a spadnout až při skládání odpovědi.
Retry by vystavil druhý doklad, protože `custom_id` u Fakturoidu není unikátní
klíč, jen naše značka. Správná cesta po selhaném POSTu je nechat ho spadnout
a spolehnout se na zámek 2 v příštím běhu. 429 se naopak opakuje vždycky:
znamená „odmítnuto, nezpracováno". Rozhoduje o tom `smiSeOpakovat` v `http.ts`,
a platí to i pro opakování po 401 a pro odmítnutý `fetch` (`ECONNRESET`) —
u čtení se opakují, u zápisu ne.

Na úrovni CELÉHO vystavení se naopak opakovat smí (`lzeOpakovat` vrací `true`
pro 5xx i síťovou chybu). Je to bezpečné **jen díky zámkům 2 a 3**: nový běh se
nejdřív zeptá, jestli doklad nevznikl, a porovná jeho řádky s dnešním podkladem.
Kdyby některý z těch zámků padl, změní se to `true` v duplicitní fakturu.

⚠️ **`lzeOpakovat` NENÍ povolení zopakovat `createInvoice` napřímo.** Chyba
z neúspěšného zápisu nese příznak `zapisNejisty` (čte se přes `jeZapisNejisty`):
doklad mohl vzniknout a provider spadnout až při skládání odpovědi. Fronta
v PR 4 smí opakovat jen celé `vystavDoklad`.

**Chybová těla se začerňují parsováním, ne regexem.** `"[^"]*"` neumí escapovanou
uvozovku, takže na názvu `Firma "ABC" s.r.o.` — a ty z ARESu chodí — začerní jen
první půlku, do logu pustí zbytek a rozbije JSON; nekvotované hodnoty (`{"zip":70800}`)
mine úplně. `zkrat` proto tělo **parsuje a prochází rekurzivně**, a když se
rozparsovat nedá, do chyby ho nedá vůbec: neznámý tvar nejde spolehlivě začernit.

**Zámek 2 se čte DVAKRÁT — před claimem i po něm.** Mezi prvním dotazem
a claimem je okno, kterým projde duplicita: běh A i B projdou zámkem 2 (oba
null), B se zdrží na 429 (čeká se podle hlavičky až minutu), A mezitím zabere
claim, POSTne doklad, Fakturoid ho **založí** a spadne na 5xx při skládání
odpovědi → A claim správně uvolní (neví, jak to dopadlo) → B claim dostane
a POSTne druhý doklad. Jeden GET navíc to okno zavře celé.

**Tři zámky, ne dva.** Zámek 1 (lokální, bez sítě) chytí, že rezervace už doklad
nese; zámek 2 (dotaz k providerovi před POSTem) chytí doklad, který vznikl, ale
odpověď se ztratila. Oba jsou ale jen ČTENÍ — když cron a admin kliknou ve stejnou
vteřinu, projdou jimi oba běhy. Teprve zámek 3 (`zkusZabrat`, atomický claim)
je rozhodne. Nad databází to musí být jeden atomický příkaz, ne „SELECT, a když
nic, tak INSERT" — vzor je `UPDATE … WHERE invoice_id IS NULL RETURNING`
v `create_invoice_draft_club`.

**Nalezenému dokladu se nevěří naslepo — a porovnávají se ŘÁDKY, ne částka.**
Když zámek 2 doklad najde, vznikl ze VČEREJŠÍCH rezervací, ale vazba by se
zapsala na dnešní `sourceReservationIds`: rezervace, která mezitím přibyla,
by se označila za vyfakturovanou, ačkoli na dokladu není, a už nikdy by se
nevyfakturovala.

Porovnávat jen součet tu nestačí, a selhalo by to přesně v normálním provozu:
klub trénuje týdně za stejnou sazbu, takže doklad na rezervaci „a" a doklad
na rezervaci „b" mají **tutéž částku**. Popis řádku nese datum a čas, takže
rezervace rozliší. Při rozdílu se vrací stav `nesedi` a **vazba se nezapíše** —
rozdíl patří člověku, ne automatice. Bez řádků od providera se spadne na
slabší kontrolu částkou (tolerance 0,50 Kč).

**Kontrolní součet se ověřuje i po vystavení.** Co jsme poslali == co provider
vytiskl. Rozpor se vrací jako `varovani` na výsledku; doklad už existuje, takže
ho nejde vzít zpět, ale **tichý rozpor u peněz je horší než hlasitý**. PR 4 ho
musí někam vypsat.

**PDF nesmí shodit vystavení — a dobírá se `dobirPdf`, ne dalším během.**
Výjimka při stahování (429, výpadek sítě, plné úložiště) by shodila celé
`vystavDoklad`, ačkoli vazba je v tu chvíli už zapsaná. Doklad má číslo a platí
i bez PDF; stahování je dobírání, ne vystavování. Důvod selhání se vrací
ve `varovani`, nespolkne se.

Pozor na past, kterou tu měl dřív komentář: „PDF dobere další běh fronty"
**nepopisovalo žádnou existující cestu**. Jakmile vazba existuje, `vystavDoklad`
se zastaví hned na `najdiPodleKlice` a k PDF se nedostane. Proto je tu
`dobirPdf(link, …)` jako samostatný vstupní bod — PR 4 ho zavolá pro vazby
bez `pdfPath`.

**Doklad na nula korun se nevystavuje.** Sazba 0 na jednotlivém řádku je platná
(hodina zdarma uvnitř placeného dokladu), celý doklad na nulu ne — automatika
v repu to má stejně (`amount > 0` v `automatika.sql`).

## Odloženo vědomě

**Tvar hlavičky rate limitu není ověřený.** Přesnou podobu, kterou Fakturoid v3
posílá u 429, jsme neviděli na živé odpovědi. `prodlevaPoLimitu` proto čte tři
podoby (`Retry-After`, `X-RateLimit-Reset`, parametrické `X-RateLimit: …; t=42`)
a když nesedí ani jedna, spadne na exponenciální backoff. **Ověřit při prvním
živém 429** a zúžit. Do té doby je to odolnost, ne znalost.

**Timeout požadavků (`AbortController`).** `http.ts` nemá horní mez čekání, takže
zaseknuté spojení drží Edge funkci až do jejího vlastního limitu. Zvyšuje to
četnost stavu „doklad vznikl, ale odpověď se ztratila". Riziko je dnes ohraničené
zámkem 2 a claimem, ale bez timeoutu se do něj chodí častěji. **Follow-up PR.**

**Chybové hlášky ven ke klientovi.** `mapping.ts` dává do zprávy sazbu a částku,
což jsou podle CLAUDE.md údaje jen pro admina a autora. Uvnitř Edge funkce to
vadit nemůže, ale **PR 4 nesmí surové chyby této vrstvy posílat klientovi** —
musí je přeložit na obecnou hlášku a podrobnost nechat v logu.

**Fakturoid je nový zpracovatel osobních údajů.** Posílají se mu údaje odběratelů
(název, IČO, DIČ, sídlo). Patří k tomu zpracovatelská smlouva a záznam o činnostech
zpracování. **Pro PM, ne pro kód.**

## Otevřené věci

**D1 — cílový stav (čeká na potvrzení s klientem).** Pracovní směr je **S1**:
Fakturoid je výstupní kanál, naše doklady zůstávají zdroj pravdy. Dokud to není
potvrzené, `billing/` persistuje přes port `InvoiceLinkStore` s paměťovou
implementací a **nesahá na migrace ani na `reservations.invoice_id`**.

Jediné místo, kde se D1 projeví, je význam `jeVyfakturovana` v `store.ts`:
- **S1** — „už má interní doklad" ≠ „nemá jít do Fakturoidu"; ptát se musí na
  vazbu k **provideru**.
- **S2** — interní a providerská vazba splývají.

Paměťová implementace odpovídá „tahle fakturační cesta už to poslala", což platí
ve všech variantách — proto na D1 nesahá a nefixuje ji.

**Follow-up: strukturovaná adresa z ARESu.** `subjects.address` je jeden textový
řádek, protože `ares-lookup` bere z ARESu jen `sidlo.textovaAdresa` a zbytek
zahazuje. Fakturoid přitom umí `street`/`city`/`zip` zvlášť. Rozšířit
`supabase/functions/ares-lookup/index.ts`, aby si držel `sidlo.nazevUlice`,
`sidlo.cisloDomovni`, `sidlo.nazevObce` a `sidlo.psc`, přidat sloupce na
`subjects` a doplnit mapování. **Samostatný PR, ne teď** (rozhodnutí 24. 8. 2026).
Do té doby jde celá adresa do `street` a `city`/`zip` zůstávají prázdné.

**Zaokrouhlení celkové částky — ZATÍM NEZMĚŘENO.** Fakturoid si částku k úhradě
zaokrouhluje sám a jeho pravidlo nemusí být naše `round(round(v, 2), 0)`
(rozhodnutí R3). Rozdíl může být do 0,50 Kč na doklad.

Test to **změří a vypíše deltu**, nepřekrývá ji:

```
[ZAOKROUHLENÍ] přesný součet 3751.53 Kč · naše k úhradě 3752 Kč ·
               Fakturoid <X> Kč · DELTA <±Y> Kč na doklad
```

Fixtura je schválně ta, na které se to má projevit (3 × 1 250,505 Kč — přesně
případ, na kterém se v Etapě 2 rozešla obrazovka s dokladem). Do 0,50 Kč test
propustí (rozdíl pravidla), nad 0,50 Kč spadne — tam už je špatně mapování,
sazba nebo počet řádků, ne zaokrouhlení.

**Změřit to jde až proti testovacímu účtu**, tedy až budou klíče. Podle výsledku
se buď nastaví zaokrouhlení na účtu Fakturoidu, nebo se to zapíše jako známá
odchylka. Do té doby je to otevřená otázka, ne vyřešená věc.
