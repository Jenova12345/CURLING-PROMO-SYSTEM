-- =============================================================================
-- Životní cyklus účtu, schvalování zástupcem, právo navíc
-- Blok C · rozhodnutí PM 27. 8. 2026 (docs/ETAPA3-ROLE-NAVRH.md, R3–R6, R10, R11)
-- =============================================================================
-- CO SE MĚNÍ:
--
-- Dosud dostal každý po registraci rovnou roli `hobby_player` a byl uvnitř.
-- Nově registrace roli NEDÁVÁ — účet čeká, dokud ho někdo neschválí:
--
--   registrace → profil, ŽÁDNÁ role, stav `ceka`
--        ↓  žádost o klub (z registračního formuláře nebo podaná později)
--   schválí ADMIN nebo ZÁSTUPCE cílového klubu
--        ↓
--   členství v klubu + role `hobby_player` + stav `aktivni`   ← jedním krokem
--
-- Tři věci, které z toho plynou a stojí za přečtení:
--
-- 1) DEFAULT-DENY JE VIDĚT (R6). Účet mimo stav `aktivni` by dnes neprošel
--    „náhodou" — nemá roli ani členství, takže mu nesedí žádná politika.
--    Spoléhat u přístupů na náhodu se nemá, a hlavně to neřeší účet, který roli
--    má a byl DEAKTIVOVANÝ. Brána je proto v `ucet_aktivni()` a je zapojená do
--    tří funkcí, na kterých stojí všechny politiky: `has_role`,
--    `is_subject_member`, `is_subject_rep`. Zavřít účet jde tím na jednom místě.
--
-- 2) SCHVALOVAT SMÍ I ZÁSTUPCE (R5), ale jen do SVÉHO klubu — a úroveň
--    „zástupce" smí udělit dál jen admin, jinak by si zástupce vyrobil druhého
--    zástupce a obešel správce haly.
--
-- 3) „PRÁVO NAVÍC" JE ÚZKÉ (R11). `subject_reps.muze_potvrzovat` dovolí hráči
--    potvrdit VÝHRADNĚ SVOJI REZERVACI před akcí. Potvrzení PO akci, které
--    spouští fakturaci firmě a výplaty brigádníkům, hráč nedostane NIKDY (R10).
--
-- -----------------------------------------------------------------------------
-- EXISTUJÍCÍ ÚČTY SE NESMÍ ZAVŘÍT
-- -----------------------------------------------------------------------------
-- Na demu i v provozu už účty s rolí jsou. Sloupec se proto přidává s výchozí
-- hodnotou `aktivni` (tím ji dostanou všechny existující řádky) a teprve POTOM
-- se výchozí hodnota přepne na `ceka` pro nové registrace. Kdyby se to udělalo
-- obráceně, zamkla by migrace úplně všechny — včetně admina, který by to měl
-- odemknout.
--
-- -----------------------------------------------------------------------------
-- VRATNOST (v tomhle pořadí):
--   -- 1) Funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef), ne ze starých
--   --    migrací: handle_new_user, has_role, is_subject_member, is_subject_rep,
--   --    approve_subject_request, reject_subject_request, approve_reservation.
--   -- 2) Politika:
--   DROP POLICY IF EXISTS subject_requests_select ON public.subject_requests;
--   CREATE POLICY subject_requests_select ON public.subject_requests FOR SELECT TO authenticated
--     USING (user_id = auth.uid() OR has_role(auth.uid(), 'admin'));
--   -- 3) Až pak sloupce a pomocné funkce:
--   ALTER TABLE public.subject_reps DROP COLUMN IF EXISTS muze_potvrzovat;
--   ALTER TABLE public.profiles     DROP COLUMN IF EXISTS stav;
--   DROP FUNCTION IF EXISTS public.ma_pravo_navic(uuid);
--   DROP FUNCTION IF EXISTS public.nastav_pravo_navic(uuid, uuid, boolean);
--   DROP FUNCTION IF EXISTS public.ucet_aktivni(uuid);
--   DROP TYPE IF EXISTS public.ucet_stav;
-- Revert NEVRÁTÍ role lidem, kterým je schválení mezitím přidělilo — a nemá,
-- jsou to platná členství.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Stav účtu
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type
                  WHERE typname = 'ucet_stav' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.ucet_stav AS ENUM ('ceka', 'aktivni', 'zamitnut', 'deaktivovan');
  END IF;
