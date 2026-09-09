-- Barevné označení klubů v kalendáři
-- ---------------------------------------------------------------------------
-- Klub dostane vlastní barvu (hex) a kalendář podle ní obarví jeho rezervace.
-- Dosud se barvilo podle TYPU akce, takže tři různé kluby na trénink vypadaly
-- úplně stejně a v týdenním pohledu nešlo poznat, kdo kde je.
--
-- Kudy se barva dostane k lidem: `subjects` má RLS
--   `admin OR (deleted_at IS NULL AND is_subject_member(id))`
-- a `authenticated` na ní nemá ani SELECT grant — běžný člen tedy o cizích
-- klubech neví nic. Barvu proto NEČTE z tabulky, ale z view
-- `reservations_calendar`, které je SECURITY DEFINER a `subject_name` už dnes
-- vydává všem. Přidáním `subject_color` se tam nezpřístupňuje nic nového:
-- kdo vidí jméno klubu u rezervace, uvidí i jeho barvu. RLS `subjects`
-- zůstává nedotčená.
--
-- Jediné nové právo je `GRANT SELECT (barva)` na jeden sloupec — kvůli
-- adminovi v Nastavení, viz odůvodnění u samotného grantu níž.
--
-- Měnit barvu smí jen admin — drží to stávající `subjects_update_admin`,
-- nic nového se pro zápis neotevírá.
--
-- JAK TO VRÁTIT ZPÁTKY (kdyby bylo potřeba):
--   Prosté `ALTER TABLE subjects DROP COLUMN barva` SELŽE — view na tom sloupci
--   závisí. A `DROP COLUMN barva CASCADE` by shodilo celé
--   `reservations_calendar` i s grantem, čímž zhasne kalendář všem. Pořadí je:
--     1) DROP VIEW public.reservations_calendar;
--     2) CREATE VIEW public.reservations_calendar WITH (security_invoker = off)
--        AS <tělo BEZ řádku `s.barva AS subject_color`>;
--     3) GRANT SELECT ON public.reservations_calendar TO authenticated;
--     4) ALTER TABLE public.subjects DROP COLUMN barva;
--   `CREATE OR REPLACE VIEW` na krok 2 nestačí — sloupec ubrat neumí.
-- ---------------------------------------------------------------------------

-- ---- 1) Sloupec -----------------------------------------------------------
-- Text s CHECKem, ne integer: hex se ukládá v té podobě, v jaké ho pošle
-- prohlížeč (`<input type="color">` vrací vždy `#rrggbb` malými písmeny),
-- a v DB je čitelný na první pohled. CHECK pouští i velká písmena, ať ruční
-- zápis přes SQL neselže na kosmetice.
ALTER TABLE public.subjects
  ADD COLUMN IF NOT EXISTS barva text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.subjects'::regclass AND conname = 'subjects_barva_hex'
  ) THEN
    ALTER TABLE public.subjects
      ADD CONSTRAINT subjects_barva_hex CHECK (barva IS NULL OR barva ~ '^#[0-9a-fA-F]{6}$');
  END IF;
END $$;

-- `subjects` má práva po SLOUPCÍCH, ne na celou tabulku: `authenticated` má
-- SELECT na name/ico/adresu, ale NE na `default_rate` (sazby vidí jen admin,
-- migrace 20260812140000_cenik_jen_adminovi). Nový sloupec zdědí jen to, co má
-- tabulka jako celek — a to je tady INSERT+UPDATE bez SELECTu.
--
-- Bez tohohle grantu by `barva` byla zapisovatelná, ale nečitelná: admin by ji
-- v Nastavení → Subjekty nepřečetl a stránka by spadla na 42501. Změřeno
-- reálným tokenem 9. 9. 2026 — jako `postgres` se tahle díra nepozná.
--
-- Bezpečnostně to nic neotvírá: barvu už tak vidí každý přihlášený přes
-- `reservations_calendar`, a RLS `subjects` pořád pouští jen vlastní kluby.
GRANT SELECT (barva) ON public.subjects TO authenticated;

