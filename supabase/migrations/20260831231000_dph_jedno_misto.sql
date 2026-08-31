-- =============================================================================
-- DPH: jedno kritérium místo tří — `cena_bez_dph` jako snapshot
-- Nález z brány (ultra review, 31. 8. 2026) — MUST-FIX, peníze
-- =============================================================================
-- CO BYLO ŠPATNĚ:
--
-- Od přechodu na plátce znamená `reservations.amount` u každé rezervace něco
-- jiného — u klubového ceníku částku VČETNĚ daně, u komerční sazby ZÁKLAD.
-- Jenže KDO O TOM ROZHODUJE, si každá vrstva vykládala po svém:
--
--   • výběr sazby (`set_reservation_pricing`) …… podle TYPU AKCE i typu subjektu
--       (`WHEN _event_type = 'commercial' THEN _st.commercial_default_rate`)
--   • „Kdo kolik dluží" (`reservations_billing`) … podle TYPU SUBJEKTU
--       (`WHEN s.type = 'commercial'`)
--   • doklad (`mapping.ts`) ………………………………………… podle DRUHU DOKLADU
--       (`mapujKomercniAkci` → pricesIncludeVat: false)
--
-- Dokud typ subjektu a typ akce chodily spolu, sedělo to. Rozejdou se ale
-- jedním kliknutím, které přibylo 31. 8.: `zmen_typ_akce(klubová akce,
-- 'commercial')`. Pak:
--
--     4 h × 5 000 Kč/h (komerční sazba, BEZ DPH)  →  amount = 20 000
--     „Kdo kolik dluží"  ……  20 000   (subjekt je klub → bere to jako s daní)
--     doklad z Fakturoidu ……  22 400   (základ 20 000 + 12 %)
--
-- Rozdíl 2 400 Kč na akci — a rovnice „suma vystavených faktur == Kdo kolik
-- dluží", kterou CLAUDE.md dělá podmínkou mergu, neplatí.
--
-- Zrcadlově totéž obráceně: trénink KOMERČNÍHO subjektu se ocení komerční
-- sazbou (bez daně), ale na měsíční klubový doklad by šel jako částka s daní.
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ
-- -----------------------------------------------------------------------------
--   1. `cena_je_bez_dph(...)` — pravidlo NAPSANÉ JEDNOU.
--   2. `reservations.cena_bez_dph` — snapshot pořízený ve chvíli, kdy se
--      vybírá sazba. Jediné místo, které opravdu ví, kterou sazbu vzalo.
--   3. `reservations_billing.dluh` se ptá snapshotu, ne typu subjektu.
--   4. Obě fakturační podkladové funkce mají DAŇOVOU BRÁNU: doklad, jehož
--      režim neodpovídá snapshotu, se nevystaví vůbec.
--
-- Ceny se tím NEMĚNÍ. `amount` zůstává, jak bylo — mění se jen to, jak se
-- jeho daňový význam čte, a to na jednom místě pro všechny konzumenty.
--
-- ⚠️ OTÁZKA NA PM (nezáleží na ní správnost, jen výše ceny): má klub, který si
-- objedná KOMERČNÍ akci, platit komerčních 5 000 Kč/h? Dnes ano — a od téhle
-- migrace se mu k tomu aspoň správně připočte DPH. Kdyby měl platit klubový
-- ceník, je to jednořádková změna ve výběru sazby, ne v tomhle mechanismu.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   -- funkce zpátky ze ŽIVÉHO schématu (pg_get_functiondef):
--   --   set_reservation_pricing, fakturoid_podklady_akce, fakturoid_podklady_klub
--   -- pohled reservations_billing zpátky z 20260831090000_dluh_s_dph.sql
--   DROP FUNCTION IF EXISTS public.over_danovy_rezim_podkladu(uuid[], boolean, text);
--   DROP FUNCTION IF EXISTS public.cena_je_bez_dph(public.subject_type, public.event_type, numeric);
--   ALTER TABLE public.reservations DROP COLUMN IF EXISTS cena_bez_dph;
--   -- Data se neztrácejí: sloupec je odvozený, `amount` se nikde nepřepisuje.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Pravidlo napsané jednou
--
-- IMMUTABLE schválně: je to čistá funkce svých argumentů, žádné čtení tabulek.
-- Díky tomu se dá použít i v backfillu a v testech bez rizika, že se odpověď
-- mezi dvěma voláními změní.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cena_je_bez_dph(
  _subject_type   public.subject_type,
  _event_type     public.event_type,
  _sazba_subjektu numeric
)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $$
  SELECT CASE
    -- Bez subjektu není komu fakturovat, takže ani není daň.
    WHEN _subject_type IS NULL THEN false
    -- INDIVIDUÁLNÍ SAZBA SUBJEKTU PŘEBÍJÍ TYP AKCE. Dohodnutá cena je dohoda
    -- s TÍM zákazníkem — u firmy bez daně, u klubu s daní — a nemění význam
    -- podle toho, jak se akce jmenuje.
    WHEN _sazba_subjektu IS NOT NULL THEN _subject_type = 'commercial'
    -- Jinak rozhoduje sazba, kterou vybere `set_reservation_pricing`:
    -- `commercial_default_rate` je vedená BEZ DPH, klubový ceník S DPH.
    ELSE _subject_type = 'commercial'
         OR COALESCE(_event_type, 'training') IN ('commercial', 'recruitment')
  END;
