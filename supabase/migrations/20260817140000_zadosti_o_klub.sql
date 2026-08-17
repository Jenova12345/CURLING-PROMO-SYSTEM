-- =============================================================================
-- Přiřazení ke klubu při registraci — žádost, ne automatické členství
-- =============================================================================
-- Při registraci si člověk vybere svůj klub. NEVZNIKNE tím členství, ale ŽÁDOST,
-- kterou musí admin schválit a přitom přidělit úroveň (člen / zástupce).
--
-- PROČ ŽÁDOST A NE ROVNOU ČLENSTVÍ: členství v klubu je oprávnění, ne údaj
-- o uživateli. Člen klubu vidí rezervace celého klubu a smí za něj rezervovat;
-- zástupce navíc potvrzuje rezervace ostatních. Kdyby si to člověk nastavil sám
-- výběrem z rozbalovátka, stačilo by se zaregistrovat a vybrat cizí klub.
--
-- ZÁSTUPCE NASTAVUJE VÝHRADNĚ ADMIN (rozhodnutí PM). Ve formuláři žádosti se
-- úroveň nezadává vůbec — žadatel o ní nerozhoduje ani jako o přání.
--
-- CO SE TÍM NEMĚNÍ: aplikační role (`user_roles`) zůstává `hobby_player`.
-- Práva k rezervacím nestojí na ní, ale na `subject_reps` — viz `is_subject_member`
-- a `is_subject_rep` v `20260716140000_etapa1_rls.sql`.
--
-- VRATNOST:
--   DROP VIEW IF EXISTS public.subject_requests_list;
--   DROP VIEW IF EXISTS public.clubs_public;
--   DROP FUNCTION IF EXISTS public.request_subject_membership(uuid, text);
--   DROP FUNCTION IF EXISTS public.approve_subject_request(uuid, public.subject_rep_level);
--   DROP FUNCTION IF EXISTS public.reject_subject_request(uuid, text);
--   DROP TABLE IF EXISTS public.subject_requests;
--   DROP TYPE IF EXISTS public.subject_request_status;
--   -- a `handle_new_user` zpět do znění z 20260715000000_baseline_production.sql
--   -- POZOR: revert ZTRATÍ nevyřízené žádosti.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Stav žádosti
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subject_request_status'
                  AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.subject_request_status AS ENUM ('ceka', 'schvalena', 'zamitnuta');
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2) Tabulka žádostí
--
-- Zamítnuté a schválené se NEMAŽOU: „kdo koho pustil do klubu" je přesně ten
-- druh věci, na kterou se za půl roku někdo ptá (zásada auditovatelnosti).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.subject_requests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES public.profiles(user_id) ON DELETE CASCADE,
  subject_id  uuid NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  status      public.subject_request_status NOT NULL DEFAULT 'ceka',

  -- Co k tomu žadatel napsal (nepovinné). Úroveň členství tu schválně NENÍ —
  -- o zástupci rozhoduje admin, ne přání v textovém poli.
  poznamka    text,

  created_at  timestamptz NOT NULL DEFAULT now(),
  decided_at  timestamptz,
  decided_by  uuid REFERENCES public.profiles(user_id),
  decision_reason text,

  -- Rozhodnutá žádost musí mít razítko, čekající ho mít nesmí.
  CONSTRAINT subject_requests_rozhodnuti CHECK (
    (status = 'ceka'  AND decided_at IS NULL AND decided_by IS NULL)
    OR (status <> 'ceka' AND decided_at IS NOT NULL)
  ),
  CONSTRAINT subject_requests_poznamka_delka CHECK (poznamka IS NULL OR length(poznamka) <= 500)
);

-- Jedna čekající žádost na člověka. Bez toho by šlo frontu zahltit opakovaným
-- odesíláním a admin by pak vybíral z deseti stejných řádků.
CREATE UNIQUE INDEX IF NOT EXISTS idx_subject_requests_jedna_cekajici
  ON public.subject_requests (user_id) WHERE status = 'ceka';

CREATE INDEX IF NOT EXISTS idx_subject_requests_fronta
  ON public.subject_requests (created_at) WHERE status = 'ceka';

DROP TRIGGER IF EXISTS trg_subject_requests_audit ON public.subject_requests;
CREATE TRIGGER trg_subject_requests_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.subject_requests
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- -----------------------------------------------------------------------------
-- 3) RLS — číst smí žadatel svoje, admin všechno; zapisovat nikdo přímo
--
-- Zápis jde výhradně přes RPC (týž vzor jako u faktur, rozhodnutí R8): kdyby
-- existovala INSERT politika, mohl by si žadatel založit žádost s cizím
-- `user_id` nebo rovnou se stavem `schvalena`.
-- -----------------------------------------------------------------------------
ALTER TABLE public.subject_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.subject_requests FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.subject_requests TO authenticated;