COMMENT ON COLUMN public.subjects.barva IS
  'Barva subjektu v kalendáři, hex #rrggbb. NULL = neutrální výchozí barva. '
  'Nastavuje admin v Nastavení → Subjekty. Čte se přes reservations_calendar.subject_color, '
  'ne přímo z téhle tabulky (RLS ji běžnému členovi u cizích klubů nevydá).';

-- ---- 2) Výchozí barvy existujícím klubům ----------------------------------
-- Paleta: středně syté tóny, ze kterých kalendář míchá světlý podklad
-- (18 % barvy na bílé), takže na nich zůstane čitelný tmavý text bez ohledu
-- na to, kterou barvu klub dostane. Vyhýbá se dvojici červená+zelená,
-- aby se daly rozlišit i při nejběžnější barvosleposti.
--
-- Přiřazuje se podle abecedy, ne podle konkrétních UUID: migrace musí projít
-- stejně na produkci i na čisté lokální databázi, kde ta tři UUID neexistují.
-- Bere jen kluby BEZ barvy, takže opakované spuštění nikomu barvu nepřepíše.
WITH paleta(poradi, hex) AS (
  VALUES (1, '#2563eb'),   -- modrá
         (2, '#7c3aed'),   -- fialová
         (3, '#059669'),   -- zelená
         (4, '#d97706'),   -- jantarová
         (5, '#db2777'),   -- růžová
         (6, '#0891b2')    -- tyrkysová
), kluby AS (
  SELECT id, row_number() OVER (ORDER BY name) AS poradi
    FROM public.subjects
   WHERE type = 'club' AND deleted_at IS NULL AND barva IS NULL
)
UPDATE public.subjects s
   SET barva = p.hex
  FROM kluby k
  JOIN paleta p ON p.poradi = ((k.poradi - 1) % 6) + 1
 WHERE s.id = k.id;

-- ---- 2b) Nový klub dostane barvu sám ---------------------------------------
-- Backfill výš obarví jen kluby, které existují v den nasazení. Bez tohohle
-- triggeru by každý klub založený POTOM byl v kalendáři šedý a spadl by do
-- legendy pod „Ostatní" — tedy přesně to, čemu se celá funkce snaží zabránit.
--
-- Proč trigger a ne default ve formuláři: platí i pro kluby založené mimo UI
-- (import, ruční SQL, budoucí RPC), a admin ho může kdykoli přebít vlastní
-- volbou. Bere první barvu z palety, kterou zatím nikdo nemá — a když jsou
-- všechny rozebrané, nechá NULL (neutrální) místo toho, aby vyrobil dvojici
-- k nerozeznání.
CREATE OR REPLACE FUNCTION public.barva_pro_novy_klub()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $barva$
BEGIN
  IF NEW.type <> 'club' OR NEW.barva IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT p.hex INTO NEW.barva
    FROM (VALUES ('#2563eb'), ('#7c3aed'), ('#059669'),
                 ('#d97706'), ('#db2777'), ('#0891b2'),
                 ('#4f46e5'), ('#b45309')) AS p(hex)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.subjects s
      WHERE s.type = 'club' AND s.deleted_at IS NULL AND s.barva = p.hex
   )
   LIMIT 1;

  RETURN NEW;   -- když je paleta vyčerpaná, zůstane NULL = neutrální
END;
$barva$;

COMMENT ON FUNCTION public.barva_pro_novy_klub() IS
  'Novému klubu přidělí první volnou barvu z palety, aby nebyl v kalendáři šedý. '
  'Admin ji může přepsat; při vyčerpané paletě nechá NULL místo duplicity.';

DROP TRIGGER IF EXISTS trg_subjects_barva ON public.subjects;
CREATE TRIGGER trg_subjects_barva
  BEFORE INSERT ON public.subjects
  FOR EACH ROW EXECUTE FUNCTION public.barva_pro_novy_klub();