$$;

COMMENT ON FUNCTION public.cena_je_bez_dph(public.subject_type, public.event_type, numeric) IS
  'Je `amount` u takové rezervace ZÁKLAD DANĚ (true), nebo částka VČETNĚ DPH (false)? Zrcadlí výběr sazby v set_reservation_pricing: commercial_default_rate je bez daně, klubový ceník (cenik_pasma i club_default_rate) s daní. Jediné místo, kde je tohle pravidlo napsané — dřív si ho každá vrstva odvozovala po svém a kontrolní součet se rozešel o sazbu DPH.';

REVOKE ALL ON FUNCTION public.cena_je_bez_dph(public.subject_type, public.event_type, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cena_je_bez_dph(public.subject_type, public.event_type, numeric) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2) Snapshot na rezervaci
-- -----------------------------------------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS cena_bez_dph boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.reservations.cena_bez_dph IS
  'Je `amount` základ daně (true), nebo částka včetně DPH (false)? Snapshot z okamžiku, kdy se vybírala sazba — plní ho výhradně trigger set_reservation_pricing, na vstupu se hodnota zahazuje (tabulkový UPDATE grant by ji jinak pustil komukoli). Čte ho „Kdo kolik dluží" i daňová brána fakturačních podkladů.';

-- BACKFILL. Bere DNEŠNÍ typ subjektu, typ akce a sazbu subjektu — u historických
-- rezervací je to nejlepší dostupný odhad, ne pravda o okamžiku vzniku. Pro
-- kontrolní součet to stačí: rozejít se mohly jen rezervace, kde se typ akce
-- rozchází s typem subjektu, a těch je dnes hrstka.
--
-- Trigger `set_reservation_pricing` se tím nespouští (UPDATE by přepsal
-- `cena_bez_dph` zpátky na OLD, což je právě to, co teď nastavujeme) —
-- proto přímý UPDATE s vypnutými triggery, jako to dělá `booking_core`
-- u otevírací doby.
ALTER TABLE public.reservations DISABLE TRIGGER USER;
UPDATE public.reservations r
   SET cena_bez_dph = public.cena_je_bez_dph(
         (SELECT s.type         FROM public.subjects s WHERE s.id = r.subject_id),
         (SELECT e.event_type   FROM public.events   e WHERE e.id = r.event_id),
         (SELECT s.default_rate FROM public.subjects s WHERE s.id = r.subject_id));
ALTER TABLE public.reservations ENABLE TRIGGER USER;