DROP POLICY IF EXISTS subject_requests_select ON public.subject_requests;
CREATE POLICY subject_requests_select ON public.subject_requests
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR has_role(auth.uid(), 'admin'));

-- -----------------------------------------------------------------------------
-- 4) Seznam klubů pro registrační formulář
--
-- Registrace je VEŘEJNÁ stránka, takže rozbalovátko s kluby musí přečíst i
-- nepřihlášený návštěvník. `subjects` je přitom admin-only (a správně: jsou tam
-- IČO, adresy a sazby). Pohled proto vydává JEN `id` a `název`, a jen u klubů —
-- ne u komerčních zákazníků, kteří se neregistrují.
--
-- Je to vědomé zveřejnění názvů klubů. Považuju to za přijatelné (jsou to
-- sportovní oddíly, ne citlivý údaj) a bez toho by se klub při registraci vybrat
-- nedal — ale je to rozhodnutí, ne technikálie, tak ať je vidět.
-- -----------------------------------------------------------------------------
-- `CREATE OR REPLACE`, ne DROP + CREATE: `subject_requests_list` níž na tomhle
-- pohledu stojí, takže DROP by při opakovaném spuštění migrace narazil na
-- závislost (a s CASCADE by mi pod rukama zmizel pohled, který se teprve o kus
-- dál vytváří). Replace závislost respektuje.
CREATE OR REPLACE VIEW public.clubs_public
  WITH (security_invoker = off) AS
  SELECT s.id, s.name
    FROM public.subjects s
   WHERE s.type = 'club' AND s.deleted_at IS NULL;

REVOKE ALL ON public.clubs_public FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.clubs_public TO anon, authenticated;

COMMENT ON VIEW public.clubs_public IS
  'Názvy klubů pro rozbalovátko v registraci. Vědomě čitelné i nepřihlášeným — bez toho by si klub nešlo vybrat. Vydává JEN id a název, nikdy IČO, adresu ani sazby.';

