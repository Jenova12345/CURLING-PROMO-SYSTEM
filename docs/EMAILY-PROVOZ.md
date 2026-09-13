# E-mailové notifikace — jak to jede a co zapnout

Provozní list pro chvíli, kdy se notifikace budou zapínat. Stav produkce
v tabulce níž je **změřený dotazem**, ne odhadnutý (13. 9. 2026).

---

## Stav produkce (curling-promo-prod, `fcwubbytqxubgptftnru`)

| Co | Hodnota | Co to znamená |
|---|---|---|
| `settings.email_notifications_enabled` | `false` | Fronta se ani nenaplňuje. Nic neodejde. |
| řádků v `email_outbox` | 0 | Fronta je prázdná. |
| `pg_net` | **není** | Plánovač v databázi neběží a nebude, viz níž. |
| `pg_cron` | **není** | Totéž. |
| poslední migrace | `20260912140000` | Migrace `…160000` a `…200000` NEJSOU nasazené. |
| strop `email_max_za_hodinu` | **na produkci není** | Sloupec neexistuje a `email_outbox_prevzit` o stropu neví. Přináší ho krok 0. |

---

## Cesta jednoho e-mailu

1. **Něco se stane** (admin posune klubu trénink, přebije termín komerční
   akcí, zruší sérii). Trigger `notify_reservation_changed` založí řádek
   v `notifications`.
2. **Do fronty** — jen pokud je `email_notifications_enabled = true`.
   Trigger `notify_user` přidá řádek do `email_outbox` se sestaveným
   předmětem a tělem podle `email_sablona`.
3. **Plánovač** (Netlify, každých 5 minut) zavolá edge funkci `send-emails`
   servisním klíčem.
4. **`send-emails`** si přes RPC `email_outbox_prevzit` zamkne dávku
   (`FOR UPDATE SKIP LOCKED`), pošle ji přes Resend a zapíše výsledek.
   Mezi zprávami čeká 550 ms (Resend pouští 2 požadavky za sekundu).
   Po 5 neúspěšných pokusech řádek končí jako `failed`.

### Dvě pojistky proti záplavě

⚠️ **Obě přinášejí nenasazené migrace, viz krok 0 níž.** Na dnešní produkci
ani jedna neplatí.

* **Série a přebití jdou jako JEDNA zpráva**, ne jako N. Migrace
  `20260912160000` a `20260912200000`. Bez nich by zrušení celé sezóny
  poslalo klubu desítky e-mailů o jedné události.
* **Strop na odchozí poštu:** `settings.email_max_za_hodinu`, výchozích 100
  na uživatele a hodinu. Hlídá ho `email_outbox_prevzit`, ne odesílací
  funkce — přes strop se tedy nedá dostat ani přímým voláním funkce.
  Zprávy nad strop se **nezahazují**, jen počkají na další běh, a přednost
  mají zrušení a přebití před běžnými změnami.

---

## Proč plánovač běží zvenčí a ne v databázi

Původní návrh měl `pg_cron` + `pg_net` přímo v Supabase. Brány to zamítly
a **rozhodnutí PM je nechat ho venku**:

`CREATE EXTENSION pg_net` spustí supabasí event trigger
`issue_pg_net_access`, který udělí **`anon` i `authenticated`** USAGE na
schéma `net` a SELECT na `net._http_response`. Role `postgres` ty granty
**odebrat neumí** (udělil je `supabase_admin`). Instalace rozšíření by tedy
útočnou plochu teprve vytvořila — a s ní tabulku bez RLS, ve které by ležely
hlavičky odchozích požadavků včetně tokenu a odpovědi včetně obsahu pošty.

**Na produkci se `pg_net` neinstaluje.** Ověřeno, že tam dnes není.

---

## Co musí kdo nastavit, než se zapne

> ⚠️ **POŘADÍ NENÍ LIBOVOLNÉ A KROK 0 SE NESMÍ PŘESKOČIT.** Kdo dnes provede
> jen kroky 1–3 a přeskočí nulu, zapne rozesílání **bez obou pojistek proti záplavě** — na
> produkci dnes strop `email_max_za_hodinu` neexistuje (ověřeno: sloupec tam
> není a nasazená verze `email_outbox_prevzit` o stropu nic neví) a zrušení
> série pošle jeden e-mail za každý termín. Přesně ten scénář, kvůli kterému
> obě pojistky vznikly. Našla bezpečnostní brána 13. 9. 2026.

### 0) Nasadit obě migrace — PRVNÍ, ne až potom

