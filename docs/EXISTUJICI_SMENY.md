# Jak dnes funguje: komerční akce → směny brigádníků

Čistě popisný přehled STÁVAJÍCÍHO stavu (read-only průzkum ke dni 2026-07-17).
Nic se nenavrhuje ani nemění. Odkazy na kód: baseline migrace
`supabase/migrations/20260715000000_baseline_production.sql`, frontend
`src/pages/Calendar.tsx` + `src/components/reservations/ReservationDialog.tsx`
a hook `src/hooks/useEvents.ts`.

> **Pozor na stáří.** Průzkum vznikl nad `src/pages/IceCalendar.tsx`, který
> byl v září 2026 smazán jako mrtvý kód (nevedl na něj import ani routa).
> Odkazy níž jsou přepsané na dnešní soubory; čísla řádků u nich platí ke
> 4. 9. 2026.

---

## 1. Vznik akce a generování směn

### Tabulka `events` (akce v kalendáři ledu)
Relevantní sloupce:
- `event_type` (enum `event_type`: `commercial`, `training`, `maintenance`, `recruitment`), default `commercial`.
- `required_staff integer DEFAULT 0` — celkový počet potřebných brigádníků.
- `role_reqs jsonb DEFAULT '{}'` — „nový" rozpis po rolích, např. `{"instructor": 2, "bar_staff": 1}`.
- `start_time`, `end_time`, `title`, `description`, `created_by` …

### Tabulka `shifts` (jednotlivé směny/sloty)
- `event_id` → `events(id)` **ON DELETE CASCADE** (smazání akce smaže i směny).
- `status` (enum `shift_status`: `open` → `pending` → `claimed` → `completed` / `cancelled`), default `open`.
- `required_role public.app_role` (nullable) — pro jakou roli je slot určený; `NULL` = bez konkrétní role.
- dále `claimed_by`, `claimed_at`, `hours_worked`, `hourly_rate` (default 150), `completed_at`, `payout_id`, `notes`.

### Trigger `create_shifts_for_commercial_event`
`AFTER INSERT ON events FOR EACH ROW EXECUTE FUNCTION handle_new_commercial_event()`.
Funkce (`SECURITY DEFINER`) rozhoduje dvěma větvemi:

1. **Nový režim (podle `role_reqs`)** — když `role_reqs IS NOT NULL AND role_reqs != '{}'`:
   projde JSON přes `jsonb_each_text`; pro každou dvojici `role → počet` vloží `počet` řádků do
   `shifts` se `status='open'` a `required_role = <role>`. Platí pro jakýkoli typ akce, pokud je
   `role_reqs` vyplněný.
2. **Starý režim (podle `required_staff`)** — jinak, když `event_type IN ('commercial','recruitment')`
   a `required_staff > 0`: vloží `required_staff` řádků `status='open'` **bez** `required_role` (NULL).

Pro `training` a `maintenance` bez `role_reqs` se negeneruje nic.

> **Důležité: trigger reaguje jen na INSERT (vytvoření akce).** Při EDITaci akce se směny
> nedorovnávají v DB — dělá to frontend (viz níže).

### Dorovnání směn při editaci (frontend, ne DB)
`useEvents.updateEvent` (`src/hooks/useEvents.ts`): po úpravě akce typu `commercial`/`recruitment`
spočítá rozdíl mezi požadovaným počtem (`required_staff`) a existujícími směnami a:
- přidá chybějící `open` směny, nebo
- odebere přebytečné, ale **jen ty se `status='open'`** (obsazené nechá být).

> **Nesoulad k vědomí:** dorovnání při editaci pracuje jen s **celkovým počtem** a přidává směny
> **bez `required_role`** (`{ event_id, status: 'open' }`). Per-role rozpis (`role_reqs`) se tak
> uplatní **jen při vzniku akce**, ne při pozdější editaci — po editaci mohou vzniknout role-less sloty.

### Životní cyklus vzniklé směny (jen ve zkratce)
Vygenerovaný slot je `open`. Dál ho řeší jiný mechanismus (přihlášení brigádníka → `pending` →
admin schválí `claimed` → dokončení `completed`), hlídaný triggerem `validate_shift_claim` a/nebo
tabulkou `shift_applications`. To je mimo rozsah tohoto přehledu (týká se obsazování, ne generování).

---

## 2. Role brigádníků

### Celý enum `app_role` (8 hodnot)
`admin`, `trainer`, `part_time_staff`, `pro_player`, `hobby_player`, `instructor`, `bar_staff`, `manager`.