-- -----------------------------------------------------------------------------
-- 5) Podání žádosti
--
-- Volá se ze dvou míst: z triggeru při registraci (klub vybraný ve formuláři)
-- a z aplikace, když si ho člověk doplní až potom.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_subject_membership(_subject_id uuid, _poznamka text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _id  uuid;
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Pro podání žádosti se musíte přihlásit.';
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
END;
$$;

REVOKE ALL ON FUNCTION public.request_subject_membership(uuid, text) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.request_subject_membership(uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 6) Schválení a zamítnutí — jen admin
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_subject_request(
  _request_id uuid,
  _level public.subject_rep_level DEFAULT 'member'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _uid uuid := auth.uid(); _z record;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Žádosti o členství vyřizuje jen správce haly.';
  END IF;

  -- Zámek řádku: dvě souběžná kliknutí by jinak vyrobila dvě členství.
  SELECT * INTO _z FROM public.subject_requests WHERE id = _request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Žádost neexistuje.';
  END IF;
  IF _z.status <> 'ceka' THEN
    RAISE EXCEPTION 'Tahle žádost už je vyřízená (%).', _z.status;
  END IF;

  -- Klub se kontroluje ZNOVU, i když se ověřoval při podání žádosti. Mezi
  -- podáním a schválením leží libovolně dlouhá doba a klub se mezitím může
  -- smazat; bez téhle kontroly vzniklo členství ve smazaném klubu, které nikde
  -- není vidět (`subjects` skryté kluby nepouští), ale opravňuje. Frontu to
  -- neblokuje — admin takovou žádost prostě zamítne.
  IF NOT EXISTS (SELECT 1 FROM public.subjects
                  WHERE id = _z.subject_id AND type = 'club' AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Klub už neexistuje, takže do něj nejde nikoho přiřadit.'
      USING HINT = 'Žádost zamítni — případně klub nejdřív obnov.';
  END IF;

  -- Členství. `ON CONFLICT` kvůli případu, kdy admin mezitím přiřadil ručně —
  -- žádost se pak jen uzavře a úroveň se srovná na to, co teď zvolil.
  INSERT INTO public.subject_reps (subject_id, user_id, level, created_by)
  VALUES (_z.subject_id, _z.user_id, _level, _uid)
  ON CONFLICT (subject_id, user_id) DO UPDATE SET level = EXCLUDED.level;

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
$$;

REVOKE ALL ON FUNCTION public.approve_subject_request(uuid, public.subject_rep_level) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.approve_subject_request(uuid, public.subject_rep_level) TO authenticated;

CREATE OR REPLACE FUNCTION public.reject_subject_request(_request_id uuid, _duvod text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _uid uuid := auth.uid(); _stav public.subject_request_status;
BEGIN
  IF NOT has_role(_uid, 'admin') THEN
    RAISE EXCEPTION 'Žádosti o členství vyřizuje jen správce haly.';
  END IF;

  SELECT status INTO _stav FROM public.subject_requests WHERE id = _request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Žádost neexistuje.';
  END IF;
  IF _stav <> 'ceka' THEN
    RAISE EXCEPTION 'Tahle žádost už je vyřízená (%).', _stav;
  END IF;

  UPDATE public.subject_requests
     SET status = 'zamitnuta', decided_at = now(), decided_by = _uid,
         decision_reason = nullif(btrim(coalesce(_duvod, '')), '')
   WHERE id = _request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_subject_request(uuid, text) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.reject_subject_request(uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7) Fronta pro admina
--
-- `security_invoker = on`: platí RLS volajícího, takže žadatel uvidí jen svoje
-- řádky a admin všechny. S `off` by frontu se jmény přečetl každý přihlášený.
--
-- Obě spojení jsou LEVÁ, a to je nosné, ne kosmetika. Při `security_invoker = on`
-- se RLS uplatní i na připojované tabulky, takže VNITŘNÍ spojení řádek nejen
-- ochudí o jméno — celý ho ZAHODÍ. Konkrétně `subjects` pouští jen adminovi a
-- členům klubu; žadatel s čekající žádostí členem z definice ještě není, takže
-- by v pohledu neviděl ani vlastní žádost. Klub se proto bere z `clubs_public`
-- (definer, jen id + název, stejně čitelný pro nepřihlášené) a chybějící název
-- se pojmenuje, místo aby řádek zmizel.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.subject_requests_list;
CREATE VIEW public.subject_requests_list WITH (security_invoker = on) AS
  SELECT z.id,
         z.user_id,
         COALESCE(p.full_name, '(neznámý uživatel)') AS zadatel,
         z.subject_id,
         COALESCE(s.name, '(klub už neexistuje)')    AS klub,
         z.status,
         z.poznamka,
         z.created_at,
         z.decided_at,
         z.decision_reason,
         -- Úroveň, kterou žadatel dostal (u vyřízených). Bere se z členství,
         -- ne z žádosti — žádost o úrovni nikdy nerozhoduje.
         (SELECT sr.level FROM public.subject_reps sr
           WHERE sr.user_id = z.user_id AND sr.subject_id = z.subject_id) AS uroven
    FROM public.subject_requests z
    LEFT JOIN public.profiles     p ON p.user_id = z.user_id
    LEFT JOIN public.clubs_public s ON s.id      = z.subject_id;

REVOKE ALL ON public.subject_requests_list FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.subject_requests_list TO authenticated;

-- -----------------------------------------------------------------------------
-- 8) Registrace: vybraný klub se promění v žádost
--
-- Tělo je vygenerované z `pg_get_functiondef` živého schématu (pravidlo 7);
-- vložený je do něj jen nový blok.
--
-- DVĚ VĚCI, KTERÉ TU JSOU SCHVÁLNĚ:
--
-- 1) `subject_id` z metadat je hodnota od NEPŘIHLÁŠENÉHO uživatele — může tam
--    napsat co chce. Nevadí to, protože vznikne jen ŽÁDOST, kterou musí admin
--    schválit; přesto se ověřuje, že jde o existující, nesmazaný klub.
-- 2) Nevalidní hodnota registraci NESMÍ shodit. Kdo se překlepne v id klubu,
--    má dostat účet bez žádosti, ne hlášku „registrace selhala".
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _klub uuid;
BEGIN
  -- Vytvoř profil
  INSERT INTO public.profiles (user_id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data ->> 'full_name');

  -- Přiřaď výchozí roli hobby_player
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'hobby_player');

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
$$;

-- -----------------------------------------------------------------------------
-- 9) Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _politiky text;
BEGIN
  SELECT string_agg(DISTINCT cmd, ', ') INTO _politiky
    FROM pg_policies WHERE schemaname = 'public' AND tablename = 'subject_requests';
  IF _politiky IS DISTINCT FROM 'SELECT' THEN
    RAISE EXCEPTION 'Žádosti mají jinou politiku než SELECT (%) — zápis musí jít přes RPC.', _politiky;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname IN ('approve_subject_request', 'reject_subject_request',
                                  'request_subject_membership')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('service_role', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'RPC žádostí jsou dosažitelná pro anon nebo service_role.';
  END IF;

  -- Veřejné rozbalovátko nesmí vydat víc než jméno klubu.
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'clubs_public'
                AND column_name NOT IN ('id', 'name')) THEN
    RAISE EXCEPTION 'clubs_public vydává víc než id a název.';
  END IF;

  IF position('subject_requests' in pg_get_functiondef('public.handle_new_user()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Registrace nezakládá žádost o klub.';
  END IF;

  RAISE NOTICE 'Žádosti o klub: tabulka, RPC, fronta i registrační cesta hotové.';
END $kontrola$;
