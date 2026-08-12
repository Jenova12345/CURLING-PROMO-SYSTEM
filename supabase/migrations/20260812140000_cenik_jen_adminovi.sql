-- =============================================================================
-- A2b — Ceník vidí jen admin (Etapa 2)
-- =============================================================================
-- PROČ: rozhodnutí klienta z 31. 7. 2026 zní „obsazenost i název klubu vidí
-- všichni přihlášení, ČÁSTKU jen admin a autor". U `reservations` to platí —
-- peněžní sloupce mají sloupcový REVOKE a maskuje je pohled `reservations_calendar`.
-- U `public.settings` ale ne: politika `settings_select` má `USING (true)`
-- a tabulkový grant, takže `GET /rest/v1/settings` vrátí každému přihlášenému
-- KOMPLETNÍ CENÍK. Ověřeno útokem: obyčejný člen dostal 600 / 1500 / 600 / 800.
--
-- Člen přitom vidí časy rezervací svého klubu, takže si z ceníku částku
-- dopočítá — a maskování na `reservations` je tím obejité.
--
-- Není to nový požadavek, jen dodržení už odsouhlaseného.
--
-- CO TO ZAVÍRÁ A CO NE, ať se přínos nepřeceňuje: autor rezervace svou sazbu vidí
-- dál přes `reservations_calendar` — a má, klientovo pravidlo zní „admin A AUTOR".
-- Zmizí tedy sazby typů akcí, které dotyčný nikdy nerezervuje (komerční, turnaj),
-- a celý ceník před lidmi, kteří nerezervují vůbec (instruktor, brigádník).
--
-- Pohledy mají `security_invoker = off`, takže běží pod vlastníkem a RLS základní
-- tabulky NEuplatňují. U `settings` je to bez následku (jeden řádek, politika
-- `USING (true)`), u `subjects_rates` je řádkové omezení napsané přímo v pohledu.
--
-- JAK: přesně tím vzorem, který v projektu už je (booking_api.sql:58-62):
--   1. sloupcový REVOKE na peněžních sloupcích tabulky,
--   2. pohled se `security_invoker = off`, který sazby vydá jen adminovi.
-- Druhý vzor se schválně nezavádí — dva různé způsoby maskování ceny by byly
-- horší než jeden, i kdyby byl každý sám o sobě v pořádku.
--
-- VIDITELNOST SE ZUŽUJE, NE ROZŠIŘUJE. Neprice pole (otevírací doba, přepínač
-- e-mailů) zůstávají čitelná všem přihlášeným — kalendář na otevírací době stojí
-- (`hoursForDay`), takže kdyby zmizela, rozbije se všem.
--
-- VRATNOST — celý revert, ověřený proti ACL netknutého dema (shoda bit po bitu):
--   DROP VIEW IF EXISTS public.settings_public;
--   DROP VIEW IF EXISTS public.subjects_rates;
--   REVOKE SELECT ON public.settings FROM anon, authenticated;  -- smete i sloupcové granty
--   GRANT  SELECT ON public.settings TO   anon, authenticated;
--   REVOKE SELECT ON public.subjects FROM anon, authenticated;
--   GRANT  SELECT ON public.subjects TO   anon, authenticated;
--   ALTER FUNCTION public.set_reservation_pricing() SECURITY INVOKER;
--
-- Ten REVOKE před GRANTem není překlep: bez něj zůstanou viset sloupcové granty
-- a první nově přidaný sloupec by byl pro `authenticated` nečitelný — tabulka by
-- se rozbila až někdy později a nikdo by to nespojil s tímhle revertem.
--
-- Revert DB musí jít SPOLU s revertem kódu: `useSettings` a `useReservations` už
-- čtou `settings_public`, takže samotné shození pohledu je v aplikaci 404.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Pohled: neprice pole všem, sazby jen adminovi
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.settings_public;