-- -----------------------------------------------------------------------------
-- 3) Daňová brána pro fakturační podklady
--
-- Vlastní funkce, ne dvě kopie podmínky: obě podkladové funkce se ptají téhož
-- a hlásit to musí stejně. `_ceka_bez_dph` říká, co ten DRUH DOKLADU o cenách
-- tvrdí Fakturoidu (`pricesIncludeVat`).
--
-- U NEPLÁTCE se brána neuplatní — tam žádná daň není a obě čtení `amount`
-- splývají. Kdyby fungovala i tam, zablokovala by fakturaci na demu.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.over_danovy_rezim_podkladu(
  _rezervace     uuid[],
  _ceka_bez_dph  boolean,
  _popis_dokladu text
)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE _spatne int; _prvni uuid;
BEGIN
  IF COALESCE((SELECT bs.vat_mode FROM public.billing_settings bs WHERE bs.singleton), 'neplatce')
     = 'neplatce' THEN
    RETURN;
  END IF;

  SELECT count(*), min(r.id::text)::uuid INTO _spatne, _prvni
    FROM public.reservations r
   WHERE r.id = ANY (_rezervace)
     AND r.cena_bez_dph IS DISTINCT FROM _ceka_bez_dph;

  IF _spatne > 0 THEN
    RAISE EXCEPTION
      '% by míchal ceny s DPH a bez DPH (% z % rezervací je vedená opačně, např. %).',
      _popis_dokladu, _spatne, cardinality(_rezervace), _prvni
      USING HINT = 'Zkontroluj typ akce a typ odběratele. Komerční sazba je bez daně, klubový ceník s daní — na jeden doklad patří jen jedno z toho.';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.over_danovy_rezim_podkladu(uuid[], boolean, text) IS
  'Hlídá, že se na jeden doklad nedostanou rezervace se dvěma daňovými významy `amount`. Doklad za akci jde do Fakturoidu jako ceny BEZ DPH, měsíční klubový jako ceny S DPH — a `cena_bez_dph` na rezervaci říká, co je pravda. U neplátce nedělá nic.';

