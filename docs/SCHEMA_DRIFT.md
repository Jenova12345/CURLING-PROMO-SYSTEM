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

## 8. Nálezy bezpečnostní brány u PR A2

**Zaevidováno 12. 8. 2026** při Etapě 2 (bezpečnostní brána PR A2). Všechno jsou
věci **starší než A2** — jen se ukázaly, když se prosvítila peněžní plocha.
Ověřeno útokem přes PostgREST, ne čtením kódu.

> **VYŘEŠENO.** Body 8b–8f uzavřel **PR A5** (migrace `20260812200000_security_hardening.sql`),
> hlídá je `supabase/tests/security_hardening_test.sql`. Kapitola zůstává jako záznam
> toho, co bylo špatně a proč — ne jako seznam úkolů. Bod 8a vyřešila A2b.
>
> Dvě věci, které A5 odhalila a NEuzavřela, jsou zapsané níž jako **8g** a **8h**.

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

### 8b) `SECURITY DEFINER` RPC prozradí obsah řádku při porušení CHECKu · **→ A5**

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

### 8c) `reservations_update` nemá v `USING` filtr `deleted_at IS NULL` · **→ A5**

Na rozdíl od `reservations_select`. Dnes to nevadí — Postgres na `UPDATE` s podmínkou
nad sloupci uplatní i SELECT politiku, takže soft-smazané řádky zapisovatelné nejsou
(ověřeno útokem). Je to ale **ochrana náhodou, ne návrhem**: stačí, aby někdo
`authenticated` přidal tabulkový `SELECT`, a soft-smazané rezervace se stanou
zapisovatelnými.

### 8d) `anon` a `authenticated` mají `TRUNCATE` na peněžních tabulkách · **→ A5**

`GRANT ALL` zahrnuje `TRUNCATE`, na který se **RLS nevztahuje**. Ověřeno:
`SET ROLE anon; TRUNCATE public.settings;` projde (v odrolované transakci).
**Verdikt k závažnosti (ověřeno útokem 12. 8. 2026, na žádost PM):** teoretické
právo bez cesty k němu. `TRUNCATE` přes PostgREST vyjádřit nejde; `DELETE` vyjádřit
jde, ale RLS ho zahodí (`audit_log` má jedinou politiku, a to na SELECT), takže
anonymní `DELETE` vrátí 204 a smaže **0 řádků** — ověřeno, počty se nezměnily.
Žádná funkce s dynamickým SQL není pro anon volatelná (0 nálezů) a Edge funkce
arbitrární SQL nespouštějí.

**A3 (12. 8. 2026) ale zvýšila cenu toho, co se tím chrání.** `billing_settings`
posílá přes auditní trigger do `audit_log` **IBAN a IČO dodavatele v plném znění**
(v `old_data` i `new_data`). Čtení `audit_log` je kryté admin-only politikou, takže
únik to není — ale seznam toho, o co by při smazání či úniku šlo, se rozrostl
o bankovní spojení haly. Verdikt „bez cesty k němu" platí dál, závažnost dopadu
při případném otevření cesty stoupla.

Nehoří to tedy, ale je to **latentní zesilovač**: `TRUNCATE` je jediná operace,
na kterou se RLS nevztahuje, takže první RPC s dynamickým SQL nebo edge funkce
s uživatelským vstupem v dotazu ji zpřístupní — a nic by to nezachytilo.
`REVOKE` je nulová změna chování, proto do A5.

**Návrh:** `REVOKE TRUNCATE, DELETE ON settings, subjects, audit_log, reservations
FROM anon, authenticated;` a `REVOKE ALL ON settings, subjects FROM anon;`

### 8f) `profiles.bank_account` čte každý přihlášený · **→ A5**

**Zaevidováno 12. 8. 2026** (bezpečnostní brána A3). Politika
`Anyone authenticated can read profiles USING (true)` plus plné sloupcové granty
znamenají, že si běžný člen přečte přes REST **cizí bankovní účty a telefony**:

```
{"full_name":"Test Instruktor","phone":"+420700000002","bank_account":"1000000002/0800"}
```

Je to starší dluh, ne A3 — ale je absurdní chránit IBAN haly na úroveň „nikdo kromě
admina", zatímco čísla účtů brigádníků jsou na jeden GET.

**Rozhodnutí PM (12. 8. 2026), řeší A5:** citlivá pole profilu vidí **jen vlastník
a admin**, nikdo jiný. Neplatí to jen pro `bank_account` — stejnou logikou projít
i ostatní citlivá pole (telefon, adresa, datum narození, rodné číslo, pokud tam je).
Součástí musí být ověření, že tím nepadne žádná legitimní cesta: výplaty jsou
admin-only, takže by nemělo, ale chce to potvrdit útokem i průchodem UI.

### 8e) Korekce hodin nemá horní mez ani povinný důvod · **→ A5**

`corrected_hours = 9999.75` na jednohodinové rezervaci projde — to je faktura
na šest milionů. `correction_reason` není vynucený žádným constraintem, takže
korekce může být bez zdůvodnění.

