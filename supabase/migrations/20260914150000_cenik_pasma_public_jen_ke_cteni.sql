-- =============================================================================
-- HOTFIX: cenik_pasma_public je JEN KE ČTENÍ (odvolání zápisu pro authenticated)
-- =============================================================================
-- CO SE MĚNÍ: `authenticated` ztrácí na pohledu `cenik_pasma_public` INSERT,
-- UPDATE, DELETE, REFERENCES, TRIGGER a MAINTAIN. Zůstává mu SELECT. Tabulka
-- `cenik_pasma`, její RLS ani nic jiného se NEDOTÝKÁ.
--
-- PROČ (a je to díra, ne kosmetika): migrace 20260914140000 pohled založila
-- a odvolala práva jen takto:
--     REVOKE ALL ON public.cenik_pasma_public FROM PUBLIC, anon;
--     GRANT SELECT ON public.cenik_pasma_public TO authenticated, service_role;
-- `authenticated` v tom REVOKE CHYBÍ. Supabase má v schématu `public`
-- nastavené DEFAULT PRIVILEGES, které roli `authenticated` dávají na každou
-- nově vzniklou tabulku i pohled ALL — takže `GRANT SELECT` nepřidal nic
-- a pohled vznikl rovnou jako `authenticated=arwdxtm`.
--
-- Proč to není neškodné: pohled je AUTO-UPDATABLE (jeden FROM, žádná agregace;
-- `information_schema.views.is_updatable = YES`) a běží se `security_invoker = off`.
-- Práva k podkladové tabulce se tedy kontrolují proti VLASTNÍKOVI pohledu
-- (`postgres`, `rolbypassrls = t`), ne proti volajícímu. Politika
-- `cenik_pasma_admin` zápis neadminovi nezastaví — pohled ji obejde.
--
-- ZMĚŘENO NA REPLICE (granty srovnané na produkční tvar), pod reálným tokenem
-- neadmina `SET LOCAL ROLE authenticated`:
--     UPDATE public.cenik_pasma_public SET sazba = 1 WHERE sazba = 1000.00;
--     → UPDATE 2, sazby 1000 Kč se změnily na 1 Kč
-- Tedy kdokoli přihlášený mohl přepsat vyvěšený ceník ledu. Jsou to peníze,
-- takže tohle jde ven hned a samostatně.
--
-- PROČ TO NEBYLO VIDĚT DŘÍV: oba vzory, na které se 20260914140000 odvolávala,
-- mají `authenticated=r` (jen SELECT) — `settings_public` i `subjects_rates`.
-- Vypadaly tedy jako důkaz, že ten zápis grantů stačí. Nestačí; ony to mají
-- správně proto, že `authenticated` odvolávají výslovně.
--
-- PRAVIDLO PRO PŘÍŠTĚ: u každého nového pohledu v `public` musí `REVOKE ALL`
-- jmenovat i `authenticated`, ne jen `PUBLIC` a `anon`. Samotný `GRANT SELECT`
-- práva NEZUŽUJE — jen přidává k tomu, co už tam default privileges nasypaly.
--
-- VRATNOST (úplná, ale nedělej to — vrátilo by to tu díru):
--   GRANT INSERT, UPDATE, DELETE, REFERENCES, TRIGGER, MAINTAIN
--     ON public.cenik_pasma_public TO authenticated;
-- =============================================================================

REVOKE ALL ON public.cenik_pasma_public FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cenik_pasma_public TO authenticated;

COMMENT ON VIEW public.cenik_pasma_public IS
  'Standardní pásmový ceník ledu pro všechny přihlášené (stránka Ceník). '
  'JEN KE ČTENÍ: pohled je auto-updatable a security_invoker=off, takže zápis '
  'přes něj obchází RLS tabulky cenik_pasma — authenticated proto smí jen SELECT '
  '(hotfix 20260914150000). Jen platná pásma, bez auditních sloupců. Komerční '
  'sazba a individuální sazby klubů sem NEPATŘÍ (viz A2b, 20260812140000).';
