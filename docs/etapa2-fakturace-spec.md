# Etapa 2 — Fakturační modul · Specifikace (production-ready)

**Projekt:** Rezervační systém curlingové haly — Curling Promo Ostrava
**Autor:** Tomáš Adamčík (PM) · **Verze:** návrh k odsouhlasení
**Účel:** Kompletní zadání fakturačního modulu tak, aby fungoval bezchybně v ostrém provozu. Slouží jako podklad pro vývoj (CC), pro odsouhlasení klientem (Jakub) i pro nacenění.

> Pozn.: Fakturace pracuje s penězi a zákonnými náležitostmi. Body označené **[POTVRDIT]** musí před spuštěním potvrdit klient / jeho účetní — nejsou to věci, které lze „vymyslet".

---

## 1. Cíl

Ze schválených rezervací automaticky i ručně vytvářet právně korektní faktury (PDF), evidovat je, hlídat zaplacení a bezpečně ukládat. Systém navazuje na existující data (rezervace, subjekty z ARESu, ceník, „Kdo kolik dluží") — nic nepočítá znovu, jen z toho vystaví doklad.

## 2. Dva typy dokladů

**A) Faktura za komerční akci — průběžně / denně**
- Vzniká z proběhlé komerční akce (teambuilding firmy).
- Odběratel = firma (údaje z ARESu: název, sídlo, IČO, DIČ).
- Obsah: 1 doklad = 1 akce; položky podle drah/hodin, sazba, celkem.

**B) Souhrnná faktura klubu — měsíční**
- Vzniká k poslednímu dni v měsíci za všechny zpoplatněné rezervace klubu.
- Odběratel = klub.
- Obsah: **řádek = jedna rezervace** (datum, čas od–do, kdo objednal / název akce, hodiny, sazba, cena), pod tím celkový součet, hlavička klubu.
- Interní akce (tréninky bez fakturace / údržba) se nezapočítávají — stejná logika jako dnešní „Kdo kolik dluží".

## 3. Povinné náležitosti faktury (zákon)

Systém musí umět obojí; výchozí režim **[POTVRDIT: je hala plátce DPH?]**.

**Neplátce DPH (předpokládaný výchozí stav):**
- Označení „Faktura" + evidenční číslo
- Dodavatel: název, sídlo, IČO
- Odběratel: název, sídlo, IČO
- Datum vystavení, datum splatnosti
- Popis plnění (pronájem ledové plochy / komerční akce…)
- Množství (hodiny) a cena, celková částka k úhradě
- Platební údaje: číslo účtu, variabilní symbol
- Doložka „Nejsme plátci DPH."
- ⚠️ Neplátce **nesmí** uvádět sazbu ani výši DPH (jinak mu vzniká povinnost daň odvést).

**Plátce DPH (pokud se potvrdí):** navíc DIČ obou stran, datum uskutečnění zdanitelného plnění (DUZP), základ daně / sazba DPH / výše DPH zvlášť pro každou sazbu, celkem s DPH.

## 4. Číslování (číselná řada)

- Souvislá, bez děr, neopakuje se. **[POTVRDIT formát]** — návrh: `RRRRNNNN` (např. `20260001`), reset pořadí každý rok.
- Variabilní symbol = číslo faktury bez nečíselných znaků.
- Číslo se přiděluje až při **vystavení** (ne u konceptu), atomicky (DB sekvence / počítadlo v transakci), aby při souběhu nevznikly duplicity.
- **[POTVRDIT]** jedna společná řada, nebo oddělené řady pro komerční vs. klubové faktury.

## 5. Workflow a automatizace

**Denní běh (komerční):** naplánovaná úloha 1×/den projde komerční akce, které už **skončily** a ještě **nejsou vyfakturované** → vytvoří faktury. Idempotentní: každá akce vyfakturována právě jednou (rezervace nese `invoice_id`).

**Měsíční běh (kluby):** k poslednímu dni v měsíci **[POTVRDIT: poslední den, nebo 1. den následujícího?]** vytvoří za každý klub souhrnnou fakturu za daný měsíc.

**Manuální režim:** admin může kdykoli vytvořit/dogenerovat fakturu ručně (tlačítko u subjektu / v přehledu „Kdo dluží"), např. když chce fakturovat dřív. Automatika a ruční tvorba se nesmí prát (kontrola „už fakturováno").

**Náhled před vystavením:** volitelně režim „koncept" ke kontrole, pak jedním klikem „Vystavit".

## 6. Ukládání a pojmenování

