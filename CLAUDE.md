# CLAUDE.md — Curling Ostrava systém

Kontext projektu pro Claude Code. Přečti si to na začátku každé session.

## O co jde

Přebíráme existující webovou aplikaci pro **curlingovou halu v Ostravě** z nástroje
Lovable do normálního repozitáře, který spravujeme přes Claude Code. Nad stávající
funkcí (správa směn a brigádníků) budeme stavět velký nový modul: **rezervační systém ledu**.

## Rozdělení rolí

- **PM (Claude v Cowork appce):** drží plán a roadmapu, píše zadání (briefy), kontroluje
  výstupy, řeší produktová rozhodnutí se zákazníkem (Tomáš).
- **Claude Code (ty, v terminálu):** „ruce" projektu — klonuješ repo, píšeš kód, spouštíš,
  migruješ databázi, nasazuješ. Řídíš se briefy od PM a hlásíš zpět zjištění.
- **Tomáš:** majitel projektu, schvaluje rozhodnutí, předává přístupy.

Když narazíš na produktové rozhodnutí (co má systém dělat, jak se má chovat), **nevymýšlej
si** — sepiš otázku a nech ji Tomášovi / PM. U technických rozhodnutí (jak to udělat) jednej.

## Tech stack (stávající — zachováváme)

- **Frontend:** React + Vite + TypeScript (vygenerováno Lovable, Tailwind + shadcn-ui).
- **Backend + DB:** Supabase (Postgres, Auth, RLS). Napojeno přes Supabase MCP.
- **Hosting:** Netlify, nasazuje se automaticky z GitHubu.
- **Lovable: opouštíme.** Od teď se needituje v Lovable — jediný zdroj pravdy je tento repozitář.

## Zásady

1. **Jeden zdroj pravdy = repo.** Databázové schéma drž v migracích v repu
   (supabase/migrations), ne jen v cloudu. Konec rozjíždění frontendu a DB.
2. **Nic nemazat natvrdo.** Používej „soft delete" (sloupec deleted_at), ať se data nedají
   omylem ztratit.
3. **Auditovatelnost.** U záznamů drž created_by, created_at, updated_by, updated_at.
   U klíčových tabulek historii změn (audit log / triggery). Požadavek zákazníka: „musí být
   vidět, kdo co zadával."
4. **Zabezpečení přes RLS.** Přístup jen pro přihlášené (Supabase Auth), práva podle rolí.
5. **Malé, srozumitelné commity.** Piš čitelný kód, komentuj netriviální věci česky/anglicky.
6. **Než něco velkého předěláš, zeptej se PM.**

## Architektonické rozhodnutí: zachovat a čistit (varianta B)

**Rozhodnuto:** stávající databázi a reálná data **NEbudujeme znovu od nuly**.

- **Varianta A (zamítnuto):** postavit čistou DB na zelené louce a data přemigrovat.
- **Varianta B (zvoleno):** **zachováváme** produkční databázi i reálná data
  (brigádníci, směny, výplaty, chaty) a **čistíme je za pochodu** — nekonzistence
  řešíme postupně migracemi, ne velkým třeskem.

**Rezervační systém ledu se staví jako nový, čistý kód _nad_ stávajícím základem** —
nové tabulky/moduly navrhneme pořádně od začátku, ale napojíme je na existující
`profiles` / `user_roles` / brigádnický systém, který nepřepisujeme. Důvod: data jsou
živá a v provozu, přepis od nuly by znamenal riziko ztráty a zbytečný výpadek.

