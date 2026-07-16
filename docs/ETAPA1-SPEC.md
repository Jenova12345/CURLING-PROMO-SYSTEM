# Etapa 1 — Specifikace: Rezervace ledu + podklady pro fakturaci

*Curling hala. Hlavní podklad pro implementaci. Staví na stávajícím systému (Supabase), nic z něj nemaže.*

---

## 1. Cíl Etapy 1

Systém umí rezervovat led a dát přehled: **kdo (klub / komerční akce) byl kdy a jak dlouho na ledě a kolik za to dluží.** Faktury se ještě negenerují — to je Etapa 2. Etapa 1 končí u podkladů („firma/klub měl tyhle časy → tolik dluží").

---

## 2. Zamčená rozhodnutí

- Fakturuje se podle **rezervovaných hodin** s možností **ruční korekce** adminem.
- **Kluby si rezervují samy** (přihlášený zástupce), **komerční akce zadává Jakub** (admin).
- **Různé sazby** podle typu subjektu (klub vs. komerční).
- Dva typy fakturačního subjektu: **klub** (MK, Curling Ostrava, nové kluby) a **komerční zákazník** (firma, načtená přes ARES podle IČO).
- **Kolize:** jeden slot na jednom plátně = jen jedna rezervace (technicky vynuceno). Přeobsadit smí jen admin, ručně, s důvodem a auditem.
- **2 plátna**, typický slot **1,5 h**, otevírací doba **nastavitelná** (default 8:00–22:00).

---

## 3. Datový model

### Nové tabulky

**`subjects`** — fakturační subjekty
- `id`, `type` (`club` | `commercial`), `name`
- `ico`, `dic`, `address` (vyplněné z ARESu u komerčních, u klubů volitelné)
- `default_rate` (Kč/h, volitelný override sazby pro konkrétní subjekt)
- audit: `created_by`, `created_at`, `updated_by`, `updated_at`, `deleted_at`

**`subject_reps`** — napojení přihlášeného uživatele na klub (kdo smí rezervovat za který klub)
- `id`, `subject_id` → subjects, `user_id` → profiles, `created_at`
- (Jen kluby mají zástupce, kteří se přihlašují. Komerční zákazníci se nepřihlašují.)

**`sheets`** — plátna
- `id`, `name` (Plátno 1 / Plátno 2), `active`. Naplnit 2 řádky.

**`reservations`** — rezervace
- `id`, `sheet_id` → sheets, `subject_id` → subjects
- `start_at`, `end_at` (timestamptz)
- `status` (`confirmed` | `cancelled`)
- `rate_per_hour` (snapshot sazby v době rezervace — pozdější změna ceníku nemění minulé rezervace)
- `hours` (spočítané z start/end), `amount` (hours × rate_per_hour)
- `corrected_hours`, `corrected_amount`, `correction_reason` (volitelná ruční korekce adminem)
- `note`
- audit: `created_by`, `created_at`, `updated_by`, `updated_at`, `deleted_at`
- **Constraint:** zákaz překryvu na stejném plátně pro `status = confirmed` a `deleted_at IS NULL` (Postgres exclusion constraint nad `tstzrange(start_at, end_at)` + `sheet_id`).

**`settings`** — konfigurace (klíč–hodnota nebo pár sloupců)
- `club_default_rate`, `commercial_default_rate` (Kč/h)
- otevírací doba po dnech v týdnu

**`audit_log`** — historie změn
- `id`, `table_name`, `record_id`, `action` (insert/update/delete/override), `changed_by`, `changed_at`, `old_data` (jsonb), `new_data` (jsonb)
- plněno triggery na klíčových tabulkách (reservations, subjects, settings)

### Napojení na stávající
- `profiles` a `user_roles` zůstávají. Rezervační práva řešíme přes roli **admin** + tabulku `subject_reps` (zástupce klubu). Stávající role pro směny se nemění.

---

## 4. Role a práva

- **admin (Jakub):** vše — správa subjektů, plátna, sazby, otevírací doba, všechny rezervace, přeobsazení, přehled „kdo kolik dluží", ruční korekce.
- **zástupce klubu:** rezervace a rušení jen za **svůj** klub, přehled využití jen svého klubu. Nevidí cizí kluby ani jejich čísla.
- **komerční zákazník:** nemá přihlášení, zadává ho admin.
- Vše chráněno přes RLS (přístup jen pro přihlášené, práva podle role/napojení).

---

## 5. Rezervační logika a kolize

1. Volný slot → zástupce klubu (nebo admin) rezervuje → **hned potvrzeno a zamčeno**.
2. Obsazený slot ostatní vidí jako obsazený, nejde na něj kliknout. Dvojitá rezervace je technicky nemožná (exclusion constraint).
3. **Přeobsazení / storno cizí rezervace:** jen admin, ručně, s uvedeným důvodem. Dotčený klub dostane upozornění. Zapíše se do `audit_log`.
4. Rušení = soft (status `cancelled`), historie zůstává.

---

## 6. Sazby a výpočet „kdo kolik dluží"

- Sazba rezervace = `subjects.default_rate` ?? default podle typu (`club_default_rate` / `commercial_default_rate`), uložená jako snapshot na rezervaci.
- Dlužná částka = `(corrected_hours ?? hours) × rate_per_hour`.
- **Přehled:** filtr období (den / týden / měsíc), seskupení po subjektech: hodiny, částka, součet k úhradě. Denní pohled („včera: který subjekt, jak dlouho, kolik").

---

## 7. ARES napojení (komerční subjekty)

- Serverová funkce (Supabase Edge Function nebo Netlify function) volá:
  `GET https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/ekonomicke-subjekty/{ICO}`
- Zdarma, bez klíče. Mapování: `obchodniJmeno` → name, `sidlo.textovaAdresa` → address, `dic` → dic.
- Ve formuláři komerčního subjektu: zadám IČO → tlačítko „Načíst z ARESu" → předvyplní název, adresu, DIČ.

---

## 8. Obrazovky

1. **Kalendář rezervací** — 2 plátna vedle sebe, denní/týdenní pohled, klik na volný slot = nová rezervace.
2. **Formulář rezervace** — výběr subjektu, plátno, čas (default 1,5 h), sazba (auto), poznámka. Zástupce klubu má předvybraný svůj klub.
3. **Správa subjektů** — seznam klubů a komerčních; u komerčního načtení z ARESu podle IČO.
4. **Přehled „kdo kolik dluží"** — filtr období, po subjektech, hodiny + částka + součet; denní pohled.
5. **Nastavení (admin)** — sazby (klub / komerce), otevírací doba, plátna.
6. **Portál** — tlačítko/odkaz na systém z nového webu, starého webu i odjinud.

---

## 9. Audit, soft-delete, zálohy

- `audit_log` + triggery na reservations, subjects, settings → „kdo co zadával".
- Soft-delete (`deleted_at`) místo tvrdého mazání; storno rezervace = status, ne smazání.
- Zálohy dle Fáze 4 (automatický pg_dump).

---

## 10. Co NENÍ v Etapě 1 (→ Etapa 2)

Generování PDF faktur, QR platba a bankovní údaje na faktuře, evidence vystavených faktur, evidence plateb (zaplaceno / nezaplaceno), online platby.
