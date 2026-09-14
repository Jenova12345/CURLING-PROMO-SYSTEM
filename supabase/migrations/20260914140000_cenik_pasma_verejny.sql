-- =============================================================================
-- Standardní pásmový ceník ledu je čitelný všem přihlášeným
-- =============================================================================
-- CO SE MĚNÍ: přibývá jeden ČTECÍ pohled `cenik_pasma_public`. Tabulka
-- `cenik_pasma`, její RLS ani granty se NEDOTÝKAJÍ — zápis i nadále smí jen
-- admin (politika `cenik_pasma_admin`).
--
-- PROČ: hala má vyvěšený ceník ledu jako každá jiná — 700 / 900 / 1 000 Kč/h
-- podle denní doby. V aplikaci ho ale neviděl nikdo kromě správce, a dokonce
-- ani ten (editor pásem v UI vůbec není). Člen klubu, který si jde rezervovat
-- led, tak neměl kde zjistit, kolik to stojí, a hláška z `cena_ledu` mu radila
-- „řekněte to správci haly".
--
-- -----------------------------------------------------------------------------
-- VZTAH K A2b („Ceník vidí jen admin", 20260812140000) — ČTI, NEŽ TOHLE ROZŠÍŘÍŠ
-- -----------------------------------------------------------------------------
-- A2b zavřela `settings` kvůli rozhodnutí klienta z 31. 7. 2026: „obsazenost
-- i název klubu vidí všichni přihlášení, ČÁSTKU jen admin a autor". Odůvodnění
-- bylo, že člen vidí časy cizích rezervací, takže si z ceníku částku dopočítá.
--
-- Tahle migrace tu úvahu NERUŠÍ, jen ji zužuje na to, co je stejně veřejné.
-- Rozhodnutí Tomáše (14. 9. 2026), vědomé a vymezené:
--
--   ZVEŘEJŇUJE SE   `cenik_pasma` — standardní pásmový ceník ledu. Je to
--                   vyvěšená cena pro každého, ne cena konkrétního zákazníka.
--
--   ZŮSTÁVÁ ADMINOVI
--     • `settings.commercial_default_rate` (komerční sazba)
--     • `settings.club_default_rate`, `training_rate`, `tournament_rate`
--     • `subjects.default_rate` (individuálně sjednané sazby klubů)
--     • `reservations.amount` / `rate_per_hour` (maskuje `reservations_calendar`)
--   Tady je dopočet cizí částky doopravdy možný, a proto se na těchhle
--   sloupcích NESMÍ nic povolovat. Kdo sem bude příště přidávat sloupec, ať se
--   vrátí k A2b a k tomuhle odstavci — hranice vede tudy, ne jinde.
--
-- Otevírací doba už veřejná je (`settings_public.opening_hours`) a nemění se.
--
-- -----------------------------------------------------------------------------
-- JAK: týmž vzorem, jaký v projektu už je (`settings_public`, `subjects_rates`):
-- pohled se `security_invoker = off`, takže běží pod vlastníkem a RLS základní
-- tabulky se neuplatní; omezení se píše PŘÍMO DO POHLEDU. Druhý vzor maskování
-- se schválně nezavádí.
--
-- -----------------------------------------------------------------------------
-- ⚠️ V JEDNÉ VĚCI JE TENHLE POHLED PRVNÍ SVÉHO DRUHU (nález brány migrací)
-- -----------------------------------------------------------------------------
-- Oba vzory, na které se odvoláváme, jsou vůči RLS své tabulky STEJNĚ ŠIROKÉ
-- nebo UŽŠÍ. Tenhle je ŠIRŠÍ — a je to zatím jediný takový v repu:
--
--   settings_public     RLS `ucet_aktivni()`    pohled `ucet_aktivni()`   shodné
--   subjects_rates      RLS admin OR …          pohled `has_role(admin)`  užší
--   cenik_pasma_public  RLS `has_role(admin)`   pohled `ucet_aktivni()`   ŠIRŠÍ
--
-- `cenik_pasma` má jedinou politiku `cenik_pasma_admin [ALL] has_role(admin)`,
-- kdežto pohled má řádky ukázat NEADMINŮM. Drží to výhradně tím, že pohled běží
-- pod vlastníkem (`postgres`) a ten je z RLS vyjmutý.
--
-- ZMĚŘENO, ať se nespoléhá na dojem. Vlastník je na produkci `postgres`
-- s `rolsuper = f`, ale `rolbypassrls = t` (na lokální replice je naopak
-- superuser, takže replika sama tenhle rozdíl NEDOKÁŽE ukázat — proto zvlášť
-- postavená fixtura, která produkci napodobí):
--
--   vlastník NOSUPERUSER + BYPASSRLS   bez FORCE RLS → 2 řádky
--                                      s  FORCE RLS → 2 řádky   ← produkce
--   vlastník NOSUPERUSER bez BYPASSRLS bez FORCE RLS → 2 řádky
--                                      s  FORCE RLS → 0 řádků   ← protipól
--
-- Čili: `ALTER TABLE cenik_pasma FORCE ROW LEVEL SECURITY` stránku Ceník
-- na dnešní produkci NEVYPRÁZDNÍ, protože BYPASSRLS přebíjí i FORCE. Kdyby
-- ale někdo vlastníkovi BYPASSRLS odebral, ztichne to BEZ CHYBY — Ceník bude
-- prázdný a bude to vypadat jako nevyplněný ceník, ne jako porucha.
-- Hlídá to scénář 1a v `supabase/tests/cenik_pasma_verejny_test.sql`, který
-- porovnává počet řádků z pohledu s počtem platných pásem v tabulce.
--
-- OVĚŘENO NA PRODUKCI 14. 9. 2026 (jen SELECT, před nasazením téhle migrace):
--     cenik_pasma   vlastník `postgres`, relrowsecurity = t, relforcerowsecurity = f
--     role postgres rolsuper = f, rolbypassrls = t
-- Předpoklad tedy platí. Kdo tuhle migraci nasazuje později nebo do jiného
-- projektu, ať si to ověří znovu — je to podmínka, ne konstatování:
--     SELECT relname, pg_get_userbyid(relowner), relforcerowsecurity
--       FROM pg_class WHERE oid = 'public.cenik_pasma'::regclass;
--
-- CO POHLED NEVYDÁVÁ: `created_by`, `updated_by`, `created_at`, `updated_at`
-- ani `deleted_at`. Je to ceník, ne auditní stopa — kdo sazbu měnil, zůstává
-- adminovi. Smazaná pásma (`deleted_at IS NOT NULL`, na produkci k 14. 9. 2026
-- čtyři historická) se nevydávají vůbec: platný ceník je jen ten dnešní.
--
-- `ucet_aktivni()` je tu ze stejného důvodu jako v `settings_public` — účet,
-- který ještě nikdo nepustil dovnitř, nedostane nic (blok C, default-deny).
-- Servisní větev (`auth.uid() IS NULL AND SESSION_USER IN (postgres, …)`) je
-- doslovná kopie ze `settings_public`, aby migrace a skripty pohled přečetly.
--
-- VRATNOST (úplná, jedním příkazem — nic jiného se nezměnilo):
--   DROP VIEW IF EXISTS public.cenik_pasma_public;
-- Revert DB musí jít SPOLU s revertem frontendu: stránka Ceník pohled čte,
-- takže samotný DROP je v aplikaci chyba při načtení.
-- =============================================================================

DROP VIEW IF EXISTS public.cenik_pasma_public;

CREATE VIEW public.cenik_pasma_public
  WITH (security_invoker = off) AS
  SELECT
    p.id,
    p.den_typ,
    p.od_hodina,
    p.do_hodina,
    p.sazba,
    p.popis
  FROM public.cenik_pasma p
  WHERE p.deleted_at IS NULL
    AND (
      public.ucet_aktivni()
      OR (auth.uid() IS NULL AND SESSION_USER = ANY (ARRAY['postgres'::name, 'supabase_admin'::name]))
    );

COMMENT ON VIEW public.cenik_pasma_public IS
  'Standardní pásmový ceník ledu pro všechny přihlášené (stránka Ceník). '
  'Jen platná pásma, bez auditních sloupců. Komerční sazba a individuální '
  'sazby klubů sem NEPATŘÍ — ty zůstávají adminovi (viz A2b, 20260812140000).';

REVOKE ALL ON public.cenik_pasma_public FROM PUBLIC, anon;
GRANT SELECT ON public.cenik_pasma_public TO authenticated, service_role;
