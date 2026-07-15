# Archiv — historické Lovable migrace

Tady je **19 původních migrací**, které vygeneroval Lovable v období leden–květen 2026
(soubory `20260104…` až `20260525…`).

## Proč jsou v archivu

Ve Fázi 1 jsme udělali **squash do baseline**: skutečný stav produkční databáze
(`fareavttiwkamrukpfqk`) k 2026-07-15 je nově popsán jediným souborem
`supabase/migrations/20260715000000_baseline_production.sql`.

Tyto historické migrace se proto **už nespouští** — kdyby zůstaly v aktivní složce
`supabase/migrations/`, `supabase db reset` by je přehrál spolu s baseline a došlo by
ke kolizím (duplicitní `CREATE TYPE`, `CREATE TABLE` apod.).

## Pravidla

- **Nemazat.** Držíme je jako historii vývoje (kdo/kdy co měnil) — v souladu se
  zásadou „nic nemazat natvrdo".
- **Nespouštět.** Nejsou to aktivní migrace; jsou mimo cestu, kterou Supabase CLI čte.
- Zdroj pravdy pro schéma = `../20260715000000_baseline_production.sql`.
- Reálná data k témuž datu jsou v `backups/2026-07-15/` (mimo git).

## Poznámka

Baseline nemusí být „součtem" těchto migrací 1:1 — do produkce se během provozu dostaly
i ruční změny (nové hodnoty enumů, sloupce `role_reqs` / `required_role`), které v těchto
souborech nejsou. Baseline zachycuje **skutečný živý stav**, ne teoretický výsledek replay.
Rozdíly viz `docs/SCHEMA_DRIFT.md`.
