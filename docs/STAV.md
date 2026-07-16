# STAV — převzetí aplikace „Mladé kameny"

Zjištěno průzkumem repozitáře ke dni **11. 7. 2026**, commit `51e5e21` („Přidán slot sync do updateEvent").
Dokument je čistě popisný — nic v kódu ani v databázi nebylo měněno.

**Jedna věta na úvod:** aplikace je funkční interní systém pro směny brigádníků a kalendář ledu,
ale **migrace v repu nesouhlasí s databází v cloudu** a **rezervační systém ledu zatím vůbec neexistuje** —
tabulka `events` je jediný časový objekt a nemá vazbu na plátno ani zákazníka.

---

## Fáze 1 — zpevnění základu (aktualizace 15. 7. 2026)

Tato sekce shrnuje změny z Fáze 1. Vše proběhlo **read-only vůči Supabase** (do produkční DB se
nezapisovalo); měnily se jen soubory v repu. Původní snapshot (níže, ke dni 11. 7.) zůstává pro kontext,
u vyřešených bodů je poznámka.

### 1. Produkční projekt — na co míří ostrý web

**Závěr: produkce běží na Supabase projektu `fareavttiwkamrukpfqk` (MladeKameny).**

- Rozhodující důkaz: tento projekt obsahuje **živá, aktuální data** (směny a akce až do července 2026) —
  do něj reálně zapisuje běžící aplikace. To je jediný projekt viditelný v našem Supabase účtu a je
  z něj i záloha z Fáze 0. **Záloha tedy sedí na produkci.**
- Repo dřív na několika místech odkazovalo **zastaralý** projekt `raxbmhfnifplapnqczbg` (původní Lovable):
  `.env`, `supabase/config.toml`, `preconnect` v `index.html`. Na živém webu se uplatní **Netlify
  env proměnné**, které repo `.env` při buildu přebíjejí.
- **✅ POTVRZENO (16. 7. 2026):** Netlify env `VITE_SUPABASE_URL = https://fareavttiwkamrukpfqk.supabase.co`
  → produkce je **`fareavttiwkamrukpfqk`**.
- **✅ SROVNÁNO:** repo konfigurace přepnuta z `raxbmhfnifplapnqczbg` na `fareavttiwkamrukpfqk`:
  - `supabase/config.toml` (`project_id`) — verzováno,
  - `index.html` (`preconnect`) — verzováno,
  - `.env` (URL, project_id, anon klíč) — jen lokálně (soubor je v `.gitignore`, do gitu nejde),
  - `.env.example` — doplněna poznámka o produkčním projektu + Netlify (bez reálného klíče).
  V repu už `raxbmhfnifplapnqczbg` **nikde nefiguruje** jako aktivní konfigurace.

### 2. Baseline migrace = jediný zdroj pravdy pro schéma

- Nový soubor `supabase/migrations/20260715000000_baseline_production.sql` = **squashed baseline**,
  přesný živý stav produkce (3 enum typy, 7 tabulek, 7 funkcí, 8 triggerů v schématu `public`,
  view `profiles_public`, 11 indexů, 5 FK, 30 RLS politik). Trigger `handle_new_user` na `auth.users`
  je **mimo** baseline (jen jeho funkce je uvnitř). Prošel **databázovou/migrační bránou** (agent) — verdikt PASS
  (přidán `SET check_function_bodies = false;` kvůli reset-safety).
- 19 původních Lovable migrací přesunuto do `supabase/migrations/archive_lovable/` (nemažou se, jen archiv).
- Rozdíly schéma vs. kód (enumy, `role_reqs`, stavy směn, trigger na `auth.users`) jsou **popsané, ne opravené**
  v `docs/SCHEMA_DRIFT.md` — opravy přijdou jako samostatné migrace nad baseline.

### 3. Zabezpečení klíčů

- `.env` přidán do `.gitignore` a **odverzován** (`git rm --cached`; soubor zůstal na disku pro lokální vývoj).
  `.env.example` se dál verzuje.
- **`service_role` klíč NEUNIKL** — v pracovním stromu ani v celé git historii žádný service_role JWT není;
  jediný JWT v repu je veřejný **anon** klíč. Výskyty řetězce „service_role" jsou jen jméno role v `GRANT`
  příkazech zdeprecovaného skriptu. **Klíče se nerotují.**
- Anon klíč je i v git historii (commit `e803401`) — je veřejný design, rotace není nutná.
- **Pravidlo:** produkční klíče patří do **Netlify env**, ne do gitu. `service_role` NIKDY do frontendu/gitu.

### 4. `MIGRATION_SCRIPT.sql` zdeprecován

Přejmenován na `MIGRATION_SCRIPT.sql.DEPRECATED` s výrazným varováním (má `GRANT ALL … TO anon`,
neaktuální schéma). `DEPLOYMENT.md` upraven — schéma se nasazuje z `supabase/migrations/` přes Supabase CLI.

### 5. Doporučené vývojové prostředí pro Fázi 1

Dnes lokální běh míří rovnou na **produkci** (viz Riziko, dev/staging neexistuje) — to je pro stavbu
rezervačního systému nepřijatelné. Dvě bezpečné varianty:

| | **Lokální Supabase (CLI + Docker)** | **Samostatný staging projekt (cloud)** |
|---|---|---|
| Co je potřeba | Docker Desktop + Supabase CLI | druhý Supabase projekt (zdarma tier) |
| Reprodukce schématu | `supabase db reset` (spustí baseline) | `supabase db push` na staging |
| Data | čistá / seed dle libosti, žádná ostrá | drží se ručně v syncu, blízko produkci |
| Náklady | zdarma, offline | spotřebuje cloud projekt |
| Riziko pro produkci | **nulové** (běží na `localhost`) | nízké (jiný projekt), ale sdílí cloud účet |
| Zátěž stroje | vyšší (Docker: Postgres, Auth, Studio…) | žádná |

**Doporučení:** primárně **lokální Supabase přes CLI (Docker)** — nulové riziko pro produkci, `supabase
db reset` reprodukuje baseline, ideální na vývoj Fáze 1. Volitelně navíc **jeden staging cloud projekt**
pro předprodukční ověření (auth flow, e-maily) blíž realitě.

Konkrétní kroky (zatím **nespuštěno**, jen návod na příště):
```bash
# 1) instalace CLI (macOS)         brew install supabase/tap/supabase
# 2) start lokálního stacku         supabase start          # potřebuje běžící Docker
# 3) reprodukce schématu z baseline supabase db reset
# 4) (po resetu) ručně dovytvořit trigger handle_new_user na auth.users — viz SCHEMA_DRIFT.md
# 5) frontend proti lokálu: .env s VITE_SUPABASE_URL=http://127.0.0.1:54321 + lokální anon klíč z `supabase status`
```
Před prvním spuštěním čehokoli proti produkci: **čerstvá záloha + souhlas PM** (viz pracovní postup v CLAUDE.md).

---

## (a) Přehled aplikace a stránek

### Co to je

Interní („portálová") webová aplikace curlingové haly **Mladé kameny**. Slouží ke třem věcem:

1. **Kalendář ledu** — admin zakládá události (komerční akce, tréninky, údržba).
2. **Směny brigádníků** — u komerčních akcí se automaticky generují sloty směn, brigádníci se na ně hlásí, admin schvaluje, po odpracování zadá hodiny a vyplatí.
3. **Komunikace** — rozcestník odkazů do WhatsApp skupin podle role (vlastní chat v appce není).

Aplikace je psaná **česky**, mobile-first (má `manifest.json`, `display: standalone`, iOS meta tagy — chová se jako PWA, ale **service worker chybí**, takže offline nefunguje).

### Technologie

| Vrstva | Co |
|---|---|
| Build | Vite 5 (`@vitejs/plugin-react-swc`), dev server na portu **8080** |
| Jazyk | TypeScript 5.8, React 18.3 |
| UI | Tailwind 3.4 + shadcn-ui (Radix primitives), `lucide-react` ikony, `sonner` + vlastní toaster |
| Routing | `react-router-dom` v7 (BrowserRouter, SPA) |
| Data | `@tanstack/react-query` v5 nad `@supabase/supabase-js` v2 |
| Formuláře | `react-hook-form` + `zod` (schémata v `src/lib/validation.ts`) |
| Backend | Supabase (Postgres, Auth, RLS) — **produkce `fareavttiwkamrukpfqk`** (potvrzeno Netlify env; repo konfigurace ve Fázi 1 srovnána, viz níže) |
| Hosting | Netlify, auto-deploy z GitHubu |

Původ: **Lovable** (generátor). Zbytky jsou pořád v repu — viz Rizika.

### Stránky a routy (`src/App.tsx`)

**Veřejné (bez přihlášení):**

| Routa | Soubor | Co dělá |
|---|---|---|
| `/auth` | `pages/Auth.tsx` | Přihlášení + registrace (e-mail/heslo) |
| `/forgot-password` | `pages/ForgotPassword.tsx` | Odeslání resetovacího e-mailu |
| `/update-password` | `pages/UpdatePassword.tsx` | Nastavení nového hesla z odkazu |

**Chráněné** — všechny jsou uvnitř `AppLayout`, který jen přesměruje na `/auth`, pokud není přihlášený uživatel:

| Routa | Soubor | Co dělá | Kdo to vidí v menu |
|---|---|---|---|
| `/` | `Dashboard.tsx` | Přehled — nejbližší akce, moje směny, upozornění na nové směny | všichni |
| `/calendar` | `IceCalendar.tsx` (1299 ř.) | Kalendář ledu: měsíční/týdenní/denní pohled, admin zakládá a edituje události, nastavuje kolik potřebuje lidí | všichni |
| `/shifts` | `Shifts.tsx` (1535 ř.) | Směny: brigádník se hlásí, admin schvaluje/přiřazuje/dokončuje, zadává hodiny | admin + „staff" role |
| `/payouts` | `Payouts.tsx` (688 ř.) | Výplaty: admin spočítá neproplacené hodiny a založí výplatu | jen admin |
| `/members` | `Members.tsx` (366 ř.) | Členové: admin přidává/odebírá role uživatelům | jen admin |
| `/communication` | `Communication.tsx` (568 ř.) | WhatsApp skupiny podle role; admin je spravuje | všichni |
| `/help` | `Help.tsx` | Statická nápověda | všichni |
| `/profile` | `Profile.tsx` | Vlastní profil — jméno, telefon, číslo účtu, změna hesla | všichni |
| `*` | `NotFound.tsx` | 404 | — |

> `src/pages/Index.tsx` existuje, ale **není nikde nasměrovaný** — mrtvý soubor.

Navigace se filtruje podle rolí v `src/config/navigation.ts` (`NAV_ITEMS[].roles`). Layout je responzivní:
`Sidebar` na desktopu, `MobileHeader` + `MobileNav` (spodní lišta) na mobilu.

### Build a nasazení

```
npm run dev      # vite, http://localhost:8080
npm run build    # vite build -> dist/
npm run lint     # eslint
npm run preview  # náhled buildu
```

**Netlify:** `netlify.toml` obsahuje **pouze SPA redirect** (`/* -> /index.html 200`) — žádnou `[build]` sekci.
Totéž ještě jednou duplicitně v souboru `_redirects`. Z toho plyne:

- **Build command (`npm run build`), publish adresář (`dist`) a hlavně proměnné prostředí `VITE_*` jsou nastavené v Netlify UI, ne v repu.** Bez přístupu do Netlify nevíme, jak přesně je build nakonfigurovaný, a nastavení není verzované.

---

## (b) Datový model a tabulky

⚠️ **Nejdřív varování:** popis schématu se ve Fázi 1 (15. 7. 2026) sjednotil:

- **Zdroj pravdy = `supabase/migrations/20260715000000_baseline_production.sql`** (squashed baseline
  = přesný živý stav produkce k 15. 7. 2026). Prošel databázovou bránou.
- Původních 19 Lovable migrací je v `supabase/migrations/archive_lovable/` (historie, nespouští se).
- `MIGRATION_SCRIPT.sql` → přejmenován na `MIGRATION_SCRIPT.sql.DEPRECATED`, nepoužívat (Rizika, bod 6).

Tabulky níže popisují stav podle (starých) migrací; **baseline navíc obsahuje** i to, co dřív v migracích
chybělo (role `instructor`/`bar_staff`/`manager`, `event_type='recruitment'`, `events.role_reqs`,
`shifts.required_role`). Rozdíly schéma vs. kód: `docs/SCHEMA_DRIFT.md`.

### Tabulky (stav podle migrací)

#### `profiles` — uživatelské profily
| Sloupec | Typ | Pozn. |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid UNIQUE NOT NULL | FK → `auth.users(id)` ON DELETE CASCADE |
| `full_name` | text | |
| `phone` | text | |
| `bank_account` | text | pro výplaty; přidáno migrací `20260113221838` |
| `created_at`, `updated_at` | timestamptz | `updated_at` udržuje trigger |

Sloupec `avatar_url` byl přidán a později zase **odstraněn** (`20260114202610`), včetně storage bucketu `avatars`.

#### `user_roles` — role (schválně oddělená tabulka, ne sloupec v profiles)
| Sloupec | Typ |
|---|---|
| `id` | uuid PK |
| `user_id` | uuid NOT NULL → `auth.users` CASCADE |
| `role` | `app_role` NOT NULL |
| `created_at` | timestamptz |

`UNIQUE(user_id, role)` → **jeden uživatel může mít víc rolí současně.** Aplikace to využívá.

#### `events` — akce v kalendáři ledu
| Sloupec | Typ | Pozn. |
|---|---|---|
| `id` | uuid PK | |
| `title` | text NOT NULL | |
| `description` | text | |
| `event_type` | `event_type` NOT NULL DEFAULT `'commercial'` | |
| `start_time`, `end_time` | timestamptz NOT NULL | |
| `required_staff` | integer DEFAULT 0 | kolik brigádníků je potřeba |
| `created_by` | uuid → `auth.users` ON DELETE SET NULL | |
| `created_at`, `updated_at` | timestamptz | |

**Nemá `deleted_at`, nemá `updated_by`.** Nemá vazbu na plátno ani zákazníka.

#### `shifts` — směny (sloty)
| Sloupec | Typ | Pozn. |
|---|---|---|
| `id` | uuid PK | |
| `event_id` | uuid NOT NULL → `events(id)` **ON DELETE CASCADE** | ⚠️ smazání akce smaže i směny |
| `status` | `shift_status` NOT NULL DEFAULT `'open'` | |
| `claimed_by` | uuid → `auth.users` ON DELETE SET NULL | kdo směnu má |
| `claimed_at` | timestamptz | |
| `hours_worked` | numeric(4,2) | odpracováno |
| `hourly_rate` | numeric(6,2) DEFAULT **150.00** | sazba natvrdo v defaultu |
| `completed_at` | timestamptz | |
| `payout_id` | uuid → `payouts(id)` | proplaceno v rámci které výplaty |
| `notes` | text | |
| `created_at`, `updated_at` | timestamptz | |

**Směna nemá sloupec `role`** — slot je „bezejmenný", nerozlišuje se instruktor / obsluha baru / …

#### `shift_applications` — přihlášky na směny (nejnovější migrace, `20260525135203`)
| Sloupec | Typ |
|---|---|
| `id` | uuid PK |
| `shift_id` | uuid NOT NULL → `shifts(id)` CASCADE |
| `user_id` | uuid NOT NULL |
| `status` | text DEFAULT `'pending'`, CHECK ∈ (`pending`,`approved`,`rejected`,`cancelled`) |
| `created_at`, `updated_at` | timestamptz |

`UNIQUE(shift_id, user_id)` → na jeden slot se může hlásit **víc lidí**, admin vybere jednoho.

#### `payouts` — výplaty
| Sloupec | Typ |
|---|---|
| `id` | uuid PK |
| `user_id` | uuid NOT NULL → `profiles(user_id)` CASCADE |
| `amount` | numeric NOT NULL |
| `paid_at` | timestamptz DEFAULT now() |
| `notes` | text |
| `created_by` | uuid → `profiles(user_id)` |
| `created_at` | timestamptz |

#### `chat_groups` — WhatsApp skupiny
| Sloupec | Typ |
|---|---|
| `id` | uuid PK |
| `name`, `description` | text |
| `whatsapp_url` | text NOT NULL |
| `icon` | text (emoji), `icon_slug` text (Lucide) |
| `authorized_roles` | `app_role[]` NOT NULL — prázdné pole = veřejná skupina |
| `visible_to_user_ids` | uuid[] — navíc konkrétní lidé (`20260208212610`) |
| `created_at`, `updated_at` | timestamptz |

#### Zrušené / pomocné objekty
- **`notifications`** — vytvořena v první migraci, **zahozena** v `20260113165048` s komentářem „using WhatsApp for communication".
- **View `profiles_public`** (`20260114205538`, `WITH (security_invoker = on)`) — stejná data jako `profiles`, ale `bank_account` vrací jen vlastníkovi a adminovi. Aplikace ho používá tam, kde zobrazuje cizí jména.

### Enumy

| Enum | Hodnoty **podle migrací** | Poznámka |
|---|---|---|
| `app_role` | `admin`, `trainer`, `part_time_staff`, `pro_player`, `hobby_player` | ⚠️ kód a `types.ts` znají navíc **`instructor`, `bar_staff`, `manager`** — v migracích nejsou |
| `event_type` | `commercial`, `training`, `maintenance` | původně bylo i `free`, odstraněno v `20260113220934`. ⚠️ kód navíc posílá **`recruitment`** — v DB neexistuje |
| `shift_status` | `open`, `pending`, `claimed`, `completed`, `cancelled` | |

### Funkce a triggery

| Objekt | Co dělá |
|---|---|
| `has_role(user, role)` | SECURITY DEFINER, používá se ve všech RLS politikách |
| `get_user_role(user)` | vrátí „primární" roli podle pevného pořadí — ⚠️ **CASE zná jen 5 původních rolí** |
| `handle_new_user()` | trigger na `auth.users` INSERT → založí `profiles` řádek + přiřadí roli **`hobby_player`** |
| `handle_new_commercial_event()` | trigger po INSERT do `events` → je-li typ `commercial` a `required_staff > 0`, vytvoří N řádků v `shifts` se stavem `open` |
| `update_updated_at_column()` | trigger na `profiles`, `events`, `shifts`, `chat_groups`, `shift_applications` |
| `validate_shift_claim()` | BEFORE UPDATE na `shifts` — hlídá povolené přechody stavů a rozsahy (`hours_worked` 0.1–24, `hourly_rate` 1–10000) |
| `validate_payout()` | BEFORE INSERT na `payouts` — částka 1–1 000 000 Kč, **vytvořit smí jen admin** |

### RLS politiky (výsledný stav po všech migracích)

| Tabulka | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `profiles` | vlastní **nebo** admin / part_time_staff / trainer | vlastní | vlastní | — |
| `user_roles` | vlastní nebo admin | admin | admin | admin |
| `events` | nekomerční vidí **všichni**; `commercial` jen admin / part_time_staff / trainer | admin | admin | admin |
| `shifts` | admin, part_time_staff, nebo `claimed_by = já` | admin | admin, nebo part_time_staff v povolených přechodech | admin |
| `shift_applications` | vlastní nebo admin | vlastní (`user_id = auth.uid()`) | vlastní nebo admin *(bez `WITH CHECK` — viz riziko 5)* | admin |
| `payouts` | vlastní nebo admin | admin | admin | admin |
| `chat_groups` | admin, veřejné skupiny, shoda role, nebo jsem v `visible_to_user_ids` | admin | admin | admin |

**Nikde není soft-delete a nikde není audit log.**

### Jak jsou konkrétně uložení BRIGÁDNÍCI a SMĚNY

*(část zadání — proto zvlášť)*

**Brigádník není samostatná tabulka.** Je to obyčejný uživatel:

```
auth.users (e-mail, heslo)
   └─ profiles      (full_name, phone, bank_account)
   └─ user_roles    (role = 'part_time_staff')
```

Brigádníka „vyrobíte" tak, že se člověk zaregistruje (dostane automaticky `hobby_player`)
a admin mu na stránce `/members` přidá roli `part_time_staff`. Číslo účtu si vyplňuje sám v profilu.

V novější sadě rolí (jen v kódu, ne v migracích) je „brigádník" rozpadlý na
`part_time_staff` / `instructor` / `bar_staff` / `manager` — v kódu je souhrnně řeší `isStaff`.

**Směna = řádek v `shifts`, vždy pověšený na událost (`events`).** Sloty vznikají dvěma způsoby:

1. **Při založení akce** — DB trigger `handle_new_commercial_event` vytvoří `required_staff` prázdných slotů (`status = 'open'`).
2. **Při editaci akce** — od posledního commitu to dorovnává **frontend** v `useEvents.updateEvent`: dopočítá rozdíl, přidá nové `open` sloty, nebo přebytečné `open` sloty smaže (obsazené nechá být).

**Životní cyklus směny je v repu ale implementovaný DVAKRÁT, a obě cesty jsou živé:**

- **Starší cesta — přes `shifts.status`:** `open` → brigádník se přihlásí (`pending`, zapíše se do `claimed_by`) → admin schválí (`claimed`) → admin dokončí a zadá hodiny (`completed`). Hlídá to trigger `validate_shift_claim`.
- **Novější cesta — přes `shift_applications`:** na jeden `open` slot se přihlásí víc lidí (řádky se stavem `pending`). Admin jednoho schválí → `shifts` se přepne na `claimed` + `claimed_by`, ostatní přihlášky se přepnou na `rejected`. Řeší to hook `useShiftApplications.ts`.

**Proplacení:** admin dokončí směnu (jen admin, `hours_worked` je povinné) → odměna = `hours_worked × hourly_rate` (default 150 Kč/h) → na `/payouts` admin vybere neproplacené dokončené směny, založí `payouts` řádek a směnám nastaví `payout_id`.

---

## (c) Přihlašování a role

### Přihlášení

Supabase Auth, **e-mail + heslo** (`signInWithPassword`). Žádné OAuth, žádné magic linky, žádná 2FA.

- **Registrace je otevřená** — kdokoli se může zaregistrovat a trigger `handle_new_user` mu dá roli `hobby_player`. Není žádné schvalování ani pozvánka.
- Session se drží v `localStorage` (`persistSession: true`, `autoRefreshToken: true`).
- Reset hesla: `/forgot-password` pošle e-mail → odkaz vede na `/update-password`.
- **Prvního admina musí někdo nastavit ručně SQL příkazem** v Supabase (postup v `DEPLOYMENT.md`).

### Role

`AuthContext` (`src/contexts/AuthContext.tsx`) načte po přihlášení profil a **všechny** role uživatele
a spočítá jednu „primární" roli podle pevného pořadí:

```
admin > trainer > manager > instructor > bar_staff > part_time_staff > pro_player > hobby_player
```

Odvozené příznaky, které používá celá aplikace:

| Příznak | Splňují role |
|---|---|
| `isAdmin` | `admin` |
| `isTrainer` | `trainer` |
| `isStaff` | `part_time_staff`, `instructor`, `bar_staff`, `manager` |
| `isMember` | `hobby_player`, `pro_player` |

České názvy rolí (`src/config/navigation.ts`):
`admin` = Správce, `trainer` = Trenér, `instructor` = Instruktor, `bar_staff` = Obsluha baru,
`manager` = **Provozní hospoda**, `pro_player` = Profi hráč, `hobby_player` = Hobby hráč.
(`part_time_staff` v tomhle seznamu **chybí** — nemá český popisek.)

### Jak je to zabezpečené

**Dvě vrstvy, každá jinak spolehlivá:**

1. **Menu se filtruje podle rolí** (`filterNavItemsByRoles`) — kosmetika. `AppLayout` kontroluje **jen to, že je uživatel přihlášený**, roli nekontroluje. Kdokoli přihlášený si může do adresního řádku napsat `/payouts` nebo `/members` a stránka se mu vykreslí.
2. **RLS v Postgresu** — tohle je skutečná ochrana. Stránka se sice vykreslí, ale data se nenačtou (např. `payouts` vrátí jen vlastní výplaty, `user_roles` jen vlastní roli).

Prakticky to drží, ale spoléhá se to celé na RLS. Viz Rizika, bod 4 a 5.

### Připojení k Supabase a lokální spuštění

Klient: `src/integrations/supabase/client.ts`. Klíče **nejsou napevno v kódu**, čtou se z env:

```ts
const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const SUPABASE_PUBLISHABLE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
```

Potřebné proměnné (vzor je v `.env.example`):

| Proměnná | K čemu |
|---|---|
| `VITE_SUPABASE_URL` | adresa projektu |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | anon/public klíč |
| `VITE_SUPABASE_PROJECT_ID` | ID projektu (kód ho ale reálně nepoužívá) |

ID projektu bylo natvrdo ještě na dvou místech (`supabase/config.toml` a `preconnect` v `index.html`) —
ve Fázi 1 srovnáno ze zastaralého `raxbmhfnifplapnqczbg` na produkční `fareavttiwkamrukpfqk` (viz sekce „Fáze 1").

**Co je potřeba pro lokální spuštění** (zatím nespuštěno, jen popis):

1. Node.js + npm.
2. `npm install` — pozor, v repu jsou **dva lockfily** (`package-lock.json` i `bun.lockb`); je potřeba se rozhodnout pro jeden.
3. `.env` — **už v repu je** (viz Rizika, bod 1), takže by appka nastartovala rovnou proti ostré databázi.
4. `npm run dev` → `http://localhost:8080`.
5. Aby fungovalo přihlášení a reset hesla, musí být `http://localhost:8080/` a `http://localhost:8080/update-password` mezi **Redirect URLs** v Supabase (Authentication → URL Configuration). Jestli tam jsou, z repa nezjistíme.

⚠️ **Lokální běh míří na PRODUKČNÍ databázi.** Neexistuje dev/staging projekt. Cokoli si lokálně naklikáte, zapíše se do ostrých dat.

---

## (d) Rizika a nejasnosti

Seřazeno od nejzávažnějšího.

### 1. `.env` s klíči je commitnutý v gitu — ✅ VYŘEŠENO ve Fázi 1 (15. 7. 2026)
`.gitignore` **neobsahoval `.env`** a soubor byl verzovaný (přidán commitem `e803401`). Anon klíč je sice určený do prohlížeče a sám o sobě není katastrofa (chrání ho RLS), ale:
- v repu nemá co dělat, patří do Netlify env,
- hrozí, že tam někdo časem přidá `service_role` klíč — a ten RLS obchází úplně,
- `.env.example` přitom sám varuje „POZOR: .env soubor NIKDY nepushuj do gitu!".

**Vyřešeno:** `.env` přidán do `.gitignore` a odverzován (`git rm --cached`, soubor zůstal na disku).
Ověřeno, že v repu ani v git historii **není `service_role` klíč** (jediný JWT je anon). Anon klíč
zůstává v historii — je veřejný, rotace není nutná. Detaily v sekci „Fáze 1" a `docs/SCHEMA_DRIFT.md`.

### 2. Databáze v cloudu ≠ migrace v repu (porušená zásada č. 1 z CLAUDE.md)
Vygenerovaný `src/integrations/supabase/types.ts` (odráží **skutečnou** cloud DB) obsahuje věci, které **v žádné migraci nejsou**:
- role `instructor`, `bar_staff`, `manager` v enumu `app_role`,
- (a naopak) kód zapisuje do `events` sloupec **`role_reqs`** (JSONB, per-role počty lidí), který není ani v migracích, ani v `types.ts` — proto je v `IceCalendar.tsx` a `useEvents.ts` obcházený přes `as any`.

Znamená to, že se v Supabase editovalo ručně mimo migrace. **Dokud tohle nesrovnáme, nejde databázi spolehlivě obnovit ze zálohy ani postavit dev prostředí.** Toto je podle mě první věc k opravě.

### 3. Typ události „Náborová akce" (`recruitment`) pravděpodobně nefunguje
UI ho v `/calendar` nabízí v selectu, `validation.ts` ho zná — ale **enum `event_type` v DB ho nemá**.
V kódu je to i přiznané: `IceCalendar.tsx:24` → `// Extended EventType to include 'recruitment' (pending database migration)`.
Založení náborové akce tedy nejspíš skončí chybou z Postgresu. **Potřeba ověřit proti živé DB.**
Navíc trigger `handle_new_commercial_event` reaguje jen na `commercial`, takže by se pro náborovku ani negenerovaly sloty.

### 4. RLS politiky neznají nové role
Politiky u `shifts`, `profiles` a `events` jmenují natvrdo jen `admin` / `part_time_staff` / `trainer`.
Uživatel s rolí **`instructor`, `bar_staff` nebo `manager`** proto:
- uvidí v menu položku „Směny" (frontend ho pustí, `isStaff` je true),
- ale **RLS mu žádné směny nevrátí** → uvidí prázdno.

Stejně tak `get_user_role()` má v `CASE` jen 5 původních rolí — pro nové role se chová nedefinovaně.

### 5. Schvalování směn jde možná obejít (k ověření)
Dvě věci, které spolu nesedí:
- RLS `UPDATE` politika na `shift_applications` má jen `USING`, **žádné `WITH CHECK`** → uživatel by si teoreticky mohl u vlastní přihlášky sám přepsat `status` na `'approved'`.
- RLS `WITH CHECK` na `shifts` povoluje `part_time_staff` zapsat `status = 'claimed' AND claimed_by = auth.uid()`, a trigger `validate_shift_claim` hlídá přechod `pending → claimed` (jen admin), ale **přechod `open → claimed` napřímo neblokuje**.

Dohromady to vypadá, že si brigádník může směnu přiřadit sám bez schválení admina. **Je to zatím jen analýza kódu — potřebuje ověřit dotazem na živou DB**, ale pokud to platí, je to díra v hlavním workflow.

### 6. `MIGRATION_SCRIPT.sql` je zastaralý a nebezpečný — ✅ ŘEŠENO ve Fázi 1 (přejmenován na `.DEPRECATED` + varování, `DEPLOYMENT.md` upraven)
`DEPLOYMENT.md` říkal „zkopíruj a spusť". Kdyby to někdo udělal, dostane **jinou databázi, než na jaké appka běží**:
- chybí v něm celá tabulka `shift_applications`,
- má jen 5 rolí,
- má **`GRANT ALL ON ALL TABLES IN SCHEMA public TO anon`** — plus stejný default privilege do budoucna. Roli `anon` má každý nepřihlášený návštěvník. Data drží jen RLS; jakákoli budoucí tabulka bez zapnutého RLS by byla veřejně čitelná i zapisovatelná.
- jeho verze view `profiles_public` **nemá `security_invoker = on`** (migrace ho má) → view by běželo s právy vlastníka a obešlo RLS.
- má jinak napsané RLS než migrace (např. `events` nechává číst všechny).

### 7. Nesplněné zásady z CLAUDE.md a požadavky zákazníka
- **Soft delete neexistuje.** `deleted_at` není nikde v repu. `deleteEvent` maže natvrdo a `shifts.event_id` má `ON DELETE CASCADE` → **smazáním akce nenávratně zmizí i všechny její směny**, tedy i podklad pro už vyplacené odměny.
- **Audit log neexistuje.** Máme jen `created_by` + `created_at` / `updated_at`. Chybí `updated_by` a jakákoli historie změn. Požadavek zákazníka „musí být vidět, kdo co zadával" tedy zatím **není splněn**.
- **Zálohy** — v repu o nich není nic. Neví se, jestli jsou na Supabase zapnuté (u free tieru bývají jen 7denní, a nemusí být vůbec).

### 8. Rezervační systém ledu neexistuje ani v základech
Není žádná tabulka pro **plátna (sheets)**, **zákazníky/IČO**, **ceník** ani **faktury**. `events` je jediný časový objekt a nemá vazbu ani na plátno, ani na zákazníka. Fáze 2/3 se staví prakticky na zelené louce (což je vlastně dobrá zpráva — nic se nebude přepisovat).

### 9. Rate limiting je jen v prohlížeči
`useRateLimit.ts` je poctivě napsaný, ale ukládá stav do `sessionStorage` → obejde se zavřením panelu. Sám soubor to v komentáři přiznává („Server-side rate limiting … is also required"). Reálnou ochranu přihlašování má na starosti Supabase.

### 10. Drobnosti
- **Zbytky Lovable:** `lovable-tagger` v dependencies (a v `vite.config.ts`), README pořád odkazuje na Lovable, adresář `.lovable/` s posledním plánem. `DEPLOYMENT.md` má návod, jak to odstranit — zatím se neprovedlo.
- **Dva lockfily** (`bun.lockb` + `package-lock.json`) → různí lidé můžou dostat různé verze balíčků.
- **Netlify build není v repu** (viz sekce a) — konfigurace žije jen v UI.
- **Žádné testy** v celém projektu.
- **Logo a PWA ikony se tahají z `storage.googleapis.com/gpt-engineer-file-uploads/…`** (Lovable CDN). Až to zmizí, appka přijde o ikonu i o og:image.
- **`profiles` nemá admin UPDATE politiku** → admin nemůže opravit cizí profil (např. špatně zadané číslo účtu), i když by to nejspíš potřeboval.
- Mrtvý soubor `src/pages/Index.tsx`.
- Chybí český popisek pro roli `part_time_staff` v `ROLE_LABELS`.

---

## (e) Otázky na PM / zákazníka

### Musíme vědět hned (blokuje úklid schématu — Fáze 1)

1. **Role — která sada platí?** Migrace znají 5 rolí, aplikace 8. Co přesně znamená `instructor`, `bar_staff` a `manager` („Provozní hospoda")? A **kdo z nich smí brát směny** — všichni čtyři „staff", nebo jen brigádník?
2. **Náborová akce (`recruitment`)** — má to být plnohodnotný typ události? Pokud ano, doplníme migraci a trigger. Pokud to byl experiment, odstraníme to z UI (dnes to nejspíš padá).
3. **Přihlašování na směny — který ze dvou workflow je ten správný?** V kódu žijí oba: (a) přímé zabrání směny přes `shifts.status`, (b) přihlášky přes `shift_applications` s výběrem admina. Jeden je potřeba vypnout, jinak si budou lézt do zelí.
4. **Mají mít sloty směn roli?** („Na tuhle akci potřebuju 1 instruktora + 2 lidi na bar.") Dnes je slot bezejmenný a per-role počty se drží jen v `events.role_reqs` pro zobrazení — nikoli v samotných směnách.
5. **Běží aplikace ostře s reálnými daty (hlavně výplaty)?** Určuje to, jak opatrně můžeme migrovat a jestli potřebujeme nejdřív zálohu.
6. **Přístupy** — kdo vlastní Supabase projekt a Netlify účet? Potřebujeme je pro zálohy, migrace a kvůli tomu, abychom vůbec viděli nastavení buildu.

### K rozhodnutí před Fází 2 (návrh rezervace ledu)

7. **Struktura ledu:** kolik pláten, jaká je nejmenší jednotka rezervace (30/60/90 min?), otevírací doba, sezónnost (kdy led je a kdy není)?
8. **Kdo co smí rezervovat?** HOBBY / člen / „Mladé kameny" / brigádník / veřejnost — a smí si člen rezervovat sám, nebo to jen navrhne a admin schválí?
9. **Ceník:** sazba za hodinu podle typu akce, nebo podle role objednatele? Kdo má jaké slevy?
10. **Zákazníci s IČO:** má to být samostatná tabulka firem, oddělená od uživatelů (jedna firma → víc kontaktních osob)? Nebo je zákazník vždycky uživatel systému?
11. **Fakturace:** vlastní generování, nebo napojení na Fakturoid / iDoklad? *(Doporučení: napojení — vyhneme se řešení číselných řad, DPH a archivace.)*
12. **Platby:** jen faktura po akci, nebo i online platba / záloha při rezervaci?

### K potvrzení (technické, ale s dopadem na peníze a data)

13. **Smí se cokoli mazat natvrdo?** Navrhujeme všude soft delete (`deleted_at`) — zejména u akcí, protože dnes smazání akce smaže i směny včetně historie odměn.
14. **Audit:** stačí evidovat změny od chvíle, kdy to nasadíme, nebo se očekává i historie zpětně? (Zpětně to nepůjde, data neexistují.)
15. **Registrace je dnes otevřená komukoli z internetu** (nový uživatel automaticky dostane roli hobby hráče). Má to tak zůstat, nebo chceme registraci na pozvánku / schválení adminem?
