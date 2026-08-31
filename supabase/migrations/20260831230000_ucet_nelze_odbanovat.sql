-- =============================================================================
-- Zavřený účet se nesmí otevřít přes žádost o klub
-- Nález z brány (ultra review, 31. 8. 2026) — MUST-FIX před vpuštěním klubů
-- =============================================================================
-- CO BYLO ŠPATNĚ:
--
-- `approve_subject_request` přepínala stav účtu na `aktivni` bezpodmínečně
-- (`WHERE stav <> 'aktivni'`) a `request_subject_membership` se stavu neptala
-- vůbec. Dohromady to byl obchvat kolem deaktivace, který nepotřeboval admina:
--
--   1. admin uživatele zavře (`stav = 'deaktivovan'`) — token mu dál funguje,
--   2. uživatel si přes REST podá žádost do JAKÉHOKOLI jiného klubu,
--   3. zástupce toho klubu ji schválí (o zavření nic neví),
--   4. účet je zpátky `aktivni`, i s rolí `hobby_player`.
--
-- A protože `ucet_aktivni()` je brána pod `has_role`, `is_subject_member`
-- i `is_subject_rep`, otevřelo se tím ÚPLNĚ VŠECHNO, co blok C zavřel.
-- Čekací obrazovka v `AppLayout` je jen klientská a tuhle cestu nevidí.
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ (dvě vrstvy, schválně obě)
-- -----------------------------------------------------------------------------
--   1. ŽÁDOST SE NEPODÁ z účtu ve stavu `deaktivovan` / `zamitnut`.
--   2. SCHVÁLENÍ neotevře účet, který v takovém stavu je — a stav zvedá jen
--      z `ceka`, nikdy z konečného rozhodnutí admina.
--
-- Druhá vrstva není opis první: žádost mohla ve frontě ležet z doby PŘED
-- deaktivací, a tu by první vrstva nezachytila.
--
-- `ucet_aktivni()` se na to použít nedá — účet po registraci je `ceka` a žádost
-- o klub je právě ta cesta, kterou se z `ceka` dostane ven. Zavírají se proto
-- jmenovitě jen konečné stavy.
--
-- -----------------------------------------------------------------------------
-- OBNOVENÍ ÚČTU
-- -----------------------------------------------------------------------------
-- Zůstává tam, kde bylo: `UPDATE profiles SET stav = 'aktivni'` pod adminem
-- (RLS to pouští jen jemu). Vlastní RPC ani obrazovka na to zatím nejsou —
-- je to follow-up, ne součást téhle opravy.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   -- Obě funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef) ve znění
--   -- z 20260817140000_zadosti_o_klub.sql a 20260831140000_zivotni_cyklus_uctu.sql.
--   -- Data se nemění, migrace jen mění těla dvou funkcí.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Žádost se ze zavřeného účtu nepodá
--
-- Tělo vygenerované z `pg_get_functiondef` živého schématu (pravidlo 7); zásah
-- je jediný přidaný blok hned za kontrolou přihlášení.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_subject_membership(_subject_id uuid, _poznamka text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid uuid := auth.uid();
  _id  uuid;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Pro podání žádosti se musíte přihlásit.';
  END IF;

  -- ZAVŘENÝ ÚČET SI ŽÁDOST NEPODÁ.
  --
  -- Bez tohohle byla žádost o klub obchvat kolem deaktivace: účet, který admin
  -- zavřel, si podal žádost do LIBOVOLNÉHO jiného klubu a jeho zástupce ho
  -- jedním kliknutím otevřel zpátky (`approve_subject_request` stav
  -- bezpodmínečně přepínala na `aktivni`). Zástupce přitom o zavření nic neví.
  --
  -- `ucet_aktivni()` se tu použít NEDÁ: účet po registraci je `ceka` a tohle je
  -- právě ta cesta, kterou se odtamtud dostane ven. Zavírají se jen konečné
  -- stavy, o kterých rozhodl admin.
  IF EXISTS (SELECT 1 FROM public.profiles p
              WHERE p.user_id = _uid AND p.stav IN ('deaktivovan', 'zamitnut')) THEN
    RAISE EXCEPTION 'Tenhle účet je uzavřený, žádost o klub z něj podat nejde.'
      USING HINT = 'Obnovit účet může jen správce haly.';
  END IF;
  -- Délka poznámky se kontroluje TADY, ne až constraintem. Constraint by ji
  -- taky zachytil, jenže jako `check_violation` uvnitř SECURITY DEFINER — a to
  -- znamená, že Postgres do chyby přidá `DETAIL: Failing row contains (…)`
  -- s celým řádkem a jménem constraintu, a `useSubjectRequests` tu anglickou
  -- hlášku pošle rovnou uživateli. Česká věta předem je lepší než odchycená
  -- havárie potom.
  IF length(coalesce(_poznamka, '')) > 500 THEN
    RAISE EXCEPTION 'Poznámka je moc dlouhá (nejvýš 500 znaků, máš %).', length(_poznamka);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subjects
                  WHERE id = _subject_id AND type = 'club' AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Vybraný klub neexistuje.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.subject_reps WHERE user_id = _uid AND subject_id = _subject_id) THEN
    RAISE EXCEPTION 'V tomhle klubu už jste.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.subject_requests WHERE user_id = _uid AND status = 'ceka') THEN
    RAISE EXCEPTION 'Jedna žádost už čeká na vyřízení.'
      USING HINT = 'Počkej, až ji správce vyřídí, nebo mu napiš.';
  END IF;

  INSERT INTO public.subject_requests (user_id, subject_id, poznamka)
  VALUES (_uid, _subject_id, nullif(btrim(coalesce(_poznamka, '')), ''))
  RETURNING id INTO _id;

  RETURN _id;