END $$;

-- Pořadí je schválně: nejdřív DEFAULT 'aktivni' (dostanou ho existující řádky),
-- teprve pak se DEFAULT přepne na 'ceka'. Viz hlavička.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS stav public.ucet_stav NOT NULL DEFAULT 'aktivni';
ALTER TABLE public.profiles
  ALTER COLUMN stav SET DEFAULT 'ceka';

COMMENT ON COLUMN public.profiles.stav IS
  'Životní cyklus účtu: ceka (po registraci, bez role a bez přístupu) → aktivni (schváleno, přiděleno členství i role) → zamitnut / deaktivovan. Bránu drží ucet_aktivni(), zapojená do has_role / is_subject_member / is_subject_rep.';

CREATE INDEX IF NOT EXISTS idx_profiles_stav_ceka
  ON public.profiles (created_at) WHERE stav = 'ceka';

-- -----------------------------------------------------------------------------
-- 2) Brána default-deny (R6)
--
-- SECURITY DEFINER schválně: čte `profiles` pod vlastníkem, takže se neptá
-- politik na `profiles` a nevzniká rekurze (politika → has_role → ucet_aktivni
-- → profiles → politika).
--
-- Chybějící profil = NEAKTIVNÍ. Účet bez profilu by neměl existovat, a když
-- vznikne, ať je zavřený, ne otevřený.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ucet_aktivni(_uid uuid DEFAULT auth.uid())
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.user_id = _uid AND p.stav = 'aktivni'
  );
$$;

COMMENT ON FUNCTION public.ucet_aktivni(uuid) IS
  'Je účet ve stavu aktivni? Default-deny brána z R6 — zapojená do has_role, is_subject_member a is_subject_rep, takže zavřít účet jde na jednom místě. Chybějící profil se počítá jako neaktivní.';

REVOKE ALL ON FUNCTION public.ucet_aktivni(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ucet_aktivni(uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) Brána zapojená do tří funkcí, na kterých stojí politiky
--
-- Těla jsou vygenerovaná z `pg_get_functiondef` živého schématu (pravidlo 7),
-- zásah je v každé jediná přidaná podmínka.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role app_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles
    WHERE user_id = _user_id
      AND role = _role
  )
  -- R6: role sama nestačí, účet musí být otevřený. Tohle zavírá deaktivovaný
  -- účet i tam, kde mu role zůstala.
  AND public.ucet_aktivni(_user_id)
$function$;

CREATE OR REPLACE FUNCTION public.is_subject_member(_subject uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.subject_reps sr
    JOIN public.subjects s ON s.id = sr.subject_id
    WHERE sr.subject_id = _subject AND sr.user_id = auth.uid() AND s.deleted_at IS NULL
  )
  AND public.ucet_aktivni();
$function$;

CREATE OR REPLACE FUNCTION public.is_subject_rep(_subject uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.subject_reps sr
    JOIN public.subjects s ON s.id = sr.subject_id
    WHERE sr.subject_id = _subject AND sr.user_id = auth.uid()
      AND sr.level = 'rep' AND s.deleted_at IS NULL
  )
  AND public.ucet_aktivni();
$function$;

-- -----------------------------------------------------------------------------
-- 4) Registrace už roli nedává (R4)
--
-- Tělo vygenerované z živého schématu; ubraný je jediný blok — přidělení role.
-- Žádost o klub z registračního formuláře zůstává, je to teď ta jediná cesta,
-- jak se člověk dostane dovnitř.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _klub uuid;
BEGIN
  -- Profil vzniká ve stavu `ceka` (výchozí hodnota sloupce). ROLE SE NEPŘIDĚLUJE —
  -- dostane ji až schválení žádosti (`approve_subject_request`).
  INSERT INTO public.profiles (user_id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data ->> 'full_name');

  -- Vybraný klub z registračního formuláře → ŽÁDOST, ne členství.
  BEGIN
    _klub := nullif(NEW.raw_user_meta_data ->> 'subject_id', '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    _klub := NULL;   -- co není uuid, prostě ignorujeme
  END;

  IF _klub IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.subjects
                  WHERE id = _klub AND type = 'club' AND deleted_at IS NULL) THEN
    INSERT INTO public.subject_requests (user_id, subject_id)
    VALUES (NEW.id, _klub);
  END IF;

  RETURN NEW;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5) Právo navíc (R11)