REVOKE ALL ON FUNCTION public.over_danovy_rezim_podkladu(uuid[], boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.over_danovy_rezim_podkladu(uuid[], boolean, text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4) Trigger plní snapshot
--
-- Tělo z `pg_get_functiondef` živého schématu (pravidlo 7). Zásahy jsou čtyři
-- a všechny jen přiřazují `cena_bez_dph`: sanitizace vstupu, větev bez
-- subjektu, pásmová větev a sazbová větev.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_reservation_pricing()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _rate         numeric;
  _subject_rate numeric;
  _subject_type public.subject_type;
  _event_type   public.event_type;
  _st           public.settings%ROWTYPE;
  _cena         numeric;
  _rozpis       jsonb;
BEGIN
  -- `cenove_pasma` JE ODVOZENÁ HODNOTA, NE VSTUP.
  --
  -- `reservations` má tabulkové INSERT/UPDATE granty, takže nový sloupec je pro
  -- `authenticated` rovnou zapisovatelný. Podstrčený rozpis by přitom rozhodoval
  -- o tom, co se vyfakturuje, tak se na vstupu zahazuje a plní ho jen tenhle
  -- trigger.
  --
  -- A pozor na `'null'::jsonb`: to NENÍ SQL NULL, takže `cenove_pasma IS NULL`
  -- je u něj false — a tím by vypnul pravidlo o celých korunách i dopočet
  -- `amount`. Ověřeno: rezervace se sazbou 1 234,56 Kč/h a `amount = NULL`
  -- takhle prošla. Proto se netestuje NULL, ale jestli je to vůbec pole.
  IF TG_OP = 'INSERT' OR jsonb_typeof(NEW.cenove_pasma) IS DISTINCT FROM 'array' THEN
    NEW.cenove_pasma := NULL;
  END IF;

  -- `cena_bez_dph` JE TAKY ODVOZENÁ HODNOTA, NE VSTUP — a ze všech tří je
  -- nejcitlivější: rozhoduje, jestli je `amount` základ daně, nebo částka
  -- s daní. Podstrčená hodnota by posunula dluh o celou sazbu DPH.
  --
  -- Na INSERTu ji vždycky přepíše větev, která vybírá sazbu (níž). Na UPDATE
  -- se DRŽÍ STARÁ, protože je to snapshot ze stejné chvíle jako sazba — mimo
  -- přecenění (`app.preceneni`), kde se spolu se sazbou přepočítá i tahle.
  IF TG_OP = 'UPDATE'
     AND COALESCE(current_setting('app.preceneni', true), 'off') <> 'on' THEN
    NEW.cena_bez_dph := OLD.cena_bez_dph;
  END IF;

  IF NEW.subject_id IS NULL THEN
    NEW.rate_per_hour    := NULL;
    NEW.amount           := NULL;
    NEW.corrected_amount := NULL;
    -- Není komu fakturovat (interní trénink, údržba), takže není ani daň.
    NEW.cena_bez_dph     := false;
    NEW.hours := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    RETURN NEW;
  END IF;

  -- Snapshot sazby jen při vzniku; pozdější změna ceníku nepřepočítává minulé rezervace.
  -- PŘECENĚNÍ PŘI ZMĚNĚ TYPU AKCE.
  --
  -- Cena se normálně počítá jen při vzniku rezervace — snapshot se pak nemá
  -- kam hnout. Když ale admin změní TYP akce (trénink ↔ komerční ↔ turnaj),
  -- musí se cena přepočítat, protože každý typ se oceňuje jinak.
  --
  -- Otevírá se to jen na výslovné vyžádání přes `app.preceneni`, ne plošně:
  -- kdyby se přepočítávalo při každém UPDATE, posunula by se částka i u akce,
  -- na kterou se jen sáhlo — a to na dokladu, který už mohl odejít.
  -- Nastavuje ho `zmen_typ_akce()`, jinde se nepoužívá.
  IF (TG_OP = 'INSERT'
      OR COALESCE(current_setting('app.preceneni', true), 'off') = 'on')
     AND NEW.rate_per_hour IS NULL THEN
    SELECT s.default_rate, s.type INTO _subject_rate, _subject_type
      FROM public.subjects s WHERE s.id = NEW.subject_id;
    SELECT * INTO _st FROM public.settings LIMIT 1;

    IF NEW.event_id IS NOT NULL THEN
      SELECT e.event_type INTO _event_type FROM public.events e WHERE e.id = NEW.event_id;
    END IF;

    -- PÁSMOVÝ CENÍK — jen pro KLUBY a jen když nemají vlastní sazbu.
    --
    -- Komerční zákazník má dál jednu sazbu (rozhodnutí PM: 5 000 Kč/h bez DPH),
    -- takže se pásem netýká. A `subjects.default_rate` má přednost před vším —
    -- individuálně dohodnutá cena je dohoda, ne ceník.
    IF _subject_type = 'club' AND _subject_rate IS NULL
       AND COALESCE(_event_type, 'training') <> 'commercial'
       AND COALESCE(_event_type, 'training') <> 'recruitment' THEN
      SELECT c.castka, c.rozpis INTO _cena, _rozpis
        FROM public.cena_ledu(NEW.start_at, NEW.end_at) c;

      NEW.cenove_pasma := _rozpis;
      -- Klubový ceník (`cenik_pasma`) je vedený VČETNĚ DPH — `amount` je tedy
      -- konečná částka, ne základ.
      NEW.cena_bez_dph := false;
      NEW.amount       := _cena;
      NEW.hours        := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
      -- `rate_per_hour` je u pásmové ceny ODVOZENÝ PRŮMĚR, ne vstup. Autoritativní
      -- je `amount` a `cenove_pasma`; tohle číslo je do přehledů a na starý kód,
      -- který sazbu čte. Proto smí mít haléře — a proto se z něj částka NEPOČÍTÁ.
      NEW.rate_per_hour := round(_cena / NULLIF(NEW.hours, 0), 2);
      NEW.corrected_amount := CASE
        WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
        ELSE NULL END;
      RETURN NEW;
    END IF;

    -- Komerční zákazník se účtuje komerční sazbou i u turnaje/tréninku — jinak by
    -- firma jezdila za klubovou cenu jen proto, že se akce jmenuje „turnaj".
    _rate := COALESCE(
      _subject_rate,
      CASE
        WHEN _subject_type = 'commercial' THEN _st.commercial_default_rate
        WHEN _event_type = 'commercial'   THEN _st.commercial_default_rate
        WHEN _event_type = 'recruitment'  THEN _st.commercial_default_rate
        WHEN _event_type = 'tournament'   THEN COALESCE(_st.tournament_rate, _st.club_default_rate)
        WHEN _event_type = 'training'     THEN COALESCE(_st.training_rate, _st.club_default_rate)
        ELSE _st.club_default_rate
      END,
      -- akce bez vlastní sazby (např. údržba s fakturačním subjektem) → podle typu subjektu
      CASE _subject_type WHEN 'commercial' THEN _st.commercial_default_rate
                         ELSE _st.club_default_rate END
    );

    IF _rate IS NULL THEN
      RAISE EXCEPTION 'Sazba není nastavena — admin musí nejdřív vyplnit ceník (Nastavení) nebo sazbu subjektu';
    END IF;
    NEW.rate_per_hour := _rate;
    -- DAŇOVÝ VÝZNAM `amount` SE SNAPSHOTUJE SPOLU SE SAZBOU.
    --
    -- Je to jediné místo, které ví, KTEROU sazbu právě vybralo — a tím pádem
    -- jediné, které umí říct, jestli je v ní daň. Odvozovat to potom z typu
    -- subjektu (jak to dělal `dluh`) nebo z typu akce (jak to dělá výběr sazby)
    -- znamená dvě různá kritéria nad jedním číslem; přesně tím se kontrolní
    -- součet rozešel o 12 % u komerční akce na klubovém subjektu.
    NEW.cena_bez_dph := public.cena_je_bez_dph(_subject_type, _event_type, _subject_rate);
  END IF;

  -- RUČNÍ SAZBA PŘEBÍJÍ PÁSMA.
  --
  -- Když admin u pásmové rezervace vědomě přepíše `rate_per_hour`, je to dohoda
  -- s klubem a má vyhrát. Bez tohohle by se `amount` NEPŘEPOČÍTALO (viz níž) a
  -- systém by vyfakturoval starou částku: sazba v UI 900 Kč/h, na faktuře
  -- pořád 3 400 Kč místo 2 700. Tichý rozdíl mezi zobrazenou a fakturovanou
  -- cenou je to nejhorší, co může peněžní vrstva udělat.
  --
  -- Rozpis se proto zahodí — přestal cenu popisovat — a dál se rezervace chová
  -- jako každá jiná s ruční sazbou, včetně pravidla o celých korunách.
  IF TG_OP = 'UPDATE' AND NEW.cenove_pasma IS NOT NULL
     AND NEW.rate_per_hour IS DISTINCT FROM OLD.rate_per_hour
     AND NEW.cenove_pasma IS NOT DISTINCT FROM OLD.cenove_pasma THEN
    NEW.cenove_pasma := NULL;
  END IF;

  -- PŘESUN NEBO PRODLOUŽENÍ PÁSMOVÉ REZERVACE JI PŘECENÍ.
  --
  -- Snapshot ceny platí pro ČAS, na který byl pořízený. Když rezervace 16–19
  -- (3 400 Kč) přejede na 9–12, je to ranní led za 2 400 Kč — držet dál starou
  -- částku znamená přeúčtovat klubu 1 000 Kč. A kdyby se změnila jen délka,
  -- rozešel by se rozpis s hodinami a doklad by se vůbec nedal vystavit
  -- (`mapping.ts` takovou rezervaci odmítne).
  --
  -- Přeceňuje se podle PLATNÉHO ceníku — na nový čas žádný jiný neexistuje.
  -- Je to táž úvaha jako u nepásmové rezervace, které se při změně délky taky
  -- přepočítá `amount`; jen tady je vstupem rozpis, ne sazba.
  IF TG_OP = 'UPDATE' AND NEW.cenove_pasma IS NOT NULL
     AND (NEW.start_at, NEW.end_at) IS DISTINCT FROM (OLD.start_at, OLD.end_at) THEN
    SELECT c.castka, c.rozpis INTO _cena, _rozpis
      FROM public.cena_ledu(NEW.start_at, NEW.end_at) c;

    NEW.cenove_pasma  := _rozpis;
    NEW.amount        := _cena;
    NEW.hours         := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    NEW.rate_per_hour := round(_cena / NULLIF(NEW.hours, 0), 2);
    NEW.corrected_amount := CASE
      WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
      ELSE NULL END;
    RETURN NEW;
  END IF;

  IF NEW.rate_per_hour IS NULL THEN
    RAISE EXCEPTION 'Sazba (rate_per_hour) nesmí zůstat prázdná';
  END IF;

  NEW.hours  := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);

  -- U PÁSMOVÉ CENY SE `amount` NEPŘEPOČÍTÁVÁ. `hodiny × rate_per_hour` by dalo
  -- jiné číslo než snapshot rozpisu (průměr je zaokrouhlený na haléře), takže
  -- by každý UPDATE rezervace tiše posunul částku — třeba jen o pár haléřů,
  -- ale na dokladu, který už mohl odejít.
  IF NEW.cenove_pasma IS NULL THEN
    NEW.amount := round(NEW.hours * NEW.rate_per_hour, 2);
  END IF;
  NEW.corrected_amount := CASE
    WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
    ELSE NULL END;

  RETURN NEW;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5) „Kdo kolik dluží" se ptá snapshotu