-- ---- 3) Barva do kalendářového view ---------------------------------------
-- Tělo view je VYGENEROVANÉ z `pg_get_functiondef`-obdoby pro view
-- (`pg_get_viewdef` živého schématu, 9. 9. 2026) a vložen do něj je jediný
-- řádek `s.barva AS subject_color`. Ověřeno diffem: proti původní definici
-- se liší přesně o ten jeden sloupec, nic jiného nezmizelo.
--
-- Nový sloupec musí být POSLEDNÍ: `CREATE OR REPLACE VIEW` umí sloupce jen
-- přidávat na konec, přejmenovat ani přeskládat existující nedovolí.
-- `WITH (security_invoker = off)` tu NENÍ dekorace: `CREATE OR REPLACE VIEW`
-- bez WITH klauzule celý seznam reloptions ZAHODÍ, nemerguje ho. View je
-- SECURITY DEFINER schválně — na tom stojí to, že člen vidí jméno a barvu
-- cizího klubu, přestože mu RLS `subjects` cizí řádek nevydá. Kdyby se sem
-- omylem dostalo `security_invoker = on`, kalendář by zčásti oslepl.
-- (Dnes je `off` shodou okolností i výchozí hodnota Postgresu, takže by to
-- prošlo i bez toho — ale spoléhat se na default u bezpečnostního přepínače
-- je přesně ten druh tichého předpokladu, který tady nechceme.)
CREATE OR REPLACE VIEW public.reservations_calendar
  WITH (security_invoker = off) AS
 SELECT r.id,
    r.sheet_id,
    r.subject_id,
    r.event_id,
    r.series_id,
    r.start_at,
    r.end_at,
    r.status,
    s.name AS subject_name,
    s.type AS subject_type,
    e.title AS event_title,
    COALESCE(e.event_type,
        CASE
            WHEN s.type = 'commercial'::subject_type THEN 'commercial'::event_type
            ELSE 'training'::event_type
        END) AS event_type,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND s2.deleted_at IS NULL)) THEN r.note
            ELSE NULL::text
        END AS note,
    r.approved_at,
    r.created_by,
    cp.full_name AS created_by_name,
    r.created_at,
    r.cancelled_at,
    r.cancelled_by,
    xp.full_name AS cancelled_by_name,
    r.cancel_reason,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.hours
            ELSE NULL::numeric
        END AS hours,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.rate_per_hour
            ELSE NULL::numeric
        END AS rate_per_hour,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.amount
            ELSE NULL::numeric
        END AS amount,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.corrected_hours
            ELSE NULL::numeric
        END AS corrected_hours,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid() THEN r.corrected_amount
            ELSE NULL::numeric
        END AS corrected_amount,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR r.created_by = auth.uid(), false) AS can_see_amount,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid() AND (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND s2.deleted_at IS NULL)), false) AS can_manage,
    COALESCE(( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
           FROM subject_reps sr
             JOIN subjects s2 ON s2.id = sr.subject_id
          WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)), false) AS can_approve,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid() THEN r.preferovany_trener
            ELSE NULL::uuid
        END AS preferovany_trener,
        CASE
            WHEN ( SELECT has_role(auth.uid(), 'admin'::app_role) AS has_role) OR (r.subject_id IN ( SELECT sr.subject_id
               FROM subject_reps sr
                 JOIN subjects s2 ON s2.id = sr.subject_id
              WHERE sr.user_id = auth.uid() AND sr.level = 'rep'::subject_rep_level AND s2.deleted_at IS NULL)) OR r.created_by = auth.uid() THEN tp.full_name
            ELSE NULL::text
        END AS preferovany_trener_jmeno,
    s.barva AS subject_color
   FROM reservations r
     LEFT JOIN subjects s ON s.id = r.subject_id
     LEFT JOIN events e ON e.id = r.event_id
     LEFT JOIN profiles cp ON cp.user_id = r.created_by
     LEFT JOIN profiles xp ON xp.user_id = r.cancelled_by
     LEFT JOIN profiles tp ON tp.user_id = r.preferovany_trener
  WHERE r.deleted_at IS NULL AND ucet_aktivni();