-- -----------------------------------------------------------------------------
ALTER TABLE public.subject_reps
  ADD COLUMN IF NOT EXISTS muze_potvrzovat boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.subject_reps.muze_potvrzovat IS
  'Právo navíc (R11): člen si smí sám potvrdit SVOJI rezervaci před akcí. Netýká se potvrzení PO akci, které spouští fakturaci a výplaty — to zůstává adminovi a zástupci (R10).';

CREATE OR REPLACE FUNCTION public.ma_pravo_navic(_subject uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.subject_reps sr
    JOIN public.subjects s ON s.id = sr.subject_id
    WHERE sr.subject_id = _subject AND sr.user_id = auth.uid()
      AND sr.muze_potvrzovat AND s.deleted_at IS NULL
  )
  AND public.ucet_aktivni();
$$;

COMMENT ON FUNCTION public.ma_pravo_navic(uuid) IS
  'Má přihlášený člen v tomhle klubu „právo navíc" (smí si potvrdit svoji rezervaci)? Zástupce ho nepotřebuje — ten smí potvrdit cokoli ve svém klubu.';

REVOKE ALL ON FUNCTION public.ma_pravo_navic(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ma_pravo_navic(uuid) TO authenticated, service_role;

-- Udělování práva navíc. Vlastní RPC proto, že `subject_reps` pouští zápis jen
-- adminovi — a tohle má umět i zástupce ve svém klubu.
CREATE OR REPLACE FUNCTION public.nastav_pravo_navic(
  _subject uuid,
  _user    uuid,
  _hodnota boolean
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _uid uuid := auth.uid();
BEGIN
  IF NOT (has_role(_uid, 'admin') OR public.is_subject_rep(_subject)) THEN
    RAISE EXCEPTION 'Právo potvrzovat rezervace uděluje zástupce klubu nebo správce haly.';
  END IF;

  -- Zástupci ho nemá smysl nastavovat — potvrzovat smí z titulu své úrovně.
  UPDATE public.subject_reps
     SET muze_potvrzovat = COALESCE(_hodnota, false)
   WHERE subject_id = _subject AND user_id = _user AND level = 'member';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenhle člověk není členem klubu, kterému chceš právo nastavit.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.nastav_pravo_navic(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.nastav_pravo_navic(uuid, uuid, boolean) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6) Fronta žádostí je vidět i zástupci (R5)
--
-- Bez tohohle by zástupce sice měl právo schválit, ale žádnou žádost by
-- neuviděl — schvalovací fronta by pro něj byla prázdná.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS subject_requests_select ON public.subject_requests;
CREATE POLICY subject_requests_select ON public.subject_requests
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR has_role(auth.uid(), 'admin')
    OR public.is_subject_rep(subject_id)
  );

-- -----------------------------------------------------------------------------
-- 6b) Stav účtu musí vidět i sám čekající uživatel
--
-- Aplikace čte profil z `profiles_self`, ne z tabulky. Pohled byl vytvořený
-- před tímhle sloupcem, takže `stav` v něm nebyl — a přihlašovací obrazovka by
-- se neměla podle čeho rozhodnout, jestli ukázat aplikaci, nebo „čeká se na
-- potvrzení". Vlastní řádek si přečte i účet bez role: politika na `profiles`
-- se ptá na `user_id = auth.uid()`, což na roli nestojí.
--
-- Sloupec se PŘIDÁVÁ NA KONEC a nic se nepřejmenovává — `CREATE OR REPLACE
-- VIEW` jiné pořadí ani odebrání sloupce nepustí.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.profiles_self AS
 SELECT id,
    user_id,
    full_name,
        CASE
            WHEN user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN phone
            ELSE NULL::text
        END AS phone,
        CASE
            WHEN user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) THEN bank_account
            ELSE NULL::text
        END AS bank_account,
    created_at,
    updated_at,
    COALESCE(user_id = auth.uid() OR ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role), false) AS smim_videt_udaje,
    stav
   FROM profiles p;