CREATE VIEW public.settings_public
  WITH (security_invoker = off) AS
  SELECT
    s.id,
    s.singleton,
    -- Neprice pole — čte je kalendář, musí zůstat dostupná všem přihlášeným.
    s.opening_hours,
    s.email_notifications_enabled,
    s.updated_at,
    s.updated_by,
    -- Sazby: jen admin. Stejný tvar jako maskování v reservations_calendar,
    -- ať se obě místa čtou stejně.
    CASE WHEN (SELECT has_role(auth.uid(), 'admin')) THEN s.club_default_rate       END AS club_default_rate,
    CASE WHEN (SELECT has_role(auth.uid(), 'admin')) THEN s.commercial_default_rate END AS commercial_default_rate,
    CASE WHEN (SELECT has_role(auth.uid(), 'admin')) THEN s.training_rate           END AS training_rate,
    CASE WHEN (SELECT has_role(auth.uid(), 'admin')) THEN s.tournament_rate         END AS tournament_rate,
    -- Ať frontend nemusí dopočítávat z rolí, jestli je prázdná sazba „nenastaveno"
    -- nebo „nesmíš vidět". Bez toho by admin s prázdným ceníkem vypadal stejně
    -- jako člen — a formulář by tiše nabídl uložit NULL přes existující hodnotu.
    COALESCE((SELECT has_role(auth.uid(), 'admin')), false) AS can_see_rates
  FROM public.settings s;

REVOKE ALL ON public.settings_public FROM anon, authenticated, public;
GRANT SELECT ON public.settings_public TO authenticated;

COMMENT ON VIEW public.settings_public IS
  'Nastavení pro frontend. Neprice pole všem přihlášeným, sazby jen adminovi (rozhodnutí klienta „částku jen admin a autor"). Zápis jde dál přes tabulku public.settings, kde ho hlídá settings_update_admin.';

-- -----------------------------------------------------------------------------
-- 2) Sloupcový REVOKE — aby pohled nešlo obejít čtením tabulky napřímo
--
-- Tohle je ta část, která únik doopravdy zavírá. Samotný pohled by nestačil:
-- `GET /rest/v1/settings?select=club_default_rate` míří na tabulku, ne na pohled.
--
-- REVOKE dopadá i na admina (`admin` je aplikační role v user_roles, ne databázová,
-- takže se granty rozlišit nedají) — admin proto čte sazby z pohledu. Zápis tím
-- dotčený není: `UPDATE ... SET club_default_rate = …` potřebuje UPDATE, ne SELECT,
-- a `useSettings` nepoužívá RETURNING.
-- -----------------------------------------------------------------------------
-- POZOR NA POŘADÍ: samotný sloupcový REVOKE je bez účinku, dokud drží TABULKOVÝ
-- grant — ten totiž pokrývá všechny sloupce včetně budoucích a sloupcové odebrání
-- ho nepřebije. Musí se proto sundat celý SELECT a vrátit jen povolené sloupce.
-- (Napoprvé jsem to napsal obráceně a kontrola v části 3 to zachytila.)
REVOKE SELECT ON public.settings FROM anon, authenticated;

-- Neprice pole zůstávají čitelná napřímo. `singleton` je mezi nimi nutně:
-- `UPDATE … WHERE singleton = true` potřebuje na ten sloupec SELECT, jinak by
-- adminovi přestalo fungovat ukládání.
GRANT SELECT (id, singleton, opening_hours, email_notifications_enabled, updated_at, updated_by)
  ON public.settings TO authenticated;

-- -----------------------------------------------------------------------------
-- 2b) Táž díra u `subjects.default_rate` — bez ní by oprava ceníku byla k ničemu
--
-- `defaultRateFor` v ReservationDialog sahá po sazbě subjektu DŘÍV než po ceníku,
-- takže dokud je čitelná, člen i instruktor si cenu přečtou i se zavřeným ceníkem.
-- Ověřeno útokem: instruktor dostal u svého klubu 450,00 Kč/h, a šlo to použít
-- i jako filtr (`?default_rate=gt.400`).
--
-- Ne-admin `default_rate` k ničemu nepotřebuje: pole se sazbou má jen pro čtení
-- a rezervaci mu stejně nacení trigger. Sazby proto dostane jen admin, a to
-- samostatným pohledem — ten nemusí replikovat řádkový filtr RLS, protože
-- adminovi `subjects_select` stejně vydá všechny řádky.
-- -----------------------------------------------------------------------------
REVOKE SELECT ON public.subjects FROM anon, authenticated;

GRANT SELECT (id, type, name, ico, dic, address,
              created_by, created_at, updated_by, updated_at, deleted_at)
  ON public.subjects TO authenticated;

DROP VIEW IF EXISTS public.subjects_rates;

CREATE VIEW public.subjects_rates
  WITH (security_invoker = off) AS
  SELECT s.id, s.default_rate
    FROM public.subjects s
   WHERE (SELECT has_role(auth.uid(), 'admin'));

REVOKE ALL ON public.subjects_rates FROM anon, authenticated, public;
GRANT SELECT ON public.subjects_rates TO authenticated;

COMMENT ON VIEW public.subjects_rates IS
  'Sazby subjektů pro admina. Ne-admin dostane prázdno (řádkové omezení je v pohledu, protože security_invoker = off obchází RLS).';