Praktický dopad: baseline migrace = skutečný (i „nehezký") stav produkce; opravy schématu
jdou jako další migrace nad baseline, ne přepisem historie.

## Pracovní postup (povinný pro každou změnu)
1. Plánuj první. U každého netriviálního úkolu nejdřív připrav plán a nech si ho schválit, než začneš měnit kód nebo databázi.
2. Agenti jako kontrolní brány. Před dokončením každé změny ji nech zkontrolovat příslušnými specializovanými agenty. Povinné brány: (a) Bezpečnost/RLS u čehokoli kolem přístupů, auth, RLS a klíčů; (b) Databáze/migrace u každé migrace (bezpečná, vratná, bez ztráty dat); (c) Code review u implementace před commitem.
3. Záloha před zásahem do produkce. Nikdy neaplikuj změnu na produkční DB bez čerstvé zálohy a odsouhlasení PM.
   - **Supabase CLI proti živé databázi = zakázáno bez výslovného souhlasu PM a čerstvé zálohy.** NIKDY nespouštěj `supabase db push` ani `supabase link` sám od sebe. Lokální vývoj (`supabase start`, `supabase db reset`) je bezpečný a míří jen na lokální Docker.
   - **Kam `db push` doopravdy míří:** na **nalinkovaný** projekt, ne na to, co je v `config.toml`. `project_id` v `supabase/config.toml` je jen lokální jméno Docker kontejnerů a cíl pushe neurčuje (dřívější znění téhle poznámky tvrdilo opak). Link žije v `supabase/.temp/`, což je v `.gitignore` — po čerstvém klonu tam nic není, takže **stav linku si vždycky ověř a nikdy ho nehádej**. Ověřuj **jen pro čtení**: `supabase projects list` (má sloupec `LINKED`) nebo `cat supabase/.temp/linked-project.json`. (Pozor: soubor `project-ref` tenhle CLI nezakládá — kdo se po něm shání, dostane „no such file" a mylně si to přečte jako „nic není nalinkované".) **Nikdy ne `supabase db push --dry-run`** — je to zakázaný příkaz jeden flag od ostrého běhu, na ověřování se nehodí.
   - **Dva projekty, ať se nepletou:** `fareavttiwkamrukpfqk` = stará Lovable DB (jen směny a brigádníci, **rezervační tabulky tam vůbec nejsou**). `ltrazktulfxvzlvkxdsb` = curling-demo, kde běží rezervační systém i Etapa 2.
4. Nic nemazat natvrdo, vše auditovat.
5. Změna je hotová, teprve až projde svými bránami.
6. **Commit po každém PR, který prošel bránami.** Neschovávej odbraněnou práci
   v pracovním stromu „než bude celek hotový" — necommitnutá práce má stejnou
   expozici na pád session jako nezaverzovaný dokument. Jeden PR = jeden commit,
   hned jak projde. (Push a merge zůstávají na vyžádání, tohle je o commitu.)
7. **Dlouhé SQL funkce nikdy nepřepisuj ručně.** `CREATE OR REPLACE FUNCTION`
   vyžaduje celé tělo, takže je vygeneruj z `pg_get_functiondef` živého schématu
   a vlož do nich jen ten zásah, který děláš — pak ověř diffem, že nic nezmizelo.
   Přepis z paměti už jednou utnul půlku bezpečnostního guardu (commit `87b1f78`).
8. **Testy práv piš pod `SET LOCAL ROLE authenticated`.** Jako `postgres` projde
   všechno (obchází granty i RLS), takže test tvrdí zavřeno o dveřích, vedle
   kterých je otevřené okno. Dvakrát to takhle propustilo blokér.

## Čemu v tomhle repu nevěřit

- **`npx tsc --noEmit` netypuje nic** — kořenový `tsconfig.json` má `"files": []`
  a jen reference na podprojekty. Používej **`npm run typecheck`** (`tsc -b`).
- **`npm run lint` je červený už na HEADu** (66 errors z Etapy 1), takže jako brána
  nefunguje — nový error od šumu nikdo nerozezná.
- Úplný seznam takových pastí je v `docs/ETAPA2-STAV.md`, kapitola 5.

## Pravidlo pro Etapu 2 (fakturace) — povinné

**Po každé smysluplné změně, PŘED commitem/mergem, pusť review agenty jako bránu:**
code review + bezpečnost/RLS + kontrola migrací. **Nic se nemerguje bez projití těchto
tří gatů.** Platí i pro drobné úpravy — u peněz není „malá změna".

**Navíc u fakturace vždy ověř kontrolní součet:**
> suma vystavených faktur za období **==** „Kdo kolik dluží" za totéž období

Když se součty rozejdou, změna neprochází — bez ohledu na to, jak dobře vypadá kód.

## Kde právě jsme (aktualizováno 24. 8. 2026)

**Etapa 3 — napojení na Fakturoid (varianta S2).** Ostrý doklad vystavuje
Fakturoid, náš systém do něj posílá jen podklady. Interní fakturační engine se
na ostré doklady přestává používat; jeho vyřazení je samostatný pozdější ticket.

> **Než začneš cokoli kolem fakturace, přečti `docs/ETAPA3-STAV.md`.**
> Pak `billing/README.md` (pravidla vrstvy). `docs/ETAPA2-STAV.md` níž popisuje
> interní engine, který Etapa 3 nahrazuje — je pořád platný jako popis toho,
> co v databázi je, ne jako popis toho, kam se jde.

---

## Kde jsme byli (Etapa 2, aktualizováno 13. 8. 2026)

**Etapa 2 — fakturační modul.** Fáze A je hotová (A1–A5), z fáze B je hotové
B1+B2 (základ dokladu) a B5+B6 (RPC „faktura na klik" a **kontrolní součet**),
plus strop sazby (drift 8g) a E1-lite (stránka Faktury). Zbývá QR a serverové PDF.

> **Než začneš cokoli dělat, přečti `docs/ETAPA2-STAV.md`.**
> Je to předávací dokument: co je hotové s commit hashi, co se dělá dál a v jakém
> pořadí, jaká rozhodnutí PM platí, stav dema a seznam věcí, které se v téhle
> codebase tváří jinak, než jsou.
>
> Pak `docs/etapa2-fakturace-plan.md` (rozhodnutí R1–R11, otázky Q1–Q7)
> a `docs/etapa2-fakturace-spec.md` (zadání od klienta).

Aktuální cíl: **ruční „faktura na klik"** — jedna svislá funkční věc na demo,
v režimu neplátce DPH. Bez automatiky, dobropisů a evidence plateb.

## Roadmapa (fáze)

- **Fáze 0 — Převzetí kódu:** ✅ hotovo.
- **Fáze 1 — Zmapování:** ✅ hotovo (schéma v migracích, drift v `docs/SCHEMA_DRIFT.md`).
- **Fáze 2 — Návrh rezervace ledu:** ✅ hotovo.
- **Fáze 3 — Implementace rezervace ledu:** ✅ hotovo (Etapa 1).
- **Fáze 4 — Testy, zálohy, nasazení:** průběžně.
- **Etapa 2 — fakturace:** ⏳ probíhá, viz `docs/ETAPA2-STAV.md`.

## Požadavky na rezervační systém (od zákazníka)

- Přístup jen pro lidi s heslem (role: admin / brigádník / člen / …).
- Musí být vidět, kdo co zadával (audit).
- Záloha a garance, že se data nesmažou.
- Načítání IČO a údajů z adresy → ARES (oficiální registr, REST API zdarma).
- Tvorba faktur podle rezervovaných hodin (zvažuje se napojení na Fakturoid / iDoklad).
- Brigádníci už v systému nějak jsou — napojit, nepřepisovat.
- Systém = jeden „portál", odkaz na něj vede z nového webu, starého webu i odjinud.

## Rozhodnuto (feedback klienta, 31. 7. 2026 — detaily v docs/E2-ZMENY.md)

- **Název systému: Curling Promo Ostrava** (dřív „Mladé kameny"). Logo zatím placeholder.
- **Terminologie: „dráha"**, ne „plátno" (Dráha 1 / Dráha 2).
- **Struktura ledu:** 2 dráhy, rezervace po **celých hodinách**, otevírací doba **7:00–22:00**
  (nastavitelná adminem po dnech).
- **Typy akcí:** trénink / turnaj / komerční akce / údržba ledu; každá má název.
  Priorita při kolizi: údržba > komerční > turnaj > trénink; přebít smí jen admin a jen vědomě.
- **Kdo co smí:** hobby hráč (jen kouká) → člen klubu (rezervuje, edituje svoje) →
  zástupce klubu (celý klub, potvrzuje rezervace členů, může jich být víc) → admin.
- **Cena:** obsazenost i název klubu/akce vidí všichni přihlášení, **částku jen admin a autor**.
- **Ceník:** sazby podle typu akce vyplňuje admin v Nastavení (migrace je nechává prázdné).

## Otevřené otázky (řeší PM se zákazníkem)

- Fakturace: vlastní generování vs Fakturoid/iDoklad?
- E-maily k notifikacím: který poskytovatel (Resend / SMTP) a z jaké domény?
  (v aplikaci notifikace fungují, e-mailová fronta je připravená a vypnutá)
- Platby: jen faktura, nebo i online platby/zálohy?
- Finální logo a barevnost.
