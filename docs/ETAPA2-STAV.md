# Etapa 2 — Fakturace · STAV

**Aktualizováno:** 13. 8. 2026 (odpoledne) · **Větev:** `dev` · **HEAD:** `3a5119b`

Předávací dokument. Kdo přebírá práci, ať čte tohle první — pak
`docs/etapa2-fakturace-plan.md` (rozhodnutí R1–R11, otázky Q1–Q7)
a `docs/etapa2-fakturace-spec.md` (zadání od klienta).

---

## 0. Kam to celé míří (páteční cíl)

**Jedna svislá funkční věc na demo: ruční „faktura na klik".** Admin ji vygeneruje
u subjektu nebo v „Kdo dluží", zkontroluje, vystaví a stáhne. Klient to má přes
víkend proklikat.

Rozsah je záměrně úzký (rozhodnutí PM 13. 8. 2026): **režim neplátce DPH**, bez
dobropisů, bez automatiky, bez evidence plateb. Nejde o to mít hotovou fakturaci,
ale o jednu cestu od začátku do konce, na kterou se dá sáhnout.

---

## 1. Hotovo

Fáze A je celá hotová, každý PR prošel svými bránami (code review + bezpečnost/RLS
+ kontrola migrací). Brány blokovaly u **šesti z devíti** PR — nálezy jsou popsané
v commit messages, které jsou pro tenhle projekt zásadní čtení.

| PR | Commit | Co přineslo |
|---|---|---|
| A1 | `fe4c5fe` | Jedna peněžní politika (`src/lib/money.ts`) místo tří rozesetých |
| A1b+A1c | `70b75d0` | Vitest + `money.test.ts`, SQL testy JS proti živému Postgresu |
| A1d | `73010c3` | R3 sjednoceno na **stupňovitou kvantizaci** jako kanonické pravidlo |
| A2 | `72904c0` | Sazby v celých korunách, korekce po čtvrthodinách (CHECKy + trigger) |
| A2b | `1de3c53` | Ceník a sazby subjektů vidí jen admin |
| A3 | `fbd6282` | `billing_settings` (singleton, admin-only, audit) |
| A4 | `25a34d0` | UI Nastavení → Fakturace, dopočet IBANu (mod-11 + mod-97) |
| A5 | `378002d` | Bezpečnostní zpevnění před fází B (drift 8b–8f) |
| B1+B2 | `bd99848`, `87b1f78` | Základ dokladu: číselná řada, `invoices`, `invoice_items`, immutabilita |
| Strop sazby | (viz git log) | Drift 8g uzavřen: 50 000 Kč/h na všech čtyřech zdrojích sazby |
| B5+B6 | (viz git log) | RPC „faktura na klik" + **kontrolní součet** `billing_reconcile` |
| E1-lite | (viz git log) | Stránka Faktury, tlačítko v „Kdo dluží", tisk dokladu |

### Co z toho stojí za zapamatování

**Kanonické pravidlo zaokrouhlení (R3):** `částka k úhradě = round(round(v, 2), 0)`,
nikdy `round(v, 0)` ze surové hodnoty. Účetní důvod: základ daně musí být určité
dvoudesetinné číslo. Obě strany (JS i SQL) to musí dělat stejně — hlídá to
`scripts/overit-zaokrouhleni.ts` (`npm run overit:zaokrouhleni`) proti živé DB.

**Kontrolní součet je autorita.** `total` (přesný), ne `total_rounded`. Sčítat
zaokrouhlené částky k úhradě nasčítá drift `±N/2 Kč`.

**Číslo faktury se přiděluje až při vystavení**, ne konceptu — smazaný koncept by
jinak udělal v řadě díru. Počítadlo je tabulka, ne sekvence (`nextval` je
netransakční a při rollbacku číslo nevrátí).

### Testy

```
supabase/tests/zaokrouhleni_test.sql        peněžní politika, JS ↔ numeric
supabase/tests/cenik_viditelnost_test.sql   kdo vidí sazby
supabase/tests/billing_settings_test.sql    fakturační nastavení, audit
supabase/tests/security_hardening_test.sql  A5 — plošné kontroly práv
supabase/tests/rezervace_test.sql           původní rezervační sada (85 tvrzení)
supabase/tests/strop_sazby_test.sql         strop 50 000 Kč/h (19 tvrzení)
supabase/tests/fakturace_test.sql           B5+B6 — doklad a kontrolní součet (81 tvrzení)
npx vitest run                              89 unit testů (money, iban, spayd)
```