--
-- DROP + CREATE, protože `CREATE OR REPLACE VIEW` neumí měnit nic než tělo
-- sloupců, a chceme mít jistotu, že pohled odpovídá téhle migraci. Znění je
-- převzaté z 20260831090000_dluh_s_dph.sql; JEDINÝ zásah je podmínka u `dluh`
-- (`s.type = 'commercial'` → `r.cena_bez_dph`).
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.reservations_billing;
CREATE VIEW public.reservations_billing
  WITH (security_invoker = off) AS
  SELECT
    r.id, r.subject_id, s.name AS subject_name, s.type AS subject_type,
    r.sheet_id, sh.name AS sheet_name,
    r.start_at, r.end_at,
    r.hours, r.rate_per_hour, r.amount,
    r.corrected_hours, r.corrected_amount, r.correction_reason,
    r.note, e.title AS event_title, e.event_type,
    r.created_by, cp.full_name AS created_by_name,

    COALESCE(r.corrected_amount, r.amount) AS dluh_zaklad,

    -- SKUTEČNÝ DLUH.
    --
    -- Ptá se SNAPSHOTU na rezervaci, ne typu subjektu. Typ subjektu byl špatné
    -- kritérium: komerční sazbu (bez daně) dostane i klub, když má akce typ
    -- `commercial` — a pak se dluh a doklad rozešly přesně o sazbu DPH.
    --
    -- Zaokrouhluje se NA HALÉŘE a po řádcích, ne až na součtu: kanonické
    -- pravidlo R3. Na celé koruny se zaokrouhluje až částka k úhradě na
    -- dokladu, ne tady.
    CASE
      WHEN r.cena_bez_dph
       AND COALESCE((SELECT bs.vat_mode FROM public.billing_settings bs WHERE bs.singleton),
                    'neplatce') <> 'neplatce'
        THEN round(COALESCE(r.corrected_amount, r.amount)
                   * (1 + COALESCE((SELECT bs.vat_rate_ice FROM public.billing_settings bs
                                     WHERE bs.singleton), 0) / 100), 2)
      ELSE COALESCE(r.corrected_amount, r.amount)
    END AS dluh

  FROM public.reservations r
  JOIN public.subjects s    ON s.id  = r.subject_id
  JOIN public.sheets   sh   ON sh.id = r.sheet_id
  LEFT JOIN public.events   e  ON e.id = r.event_id
  LEFT JOIN public.profiles cp ON cp.user_id = r.created_by
  WHERE r.status = 'confirmed'
    AND r.deleted_at IS NULL
    AND has_role(auth.uid(), 'admin');

