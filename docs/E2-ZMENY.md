# Etapa 2 — úpravy podle feedbacku klienta (Jakub)

Stav ke dni **31. 7. 2026**, větev `dev`. Vše ověřeno na **lokálním** Supabase
(`supabase db reset` + `supabase/tests/rezervace_test.sql`). **Na produkci se nic neaplikovalo.**

---

## Co se změnilo (podle bodů zadání)

| # | Požadavek | Jak je to udělané |
|---|---|---|
| 1 | Rebrand „Mladé kameny" → **Curling Promo Ostrava** | Název systému je na jednom místě (`src/config/brand.ts`) + `index.html`, `public/manifest.json`. Logo v aplikaci zatím **žádné není** (na přání klienta) — všude je jen textový název. |
| 2 | „plátno" → **„dráha"** | Texty v aplikaci + migrace přejmenovala data (`Plátno 1/2` → `Dráha 1/2`). Tabulka se dál jmenuje `sheets` (přejmenování tabulky by nic nepřineslo a rozbilo vazby). |
| 3 | Rezervace **obou drah najednou** | Ve formuláři jsou zaškrtávátka drah. Jedna akce může mít víc rezervací (po jedné na dráhu); anti-kolizní constraint dál hlídá každou dráhu zvlášť. Storno nabízí „jen tuhle dráhu" / „celou akci". |
| 4 | **Skrytí ceny** | Název klubu/akce vidí každý přihlášený, **částku jen admin a autor rezervace**. Vynuceno v databázi: role `authenticated` nemá právo číst cenové sloupce tabulky `reservations`, čte se přes maskující view `reservations_calendar`. Nejde to obejít ani ručním voláním API. |
| 5 | **ARES bez duplicit** | Před založením firmy se serverovou funkcí `find_subject_by_ico` ověří, jestli IČO už v systému není — pokud ano, použije se stávající subjekt. Navíc unikátní index na IČO (nesmazané subjekty). |
| 6 | **Auto-název komerční akce** | Po výběru firmy se název předvyplní na „Teambuilding \<firma\>" a jde přepsat. |
| 7 | **Otevírací doba 7:00–22:00** | Výchozí hodnota v nastavení (admin ji může změnit po dnech). Rezervaci mimo otevírací dobu odmítne databáze, ne jen formulář. |
| 8 | **Kolize na jedné dráze** | Ověřeno testem: druhý uživatel dostane českou hlášku („Dráha 1 je v tomto čase už obsazená…"), ne pád. Souběh hlídá exclusion constraint v DB. |
| 9 | **Typy akcí + priorita + sazby** | Trénink / Turnaj / Komerční akce / Údržba ledu, každá s názvem. Priorita: údržba (40) > komerční (30) > turnaj (20) > trénink (10). Sazby se předvyplňují podle typu z ceníku v Nastavení. |
| 10 | **Instruktor u komerční akce** | Bez aspoň jednoho instruktora akci nejde založit (kontroluje formulář i databáze). Počet se předvyplní podle počtu drah, ručně jde změnit. |
| 11 | **Pravidelné tréninky** | Ve formuláři: opakovat každý týden, výběr dnů (Po–Ne), datum konce. Vytvoří sérii; kolizní termíny přeskočí a vypíše které. Limit: rok dopředu, max 200 termínů. |
| 12 | **Notifikace při přebití** | Přebít smí jen admin a jen vědomě (potvrzovací dialog s výpisem, co se zruší). Všichni lidé napojení na dotčený klub dostanou upozornění „Vaše akce byla zrušena kvůli komerční události". |
| 13 | **Role a schvalování** | Hobby hráč (jen kouká) → člen klubu (rezervuje, edituje svoje) → zástupce klubu (celý klub, potvrzuje; může jich být víc) → admin. Rezervace člena drží slot, ale je označená „čeká na potvrzení"; zástupci dostanou upozornění, po potvrzení dostane autor zprávu. |
| 14 | **Výběr času roletkou** | Roletky po celých hodinách, omezené otevírací dobou daného dne. Rezervace jen na celé hodiny (hlídá i databáze). |
| 15 | **Drag & drop** | Rezervaci lze myší přetáhnout na jiný čas/den/dráhu (skok po celých hodinách). Akce na obou drahách se posune celá. Na dotykových zařízeních je tažení vypnuté, aby nebralo scrollování. |
| 16 | **Audit „kdo vytvořil / kdo zrušil"** | V detailu rezervace je vidět kdo a kdy zadal, kdo potvrdil, a u storna kdo, kdy a proč. U směn je vidět, kdo akci zadal. |

---

## Jak to funguje uvnitř (pro příští úpravy)

### Serverové API místo přímých zápisů
Rezervace se zakládají přes databázové funkce (`public.create_booking`,
`create_booking_series`, `update_booking`, `move_booking`, `cancel_booking`,
`approve_reservation`, `check_booking_conflicts`). Důvod: obě dráhy, série a přebití
musí proběhnout v **jedné transakci** — přes běžné REST volání by při chybě zůstaly
poloviční záznamy. Funkce jsou `SECURITY DEFINER` a **práva si ověřují samy**;
guard trigger je pouští přes transakčně lokální GUC `app.trusted_booking`.

### Kde se co vynucuje
- **celé hodiny + otevírací doba** → trigger `validate_reservation_slot`
- **kolize na dráze** → exclusion constraint `reservations_no_overlap`
- **kdo co smí** → RLS politiky + guard trigger + kontroly v RPC funkcích
- **cena** → sloupcová práva na tabulce + maskující view
- **upozornění** → triggery (`notify_reservation_approval`) a RPC (přebití)

### E-maily
Notifikace v aplikaci fungují. E-mail je připravený, ale **vypnutý**:
- fronta `public.email_outbox` se plní jen když admin zapne
  `settings.email_notifications_enabled` (výchozí `false`),
- edge funkce `supabase/functions/send-emails` bez `RESEND_API_KEY` nic neodešle.

Až padne rozhodnutí o poskytovateli (Resend / SMTP) a doméně:
```bash
supabase secrets set RESEND_API_KEY=… EMAIL_FROM="Curling Promo Ostrava <rezervace@…>"
supabase functions deploy send-emails
```
a naplánovat pravidelné volání (pg_cron / Supabase Scheduler).

---

## Testy

```bash
supabase db reset                      # migrace + demo seed
docker exec -i supabase_db_<projekt> psql -U postgres -X -q -v ON_ERROR_STOP=1 \
  < supabase/tests/rezervace_test.sql  # 30 kontrol, na konci „VŠECHNY TESTY PROŠLY"
```
Testy pokrývají: obě dráhy, kolize, celé hodiny, otevírací dobu, schvalování členem
i zástupcem, komerční akci bez instruktora, přebití + notifikace, opakování, přesun,
storno (jedna dráha vs celá akce), maskování ceny a duplicitní IČO.

---

## Nasazení dema

```bash
./scripts/build-demo-sql.sh     # vygeneruje demo_setup.sql (migrace + seed)
```
Výsledek se pouští **ručně v SQL editoru DEMO projektu** (`ltrazktulfxvzlvkxdsb`),
nikdy na produkci. Skript vkládá `COMMIT;` za migraci s novou hodnotou enumu —
bez toho by Postgres odmítl použít typ `tournament` ve stejné transakci.

---

## Co zůstává otevřené

1. **Logo** — v aplikaci žádné není, jen textový název (rozhodnutí klienta z 1. 8.).
   Až finální podklad přijde, bude potřeba: obrázek do hlavičky a přihlašovací
   obrazovky, **PNG 180×180** pro `apple-touch-icon` (iOS u téhle ikony SVG
   nepodporuje), `icons` zpět do `public/manifest.json` a v `og:image`/`twitter:image`
   **absolutní URL** — jinak náhledy odkazu na Facebooku a X zůstanou bez obrázku.
2. **Sazby** — migrace je záměrně nechává prázdné (v produkci se nesmí účtovat podle
   vymyšlených čísel). Placeholder hodnoty jsou jen v demo seedu; admin je vyplní
   v Nastavení.
3. **E-mailový poskytovatel** — viz výše, čeká na rozhodnutí a klíč.
4. **Sazba za trénink vs turnaj u klubů** — klub si volbou typu akce (trénink / turnaj)
   sám vybírá, kterou sazbou se bude účtovat. U komerčních zákazníků to neplatí
   (ti jedou komerční sazbou vždy). Buď necháme obě klubové sazby stejné, nebo bude
   turnaj potřebovat schválení správcem.
5. **Nepotvrzená rezervace člena drží led bez omezení** — pokud ji zástupce nepotvrdí
   ani nezruší, blokuje termín donekonečna. Zvážit expiraci (např. 48 hodin).
4. **Produkční nasazení** — migrace `20260731*` nejsou na produkci. Před nasazením:
   čerstvá záloha + souhlas PM. Napřed ověřit `SELECT id, name FROM public.sheets;` —
   přejmenování hledá názvy začínající na „Plátno"; pokud je admin v produkci
   přejmenoval jinak, je potřeba migraci upravit. Dál pozor na dvě věci:
   - unikátní index na IČO spadne, pokud jsou v produkci duplicity (migrace to řekne
     jasnou hláškou a data nezmění);
   - staré rezervace na půl hodiny zůstanou beze změny; validace celých hodin platí
     jen pro nové a pro změnu času.