-- ---- 4) Vlastní kontrola --------------------------------------------------
-- Měří KONKRÉTNÍ hodnoty, ne „něco tam je". Když se kterákoli rozejde,
-- migrace spadne a nenasadí se nic.
--
-- Testy zápisu běží uvnitř plpgsql bloku s EXCEPTION, což je implicitní
-- savepoint: ať dopadnou jakkoli, zapsaná data se vrátí. Kontrola tedy
-- NEZANECHÁ v `subjects` ani v audit logu jedinou změnu — jinak by si
-- migrace sama přebarvila cizí klub a zamíchala `updated_at`.
DO $$
DECLARE
  _pocet_klubu int;
  _bez_barvy   int;
  _spatny_hex  int;
  _grant_ok    boolean;
  _politik     int;
  _masek       int;
  _neadmin     uuid;
  _zmeneno     int;
  _kolizi      int;
  _hlidac_pustil boolean;
BEGIN
  -- (a) každý živý klub má barvu a je to platný hex
  SELECT count(*) INTO _pocet_klubu FROM public.subjects WHERE type='club' AND deleted_at IS NULL;
  SELECT count(*) INTO _bez_barvy   FROM public.subjects WHERE type='club' AND deleted_at IS NULL AND barva IS NULL;
  IF _bez_barvy > 0 THEN
    RAISE EXCEPTION 'Backfill nedojel: % z % živých klubů zůstalo bez barvy.', _bez_barvy, _pocet_klubu;
  END IF;
  -- Počet klubů se ZÁMĚRNĚ netvrdí. Čistá databáze (lokální `db reset`, nový
  -- projekt) žádné kluby nemá a tvrzení „aspoň jeden musí být" by ji rozbilo —
  -- migrace musí projít na produkci i na prázdnu. Na prázdné DB projde
  -- kontrola (a) triviálně; na produkci má co měřit.

  SELECT count(*) INTO _spatny_hex
    FROM public.subjects WHERE barva IS NOT NULL AND barva !~ '^#[0-9a-fA-F]{6}$';
  IF _spatny_hex > 0 THEN
    RAISE EXCEPTION 'V subjects je % barev, které nejsou hex #rrggbb.', _spatny_hex;
  END IF;

  -- Jádro celé funkce: dva kluby nesmí mít stejnou barvu, jinak je v legendě
  -- dvakrát táž tečka a v týdnu se nepozná, kdo kde je. Backfill točí paletu
  -- `% 6`, takže od sedmého klubu by kolize vznikla sama — a `row_number()`
  -- počítá jen přes NEBAREVNÉ řádky, takže při druhém běhu (přidaný klub,
  -- obnova ze zálohy) začne pořadí znovu od 1 a sáhne po první barvě.
  SELECT count(*) INTO _kolizi FROM (
    SELECT barva FROM public.subjects
     WHERE type='club' AND deleted_at IS NULL AND barva IS NOT NULL
     GROUP BY barva HAVING count(*) > 1
  ) q;
  IF _kolizi > 0 THEN
    RAISE EXCEPTION 'Barvu má % klubů společnou s jiným klubem — v kalendáři půjdou k nerozeznání.', _kolizi;
  END IF;

  -- (b) CHECK drží: nesmysl musí odmítnout, platný hex musí pustit.
  --     Testuje se na VLASTNÍM zkušebním řádku, ne na cizím subjektu —
  --     `UPDATE ... WHERE id = NULL` na prázdné databázi neovlivní nic,
  --     nevyhodí chybu, a test by pak hlásil díru tam, kde žádná není.
  --     Oba INSERTy končí vrácením (výjimka = návrat k savepointu), takže
  --     zkušební subjekt nikdy nepřežije do dat ani do audit logu.
  _hlidac_pustil := true;
  BEGIN
    INSERT INTO public.subjects (type, name, barva) VALUES ('club', '__zkouska_barvy__', 'zelena');
    RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZB001';   -- CHECK nezabral
  EXCEPTION
    WHEN check_violation      THEN _hlidac_pustil := false;   -- CHECK zabral, INSERT se vrátil
    WHEN SQLSTATE 'ZB001'     THEN NULL;                      -- prošlo → _hlidac_pustil zůstává true
  END;
  IF _hlidac_pustil THEN
    RAISE EXCEPTION 'CHECK subjects_barva_hex nedrží: prošla hodnota "zelena".';
  END IF;

  _hlidac_pustil := false;
  BEGIN
    INSERT INTO public.subjects (type, name, barva) VALUES ('club', '__zkouska_barvy__', '#ABCDEF');
    _hlidac_pustil := true;
    RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZB001';
  EXCEPTION
    WHEN check_violation  THEN _hlidac_pustil := false;
    WHEN SQLSTATE 'ZB001' THEN NULL;
  END;
  IF NOT _hlidac_pustil THEN
    RAISE EXCEPTION 'CHECK subjects_barva_hex je moc přísný: odmítl i platný hex #ABCDEF.';
  END IF;

  -- (c) View: barvu vydává, ceny maskuje, RLS obchází.
  --
  --     `subject_color` a `can_see_amount` se ZÁMĚRNĚ netestují přítomností
  --     sloupce: `CREATE OR REPLACE VIEW` sloupec ubrat neumí („cannot drop
  --     columns from view"), takže takový IF nemůže nikdy zčervenat a jen
  --     předstírá pokrytí. Reálné riziko u 85 řádků ručně přeneseného těla je
  --     jiné — že se maskovací větev změní z `ELSE NULL` na `ELSE r.amount`.
  --     Jména sloupců to nepozná, počet maskovacích větví ano.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema='public' AND table_name='reservations_calendar' AND column_name='subject_color'
  ) THEN
    RAISE EXCEPTION 'reservations_calendar nemá sloupec subject_color.';
  END IF;
  IF pg_get_viewdef('public.reservations_calendar'::regclass, true) NOT LIKE '%s.barva AS subject_color%' THEN
    RAISE EXCEPTION 'subject_color ve view nevede na subjects.barva.';
  END IF;

  --     Osm maskovaných sloupců: note, hours, rate_per_hour, amount,
  --     corrected_hours, corrected_amount, preferovany_trener,
  --     preferovany_trener_jmeno. Když někdo maskování oslabí, číslo klesne.
  --     Legitimní změna počtu je možná — pak se tohle číslo přepíše VĚDOMĚ.
  SELECT count(*) INTO _masek FROM regexp_matches(
    pg_get_viewdef('public.reservations_calendar'::regclass, true), 'ELSE NULL::', 'g');
  IF _masek <> 8 THEN
    RAISE EXCEPTION 'Ve view je % maskovacích větví místo 8 — ceny nebo jména se přestaly skrývat.', _masek;
  END IF;

  --     A pojistka na to, na čem stojí viditelnost cizích klubů: view musí
  --     zůstat SECURITY DEFINER. `CREATE OR REPLACE VIEW` reloptions přepisuje
  --     celé, takže `security_invoker=on` sem může vklouznout jedním slovem.
  IF EXISTS (
    SELECT 1 FROM pg_class
     WHERE oid = 'public.reservations_calendar'::regclass
       AND reloptions @> ARRAY['security_invoker=on']
  ) THEN
    RAISE EXCEPTION 'reservations_calendar má security_invoker=on — kalendář přestane vydávat cizí kluby.';
  END IF;

  -- (d) `CREATE OR REPLACE VIEW` nesmělo shodit grant, jinak kalendář oslepne.
  --     Pozor na dosah: Supabase má na `public` ALTER DEFAULT PRIVILEGES pro
  --     `authenticated`, takže view smazané a založené znovu grant dostane samo
  --     a tenhle test u toho scénáře nezčervená. Chytá výslovné REVOKE
  --     (ověřeno mutací 9. 9. 2026), ne každou možnou cestu ke ztrátě práva.
  SELECT has_table_privilege('authenticated', 'public.reservations_calendar', 'SELECT') INTO _grant_ok;
  IF NOT _grant_ok THEN
    RAISE EXCEPTION 'authenticated přišel o SELECT na reservations_calendar.';
  END IF;

  -- (e) RLS na subjects se hnout nesměla — pořád tři politiky
  SELECT count(*) INTO _politik FROM pg_policy WHERE polrelid = 'public.subjects'::regclass;
  IF _politik <> 3 THEN
    RAISE EXCEPTION 'Na subjects je % politik místo očekávaných 3 — RLS se posunula.', _politik;
  END IF;

  -- (f) Barvu smí měnit JEN admin — a měří se to CHOVÁNÍM, ne tvarem politiky.
  --
  --     Dřív tu stál filtr `polcmd='w'` na politiky bez `has_role`. Ten
  --     přehlédne politiku `FOR ALL` (polcmd='*'), která UPDATE povoluje taky:
  --     `DROP POLICY subjects_update_admin; CREATE POLICY … FOR ALL USING (true)`
  --     projde i kontrolou (e), protože počet politik zůstane 3. Našly to obě
  --     databázové brány nezávisle na sobě 9. 9. 2026.
  --
  --     Test proto sáhne na data pod ROLÍ BĚŽNÉHO ČLENA a čeká, že nezmění nic.
  --     Jako `postgres` projde všechno (obchází granty i RLS) — proto ROLE.
  --     Běží v savepointu, takže po sobě nenechá stopu ať dopadne jakkoli.
  SELECT sr.user_id INTO _neadmin
    FROM public.subject_reps sr
   WHERE NOT public.has_role(sr.user_id, 'admin')
   ORDER BY sr.user_id
   LIMIT 1;

  IF _neadmin IS NULL THEN
    -- Na čisté databázi není koho vyzkoušet; zbývá aspoň tvar politik.
    IF EXISTS (
      SELECT 1 FROM pg_policy
       WHERE polrelid='public.subjects'::regclass AND polcmd IN ('w','*')
         AND (COALESCE(pg_get_expr(polwithcheck, polrelid), '') NOT LIKE '%has_role%'
           OR COALESCE(pg_get_expr(polqual, polrelid), '')      NOT LIKE '%has_role%')
    ) THEN
      RAISE EXCEPTION 'Na subjects je zapisovací politika, která nevyžaduje admina.';
    END IF;
  ELSE
    BEGIN
      SET LOCAL ROLE authenticated;
      PERFORM set_config('request.jwt.claims',
        json_build_object('sub', _neadmin, 'role', 'authenticated')::text, true);

      UPDATE public.subjects SET barva = '#ABCDEF' WHERE type = 'club';
      GET DIAGNOSTICS _zmeneno = ROW_COUNT;

      RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZB001';
    EXCEPTION
      WHEN SQLSTATE 'ZB001'  THEN NULL;
      WHEN insufficient_privilege THEN _zmeneno := 0;   -- práva to zastavila dřív
    END;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', NULL, true);

    IF _zmeneno > 0 THEN
      RAISE EXCEPTION 'Neadmin přebarvil % klubů — zápis barvy není chráněný.', _zmeneno;
    END IF;
  END IF;

  -- (g) Práva na sloupce sedí: barvu musí jít PŘEČÍST (jinak admin UI spadne
  --     na 42501), sazba musí zůstat neviditelná (peníze), a celá tabulka
  --     nesmí být otevřená plošným SELECTem.
  IF NOT has_column_privilege('authenticated', 'public.subjects', 'barva', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated nepřečte subjects.barva — admin by v Nastavení dostal 42501.';
  END IF;
  IF has_column_privilege('authenticated', 'public.subjects', 'default_rate', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated nově vidí subjects.default_rate — sazby patří jen adminovi.';
  END IF;
  IF has_table_privilege('authenticated', 'public.subjects', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated má nově SELECT na celou subjects — práva se rozšířila.';
  END IF;
  -- `anon` (nepřihlášený) nemá na subjects mít vůbec nic — drží to
  -- `REVOKE ALL … FROM anon` z 20260812200000_security_hardening. Nový sloupcový
  -- grant míří jen na `authenticated`, ale ať si to migrace hlídá sama.
  IF has_column_privilege('anon', 'public.subjects', 'barva', 'SELECT') THEN
    RAISE EXCEPTION 'anon vidí subjects.barva — nepřihlášený nemá do subjektů co číst.';
  END IF;

  RAISE NOTICE 'Barvy klubů OK: % živých klubů má platný hex, view vydává subject_color, RLS beze změny.', _pocet_klubu;
END $$;
