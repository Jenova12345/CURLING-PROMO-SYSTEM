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

## 8. Nálezy bezpečnostní brány u PR A2, které leží mimo jeho rozsah

**Zaevidováno 12. 8. 2026** při Etapě 2 (bezpečnostní brána PR A2). Všechno jsou
věci **starší než A2** — jen se ukázaly, když se prosvítila peněžní plocha.
Ověřeno útokem přes PostgREST, ne čtením kódu.

### 8a) ~~Ceník vidí každý přihlášený~~ — VYŘEŠENO v PR A2b (12. 8. 2026)

`GET /rest/v1/settings` jako obyčejný člen vrátí **kompletní ceník** (club 600,
commercial 1500, training 600, tournament 800). Politika je `settings_select
USING (true)` (`etapa1_rls.sql:85`) s plným tabulkovým grantem.

Přitom `reservations.rate_per_hour` a `amount` jsou před `authenticated` pečlivě
schované sloupcovým REVOKE (vrací `403`). Jenže člen vidí `start_at`/`end_at`
a `subjects.default_rate` svého klubu, takže si částku klubové rezervace
**dopočítá z ceníku**. Rozhodnutí klienta přitom zní „částku vidí jen admin a autor"
(CLAUDE.md, feedback z 31. 7. 2026).

**Opraveno** migrací `20260812140000_cenik_jen_adminovi.sql` po rozhodnutí PM:
tabulkový SELECT odebrán, neprice sloupce vráceny sloupcovým grantem, sazby vydává
pohled `settings_public` jen adminovi. Spolu s tím zavřena i táž díra u
`subjects.default_rate` (pohled `subjects_rates`) — bez ní by oprava byla k ničemu,
protože `defaultRateFor` sahá po sazbě subjektu dřív než po ceníku. Hlídá to
`supabase/tests/cenik_viditelnost_test.sql`.

Souvisí s rozhodnutím R9 v `etapa2-fakturace-plan.md`, které právě kvůli
`USING (true)` zakazuje dávat fakturační údaje do `public.settings`.

### 8b) `SECURITY DEFINER` RPC prozradí obsah řádku při porušení CHECKu

Uvnitř `SECURITY DEFINER` funkce vlastněné `postgres` není RLS aktivní, takže
Postgres do chyby doplní `DETAIL: Failing row contains (…)` — a PostgREST ho pošle
klientovi. U přímého zápisu do tabulky se to nestane (Postgres to při aktivní RLS
sám potlačí), u RPC ano.

A2 to pro své vlastní constrainty **uzavřela** triggerem `trg_reservations_z_money`,
který vyhodí srozumitelnou chybu dřív, než CHECK vůbec dostane slovo (ověřeno:
`details: null`). Ale zbylé constrainty na `reservations` tím chráněné nejsou.

**Návrh:** do `create_booking`, `create_booking_series`, `update_booking`,
`move_booking` a `cancel_booking` doplnit `EXCEPTION WHEN check_violation` s vlastní
hláškou, vedle už existujícího handleru na `exclusion_violation`.

### 8c) `reservations_update` nemá v `USING` filtr `deleted_at IS NULL`

Na rozdíl od `reservations_select`. Dnes to nevadí — Postgres na `UPDATE` s podmínkou
nad sloupci uplatní i SELECT politiku, takže soft-smazané řádky zapisovatelné nejsou
(ověřeno útokem). Je to ale **ochrana náhodou, ne návrhem**: stačí, aby někdo
`authenticated` přidal tabulkový `SELECT`, a soft-smazané rezervace se stanou
zapisovatelnými.

### 8d) `anon` a `authenticated` mají `TRUNCATE` na peněžních tabulkách

`GRANT ALL` zahrnuje `TRUNCATE`, na který se **RLS nevztahuje**. Ověřeno:
`SET ROLE anon; TRUNCATE public.settings;` projde (v odrolované transakci).
Přes PostgREST to dosažitelné není (neumí `TRUNCATE` vygenerovat), takže jde
o obranu do hloubky — ale `audit_log` truncatable rolí `anon` sedí špatně proti
požadavku „auditovatelnost" a „garance, že se data nesmažou".

**Návrh:** `REVOKE TRUNCATE, DELETE ON settings, subjects, audit_log, reservations
FROM anon, authenticated;` a `REVOKE ALL ON settings, subjects FROM anon;`

### 8e) Korekce hodin nemá horní mez ani povinný důvod

`corrected_hours = 9999.75` na jednohodinové rezervaci projde — to je faktura
na šest milionů. `correction_reason` není vynucený žádným constraintem, takže
korekce může být bez zdůvodnění.

**Kdy to řešit:** jakmile vznikne UI pro korekce (dnes se `corrected_hours`
z frontendu jen čte). Tehdy tam patří i `parseKorekce` v `money.ts` a
`CHECK (corrected_hours IS NULL OR correction_reason IS NOT NULL)`.

---

## Doporučené pořadí oprav (návrh do dalších fází, nezávazné)

1. Doplnit řazení `instructor/bar_staff/manager` do `get_user_role` a highest-role logiky.
2. Projít a zúžit „read = true" RLS politiky podle skutečné potřeby.
3. Rozhodnout o sjednocení stavů směn (`shifts` vs. `shift_applications`).

Každá oprava: samostatná migrace nad baseline → databázová brána → bezpečnostní brána → PM.
