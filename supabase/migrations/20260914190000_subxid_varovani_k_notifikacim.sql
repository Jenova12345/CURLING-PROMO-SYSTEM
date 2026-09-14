-- =============================================================================
-- Oprava změřeného čísla: kolik subtransakcí stojí notifikace
-- =============================================================================
-- CO SE MĚNÍ: NIC VE SCHÉMATU. Jen dva `COMMENT ON FUNCTION`. Žádná tabulka,
-- žádný grant, žádná politika, žádné tělo funkce.
--
-- PROČ TAHLE MIGRACE VŮBEC JE: migrace 20260914180000 nese ve svém komentáři
-- číslo, které je PODSTŘELENÉ. Tvrdí „34 volání = 68 subxid"; po nasazení se
-- doměřilo 36 na produkci a strop je 56. Závěr té věty (práh 64 se překračuje)
-- platí dál, ale odstup je jiný, než tam stojí.
--
-- Soubor 20260914180000 se kvůli tomu NEPŘEPISUJE — je aplikovaný a jeho text
-- je uložený v `supabase_migrations.schema_migrations.statements` (pravidlo 6:
-- migrace jsou dopředné, historie se nepřepisuje). Oprava jde tedy dopředu
-- a přistává tam, kde ji čtenář opravdu najde: na komentáři funkce, kterou
-- uvidí každý, kdo si dá `\df+ notify_user` nebo sáhne na tu smyčku.
--
-- -----------------------------------------------------------------------------
-- ZMĚŘENÁ ČÍSLA (14. 9. 2026; slope nezávisle dvakrát — bezpečnostní brána
-- a znovu nad nečinnou replikou: N=1 → 3, N=5 → 11, N=20 → 41 XID)
-- -----------------------------------------------------------------------------
--   2,00 subxid na jedno volání `notify_user`   (před migrací 180000: 0)
--   práh `PGPROC_MAX_CACHED_SUBXIDS` = 64  →  32 volání v jedné transakci
--
--   běžná rezervace člena        5 volání → 12 XID  ≈ 19 % cache   (změřeno)
--   přebití obou velkých klubů  36 volání → 73 XID  ≈ 114 % cache  (POD/NAD)
--   strop produkce              56 volání → ~113 XID ≈ 176 % cache
--
-- Strop 56 = počet dvojic (uživatel, klub) ze `subject_reps` SJEDNOCENÝCH
-- s dvojicemi (autor rezervace, klub). Dotaz, kterým se přepočítá:
--   WITH dvojice AS (
--     SELECT sr.user_id, sr.subject_id FROM public.subject_reps sr
--     UNION
--     SELECT r.created_by, r.subject_id FROM public.reservations r
--      WHERE r.created_by IS NOT NULL)
--   SELECT count(*) FROM dvojice;
--
-- ⚠️ DVĚ VĚCI, KTERÉ JSME S BRÁNOU OBA PŘEHLÉDLI, ať je příště nikdo nehledá
-- znovu: smyčka `reservation_overridden` v `create_booking` NEFILTRUJE podle
-- `level`, takže jde i přes členy, ne jen přes zástupce — a k tomu přidává
-- `UNION SELECT rr.created_by`, což na produkci přihazuje 20 dvojic, které
-- v `subject_reps` vůbec nejsou.
--
-- ZÁVAŽNOST, bez nafukování: není to chyba správnosti ani ztráta dat.
-- Přelitá cache znamená, že cizí backendy musí viditelnost řádků dohledávat
-- v `pg_subtrans` (SLRU). Při zátěži jedné curlingové haly je to nejspíš
-- neměřitelné. Netvrdíme tu ale odstup, který neexistuje.
--
-- VRATNOST: `COMMENT ON FUNCTION ... IS NULL` nebo původní text. Nic víc.
-- =============================================================================

COMMENT ON FUNCTION public.notify_user(uuid,text,text,text,text,uuid,uuid) IS
  'Interní: zakládá upozornění v aplikaci a (jen při zapnutém odesílání a jen '
  'u typů se šablonou) e-mail do fronty. Volá se z RPC rezervací, ne z klienta. '
  'Od 20260914180000 má dva vnořené EXCEPTION bloky, takže chyba notifikace '
  'ani e-mailu neshodí rezervaci; spolknuté chyby jdou do notifikace_chyby. '
  'CENA: 2 subtransakce na volání (změřeno), cache má 64 — práh je tedy 32 '
  'volání v jedné transakci a smyčka reservation_overridden v create_booking '
  'ho už dnes překračuje (36 volání = 73 XID). Není to chyba správnosti, jen '
  'suboverflow a čtení pg_subtrans. Kdo tu smyčku rozšíří, ať to přepočítá.';

COMMENT ON FUNCTION public.create_booking(uuid[],text,text,timestamptz,timestamptz,uuid,text,jsonb,numeric,boolean,uuid,numeric) IS
  'Zakládá rezervaci ledu včetně přebití (p_override) a notifikací. '
  '⚠️ Smyčka reservation_overridden volá notify_user pro KAŽDOU dvojici '
  '(uživatel, klub) zasaženého klubu — bere členy i zástupce (nefiltruje se '
  'level) a navíc autora přebité rezervace. Produkce 14. 9. 2026: až 36 volání, '
  'strop 56. Každé volání stojí 2 subtransakce, cache jich má 64. Než sem '
  'přidáš další notifikaci na člověka, přečti si 20260914190000.';
