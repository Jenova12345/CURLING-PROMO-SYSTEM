# Etapa 2 — Fakturace · STAV

**Aktualizováno:** 13. 8. 2026 · **Větev:** `dev` · **HEAD:** `87b1f78`

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
npx vitest run                              73 unit testů (money, iban)
```

Spouštění SQL testů:
`docker exec -i supabase_db_ltrazktulfxvzlvkxdsb psql -U postgres -X -q -v ON_ERROR_STOP=1 < <soubor>`

**Poučení, které stálo nejvíc času:** testy práv se MUSÍ psát pod `SET LOCAL ROLE
authenticated`. Jako `postgres` projde všechno (obchází granty i RLS) a test pak
tvrdí zavřeno o dveřích, vedle kterých je otevřené okno. Dvakrát to takhle
propustilo blokér.

---

## 2. Rozpracováno — co dělat dál, v tomhle pořadí

### Nejdřív: strop sazby (rozhodnutí PM čeká na implementaci)

Drift **8g**: `rate_per_hour` nemá horní mez, takže je to jediný neomezený peněžní
vstup v systému — `99999999 Kč/h` projde. **PM rozhodl: strop 50 000 Kč/h.**
Rozhodnutí padlo, **kód ještě ne.** Vzor je hotový vedle (A5, korekce hodin):
CHECK + srozumitelná hláška v `check_reservation_money`.

### B5-subset + B6 — RPC a kontrolní součet

- `create_invoice_draft_club(subject_id, obdobi_od, obdobi_do)` — měsíční souhrn,
  **řádek = jedna rezervace**
- `create_invoice_draft_commercial(event_id)` — za akci
- `issue_invoice(invoice_id)` — přidělí číslo atomicky, doplní snapshoty
- `billing_reconcile(od, do)` — **kontrolní součet: suma faktur == „Kdo dluží"**

**B6 nevynechávat ani pod tlakem.** Je to jediný způsob, jak poznat, že modul
počítá správně; bez něj je zbytek jen hezky vypadající obrazovka.

Zdroj dat: táž logika jako „Kdo dluží" (`reservations_billing`), ale **běh musí
číst základní tabulky, ne ten view** — má v sobě `has_role(auth.uid(), 'admin')`
a pod cronem/service_role vrátí nula řádků (nález N4). Fakturují se **jen schválené
rezervace** (`billing_settings.invoice_only_approved`).

Ceny se berou ze snapshotu na rezervaci (`rate_per_hour`, `corrected_amount ?? amount`),
nikdy se nepočítají znovu z ceníku.

**Nutná mechanika, na kterou se přijde jinak až za běhu:** do vystavené faktury
nejde vložit položku (guard to blokuje). RPC musí jít cestou *založ koncept →
naplň položky → jedním UPDATE nastav `status` + `cislo` + `datum_vystaveni`*.
Ten poslední UPDATE projde jen proto, že `OLD.status = 'koncept'`.

Zápis do `reservations.invoice_id` jde jen z RPC — guard ho jinak odmítne i adminovi.
RPC si musí nastavit `app.trusted_booking`, jako to dělají rezervační funkce.

### E1-lite — stránka Faktury

Seznam + detail + tlačítko „Vygenerovat fakturu" u subjektu a v „Kdo dluží".

### C-subset — PDF s QR (SPAYD)

`pdf-lib` v Edge funkci, font se musí subsetovat (Noto Sans, diakritika).
**Fallback, kdyby došel čas:** doklad na obrazovce k tisku do PDF — základ existuje
v `src/lib/invoiceDraft.ts` a už dnes používá správnou peněžní politiku.

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
| Sazba | **Strop 50 000 Kč/h** — ⚠️ rozhodnuto, ale **ještě neimplementováno** (drift 8g) |
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
- **`supabase/config.toml` neurčuje cíl `db push`.** Ten se bere z nalinkovaného
  projektu (`supabase/.temp/linked-project.json`). Soubor `project-ref` tenhle CLI
  nezakládá.
- **Dlouhé SQL funkce nikdy nepřepisuj ručně.** Generuj je z `pg_get_functiondef`
  a vkládej jen ten zásah, který děláš — jednou jsem to zkusil z paměti a utnul
  půlku guardu (`87b1f78`).
