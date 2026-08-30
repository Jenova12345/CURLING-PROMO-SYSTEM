-- =============================================================================
-- Ceník rolí (`sazby_roli`) + snapshot sazby do směny
-- Etapa 3, bod 1 z pořadí prací · rozhodnutí PM R9 (27. 8. 2026)
-- =============================================================================
-- CO SE MĚNÍ A PROČ:
-- Dneska `shifts.hourly_rate` nemá odkud vzít hodnotu. Sloupec má
-- `DEFAULT 150.00` a při uzavírání směny se sazba PŘEPISUJE RUČNĚ ve formuláři.
-- Takže: trenér za 600 se musí napsat pokaždé znovu, překlep nikdo nepozná
-- (150 je platná sazba pro kohokoli) a z hodinových sazeb nejde udělat rozpočet,
-- protože nikde nejsou zapsané — jsou jen v hlavě toho, kdo je píše.
--
-- Sazby od PM (jednotné pro celou halu, ne per klub — to je součást R9):
--   trainer 600 · instructor 250 · bar_staff 200 · manager 200 · part_time_staff 150
--
-- VZOR JE `reservations.rate_per_hour`, NE NĚCO NOVÉHO:
-- sazba se do směny SNAPSHOTUJE při jejím vzniku a pozdější změna ceníku
-- minulé směny nepřepočítá. U peněz, které už někdo dostal, je to jediná
-- obhajitelná varianta — jinak by úprava ceníku tiše přepsala historii výplat.
-- Ruční přepsání sazby na konkrétní směně zůstává možné (a je to občas potřeba),
-- jen přestává být VÝCHOZÍ cestou.
--
-- -----------------------------------------------------------------------------
-- TŘI VĚCI, KTERÉ JE POTŘEBA VIDĚT, NEŽ SE TO BUDE ČÍST DÁL
-- -----------------------------------------------------------------------------
-- 1) `DEFAULT 150.00` NA SLOUPCI MUSÍ PRYČ, jinak trigger nemá jak poznat
--    „volající sazbu nezadal" od „volající zadal 150". S defaultem je
--    `NEW.hourly_rate` při INSERTu vždy vyplněné, takže by se ceník neuplatnil
--    nikdy a tahle migrace by byla mrtvý kód. Default nahrazuje trigger, který
--    umí totéž a navíc se ptá na roli.
--
-- 2) CENÍK JE UZAVŘENÝ SEZNAM, ne tabulka, do které se přidává za provozu.
--    `authenticated` na ní nemá INSERT ani DELETE — jen UPDATE popisných polí
--    a sazby (`sazba`, `popis`, `poradi`, `poznamka`; `role` ani razítka ne).
--    Důvod: chybějící řádek je tiché selhání. Směna by dostala záložní sazbu
--    150 Kč/h a nikde by nesvítilo, že to není rozhodnutí, ale mezera. Nová
--    placená role je produktové rozhodnutí, tedy migrace, ne klik v nastavení.
--
--    „Uzavřený" platí bez výhrad pro `authenticated` (granty + RLS) a pro
--    DELETE i TRUNCATE úplně pro každého (guard trigger, tedy i pro
--    `service_role`). INSERT pod `service_role` guard nehlídá — musel by se
--    zakládat až po naplnění tabulky a rozbil by opakovatelnost migrace.
--
-- 3) ZÁLOŽNÍ SAZBA 150 Kč/h ZŮSTÁVÁ, a to ve dvou případech:
--    • směna BEZ role (`required_role IS NULL`) — starší cesta přes
--      `events.required_staff`, která pořád existuje a data v ní jsou;
--    • směna s rolí, která v ceníku není. Dnes nastat nemá (ceník je uzavřený
--      seznam), ale kdyby do `app_role` přibyla placená hodnota, nesmí to být
--      tiché — funkce na to píše WARNING.
--    Je to táž hodnota, jakou měl dosud default sloupce, takže se pro tyhle
--    směny nemění nic.
--
-- -----------------------------------------------------------------------------
-- VRATNOST (revert je celý tenhle blok, žádná ztráta dat):
--   DROP TRIGGER  IF EXISTS trg_shifts_sazba ON public.shifts;
--   DROP FUNCTION IF EXISTS public.set_shift_rate();
--   ALTER TABLE public.shifts DROP CONSTRAINT IF EXISTS shifts_hourly_rate_rozsah;
--   ALTER TABLE public.shifts ALTER COLUMN hourly_rate DROP NOT NULL;
--   ALTER TABLE public.shifts ALTER COLUMN hourly_rate SET DEFAULT 150.00;
--   DROP TABLE public.sazby_roli;   -- vezme s sebou politiky, granty i TRIGGERY
--   -- ale NE funkce, které ty triggery volaly — ty musí zvlášť:
--   DROP FUNCTION IF EXISTS public.guard_sazby_roli_role();
--   DROP FUNCTION IF EXISTS public.guard_sazby_roli_delete();
--   DROP FUNCTION IF EXISTS public.write_audit_log_sazby_roli();
-- Sazby, které trigger stihl vepsat do směn, revert NEODSTRANÍ — a je to tak
-- správně: jsou to snapshoty, ne odvozená data. Po revertu prostě zůstanou
-- jako ručně zadané sazby, což je přesně to, čím byly předtím.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Tabulka
--
-- PK je `role`, ne umělé `id`: jedna role = jedna sazba je invariant, ne shoda
-- náhod, a PK to vyjadřuje tvrději než UNIQUE index vedle sekvence.
--
-- `popis` a `poradi` jsou tu proto, aby formulář v Nastavení nemusel mít vedle
-- sebe druhý, ručně udržovaný seznam rolí. Kdyby ho měl, rozejde se — a rozejde
-- se tiše, protože chybějící popisek vypadá jako prázdné pole, ne jako chyba.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sazby_roli (
  role       public.app_role PRIMARY KEY,
  sazba      numeric(10,2) NOT NULL,
  popis      text          NOT NULL,
  poradi     smallint      NOT NULL,
  poznamka   text,

  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.profiles(user_id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.profiles(user_id),

  -- Strop 10 000 Kč/h je TÝŽ, jaký hlídá `validate_shift_claim` na
  -- `shifts.hourly_rate` od baseline. Kdyby ceník pustil víc, uložila by se
  -- sazba, kterou pak směna odmítne — a hláška by mluvila o směně, do které to
  -- nikdo nezadával. Strop musí být tam, kde se hodnota ZADÁVÁ (táž úvaha jako
  -- u `strop_sazby` v Etapě 2), ne jen tam, kde se projeví.
  --
  -- Horní mez zavírá i `NaN`: v Postgresu je `'NaN'::numeric > 0` true, takže
  -- samotné „kladné číslo" by ji pustilo. `NaN <= 10000` je false, tedy CHECK
  -- neprojde. Hlídá to vlastní tvrzení v testu, ať to revert nevrátí zpátky.
  CONSTRAINT sazby_roli_sazba  CHECK (sazba > 0 AND sazba <= 10000),
  -- Celé koruny — stejné pravidlo jako u ceníku ledu (`parseSazba`, Etapa 2).
  -- Haléřová sazba se nedá vyplatit a v souhrnech dělá nedohledatelné rozdíly.
  CONSTRAINT sazby_roli_cele   CHECK (sazba = round(sazba)),
  CONSTRAINT sazby_roli_popis  CHECK (btrim(popis) <> '')
);

COMMENT ON TABLE public.sazby_roli IS
  'Ceník hodinových sazeb podle role (rozhodnutí PM R9, 27. 8. 2026). Jednotný pro celou halu. Uzavřený seznam — nová placená role je migrace, ne klik v nastavení. Sazba se do směny snapshotuje při jejím vzniku a pozdější změna ceníku minulé směny nepřepočítá.';
COMMENT ON COLUMN public.sazby_roli.poradi IS
  'Pořadí ve formuláři v Nastavení. Aby seznam nezáležel na abecedě anglických názvů rolí.';
COMMENT ON COLUMN public.sazby_roli.popis IS
  'Český popisek role pro UI. Drží se tady, aby vedle nevznikl druhý ručně udržovaný seznam, který se tiše rozejde.';

-- -----------------------------------------------------------------------------
-- 2) Triggery: updated_by/updated_at + audit
--
-- POŘADÍ: triggery se zakládají PŘED naplněním tabulky, aby i vznik řádků měl
-- auditní stopu. Požadavek zákazníka zní „musí být vidět, kdo co zadával" —
-- a u ceníku, ze kterého se počítají výplaty, to platí dvojnásob.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_sazby_roli_updated ON public.sazby_roli;
CREATE TRIGGER trg_sazby_roli_updated
  BEFORE UPDATE ON public.sazby_roli
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_fields();

