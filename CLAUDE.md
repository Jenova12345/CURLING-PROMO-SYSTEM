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
4. Nic nemazat natvrdo, vše auditovat.
5. Změna je hotová, teprve až projde svými bránami.

## Roadmapa (fáze)

- **Fáze 0 — Převzetí kódu (teď):** naklonovat repo, rozjet lokálně, napojit Supabase MCP
  (read-only), opustit Lovable.
- **Fáze 1 — Zmapování:** projít appku + datový model, sepsat co existuje, schéma do migrací,
  nastavit zálohy + soft-delete.
- **Fáze 2 — Návrh rezervace ledu:** model (plátna, sloty, rezervace, typy, zákazníci s IČO,
  ceník), role a přístup, ARES, fakturace, audit.
- **Fáze 3 — Implementace rezervace ledu.**
- **Fáze 4 — Testy, zálohy, nasazení.**

## Požadavky na rezervační systém (od zákazníka)

- Přístup jen pro lidi s heslem (role: admin / brigádník / člen / …).
- Musí být vidět, kdo co zadával (audit).
- Záloha a garance, že se data nesmažou.
- Načítání IČO a údajů z adresy → ARES (oficiální registr, REST API zdarma).
- Tvorba faktur podle rezervovaných hodin (zvažuje se napojení na Fakturoid / iDoklad).
- Brigádníci už v systému nějak jsou — napojit, nepřepisovat.
- Systém = jeden „portál", odkaz na něj vede z nového webu, starého webu i odjinud.

## Otevřené otázky (řeší PM se zákazníkem)

- Fakturace: vlastní generování vs Fakturoid/iDoklad?
- Členská struktura: HOBBY / člen / „Mladé kameny" / brigádník — kdo co smí rezervovat?
- Struktura ledu: kolik pláten, délka slotů, otevírací doba?
- Ceník: sazby za hodinu podle typu / role?
- Platby: jen faktura, nebo i online platby/zálohy?