-- -----------------------------------------------------------------------------
-- 7) Schválení přiděluje roli i klub; schvaluje admin i zástupce (R4, R5)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_subject_request(_request_id uuid, _level subject_rep_level DEFAULT 'member'::subject_rep_level)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _uid uuid := auth.uid(); _z record;
BEGIN
  -- HRUBÁ BRÁNA: kdo není ani admin, ani zástupce ŽÁDNÉHO klubu, nemá tu co
  -- dělat. Přesná kontrola (zástupce TOHO klubu) přijde až po načtení žádosti —
  -- dřív se klub nedá zjistit. Bez téhle první brány by si kdokoli mohl
  -- id žádostí zkoušet a z různých hlášek vyčíst, které existují.
  IF NOT (has_role(_uid, 'admin')
          OR EXISTS (SELECT 1 FROM public.subject_reps sr
                      WHERE sr.user_id = _uid AND sr.level = 'rep')) THEN
    RAISE EXCEPTION 'Žádosti o členství vyřizuje správce haly nebo zástupce klubu.';
  END IF;

  -- Zámek řádku: dvě souběžná kliknutí by jinak vyrobila dvě členství.
  SELECT * INTO _z FROM public.subject_requests WHERE id = _request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Žádost neexistuje.';
  END IF;
  IF _z.status <> 'ceka' THEN
    RAISE EXCEPTION 'Tahle žádost už je vyřízená (%).', _z.status;
  END IF;

  -- PŘESNÁ BRÁNA (R5): zástupce smí schvalovat JEN DO SVÉHO KLUBU. Bez tohohle
  -- by zástupce jednoho klubu přiřazoval lidi do cizích.
  IF NOT (has_role(_uid, 'admin') OR public.is_subject_rep(_z.subject_id)) THEN
    RAISE EXCEPTION 'Do tohohle klubu můžeš přiřazovat jen jako jeho zástupce nebo správce haly.';
  END IF;

  -- ÚROVEŇ „ZÁSTUPCE" PŘIDĚLUJE JEN ADMIN. Kdyby ji směl udělit zástupce, mohl
  -- by si do klubu vyrobit druhého zástupce a obejít tím správce haly.
  IF _level = 'rep' AND NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Zástupce klubu smí jmenovat jen správce haly.';
  END IF;

  -- Klub se kontroluje ZNOVU, i když se ověřoval při podání žádosti. Mezi
  -- podáním a schválením leží libovolně dlouhá doba a klub se mezitím může
  -- smazat; bez téhle kontroly vzniklo členství ve smazaném klubu, které nikde
  -- není vidět (`subjects` skryté kluby nepouští), ale opravňuje. Frontu to
  -- neblokuje — admin takovou žádost prostě zamítne.
  --
  -- `FOR SHARE`, ne holý `EXISTS`: `FOR UPDATE` výš zamyká žádost, ne klub.
  -- Bez tohohle se mezi kontrolu a `INSERT` níž vejde souběžné smazání klubu
  -- a členství vznikne přesto. (Neopravňovalo by k ničemu — `is_subject_member`
  -- i `is_subject_rep` filtrují `deleted_at IS NULL` — ale ožilo by ve chvíli,
  -- kdy by někdo klub obnovil. Zámek na řádku je levnější než ta úvaha.)
  PERFORM 1 FROM public.subjects
    WHERE id = _z.subject_id AND type = 'club' AND deleted_at IS NULL
    FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Klub už neexistuje, takže do něj nejde nikoho přiřadit.'
      USING HINT = 'Žádost zamítni — případně klub nejdřív obnov.';
  END IF;

  -- Členství. `ON CONFLICT` kvůli případu, kdy admin mezitím přiřadil ručně —
  -- žádost se pak jen uzavře a úroveň se srovná na to, co teď zvolil.
  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES (_z.subject_id, _z.user_id, _level, _uid)
  ON CONFLICT (subject_id, user_id) DO UPDATE SET level = EXCLUDED.level;

  -- R4: SCHVÁLENÍ PŘIDĚLUJE ROLI I KLUB JEDNÍM KROKEM.
  --
  -- `handle_new_user` roli po registraci už nedává (účet čeká bez role), takže
  -- tohle je jediné místo, kde ji člověk dostane. `ON CONFLICT DO NOTHING` kvůli
  -- lidem, kteří roli z dřívějška mají — schválení je nesmí shodit.
  INSERT INTO public.user_roles (user_id, role)
  VALUES (_z.user_id, 'hobby_player')
  ON CONFLICT (user_id, role) DO NOTHING;

  -- A účet se tím otevírá. Dokud je `ceka`, zavře ho `ucet_aktivni()` úplně
  -- všude — role ani členství samy o sobě nestačí.
  UPDATE public.profiles SET stav = 'aktivni'
   WHERE user_id = _z.user_id AND stav <> 'aktivni';

  UPDATE public.subject_requests
     SET status = 'schvalena', decided_at = now(), decided_by = _uid
   WHERE id = _request_id;

  PERFORM public.notify_user(
    _z.user_id,
    'subject_request_approved',
    'Jste v klubu',
    'Správce schválil vaše přiřazení ke klubu „'
      || (SELECT name FROM public.subjects WHERE id = _z.subject_id) || '".',
    -- Šestý parametr je `reservation_id` s cizím klíčem na `reservations` —
    -- id žádosti tam NEPATŘÍ (a FK by to odmítl). Notifikace se váže jen ke klubu.
    '/calendar', NULL, _z.subject_id);

  RETURN jsonb_build_object('id', _request_id, 'level', _level);