-- `write_audit_log` bere `record_id` z `NEW.id` / `OLD.id`. Tahle tabulka
-- sloupec `id` nemá (PK je `role`), takže generický trigger by spadl na
-- „record "new" has no field "id"". Vlastní varianta zapíše roli do `new_data`
-- a `record_id` nechá NULL — sloupec je nullable a role je v datech.
CREATE OR REPLACE FUNCTION public.write_audit_log_sazby_roli()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.audit_log (table_name, record_id, action, changed_by, old_data, new_data)
  VALUES (
    TG_TABLE_NAME, NULL, lower(TG_OP), auth.uid(),
    CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) ELSE NULL END
  );
  RETURN NULL;  -- AFTER trigger, návratová hodnota se ignoruje
END;
$$;

DROP TRIGGER IF EXISTS trg_sazby_roli_audit ON public.sazby_roli;
CREATE TRIGGER trg_sazby_roli_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.sazby_roli
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log_sazby_roli();

-- Mazání a TRUNCATE zavírá trigger, ne jen chybějící grant.
--
-- Granty i RLS obchází `service_role` (má BYPASSRLS), a to je role, pod kterou
-- běží Edge funkce. `DELETE FROM sazby_roli` pod ní by nechal halu bez ceníku
-- a všechny nové směny by tiše spadly na záložních 150 Kč/h. TRUNCATE navíc
-- řádkové BEFORE DELETE triggery VŮBEC NESPOUŠTÍ (ověřeno u `billing_settings`),
-- takže musí být i statement-level varianta — jinak je slib výš nepravdivý.
CREATE OR REPLACE FUNCTION public.guard_sazby_roli_delete()
RETURNS trigger
LANGUAGE plpgsql
-- `search_path` je přišpendlený, i když tělo je jen RAISE a funkce není
-- SECURITY DEFINER. Důvod je hygienický: sousední dvě funkce v téhle migraci
-- pinning mají, a nepřišpendlená funkce svítí v Supabase advisoru jako nález,
-- který příště někdo bude muset znovu posoudit. (Stávající
-- `guard_billing_settings_delete` ho nemá — to je na úklidový ticket, ne na
-- rozšiřování téhle migrace.)
SET search_path TO 'public'
AS $$
BEGIN
  RAISE EXCEPTION 'Ceník rolí se nemaže — je to uzavřený seznam. Uprav sazbu, nebo přidej roli migrací.';
