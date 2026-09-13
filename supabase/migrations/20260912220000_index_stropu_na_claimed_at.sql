-- =============================================================================
-- Index pro okno stropu odchozí pošty: (claimed_at) místo (user_id, claimed_at)
-- =============================================================================
-- CO SE TU OPRAVUJE
--
-- Migrace `20260912160000` založila `idx_email_outbox_user_claimed`
-- na `(user_id, claimed_at DESC)`. Sloupce jsou ve špatném pořadí: poddotaz
-- stropu v `email_outbox_prevzit` FILTRUJE podle `claimed_at`
--
--     WHERE o.claimed_at >= now() - interval '1 hour'
--     GROUP BY COALESCE(o.user_id, …)
--
-- a seskupuje až podle `user_id`. S `user_id` vepředu nemá plánovač co použít
-- pro rozsah a sáhne po `Seq Scan` přes celou frontu. Ověřeno `EXPLAIN`em.
--
-- PROČ SAMOSTATNÁ MIGRACE A NE OPRAVA V TÉ PŮVODNÍ
--
-- Protože `20260912160000` už někde běžela. Databáze, která ji má
-- v `schema_migrations`, by opravený soubor NIKDY nespustila znovu — zůstal by
-- jí starý index, nový by nevznikl a nenahlásilo by to vůbec nic, protože
-- se nespustí ani kontrola na konci té migrace. Ověřeno, že produkce
-- `20260912160000` nikdy neměla (je na `20260912140000` a index na `claimed_at`
-- tam žádný není), ale u dema se to doložit nedalo — a dokazovat zápor
-- je horší cesta než napsat dopřednou migraci. CLAUDE.md, pravidlo 6.
-- Našla brána code review 13. 9. 2026.
--
-- ZMĚŘENO (ne odhadnuto)
--
-- 100 000 odeslaných řádků + 2 000 čekajících, každá varianta ve VLASTNÍ
-- transakci (varianty za sebou v jedné transakci si výsledky kontaminují),
-- medián z 12 běhů `email_outbox_prevzit(20)`, celé dvakrát v opačném pořadí:
--
--     index                          běh 1      běh 2
--     žádný                          10,97 ms    6,81 ms
--     (user_id, claimed_at DESC)      1,82 ms    6,52 ms
--     (claimed_at)                    1,03 ms    1,08 ms   ← zvolený
--
-- Přeměřeno i na RŮZNÉM ROZLOŽENÍ UŽIVATELŮ, protože strop se počítá na
-- uživatele a první měření mělo všech 100 000 řádků od jednoho člověka —
-- tedy tvar, který `(claimed_at)` zvýhodňuje:
--
--     index                        5 uživ.   200 uživ.   2 000 uživ.
--     žádný                        10,17 ms    8,95 ms      9,12 ms
--     (user_id, claimed_at DESC)    2,26 ms    3,76 ms      3,65 ms
--     (claimed_at)                  1,36 ms    2,74 ms      2,79 ms
--
-- Náskok se s počtem uživatelů zmenšuje, ale pořadí se nemění v žádném z tvarů.
--
-- ⚠️ K rozptylu: brána code review si měření zopakovala nezávisle a vyšlo jí
--     žádný 5,46 / 9,87 ms, (user_id, claimed_at) 2,50 / 2,83 ms,
--     (claimed_at) 1,60 / 1,66 ms.
-- Pořadí stejné, ale složený index jí vyšel STABILNÍ. Moje hodnota 6,52 ms
-- byla nejspíš šum jednoho běhu (ve stejném běhu skočil i „žádný index"
-- z 10,97 na 6,81). Dřívější znění tady tvrdilo „kolísá, nespolehlivý" —
-- to se nereprodukovalo a je vypuštěné. Co drží napříč všemi měřeními obou
-- stran: `(claimed_at)` je nejrychlejší a pořadí sloupců je u tohohle tvaru
-- dotazu špatné bez ohledu na rozložení dat.
-- =============================================================================

-- Starý index se zahazuje: na zápisy stojí a v žádném měření si své místo
-- nezasloužil. `IF EXISTS`, protože na čisté databázi ho `20260912160000`
-- sice založí, ale na databázi, která tuhle migraci dostane dřív než tu,
-- tam být nemusí.
DROP INDEX IF EXISTS public.idx_email_outbox_user_claimed;

-- ⚠️ ZÁMĚRNĚ BEZ `CONCURRENTLY`, a není to opomenutí. `CREATE INDEX
-- CONCURRENTLY` se NESMÍ spustit uvnitř transakčního bloku a migrace Supabase
-- v transakci běží — takže tady to ani nejde. Nevadí to: `email_outbox` má na
-- produkci dnes 0 řádků, takže se nemá co zamykat. U velké živé tabulky by
-- tahle úvaha dopadla jinak a index by musel jít mimo migraci. Ptaly se na to
-- obě brány 13. 9. 2026, tak ať na to příště nikdo nemusí přijít znovu.
CREATE INDEX IF NOT EXISTS idx_email_outbox_claimed
  ON public.email_outbox (claimed_at);

-- Kontrola, ať migrace nelže o tom, co udělala.
--
-- ⚠️ KONTROLUJE SE DEFINICE, NE JEN JMÉNO. `CREATE INDEX IF NOT EXISTS` se
-- rozhoduje podle JMÉNA: kdyby v databázi už ležel index `idx_email_outbox_claimed`
-- postavený třeba na `(status)`, příkaz ho tiše přeskočí a kontrola na pouhé
-- jméno by odkývala index, který dotazu stropu nepomůže vůbec. Změřeno:
-- podvržený index na `(status)` starou kontrolou prošel. Našla brána
-- code review 13. 9. 2026.
--
-- `schemaname='public'` tu je taky schválně: bez něj by shoda jména v jiném
-- schématu zastavila nasazení na falešný poplach.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes
                  WHERE schemaname='public' AND tablename='email_outbox'
                    AND indexname='idx_email_outbox_claimed'
                    AND indexdef LIKE '%btree (claimed_at)%') THEN
    RAISE EXCEPTION 'Index pro okno stropu chybí nebo nestojí na claimed_at, dotaz by četl celou frontu.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes
              WHERE schemaname='public' AND tablename='email_outbox'
                AND indexname='idx_email_outbox_user_claimed') THEN
    RAISE EXCEPTION 'Starý index na (user_id, claimed_at) zůstal, platí se za něj při každém zápisu.';
  END IF;
END $$;
