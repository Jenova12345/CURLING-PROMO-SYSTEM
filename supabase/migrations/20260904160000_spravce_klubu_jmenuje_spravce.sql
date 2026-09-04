-- =============================================================================
-- Správce klubu smí jmenovat dalšího správce — ve SVÉM klubu (zadání 4. 9. 2026)
-- =============================================================================
-- ⚠ TOHLE JE VĚDOMÁ ZMĚNA BEZPEČNOSTNÍHO PRAVIDLA, ne oprava chyby.
--
-- Do dneška platilo: „Zástupce klubu smí jmenovat jen správce haly." Stálo to
-- v `approve_subject_request` i s odůvodněním — zástupce by si jinak vyrobil
-- druhého zástupce a obešel tím správce haly. To odůvodnění NEPŘESTALO PLATIT;
-- jen se to nově povoluje, protože si klub má své správce spravovat sám.
--
-- CO SE MĚNÍ
--
-- 1. `approve_subject_request` — správce klubu smí schválit nového člověka
--    rovnou jako SPRÁVCE svého klubu (dřív jen jako člena).
-- 2. Nová RPC `jmenuj_spravce_klubu(_subject, _user)` — povýší STÁVAJÍCÍHO
--    člena klubu na správce. Bez ní by šlo jmenovat jen lidi, kteří zrovna
--    čekají ve frontě žádostí, což je ta vzácnější půlka; běžný případ je
--    „Petr je u nás rok členem, ať to po mně převezme".
--
-- CO SE NEMĚNÍ (hranice ze zadání)
--
--   * JEN SVŮJ KLUB. Obě cesty stojí na `is_subject_rep(<klub>)`, které
--     vyžaduje `level = 'rep'` I aktivní účet. Cizí klub je nedosažitelný.
--   * NA PENÍZE SE NESAHÁ. Ani jedna cesta nemění `subjects.default_rate`,
--     ceník, sazby ani doklady.
--   * ROLE ZŮSTÁVAJÍ ADMINOVI. `user_roles` se odsud přiděluje jen
--     `hobby_player` (to dělalo schválení odjakživa); `trainer`, `admin`
--     a štábní role dál uděluje výhradně správce haly.
--   * ODEBRAT správce klubu tudy NEJDE. Zadání mluví o jmenování; degradace
--     a odebrání členství zůstávají adminovi (`subject_reps_update_admin`
--     a `subject_reps_delete_admin`). Kdyby to klub potřeboval, je to
--     samostatné rozhodnutí — a nebezpečnější, protože „odeber správce"
--     je nástroj, kterým se dá klub převzít.
--
--     POZOR, tohle tvrzení NEPLATILO samo od sebe: `approve_subject_request`
--     měla `ON CONFLICT DO UPDATE SET level = EXCLUDED.level`, takže schválení
--     zaseklé žádosti na `'member'` uměla stávajícího správce SUNDAT. Do téhle
--     migrace to zvládl jen admin; s ní by to zvládl každý správce klubu.
--     Zavírá se to tady (viz `CASE WHEN ... level = 'rep'` u toho INSERTu) —
--     našla to bezpečnostní brána, ne úvaha.
--   * UZAVŘENÝ ÚČET SE TÍM NEOTEVÍRÁ. Obě cesty ho odmítnou.
--
-- ZBYLÉ RIZIKO, ať je řečené nahlas: jeden kompromitovaný účet správce klubu
-- teď umí do klubu přidat další správce a správce haly se to dozví až
-- z auditu (`trg_subject_reps_audit` na `subject_reps` a
-- `trg_subject_requests_audit` na žádostech). Do dneška to uměl jen admin.
--
-- VRATNOST
--
-- SCHÉMA — vratné:
--   1. `approve_subject_request` vrátit celým tělem — vygenerovat
--      z `pg_get_functiondef`, nepřepisovat z hlavy (pravidlo 7). Naposledy ji
--      před touhle migrací definovala `20260831230000_ucet_nelze_odbanovat.sql`;
--      dřívější znění tady ukazovalo na „řadu 20260902…", což NEPLATÍ.
--      Tělo v téhle migraci je převzaté ze ŽIVÉHO schématu a ověřené diffem:
--      odebrány 4 řádky (starý komentář + stará brána), přidáno 25.
--   2. `DROP FUNCTION public.jmenuj_spravce_klubu(uuid, uuid);`
-- DATA — migrace žádná data nemění.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Schválení žádosti rovnou na úroveň správce klubu
-- ---------------------------------------------------------------------------
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

  -- ÚROVEŇ „SPRÁVCE KLUBU" SMÍ UDĚLIT I SPRÁVCE KLUBU — ALE JEN VE SVÉM.
  --
  -- VĚDOMÁ ZMĚNA PRAVIDLA (zadání Tomáše, 4. 9. 2026). Do téhle migrace tu
  -- stálo „úroveň zástupce přiděluje jen admin" s odůvodněním, že by si jinak
  -- zástupce vyrobil druhého zástupce a obešel správce haly. To je pořád
  -- pravda — jen se to nově POVOLUJE: klub si své správce spravuje sám.
  --
  -- CO TÍM PŘIBYLO ZA RIZIKO, ať to není schované: jeden kompromitovaný účet
  -- správce klubu umí do klubu přidat další správce a správce haly se to
  -- dozví jen z auditu. Hranice, které to drží:
  --   * PŘESNÁ BRÁNA (R5) o pár řádků výš pustí dál jen admina nebo správce
  --     TOHOHLE klubu, takže cizí klub je nedosažitelný;
  --   * `is_subject_rep()` vyžaduje `level = 'rep'` I aktivní účet — řadový
  --     člen ani zavřený účet tudy neprojdou;
  --   * na peníze to nesahá: `subjects.default_rate`, ceník ani doklady se
  --     odsud nemění;
  --   * role v `user_roles` dál uděluje jen správce haly (níž se přiděluje
  --     pouze `hobby_player`);
  --   * `trg_subject_reps_audit` zapíše, kdo koho jmenoval.
  --
  -- Kontrola je schválně ZDVOJENÁ s R5, i když je dnes díky pořadí nadbytečná:
  -- kdyby někdo bloky přeházel, tenhle si hranici „jen svůj klub" ohlídá sám.
  IF _level = 'rep' AND NOT (has_role(_uid, 'admin')
                             OR public.is_subject_rep(_z.subject_id)) THEN
    RAISE EXCEPTION 'Správce klubu jmenuje jen jeho stávající správce nebo správce haly.';
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
  -- SCHVÁLENÍM SE NEDEGRADUJE (nález bezpečnostní brány).
  --
  -- `DO UPDATE SET level = EXCLUDED.level` znamenalo, že když člověk, který
  -- v klubu UŽ JE SPRÁVCEM, má někde zaseklou žádost ve stavu `ceka`, dalo se
  -- ho schválením na `'member'` sundat z `rep`. Do téhle migrace to uměl jen
  -- admin, a tomu to patří; od teď by to uměl každý správce klubu — a „sundej
  -- ostatní správce" je přesně nástroj, kterým se dá klub převzít.
  --
  -- Stávající úroveň `rep` proto schválení nikdy nesnižuje. Povýšit
  -- (`member` → `rep`) smí dál. Degradace zůstává adminovi, který na
  -- `subject_reps` sahá přímo přes RLS (`subject_reps_update_admin`).
  --
  -- Na produkci je dnes takových žádostí 0, takže to nic neopravuje zpětně —
  -- zavírá to cestu, kterou tahle migrace otevřela širšímu okruhu lidí.
  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES (_z.subject_id, _z.user_id, _level, _uid)
  ON CONFLICT (subject_id, user_id) DO UPDATE
    SET level = CASE WHEN public.subject_reps.level = 'rep'
                     THEN 'rep'::public.subject_rep_level
                     ELSE EXCLUDED.level END;

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