END;
$$;

-- A JEŠTĚ JEDEN GUARD: přepsání samotné role.
--
-- `authenticated` sloupec `role` měnit nemůže (GRANT UPDATE je sloupcový a
-- `role` v něm není), ale `service_role` granty ani RLS neřeší — a `UPDATE
-- sazby_roli SET role = 'admin'` pod ní projde. Rozpojilo by to řádek od jeho
-- historie v `audit_log` a zároveň by to potichu vyrobilo ceníkovou položku pro
-- roli, o které nikdo nerozhodl. Uzavřený seznam znamená uzavřený i shora.
CREATE OR REPLACE FUNCTION public.guard_sazby_roli_role()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'Role v ceníku se nepřepisuje — je to primární klíč a váže na sebe historii v audit_log.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sazby_roli_role ON public.sazby_roli;
CREATE TRIGGER trg_sazby_roli_role
  BEFORE UPDATE ON public.sazby_roli
  FOR EACH ROW EXECUTE FUNCTION public.guard_sazby_roli_role();

DROP TRIGGER IF EXISTS trg_sazby_roli_no_delete ON public.sazby_roli;
CREATE TRIGGER trg_sazby_roli_no_delete
  BEFORE DELETE ON public.sazby_roli
  FOR EACH ROW EXECUTE FUNCTION public.guard_sazby_roli_delete();

DROP TRIGGER IF EXISTS trg_sazby_roli_no_truncate ON public.sazby_roli;
CREATE TRIGGER trg_sazby_roli_no_truncate
  BEFORE TRUNCATE ON public.sazby_roli
  FOR EACH STATEMENT EXECUTE FUNCTION public.guard_sazby_roli_delete();