Spouštění SQL testů:
`docker exec -i supabase_db_ltrazktulfxvzlvkxdsb psql -U postgres -X -q -v ON_ERROR_STOP=1 < <soubor>`

**Poučení, které stálo nejvíc času:** testy práv se MUSÍ psát pod `SET LOCAL ROLE
authenticated`. Jako `postgres` projde všechno (obchází granty i RLS) a test pak
tvrdí zavřeno o dveřích, vedle kterých je otevřené okno. Dvakrát to takhle
propustilo blokér.

---

## 2. Rozpracováno — co dělat dál, v tomhle pořadí

### Hotovo v této session (13. 8. odpoledne)

**Strop sazby 50 000 Kč/h** — drift 8g uzavřen. CHECK je na **všech čtyřech
zdrojích** sazby (`reservations.rate_per_hour`, `subjects.default_rate`, čtyři
sloupce ceníku), ne jen na rezervaci: sazba se do rezervace dopočítává z ceníku,
takže strop jen tam by šlo obejít zápisem do ceníku a projevilo by se to až
o krok dál. Frontend má tutéž mez v `SAZBA_STROP` (`src/lib/money.ts`).

**Mimochodem tím zmizela díra s `NaN`** a stojí za to o ní vědět, ať ji někdo při
případném revertu nevrátí zpátky: v Postgresu je `'NaN'::numeric >= 0` **true**
a `'NaN' <> round('NaN')` **false**, takže `NaN` prošla úplně všemi peněžními
kontrolami z A2 i A5 a uložila by se jako sazba — a `amount` by pak byl `NaN`
u každého dopočtu. Chytí ji až porovnání se stropem. Hlídá to vlastní tvrzení
v `supabase/tests/strop_sazby_test.sql`.

**B5 + B6** — `20260813140000_faktury_rpc.sql`, `20260813160000_billing_reconcile.sql`:
`create_invoice_draft_club` / `_commercial`, `issue_invoice`, `delete_invoice_draft`,
`nevyfakturovane_akce`, `fakturovatelne_rezervace`, `obdobi_hranice`,
pohled `invoices_list`; `billing_reconcile` + pohled `billing_health`.

**E1-lite** — stránka `/invoices` (seznam, detail, vystavit, zahodit koncept),
tlačítko „Vygenerovat fakturu" v „Kdo dluží" (klub za období, firma přes dialog
s akcemi), tisk dokladu `src/lib/invoicePrint.ts`.