EXCEPTION
  -- R11: uvnitř SECURITY DEFINER neplatí RLS, takže by Postgres do chyby doplnil
  -- celý řádek. U žádosti to není IBAN, ale pořád je to cizí jméno a poznámka.
  WHEN check_violation OR unique_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'Žádost se nepodařilo schválit.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj, jestli uživatel i klub pořád existují.';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 8) Zamítnutí — taky zástupce, a účet se jím nezavírá
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_subject_request(_request_id uuid, _duvod text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _uid uuid := auth.uid(); _z record;
BEGIN
  IF NOT (has_role(_uid, 'admin')
          OR EXISTS (SELECT 1 FROM public.subject_reps sr
                      WHERE sr.user_id = _uid AND sr.level = 'rep')) THEN
    RAISE EXCEPTION 'Žádosti o členství vyřizuje správce haly nebo zástupce klubu.';
  END IF;

  SELECT * INTO _z FROM public.subject_requests WHERE id = _request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Žádost neexistuje.';
  END IF;
  IF _z.status <> 'ceka' THEN
    RAISE EXCEPTION 'Tahle žádost už je vyřízená (%).', _z.status;
  END IF;

  -- Zamítat smí zástupce jen do svého klubu — souměrně se schvalováním.
  IF NOT (has_role(_uid, 'admin') OR public.is_subject_rep(_z.subject_id)) THEN
    RAISE EXCEPTION 'Tuhle žádost může vyřídit jen zástupce toho klubu nebo správce haly.';
  END IF;
  -- Týž strop jako u poznámky žadatele. Admin-only, takže nízké riziko, ale
  -- nesouměrné pravidlo („žadateli 500 znaků, adminovi neomezeně") je jen
  -- čekání na to, až se do `decision_reason` vleze něco, co nikdo nečeká.
  IF length(coalesce(_duvod, '')) > 500 THEN
    RAISE EXCEPTION 'Důvod je moc dlouhý (nejvýš 500 znaků, máš %).', length(_duvod);
  END IF;

  UPDATE public.subject_requests
     SET status = 'zamitnuta', decided_at = now(), decided_by = _uid,
         decision_reason = nullif(btrim(coalesce(_duvod, '')), '')
   WHERE id = _request_id;

  -- ÚČET ZŮSTÁVÁ ČEKAT, NEZAVÍRÁ SE.
  --
  -- Zamítnutí žádosti o KLUB neznamená zamítnutí ČLOVĚKA — typicky si spletl
  -- klub a podá si to znovu. Na `zamitnut` ho převede až admin ručně; sem to
  -- nepatří, protože by se tím z překliku ve frontě stalo zavření účtu.
  -- (Účet bez schválené žádosti je stejně `ceka`, takže dovnitř se nedostane.)

EXCEPTION
  -- R11, ať je to souměrné se `approve_subject_request`.
  WHEN check_violation OR not_null_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'Žádost se nepodařilo zamítnout.'
      USING ERRCODE = '22023',
            HINT = 'Zkus to znovu; když to potrvá, zkontroluj stav žádosti ve frontě.';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 9) Potvrzení rezervace: větev pro hráče s právem navíc (R11)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_reservation(p_reservation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _res      public.reservations%ROWTYPE;
  _ids      uuid[];
  _potvrzeno int;
  _spravce  boolean;
  _jen_svoje boolean;
BEGIN
  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;

  -- KDO SMÍ POTVRDIT REZERVACI (R11).
  --
  -- Admin a zástupce klubu smí cokoli ve svém rozsahu. Hráč s „právem navíc"
  -- (`subject_reps.muze_potvrzovat`) smí potvrdit JEN SVOJI rezervaci — a nic
  -- víc, protože jinak by si jedním kliknutím odbavil celou akci klubu.
  --
  -- ⚠️ Tohle je potvrzení REZERVACE PŘED AKCÍ. Potvrzení PO akci, které spouští
  -- fakturaci a výplaty, je jiná brána a hráči se nedává NIKDY (R10).
  _spravce := has_role(auth.uid(), 'admin')
              OR (_res.subject_id IS NOT NULL AND public.is_subject_rep(_res.subject_id));

  _jen_svoje := NOT _spravce
                AND _res.created_by = auth.uid()
                AND _res.subject_id IS NOT NULL
                AND public.ma_pravo_navic(_res.subject_id);

  IF NOT (_spravce OR _jen_svoje) THEN
    RAISE EXCEPTION 'Rezervaci může potvrdit jen zástupce klubu nebo správce.';
  END IF;

  -- Celá akce = všechny živé rezervace se stejným event_id (typicky obě dráhy).
  -- Klubová rezervace bez akce zůstává sama za sebe.
  -- Skupina se drží JEDNOHO subjektu: kdyby někdo ručně pověsil na akci rezervaci
  -- jiného klubu, nesmí ji zástupce potvrdit jedním kliknutím s tou svou.
  SELECT array_agg(r.id) INTO _ids
    FROM public.reservations r
   WHERE r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND r.approved_at IS NULL
     AND r.subject_id IS NOT DISTINCT FROM _res.subject_id
     -- Hráč s právem navíc potvrzuje jen to, co sám založil. U akce na dvou
     -- drahách to tedy sebere obě jeho rezervace, ale ne rezervaci, kterou pod
     -- tutéž akci pověsil někdo jiný.
     AND (NOT _jen_svoje OR r.created_by = auth.uid())
     AND (
       (_res.event_id IS NOT NULL AND r.event_id = _res.event_id)
       OR (_res.event_id IS NULL AND r.id = _res.id)
     );

  IF _ids IS NULL OR array_length(_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('approved', 0);   -- už potvrzeno, není co dělat
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET approved_at = now(), approved_by = auth.uid()
   WHERE id = ANY (_ids);
  GET DIAGNOSTICS _potvrzeno = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object('approved', _potvrzeno);
EXCEPTION
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 10) Kontrola
-- -----------------------------------------------------------------------------
DO $$
DECLARE _n int;
BEGIN
  IF EXISTS (SELECT 1 FROM public.profiles WHERE stav <> 'aktivni') THEN
    SELECT count(*) INTO _n FROM public.profiles WHERE stav <> 'aktivni';
    RAISE NOTICE 'Pozor: % existujících účtů není ve stavu aktivni.', _n;
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.handle_new_user'::regproc) LIKE '%hobby_player%' THEN
    RAISE EXCEPTION 'handle_new_user pořád přiděluje roli — životní cyklus účtu by nefungoval.';
  END IF;

  PERFORM 1 FROM pg_proc WHERE oid = 'public.ucet_aktivni(uuid)'::regprocedure;
  IF NOT FOUND THEN RAISE EXCEPTION 'ucet_aktivni() chybí.'; END IF;

  RAISE NOTICE 'Životní cyklus účtu je na místě (registrace bez role, brána ucet_aktivni, právo navíc).';
END $$;