-- -----------------------------------------------------------------------------
-- 3) Sazby od PM
--
-- `ON CONFLICT DO NOTHING`, ne `DO UPDATE`: kdyby migrace běžela podruhé nad
-- databází, kde už admin sazby upravil, `DO UPDATE` by mu je vrátil na výchozí.
-- Tichý přepis peněžního nastavení je horší než opakovaná migrace bez efektu.
--
-- Role, které tu NEJSOU (`admin`, `pro_player`, `hobby_player`), tu nejsou
-- schválně: dnes nedělají směny. Kdyby začaly, je to rozhodnutí PM a tedy
-- migrace — viz poznámka 2 v hlavičce.
-- -----------------------------------------------------------------------------
INSERT INTO public.sazby_roli (role, sazba, popis, poradi, poznamka) VALUES
  ('trainer',         600, 'Trenér',            1, NULL),
  ('instructor',      250, 'Instruktor',        2, NULL),
  ('bar_staff',       200, 'Obsluha baru',      3, NULL),
  ('manager',         200, 'Provozní hospoda',  4, NULL),
  ('part_time_staff', 150, 'Brigádník',         5, 'V zadání klienta uváděný jako „Linda".')
ON CONFLICT (role) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4) RLS a granty — čte i mění jen admin
--
-- Proč ne-admin nepotřebuje ANI ČÍST: sazbu, která se ho týká, vidí na SVÉ
-- směně (`shifts.hourly_rate`, snapshot). Ceník jako celek je mzdový přehled
-- celé haly — hráč klubu nemá důvod vědět, kolik bere trenér.
--
-- Že to nezavře i dopočet sazby při zakládání směny, obstarává `SECURITY DEFINER`
-- na `set_shift_rate` níž: rezervaci zakládá běžný člen a směna přitom musí
-- dostat sazbu z ceníku, do kterého ten člen nevidí.
-- -----------------------------------------------------------------------------
ALTER TABLE public.sazby_roli ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.sazby_roli FROM anon, authenticated, public;

GRANT SELECT ON public.sazby_roli TO authenticated;
-- UPDATE je SLOUPCOVÝ. Tabulkový by adminovi přes `PATCH /rest/v1/…` dovolil
-- přepsat i `role` (tedy rozpojit řádek od jeho historie v `audit_log`),
-- `created_at` nebo `updated_by` — což je zrovna to pole, které má dokazovat,
-- kdo změnu udělal.
GRANT UPDATE (sazba, popis, poradi, poznamka) ON public.sazby_roli TO authenticated;

DROP POLICY IF EXISTS sazby_roli_select_admin ON public.sazby_roli;
CREATE POLICY sazby_roli_select_admin ON public.sazby_roli
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS sazby_roli_update_admin ON public.sazby_roli;
CREATE POLICY sazby_roli_update_admin ON public.sazby_roli
  FOR UPDATE TO authenticated
  USING (has_role(auth.uid(), 'admin'))
  WITH CHECK (has_role(auth.uid(), 'admin'));

-- INSERT ani DELETE politika neexistuje — bez politiky je RLS odmítne. Je to
-- druhá vrstva k chybějícím grantům a k `guard_sazby_roli_delete`.

-- -----------------------------------------------------------------------------
-- 5) Dopočet sazby do směny
--
-- BEFORE INSERT, ne AFTER: sazba musí být v řádku dřív, než se zkontroluje
-- `NOT NULL` a `CHECK` níž. AFTER trigger by musel řádek přepisovat druhým
-- UPDATE a mezitím by v tabulce chvíli stála směna bez sazby.
--
-- POUZE INSERT. Na UPDATE se sazba nedopočítává schválně: uzavření směny
-- posílá `hourly_rate` z formuláře a dopočet by se s ním pral. A `NULL` při
-- UPDATE má skončit chybou (NOT NULL), ne tichým doplněním — kdo maže sazbu
-- u hotové směny, dělá něco, o čem má vědět.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_shift_rate()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _sazba numeric(10,2);
BEGIN
  -- Ruční sazba má přednost a NIKDY se nepřepisuje. Tohle je celá podstata
  -- „ručně přepsatelné" z R9 — a taky důvod, proč sloupec nesmí mít DEFAULT.
  IF NEW.hourly_rate IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.required_role IS NOT NULL THEN
    SELECT z.sazba INTO _sazba
      FROM public.sazby_roli z
     WHERE z.role = NEW.required_role;
  END IF;

  IF _sazba IS NULL THEN
    -- Sem se dostane směna bez role (starší cesta přes `events.required_staff`)
    -- nebo směna s rolí, která v ceníku není. To druhé dnes nastat nemá —
    -- ceník je uzavřený seznam — ale kdyby do `app_role` přibyla hodnota
    -- a někdo na ni založil směnu, ať to není tiché.
    IF NEW.required_role IS NOT NULL THEN
      RAISE WARNING 'Role % není v ceníku (sazby_roli), směna dostala záložní sazbu 150 Kč/h.', NEW.required_role;
    END IF;
    _sazba := 150;  -- táž hodnota, jakou měl dosud DEFAULT sloupce
  END IF;

  NEW.hourly_rate := _sazba;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_shift_rate() IS
  'Doplní shifts.hourly_rate z ceníku sazby_roli podle required_role, pokud volající sazbu nezadal. Snapshot — pozdější změna ceníku minulé směny nepřepočítá.';

