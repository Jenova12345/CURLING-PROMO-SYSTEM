# Produkce `curling-promo-prod` — ZÁVAZNÁ PRAVIDLA

**Platí od:** 31. 8. 2026 · **Rozhodl:** Tomáš (majitel projektu)
**Projekt:** `curling-promo-prod`, ref **`fcwubbytqxubgptftnru`**, organizace JENOVA
**Web:** https://curling-ostrava-system.netlify.app

> Tenhle soubor má přednost před pohodlím. Když je něco v rozporu s tím, co se
> zrovna hodí, platí tenhle soubor. Do produkce zadává data klient — od 31. 8.
> 2026 je to živý provoz, ne demo.

---

## 1. Čtyři pravidla, která se neobcházejí

### P1 — NIKDY `supabase db reset --linked` na produkci

**Zakázáno bez výjimky.** Reset smaže celou databázi včetně `auth.users`, tedy
i účty, kterými se lidé přihlašují. Na produkci se jede **výhradně dopředu**:
nová migrace → `supabase db push`.

Když se něco nepovede, cesta ven je **další migrace**, která to opraví — ne
reset a znovu.

⚠️ `db reset` bez `--linked` míří na lokál a je neškodný. Rozdíl je jeden
přepínač, takže si u každého resetu ověř, co píšeš.

### P2 — Před KAŽDÝM `db push` na produkci čerstvý dump

Ne „záloha z minulého týdne", ne „vždyť je to malá migrace". **Čerstvý dump,
těsně před pushem.** Postup je v kapitole 3.

Důvod: `db push` není přes migrace atomický. Když spadne osmá z deseti, produkce
zůstane půl migrovaná a rollback neexistuje — jedinou cestou zpátky je ta záloha.

### P3 — Každá migrace nejdřív lokálně, na produkci až po zeleném

Pořadí je vždycky:

```
1. supabase db reset            (lokálně, čistý stav + seed)
2. sada testů                   (supabase/tests/*.sql — všechny musí projít)
3. npm run typecheck && npm run test:run
4. teprve pak dump produkce + supabase db push
```

Migrace, která neproběhla lokálně, na produkci nemá co dělat. Platí to i pro
„jednořádkové" migrace — právě ty se nekontrolují a právě ty pak spadnou.

### P4 — Schema změny do produkce, když se do ní nezadává

Migrace mění funkce, politiky i constrainty za provozu. Když v tu chvíli někdo
ukládá rezervaci, může dostat chybu z půlky přepnutého schématu. **Domluv se
předem** (dnes typicky s Jakubem) a dělej to mimo jeho okno.

---

## 2. Co si ověřit PŘED každým zásahem

**Na co míří link.** Je to jednořádková kontrola a odděluje produkci od dema:

```bash
cat supabase/.temp/linked-project.json
```

Musí tam být `fcwubbytqxubgptftnru`. Soubor je v `.gitignore`, takže po čerstvém
klonu tam **není nic** a link se musí udělat znovu — nikdy ho nehádej.

⚠️ `project_id` v `supabase/config.toml` je jen jméno lokálních Docker
kontejnerů. **Cíl pushe neurčuje.**

**Tři projekty, ať se nepletou:**

| ref | jméno | co to je |
|---|---|---|
| `fcwubbytqxubgptftnru` | curling-promo-prod | **PRODUKCE** — sem chodí klient |
| `ltrazktulfxvzlvkxdsb` | curling-demo | demo, Etapa 1 + část 2 |
| `fareavttiwkamrukpfqk` | MladeKameny | stará Lovable DB, **reálné účty, nemigrovat** |

---

## 3. Jak udělat dump produkce (ověřený postup)

### Rychlá cesta — `pg_dump` přes pooler

Funguje spolehlivě a hned:

```bash
PG="postgresql://postgres.fcwubbytqxubgptftnru:<HESLO>@aws-1-eu-west-1.pooler.supabase.com:5432/postgres"
mkdir -p backups/prod-$(date +%F)
docker exec -i supabase_db_ltrazktulfxvzlvkxdsb pg_dump "$PG" \
  --schema=public --schema=auth --no-owner --no-privileges \
  > backups/prod-$(date +%F)/prod_full_$(date +%F).sql
```

**Dvě věci, které stály čas a je škoda je hledat znovu:**

- **Pooler je `aws-1-eu-west-1`, ne `aws-0`.** S `aws-0` to spadne na
  `FATAL: (ENOTFOUND) tenant/user postgres.<ref> not found`, což vypadá jako
  špatné heslo, ale je to špatný host.
- **Přímé spojení `db.<ref>.supabase.co:5432` nefunguje** — je jen přes IPv6
  a kontejner ho nemá (`Network is unreachable`). Proto pooler.
- Port **5432** = session mode (pro `pg_dump`), **6543** = transaction mode
  (pro dotazy).

### `supabase db dump --linked`

Funguje taky, ale má **dvě pasti, a ta druhá je vážná**.

**Past 1 — mlčí.** Při prvním běhu stahuje Docker image a několik minut nevypíše
vůbec nic; soubor navíc plní až na konci, takže mezitím má nula bajtů. Není
zaseknutý. Nezabíjej ho — a hlavně si po doběhnutí zkontroluj velikost, protože
prázdný soubor vypadá jako hotová práce.

**Past 2 — ⚠️ BEZ PŘEPÍNAČŮ DUMPUJE JEN SCHÉMA, ŽÁDNÁ DATA.** Změřeno na téhle
produkci, oba soubory ze stejné databáze a stejné minuty:

| | `supabase db dump --linked` | `pg_dump` (postup výš) |
|---|---|---|
| velikost | 413 kB | 395 kB |
| `CREATE TABLE` | 25 (jen `public`) | 48 (`public` + `auth`) |
| `CREATE POLICY` | 59 | 59 |
| **`COPY` bloků (DATA)** | **0** | **48** |

Ten CLI soubor je *větší*, a přitom v něm **není jediný řádek dat** — ani
uživatelé, ani rezervace, ani ceník. Jako záloha před migrací je bezcenný:
obnovil by prázdnou databázi se správnými tabulkami.

Kdo chce data z CLI, musí přidat `--data-only` (a udělat druhý soubor na
schéma). **Proto je závazná cesta `pg_dump` výš** — jeden soubor, schéma i data,
`public` i `auth`.

### Ověření zálohy (dělej to vždycky)

```bash
D=backups/prod-<datum>/prod_full_<datum>.sql
grep -c "^CREATE TABLE" $D    # ~48
grep -c "^CREATE POLICY" $D   # ~59  ← RLS politiky
grep -c "^COPY " $D           # ~48  ← DATA, ne jen schéma
```

Když `COPY` bloky chybí, máš dump schématu bez dat.

### Dump z `pg_dump` 18+ potřebuje k obnově `psql` 18+

Od verze 18 obaluje `pg_dump` výstup dvojicí `\restrict` / `\unrestrict`
(první řádky souboru a úplný konec). Jsou to **meta-příkazy `psql`, ne SQL** —
starší `psql` (17.x) je nezná a obnova na nich skončí chybou.

Změřeno 4. 9. 2026 na tomhle Macu: `pg_dump` i `psql` jsou **18.6**, server
produkce je **17.6**. Dumpovat novějším klientem starší server je v pořádku
(odmítá se jen opačná kombinace), takže zálohy odsud jsou platné — ale:

> **Obnovovat je musíš `psql` 18+.** Na stroji, kde je `psql` 17.x, ten dump
> neprojde. Buď tam doinstaluj klienta 18+, nebo z něj ty dva řádky smaž:
> ```bash
> grep -vE '^\\(un)?restrict ' zaloha.sql > zaloha-bez-restrict.sql
> ```

Záloha, kterou nejde obnovit, není záloha — proto to stojí tady, a ne
v poznámkách.

Složka `backups/` je v `.gitignore` — zálohy do gitu nepatří.

---

## 4. Automatické zálohy Supabase — co na ně spoléhat lze a co ne

Organizace JENOVA je na tarifu **Pro**, takže:

| | stav |
|---|---|
| Denní automatické zálohy | ✅ zapnuté (`walg_enabled: true`) |
| Retence | 7 dní (Pro) |
| **PITR** (point-in-time recovery) | ❌ **vypnuté** (`pitr_enabled: false`) — placený doplněk |

**Co to znamená prakticky:** bez PITR se dá vrátit jen k **poslední noční
záloze**. Když se migrace pokazí ve dvě odpoledne, přijdeš o celý den zadávání.
Proto platí P2 — vlastní dump těsně před zásahem je jediná věc, která tuhle
díru zavírá.

Jestli má hala zadávat data denně, **stojí za zvážení zapnout PITR.**
Rozhodnutí je na PM, ne technické.

---

## 5. Netlify — na co narazit

- **Env se zapéká při BUILDU.** Změna proměnné se na běžícím webu neprojeví,
  dokud se nepřestaví. Vždycky *Deploys → Trigger deploy →
  **Clear cache and deploy site***.
- Klíč se jmenuje **`VITE_SUPABASE_PUBLISHABLE_KEY`**, ne `..._ANON_KEY`
  (`src/integrations/supabase/client.ts:6`).
- **Jak poznat, že nový build dosedl — pozor, hash assetu na to nestačí.**
  Vite počítá hash z OBSAHU bundlu. Když commit sáhne jen na dokumentaci nebo na
  `index.html`, JS se nezmění a `/assets/index-XXXX.js` **zůstane stejný,
  přestože deploy proběhl.** Ověřeno 31. 8. 2026: commit `66f74a6` (docs +
  jednořádková změna `index.html`) dosedl za ~20 s, ale asset zůstal
  `index-MzqHbFqd.js`.
  - Změna hashe je spolehlivá jen tam, kde se **mění obsah bundlu** — typicky
    při změně env proměnných nebo zdrojáků v `src/`.
  - Univerzálnější kontrola je sáhnout na něco, co se opravdu změnilo (třeba
    `preconnect` v HTML), nebo se podívat do Netlify deploy logu.
- Chybějící env se projeví **bílou stránkou** a hláškou v konzoli
  `Invalid supabaseUrl: Must be a valid HTTP or HTTPS URL.` — build přitom
  projde zeleně. Zelený build tedy neznamená funkční web.

---

## 6. Baseline záloha

První záloha produkce, pořízená před tím, než do ní klient začal zadávat data:

```
backups/prod-2026-08-31/prod_full_2026-08-31.sql
```

395 kB, 48 tabulek, 88 funkcí, 59 RLS politik, 48 COPY bloků. Obsahuje
i vyplněný ceník (komerční 5 000 Kč/h, klubová pásma 800/1000/1200/1000).

Vedle leží `prod_schema_2026-08-31.sql` z `supabase db dump` — **jen schéma
`public`, bez dat**. Nechal jsem ho tam jako doplněk (je to Supabase-tvarované
schéma), ale **zálohou je ten první soubor**, ne tenhle. Viz past 2 v kapitole 3.