-- Kontrola „už jedna čeká" výš je TOCTOU: dvě soubězná odeslání formuláře jí
-- obě projdou a teprve unikátní index jedno z nich zastaví. Bez tohohle bloku
-- by druhý uživatel dostal anglické „duplicate key value violates unique
-- constraint …" i s vypsaným klíčem místo české věty. Vyhodnocení je stejné
-- jako u kontroly výš, jen se dozví přes index.
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Jedna žádost už čeká na vyřízení.'
      USING HINT = 'Počkej, až ji správce vyřídí, nebo mu napiš.';
  -- R11 jako u sourozenců. Kontrola délky výš pokrývá jediný constraint, na
  -- který dnes jde narazit; tohle je záchytná síť pro ty, které někdo přidá
  -- příště — ať se ven nedostane `DETAIL: Failing row contains (…)`.
  WHEN check_violation OR not_null_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'Žádost se nepodařilo podat.'
      USING ERRCODE = '22023',
            HINT = 'Zkontroluj vyplněné údaje a zkus to znovu.';
END;
$function$;

-- -----------------------------------------------------------------------------
-- 2) Schválení neotevře zavřený účet
--
-- Tělo z živého schématu; zásahy jsou dva — brána po načtení žádosti a změna
-- `stav <> 'aktivni'` na `stav = 'ceka'` u otevírání účtu.
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

  -- UZAVŘENÝ ÚČET SE PŘES FRONTU NEOTVÍRÁ. Žádost mohla vzniknout dřív, než
  -- ho admin zavřel; schválit ji by znamenalo vrátit mu roli i členství.
  -- Zástupce klubu o deaktivaci nic neví, takže by to udělal v dobré víře.
  IF EXISTS (SELECT 1 FROM public.profiles p
              WHERE p.user_id = _z.user_id AND p.stav IN ('deaktivovan', 'zamitnut')) THEN
    RAISE EXCEPTION 'Účet žadatele je uzavřený — schválit členství mu nejde.'
      USING HINT = 'Nejdřív ho musí obnovit správce haly; pak žádost projde.';
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

  -- A účet se tím otevírá — ALE JEN Z „ČEKÁ".
  --
  -- Dřív tu byla podmínka „stav není aktivni", což znamenalo, že schválení
  -- žádosti otevřelo i účet, který admin vědomě ZAVŘEL nebo ZAMÍTL.
  -- Zástupce klubu tím uměl zrušit rozhodnutí správce haly, aniž by o něm
  -- věděl — stačilo, aby si zavřený uživatel podal žádost do jeho klubu.
  -- Podat ji dnes nejde (`request_subject_membership`), tohle je druhá vrstva:
  -- stará žádost mohla zůstat ve frontě z doby PŘED deaktivací.
  UPDATE public.profiles SET stav = 'aktivni'
   WHERE user_id = _z.user_id AND stav = 'ceka';

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
-- 3) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.approve_subject_request(uuid,public.subject_rep_level)'::regprocedure)
     LIKE '%stav <> ''aktivni''%' THEN
    RAISE EXCEPTION 'approve_subject_request pořád otevírá účet bezpodmínečně — obchvat kolem deaktivace je zpátky.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.request_subject_membership(uuid,text)'::regprocedure)
     NOT LIKE '%deaktivovan%' THEN
    RAISE EXCEPTION 'request_subject_membership nekontroluje stav účtu.';
  END IF;

  -- Granty se `CREATE OR REPLACE` nemění, ale ať je to vidět: obě funkce musí
  -- zůstat dostupné přihlášeným a nedostupné anonymům.
  IF EXISTS (SELECT 1 FROM information_schema.role_routine_grants
              WHERE routine_schema = 'public'
                AND routine_name IN ('approve_subject_request', 'request_subject_membership')
                AND grantee IN ('anon', 'PUBLIC')) THEN
    RAISE EXCEPTION 'Žádostní funkce mají grant pro anon/PUBLIC.';
  END IF;

  RAISE NOTICE 'Zavřený účet se přes žádost o klub neotevře.';
END $kontrola$;