-- Postgres dává na novou funkci `EXECUTE` roli `PUBLIC` automaticky a v Supabase
-- je `public` schéma vystavené přes PostgREST. U funkcí, které vracejí `trigger`,
-- to samo o sobě volat nejde — ale ponechaný grant je matoucí signál a u
-- `SECURITY DEFINER` funkcí se to nemá nechávat na tom, co PostgREST zrovna umí.
-- Trigger na EXECUTE nekouká: právo se ověřuje při `CREATE TRIGGER`, ne při
-- každém spuštění. Hlídá to vlastní tvrzení v testu.
REVOKE ALL ON FUNCTION public.set_shift_rate() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.write_audit_log_sazby_roli() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_sazby_roli_delete() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_sazby_roli_role() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_shifts_sazba ON public.shifts;
CREATE TRIGGER trg_shifts_sazba
  BEFORE INSERT ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.set_shift_rate();

-- -----------------------------------------------------------------------------
-- 6) Sloupec `shifts.hourly_rate`: default pryč, NOT NULL a rozsah dovnitř
--
-- POŘADÍ JE ZÁVAZNÉ: nejdřív ZKONTROLOVAT data, pak dorovnat NULLy, teprve pak
-- NOT NULL a CHECK. Obráceně migrace spadne na datech, která nikdo nezavinil,
-- a hláška neřekne na kterých.
--
-- PROČ NOT NULL: `useShifts.ts` počítá výdělky jako
-- `hours_worked * (hourly_rate || 150)`. Prázdná sazba se tam tedy tiše promění
-- ve 150 Kč/h a nikde to není vidět. `NOT NULL` z toho dělá chybu při zápisu
-- místo špatného čísla ve výplatě.
-- -----------------------------------------------------------------------------

-- 6a) PŘEDKONTROLA — rozpor se OHLÁSÍ, NEOPRAVUJE
--
-- Postup je převzatý z `20260813120000_strop_sazby.sql`: data se nejdřív
-- zkontrolují a případný rozpor se vypíše i s ukázkami; migrace ho ZÁMĚRNĚ
-- neopravuje, protože tiché přepsání peněžního údaje je horší než zastavená
-- migrace. Kdo uvidí hlášku, ví přesně, co má opravit.
--
-- Bez tohohle bloku by `ADD CONSTRAINT` na produkci spadl na
-- „check constraint … is violated by some row" — bez počtu a bez jediného ID.
-- A že takové řádky vzniknout MOHLY, říká komentář u constraintu níž: INSERT
-- dosud neměl na sazbu žádnou zábranu, takže 99 999 999 se dalo vložit rovnou.
DO $$
DECLARE _mimo int; _ukazky text;
BEGIN
  SELECT count(*) INTO _mimo FROM public.shifts
   WHERE hourly_rate IS NOT NULL AND (hourly_rate < 1 OR hourly_rate > 10000);

  IF _mimo > 0 THEN
    SELECT string_agg(format('%s (%s Kč/h)', id, hourly_rate), ', ')
      INTO _ukazky
      FROM (SELECT id, hourly_rate FROM public.shifts
             WHERE hourly_rate IS NOT NULL AND (hourly_rate < 1 OR hourly_rate > 10000)
             ORDER BY hourly_rate DESC LIMIT 5) u;
    RAISE EXCEPTION E'Migrace zastavena: % směn má sazbu mimo rozsah 1–10 000 Kč/h.\nUkázky: %\nOprav je ručně (je to peněžní údaj, migrace ho nepřepisuje) a spusť migraci znovu.',
      _mimo, _ukazky;
  END IF;
