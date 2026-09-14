# E-mailové notifikace — jak to jede a co zapnout

Provozní list k e-mailovým notifikacím. Stav produkce v tabulce níž je
**změřený dotazem**, ne odhadnutý.

---

## Stav produkce (curling-promo-prod, `fcwubbytqxubgptftnru`)

Změřeno dotazem **14. 9. 2026 v 16:20**, po nasazení migrace `20260914160000`.

| Co | Hodnota | Co to znamená |
|---|---|---|
| `settings.email_notifications_enabled` | **`true`** | **Fronta se PLNÍ.** Řádky do `email_outbox` vznikají. |
| řádků v `email_outbox` | 6 | Všech 6 má `status = 'sent'`, ve frontě nečeká nic. |
| `pg_net` | není | Plánovač v databázi neběží a nebude, viz níž. |
| `pg_cron` | není | Totéž. |
| poslední migrace | `20260914160000` | Adresa portálu se bere z `settings`, ne z kódu. |
| strop `email_max_za_hodinu` | `100` | Nasazený a je i uvnitř `email_outbox_prevzit`. |
| index `idx_email_outbox_claimed` | je | Starý `idx_email_outbox_user_claimed` zahozen. |

> ⚠️ **Dřívější znění téhle tabulky tvrdilo, že je fronta VYPNUTÁ** (`false`,
> 0 řádků, poslední migrace `20260912220000`) — a to se stejným razítkem
> „změřeno dotazem 14. 9. 2026". Nebyla to pravda a stálo to za pozornost:
> `notify_user` běží v živé cestě `create_booking`, takže na tom, jestli se
> e-mailová větev vůbec prochází, záleží víc než na pohodlí. Kdo tuhle tabulku
> aktualizuje, ať přiloží dotaz, ne dojem.

## Chyba notifikace rezervaci neshodí (od `20260914180000`)

`notify_user` má od té migrace dva vnořené `EXCEPTION` bloky: selže-li e-mail,
notifikace v aplikaci zůstane; selže-li i ta, rezervace stejně vznikne. Každá
spolknutá chyba jde do `public.notifikace_chyby` (čte ji **jen admin**) a do logu
Postgresu jako `WARNING`.

**Prázdná `notifikace_chyby` = notifikace jedou.** Řádky v ní znamenají, že se
někomu nedoručila zpráva, i když jeho rezervace vznikla. Dnes na to v aplikaci
není obrazovka ani alert — jediná cesta je dotaz:

```sql
SELECT created_at, faze, sqlstate, left(chyba, 120) FROM public.notifikace_chyby
 ORDER BY created_at DESC LIMIT 20;
```

Tabulku nic nerotuje (`pg_cron` na produkci není), takže poroste. Při zapínání
odesílatele je to jedna z věcí k dořešení.

### Cena za tu pojistku: subtransakce (změřeno, a vyšlo to hůř než odhad)

Každý `EXCEPTION` blok je subtransakce. Jedno volání `notify_user` teď stojí
**2 subxid** (před migrací `20260914180000` stálo 0); backend jich cachuje
**64**, takže práh je **32 volání v jedné transakci**.

| případ | volání | XID | z 64 slotů |
|---|---|---|---|
| běžná rezervace člena | 5 | 12 | ≈ 19 % |
| **přebití obou velkých klubů** | **36** | **73** | **≈ 114 %** |
| strop produkce (všechny dvojice) | 56 | ~113 | ≈ 176 % |

**Práh se tedy už dnes překračuje** — v komerční akci, která přebije led oběma
velkým klubům. Není to chyba správnosti ani ztráta dat: přelitá cache znamená,
že cizí backendy dohledávají viditelnost v `pg_subtrans`. Při zátěži jedné haly
to nejspíš nikdo nepozná. Ale odstup tam **není** a nesmí se tvrdit, že je.