**SPAYD** — `src/lib/spayd.ts` + testy. Řetězec QR platby ano, **obrázek zatím ne**
(chybí QR enkodér, viz „Co zbývá").

#### Co si z toho zapamatovat

**Kontrolní součet je rozpad, ne rovnost.** Platí
`dluzi = fakturovano + v_konceptu + k_fakturaci + neschvalene`, a sloupec `rozdil`
musí být 0. Prostá rovnost „faktury == dluží" nastane až v okamžiku, kdy je
vyfakturované všechno — rozpad na čtyři sloupce říká i **proč** se to zrovna nerovná.

**Obě strany rovnice se schválně počítají z jiného místa:** fakturovaná částka
z uloženého `invoice_items.line_total`, dluh z aktuální částky rezervace. Kdyby
braly ze stejného, sedělo by to vždycky a nezjistilo nic — takhle to odhalí i
nález N1 (dodatečnou změnu už vyfakturované rezervace). Test to ověřuje tak, že
změnu **provede** a čeká rozdíl 1 000 Kč.

**Mechanika, na kterou by se jinak přišlo až za běhu** (a je zadrátovaná v RPC):
do vystavené faktury nejde vložit položku, takže cesta musí být *založ koncept →
naplň položky → jedním UPDATE nastav stav, číslo a datum*. Ten UPDATE projde jen
proto, že `OLD.status = 'koncept'`. Zápis do `reservations.invoice_id` guard
odmítne i adminovi, proto si RPC nastavují `app.trusted_booking`.

**Snapshot dodavatele se dělá až při vystavení**, ne u konceptu — doklad je obraz
stavu v okamžiku vystavení. Ověřeno testem: změna nastavení po vystavení už
doklad nepřepíše.

**Demo má předvyplněné fakturační údaje** (`supabase/demo/99_finalize_demo.sql`),
protože bez nich se `issue_invoice` správně zastaví na „chybí IČO dodavatele" a
cesta k dokladu se nedá proklikat. Jsou zjevně vymyšlené (IČO 12345678) a plní se
**jen v demo skriptu**, ne v seedu a ne v migraci.

### Co zbývá

**QR platba na dokladu.** `spayd.ts` umí řetězec, chybí z něj udělat obrázek —
a v repu není QR enkodér. Buď nová (drobná) frontendová závislost, nebo vlastní
enkodér, nebo QR až se serverovým PDF (C4). **Rozhodnutí PM.**

**C-subset (PDF přes `pdf-lib` v Edge funkci)** zůstává neudělaný; fallback
„tisk z obrazovky" funguje a používá snapshot z faktury, ne `BRAND`.

**Dobropisy, storno, evidence plateb, automatika** — vědomě odložené (viz níž).

### Odloženo (vědomě, rozhodnutí PM)

Automatika (D), dobropisy a storno, evidence plateb (E2), měsíční cron,
agregace DPH (Q7).

---

## 3. Rozhodnutí PM — platná, nepřerozhodovat

| Věc | Rozhodnutí |
|---|---|
| Režim DPH | **Neplátce** jako default (`billing_settings.vat_mode`) |
| Měsíční běh | **1. den následujícího měsíce v 06:00**; `monthly_run_day = 0` znamená „poslední den v měsíci", aby klientova původní varianta zůstala dosažitelná `UPDATE`em |
| Q4 — co se fakturuje | **Jen schválené rezervace** (`invoice_only_approved = true`). Pozor: je to OPAK doporučení, které u Q4 stojí v plánu — to zůstalo jen jako zápis úvahy |
| Číslo faktury | `RRRRNNNN`, jedna společná řada, prefix souborů `curling`, splatnost 14 dní |
| Automatika | `automation_enabled = false`, `auto_issue = false` (režim náběhu: první měsíc jen koncepty) |
| Korekce hodin | **Tvrdý strop 24 h**, NEvázaný na délku rezervace — musí zůstat možné naúčtovat víc, než bylo rezervováno (klub zůstal o půl hodiny déle). Povinný `correction_reason` |
| Sazba | **Strop 50 000 Kč/h** — ✅ implementováno 13. 8. 2026 na všech čtyřech zdrojích sazby (drift 8g uzavřen) |
| R11 | Každá `SECURITY DEFINER` funkce nad `billing_settings` musí dusit chyby constraintů — jinak PostgREST pošle klientovi celý řádek i s IBANem. **Platné pravidlo pro fázi B** |
| Commitování | Commit po každém PR, který prošel bránami. Push a merge zůstávají na vyžádání |

### Pořád otevřené (nerozhodovat sám)

- **Q7 — agregace DPH** (po řádcích vs. z mezisoučtu za sazbu). Změřeno: liší se
  u 54,5 % dokladů, u 0,6 % i o celou korunu na částce k úhradě. **Patří účetní
  klienta.** Blokuje jen plnou DPH podporu, ne tenhle slice — sloupce `vat_*`
  v `invoice_items` jsou zatím prázdné místo, ne rozhodnutí.
- Otázky pro účetní z plánu, kapitola 5 (sazba u pronájmu ledu, osvobození
  u spolku, tvar dobropisu).
- Netlify `VITE_SUPABASE_URL` — nastaví Tomáš, potřeba až před ostrým nasazením.

---

## 4. Stav demo (`ltrazktulfxvzlvkxdsb`)

**Demo je pozadu o celou Etapu 2.** Ověřeno čtením přes MCP: nemá `billing_settings`
ani typ `vat_mode`, a **vůbec tam neexistuje tabulka migrační historie**
(`supabase_migrations.schema_migrations`), takže CLI tam žádné migrace neeviduje.

Chybí: **A2, A2b, A3, A4, A5, B1+B2.**

Prakticky to znamená, že migrace faktur by tam dnes spadla hned na
`CREATE TABLE invoices` (neexistující typ `vat_mode`).

### ✅ Schválený další krok (PM, 13. 8. 2026)

**Nasazení na demo dělá Claude Code, přes `scripts/build-demo-sql.sh`.**
Reset schématu je v pořádku — **na demu nejsou žádné ostré faktury.**

Podmínky, které platí:
1. **Nejdřív čerstvá záloha.**
2. **Až v nové session po handoffu**, ne v té, která psala tenhle dokument.
3. Pořadí migrací se musí dodržet (A2 → A2b → A3 → A4 → A5 → B1+B2).

#### Záloha pořízena 13. 8. 2026 → `backups/2026-08-13-demo/`

Data (250 řádků), auditní stopa, `schema.json` a výpis práv. Složka `backups/`
je v `.gitignore` (jsou tam čísla účtů), takže v repu ji nikdo nenajde — je na disku.

Dvě zjištění z ní, kvůli kterým je reset bezpečný a dají se doložit:

- **Nejnovější záznam v celé demo databázi je z 5. 8. 2026 10:15 UTC**, tedy
  z posledního běhu `demo_setup.sql`. Za osm dní do dema nikdo nic nezadal, takže
  reset nemaže žádnou lidskou práci.
- **Všech 5 účtů je seedových `@test.local`.** Žádný účet, který by si někdo
  založil sám a přišel by o profil a roli.

Zároveň je v záloze vidět, co nasazení opraví: `anon` i `authenticated` měly na
demu ještě plná práva `arwdDxtm` na `audit_log` a `reservations` (včetně TRUNCATE,
na který se RLS nevztahuje) — to odebírá až A5.

Pozor: `build-demo-sql.sh` začíná resetem schématu. **Jakmile na demu vzniknou
ostré faktury, tenhle postup přestane být použitelný** a musí ho nahradit
přírůstkový běh migrací (v plánu je to E6).

---

## 5. Čemu nevěřit a co si ověřit

Věci, které se v týhle codebase tvářily jinak, než jsou:

- **`npx tsc --noEmit` netypuje nic.** Kořenový `tsconfig.json` má `"files": []`
  a jen reference. Používej `npm run typecheck` (`tsc -b`).
- **`npm run lint` je červený už na HEADu** (66 errors z Etapy 1). Jako brána
  nefunguje — nový error od šumu nikdo nerozezná.
- **`SET LOCAL ROLE authenticated` NESTAČÍ na guardy, které se ptají na `session_user`.**
  Mění `current_user`, ale `session_user` zůstává `postgres` — takže test spadne do
  větve pro cron a tvrdí otevřeno tam, kde je zavřeno. Je to patro pod pravidlem 8
  v CLAUDE.md a chytilo to i mě: oprava `billing_reconcile` vypadala pod
  `psql -U postgres` pořád jako díra. Věrný kanál je přihlásit se jako
  `authenticator` (tak se připojuje PostgREST):
  ```
  docker exec -e PGPASSWORD=postgres -i supabase_db_<project> \
    psql -h 127.0.0.1 -U authenticator -d postgres
  ```
  Týmž způsobem se ukázalo, že pohled `billing_health` si jako pohled nepřečetl
  ani admin — pod `postgres` byl zelený.

- **`current_date` v databázi je UTC**, ne pražský. Projeví se to jednou za rok:
  1. ledna v 00:30 pražského času dostane doklad loňský rok v čísle. Fakturační
  kód proto počítá `(now() AT TIME ZONE 'Europe/Prague')::date`.

- **`supabase/config.toml` neurčuje cíl `db push`.** Ten se bere z nalinkovaného
  projektu (`supabase/.temp/linked-project.json`). Soubor `project-ref` tenhle CLI
  nezakládá.
- **Dlouhé SQL funkce nikdy nepřepisuj ručně.** Generuj je z `pg_get_functiondef`
  a vkládej jen ten zásah, který děláš — jednou jsem to zkusil z paměti a utnul
  půlku guardu (`87b1f78`).