REVOKE ALL ON public.reservations_billing FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.reservations_billing TO authenticated;

COMMENT ON VIEW public.reservations_billing IS
  'Podklad pro „Kdo kolik dluží". `amount` je snapshot z rezervace a pod DPH znamená podle `cena_bez_dph` buď základ daně, nebo částku s daní — sčítat ho napříč tím tedy míchá jablka s hruškami. Na to je `dluh`: skutečná částka, kterou zákazník dluží. `dluh_zaklad` je totéž bez daně.';

-- -----------------------------------------------------------------------------
-- 6) Podklady pro doklady: daňová brána + akce zadarmo
--
-- Těla z živého schématu; zásahy jsou volání brány v obou a filtr nulové ceny
-- v `fakturoid_podklady_akce` (klubová cesta ho má od 20260831220000).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fakturoid_podklady_akce(_event uuid)
 RETURNS TABLE(id uuid, start_at timestamp with time zone, end_at timestamp with time zone, sheet_name text, event_title text, hodiny numeric, sazba numeric, castka numeric, subject_id uuid, cenove_pasma jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _ids uuid[];
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturační podklady.';
  END IF;

  -- CO SE BUDE FAKTUROVAT — jednou, do `_ids`.
  --
  -- Podmínky jsou tytéž jako dřív, jen přesunuté sem, aby je daňová brána níž
  -- hlídala nad TÝMŽ výběrem, který se opravdu vrátí. Kdyby si skládala
  -- vlastní, časem by se s dotazem rozešla a hlídala by něco jiného.
  --
  -- Nově je mezi nimi i filtr NULOVÉ CENY. Bez něj byla akce zadarmo
  -- nefakturovatelná jen na klubové cestě (`fakturovatelne_rezervace`) a na
  -- komerční projela: Fakturoid dostal koncept s `unitPrice 0` a spálil číslo
  -- v číselné řadě. Vynechává se JEN cena zadarmo, ne nulová korekce
  -- („nedorazili") — na tu má narazit guard při vystavení, ne tichý filtr.
  SELECT array_agg(r.id ORDER BY r.start_at, r.id) INTO _ids
    FROM public.reservations r
   WHERE r.event_id = _event
     AND r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND r.subject_id IS NOT NULL
     AND (r.approved_at IS NOT NULL
          OR NOT COALESCE((SELECT bs.invoice_only_approved FROM public.billing_settings bs LIMIT 1), true))
     AND NOT EXISTS (
           SELECT 1 FROM public.fakturoid_invoice_reservations fr
            WHERE fr.reservation_id = r.id
         )
     AND NOT (COALESCE(r.corrected_amount, r.amount, 0) = 0
              AND r.corrected_amount IS NULL);

  IF _ids IS NULL THEN
    RETURN;   -- není co fakturovat; brána nemá co hlídat
  END IF;

  -- DAŇOVÁ BRÁNA. Doklad za akci jde do Fakturoidu s `pricesIncludeVat: false`,
  -- takže KAŽDÝ jeho řádek musí být základ daně. Rezervace oceněná klubovým
  -- ceníkem (ten je vedený S daní) by se na něm zdanila podruhé.
  -- Radši nevystavit než vystavit špatně — rozdíl by se jinak objevil až jako
  -- rozpor s „Kdo kolik dluží", tedy dávno po odeslání dokladu.
  PERFORM public.over_danovy_rezim_podkladu(_ids, true, 'Doklad za akci');

  RETURN QUERY
    SELECT r.id, r.start_at, r.end_at, sh.name, e.title,
           COALESCE(r.corrected_hours, r.hours),
           r.rate_per_hour,
           COALESCE(r.corrected_amount, r.amount),
           r.subject_id,
           -- Komerční akce pásma nemá (ocenění je z nich vyloučené), ale sloupec
           -- tu je schválně: kdyby se pásma někdy pustila i na akce, tahle cesta
           -- nesmí být ta, která o rozpis tiše přijde.
           CASE WHEN r.corrected_hours IS NULL THEN r.cenove_pasma ELSE NULL END
      FROM public.reservations r
      JOIN public.sheets sh ON sh.id = r.sheet_id
      JOIN public.events e  ON e.id = r.event_id
     WHERE r.id = ANY (_ids)
     ORDER BY r.start_at, r.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fakturoid_podklady_klub(_subject uuid, _od date, _do date)
 RETURNS TABLE(id uuid, start_at timestamp with time zone, end_at timestamp with time zone, sheet_name text, event_title text, hodiny numeric, sazba numeric, castka numeric, cenove_pasma jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _zac timestamptz; _kon timestamptz; _ids uuid[];
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturační podklady.';
  END IF;

  -- Období v PRAŽSKÉM čase, jedním sdíleným místem. Kdyby si to tahle cesta
  -- počítala po svém, „srpen" pro Fakturoid a „srpen" pro kontrolní součet
  -- by se rozešly o dvě hodiny — a projevilo by se to jen u rezervací kolem
  -- půlnoci na přelomu měsíce, tedy tam, kde si toho nikdo nevšimne.
  SELECT h.zacatek, h.konec INTO _zac, _kon FROM public.obdobi_hranice(_od, _do) h;

  -- DAŇOVÁ BRÁNA, zrcadlově k `fakturoid_podklady_akce`. Měsíční klubový doklad
  -- jde do Fakturoidu s `pricesIncludeVat: true`, takže na něm nesmí být
  -- rezervace oceněná komerční sazbou (ta je vedená BEZ daně) — jinak by hala
  -- odvedla daň z částky, kterou nevybrala.
  --
  -- Výběr řádků je týž, jaký se o pár řádků níž vrací: `fakturovatelne_rezervace`
  -- minus ty, co už na dokladu jsou.
  SELECT array_agg(f.id) INTO _ids
    FROM public.fakturovatelne_rezervace(_subject, _zac, _kon) f
   WHERE NOT EXISTS (
           SELECT 1 FROM public.fakturoid_invoice_reservations fr
            WHERE fr.reservation_id = f.id
         );

  IF _ids IS NULL THEN
    RETURN;   -- za období není co fakturovat
  END IF;

  PERFORM public.over_danovy_rezim_podkladu(_ids, false, 'Měsíční klubový doklad');

  RETURN QUERY
    SELECT f.id, f.start_at, f.end_at, f.sheet_name, f.event_title,
           f.hodiny, f.sazba, f.castka,
           -- ROZPIS JEN BEZ KOREKCE. `f.castka` i `f.hodiny` jsou u opravené
           -- rezervace z korekce, takže na původní rozpis (3 h / 3 400 Kč) už
           -- nesedí a mapovací vrstva by doklad odmítla. Bez rozpisu se řádek
           -- složí z `hodiny × sazba` nad odvozeným průměrem, což u korekce
           -- vyjde přesně — je to totiž tatáž hodnota, ze které ji spočítal
           -- trigger.
           CASE WHEN r.corrected_hours IS NULL THEN r.cenove_pasma ELSE NULL END
      FROM public.fakturovatelne_rezervace(_subject, _zac, _kon) f
      JOIN public.reservations r ON r.id = f.id
     -- Týž výběr, který prošel bránou výš — proto `_ids`, ne druhá kopie
     -- podmínky „ještě není na dokladu".
     WHERE f.id = ANY (_ids)
     ORDER BY f.start_at, f.id;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 7) Kontrola
-- -----------------------------------------------------------------------------
DO $kontrola$
DECLARE _mimo int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = 'public.reservations'::regclass
                    AND attname = 'cena_bez_dph' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'Sloupec reservations.cena_bez_dph chybí.';
  END IF;

  IF pg_get_viewdef('public.reservations_billing'::regclass) NOT LIKE '%cena_bez_dph%' THEN
    RAISE EXCEPTION 'reservations_billing se pořád ptá typu subjektu, ne snapshotu.';
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.fakturoid_podklady_akce(uuid)'::regprocedure)
     NOT LIKE '%over_danovy_rezim_podkladu%' THEN
    RAISE EXCEPTION 'Daňová brána chybí ve fakturoid_podklady_akce.';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.fakturoid_podklady_klub(uuid,date,date)'::regprocedure)
     NOT LIKE '%over_danovy_rezim_podkladu%' THEN
    RAISE EXCEPTION 'Daňová brána chybí ve fakturoid_podklady_klub.';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.fakturoid_podklady_akce(uuid)'::regprocedure)
     NOT LIKE '%corrected_amount IS NULL%' THEN
    RAISE EXCEPTION 'Filtr akcí zdarma chybí ve fakturoid_podklady_akce.';
  END IF;

  -- Backfill musí sedět na pravidlo — kdyby ne, „Kdo kolik dluží" by lhalo
  -- hned od první minuty. Porovnává se proti témuž pravidlu, ne proti kopii.
  SELECT count(*) INTO _mimo
    FROM public.reservations r
   WHERE r.deleted_at IS NULL
     AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(
           (SELECT s.type         FROM public.subjects s WHERE s.id = r.subject_id),
           (SELECT e.event_type   FROM public.events   e WHERE e.id = r.event_id),
           (SELECT s.default_rate FROM public.subjects s WHERE s.id = r.subject_id));
  IF _mimo > 0 THEN
    RAISE EXCEPTION 'Backfill cena_bez_dph nesedí u % rezervací.', _mimo;
  END IF;

  RAISE NOTICE 'Daňový význam ceny má jedno místo (cena_bez_dph) a fakturační podklady mají bránu.';
END $kontrola$;
