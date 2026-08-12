# Schema drift — nesoulady mezi produkční DB, migracemi a kódem

**Datum:** 2026-07-15 · **Fáze:** 1 (zpevnění základu)
**Status:** jen ZDOKUMENTOVÁNO — **záměrně NEOPRAVUJEME**. Opravy přijdou jako samostatné
migrace nad baseline, každá přes databázovou + bezpečnostní bránu.

Baseline (`supabase/migrations/20260715000000_baseline_production.sql`) zachycuje **skutečný
živý stav** produkce (`fareavttiwkamrukpfqk`). Ten se rozešel jak se starým
`MIGRATION_SCRIPT.sql.DEPRECATED`, tak místy i s aplikačním kódem. Přehled níže.

---

## 1. Enum `app_role` — 8 hodnot živě vs. 5 v starém skriptu

**Živá DB:** `admin, trainer, part_time_staff, pro_player, hobby_player, instructor, bar_staff, manager`
**`MIGRATION_SCRIPT.sql.DEPRECATED` i nejstarší Lovable migrace:** jen prvních 5.

Hodnoty `instructor`, `bar_staff`, `manager` byly přidány později (za provozu). Kód je běžně
používá (RLS politiky `shifts`, `chat_groups` se na `instructor/bar_staff/manager` odkazují).

**Navazující nesoulad v kódu (funkce `get_user_role` + politika „Users see groups matching
their highest role"):** řazení rolí přes `CASE ... END` pokrývá **jen 5 původních rolí**.
Pro `instructor / bar_staff / manager` vrací `CASE` hodnotu `NULL` → tyto role nemají
definované pořadí („nejvyšší role"). Důsledek: uživatel, který má jen některou z těchto tří
rolí, může z logiky „nejvyšší role" vypadnout. **Neopravovat teď**, jen evidovat.

---

## 2. Enum `event_type` — 4 hodnoty živě vs. 3 v starém skriptu

**Živá DB:** `commercial, training, maintenance, recruitment`
**Starý skript:** `commercial, training, maintenance` (chybí `recruitment`).

`recruitment` se reálně používá (viz akce „Zs volgogradska") a trigger
`handle_new_commercial_event` generuje směny i pro `recruitment`.

---

## 3. Sloupce, které v starém skriptu chybí

| Tabulka | Sloupec | Živě | Starý skript |
|---|---|---|---|
| `events` | `role_reqs jsonb DEFAULT '{}'` | ✅ | ❌ chybí |
| `shifts` | `required_role app_role` | ✅ | ❌ chybí |

Na `role_reqs` staví trigger `handle_new_commercial_event` (nový JSON rozpis rolí:
`{"instructor": 2, "bar_staff": 1}` → generuje odpovídající směny s `required_role`).
Starý skript tuhle logiku vůbec neměl. **Baseline oba sloupce i trigger obsahuje.**

---

## 4. Dvě různé sady stavů pro „směny"

- `shifts.status` = enum **`shift_status`**: `open, pending, claimed, completed, cancelled`.
- `shift_applications.status` = **text** s CHECK: `pending, approved, rejected, cancelled`.

Jsou to dva různé slovníky pro dva paralelní mechanismy (přímé obsazení směny
`shifts.claimed_by` vs. tabulka přihlášek `shift_applications`). Sjednocení / vyjasnění
je kandidát na pozdější čištění — teď **neřešíme**.

---

## 5. Trigger `handle_new_user` na `auth.users`

Funkce `public.handle_new_user()` (zakládá profil + výchozí roli `hobby_player`) je v baseline.
**Trigger** samotný ale visí na `auth.users` (mimo schéma `public`), takže ho baseline
neobsahuje. Při čisté obnově (lokál/staging) je nutné ho vytvořit ručně:

```sql
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
```

---

## 6. Další pozorování (pro bezpečnostní bránu, nikoli teď k opravě)

- **Překrývající se RLS SELECT politiky.** Tabulky `events`, `profiles`, `user_roles`, `shifts`
  mají politiku typu „Anyone authenticated can read … USING (true)". Protože permissive
  politiky se OR-ují, tato jedna otevřená politika **zneplatní** přísnější „staff/admin"
  politiky vedle ní (u `shifts` jsou obě). Pro přihlášeného uživatele je tedy čtení fakticky
  otevřené. Posoudí bezpečnostní brána; případná úprava = samostatná migrace.
- **`GRANT ALL … TO anon`** se vyskytuje jen ve zdeprecovaném `MIGRATION_SCRIPT.sql.DEPRECATED`,
  **ne** v baseline. Nikdy nespouštět (obchází RLS).

---

## 7. Výplatní modul: peníze ve float součtech a `numeric` bez precision

**Zaevidováno 11. 8. 2026** při Etapě 2 (code review PR A1). **Záměrně NEOPRAVUJEME teď.**

Fakturace dostala jednotnou peněžní politiku (`src/lib/money.ts`: sčítání v haléřích,
stupňovitá kvantizace podle R3, půlka nahoru v absolutní hodnotě jako Postgres).
**Výplatní modul ji nemá** a trpí toutéž vadou, kterou to opravovalo:

- `baseline_production.sql:311` — `payouts.amount numeric` **bez precision**;
  `:325-326` — `shifts.hours_worked`, `shifts.hourly_rate` taktéž. Žádná záruka `(x,2)`,
  na rozdíl od `reservations`.
- `src/pages/Payouts.tsx:223` a `:585` — součty peněz přes `reduce((s, p) => s + Number(p.amount), 0)`,
  tedy v pohyblivé řádové čárce.
- Vlastní formátovače `toLocaleString('cs-CZ')` bez options v `Payouts.tsx`, `Shifts.tsx`,
  `Profile.tsx`, `Dashboard.tsx` — formátují jinak než `money.ts` (`3 751,5` vs. `3 751,50`).

**Proč to zatím nehoří:** ověřeno, že `calculateStaffAmount` / `calculateTotalAmount`
(`Shifts.tsx:448-463`) krmí jen zobrazení (`:1368`, `:1441`), **ne zápis do DB**. Celá
výplatní doména je display-only — rozpad nikam neprolézá. U fakturace byl problém právě
v tom, že prolezl až do dokladu, který jde zákazníkovi.

**Kdy to řešit:** jakmile se výplaty dotknou tisku, exportu nebo účetního výstupu.
Pak je to první věc na řadě a `money.ts` už bude připravené.

---

## Doporučené pořadí oprav (návrh do dalších fází, nezávazné)

1. Doplnit řazení `instructor/bar_staff/manager` do `get_user_role` a highest-role logiky.
2. Projít a zúžit „read = true" RLS politiky podle skutečné potřeby.
3. Rozhodnout o sjednocení stavů směn (`shifts` vs. `shift_applications`).

Každá oprava: samostatná migrace nad baseline → databázová brána → bezpečnostní brána → PM.