END $$;

-- 6b) DOROVNÁNÍ PRÁZDNÝCH SAZEB — na 150, ne z ceníku
--
-- ⚠️ TOHLE JE TO MÍSTO, KDE BY SE DALO NEJSNÁZ PŘEPSAT MINULOST, a proto se
-- tady ceník ZÁMĚRNĚ NEPOUŽÍVÁ.
--
-- Směna s prázdnou sazbou dnes v aplikaci figuruje jako **150 Kč/h** — přesně
-- tak ji počítá `useShifts.ts` (`hourly_rate || 150` na řádcích 524, 530, 539,
-- 560, 561 a 571). Kdyby ji migrace dorovnala z ceníku, uzavřená čtyřhodinová
-- směna trenéra by ze dne na den vyskočila ze 600 Kč na 2 400 Kč — a `payouts`
-- drží částku jako snapshot, takže výplata by pak říkala jiné číslo než směny
-- pod ní. Hlavička téhle migrace si přepočítávání minulosti sama zakazuje
-- (kapitola „VZOR JE reservations.rate_per_hour"); platí to i tady, o sto
-- řádků dál.
--
-- 150 je tedy STATUS QUO, ne odhad: je to táž hodnota, jakou měl dosud DEFAULT
-- sloupce i fallback v UI. Ceník se uplatní na směny, které vzniknou OD TEĎ.
--
-- Trigger `validate_shift_before_update` se na dobu dorovnání vypíná. Ne kvůli
-- sazbě — tu by pustil — ale proto, že týmž během validuje `hours_worked`
-- v rozsahu 0,1–24 h. Legacy řádek s 30 hodinami by shodil migraci o sazbách
-- hláškou o hodinách. Vzor je `20260731110000_booking_core.sql:190`, kde se
-- z téhož důvodu vypíná `trg_reservations_updated`.
--
-- VYPNUTÝ TRIGGER NEMŮŽE ZŮSTAT VISET, i kdyby migrace selhala mezi DISABLE
-- a ENABLE — proto je celé to trojčlení uvnitř JEDNOHO `DO` bloku. Ten je pro
-- Postgres jediný příkaz, takže se při chybě vrátí celý, DDL uvnitř včetně.
-- Ověřeno: po simulovaném `RAISE EXCEPTION` mezi DISABLE a ENABLE zůstal
-- `pg_trigger.tgenabled = 'O'`, tedy zapnutý.
--
-- `ALTER TABLE … DISABLE TRIGGER` navíc bere ACCESS EXCLUSIVE zámek, takže po
-- tu dobu do `shifts` nikdo jiný nezapíše — okno, kterým by prošel nevalidovaný
-- zápis odjinud, nevzniká.
DO $$
DECLARE _bez_sazby int; _po_statusech text;
BEGIN
  SELECT count(*) INTO _bez_sazby FROM public.shifts WHERE hourly_rate IS NULL;

  IF _bez_sazby = 0 THEN
    RAISE NOTICE 'Žádná směna nemá prázdnou sazbu — dorovnávat není co.';
  ELSE
    SELECT string_agg(format('%s: %s', status, pocet), ', ' ORDER BY status)
      INTO _po_statusech
      FROM (SELECT status, count(*) AS pocet FROM public.shifts
             WHERE hourly_rate IS NULL GROUP BY status) u;
    RAISE NOTICE 'Dorovnávám % směn s prázdnou sazbou na 150 Kč/h (status quo z UI). Po stavech: %',
      _bez_sazby, _po_statusech;

    ALTER TABLE public.shifts DISABLE TRIGGER validate_shift_before_update;
    UPDATE public.shifts SET hourly_rate = 150 WHERE hourly_rate IS NULL;
    ALTER TABLE public.shifts ENABLE TRIGGER validate_shift_before_update;
  END IF;
END $$;

ALTER TABLE public.shifts ALTER COLUMN hourly_rate DROP DEFAULT;
ALTER TABLE public.shifts ALTER COLUMN hourly_rate SET NOT NULL;

-- Rozsah 1–10 000 dosud hlídal jen trigger `validate_shift_claim`, a ten běží
-- POUZE NA UPDATE. INSERT tedy neměl žádnou zábranu: sazba 99 999 999 se dala
-- vložit rovnou a projevila by se až ve výplatě. CHECK platí na obě operace
-- a taky na `service_role`, na kterou se granty ani RLS nevztahují.
--
-- HALÉŘE SE ZÁMĚRNĚ NEZAKAZUJÍ, i když je ceník zakazuje. `useShifts.ts:244`
-- dopočítává sazbu zpátky z ručně zadané částky (`manualAmount / hoursWorked`),
-- takže nedělitelná částka vyrobí legitimní haléřovou sazbu. Kdo by to sem
-- „dorovnal" kvůli souladu s ceníkem, rozbil by ruční zadání částky u výplaty.
ALTER TABLE public.shifts DROP CONSTRAINT IF EXISTS shifts_hourly_rate_rozsah;
ALTER TABLE public.shifts ADD CONSTRAINT shifts_hourly_rate_rozsah
  CHECK (hourly_rate >= 1 AND hourly_rate <= 10000);

-- -----------------------------------------------------------------------------
-- 7) Kontrola, že to sedí — migrace si nemá jen přát
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _anon    int;
  _radku   int;
  _default text;
