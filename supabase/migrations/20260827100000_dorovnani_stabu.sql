-- =============================================================================
-- Dorovnání štábu: směny se dopočítají i při ÚPRAVĚ akce, ne jen při vzniku
-- Etapa 3, bod 4 z pořadí prací · rozhodnutí PM R8 (27. 8. 2026)
-- =============================================================================
-- CO JE ŠPATNĚ DNES:
-- `create_shifts_for_commercial_event` je `AFTER INSERT ON events`. Ověřeno
-- v `pg_trigger`. Důsledek: akce se běžně upravují, ale směny se s nimi nehnou.
--   • změna `role_reqs` na existující akci se ve směnách VŮBEC neprojeví,
--   • přidání dráhy k akci nepřidá směnu pro instruktora,
--   • ubrání dráhy nechá směnu viset.
-- Štáb se tím tiše rozejde se skutečností a přijde se na to na place.
--
-- Že to není jen teorie, je vidět v seedu: „Firemní teambuilding Demo" má
-- JEDNU dráhu a TŘI směny. Počet plyne z toho, co kdo naklikal.
--
-- -----------------------------------------------------------------------------
-- ZDROJEM PRAVDY JE `role_reqs`, NE POČET DRAH — a je potřeba vědět proč
-- -----------------------------------------------------------------------------
-- Rozhodnutí PM R8 zní: „default 1 instruktor na dráhu, ale vědomé přebití je
-- povolené — VAROVÁNÍ, ne zákaz." Kdyby přidaná dráha sama zakládala směnu,
-- nešlo by vědomé přebití vůbec zapsat: akce se dvěma dráhami a jedním
-- instruktorem by si druhou směnu pokaždé sama vyrobila zpátky.
--
-- Proto se to dělí na dvě věci:
--   • DOROVNÁNÍ SMĚN drží `shifts` v souladu s `role_reqs` — dělá to trigger.
--   • VAROVÁNÍ O DRÁHÁCH říká „akce má 2 dráhy a 1 instruktora" — dělá to
--     pohled `stab_kontrola`. Směnu z něj založí ČLOVĚK tím, že zvedne
--     `role_reqs`; automaticky kvůli dráze nikdy nevznikne ani nezmizí.
--
-- UBRÁNÍ DRÁHY ŠTÁB NIKDY NESNIŽUJE. Sebrat směnu někomu, kdo s ní počítá, je
-- horší chyba než přebytek — a přebytek je v témž pohledu vidět.
--
-- -----------------------------------------------------------------------------
-- DOROVNÁNÍ, NE PŘEMAZÁNÍ
-- -----------------------------------------------------------------------------
-- Nejjednodušší implementace („smaž všechny směny akce a založ je znovu") by
-- při každé úpravě názvu akce sebrala brigádníkům zabrané směny. Proto:
--   • chybějící směny se DOPLNÍ,
--   • přebývající se ruší jen ve stavu `open`, a to od nejnovější,
--   • `pending` / `claimed` / `completed` se NESAHÁ vůbec,
--   • co se nepodařilo dorovnat, se OHLÁSÍ (návratová hodnota + WARNING
--     + pohled `stab_kontrola`), místo aby to zůstalo tichým rozporem.
--
-- Ruší se SOFT: `status = 'cancelled'` plus razítka `cancelled_at`/`cancelled_by`.
-- Sloupce pro to v `shifts` existují od `20260731110000_booking_core.sql`
-- („SMĚNY — audit zrušení"), jen do nich dosud nikdo nepsal. DELETE by porušil
-- zásadu „nic nemazat natvrdo" z CLAUDE.md.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   DROP TRIGGER  IF EXISTS trg_events_dorovnani ON public.events;
--   DROP TRIGGER  IF EXISTS trg_shifts_audit ON public.shifts;
--   DROP VIEW     IF EXISTS public.stab_kontrola;
--   DROP FUNCTION IF EXISTS public.trg_dorovnej_stab();
--   DROP FUNCTION IF EXISTS public.dorovnej_stab(uuid, boolean);
--   ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_role_reqs_platny;
--   DROP FUNCTION IF EXISTS public.role_reqs_je_platny(jsonb);
--   -- a zpátky původní trigger z baseline:
--   CREATE TRIGGER create_shifts_for_commercial_event AFTER INSERT ON public.events
--     FOR EACH ROW EXECUTE FUNCTION public.handle_new_commercial_event();
-- `handle_new_commercial_event()` tahle migrace ZÁMĚRNĚ NEMAŽE, aby byl revert
-- jednořádkový. Je to od teď mrtvý kód, a je to tak schválně — viz kapitola 2.
--
-- Revert NEVRÁTÍ směny, které dorovnání mezitím zrušilo. Jsou ale jen zrušené,
-- ne smazané, takže se vrátit dají — jen POZOR, ať se to nepřepíše naslepo:
-- `WHERE cancelled_at IS NOT NULL` vezme i směny, které zrušil ČLOVĚK, a ty se
-- oživit nemají. Zrušení dorovnáním se pozná podle toho, že u něj sedí i rozpor
-- s rozpisem — nejbezpečnější je vybrat konkrétní `id` z `audit_log`
-- (`table_name = 'shifts'`, `new_data ->> 'status' = 'cancelled'`) a vrátit
-- jen je. Migrace sama žádnou směnu neruší (kapitola 5).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0) `events.role_reqs` konečně dostane pravidla
--
-- Dosud NEMĚLA ŽÁDNÁ. Ověřeno grepem přes všechny migrace: ani CHECK, ani
-- trigger. Nevadilo to, protože starý trigger byl INSERT-only — rozpis se četl
-- jedinkrát, při vzniku akce. Jakmile se čte i při KAŽDÉ ÚPRAVĚ, mění se to
-- v past:
--
--   • `{"instructor": "dva"}`  → `invalid input syntax for type integer`
--   • `{"instruktor": 1}`      → `invalid input value for enum app_role`
--
-- a taková akce by se stala NAVŽDY NEEDITOVATELNOU: každý UPDATE sledovaných
-- sloupců by skončil toutéž chybou. To je horší než původní vada.
--
-- Zavírá se to ze dvou stran:
--   1. CHECK, aby nová špatná data nevznikla (tady),
--   2. `dorovnej_stab` špatný klíč PŘESKOČÍ a nahlásí, místo aby spadla —
--      pojistka pro případ, že by CHECK někdo shodil. Akce se nesmí dát
--      zabetonovat ani omylem.
--
-- HORNÍ MEZ 50 NENÍ VYMYŠLENÁ: je to `VALIDATION_LIMITS.STAFF_COUNT_MAX`
-- ze `src/lib/validation.ts:51`, kterou formulář vynucuje už dnes. Databáze se
-- tím jen srovnává s aplikací — bez ní by překlep „500 instruktorů" založil
-- 500 směn, což je nově možné právě proto, že se rozpis čte i při úpravě.
-- -----------------------------------------------------------------------------

-- `IMMUTABLE` je tu vědomá nepřesnost, ne nedbalost. Přetypování textu na enum
-- závisí na definici typu, takže přísně vzato je funkce STABLE — jenže CHECK
-- constraint jinou volatilitu nepustí. Je to bezpečné jedním směrem: do enumu
-- jde hodnoty jen PŘIDÁVAT (`ALTER TYPE … ADD VALUE`), takže rozšíření typu může
-- constraint jedině zvolnit. Řádek, který platil, platit nepřestane.
CREATE OR REPLACE FUNCTION public.role_reqs_je_platny(_rozpis jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $$
DECLARE _klic text; _hodnota text;
BEGIN
  IF _rozpis IS NULL THEN
    RETURN true;                      -- prázdno je legitimní (akce bez štábu)
  END IF;
  IF jsonb_typeof(_rozpis) <> 'object' THEN
    RETURN false;                     -- pole ani řetězec rozpis není
  END IF;

  FOR _klic, _hodnota IN SELECT key, value FROM jsonb_each_text(_rozpis) LOOP
    -- Jen celá nezáporná čísla. Nula projde schválně: `{"instructor": 0}` je
    -- srozumitelné „nikoho nechci" a chová se stejně jako vynechaný klíč.
    -- Záporné číslo ani desetinné místo smysl nedává.
    IF _hodnota IS NULL OR _hodnota !~ '^[0-9]+$' THEN
      RETURN false;
    END IF;
    IF _hodnota::numeric > 50 THEN    -- VALIDATION_LIMITS.STAFF_COUNT_MAX
      RETURN false;
    END IF;

    BEGIN
      PERFORM _klic::public.app_role;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN false;
    END;
  END LOOP;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.role_reqs_je_platny(jsonb) IS
  'Ověří events.role_reqs: objekt, klíče jsou hodnoty app_role, hodnoty celá čísla 0–50 (VALIDATION_LIMITS.STAFF_COUNT_MAX). Používá se jako CHECK.';

-- `GRANT EXECUTE` tu NENÍ zbytečně široký — bez něj by CHECK neprošel.
-- Ověřeno: po `REVOKE EXECUTE … FROM authenticated` skončí `UPDATE events`
-- pod rolí `authenticated` na „permission denied for function
-- role_reqs_je_platny". CHECK se vyhodnocuje pod právy toho, kdo zapisuje.
--
-- Nic to neodhaluje: funkce je čistý predikát nad svým argumentem, do žádné
-- tabulky nesahá. A zapisovat do `events` smí stejně jen admin (RLS).
REVOKE ALL ON FUNCTION public.role_reqs_je_platny(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.role_reqs_je_platny(jsonb) TO authenticated;

-- PŘEDKONTROLA — rozpor se OHLÁSÍ i s ukázkami, NEOPRAVUJE se.
-- Postup podle `20260813120000_strop_sazby.sql`. Bez tohohle bloku by
-- `ADD CONSTRAINT` spadl na „is violated by some row" — bez počtu a bez ID,
-- takže by nikdo nevěděl, kterou akci má opravit.
DO $$
DECLARE _spatnych int; _ukazky text;
BEGIN
  SELECT count(*) INTO _spatnych FROM public.events
   WHERE NOT public.role_reqs_je_platny(role_reqs);

  IF _spatnych > 0 THEN
    SELECT string_agg(format('%s „%s" → %s', id, title, role_reqs::text), E'\n  ')
      INTO _ukazky
      FROM (SELECT id, title, role_reqs FROM public.events
             WHERE NOT public.role_reqs_je_platny(role_reqs)
             ORDER BY start_time DESC LIMIT 5) u;
    RAISE EXCEPTION E'Migrace zastavena: % akcí má neplatný rozpis štábu (events.role_reqs).\n  %\nPlatný rozpis je objekt, klíče jsou role z app_role a hodnoty celá čísla 0–50.\nOprav je ručně a spusť migraci znovu — dorovnání štábu na nich jinak nemá z čeho počítat.',
      _spatnych, _ukazky;
  END IF;
END $$;

ALTER TABLE public.events DROP CONSTRAINT IF EXISTS events_role_reqs_platny;
ALTER TABLE public.events ADD CONSTRAINT events_role_reqs_platny
  CHECK (public.role_reqs_je_platny(role_reqs));

-- -----------------------------------------------------------------------------
-- 1) Dorovnání jako FUNKCE, ne jen tělo triggeru
--
-- Samostatná funkce proto, že ji potřebují tři různí volající: trigger, test
-- a (později) potvrzovací dialog, který má před uložením ukázat, kolik směn se
-- dorovná. Kdyby to bylo schované v triggeru, musely by si to ostatní dvě
-- místa napsat znovu — a druhá implementace téhož pravidla se vždycky rozejde.
--
-- SECURITY DEFINER: akci smí upravit i někdo, kdo na `shifts` nemá INSERT
-- (politika „Only admins can create shifts"). Vlastní zápis směn tedy nesmí
-- viset na právech volajícího. Táž úvaha jako u `handle_new_commercial_event`,
-- které bylo SECURITY DEFINER od baseline.
-- -----------------------------------------------------------------------------
-- Starý jednoparametrový podpis pryč, ať po něm nezůstane přetížení, které by
-- volalo jinou (rušicí) variantu než ta, kterou má volající na mysli.
DROP FUNCTION IF EXISTS public.dorovnej_stab(uuid);

CREATE OR REPLACE FUNCTION public.dorovnej_stab(
  _event_id    uuid,
  -- `_jen_doplnit = true` → směny se JEN DOPLŇUJÍ, nic se neruší.
  --
  -- Je to kvůli datové části v kapitole 5: ta si vybírá akce filtrem přes SOUČET
  -- za akci, kdežto tahle funkce pracuje PO ROLÍCH. Akce `{"instructor": 4}`
  -- s jedním instruktorem a dvěma volnými směnami baru má součet 3 < 4, takže
  -- filtr ji vezme jako „chybí lidi" — a funkce by přitom bar zrušila.
  -- Migrace by tedy rušila směny, přestože slibuje, že jen doplňuje.
  --
  -- Řeší se to tímhle přepínačem, ne přepsáním filtru na role: rušení směn při
  -- migraci nemá být otázka toho, jak dobře je napsaný filtr, ale toho, že se
  -- při migraci ruší NIKDY.
  _jen_doplnit boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _ev          record;
  _r           record;
  _i           int;
  _zrusenych   int;
  _pridano     int := 0;
  _zruseno     int := 0;
  _neruseno    int := 0;
  _prebytek    jsonb := '[]'::jsonb;
  _spatne      text[] := '{}';
  _cist_cely   boolean;
BEGIN
  SELECT id, event_type, role_reqs, required_staff INTO _ev
    FROM public.events WHERE id = _event_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Nepoužitelné položky v rozpisu (viz tolerantní čtení níž). Od kapitoly 0
  -- je hlídá CHECK, takže sem se za normálních okolností nedá dostat.
  SELECT array_agg(key || '=' || value) INTO _spatne
    FROM jsonb_each_text(_ev.role_reqs)
   WHERE _ev.role_reqs IS NOT NULL
     AND jsonb_typeof(_ev.role_reqs) = 'object'
     AND (value !~ '^[0-9]+$'
          OR key <> ALL (enum_range(NULL::public.app_role)::text[]));

  -- ROZPIS, KTERÝ NEJDE PŘEČÍST CELÝ, NENÍ PODKLAD KE ZRUŠENÍ SMĚN.
  --
  -- Překlep `{"instruktor": 2}` znamená, že o roli `instructor` rozpis
  -- neříká nic — ne že ji nechce. Bez téhle zábrany by se četla jako
  -- „chceme 0" a její volné směny by zmizely, přestože komentář i hláška
  -- slibují, že se nepoužitelná položka jen PŘESKOČÍ. Ověřeno, než se to
  -- zavřelo: akce se 2 směnami a překlepem v klíči o obě přišla.
  --
  -- Doplňovat se smí dál — přidaná směna nikomu nic nebere.
  _cist_cely := _spatne IS NULL OR cardinality(_spatne) = 0;
  IF NOT _cist_cely THEN
    _jen_doplnit := true;
  END IF;

  -- Projít se musí SJEDNOCENÍ rolí požadovaných a rolí, na kterých už směny
  -- visí — proto FULL JOIN. Kdyby se šlo jen po `role_reqs`, odebrání role
  -- z rozpisu by její směny nechalo viset (a to je přesně jeden ze tří případů,
  -- kvůli kterým tahle migrace vzniká).
  --
  -- Spojuje se přes `COALESCE(role::text, '')`, ne přes `IS NOT DISTINCT FROM`:
  -- FULL JOIN v Postgresu vyžaduje podmínku, která jde hashovat nebo mergovat,
  -- a `IS NOT DISTINCT FROM` ani jedno neumí — skončilo by to chybou
  -- „FULL JOIN is only supported with merge-joinable or hash-joinable join
  -- conditions". Prázdný řetězec zastupuje směnu BEZ role.
  FOR _r IN
    WITH pozadavek AS (
      -- Nový rozpis podle rolí.
      --
      -- ČTE SE TOLERANTNĚ, i když od kapitoly 0 hlídá vstup CHECK. Kdyby ten
      -- CHECK někdo shodil (nebo kdyby se sem data dostala mimo něj), nesmí to
      -- skončit tím, že se akce stane NEEDITOVATELNOU: cast `'dva'::int` uvnitř
      -- triggeru by shodil každý UPDATE té akce, tedy i ten, kterým by to šlo
      -- opravit. Nepoužitelný klíč se proto přeskočí a nahlásí (`spatne` v
      -- návratové hodnotě + WARNING), místo aby se na něm spadlo.
      --
      -- `jsonb_typeof` je tu proto, že `jsonb_each_text` na cokoli jiného než
      -- objekt rovnou vyhodí chybu — a to je právě to, čemu se vyhýbáme.
      --
      -- `event_type` PLATÍ PRO OBĚ VĚTVE. Bez toho měla funkce asymetrii:
      -- rozpis podle rolí se bral bez ohledu na typ akce, kdežto starší cesta
      -- jen u komerčky. Dokud byl trigger INSERT-only, nebylo to vidět; jakmile
      -- se rozpis čte i při ÚPRAVĚ, znamenalo to, že přepnutí akce na TRÉNINK
      -- jí založí PLACENÉ směny. Ověřeno, než se to zavřelo: komerční akce se
      -- 3 směnami → UPDATE na `training` s rozpisem 4 instruktorů → 4 volné
      -- směny po 250 Kč/h, na které se brigádníci můžou přihlásit. A z UI je
      -- nešlo odebrat, protože sekce štábu je pro trénink skrytá.
      --
      -- Pravidlo „štáb má jen komerční akce" tu není nové — `create_booking`
      -- ho drží od Etapy 1 (`CASE WHEN p_kind = 'commercial' THEN p_role_reqs
      -- ELSE '{}' END`). Tohle jen srovnává druhou cestu do `events`, kterou
      -- chodí `useEvents.updateEvent` napřímo přes PostgREST.
      --
      -- ⚠️ AŽ SE BUDE STAVĚT R7 (trenér k tréninku), musí se to povolit VĚDOMĚ
      -- a na obou místech naráz — tady i v `create_booking`. Návrh s tím počítá
      -- (ETAPA3-ROLE-NAVRH, kapitola 9).
      SELECT (key)::public.app_role AS role, (value)::int AS pocet
        FROM jsonb_each_text(_ev.role_reqs)
       WHERE _ev.role_reqs IS NOT NULL
         AND jsonb_typeof(_ev.role_reqs) = 'object'
         AND _ev.role_reqs <> '{}'::jsonb
         AND _ev.event_type IN ('commercial', 'recruitment')
         AND value ~ '^[0-9]+$'
         AND key = ANY (enum_range(NULL::public.app_role)::text[])
      UNION ALL
      -- Starší cesta bez rolí (`events.required_staff`). Pořád se používá
      -- a data v ní jsou, takže ji dorovnání musí umět taky — jinak by úprava
      -- staré akce zrušila všechny její směny jako „přebytek".
      SELECT NULL::public.app_role, COALESCE(_ev.required_staff, 0)
       WHERE (_ev.role_reqs IS NULL OR _ev.role_reqs = '{}'::jsonb)
         AND _ev.event_type IN ('commercial', 'recruitment')
         AND COALESCE(_ev.required_staff, 0) > 0
    ),
    existujici AS (
      SELECT required_role AS role, count(*)::int AS pocet
        FROM public.shifts
       WHERE event_id = _event_id
         AND status <> 'cancelled'
       GROUP BY required_role
    )
    SELECT COALESCE(p.role, e.role) AS role,
           COALESCE(p.pocet, 0)     AS chceme,
           COALESCE(e.pocet, 0)     AS mame
      FROM pozadavek p
      FULL JOIN existujici e
        ON COALESCE(e.role::text, '') = COALESCE(p.role::text, '')
  LOOP
    IF _r.chceme > _r.mame THEN
      FOR _i IN 1 .. (_r.chceme - _r.mame) LOOP
        -- `hourly_rate` se schválně NEVYPLŇUJE: doplní ho z ceníku trigger
        -- `set_shift_rate` (migrace 20260827090000). Kdyby se sem napsala
        -- konstanta, byla by to druhá, tišší cesta k sazbě.
        INSERT INTO public.shifts (event_id, status, required_role)
        VALUES (_event_id, 'open', _r.role);
      END LOOP;
      _pridano := _pridano + (_r.chceme - _r.mame);

    ELSIF _r.chceme < _r.mame THEN
      IF _jen_doplnit THEN
        -- Volající si vyžádal režim „jen doplňuj". Přebytek se spočítá a vrátí,
        -- ale nesahá se na něj.
        _neruseno := _neruseno + (_r.mame - _r.chceme);
        CONTINUE;
      END IF;

      -- Ruší se OD NEJNOVĚJŠÍ: přebytek vznikl tím, že někdo přidal víc, než
      -- nakonec chtěl, takže se bere zpátky to poslední. Původní místa zůstávají.
      WITH ke_zruseni AS (
        SELECT id FROM public.shifts
         WHERE event_id = _event_id
           AND required_role IS NOT DISTINCT FROM _r.role
           AND status = 'open'
         ORDER BY created_at DESC, id DESC
         LIMIT (_r.mame - _r.chceme)
      )
      UPDATE public.shifts s
         SET status       = 'cancelled',
             cancelled_at = now(),
             cancelled_by = auth.uid()
        FROM ke_zruseni k
       WHERE s.id = k.id;

      GET DIAGNOSTICS _zrusenych = ROW_COUNT;
      _zruseno := _zruseno + _zrusenych;

      -- Co zbylo, jsou směny ve stavu `pending`/`claimed`/`completed`. Ty se
      -- nesahají — sebrat směnu, na kterou se někdo přihlásil, je horší než
      -- nesoulad. Ale nesmí to zůstat tiché.
      IF _zrusenych < (_r.mame - _r.chceme) THEN
        _prebytek := _prebytek || jsonb_build_object(
          'role',      _r.role,
          'nezruseno', (_r.mame - _r.chceme) - _zrusenych);
      END IF;
    END IF;
  END LOOP;

  IF jsonb_array_length(_prebytek) > 0 THEN
    RAISE WARNING 'Akce % má víc obsazených směn, než rozpis žádá — nezrušeno: %. Zabrané směny dorovnání nesahá.',
      _event_id, _prebytek;
  END IF;

  IF NOT _cist_cely THEN
    RAISE WARNING 'Akce % má v rozpisu nepoužitelné položky: %. Byly přeskočeny a dorovnání kvůli nim NIC NERUŠILO — rozpis, který nejde přečíst celý, není podklad ke zrušení směn. Oprav events.role_reqs.',
      _event_id, _spatne;
  END IF;

  RETURN jsonb_build_object(
    'event_id', _event_id,
    'pridano',  _pridano,
    'zruseno',  _zruseno,
    -- Kolik směn by se zrušilo, kdyby režim „jen doplňuj" nebyl zapnutý.
    -- Volající to musí umět vypsat, jinak je „nic jsme nezrušili" jen tvrzení.
    'neruseno', _neruseno,
    'spatne',   COALESCE(to_jsonb(_spatne), '[]'::jsonb),
    'prebytek', _prebytek);
END;
$$;

COMMENT ON FUNCTION public.dorovnej_stab(uuid, boolean) IS
  'Dorovná směny akce podle events.role_reqs (nebo required_staff u starších akcí). Chybějící doplní, přebývající OPEN zruší softly, pending/claimed/completed nesahá a rozdíl ohlásí. _jen_doplnit => true nezruší nic. Idempotentní. Pro anon a authenticated NENÍ dostupná jako RPC (EXECUTE odebrané); service_role ji zavolat může — ta obchází granty vždycky.';

-- ⚠️ EXECUTE SE MUSÍ ODEBRAT, JINAK JE TO DÍRA. Postgres dává na novou funkci
-- `EXECUTE` roli `PUBLIC` automaticky, a v Supabase je `public` schéma vystavené
-- přes PostgREST — takže by šlo zavolat
--     POST /rest/v1/rpc/dorovnej_stab   {"_event_id": "…"}
-- BEZ PŘIHLÁŠENÍ. Funkce je `SECURITY DEFINER`, tedy by běžela s plnými právy
-- a nepřihlášenému volajícímu by ZRUŠILA SMĚNU. Ověřeno, než se to zavřelo:
-- pod `SET ROLE anon` vrátila {"zruseno": 1} a směna byla opravdu zrušená.
--
-- Není to teoretické: `_event_id` je jediný parametr a id akce se do světa
-- dostane běžně (odkaz, e-mail, historie prohlížeče).
--
-- Funkce NENÍ RPC — volá ji trigger, a ten na EXECUTE nekouká: právo se ověřuje
-- při `CREATE TRIGGER`, ne při každém spuštění. Hlídá to vlastní tvrzení v testu.
--
-- Přesně řečeno: nedostupná je pro `anon` a `authenticated`, tedy pro všechny
-- klíče, které se dostanou do prohlížeče. `service_role` ji zavolat může —
-- ta obchází granty i RLS ze své podstaty a chrání ji jen to, že její klíč
-- nikdy neopustí server.
REVOKE ALL ON FUNCTION public.dorovnej_stab(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2) Trigger místo `AFTER INSERT`
--
-- `UPDATE OF role_reqs, required_staff, event_type` — tři sloupce, ze kterých
-- se počet směn odvozuje. `event_type` mezi nimi je proto, že starší cesta
-- (`required_staff` bez rolí) platí jen pro `commercial` a `recruitment`:
-- překlopení typu akce tedy počet směn mění, i když se `required_staff` nehnul.
--
-- Pozn.: `UPDATE OF sloupec` se v Postgresu spouští, když je sloupec v SET
-- klauzuli — i když se hodnota nezměnila. Dorovnání je idempotentní, takže je
-- to jen práce navíc, ne chyba.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_dorovnej_stab()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public.dorovnej_stab(NEW.id);
  RETURN NULL;  -- AFTER trigger, návratová hodnota se ignoruje
END;
$$;

-- Totéž pro obal triggeru. Ten se sice přes PostgREST vystavit nedá (vrací typ
-- `trigger`), ale ponechaný grant by tvrdil opak toho, co platí o funkci nad ním.
REVOKE ALL ON FUNCTION public.trg_dorovnej_stab() FROM PUBLIC, anon, authenticated;

-- Starý trigger pryč. FUNKCE `handle_new_commercial_event()` zůstává schválně —
-- revert je pak jediný `CREATE TRIGGER`. Od teď je to mrtvý kód a je to tak
-- napsané i v komentáři té funkce níž, ať ji příště nikdo nezačne upravovat
-- v domnění, že něco dělá.
DROP TRIGGER IF EXISTS create_shifts_for_commercial_event ON public.events;

COMMENT ON FUNCTION public.handle_new_commercial_event() IS
  'MRTVÝ KÓD od migrace 20260827100000. Nahradila ho dorovnej_stab(), která umí i UPDATE. Funkce zůstává jen proto, aby revert té migrace byl jediný CREATE TRIGGER. Needituj ji — nic nevolá.';

DROP TRIGGER IF EXISTS trg_events_dorovnani ON public.events;
CREATE TRIGGER trg_events_dorovnani
  AFTER INSERT OR UPDATE OF role_reqs, required_staff, event_type ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.trg_dorovnej_stab();

-- -----------------------------------------------------------------------------
-- 3) Audit směn
--
-- Dorovnání od teď ruší směny SAMO. Bez auditní stopy by brigádníkovi zmizela
-- volná směna a nikde by nebylo, kdo a čím to způsobil — přesně proti požadavku
-- zákazníka „musí být vidět, kdo co zadával". `shifts` auditní trigger dosud
-- neměly; teď ho potřebují, protože do nich píše i stroj, nejen člověk.
--
-- `write_audit_log` je generický a `shifts` mají sloupec `id`, takže vlastní
-- variantu (jako u `sazby_roli`) nepotřebují.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_shifts_audit ON public.shifts;
CREATE TRIGGER trg_shifts_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- -----------------------------------------------------------------------------
-- 4) Varování o dráhách (rozhodnutí R8)
--
-- Pohled, ne trigger a ne CHECK: „instruktorů ≥ počet drah" je DOPORUČENÍ,
-- které se smí vědomě přebít. Tvrdé pravidlo by zavřelo legitimní případ, kdy
-- jeden instruktor obslouží obě dráhy — a přesně tomu se R8 vyhýbá.
--
-- `security_invoker = on`: pohled se ptá pod právy volajícího, takže nemůže
-- ukázat víc než přímý přístup do `events`, `shifts` a `reservations`.
-- Filtr `has_role(admin)` je NAVÍC, a je tam z jiného důvodu než utajení:
-- pod `security_invoker` by ne-admin viděl jen část rezervací a směn, takže by
-- mu ČÍSLA VYŠLA ŠPATNĚ. Prázdný výsledek je lepší než tiše nesprávný počet.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.stab_kontrola;
CREATE VIEW public.stab_kontrola
WITH (security_invoker = on) AS
SELECT
  e.id           AS event_id,
  e.title,
  e.event_type,
  e.start_time,

  COALESCE(d.drah, 0)                              AS drah,
  COALESCE((e.role_reqs ->> 'instructor')::int, 0) AS instruktoru_v_rozpisu,
  COALESCE(s.instruktoru, 0)                       AS instruktoru_smen,

  -- Kolik lidí rozpis celkem žádá. U starších akcí bez `role_reqs` se to bere
  -- z `required_staff` — tedy stejnou logikou, jakou má dorovnání.
  CASE
    WHEN e.role_reqs IS NOT NULL AND e.role_reqs <> '{}'::jsonb
      THEN COALESCE((SELECT sum(value::int) FROM jsonb_each_text(e.role_reqs)), 0)
    WHEN e.event_type IN ('commercial', 'recruitment')
      THEN COALESCE(e.required_staff, 0)
    ELSE 0
  END                                              AS stabu_v_rozpisu,

  COALESCE(s.aktivnich, 0)                         AS smen_aktivnich,
  COALESCE(s.obsazenych, 0)                        AS smen_obsazenych,

  -- Vlastní varování: méně instruktorů než drah. Nula = v pořádku (nebo vědomě
  -- přebito, což je totéž číslo — rozdíl je v tom, jestli o tom člověk ví).
  greatest(COALESCE(d.drah, 0) - COALESCE(s.instruktoru, 0), 0)
                                                   AS instruktoru_chybi,

  -- Směny navíc oproti rozpisu. Za normálních okolností 0 — dorovnání to drží.
  -- Nenulové číslo znamená, že přebytek nešlo zrušit, protože na něm někdo visí.
  greatest(
    COALESCE(s.aktivnich, 0) - CASE
      WHEN e.role_reqs IS NOT NULL AND e.role_reqs <> '{}'::jsonb
        THEN COALESCE((SELECT sum(value::int) FROM jsonb_each_text(e.role_reqs)), 0)
      WHEN e.event_type IN ('commercial', 'recruitment')
        THEN COALESCE(e.required_staff, 0)
      ELSE 0
    END, 0)                                        AS smen_navic

FROM public.events e
LEFT JOIN LATERAL (
  -- DISTINCT podle dráhy, ne count(*) rezervací. Dnes to vychází stejně (žádná
  -- akce nemá dvě rezervace na téže dráze), ale je to domněnka, ne pravidlo:
  -- exclusion constraint zakazuje jen PŘEKRYV v čase, takže dvě rezervace na
  -- téže dráze v navazujících hodinách pod jednou akcí projdou. Bez DISTINCT
  -- by taková akce hlásila „chybí instruktor", kterého nepotřebuje.
  SELECT count(DISTINCT r.sheet_id)::int AS drah
    FROM public.reservations r
   WHERE r.event_id = e.id
     AND r.deleted_at IS NULL
     AND r.status = 'confirmed'
) d ON true
LEFT JOIN LATERAL (
  SELECT count(*)::int                                                       AS aktivnich,
         count(*) FILTER (WHERE sh.required_role = 'instructor')::int        AS instruktoru,
         count(*) FILTER (WHERE sh.status IN ('pending','claimed','completed'))::int AS obsazenych
    FROM public.shifts sh
   WHERE sh.event_id = e.id
     AND sh.status <> 'cancelled'
) s ON true
WHERE has_role(auth.uid(), 'admin');

COMMENT ON VIEW public.stab_kontrola IS
  'Varování o štábu akce (rozhodnutí PM R8): instruktoru_chybi > 0 znamená míň instruktorů než drah — doporučení, ne zákaz, přebít se smí vědomě. smen_navic > 0 znamená, že dorovnání nemohlo zrušit přebytek, protože na směnách někdo visí. Admin-only: pod jinými právy by čísla vyšla nesprávně, ne jen neúplně.';

-- REVOKE MUSÍ PŘEDCHÁZET GRANTU, jinak je ochrana jednovrstvá.
-- Supabase má na schématu `public` nastavené
--   ALTER DEFAULT PRIVILEGES … GRANT ALL ON TABLES TO anon, authenticated;
-- takže čerstvě vytvořený pohled dostane pro `anon` rovnou SELECT, INSERT,
-- UPDATE, DELETE, REFERENCES i TRIGGER. A protože tahle migrace dělá
-- DROP VIEW + CREATE VIEW, nasype se to znovu při každé aplikaci.
--
-- Dnes by tím nic neuniklo — `security_invoker = on` platí a filtr
-- `has_role(auth.uid(),'admin')` vrátí anonovi nula řádků. Ale pak by celá
-- ochrana stála na jediné WHERE klauzuli, kterou příští úprava pohledu smaže
-- bez povšimnutí. Sousední migrace `sazby_roli` dělá REVOKE ze stejného důvodu.
REVOKE ALL ON public.stab_kontrola FROM anon, authenticated, public;
GRANT SELECT ON public.stab_kontrola TO authenticated;

-- -----------------------------------------------------------------------------
-- 5) Dorovnání existujících akcí
--
-- JEN DOPLŇUJE. Nikdy neruší — a nespoléhá se přitom na to, že to vyjde
-- z filtru, ale říká si o to výslovně (`_jen_doplnit => true`).
--
-- PROČ TO NESTAČILO NECHAT NA FILTRU: filtr si vybírá akce podle SOUČTU za
-- akci, kdežto `dorovnej_stab` pracuje PO ROLÍCH. Akce `{"instructor": 4}`
-- s jedním instruktorem a dvěma volnými směnami baru má součet 3 < 4, takže
-- filtrem projde jako „chybí lidi" — a bez přepínače by jí migrace ty dvě
-- směny baru ZRUŠILA, přestože hlavička slibuje, že jen doplňuje. Filtr, na
-- kterém visí slib „nic nerušíme", je slib jen do chvíle, než ho někdo upraví.
--
-- Projíždí se VŠECHNY akce, ne jen ty „s nedostatkem": rozhodnutí, co dělat,
-- dělá funkce po rolích, a součtový předvýběr by právě u smíšených rozpisů
-- (instruktor chybí, bar přebývá) vynechal ty akce, které doplnění potřebují
-- nejvíc. Akcí jsou desítky, ne miliony.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _e        record;
  _vysledek jsonb;
  _pridano  int;
  _neruseno int;
  _celkem   int := 0;
  _prebytku int := 0;
BEGIN
  FOR _e IN SELECT id, title FROM public.events ORDER BY start_time
  LOOP
    _vysledek := public.dorovnej_stab(_e.id, _jen_doplnit => true);
    _pridano  := COALESCE((_vysledek ->> 'pridano')::int, 0);
    _neruseno := COALESCE((_vysledek ->> 'neruseno')::int, 0);

    IF _pridano > 0 THEN
      _celkem := _celkem + _pridano;
      RAISE NOTICE 'Doplněno % směn: „%"', _pridano, _e.title;
    END IF;

    -- Přebytek se HLÁSÍ, i když se neruší. Bez tohohle výpisu by „migrace nic
    -- neruší" znamenalo jen to, že se o přebytku nikdo nedozví — a provoz by
    -- začínal s rozporem, o kterém neví. Dřív to hlásila druhá smyčka, která
    -- porovnávala součty, takže právě smíšené případy minula.
    IF _neruseno > 0 THEN
      _prebytku := _prebytku + _neruseno;
      RAISE NOTICE 'POZOR: „%" má o % směn víc, než rozpis žádá. Migrace je ZÁMĚRNĚ NERUŠÍ — vyřeš to v aplikaci úpravou akce.',
        _e.title, _neruseno;
    END IF;
  END LOOP;

  IF _celkem = 0 THEN
    RAISE NOTICE 'Žádná akce nepotřebovala doplnit směny.';
  ELSE
    RAISE NOTICE 'Celkem doplněno % chybějících směn.', _celkem;
  END IF;

  IF _prebytku > 0 THEN
    RAISE NOTICE 'Celkem % směn navíc oproti rozpisu zůstalo nedotčených. Jsou vidět v pohledu stab_kontrola (sloupec smen_navic).', _prebytku;
  END IF;

  -- Tvrzení „migrace nezrušila ani jednu směnu" se nenechává na komentáři.
  -- `cancelled_by IS NULL` pozná zrušení bez přihlášeného člověka, tedy přesně
  -- to, co by udělala tahle migrace.
  IF EXISTS (SELECT 1 FROM public.shifts
              WHERE status = 'cancelled' AND cancelled_at >= now() - interval '1 minute'
                AND cancelled_by IS NULL) THEN
    RAISE EXCEPTION 'Migrace zrušila směnu, přestože měla jen doplňovat. Zastavuji — tohle se nesmí stát tiše.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 6) Kontrola, že to sedí
-- -----------------------------------------------------------------------------
DO $$
DECLARE _stary int; _novy int; _udalosti text;
BEGIN
  SELECT count(*) INTO _stary FROM pg_trigger
   WHERE tgname = 'create_shifts_for_commercial_event' AND NOT tgisinternal;
  IF _stary > 0 THEN
    RAISE EXCEPTION 'Starý trigger create_shifts_for_commercial_event pořád existuje — směny by se zakládaly dvakrát.';
  END IF;

  SELECT count(*) INTO _novy FROM pg_trigger
   WHERE tgname = 'trg_events_dorovnani' AND NOT tgisinternal;
  IF _novy <> 1 THEN
    RAISE EXCEPTION 'trg_events_dorovnani nevznikl.';
  END IF;

  -- Že trigger poslouchá i na UPDATE, je celý smysl téhle migrace. `tgtype`
  -- je bitová maska: 1 = ROW, 4 = INSERT, 16 = UPDATE, 2 = BEFORE (tady 0).
  SELECT CASE WHEN (tgtype & 4) > 0 THEN 'INSERT ' ELSE '' END
      || CASE WHEN (tgtype & 16) > 0 THEN 'UPDATE' ELSE '' END
    INTO _udalosti
    FROM pg_trigger WHERE tgname = 'trg_events_dorovnani' AND NOT tgisinternal;
  IF _udalosti <> 'INSERT UPDATE' THEN
    RAISE EXCEPTION 'trg_events_dorovnani neposlouchá na INSERT i UPDATE (nalezeno: %).', _udalosti;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND c.relname = 'stab_kontrola' AND c.relkind = 'v') THEN
    RAISE EXCEPTION 'Pohled stab_kontrola nevznikl — varování o dráhách by nebylo kde vidět.';
  END IF;
END $$;