České popisky (`src/config/navigation.ts` → `ROLE_LABELS`, resp. `src/pages/Shifts.tsx`
→ `staffRoleLabels`, ř. 33):
`admin` = Správce, `trainer` = Trenér, `instructor` = Instruktor, `bar_staff` = Obsluha baru,
`manager` = Provozní hospoda, `pro_player` = Profi hráč, `hobby_player` = Hobby hráč.
(`part_time_staff` = „brigádník" — v `ROLE_LABELS` nemá vlastní popisek.)

### Které se reálně používají u komerčních akcí
Formulář komerční/náborové akce nabízí k rozpisu **jen 3 role**
(`src/components/reservations/ReservationDialog.tsx` → `STAFF_ROLES`, ř. 30–34):
- **`instructor`** (Instruktor)
- **`bar_staff`** (Obsluha baru)
- **`manager`** (Provozní hospoda)

Do `shifts.required_role` se tedy z formuláře dostávají jen tyto tři hodnoty; `NULL` u směn
vzniklých starým režimem nebo dorovnáním při editaci. Ostatní role enumu (`admin`, `trainer`,
`part_time_staff`, `pro_player`, `hobby_player`) se u generování směn komerční akce **nepoužívají**.

> Kdo si smí směnu vzít, řeší jinde příznak `isStaff` = role
> `part_time_staff` / `instructor` / `bar_staff` / `manager` (`AuthContext`). To je oddělené od
> `required_role` slotu.

---

## 3. Kde a jak se zadává počet směn a jejich rolí

### Kde
Stránka **Kalendář** (`/calendar`, `src/pages/Calendar.tsx`), dialog rezervace
(`src/components/reservations/ReservationDialog.tsx`). Sekce **„Obsazení (směny)"** (ř. 898;
dřív se jmenovala „Konfigurace týmu") se zobrazí jen pro `event_type` `commercial` nebo
`recruitment`.

### Jak (UI)
- Stav `roleCounts` = `{ instructor: 0, bar_staff: 0, manager: 0 }`.
- Pro každou z 3 rolí je **stepper +/−** (`adjustRoleCount`), max je `VALIDATION_LIMITS.STAFF_COUNT_MAX`.
- `getTotalStaff()` = součet všech tří počtů.

### Co přesně se uloží
Při vytvoření i úpravě akce (`handleCreateEvent` / `handleUpdateEvent`, řádky ~258, ~282, ~423, ~448):
- `required_staff = getTotalStaff()` (celkový součet),
- `role_reqs` = objekt z `roleCounts` **po odfiltrování nul**
  (`Object.entries(roleCounts).filter([_, c] => c > 0)`), nebo `undefined`, když jsou všechny nuly.

Příklad výsledného `role_reqs`: `{"instructor": 2, "bar_staff": 1}` → `required_staff = 3`.
(Shodné s reálnými daty v produkci, viz např. akce „Komerční banka" / „Kn".)

Při načtení akce do editace se `role_reqs` rozparsuje zpět do `roleCounts`; u starších akcí bez
`role_reqs` se celý `required_staff` přiřadí jako `instructor` (legacy fallback, řádky ~383–397).

### Shrnutí toku
```
Formulář „Konfigurace týmu"  →  roleCounts {instructor,bar_staff,manager}
        │  (filtr nul)                         │  (součet)
        ▼                                      ▼
events.role_reqs (jsonb)              events.required_staff (int)
        │
        ▼  (jen při INSERT: trigger handle_new_commercial_event)
shifts × N  (status='open', required_role = klíč z role_reqs)
        │
        ▼  (při EDITu: useEvents.updateEvent — dorovná jen počet, sloty bez required_role)
```

---

## Odkazy do kódu
- Enum, tabulky, trigger/funkce: `supabase/migrations/20260715000000_baseline_production.sql`
  (`app_role` ř. 44, funkce `handle_new_commercial_event` ř. 128, trigger ř. 427, `events` ř. 297+, `shifts` ř. 332).
- Formulář a stav rolí: `src/components/reservations/ReservationDialog.tsx`
  (`STAFF_ROLES` ř. 30, `roleCounts` ř. 127, `adjust` ř. 260 — dřív `adjustRoleCount`,
  build `role_reqs` ř. 466, UI stepper ř. 907–910).
- Popisky rolí ve výpisu směn: `src/pages/Shifts.tsx` (`staffRoleLabels` ř. 33).
- Dorovnání směn při editaci: `src/hooks/useEvents.ts` (`updateEvent`, ř. 67–101).

*(Nesoulad enumu vs. migrace/kód a další drift je popsaný v `docs/SCHEMA_DRIFT.md`.)*