-- -----------------------------------------------------------------------------
-- 3) Nacenění musí sazby číst dál — jinak REVOKE rozbije zakládání rezervací
--
-- `set_reservation_pricing()` je BEFORE INSERT trigger a sazbu bere z ceníku:
--   SELECT * INTO _st FROM public.settings LIMIT 1;
-- Byl SECURITY INVOKER, takže po odebrání SELECTu běžel jako `authenticated`
-- a spadl na „permission denied for table settings" — a to i adminovi, protože
-- `admin` je aplikační role v user_roles, ne databázová.
--
-- Přes RPC (`create_booking` a spol.) by se to neprojevilo, ty jsou SECURITY
-- DEFINER a vlastní je `postgres`. Ale `authenticated` má na `reservations`
-- zápisové granty a politika `reservations_insert` členovi klubu INSERT povoluje,
-- takže přímá cesta přes REST by přestala fungovat. Ověřeno útokem, ne úvahou.
--
-- Trigger sazby číst POTŘEBUJE — je to serverový výpočet, jehož celý smysl je
-- vzít cenu z ceníku. Správná odpověď proto není mu ji zpřístupnit přes granty
-- (to by únik znovu otevřelo), ale nechat ho běžet jako vlastník. Nic z ceníku
-- nevrací volajícímu, jen z něj naplní NEW; `search_path` má nastavený už dnes.
-- -----------------------------------------------------------------------------
ALTER FUNCTION public.set_reservation_pricing() SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- 4) Kontrola, že to opravdu zavřelo — migrace si nemá jen přát
-- -----------------------------------------------------------------------------
-- Kontroluje se ROVNOST s povoleným seznamem, ne jen nepřítomnost sazeb. Kdyby se
-- hlídal výčet, nový cenový sloupec by prošel bez povšimnutí — a to je u těchhle
-- tabulek ta pravděpodobnější chyba. Takhle migrace spadne, dokud ho někdo vědomě
-- nezařadí.
--
-- Do `grantee` patří i PUBLIC: `GRANT SELECT ON settings TO PUBLIC` by sazby otevřel
-- všem, a kontrola omezená na anon/authenticated by to propustila.
DO $$
DECLARE
  _tabulky text[] := ARRAY['settings', 'subjects'];
  _tabulka text;
  _povolene text[];
  _ctitelne text[];
  _navic    text[];
  _chybi    text[];
BEGIN
  FOREACH _tabulka IN ARRAY _tabulky LOOP
    _povolene := CASE _tabulka
      WHEN 'settings' THEN ARRAY['id', 'singleton', 'opening_hours',
                                 'email_notifications_enabled', 'updated_at', 'updated_by']
      WHEN 'subjects' THEN ARRAY['id', 'type', 'name', 'ico', 'dic', 'address',
                                 'created_by', 'created_at', 'updated_by', 'updated_at', 'deleted_at']
    END;

    SELECT COALESCE(array_agg(DISTINCT column_name ORDER BY column_name), ARRAY[]::text[])
      INTO _ctitelne
      FROM information_schema.column_privileges
     WHERE table_schema = 'public' AND table_name = _tabulka
       AND privilege_type = 'SELECT'
       AND grantee IN ('anon', 'authenticated', 'PUBLIC');

    SELECT COALESCE(array_agg(c ORDER BY c), ARRAY[]::text[]) INTO _navic
      FROM unnest(_ctitelne) c WHERE c <> ALL (_povolene);
    SELECT COALESCE(array_agg(c ORDER BY c), ARRAY[]::text[]) INTO _chybi
      FROM unnest(_povolene) c WHERE c <> ALL (_ctitelne);

    IF array_length(_navic, 1) > 0 THEN
      RAISE EXCEPTION 'A2b selhala: v %s zůstaly čitelné sloupce mimo povolený seznam (%s).',
        _tabulka, array_to_string(_navic, ', ')
        USING HINT = 'Necenový sloupec přidej do seznamu. Cenový nech nečitelný.';
    END IF;

    IF array_length(_chybi, 1) > 0 THEN
      RAISE EXCEPTION 'A2b selhala: v %s nejsou čitelné necenové sloupce (%s) — rozbil by se kalendář.',
        _tabulka, array_to_string(_chybi, ', ');
    END IF;
  END LOOP;

  RAISE NOTICE 'A2b: sazby (ceník i subjekty) jsou nově jen pro admina, ostatní pole zůstávají všem.';
END $$;