**Rozhodnutí PM (12. 8. 2026), řeší A5:**
- **Tvrdý absolutní strop 24 h**, NEvázaný na délku rezervace. Rezervace je vždy
  v rámci jednoho dne a otevírací okno je nejvýš 7–22, tedy 15 h; 24 h je pohodlná
  rezerva, která nezablokuje nic legitimního, ale z překlepu „9 999" udělá okamžitý
  blok. Vázat strop na rezervovaný čas se **zamítá** — zablokovalo by to běžný
  případ „klub použil led o půl hodiny déle, naúčtuj mu víc, než měl rezervováno".
- **`correction_reason` povinný CHECKem**, sedí na požadavek „musí být vidět,
  kdo co a proč zadával".
Až vznikne UI pro korekce, přidat i `parseKorekce` v `money.ts` (dnes se
`corrected_hours` z frontendu jen čte).

### 8g) ~~`rate_per_hour` nemá horní mez~~ — VYŘEŠENO 13. 8. 2026 (strop 50 000 Kč/h)

**Zaevidováno 12. 8. 2026** (bezpečnostní brána A5).

A5 dala `corrected_hours` tvrdý strop 24 h, aby z překlepu „9999" byl okamžitý blok.
Druhý činitel v součinu ale zábranu nemá žádnou — ověřeno:

```
UPDATE reservations SET rate_per_hour = 99999999;
→ amount 99999999.00 | corrected_amount 299999997.00
```

`hours` ohlídané je (`validate_reservation_slot`: celé hodiny, jeden den, otevírací
doba → nejvýš ~15 h), takže **`rate_per_hour` je jediný neomezený peněžní vstup
v systému**. Překlep o řád v sazbě udělá tutéž fakturu na miliony jako překlep
v korekci, který A5 zavřela.

**Proč to A5 neudělala sama:** hodnota stropu je produktové rozhodnutí, ne technikálie —
stejně jako u korekce, kde ho určil PM. Vzor je připravený (CHECK + srozumitelná
hláška v `check_reservation_money`), chybí jen číslo. Sazby jsou dnes 600–1500 Kč/h.

**Opraveno** migrací `20260813120000_strop_sazby.sql` po rozhodnutí PM (strop
50 000 Kč/h). CHECK dostaly **všechny čtyři zdroje** sazby, ne jen `reservations`:
sazba se tam dopočítává z ceníku a ze `subjects.default_rate`, takže strop jen na
rezervaci by šlo obejít zápisem do ceníku. Hlídá to `supabase/tests/strop_sazby_test.sql`
(19 tvrzení, včetně cest přes `create_booking`, `create_booking_series` a `update_booking`).

Dvě věci, které se u toho ukázaly a patří sem, ne do commit message:

- **Strop mimochodem zavřel `NaN`.** `'NaN'::numeric >= 0` je true a
  `'NaN' <> round('NaN')` je false, takže `NaN` prošla všemi peněžními kontrolami
  A2 i A5. Chytí ji až porovnání se stropem.
- **Nad 10^8 mluví Postgres anglicky.** `p_rate := 1e10` skončí na
  `numeric field overflow`, protože koerce na `numeric(10,2)` proběhne dřív, než
  trigger dostane slovo. Není to regrese (chovalo se to tak vždycky) a frontend
  to nepustí, ale záruka „hranice API mluví česky" má tady díru. Zavřelo by ji
  ověření `p_rate` uvnitř RPC před INSERTem.

Na fakturační vrstvě strop **není** a zatím být nemusí: `invoice_items.sazba` má
jen `>= 0`, ale jediný, kdo do ní zapisuje, jsou RPC z B5 — a ty berou sazbu
i částku **ze snapshotu rezervace**, nikdy od volajícího. Kdo tam bude přidávat
parametr, musí to rozhodnutí zopakovat, jinak se strop na dokladu obejde.

### 8h) Výchozí práva `supabase_admin` migrace nezmění · **na vědomí**

A5 odebrala `TRUNCATE` plošně a upravila výchozí práva role `postgres`, takže nová
tabulka založená migrací ho nedostane. Supabase má ale ještě výchozí práva role
`supabase_admin`, na která `ALTER DEFAULT PRIVILEGES` z migrace nedosáhne (na
hostované instanci není `postgres` superuser). Uplatní se jen na tabulky vytvořené
`supabase_admin` — tenhle projekt je tak nevytváří (všech 16 tabulek vlastní
`postgres`), ale kdyby někdo založil tabulku přes Studio, dostane `TRUNCATE` pro
`anon`. Hlídá to test v `security_hardening_test.sql`.

---

## Doporučené pořadí oprav (návrh do dalších fází, nezávazné)

1. Doplnit řazení `instructor/bar_staff/manager` do `get_user_role` a highest-role logiky.
2. Projít a zúžit „read = true" RLS politiky podle skutečné potřeby.
3. Rozhodnout o sjednocení stavů směn (`shifts` vs. `shift_applications`).

Každá oprava: samostatná migrace nad baseline → databázová brána → bezpečnostní brána → PM.