-- ---------------------------------------------------------------------------
-- 2) Povýšení stávajícího člena na správce klubu
-- ---------------------------------------------------------------------------
-- Vzor je opsaný z `nastav_pravo_navic` — táž tabulka, táž brána, tentýž tvar
-- hlášky, když člověk v klubu není. Držet se ho je schválně: dvě rep-volatelné
-- funkce nad `subject_reps`, které se chovají jinak, se čtou hůř než jedna.
CREATE OR REPLACE FUNCTION public.jmenuj_spravce_klubu(_subject uuid, _user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _uid uuid := auth.uid();
BEGIN
  -- JEN SVŮJ KLUB. `is_subject_rep` vyžaduje `level='rep'` i aktivní účet,
  -- takže řadový člen ani zavřený účet sem nedosáhnou.
  IF NOT (has_role(_uid, 'admin') OR public.is_subject_rep(_subject)) THEN
    RAISE EXCEPTION 'Správce klubu jmenuje jen jeho stávající správce nebo správce haly.';
  END IF;

  -- JEN KLUB, ne komerční subjekt — souměrně s `approve_subject_request`,
  -- které `type='club'` kontroluje taky. Dnes nedosažitelné (komerční subjekty
  -- nemají ani jednoho správce), ale ať se ty dvě cesty nerozejdou.
  IF NOT EXISTS (SELECT 1 FROM public.subjects
                  WHERE id = _subject AND type = 'club' AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Správce se jmenuje jen v klubu.';
  END IF;

  -- UZAVŘENÝ ÚČET SE TÍMHLE NEOTEVÍRÁ — táž věta jako v `approve_subject_request`.
  -- Bez ní by se dal zavřený účet povýšit na správce klubu a získal by tím
  -- práva, která mu správce haly vzal.
  IF EXISTS (SELECT 1 FROM public.profiles p
              WHERE p.user_id = _user AND p.stav IN ('deaktivovan', 'zamitnut')) THEN
    RAISE EXCEPTION 'Účet je uzavřený — správcem klubu ho udělat nejde.'
      USING HINT = 'Nejdřív ho musí obnovit správce haly.';
  END IF;

  -- Povyšuje se JEN ze `member`. Kdo správcem už je, není co měnit; a `WHERE`
  -- na `level` zároveň znamená, že tahle funkce nikoho degradovat neumí ani
  -- omylem.
  UPDATE public.subject_reps
     SET level = 'rep'
   WHERE subject_id = _subject AND user_id = _user AND level = 'member';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tenhle člověk není členem klubu, ve kterém ho chceš jmenovat správcem.'
      USING HINT = 'Nejdřív ho přijmi jako člena — nebo už správce je.';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.jmenuj_spravce_klubu(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jmenuj_spravce_klubu(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Sebekontrola
-- ---------------------------------------------------------------------------
DO $kontrola$
DECLARE _asr text; _jsk text;
BEGIN
  SELECT prosrc INTO _asr FROM pg_proc
   WHERE oid = 'public.approve_subject_request(uuid,subject_rep_level)'::regprocedure;
  SELECT prosrc INTO _jsk FROM pg_proc
   WHERE oid = 'public.jmenuj_spravce_klubu(uuid,uuid)'::regprocedure;

  -- Stará brána musí být pryč, jinak se změna nepropsala.
  IF position('Zástupce klubu smí jmenovat jen správce haly.' in _asr) > 0 THEN
    RAISE EXCEPTION 'V approve_subject_request zůstala stará brána — změna se nepropsala.';
  END IF;
  -- A nová tam musí být i s podmínkou na VLASTNÍ klub. Kdyby zbylo jen
  -- `_level = ''rep''` bez `is_subject_rep`, jmenoval by správce kdokoli.
  -- Kotví se na CELOU podmínku nové brány, ne jen na `is_subject_rep(_z.subject_id)`:
  -- ten řetězec je v těle DVAKRÁT (podruhé v R5), takže by kontrola prošla
  -- i tehdy, kdyby z nové brány zmizel. Nález migrační brány, ověřený.
  IF position('IF _level = ''rep'' AND NOT (has_role(_uid, ''admin'')' in _asr) = 0 THEN
    RAISE EXCEPTION 'Nová brána nehlídá vlastní klub — správce by šel jmenovat i cizímu.';
  END IF;

  -- R5 musí zůstat: je to vrstva, na které „jen svůj klub" doopravdy stojí.
  IF position('Do tohohle klubu můžeš přiřazovat jen jako jeho zástupce nebo správce haly.' in _asr) = 0 THEN
    RAISE EXCEPTION 'Zmizela brána R5 — zástupce by přiřazoval do cizích klubů.';
  END IF;
  -- A ochrana uzavřeného účtu taky.
  IF position('Účet žadatele je uzavřený' in _asr) = 0 THEN
    RAISE EXCEPTION 'Zmizela ochrana uzavřeného účtu v approve_subject_request.';
  END IF;

  IF position('THEN ''rep''::public.subject_rep_level' in _asr) = 0 THEN
    RAISE EXCEPTION 'Zmizela ochrana proti degradaci — schválením by šlo sundat správce.';
  END IF;

  IF position('is_subject_rep(_subject)' in _jsk) = 0 THEN
    RAISE EXCEPTION 'jmenuj_spravce_klubu nehlídá vlastní klub.';
  END IF;
  IF position('type = ''club''' in _jsk) = 0 THEN
    RAISE EXCEPTION 'jmenuj_spravce_klubu nekontroluje, že jde o klub.';
  END IF;
  IF position('level = ''member''' in _jsk) = 0 THEN
    RAISE EXCEPTION 'jmenuj_spravce_klubu nefiltruje na member — uměla by i degradovat.';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc
           WHERE oid='public.jmenuj_spravce_klubu(uuid,uuid)'::regprocedure) THEN
    RAISE EXCEPTION 'jmenuj_spravce_klubu není SECURITY DEFINER — RLS jí zápis nepustí.';
  END IF;
  IF NOT has_function_privilege('authenticated',
        'public.jmenuj_spravce_klubu(uuid,uuid)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated nemá EXECUTE — frontend jmenování nezavolá.';
  END IF;

  RAISE NOTICE 'Správce klubu jmenuje správce ve svém klubu; cizí kluby a peníze zůstávají mimo.';
END $kontrola$;