Pozor na dvě věci, které se při odhadu snadno přehlédnou (přehlédli jsme je
oba, já i brána migrací, každý jinam): smyčka `reservation_overridden`
v `create_booking` **nefiltruje podle `level`**, takže jde i přes členy, ne jen
přes zástupce — a navíc přidává autora rezervace přes `UNION SELECT
rr.created_by`, což na produkci přihodí 20 dvojic, které v `subject_reps`
vůbec nejsou.

> ⚠️ Komentář v migraci `20260914180000` uvádí „34 volání = 68 subxid" — je to
> **podstřelené** a neopravuje se přepisem (migrace jsou dopředné). Opravu nese
> `20260914190000`, která ji zapsala do komentářů `notify_user`
> a `create_booking`, kde ji čtenář té smyčky uvidí.

Kdyby se někdy hlásilo, že přebíjení ledu trvá dlouho nebo že u toho zlobí celý
systém, tohle je první podezřelý. Řešení není odebrat handlery, ale nevolat
`notify_user` 36× v jedné transakci — zakládat zprávy dávkově jedním
`INSERT ... SELECT`, nebo smyčku vytáhnout z transakce.

> ⚠️ **Commit messages ohledně nasazení nečti** — nesou značku „NENASAZENO"
> z doby, kdy vznikly, a přepisovat historii se nebude. Stav produkce se čte
> z `supabase_migrations.schema_migrations`, nikde jinde.

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

✅ Obě jsou na produkci nasazené od 14. 9. 2026 (krok 0 níž).

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

> ⚠️ **POŘADÍ NENÍ LIBOVOLNÉ A KROK 0 SE NESMÍ PŘESKOČIT.** Kdo přeskočí nulu,
> zapne rozesílání **bez obou pojistek proti záplavě**: bez stropu
> `email_max_za_hodinu` a se zrušením série, které pošle jeden e-mail za každý
> termín. Přesně ten scénář, kvůli kterému obě pojistky vznikly. Našla
> bezpečnostní brána 13. 9. 2026. Na produkci je krok 0 od 14. 9. 2026 hotový,
> ale platí to pro každé další prostředí i pro obnovu ze zálohy.

### 0) Nasadit migrace — PRVNÍ, ne až potom

✅ **HOTOVO 14. 9. 2026.** Všechny tři nasazené přes `scripts/safe-deploy.sh`,
jedna po druhé, každá s vlastní čerstvou zálohou (`backups/prod-2026-09-14-*`).
Zůstává tu popsané pro případ obnovy ze zálohy nebo nasazení na další prostředí.

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

⚠️ Na jinou adresu než `https://fcwubbytqxubgptftnru.supabase.co` plánovač
servisní klíč **neodešle** — ref produkčního projektu je připnutý přímo v kódu
(`netlify/lib/fronta-emailu.mts`). Je to schválně: kdo umí přepsat proměnnou
v Netlify, jinak přesměruje klíč na vlastní projekt na `supabase.co` a přečte
si ho. Kdyby se projekt někdy stěhoval, mění se i ten řádek v kódu.

* Scope nastav **Functions only** a zaškrtni **„Contains secret values"**.
  Scope „All" by ten klíč dal i do prostředí `vite build`, kde nemá co dělat.
* Jména se čtou doslova. Překlep = funkce se spustí, **nic nezavolá**
  a napíše do logu proč. Nic se tím nerozbije.

⚠️ **Po vložení proměnné spusť nový deploy** (Deploys → Trigger deploy →
Deploy site), případně pushni cokoli. Dokumentace Netlify to sice výslovně
neříká, ale scope „Functions" se váže na nasazení, takže už publikované
nasazení novou proměnnou vidět nemusí. Než se to potvrdí, je levnější
redeploy udělat než ladit, proč funkce hlásí „Chybí
SUPABASE_SERVICE_ROLE_KEY", když je proměnná vidět v UI.

**Jak poznat, že funkce jede:** naplánovanou funkci nejde zavolat URL, ale
`curl -o /dev/null -w '%{http_code}' https://<web>/.netlify/functions/posli-emaily`
vrátí **403**, když je zaregistrovaná. Když vrátí 200 (obsah `index.html`),
spadlo to do SPA redirectu a funkce nasazená není.

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