BEGIN
  -- Sloupcové granty, ne tabulkové: `GRANT SELECT (sazba) … TO anon` by
  -- `role_table_grants` minula, a je to nejtišší možná varianta úniku.
  SELECT count(*) INTO _anon FROM information_schema.column_privileges
   WHERE table_schema = 'public' AND table_name = 'sazby_roli'
     AND grantee IN ('anon', 'PUBLIC');
  IF _anon > 0 THEN
    RAISE EXCEPTION 'sazby_roli: anon/PUBLIC má práva na ceník (% sloupcových grantů).', _anon;
  END IF;

  IF has_table_privilege('authenticated', 'public.sazby_roli', 'INSERT')
     OR has_table_privilege('authenticated', 'public.sazby_roli', 'DELETE')
     OR has_table_privilege('authenticated', 'public.sazby_roli', 'TRUNCATE') THEN
    RAISE EXCEPTION 'sazby_roli: authenticated má víc než SELECT a UPDATE — ceník má být uzavřený seznam.';
  END IF;

  IF NOT has_column_privilege('authenticated', 'public.sazby_roli', 'sazba', 'UPDATE') THEN
    RAISE EXCEPTION 'sazby_roli: admin nemůže uložit sazbu.';
  END IF;
  -- A naopak: sloupce, které se měnit nemají, měnit nejdou.
  IF has_column_privilege('authenticated', 'public.sazby_roli', 'role', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.sazby_roli', 'updated_by', 'UPDATE') THEN
    RAISE EXCEPTION 'sazby_roli: UPDATE je širší, než má být (role/updated_by).';
  END IF;

  SELECT count(*) INTO _radku FROM public.sazby_roli;
  IF _radku < 5 THEN
    RAISE EXCEPTION 'sazby_roli: chybí sazby od PM (nalezeno % řádků).', _radku;
  END IF;

  -- Tohle je ta nejdůležitější kontrola celé migrace. S defaultem na sloupci
  -- by `set_shift_rate` nikdy nic nedoplnil a ceník by byl mrtvý kód, který
  -- vypadá živě.
  SELECT column_default INTO _default FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'shifts' AND column_name = 'hourly_rate';
  IF _default IS NOT NULL THEN
    RAISE EXCEPTION 'shifts.hourly_rate má pořád DEFAULT (%) — dopočet z ceníku se nikdy neuplatní.', _default;
  END IF;

  -- Kontrola na zbylé NULL sazby tu BÝVALA a byla nedosažitelná: `SET NOT NULL`
  -- výš spadne dřív, takže sem se s prázdnou sazbou nedá dojít. Nahrazuje ji
  -- tvrzení, které nedosažitelné není — že sloupec ty dvě zábrany opravdu má.
  IF (SELECT is_nullable FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'shifts'
         AND column_name = 'hourly_rate') <> 'NO' THEN
    RAISE EXCEPTION 'shifts.hourly_rate není NOT NULL — prázdná sazba se pak v UI tiše počítá jako 150.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.shifts'::regclass
                    AND conname = 'shifts_hourly_rate_rozsah') THEN
    RAISE EXCEPTION 'shifts: chybí CHECK na rozsah sazby — INSERT by zase neměl žádnou zábranu.';
  END IF;
END $$;