- Zdroj pravdy: PDF v úložišti systému (Supabase Storage) + metadata v DB.
- Pojmenování dle Kubova zadání, konfigurovatelné: `<pořadí>_<identifikátor>_<DDMMYY>` → `001_hybridní_curling_220826`. **[POTVRDIT: co znamená „hybridní" — název fakturujícího subjektu / projektu?]**
- Měsíční export: stažení všech faktur měsíce jako ZIP; jednotlivě ke stažení kdykoli.
- **[POTVRDIT]** volitelně automatická kopie do sdílené složky (Google Drive) — pokud Kuba chce mít „složky" i mimo systém. (Doporučuji systém jako zdroj pravdy, Drive jen jako kopii.)

## 7. Platba

- QR Platba (standard SPAYD / ČBA) přímo na faktuře: IBAN účtu, částka, měna CZK, variabilní symbol, zpráva.
- **[POTVRDIT]** bankovní účet (IBAN), výchozí splatnost (návrh 14 dní), text zprávy pro příjemce.

## 8. Datový model (doplnění DB)

- `invoices` — id, typ (komerční/klub), číslo, VS, subjekt_id, datum vystavení, splatnost, DUZP, stav, měna, celkem bez/s DPH, cesta k PDF, audit (kdo/kdy).
- `invoice_items` — id, invoice_id, rezervace_id, popis, datum, čas od–do, hodiny, sazba, cena.
- `invoice_counter` — řada + rok + poslední pořadí (atomické přidělování).
- `billing_settings` — údaje dodavatele (název, sídlo, IČO, DIČ, účet/IBAN, plátce DPH ano/ne, výchozí splatnost, texty).
- `subjects` — doplnit fakturační pole (už máme IČO/DIČ/adresa z ARESu; ověřit úplnost).
- `reservations` — přidat `invoice_id` (vazba „už fakturováno").

## 9. Stavy faktury

`koncept → vystaveno → zaplaceno` · vedle toho `po splatnosti` (automaticky dle data) a `stornováno`.
- Evidence plateb: admin označí „zaplaceno" (datum úhrady). **[POTVRDIT]** — ruční, nebo napojení na bankovní výpis (to je nadstavba nad rámec Etapy 2).

## 10. Opravy a storno

- Vystavená faktura se needituje. Oprava = **opravný daňový doklad / dobropis** s vlastním číslem a odkazem na původní.
- Když se **zruší už vyfakturovaná** rezervace → nabídnout dobropis.
- Ceny jsou uložené jako snapshot u rezervace, takže pozdější změna ceníku fakturu nezmění (už dnes takto funguje).

## 11. Okrajové případy k ošetření

- Akce přes půlnoc / na konci měsíce (do kterého období spadá) **[POTVRDIT pravidlo]**.
- Nulová/prázdná faktura (klub bez zpoplatněných akcí) → nevystavovat.
- Zaokrouhlování na celé koruny, měna CZK.
- Firma bez IČO / neúplné údaje → fakturu nevystavit, upozornit admina.
- Souběh automatiky a ručního vystavení → zámek proti duplicitě.

## 12. Bezpečnost a audit

- Faktury a fakturační nastavení vidí a spravuje jen **admin** (RLS). Ceny zůstávají skryté ostatním rolím.
- Každý doklad má auditní stopu (kdo vystavil, kdy, kdo označil zaplaceno / stornoval).
- Zálohy PDF i dat.

## 13. Co potřebujeme od klienta (dotazník) — **[POTVRDIT]**

1. Je hala plátce DPH? (mění náležitosti dokladu)
2. Fakturující subjekt: přesný název, sídlo, IČO (a DIČ, pokud plátce).
3. Bankovní účet / IBAN pro QR platbu a výchozí splatnost (14 dní?).
4. Formát čísla faktury a zda oddělené řady pro komerční vs. klubové.
5. Význam „hybridní" v názvu složky / jaký prefix používat.
6. Měsíční faktury generovat poslední den v měsíci, nebo 1. den následujícího?
7. Kam ukládat: stačí v systému (+ZIP ke stažení), nebo i kopie do Google Drive?
8. Evidence zaplacení ručně, nebo chce napojení na banku (nadstavba)?

## 14. Akceptační kritéria (Definition of Done)

- Komerční akce po skončení → automaticky vznikne faktura se správnými údaji z ARESu, číslem, VS, QR platbou; PDF má všechny zákonné náležitosti pro daný režim (plátce/neplátce).
- K poslednímu dni měsíce → za každý klub souhrnná faktura, řádek = rezervace, sedící součet.
- **Kontrolní součet:** suma vystavených faktur za období == částka v „Kdo kolik dluží" za totéž období (žádný rozdíl).
- Číselná řada souvislá i při souběžném vystavení; žádné duplicity.
- Storno → dobropis se správným odkazem.
- Faktury dostupné ke stažení jednotlivě i jako měsíční ZIP; správné pojmenování.
- Vše jen pro admina; audit sedí; zálohy běží.

## 15. Fázování a nacenění

- **Jádro Etapy 2** (oba typy dokladů, náležitosti, číslování, QR, ukládání, storno, evidence zaplaceno ručně, automatika denní+měsíční): **20 000–30 000 Kč** — přesně dle rozsahu potvrzeného v dotazníku.
- **Nadstavby mimo Etapu 2** (naceníme zvlášť): automatické párování plateb z bankovního výpisu, napojení na účetní software, hromadné upomínky.

---

*Tento dokument je návrh specifikace k odsouhlasení. Po vyplnění dotazníku (bod 13) rozsah a cenu finalizujeme a spustíme vývoj.*