Produkce je na `20260912140000`. Nenasazené a potřebné jsou:

| Migrace | Co přináší |
|---|---|
| `20260912160000_serie_jednou_a_strop.sql` | strop `email_max_za_hodinu`, přednost důležitých zpráv, série jako jedna zpráva |
| `20260912200000_prebiti_jedna_zprava.sql` | přebití termínů komerční akcí jako jedna zpráva místo N |
| `20260912220000_index_stropu_na_claimed_at.sql` | index `idx_email_outbox_claimed`, aby dotaz stropu nečetl celou frontu |

Nasazuje se **jedna po druhé** přes `scripts/safe-deploy.sh <popisek>` — udělá
čerstvý dump, ověří ho a teprve pak pustí `db push`. Ruční `supabase db push`
znamená, že jsi zálohu obešel.

Po nasazení zkontroluj, že strop opravdu existuje:

```sql
select email_max_za_hodinu from public.settings;          -- má vrátit 100
select pg_get_functiondef('public.email_outbox_prevzit(int)'::regprocedure)
       like '%max_za_hodinu%';                            -- má vrátit true
select indexname from pg_indexes where tablename = 'email_outbox'
   and indexname like '%claimed%';         -- má vrátit jen idx_email_outbox_claimed
```

### 1) Netlify → Site configuration → Environment variables

| Proměnná | Hodnota | Povinná |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | servisní klíč projektu `fcwubbytqxubgptftnru` | **ano** |
| `SUPABASE_URL` | `https://fcwubbytqxubgptftnru.supabase.co` | ne, jinak se vezme `VITE_SUPABASE_URL` |

* Scope nastav **Functions only** a zaškrtni **„Contains secret values"**.
  Scope „All" by ten klíč dal i do prostředí `vite build`, kde nemá co dělat.
* Jména se čtou doslova. Překlep = funkce se spustí, **nic nezavolá**
  a napíše do logu proč. Nic se tím nerozbije.

### 2) Supabase → Edge Functions → Secrets

| Proměnná | K čemu |
|---|---|
| `RESEND_API_KEY` | bez něj `send-emails` jen ukazuje náhled a **nic neodešle** |
| `EMAIL_FROM` | odesílatel; musí být na ověřené doméně |

`EMAIL_CRON_TOKEN` **nenastavuj** — patřila k plánovači v databázi, který
neexistuje. Bez ní je ta cesta inertní.

### 3) Teprve nakonec

`settings.email_notifications_enabled = true`. Dřív ne: dokud je `false`,
fronta se nenaplňuje a celý zbytek může běžet naprázdno libovolně dlouho.

⚠️ Než to přepneš, projdi si ještě jednou kontrolu z kroku 0. Přepnout tenhle
přepínač bez nasazeného stropu je ta nejdražší chyba, která se v tomhle
postupu dá udělat — poznáš ji až podle reputace domény.

---

## Kde se kouká, když něco nejede

* **Netlify → Functions → `posli-emaily`.** Každých 5 minut jeden běh.
  Úspěch = `[fronta e-mailů] OK: Fronta zpracována, odesláno N.`
  Servisní klíč v logu není nikdy.
* **Neúspěšný běh vrací 500**, takže je v přehledu vidět červeně. Hlídá se
  i tichá porucha: `send-emails` vrací HTTP 200 i tehdy, když spadlo do
  režimu náhledu (chybí nebo se zrotoval `RESEND_API_KEY`) nebo když selhala
  všechna odeslání. Plánovač proto soudí podle **těla** odpovědi, ne podle
  stavového kódu.
* **`select status, count(*) from email_outbox group by 1`** — `pending`
  roste a nic neubývá znamená, že plánovač nejede nebo nemá klíč.
* `last_error` u řádku říká, co vrátil Resend.

---

## Otevřené otázky na PM

1. **Retence `email_outbox`.** Dnes se nemaže nic a je to vědomé: bez
   `pg_cron` není co úklid spouští, tvrdé mazání jde proti zásadě „nic
   nemazat natvrdo" a po smazání by nešlo doložit, že e-mail odešel.
   Růst zatím nic nebolí — změřeno 100 000 řádků → dotaz stropu 1,3 ms.
   Mazat, archivovat, nebo nechat růst?
2. **Zahlcení notifikacemi.** Člen může zástupci klubu nasypat zprávy
   opakovaným zakládáním a rušením rezervace. Předchází to e-mailům (platí
   to i pro notifikace v aplikaci), strop odchozí pošty to brzdí, ale neřeší.
