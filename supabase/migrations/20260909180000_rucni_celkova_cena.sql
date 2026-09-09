-- Ruční celková cena akce (trénink a turnaj), zadává jen admin
-- ---------------------------------------------------------------------------
-- Jakub účtuje turnaj paušálem za den (14 000 za obě dráhy), ne za hodinu.
-- Dosud to nešlo zadat: pole „Celková cena" existovalo jen u komerce a bylo to
-- POUZE KALKULAČKA VE FRONTENDU — přepočítala částku na hodinovou sazbu, tu
-- poslala do `create_booking` a `amount` se pak zpátky dopočítalo jako
-- `hodiny × sazba`. Protože sazba musí být na celé koruny, spousta částek nešla
-- zadat vůbec: 14 000 na 13 h × 2 dráhy je 538,46 Kč/h → databáze to odmítla.
-- Změřeno: 15 z 23 turnajových dnů na produkci nešlo naúčtovat přesně.
--
-- Nově se celková částka posílá jako částka a ukládá NAPEVNO. Mechanismus není
-- nový — přesně takhle se už dnes chová pásmová cena: `amount` je autoritativní,
-- `rate_per_hour` je jen odvozený průměr (a smí mít haléře) a nic ho
-- nepřepočítává. Tady se totéž otevírá pro ručně zadanou částku.
--
-- CO SE NEMĚNÍ:
--   • Když admin nic nezadá, běží dnešní chování (pásma / sazby z ceníku).
--   • Komerce se nemění vůbec.
--   • Sazbu i částku smí zadat JEN admin. Neadminovi se obojí zahazuje
--     v `create_booking` a cenu spočítá engine.
--
-- JAK TO VRÁTIT ZPÁTKY — POŘADÍ JE ZÁVAZNÉ.
--
-- ⚠️ NEZAČÍNAT DROPNUTÍM SLOUPCE. `check_reservation_money` i guard níž čtou
-- `NEW.cena_rucni` při KAŽDÉM zápisu do rezervací, takže po samotném
-- `DROP COLUMN` skončí každý zápis na „record „new" has no field „cena_rucni""
-- (SQLSTATE 42703) — nejde založit, upravit ani zrušit žádná placená rezervace.
-- Ověřeno spuštěním, ne odhadem.
--
--   1) zahodit funkce, které tahle migrace zakládá v NOVÉ signatuře — jinak
--      z nich `CREATE OR REPLACE` níž udělá PŘETÍŽENÍ, ne návrat:
--        DROP FUNCTION public.create_booking(uuid[],text,text,timestamptz,
--              timestamptz,uuid,text,jsonb,numeric,boolean,uuid,numeric);
--        DROP FUNCTION public.fakturoid_podklady_akce(uuid);
--        DROP FUNCTION public.fakturoid_podklady_klub(uuid,date,date);
--   2) obnovit z předchozích migrací VŠECH PĚT přepsaných funkcí:
--        `set_reservation_pricing`, `check_reservation_money`  ← na tuhle se
--            zapomínalo; bez ní krok 3 zastaví provoz (viz výš)
--        `create_booking` (11 parametrů), `fakturoid_podklady_akce`,
--        `fakturoid_podklady_klub` (v původních návratových typech)
--
--      A KE VŠEM TŘEM DROPNUTÝM FUNKCÍM ZNOVU PUSTIT GRANTY:
--        REVOKE ALL ON FUNCTION <fn> FROM PUBLIC, anon;
--        GRANT EXECUTE ON FUNCTION <fn> TO authenticated, service_role;
--      Zdrojové migrace je NEOBSAHUJÍ — `create_booking` je naposledy
--      definovaná v `20260817100000_serie_kolize.sql` a podklady
--      v `20260831231000_dph_jedno_misto.sql`; ani jedna z nich REVOKE nenese.
--      Protože je krok 1 nejdřív dropne, je obnova čerstvý `CREATE` a uplatní
--      se `ALTER DEFAULT PRIVILEGES`, které dává `anon` EXECUTE. Bez téhle
--      věty by rollback `anon` ty peněžní funkce otevřel — přesně tu obranu,
--      kterou tahle migrace níž zavírá.
--
--      POZOR NA ZDROJ PODKLADŮ: ber je z `20260831231000_dph_jedno_misto.sql`,
--      NE ze starších `20260824120000` / `20260831110000`. Ty starší REVOKE
--      sice mají (takže by se grant obnovil správně a na chybu by nic
--      neupozornilo), ale nesou STARŠÍ TĚLO — bez daňové brány
--      `over_danovy_rezim_podkladu`, bez výběru přes `_ids` a bez filtru
--      nulové ceny. Rollback by tím tiše vrátil dvě pozdější opravy
--      fakturace. (Obojí nález brány migrací.)
--   3) obnovit ŠEST RPC, do kterých sekce 6 vložila guard pevné ceny — všechny
--      z posledních migrací, které je definují (signatury se nemění, takže
--      stačí `CREATE OR REPLACE` a granty zůstanou):
--        `uprav_sazbu_akce`, `zmen_typ_akce`, `uprav_drahy_akce`,
--        `move_booking`, `update_booking`, `cancel_booking`
--      Guard není trigger, je vložený v tělech těchto funkcí — nic se nedropuje.
--   4) `ALTER TABLE public.reservations DROP COLUMN cena_rucni;`
--      Pozor: vezme s sebou OBA CHECKy (`reservations_rate_per_hour_cele_koruny`
--      i `reservations_rucni_cena_smysluplna`), takže tabulka mezi krokem 4 a 5
--      nemá o celých korunách žádné pravidlo.
--   5) vrátit CHECK `reservations_rate_per_hour_cele_koruny` do původního znění
--      (viz `20260831110000_cenik_pasma.sql`)
--
--   Pozor: krok 4 zahodí informaci, že cena byla ruční — u rezervací, které ji
--   mají, se pak `amount` při další úpravě přepočítá z hodin a sazby.
-- ---------------------------------------------------------------------------

-- ---- 1) Příznak „částku zadal člověk" -------------------------------------
-- Bez příznaku by ruční částku nešlo odlišit od dopočítané a `amount` by se při
-- první úpravě rezervace tiše přepsalo na `hodiny × sazba`.
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS cena_rucni boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.reservations.cena_rucni IS
  'true = `amount` zadal ručně admin jako celkovou cenu akce a nesmí se dopočítávat '
  'z hodin a sazby ani přepisovat pásmy. `rate_per_hour` je u takové rezervace jen '
  'odvozený průměr (smí mít haléře). Odvozená hodnota, ne vstup — plní ji výhradně '
  'trigger set_reservation_pricing přes marker app.rucni_cena.';

-- ---- 2) Haléře v odvozené sazbě ------------------------------------------
-- Pravidlo „sazba se zadává v celých korunách" platí dál pro sazbu, kterou
-- admin doopravdy zadává. U ruční CELKOVÉ ceny je ale `rate_per_hour` jen
-- odvozený průměr (`amount / hodiny`), který na celé koruny vyjít nemusí —
-- 14 000 na 13 h je 1 076,923… Kč/h. Přesně tuhle výjimku už má pásmová cena;
-- tady se rozšiřuje o ruční částku.
--
-- Co se NEuvolňuje: strop dvou desetinných míst platí pořád pro všechny.
ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_rate_per_hour_cele_koruny;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_rate_per_hour_cele_koruny CHECK (
    rate_per_hour IS NULL
    OR (
      rate_per_hour >= 0
      AND (cenove_pasma IS NOT NULL OR cena_rucni OR rate_per_hour = round(rate_per_hour))
      AND rate_per_hour = round(rate_per_hour, 2)
    )
  );

-- Ruční částka nesmí být záporná a musí být na celé haléře. `amount` samotné
-- dosud žádný CHECK nehlídalo (dopočítávalo se), teď do něj píše člověk.
ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_rucni_cena_smysluplna;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_rucni_cena_smysluplna CHECK (
    NOT cena_rucni
    OR (amount IS NOT NULL AND amount >= 0 AND amount = round(amount, 2))
  );

-- ---- 3) Trigger: ruční částka se nedopočítává ------------------------------
-- Tělo je VYGENEROVANÉ z `pg_get_functiondef` živé produkce (9. 9. 2026) a
-- vložené jsou do něj jen dva zásahy — ochrana příznaku a větev pro ruční cenu.
-- Ověřeno diffem: proti původnímu tělu je změna čistě přírůstková, nic
-- z původní logiky nezmizelo. Přepis peněžní funkce z paměti už jednou utnul
-- půlku bezpečnostního guardu (commit 87b1f78), proto tahle cesta.
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

  -- `cena_rucni` JE TAKY ODVOZENÁ HODNOTA, NE VSTUP.
  --
  -- `reservations` má tabulkové INSERT/UPDATE granty, takže by si příznak mohl
  -- nastavit kdokoli — a tím vypnout dopočet `amount` i pravidlo o celých
  -- korunách, tedy zapsat si libovolnou částku. Zvenčí se proto zahazuje;
  -- zapnout ho smí jen `create_booking` transakčním markerem, ke kterému se
  -- z API nedá dostat (viz pravidlo 8 v CLAUDE.md).
  IF TG_OP = 'INSERT' THEN
    NEW.cena_rucni := COALESCE(current_setting('app.rucni_cena', true), 'off') = 'on';
  ELSE
    -- Na UPDATE se příznak DRŽÍ STARÝ. Jinak by stačilo jednou uložit rezervaci
    -- z jiného místa a ruční cena by se od příště začala dopočítávat z hodin.
    NEW.cena_rucni := OLD.cena_rucni;
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

  -- RUČNÍ CELKOVÁ CENA VYHRÁVÁ NAD VŠÍM OSTATNÍM.
  --
  -- Admin zadal, kolik akce stojí dohromady. Tahle částka se nesmí dopočítávat
  -- z hodin ani přepočítat pásmy — jinak by 14 000 za turnaj po první úpravě
  -- termínu tiše přeskočilo na cenu z ceníku. `rate_per_hour` se drží jako
  -- odvozený průměr do přehledů, přesně jako u pásmové ceny.
  --
  -- Pásma se u ruční ceny zahazují: přestala částku popisovat.
  IF NEW.cena_rucni AND NEW.subject_id IS NOT NULL THEN
    NEW.cenove_pasma := NULL;
    NEW.hours := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    NEW.rate_per_hour := round(NEW.amount / NULLIF(NEW.hours, 0), 2);
    -- DAŇOVÝ VÝZNAM SE OBNOVUJE I PŘI PŘECENĚNÍ, nejen při vzniku.
    --
    -- Tahle větev končí `RETURN NEW` ještě před blokem přecenění níž, takže je
    -- to JEDINÉ místo, kde se `cena_bez_dph` u pevné ceny může přepočítat.
    -- Bez `app.preceneni` tu zůstal snapshot ze starého typu akce: klubový
    -- turnaj (cena S daní) přepnutý na komerční akci (ceny BEZ daně) si nechal
    -- `false` — a doklad za akci ho pak odmítl vystavit („míchal by ceny s DPH
    -- a bez DPH"), zatímco měsíční klubový doklad ho vzal a hala by odvedla
    -- daň z částky, kterou nevybrala. Je to týž bug class, který stál 1 440 Kč
    -- (viz komentář o pár desítek řádků níž) — jen o jednu větev vedle.
    --
    -- Přeceňuje se JEN daňový význam. Částka zůstává pevná, o to tu jde.
    IF TG_OP = 'INSERT'
       OR COALESCE(current_setting('app.preceneni', true), 'off') = 'on' THEN
      SELECT s.default_rate, s.type INTO _subject_rate, _subject_type
        FROM public.subjects s WHERE s.id = NEW.subject_id;
      IF NEW.event_id IS NOT NULL THEN
        SELECT e.event_type INTO _event_type FROM public.events e WHERE e.id = NEW.event_id;
      END IF;
      -- Daňový význam se určuje stejně jako u ručně zadané SAZBY: podle toho,
      -- komu a na co se účtuje. Táž funkce, tatáž tři kritéria.
      NEW.cena_bez_dph := public.cena_je_bez_dph(_subject_type, _event_type, _subject_rate);
    END IF;
    NEW.corrected_amount := CASE
      WHEN NEW.corrected_hours IS NOT NULL THEN round(NEW.corrected_hours * NEW.rate_per_hour, 2)
      ELSE NULL END;
    RETURN NEW;
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
      OR COALESCE(current_setting('app.preceneni', true), 'off') = 'on') THEN
    SELECT s.default_rate, s.type INTO _subject_rate, _subject_type
      FROM public.subjects s WHERE s.id = NEW.subject_id;
    SELECT * INTO _st FROM public.settings LIMIT 1;

    IF NEW.event_id IS NOT NULL THEN
      SELECT e.event_type INTO _event_type FROM public.events e WHERE e.id = NEW.event_id;
    END IF;

    -- SAZBU UŽ MÁME ZVENČÍ? Pak se nevybírá — ALE DAŇOVÝ VÝZNAM SE URČIT MUSÍ.
    --
    -- Tohle je ten nález. Dřív podmínka „a `rate_per_hour IS NULL`" visela
    -- na CELÉM bloku, takže rezervace založená adminem se zadanou sazbou
    -- (`create_booking` → `p_rate`, řádek „sazbu smí zadat jen admin") celý
    -- blok PŘESKOČILA — a `cena_bez_dph` zůstala na DEFAULTU sloupce, tedy
    -- `false`. To u komerčního zákazníka znamená „v částce už daň je",
    -- přestože komerční sazba je vedená BEZ DPH.
    --
    -- Naměřeno na produkci: 3 živé potvrzené rezervace (Deloitte 10 000,
    -- ZŠ Poruba 2× 1 000) měly `false` tam, kde `cena_je_bez_dph()` říká
    -- `true` → 1 440 Kč DPH, které by na dokladu nikdo nenaúčtoval.
    -- Opravuje se to dobropisem, ne přepnutím, tak ať k tomu nedojde.
    --
    -- Vnitřní blok si schválně DRŽÍ PŮVODNÍ ODSAZENÍ. Přeodsadit šedesát
    -- řádků peněžní funkce znamená diff, ve kterém už nikdo nepozná, co se
    -- doopravdy změnilo — a přesně tím se sem podobná chyba dostala.
    IF NEW.rate_per_hour IS NULL THEN

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

    ELSE
      -- Sazbu zadal admin ručně. Kterou sazbu to je, tím pádem nevíme — ale
      -- KOMU a NA CO se účtuje, víme pořád, a to daňový význam určuje.
      -- Táž funkce, tatáž tři kritéria; jen se k ní dojde druhou cestou.
      NEW.cena_bez_dph := public.cena_je_bez_dph(_subject_type, _event_type, _subject_rate);
    END IF;
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

-- ---- 3b) Peněžní strážce pustí haléře i u ruční ceny -----------------------
-- `check_reservation_money` hlídá celé koruny NEZÁVISLE na CHECK constraintu —
-- je to druhý strážce téhož pravidla. Bez téhle úpravy by CHECK haléře pustil,
-- ale trigger je zamítl a ruční cena by nešla uložit vůbec. Změřeno lokálně:
-- „Sazba se zadává v celých korunách (dostal jsem 538.46 Kč/h)".
--
-- Tělo je opět vygenerované z živého schématu, změna je jediná podmínka.
CREATE OR REPLACE FUNCTION public.check_reservation_money()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.rate_per_hour IS NOT NULL THEN
    IF NEW.rate_per_hour < 0 THEN
      RAISE EXCEPTION 'Sazba nesmí být záporná (dostal jsem % Kč/h).', NEW.rate_per_hour;
    END IF;
    IF NEW.rate_per_hour > 50000 THEN
      RAISE EXCEPTION 'Sazba je nejvýš 50 000 Kč/h (dostal jsem % Kč/h). Vyšší číslo je skoro jistě překlep.', NEW.rate_per_hour;
    END IF;
    -- Celé koruny se vyžadují JEN u sazby bez pásmového rozpisu. S rozpisem je
    -- `rate_per_hour` průměr dopočítaný z částky, ne zadaná hodnota — viz
    -- komentář u `reservations.cenove_pasma`.
    --
    -- Táž výjimka platí pro RUČNÍ CELKOVOU CENU (`cena_rucni`): admin zadal
    -- částku za celou akci a sazba je z ní jen dopočítaný průměr — 14 000 na
    -- 13 hodin dá 1 076,92 Kč/h. Bez téhle větve by pravidlo o celých korunách
    -- odmítlo přesně to, kvůli čemu ruční cena vznikla.
    IF NEW.cenove_pasma IS NULL AND NOT NEW.cena_rucni
       AND NEW.rate_per_hour <> round(NEW.rate_per_hour) THEN
      RAISE EXCEPTION 'Sazba se zadává v celých korunách, bez haléřů (dostal jsem % Kč/h).', NEW.rate_per_hour;
    END IF;
    -- Haléře ano, ale ne víc: `numeric(10,2)` by třetí desetinné místo
    -- zaokrouhlil tiše, takže se to hlídá tady.
    IF NEW.rate_per_hour <> round(NEW.rate_per_hour, 2) THEN
      RAISE EXCEPTION 'Sazba jde nejvýš na haléře (dostal jsem % Kč/h).', NEW.rate_per_hour;
    END IF;
  END IF;

  IF NEW.corrected_hours IS NOT NULL THEN
    IF NEW.corrected_hours < 0 THEN
      RAISE EXCEPTION 'Korekce hodin nesmí být záporná (dostal jsem % h).', NEW.corrected_hours;
    END IF;
    IF NEW.corrected_hours > 24 THEN
      RAISE EXCEPTION 'Korekce hodin je nejvýš 24 h (dostal jsem % h). Vyšší číslo je skoro jistě překlep.', NEW.corrected_hours;
    END IF;
    IF NEW.corrected_hours * 4 <> round(NEW.corrected_hours * 4) THEN
      RAISE EXCEPTION 'Korekce hodin jde jen po čtvrthodinách (0,25 / 0,50 / 0,75 …), dostal jsem % h.', NEW.corrected_hours;
    END IF;
    IF regexp_replace(coalesce(NEW.correction_reason, ''),
                      '[[:space:]\u00a0\u200b-\u200f\u2060\ufeff]', '', 'g') = '' THEN
      RAISE EXCEPTION 'Ke korekci hodin je potřeba důvod — musí být dohledatelné, kdo co a proč změnil.';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- ---- 4) create_booking přijme celkovou cenu --------------------------------
-- Nový parametr `p_celkem` mění SIGNATURU, takže `CREATE OR REPLACE` by
-- nenahradilo starou funkci, ale vyrobilo PŘETÍŽENÍ — a volání bez `p_celkem`
-- by dál chodilo na starou verzi. Stará se proto výslovně odstraňuje.
--
-- `DROP FUNCTION` s sebou vezme i granty, takže se hned pod tím vrací
-- do původního stavu (`authenticated` + `service_role`, ověřeno v `proacl`
-- živé produkce). Bez toho by po nasazení nikdo nezaložil rezervaci.
DROP FUNCTION IF EXISTS public.create_booking(
  uuid[], text, text, timestamptz, timestamptz, uuid, text, jsonb, numeric, boolean, uuid);

CREATE OR REPLACE FUNCTION public.create_booking(p_sheet_ids uuid[], p_kind text, p_title text, p_start timestamp with time zone, p_end timestamp with time zone, p_subject_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_role_reqs jsonb DEFAULT '{}'::jsonb, p_rate numeric DEFAULT NULL::numeric, p_override boolean DEFAULT false, p_series_id uuid DEFAULT NULL::uuid, p_celkem numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _uid        uuid := auth.uid();
  _is_admin   boolean;
  _type       public.event_type;
  _event_id   uuid;
  _sheet      uuid;
  _res_ids    uuid[] := '{}';
  _res_id     uuid;
  _cancelled  jsonb  := '[]'::jsonb;
  _conf       record;
  _member     record;
  _required   int    := 0;
  _approved   timestamptz;
  _approver   uuid;
  _title      text;
  _new_prio   int;
  _sheet_cnt  int;
  _celkem     numeric;   -- ruční celková cena akce (jen admin), NULL = spočítá engine
  _podil      numeric;   -- základní díl na jednu dráhu
  _halere     int;       -- haléře, které po dělení zbyly a musí se rozdat
  _poradi     int := 0;  -- kolikátou dráhu právě zakládáme
BEGIN
  IF _uid IS NULL THEN
    RAISE EXCEPTION 'Pro rezervaci se musíte přihlásit.';
  END IF;
  _is_admin := has_role(_uid, 'admin');

  -- --- ruční celková cena ------------------------------------------------------
  -- Částku smí zadat JEN admin — stejné pravidlo jako u sazby. Neadminovi se
  -- zahazuje potichu (ne chybou): pole v UI nevidí, takže když ho někdo pošle
  -- ručně přes API, není co vysvětlovat, jen se to nepoužije.
  _celkem := CASE WHEN _is_admin THEN p_celkem ELSE NULL END;

  IF _celkem IS NOT NULL THEN
    IF _celkem < 0 THEN
      RAISE EXCEPTION 'Celková cena nemůže být záporná.';
    END IF;
    IF _celkem <> round(_celkem, 2) THEN
      RAISE EXCEPTION 'Celková cena se zadává nejvýš na haléře (dostal jsem %).', _celkem;
    END IF;
    -- Obojí najednou nedává smysl: sazba i celková cena popisují touž věc a
    -- při rozporu by se tiše rozhodlo za admina.
    IF p_rate IS NOT NULL THEN
      RAISE EXCEPTION 'Zadejte buď sazbu za hodinu, nebo celkovou cenu akce — ne obojí.';
    END IF;
    -- Bez subjektu není komu fakturovat, takže by se částka stejně zahodila.
    IF p_subject_id IS NULL THEN
      RAISE EXCEPTION 'Celkovou cenu lze zadat jen akci, která má klub nebo firmu.';
    END IF;
  END IF;

  -- --- vstupy -----------------------------------------------------------------
  IF p_kind NOT IN ('training', 'tournament', 'commercial', 'maintenance') THEN
    RAISE EXCEPTION 'Neznámý typ akce: %', p_kind;
  END IF;
  _type := p_kind::public.event_type;

  _title := nullif(btrim(coalesce(p_title, '')), '');
  IF _title IS NULL THEN
    RAISE EXCEPTION 'Vyplňte název akce.';
  END IF;

  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'Konec rezervace musí být po jejím začátku.';
  END IF;

  -- Do cizí série se nikdo nepřipojí (kazilo by to přehled opakovaných tréninků).
  IF p_series_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.reservations r
     WHERE r.series_id = p_series_id
       AND r.subject_id IS DISTINCT FROM p_subject_id
  ) THEN
    RAISE EXCEPTION 'Série patří jinému subjektu.';
  END IF;

  SELECT count(*) INTO _sheet_cnt FROM unnest(p_sheet_ids) AS x(id);
  IF p_sheet_ids IS NULL OR _sheet_cnt = 0 THEN
    RAISE EXCEPTION 'Vyberte aspoň jednu dráhu.';
  END IF;
  IF _sheet_cnt <> (SELECT count(DISTINCT id) FROM unnest(p_sheet_ids) AS x(id)) THEN
    RAISE EXCEPTION 'Každou dráhu lze vybrat jen jednou.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(p_sheet_ids) AS x(id)
     WHERE NOT EXISTS (SELECT 1 FROM public.sheets sh WHERE sh.id = x.id AND sh.active)
  ) THEN
    RAISE EXCEPTION 'Některá z vybraných drah neexistuje nebo není aktivní.';
  END IF;

  -- --- práva ------------------------------------------------------------------
  IF p_kind IN ('commercial', 'maintenance') THEN
    IF NOT _is_admin THEN
      RAISE EXCEPTION 'Komerční akci a údržbu ledu zadává jen správce haly.';
    END IF;
  ELSE
    IF p_subject_id IS NULL THEN
      RAISE EXCEPTION 'Vyberte klub, za který rezervujete.';
    END IF;
    IF NOT _is_admin AND NOT public.is_subject_member(p_subject_id) THEN
      RAISE EXCEPTION 'Za tento klub nemáte oprávnění rezervovat.';
    END IF;
  END IF;

  IF p_kind = 'commercial' AND p_subject_id IS NULL THEN
    RAISE EXCEPTION 'U komerční akce vyberte firmu (zákazníka).';
  END IF;
  IF p_kind = 'maintenance' AND p_subject_id IS NOT NULL THEN
    RAISE EXCEPTION 'Údržba ledu se neúčtuje — nezadávejte subjekt.';
  END IF;

  -- Komerční akce musí mít aspoň jednoho instruktora (požadavek klienta).
  IF p_kind = 'commercial' THEN
    IF COALESCE((p_role_reqs ->> 'instructor')::int, 0) < 1 THEN
      RAISE EXCEPTION 'Komerční akce potřebuje aspoň jednoho instruktora.';
    END IF;
    SELECT COALESCE(sum(value::int), 0) INTO _required FROM jsonb_each_text(p_role_reqs);
  END IF;

  -- --- kolize + případné přebití ----------------------------------------------
  _new_prio := public.booking_priority(_type);

  FOR _conf IN
    SELECT c.* FROM public.check_booking_conflicts(p_sheet_ids, p_start, p_end, p_kind) c
  LOOP
    IF NOT _is_admin THEN
      -- SQLSTATE U0001 = KOLIZE. Série podle něj pozná, že má
      -- termín přeskočit a jet dál. Bez vlastního kódu by musela chytat všechno
      -- (WHEN OTHERS) a hlásila by jako „kolizi" i chybějící oprávnění nebo
      -- sazbu nad stropem — tedy věci, které platí pro celé zadání, ne pro termín.
      RAISE EXCEPTION '% je v tomto čase už obsazená (%). Vyberte jiný čas nebo dráhu.',
        _conf.sheet_name, COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace')
        USING ERRCODE = 'U0001';
    END IF;
    IF NOT p_override THEN
      RAISE EXCEPTION '% je v tomto čase obsazená (%). Rezervaci lze založit jen s vědomým přebitím.',
        _conf.sheet_name, COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace')
        USING ERRCODE = 'U0001';
    END IF;
    IF NOT _conf.can_override THEN
      -- Priorita zůstává v platnosti (komerční > turnaj > trénink): termín, který
      -- drží akce se stejnou nebo vyšší prioritou, je pro sérii prostě obsazený.
      RAISE EXCEPTION 'Akci „%" (%) nelze přebít — má stejnou nebo vyšší prioritu.',
        COALESCE(_conf.event_title, _conf.subject_name, 'rezervace'), _conf.sheet_name
        USING ERRCODE = 'U0001';
    END IF;
  END LOOP;

  -- Od téhle chvíle píšeme do rezervací my (guard trigger nás pustí).
  PERFORM set_config('app.trusted_booking', 'on', true);

  IF p_override AND _is_admin THEN
    FOR _conf IN
      SELECT c.* FROM public.check_booking_conflicts(p_sheet_ids, p_start, p_end, p_kind) c
    LOOP
      -- Znovu i tady: mezi kontrolou a stornem mohla vzniknout akce vyšší priority.
      IF NOT _conf.can_override THEN
        RAISE EXCEPTION 'Akci „%" (%) nelze přebít — má stejnou nebo vyšší prioritu.',
          COALESCE(_conf.event_title, _conf.subject_name, 'rezervace'), _conf.sheet_name;
      END IF;

      UPDATE public.reservations
         SET status        = 'cancelled',
             cancelled_at  = now(),
             cancelled_by  = _uid,
             cancel_reason = 'Přebito akcí vyšší priority: ' || _title
       WHERE id = _conf.reservation_id;

      _cancelled := _cancelled || jsonb_build_object(
        'reservation_id', _conf.reservation_id,
        'sheet_name',     _conf.sheet_name,
        'title',          COALESCE(_conf.event_title, _conf.subject_name),
        'start_at',       _conf.start_at,
        'end_at',         _conf.end_at);

      -- Upozorni všechny lidi napojené na dotčený klub + autora zrušené rezervace.
      FOR _member IN
        SELECT DISTINCT u.user_id
          FROM (
            SELECT sr.user_id
              FROM public.subject_reps sr
              JOIN public.reservations rr ON rr.id = _conf.reservation_id
             WHERE sr.subject_id = rr.subject_id
            UNION
            SELECT rr.created_by FROM public.reservations rr WHERE rr.id = _conf.reservation_id
          ) u(user_id)
         WHERE u.user_id IS NOT NULL
      LOOP
        PERFORM public.notify_user(
          _member.user_id,
          'reservation_overridden',
          'Vaše akce byla zrušena kvůli komerční události',
          'Rezervace „' || COALESCE(_conf.event_title, _conf.subject_name, 'akce') || '" na '
            || _conf.sheet_name || ' dne '
            || to_char(_conf.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
            || '–' || to_char(_conf.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI')
            || ' byla zrušena kvůli akci „' || _title || '". Omlouváme se, vyberte prosím náhradní termín.',
          '/calendar',
          _conf.reservation_id,
          (SELECT rr.subject_id FROM public.reservations rr WHERE rr.id = _conf.reservation_id));
      END LOOP;
    END LOOP;
  END IF;

  -- --- akce (kvůli názvu, typu a štábu) ---------------------------------------
  INSERT INTO public.events (title, event_type, start_time, end_time, required_staff, role_reqs, created_by)
  VALUES (_title, _type, p_start, p_end, _required,
          CASE WHEN p_kind = 'commercial' THEN p_role_reqs ELSE '{}'::jsonb END,
          _uid)
  RETURNING id INTO _event_id;

  -- --- potvrzení (člen klubu potřebuje potvrzení zástupce) --------------------
  IF _is_admin OR p_subject_id IS NULL OR public.is_subject_rep(p_subject_id) THEN
    _approved := now();
    _approver := _uid;
  ELSE
    _approved := NULL;
    _approver := NULL;
  END IF;

  -- --- rozpad ruční ceny na dráhy ---------------------------------------------
  -- Akce na dvou drahách je JEDNA akce s jednou cenou, ale v databázi jsou to
  -- dva řádky — částka se tedy musí rozdělit tak, aby SOUČET seděl na haléř.
  -- Dělení samo o sobě to nezaručí: 14 000 / 3 = 4 666,666…, tři zaokrouhlené
  -- díly dají 13 999,98 a dvě koruny by zmizely. Zbylé haléře se proto rozdají
  -- po jednom prvním drahám, místo aby se zaokrouhlily stranou.
  IF _celkem IS NOT NULL THEN
    _podil  := trunc(_celkem / _sheet_cnt, 2);
    _halere := round((_celkem - _podil * _sheet_cnt) * 100)::int;
    -- Zapnout `cena_rucni` smí jen tahle funkce; trigger jinak příznak zahodí.
    PERFORM set_config('app.rucni_cena', 'on', true);
  END IF;

  -- --- rezervace ledu (jedna na každou dráhu) ---------------------------------
  FOREACH _sheet IN ARRAY p_sheet_ids LOOP
    _poradi := _poradi + 1;
    INSERT INTO public.reservations (
      sheet_id, subject_id, event_id, series_id, start_at, end_at, note,
      rate_per_hour, amount, created_by, approved_at, approved_by
    ) VALUES (
      _sheet, p_subject_id, _event_id, p_series_id, p_start, p_end,
      nullif(btrim(coalesce(p_note, '')), ''),
      CASE WHEN _is_admin THEN p_rate ELSE NULL END,   -- sazbu smí zadat jen admin
      CASE WHEN _celkem IS NOT NULL
           -- prvních `_halere` drah dostane o haléř víc, ať součet sedí přesně
           THEN _podil + CASE WHEN _poradi <= _halere THEN 0.01 ELSE 0 END
           ELSE NULL END,
      _uid, _approved, _approver
    ) RETURNING id INTO _res_id;
    _res_ids := _res_ids || _res_id;
  END LOOP;

  IF _celkem IS NOT NULL THEN
    PERFORM set_config('app.rucni_cena', 'off', true);

    -- Kontrolní součet, ne důvěra ve výpočet: zadaná částka MUSÍ sedět na haléř
    -- se součtem toho, co se opravdu uložilo. Kdyby se rozešly, je to chyba
    -- rozpadu a rezervace nesmí vzniknout.
    IF (SELECT round(sum(r.amount), 2) FROM public.reservations r
         WHERE r.id = ANY(_res_ids)) <> round(_celkem, 2) THEN
      RAISE EXCEPTION 'Rozpad ceny na dráhy nesedí se zadanou částkou (%). Rezervace nevznikla.', _celkem;
    END IF;
  END IF;

  -- Zvýšené oprávnění platí jen po dobu zápisů téhle funkce (GUC je transakčně
  -- lokální, takže bez tohohle by zůstalo zapnuté do konce transakce).
  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object(
    'event_id',        _event_id,
    'reservation_ids', to_jsonb(_res_ids),
    'approved',        _approved IS NOT NULL,
    'cancelled',       _cancelled);
EXCEPTION
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';

  WHEN exclusion_violation THEN
    -- ERRCODE MUSÍ ZŮSTAT: holý `RAISE EXCEPTION` dostane P0001, čímž se z kolize
    -- stane „obyčejná chyba" a série ji nepozná — přesně tak byla větev pro
    -- `exclusion_violation` v `create_booking_series` chvíli mrtvým kódem.
    -- Je to táž kolize jako z `check_booking_conflicts`, jen zjištěná o vteřinu
    -- později, takže dostává týž kód.
    RAISE EXCEPTION 'Dráha už je v tomto čase obsazená — někdo byl rychlejší. Zkuste jiný čas nebo dráhu.'
      USING ERRCODE = 'U0001';
END;
$function$;

-- `FROM PUBLIC, anon` — NE JEN `FROM PUBLIC`.
--
-- `anon` NENÍ `PUBLIC`, je to pojmenovaná role, a Supabase má
-- `ALTER DEFAULT PRIVILEGES … GRANT EXECUTE ON FUNCTIONS TO … anon …`. Každá
-- nově založená funkce v `public` tedy dostane `anon=X` explicitním grantem,
-- který `REVOKE FROM PUBLIC` nesundá — a protože se tahle funkce zakládá přes
-- DROP+CREATE, přišla by tím obrana, kterou původní migrace postavila
-- (`20260731120000_booking_api.sql` revokovala výslovně `FROM public, anon`).
-- Únik to není (funkce hned na začátku vyžaduje přihlášení), je to ztráta
-- obrany do hloubky u SECURITY DEFINER funkce, která sahá na peníze.
REVOKE ALL ON FUNCTION public.create_booking(
  uuid[], text, text, timestamptz, timestamptz, uuid, text, jsonb, numeric, boolean, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_booking(
  uuid[], text, text, timestamptz, timestamptz, uuid, text, jsonb, numeric, boolean, uuid, numeric) TO authenticated, service_role;

-- ---- 5) Podklady pro doklad nesou příznak pevné ceny -----------------------
-- Bez tohohle kroku se ruční cena ULOŽÍ, ale NEVYFAKTURUJE. Mapovací vrstva
-- (`billing/mapping.ts`, `overRadek`) trvá na `castka = hodiny × sazba` a u
-- paušálu součin z principu nevyjde: 7 000 Kč na 13 h je 538,46 Kč/h a zpátky
-- 6 999,98 Kč. Ověřeno testem: „částka 7000 Kč nesedí na 13 h × 538.46 Kč/h" —
-- a to na OBOU cestách, u dokladu za akci i u měsíční klubové faktury.
--
-- Podklady proto vedle částky posílají i informaci, ŽE JE PEVNÁ. Doklad z ní
-- složí jeden řádek `1 akce × 7 000 Kč` místo hodinového rozpisu.
--
-- POZOR NA KOREKCI. Příznak se posílá jen tehdy, když NENÍ admin korekce hodin.
-- Korekce („nedorazili, účtujeme 2 h ze 3") částku znovu odvodí z hodin a
-- průměrné sazby (`corrected_amount = round(corrected_hours × rate_per_hour, 2)`),
-- takže od té chvíle paušál neplatí a součin zase sedí. Je to táž úvaha, jakou
-- tu už má `cenove_pasma` — a kdyby se příznak posílal i u korekce, doklad by
-- zněl na původní paušál, přestože se fakturuje krácená částka.
--
-- Mění se NÁVRATOVÝ TYP, takže `CREATE OR REPLACE` nestačí (Postgres ho odmítne)
-- a musí se přes DROP. `DROP FUNCTION` bere s sebou granty, proto se hned pod
-- každou funkcí vracejí do stavu z `proacl` živé produkce (authenticated +
-- service_role); bez toho by Edge funkce přestala podklady číst.

DROP FUNCTION IF EXISTS public.fakturoid_podklady_akce(uuid);

CREATE OR REPLACE FUNCTION public.fakturoid_podklady_akce(_event uuid)
 RETURNS TABLE(id uuid, start_at timestamp with time zone, end_at timestamp with time zone, sheet_name text, event_title text, hodiny numeric, sazba numeric, castka numeric, subject_id uuid, cenove_pasma jsonb, cena_rucni boolean)
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
           CASE WHEN r.corrected_hours IS NULL THEN r.cenove_pasma ELSE NULL END,
           -- Pevná cena — jen dokud do ní nesáhla korekce (viz hlavička sekce).
           (r.cena_rucni AND r.corrected_hours IS NULL)
      FROM public.reservations r
      JOIN public.sheets sh ON sh.id = r.sheet_id
      JOIN public.events e  ON e.id = r.event_id
     WHERE r.id = ANY (_ids)
     ORDER BY r.start_at, r.id;
END;
$function$;

-- `, anon` ze stejného důvodu jako u `create_booking` výš.
REVOKE ALL ON FUNCTION public.fakturoid_podklady_akce(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fakturoid_podklady_akce(uuid) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.fakturoid_podklady_klub(uuid, date, date);

CREATE OR REPLACE FUNCTION public.fakturoid_podklady_klub(_subject uuid, _od date, _do date)
 RETURNS TABLE(id uuid, start_at timestamp with time zone, end_at timestamp with time zone, sheet_name text, event_title text, hodiny numeric, sazba numeric, castka numeric, cenove_pasma jsonb, cena_rucni boolean)
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
           CASE WHEN r.corrected_hours IS NULL THEN r.cenove_pasma ELSE NULL END,
           -- Pevná cena — ze stejného důvodu jako rozpis výš jen bez korekce.
           (r.cena_rucni AND r.corrected_hours IS NULL)
      FROM public.fakturovatelne_rezervace(_subject, _zac, _kon) f
      JOIN public.reservations r ON r.id = f.id
     -- Týž výběr, který prošel bránou výš — proto `_ids`, ne druhá kopie
     -- podmínky „ještě není na dokladu".
     WHERE f.id = ANY (_ids)
     ORDER BY f.start_at, f.id;
END;
$function$;

-- `, anon` ze stejného důvodu.
REVOKE ALL ON FUNCTION public.fakturoid_podklady_klub(uuid, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fakturoid_podklady_klub(uuid, date, date) TO authenticated, service_role;

-- ---- 6) Pevná cena je zatím NEMĚNNÁ — fail-closed na všech cestách ---------
-- Pevná cena je vlastnost AKCE, ale uložená PO ŘÁDCÍCH, a tři event-level RPC
-- o ní nevěděly. Změřeno na živých datech, každá položka zvlášť:
--
--   • `uprav_sazbu_akce(akce, 3000)` vrátilo {"sazba":3000,"celkem":14000} —
--     a NEZMĚNILO NIC. Odpověď si sama odporuje (3 000 × 13 h × 2 dráhy je
--     78 000, ne 14 000) a admin vidí zelený toast.
--   • `zmen_typ_akce` totéž, hlásí "preceneno":1.
--   • `uprav_drahy_akce`: PŘIDÁNÍ dráhy spadlo na „Sazba se zadává v celých
--     korunách (dostal jsem 1076.92 Kč/h)" — hláška o sazbě, kterou admin nikdy
--     nezadal. UBRÁNÍ dráhy naopak prošlo a TIŠE SNÍŽILO cenu ze 14 000 na 7 000.
--   • `move_booking`: zástupce klubu si roztáhl pevně oceněnou akci z 2 na 13
--     hodin a částka se nepohnula — jedenáct hodin ledu zdarma, bez schválení.
--   • `update_booking` s `p_rate` propadlo doprázdna, taky s hlášením úspěchu.
--
-- Všechny tyhle cesty se ZAVÍRAJÍ, a to i adminovi. Skutečný editor paušálu —
-- RPC, která částku znovu rozdělí mezi dráhy a ohlídá kontrolní součet — je
-- samostatný ticket; do té doby je jediná podporovaná cesta storno a založení
-- znovu. Tichý no-op ani tichá změna ceny se u peněz nesmí stát, a když si
-- máme vybrat mezi „nejde to" a „tváří se, že to šlo", volíme první.
--
-- CO ZŮSTÁVÁ POVOLENÉ: storno CELÉ AKCE (`cancel_booking` se `p_scope`
-- „event"), potvrzení (`approve_reservation`) a úprava názvu či poznámky
-- (`update_booking` bez `p_rate`) — nic z toho cenou nehýbe.
--
-- POZOR: storno JEDNÉ dráhy (`p_scope = 'single'`) cenou hýbe a je zavřené
-- taky — vyjmutí dráhy z paušálu na dvou drahách jinak částku tiše půlí.
-- Guard je v `cancel_booking` níž.
--
-- DRUHÁ OTEVŘENÁ CESTA: `create_booking(..., p_override => true)`. Přebití
-- ruší kolidující rezervace vlastním UPDATE pod `app.trusted_booking`, tedy
-- mimo `cancel_booking` — guard tam nesahá. Admin, který si vezme JEDNU dráhu
-- vyšší prioritou, tím srazí pevných 14 000 na 7 000. Zavřené to schválně
-- NENÍ: je to admin-only, vyžaduje vědomé `p_override`, přebitá rezervace je
-- vyjmenovaná v odpovědi a klub dostane notifikaci — nic z toho není tiché.
-- A účtovat dál 14 000 za akci, které hala sama vzala půlku, by bylo horší.
-- Správná odpověď (přecenit zbytek) potřebuje editor paušálu = jiný ticket.
-- (Nález bezpečnostní brány.)
--
-- MEZ TĚCHTO GUARDŮ: platí pro RPC, ne pro přímý zápis do tabulky. Admin má
-- na `reservations` sloupcové UPDATE granty, takže si přes PATCH /rest/v1
-- `amount` i `end_at` přepíše mimo tyhle funkce. Není to regrese — totéž jde
-- dnes u pásmové ceny — ale „blokované i adminovi" je tvrzení o RPC, ne
-- o databázi jako celku. (Poznámka bezpečnostní brány.)
--
-- Těla jsou VYGENEROVANÁ z `pg_get_functiondef` a vložený je do nich jen guard;
-- ověřeno diffem, že z původní logiky neubyl ani řádek (pravidlo 7). Signatury
-- se nemění, takže `CREATE OR REPLACE` drží i granty.

CREATE OR REPLACE FUNCTION public.uprav_sazbu_akce(_event_id uuid, _sazba numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _zmeneno int;
  _drah    int;
  _hodin   numeric;
BEGIN
  -- Sazbu smí měnit jen admin — stejně jako v `update_booking`, kde je to
  -- `has_role(auth.uid(), 'admin') AND p_rate IS NOT NULL`.
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Cenu akce může měnit jen správce haly.';
  END IF;

  -- FAIL-CLOSED U PEVNĚ ZADANÉ CENY.
  --
  -- `set_reservation_pricing` u ruční ceny drží `amount` a sazbu si dopočítá
  -- zpátky z částky, takže tahle funkce dřív TIŠE NEUDĚLALA NIC a přitom
  -- vracela úspěch — admin dostal zelený toast a v datech se nezměnilo nic.
  -- Tichý no-op je u peněz horší než chyba, tak ať je z toho chyba.
  --
  -- Zakázáno je to i ADMINOVI, schválně: skutečný editor paušálu (RPC, která
  -- částku znovu rozdělí mezi dráhy a ohlídá kontrolní součet) je samostatný
  -- ticket. Dokud není, je jediná podporovaná cesta storno a založit znovu.
  IF EXISTS (
    SELECT 1 FROM public.reservations r
     WHERE r.event_id = _event_id AND r.deleted_at IS NULL AND r.cena_rucni
  ) THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (sazbu u ní měnit nelze). Tu zatím nejde měnit — když má stát jinak, akci stornujte a založte znovu.'
      USING HINT = 'Pevnou cenu akce nastavuje jen zakládání rezervace.';
  END IF;

  IF _sazba IS NULL OR _sazba < 0 THEN
    RAISE EXCEPTION 'Sazba musí být nezáporné číslo.';
  END IF;
  -- Kontrolu celých korun a stropu dělá `check_reservation_money` na každém
  -- řádku; tady se ptáme dřív, aby chyba mluvila o AKCI, ne o jedné rezervaci.
  IF _sazba <> round(_sazba) THEN
    RAISE EXCEPTION 'Sazba se zadává v celých korunách, bez haléřů (dostal jsem % Kč/h).', _sazba;
  END IF;
  IF _sazba > 50000 THEN
    RAISE EXCEPTION 'Sazba je nejvýš 50 000 Kč/h (dostal jsem % Kč/h). Vyšší číslo je skoro jistě překlep.', _sazba;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = _event_id) THEN
    RAISE EXCEPTION 'Akce nenalezena.';
  END IF;

  -- PŘECENIT VYFAKTUROVANOU AKCI NEJDE. Doklad si drží staré částky, takže by
  -- se „Kdo kolik dluží" a vystavená faktura rozešly — a vypadalo by to jako
  -- vada fakturace, ne jako důsledek jednoho kliknutí. `billing_reconcile` to
  -- odhalí až POTOM; tohle tomu předchází.
  PERFORM public.over_neni_vyfakturovano(_event_id, 'Cena akce');

  PERFORM set_config('app.trusted_booking', 'on', true);

  -- CELÁ AKCE NARÁZ. `amount` dopočítá trigger `set_reservation_pricing`
  -- z nové sazby, takže se tu schválně nepíše — jinak by vznikla druhá,
  -- tišší cesta k částce.
  UPDATE public.reservations
     SET rate_per_hour = _sazba
   WHERE event_id = _event_id
     AND deleted_at IS NULL;
  GET DIAGNOSTICS _zmeneno = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);

  IF _zmeneno = 0 THEN
    RAISE EXCEPTION 'Akce nemá žádnou živou rezervaci, není co přecenit.';
  END IF;

  SELECT count(DISTINCT sheet_id), max(hours) INTO _drah, _hodin
    FROM public.reservations
   WHERE event_id = _event_id AND deleted_at IS NULL;

  RETURN jsonb_build_object(
    'rezervaci', _zmeneno,
    'drah',      _drah,
    'hodin',     _hodin,
    'sazba',     _sazba,
    'celkem',    (SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0)
                    FROM public.reservations
                   WHERE event_id = _event_id AND deleted_at IS NULL)
  );

EXCEPTION
  -- Táž úvaha jako v `update_booking`: syrová chyba integrity nese v DETAILu
  -- celý řádek včetně sazby a částky, a PostgREST by ho poslal klientovi.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Cenu akce se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Sazba musí být v celých korunách a nejvýš 50 000 Kč/h.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.zmen_typ_akce(_event_id uuid, _typ event_type)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _stary public.event_type;
  _zmeneno int;
  _instruktoru int;
  _trener_zrusen int := 0;
  _doplnen_instruktor boolean := false;
BEGIN
  -- Typ akce hýbe cenou, takže ho mění jen správce haly — táž úvaha jako
  -- u sazby v `update_booking` a `uprav_sazbu_akce`.
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Typ akce může změnit jen správce haly.';
  END IF;

  -- FAIL-CLOSED U PEVNĚ ZADANÉ CENY.
  --
  -- `set_reservation_pricing` u ruční ceny drží `amount` a sazbu si dopočítá
  -- zpátky z částky, takže tahle funkce dřív TIŠE NEUDĚLALA NIC a přitom
  -- vracela úspěch — admin dostal zelený toast a v datech se nezměnilo nic.
  -- Tichý no-op je u peněz horší než chyba, tak ať je z toho chyba.
  --
  -- Zakázáno je to i ADMINOVI, schválně: skutečný editor paušálu (RPC, která
  -- částku znovu rozdělí mezi dráhy a ohlídá kontrolní součet) je samostatný
  -- ticket. Dokud není, je jediná podporovaná cesta storno a založit znovu.
  IF EXISTS (
    SELECT 1 FROM public.reservations r
     WHERE r.event_id = _event_id AND r.deleted_at IS NULL AND r.cena_rucni
  ) THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (typ akce u ní měnit nelze). Tu zatím nejde měnit — když má stát jinak, akci stornujte a založte znovu.'
      USING HINT = 'Pevnou cenu akce nastavuje jen zakládání rezervace.';
  END IF;

  SELECT event_type INTO _stary FROM public.events WHERE id = _event_id;
  IF _stary IS NULL THEN
    RAISE EXCEPTION 'Akce nenalezena.';
  END IF;

  IF _stary = _typ THEN
    RETURN jsonb_build_object('zmena', false, 'typ', _typ);
  END IF;

  -- Vyfakturovanou akci nepřeceňuj — doklad by zůstal na staré částce.
  PERFORM public.over_neni_vyfakturovano(_event_id, 'Typ akce');

  -- TRENÉR PATŘÍ K TRÉNINKU, TAKŽE S NÍM ODCHÁZÍ — a odchází PRVNÍ.
  --
  -- `prirad_trenera` zakládá směnu rovnou jako `claimed`, aby ji dorovnání
  -- štábu nesebralo jako přebytek — jenže tím ji neumělo sebrat ani po změně
  -- typu akce. Hala tak platila trenéra za komerční akci a `stab_kontrola`
  -- hlásila „o směnu víc" napořád, protože rušit obsazené směny sama odmítá.
  --
  -- Ruší se PŘED zásahem do `events`, aby ji dorovnání štábu (trigger na
  -- `role_reqs`, `required_staff` i `event_type`) nestihlo ohlásit jako
  -- přebytek — jinak admin dostane WARNING o něčem, co se za dva řádky vyřeší
  -- samo. Ruší se SOFT (zásada 2); uzavřená směna se nesahá, je to podklad
  -- pro výplatu.
  IF _stary = 'training' AND _typ <> 'training' THEN
    UPDATE public.shifts
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     WHERE event_id = _event_id
       AND required_role = 'trainer'
       AND status NOT IN ('cancelled', 'completed');
    GET DIAGNOSTICS _trener_zrusen = ROW_COUNT;
  END IF;

  -- KOMERČNÍ AKCE POTŘEBUJE INSTRUKTORA (požadavek klienta).
  --
  -- `create_booking` to vynucuje od Etapy 1, tahle cesta ho obcházela: přepnutý
  -- trénink měl `role_reqs = '{}'`, takže `dorovnej_stab` neměl z čeho směnu
  -- udělat a v hale vznikla komerční akce bez štábu — a `stab_kontrola` na ni
  -- napořád svítila „chybí instruktor" bez čehokoli, co by to spravilo.
  --
  -- Nedoplňuje se odhad podle drah, ale MINIMUM, které pravidlo žádá: jeden.
  -- Kolik jich ve skutečnosti bude, ví admin a doplní to ve Správě směn.
  IF _typ IN ('commercial', 'recruitment') THEN
    SELECT COALESCE((role_reqs ->> 'instructor')::int, 0) INTO _instruktoru
      FROM public.events WHERE id = _event_id;
    IF _instruktoru < 1 THEN
      UPDATE public.events
         SET role_reqs = COALESCE(role_reqs, '{}'::jsonb) || jsonb_build_object('instructor', 1),
             required_staff = GREATEST(COALESCE(required_staff, 0), 1)
       WHERE id = _event_id;
      _doplnen_instruktor := true;
    END IF;
  END IF;

  UPDATE public.events SET event_type = _typ WHERE id = _event_id;

  -- PŘEPOČET CENY. Sazba se vynuluje a `set_reservation_pricing` ji dopočítá
  -- podle NOVÉHO typu — pásma u klubového tréninku, komerční sazba u komerčky.
  -- `app.preceneni` je jediné místo, kde se snapshot smí přepsat.
  PERFORM set_config('app.preceneni', 'on', true);
  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET rate_per_hour = NULL, cenove_pasma = NULL
   WHERE event_id = _event_id AND deleted_at IS NULL;
  GET DIAGNOSTICS _zmeneno = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);
  PERFORM set_config('app.preceneni', 'off', true);

  RETURN jsonb_build_object(
    'zmena', true, 'typ', _typ, 'puvodni', _stary, 'preceneno', _zmeneno,
    -- Ať volající pozná, co se stalo kolem směn — obojí je vidět v UI.
    'trener_zrusen', _trener_zrusen,
    'doplnen_instruktor', _doplnen_instruktor,
    'celkem', (SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0)
                 FROM public.reservations
                WHERE event_id = _event_id AND deleted_at IS NULL)
  );

EXCEPTION
  WHEN check_violation OR not_null_violation OR foreign_key_violation THEN
    RAISE EXCEPTION 'Typ akce se nepodařilo změnit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'U nového typu možná chybí sazba v ceníku (Nastavení).';
END;
$function$;

CREATE OR REPLACE FUNCTION public.uprav_drahy_akce(_event_id uuid, _sheet_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _vzor     public.reservations%ROWTYPE;
  _pridano  int := 0;
  _ubrano   int := 0;
  _sheet    uuid;
BEGIN
  IF _sheet_ids IS NULL OR array_length(_sheet_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Akce musí mít aspoň jednu dráhu.';
  END IF;

  -- Vzorová rezervace: z ní se berou časy, subjekt i sazba pro nové dráhy.
  -- Nová dráha téže akce musí mít TOTOŽNÉ podmínky, jinak by z jedné akce
  -- vznikly dvě různě drahé půlky.
  SELECT * INTO _vzor
    FROM public.reservations
   WHERE event_id = _event_id AND deleted_at IS NULL
   ORDER BY created_at LIMIT 1;

  IF _vzor.id IS NULL THEN
    RAISE EXCEPTION 'Akce nemá žádnou živou rezervaci.';
  END IF;

  IF NOT public.can_manage_reservation(_vzor.id) THEN
    RAISE EXCEPTION 'Tuhle akci nemáte právo upravit.';
  END IF;

  -- FAIL-CLOSED U PEVNĚ ZADANÉ CENY.
  --
  -- `set_reservation_pricing` u ruční ceny drží `amount` a sazbu si dopočítá
  -- zpátky z částky, takže tahle funkce dřív TIŠE NEUDĚLALA NIC a přitom
  -- vracela úspěch — admin dostal zelený toast a v datech se nezměnilo nic.
  -- Tichý no-op je u peněz horší než chyba, tak ať je z toho chyba.
  --
  -- Zakázáno je to i ADMINOVI, schválně: skutečný editor paušálu (RPC, která
  -- částku znovu rozdělí mezi dráhy a ohlídá kontrolní součet) je samostatný
  -- ticket. Dokud není, je jediná podporovaná cesta storno a založit znovu.
  IF EXISTS (
    SELECT 1 FROM public.reservations r
     WHERE r.event_id = _event_id AND r.deleted_at IS NULL AND r.cena_rucni
  ) THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (dráhy u ní měnit nelze). Tu zatím nejde měnit — když má stát jinak, akci stornujte a založte znovu.'
      USING HINT = 'Pevnou cenu akce nastavuje jen zakládání rezervace.';
  END IF;

  -- VYFAKTUROVANOU AKCI UŽ NEJDE PŘESKLÁDAT. Ubraná dráha by zmizela z rozvrhu,
  -- ale zůstala na odeslaném dokladu; přidaná by na dokladu chyběla.
  PERFORM public.over_neni_vyfakturovano(_event_id, 'Dráhy akce');

  PERFORM set_config('app.trusted_booking', 'on', true);

  -- UBRÁNÍ: soft delete (zásada 2), nikdy DELETE.
  UPDATE public.reservations
     SET deleted_at = now()
   WHERE event_id = _event_id
     AND deleted_at IS NULL
     AND NOT (sheet_id = ANY (_sheet_ids));
  GET DIAGNOSTICS _ubrano = ROW_COUNT;

  -- PŘIDÁNÍ: nová rezervace pod TOUTÉŽ akcí, se stejným časem, subjektem
  -- i sazbou. `rate_per_hour` se kopíruje ze vzoru schválně — jinak by ji
  -- trigger dopočítal z ceníku a nová dráha by mohla stát jinak než ta první.
  FOREACH _sheet IN ARRAY _sheet_ids LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.reservations
       WHERE event_id = _event_id AND sheet_id = _sheet AND deleted_at IS NULL
    ) THEN
      -- PÁSMOVÁ CENA SE NEKOPÍRUJE, DOPOČÍTÁ SE.
      --
      -- `_vzor.rate_per_hour` je u pásmové rezervace ODVOZENÝ PRŮMĚR, klidně
      -- s haléři (3 400 Kč / 3 h = 1 133,33). Zkopírovat ho do nové dráhy
      -- znamenalo jistý pád: `check_reservation_money` vyžaduje celé koruny
      -- a `reservations_rate_per_hour_cele_koruny` totéž. Přidat dráhu
      -- k dvoupásmové klubové rezervaci proto nešlo VŮBEC — a jednopásmová
      -- sice prošla, ale nová dráha tiše přišla o snapshot `cenove_pasma`.
      --
      -- S `NULL` ji ocení `set_reservation_pricing` z ceníku na TENTÝŽ čas,
      -- takže vyjde stejná částka i stejný rozpis. Že to opravdu vyšlo stejně,
      -- se ověřuje hned pod smyčkou — kdyby se mezitím změnil ceník, nesmí
      -- z jedné akce vzniknout dvě různě drahé půlky.
      INSERT INTO public.reservations
        (sheet_id, subject_id, event_id, start_at, end_at, status,
         rate_per_hour, note, approved_at, approved_by)
      VALUES
        (_sheet, _vzor.subject_id, _event_id, _vzor.start_at, _vzor.end_at, _vzor.status,
         CASE WHEN _vzor.cenove_pasma IS NULL THEN _vzor.rate_per_hour ELSE NULL END,
         _vzor.note, _vzor.approved_at, _vzor.approved_by);
      _pridano := _pridano + 1;
    END IF;
  END LOOP;

  PERFORM set_config('app.trusted_booking', 'off', true);

  IF NOT EXISTS (SELECT 1 FROM public.reservations
                  WHERE event_id = _event_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Akce by zůstala bez dráhy — na zrušení celé akce je storno.';
  END IF;

  -- JEDNA AKCE, JEDNA CENA. U pásmové rezervace se nová dráha oceňuje
  -- z ceníku, ne kopií — a kdyby se ceník mezi založením akce a přidáním
  -- dráhy změnil, vyšla by jiná částka. Radši to nedopustit než mít akci,
  -- kde stojí Dráha 1 jinak než Dráha 2.
  IF _pridano > 0
     AND (SELECT count(DISTINCT COALESCE(corrected_amount, amount))
            FROM public.reservations
           WHERE event_id = _event_id AND deleted_at IS NULL) > 1 THEN
    RAISE EXCEPTION 'Přidaná dráha by stála jinak než ty stávající — ceník se od založení akce změnil.'
      USING HINT = 'Založ akci znovu, nebo nejdřív srovnej cenu (Cena akce).';
  END IF;

  RETURN jsonb_build_object(
    'pridano', _pridano,
    'ubrano',  _ubrano,
    'drah',    (SELECT count(*) FROM public.reservations
                 WHERE event_id = _event_id AND deleted_at IS NULL),
    'celkem',  (SELECT COALESCE(sum(COALESCE(corrected_amount, amount)), 0)
                  FROM public.reservations
                 WHERE event_id = _event_id AND deleted_at IS NULL)
  );

EXCEPTION
  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Na té dráze už v tom čase něco je.'
      USING HINT = 'Vyberte jinou dráhu nebo nejdřív zrušte kolidující rezervaci.';
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Dráhy se nepodařilo upravit — zadané údaje neprošly kontrolou databáze.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.move_booking(p_reservation_id uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_sheet_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _res        public.reservations%ROWTYPE;
  _lanes      int := 1;
  _kind       text;
  _sheet_ids  uuid[];
  _conf       record;
BEGIN
  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;
  IF _res.status <> 'confirmed' THEN RAISE EXCEPTION 'Stornovanou rezervaci nelze přesunout.'; END IF;
  IF NOT public.can_manage_reservation(p_reservation_id) THEN
    RAISE EXCEPTION 'Tuto rezervaci nemáte právo přesunout.';
  END IF;

  -- FAIL-CLOSED U PEVNĚ ZADANÉ CENY — viz `uprav_sazbu_akce`.
  --
  -- Přesun ani prodloužení částku nezmění (o to u paušálu jde), ale mění
  -- odvozenou sazbu a délku, za kterou se ta částka účtuje. Zástupce klubu si
  -- takhle roztáhl akci z 2 na 13 hodin a zaplatil pořád 14 000 — jedenáct
  -- hodin ledu navíc zadarmo, bez schválení a bez upozornění.
  IF _res.cena_rucni THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (přesouvat ani prodlužovat ji nelze). Tu zatím nejde měnit — když má stát jinak, akci stornujte a založte znovu.'
      USING HINT = 'Pevnou cenu akce nastavuje jen zakládání rezervace.';
  END IF;

  IF _res.event_id IS NOT NULL THEN
    SELECT count(*) INTO _lanes FROM public.reservations
     WHERE event_id = _res.event_id AND status = 'confirmed' AND deleted_at IS NULL;
  END IF;
  IF _lanes > 1 AND p_sheet_id IS NOT NULL AND p_sheet_id <> _res.sheet_id THEN
    RAISE EXCEPTION 'Akce běží na obou drahách — přesunout jde jen její čas, ne dráhu.';
  END IF;

  SELECT COALESCE(e.event_type::text,
                  CASE WHEN s.type = 'commercial' THEN 'commercial' ELSE 'training' END)
    INTO _kind
    FROM public.reservations r
    LEFT JOIN public.events e   ON e.id = r.event_id
    LEFT JOIN public.subjects s ON s.id = r.subject_id
   WHERE r.id = p_reservation_id;

  -- cílové dráhy (u víc drah zůstávají původní)
  IF _lanes > 1 THEN
    SELECT array_agg(sheet_id) INTO _sheet_ids FROM public.reservations
     WHERE event_id = _res.event_id AND status = 'confirmed' AND deleted_at IS NULL;
  ELSE
    _sheet_ids := ARRAY[COALESCE(p_sheet_id, _res.sheet_id)];
  END IF;

  -- kolize (vlastní akci ignorujeme)
  FOR _conf IN
    SELECT c.* FROM public.check_booking_conflicts(
      _sheet_ids, p_start, p_end, _kind, _res.event_id, _res.id) c
  LOOP
    RAISE EXCEPTION 'Nový termín se kryje s rezervací „%" (%).',
      COALESCE(_conf.event_title, _conf.subject_name, 'jiná rezervace'), _conf.sheet_name;
  END LOOP;

  PERFORM set_config('app.trusted_booking', 'on', true);

  IF _lanes > 1 THEN
    UPDATE public.reservations
       SET start_at = p_start, end_at = p_end
     WHERE event_id = _res.event_id AND status = 'confirmed' AND deleted_at IS NULL;
  ELSE
    UPDATE public.reservations
       SET start_at = p_start, end_at = p_end, sheet_id = COALESCE(p_sheet_id, sheet_id)
     WHERE id = p_reservation_id;
  END IF;

  IF _res.event_id IS NOT NULL THEN
    UPDATE public.events SET start_time = p_start, end_time = p_end WHERE id = _res.event_id;
  END IF;

  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object('moved_lanes', _lanes);
EXCEPTION
  -- A5: chyby integrity se nesmí dostat ke klientovi v syrové podobě.
  -- Uvnitř SECURITY DEFINER funkce neplatí RLS, takže Postgres do chyby doplní
  -- „DETAIL: Failing row contains (…)" s CELÝM řádkem — a PostgREST ho u RPC
  -- přepošle volajícímu. U rezervací je v tom řádku sazba i částka.
  WHEN check_violation OR not_null_violation OR foreign_key_violation
       OR unique_violation OR string_data_right_truncation THEN
    RAISE EXCEPTION 'Rezervaci se nepodařilo uložit — zadané údaje neprošly kontrolou databáze.'
      USING HINT = 'Zkontrolujte časy, sazbu a vybraný klub. Když potíž trvá, řekněte to správci.';

  WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Nový termín je už obsazený — někdo byl rychlejší.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_booking(p_reservation_id uuid, p_title text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_rate numeric DEFAULT NULL::numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _res   public.reservations%ROWTYPE;
  _title text := nullif(btrim(coalesce(p_title, '')), '');
BEGIN
  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;
  IF NOT public.can_manage_reservation(p_reservation_id) THEN
    RAISE EXCEPTION 'Tuto rezervaci nemáte právo upravit.';
  END IF;

  -- FAIL-CLOSED U PEVNĚ ZADANÉ CENY — ale jen na SAZBU.
  --
  -- `p_rate` je pokus o změnu ceny a ten u paušálu dřív tiše propadl:
  -- `set_reservation_pricing` sazbu přepsal zpátky z uložené částky a funkce
  -- vrátila úspěch. Název a poznámka cenu nemění, takže projdou dál — jinak by
  -- u pevně oceněné akce nešlo opravit ani překlep v názvu.
  IF _res.cena_rucni AND p_rate IS NOT NULL THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (sazbu u ní měnit nelze). Tu zatím nejde měnit — když má stát jinak, akci stornujte a založte znovu.'
      USING HINT = 'Název a poznámku upravit můžete, cenu ne.';
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  -- p_note = NULL znamená „neměň"; prázdný řetězec znamená „smaž poznámku".
  -- (Bez tohohle rozlišení by úprava samotného názvu poznámku tiše vymazala.)
  UPDATE public.reservations
     SET note = CASE WHEN p_note IS NULL THEN note ELSE nullif(btrim(p_note), '') END,
         rate_per_hour = CASE WHEN has_role(auth.uid(), 'admin') AND p_rate IS NOT NULL
                              THEN p_rate ELSE rate_per_hour END
   WHERE id = p_reservation_id;

  IF _title IS NOT NULL AND _res.event_id IS NOT NULL THEN
    UPDATE public.events SET title = _title WHERE id = _res.event_id;
  END IF;

  PERFORM set_config('app.trusted_booking', 'off', true);
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

-- CANCEL_BOOKING: storno JEDNÉ dráhy u pevně oceněné akce.
--
-- Nález bezpečnostní brány. Komentář výš uváděl `cancel_booking` mezi cestami,
-- které „cenou nehýbou" — u paušálu na víc drahách to neplatí. Tělo je
-- VYGENEROVANÉ z `pg_get_functiondef` a vložený je do něj jen guard (pravidlo 7).
CREATE OR REPLACE FUNCTION public.cancel_booking(p_reservation_id uuid, p_scope text DEFAULT 'single'::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _res       public.reservations%ROWTYPE;
  _ids       uuid[];
  _cancelled int;
BEGIN
  IF p_scope NOT IN ('single', 'event', 'series') THEN
    RAISE EXCEPTION 'Neznámý rozsah storna: %', p_scope;
  END IF;

  SELECT * INTO _res FROM public.reservations WHERE id = p_reservation_id AND deleted_at IS NULL;
  IF _res.id IS NULL THEN RAISE EXCEPTION 'Rezervace nenalezena.'; END IF;
  IF NOT public.can_manage_reservation(p_reservation_id) THEN
    RAISE EXCEPTION 'Tuto rezervaci nemáte právo stornovat.';
  END IF;

  -- FAIL-CLOSED: JEDNU DRÁHU Z PEVNĚ OCENĚNÉ AKCE VYJMOUT NELZE.
  --
  -- `uprav_drahy_akce` je nad pevnou cenou zavřená právě proto, že ubrání
  -- dráhy TIŠE SNÍŽILO cenu ze 14 000 na 7 000. Přes storno jedné dráhy jde
  -- vyrobit týž výsledek — a narozdíl od té zavřené cesty bez jediné chyby.
  -- Smí to i zástupce klubu, protože `can_manage_reservation` mu na vlastní
  -- rezervaci storno povoluje; admin u toho být nemusí.
  --
  -- U paušálu je částka cenou za CELOU AKCI bez ohledu na počet drah, takže
  -- ubrání dráhy má cenu nechat být, nebo zrušit akci celou. Storno celé akce
  -- (`p_scope = 'event'`) proto zůstává otevřené — to cenu nepůlí, ruší ji.
  -- Jednodráhová akce sem nespadne: tam je `single` totéž co `event`.
  IF p_scope = 'single' AND _res.cena_rucni AND _res.event_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.reservations r
        WHERE r.event_id = _res.event_id
          AND r.id <> _res.id
          AND r.status = 'confirmed'
          AND r.deleted_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Akce má pevně zadanou celkovou cenu (jednu dráhu z ní vyjmout nelze).'
      USING HINT = 'Stornujte celou akci. Pevná cena platí za akci jako celek, ne za jednotlivou dráhu.';
  END IF;

  SELECT array_agg(r.id) INTO _ids
    FROM public.reservations r
   WHERE r.status = 'confirmed'
     AND r.deleted_at IS NULL
     AND (
       (p_scope = 'single' AND r.id = _res.id)
       OR (p_scope = 'event'  AND _res.event_id  IS NOT NULL AND r.event_id  = _res.event_id)
       OR (p_scope = 'series' AND _res.series_id IS NOT NULL AND r.series_id = _res.series_id
           AND r.start_at >= now())            -- u série ruš jen budoucí termíny
     )
     AND public.can_manage_reservation(r.id);

  IF _ids IS NULL OR array_length(_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Není co stornovat.';
  END IF;

  PERFORM set_config('app.trusted_booking', 'on', true);

  UPDATE public.reservations
     SET status        = 'cancelled',
         cancelled_at  = now(),
         cancelled_by  = auth.uid(),
         cancel_reason = nullif(btrim(coalesce(p_reason, '')), '')
   WHERE id = ANY (_ids);
  GET DIAGNOSTICS _cancelled = ROW_COUNT;

  PERFORM set_config('app.trusted_booking', 'off', true);

  RETURN jsonb_build_object('cancelled', _cancelled);
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

-- ---- 7) Vlastní kontrola ---------------------------------------------------
-- Měří CHOVÁNÍ na skutečném zápisu, ne tvar objektů. Zápisy běží v plpgsql
-- blocích s EXCEPTION (implicitní savepoint), takže se ať dopadnou jakkoli
-- vrátí a v datech ani v audit logu po nich nezůstane nic.
DO $kontrola$
DECLARE
  _sheet1 uuid; _sheet2 uuid; _subj uuid; _admin uuid;
  _vysledek jsonb; _ids uuid[]; _soucet numeric; _pocet int;
  _amount numeric; _rate numeric; _rucni boolean; _pasma jsonb;
  _pustil boolean; _radek record;
BEGIN
  SELECT id INTO _sheet1 FROM public.sheets WHERE active ORDER BY name LIMIT 1;
  SELECT id INTO _sheet2 FROM public.sheets WHERE active AND id <> _sheet1 ORDER BY name LIMIT 1;
  SELECT id INTO _subj  FROM public.subjects WHERE type='club' AND deleted_at IS NULL ORDER BY id LIMIT 1;

  -- `create_booking` se ptá, kdo je přihlášený (`auth.uid()`), a při migraci
  -- neběží nikdo. Kontrola se proto na dobu testu představí jako existující
  -- admin — jinak by celá migrace spadla na „Pro rezervaci se musíte přihlásit".
  -- Role zůstává `postgres`; testuje se CHOVÁNÍ ceny, ne oprávnění (ta se měří
  -- reálným tokenem zvlášť, viz mutační testy).
  SELECT ur.user_id INTO _admin FROM public.user_roles ur WHERE ur.role = 'admin' LIMIT 1;
  IF _admin IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
  END IF;

  IF _sheet1 IS NULL OR _subj IS NULL OR _admin IS NULL THEN
    -- Čistá databáze (lokální reset, nový projekt) nemá dráhy ani kluby.
    -- Tvrzení „aspoň jedna dráha musí být" by ji rozbilo, a migrace musí projít
    -- na produkci i na prázdnu. Kontroly chování se proto přeskočí.
    RAISE NOTICE 'Ruční cena: přeskakuji kontrolu chování (chybí dráhy, klub nebo admin).';
  ELSE
    -- (a) DVĚ DRÁHY, 14 000 → součet přesně 14 000, ne 2× dopočítáno z hodin
    BEGIN
      _vysledek := public.create_booking(
        ARRAY[_sheet1, _sheet2], 'tournament', '__zkouska_rucni_ceny__',
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '400 days' + interval '8 hours') AT TIME ZONE 'Europe/Prague'),
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '400 days' + interval '21 hours') AT TIME ZONE 'Europe/Prague'),
        _subj, NULL, '{}'::jsonb, NULL, false, NULL, 14000);

      SELECT array_agg((v)::uuid) INTO _ids
        FROM jsonb_array_elements_text(_vysledek->'reservation_ids') v;

      SELECT round(sum(r.amount), 2), count(*), bool_and(r.cena_rucni)
        INTO _soucet, _pocet, _rucni
        FROM public.reservations r WHERE r.id = ANY(_ids);

      IF _pocet <> 2 THEN
        RAISE EXCEPTION 'Čekal jsem 2 rezervace (2 dráhy), mám %.', _pocet USING ERRCODE='ZC002';
      END IF;
      IF _soucet <> 14000 THEN
        RAISE EXCEPTION 'Součet přes dráhy je % místo zadaných 14000.', _soucet USING ERRCODE='ZC002';
      END IF;
      IF NOT _rucni THEN
        RAISE EXCEPTION 'Rezervace nemá příznak cena_rucni — částka se bude dopočítávat.' USING ERRCODE='ZC002';
      END IF;

      -- 13 h × 2 dráhy: sazba vyjde 538,46 Kč/h, tedy s haléři. Dřív to CHECK
      -- odmítl a přesně proto tahle změna vznikla.
      SELECT r.rate_per_hour, r.cenove_pasma INTO _rate, _pasma
        FROM public.reservations r WHERE r.id = _ids[1];
      IF _pasma IS NOT NULL THEN
        RAISE EXCEPTION 'Ruční cena si nechala pásmový rozpis — přestal částku popisovat.' USING ERRCODE='ZC002';
      END IF;

      -- ÚPRAVA REZERVACE NESMÍ ČÁSTKU PŘEPOČÍTAT (to je celý smysl příznaku).
      UPDATE public.reservations SET note = 'dotek' WHERE id = _ids[1];
      SELECT r.amount, r.cena_rucni INTO _amount, _rucni
        FROM public.reservations r WHERE r.id = _ids[1];
      IF _rucni IS NOT TRUE THEN
        RAISE EXCEPTION 'Po úpravě rezervace zmizel příznak cena_rucni.' USING ERRCODE='ZC002';
      END IF;
      IF _amount <> 7000 THEN
        RAISE EXCEPTION 'Po úpravě se částka změnila na % (čekal jsem 7000).', _amount USING ERRCODE='ZC002';
      END IF;

      RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZC001';
    EXCEPTION
      WHEN SQLSTATE 'ZC001' THEN NULL;                       -- v pořádku, vráceno
      WHEN SQLSTATE 'ZC002' THEN RAISE;                      -- skutečný nález
    END;

    -- (a2) NEDĚLITELNÁ ČÁSTKA — tohle je jádro rozpadu.
    --      14 000 na dvě dráhy vyjde beze zbytku, takže by tenhle případ
    --      neodhalil ani rozpad, který haléře zaokrouhlí stranou. Ověřeno
    --      mutací: `round` místo `trunc` prošlo, dokud tu byla jen kulatá
    --      částka. Proto částka s lichým haléřem: 7 000,005 na dráhu nejde
    --      rozdělit, jeden haléř musí někdo dostat navíc.
    BEGIN
      _vysledek := public.create_booking(
        ARRAY[_sheet1, _sheet2], 'tournament', '__zkouska_halere__',
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '402 days' + interval '8 hours') AT TIME ZONE 'Europe/Prague'),
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '402 days' + interval '19 hours') AT TIME ZONE 'Europe/Prague'),
        _subj, NULL, '{}'::jsonb, NULL, false, NULL, 14000.01);

      SELECT array_agg((v)::uuid) INTO _ids
        FROM jsonb_array_elements_text(_vysledek->'reservation_ids') v;

      SELECT round(sum(r.amount), 2) INTO _soucet
        FROM public.reservations r WHERE r.id = ANY(_ids);

      IF _soucet <> 14000.01 THEN
        RAISE EXCEPTION 'Nedělitelná částka: součet je % místo 14000.01 — haléř se ztratil.', _soucet
          USING ERRCODE='ZC002';
      END IF;

      -- A ať to není náhoda: díly se musí lišit přesně o ten jeden haléř.
      IF (SELECT max(r.amount) - min(r.amount) FROM public.reservations r
           WHERE r.id = ANY(_ids)) <> 0.01 THEN
        RAISE EXCEPTION 'Haléř se nerozdal po jednom — díly se liší jinak než o 0,01.'
          USING ERRCODE='ZC002';
      END IF;

      RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZC001';
    EXCEPTION
      WHEN SQLSTATE 'ZC001' THEN NULL;
      WHEN SQLSTATE 'ZC002' THEN RAISE;
    END;

    -- (b) TŘI DÍLY: 14 000 na 3 dráhy nejde dělit beze zbytku. Kdyby se haléře
    --     zaokrouhlily stranou, součet by byl 13 999,98. Simulace rozpadu.
    DECLARE _p numeric; _h int; _s numeric;
    BEGIN
      _p := trunc(14000::numeric / 3, 2);
      _h := round((14000 - _p * 3) * 100)::int;
      _s := _p * 3 + _h * 0.01;
      IF _s <> 14000 THEN
        RAISE EXCEPTION 'Rozpad na tři díly dá % místo 14000 — haléře mizí.', _s;
      END IF;
    END;

    -- (c) SAZBA I CELKOVÁ CENA NAJEDNOU se musí odmítnout
    _pustil := true;
    BEGIN
      PERFORM public.create_booking(
        ARRAY[_sheet1], 'tournament', '__zkouska_obojiho__',
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '401 days' + interval '8 hours') AT TIME ZONE 'Europe/Prague'),
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '401 days' + interval '10 hours') AT TIME ZONE 'Europe/Prague'),
        _subj, NULL, '{}'::jsonb, 500, false, NULL, 14000);
      RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZC001';
    EXCEPTION
      WHEN SQLSTATE 'ZC001' THEN NULL;
      WHEN OTHERS THEN _pustil := false;
    END;
    IF _pustil THEN
      RAISE EXCEPTION 'Prošlo zadání sazby i celkové ceny najednou — rozpor se má odmítnout.';
    END IF;
  END IF;

  PERFORM set_config('request.jwt.claims', NULL, true);

  -- (d) Příznak nesmí jít nastavit zvenčí (bez markeru z create_booking).
  --     Kdyby šel, kdokoli si vypne dopočet částky a zapíše si libovolnou cenu.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname='public' AND p.proname='set_reservation_pricing'
         AND p.prosrc LIKE '%app.rucni_cena%') <> 1 THEN
    RAISE EXCEPTION 'set_reservation_pricing nehlídá marker app.rucni_cena.';
  END IF;

  -- (e) create_booking existuje PRÁVĚ JEDNOU (přetížení by tiše obcházelo změnu)
  SELECT count(*) INTO _pocet FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='create_booking';
  IF _pocet <> 1 THEN
    RAISE EXCEPTION 'create_booking má % verzí — volání bez p_celkem by šlo na starou.', _pocet;
  END IF;

  -- (f) grant se po DROP FUNCTION vrátil
  IF NOT has_function_privilege('authenticated',
        'public.create_booking(uuid[],text,text,timestamptz,timestamptz,uuid,text,jsonb,numeric,boolean,uuid,numeric)',
        'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated nemá EXECUTE na create_booking — nikdo nezaloží rezervaci.';
  END IF;

  -- (g) PODKLADY PRO DOKLAD MUSÍ PŘÍZNAK NÉST.
  --     Bez něj se ruční cena uloží, ale nevyfakturuje: mapovací vrstva trvá
  --     na `castka = hodiny × sazba` a u paušálu součin nevyjde (7 000 na 13 h
  --     je 538,46 Kč/h a zpátky 6 999,98). Kontroluje se návratový KONTRAKT
  --     obou cest — chování mapovací vrstvy měří `billing/mapping.test.ts`.
  FOR _radek IN
    SELECT unnest(ARRAY['fakturoid_podklady_akce','fakturoid_podklady_klub']) AS fn
  LOOP
    IF pg_get_function_result(
         (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = _radek.fn LIMIT 1)
       ) NOT LIKE '%cena_rucni boolean%' THEN
      RAISE EXCEPTION '% nevrací cena_rucni — pevná cena by se neuměla vyfakturovat.', _radek.fn;
    END IF;

    -- DROP FUNCTION bere s sebou granty. Kdyby se nevrátily, Edge funkce
    -- přestane podklady číst a fakturace se zastaví celá.
    IF NOT has_function_privilege('service_role',
          (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = _radek.fn LIMIT 1), 'EXECUTE') THEN
      RAISE EXCEPTION 'service_role nemá EXECUTE na % — fakturace by se zastavila.', _radek.fn;
    END IF;

    -- Přetížení by tiše obcházelo změnu: volání by šlo na starou verzi bez příznaku.
    SELECT count(*) INTO _pocet FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = _radek.fn;
    IF _pocet <> 1 THEN
      RAISE EXCEPTION '% má % verzí — volání by mohlo jít na starou.', _radek.fn, _pocet;
    END IF;
  END LOOP;

  -- (h) `anon` NESMÍ MÍT EXECUTE NA PENĚŽNÍCH FUNKCÍCH.
  --     `anon` není `PUBLIC`, takže `REVOKE ALL … FROM PUBLIC` ho nesundá —
  --     a `ALTER DEFAULT PRIVILEGES` mu při každém CREATE grant vrátí. Právě
  --     proto se to musí testovat: kontrola (f) níž se ptala jen na to, že
  --     `authenticated` EXECUTE MÁ, a tuhle regresi propustila.
  FOR _radek IN
    SELECT unnest(ARRAY[
      'public.create_booking(uuid[],text,text,timestamptz,timestamptz,uuid,text,jsonb,numeric,boolean,uuid,numeric)',
      'public.fakturoid_podklady_akce(uuid)',
      'public.fakturoid_podklady_klub(uuid,date,date)'
    ]) AS fn
  LOOP
    IF has_function_privilege('anon', _radek.fn, 'EXECUTE') THEN
      RAISE EXCEPTION 'anon má EXECUTE na % — REVOKE musí být „FROM PUBLIC, anon".', _radek.fn;
    END IF;
  END LOOP;

  -- (i) MUTAČNÍ CESTY U PEVNÉ CENY MUSÍ BÝT ZAVŘENÉ.
  --     Měří se CHOVÁNÍ, ne text funkce: každá z těch RPC dřív vracela úspěch
  --     a neudělala nic (nebo, u ubrání dráhy, tiše snížila cenu na polovinu).
  IF _sheet1 IS NOT NULL AND _subj IS NOT NULL AND _admin IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', _admin, 'role', 'authenticated')::text, true);
    BEGIN
      _vysledek := public.create_booking(
        ARRAY[_sheet1], 'tournament', '__zkouska_zavrenych_cest__',
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '404 days' + interval '8 hours') AT TIME ZONE 'Europe/Prague'),
        ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
          + interval '404 days' + interval '10 hours') AT TIME ZONE 'Europe/Prague'),
        _subj, NULL, '{}'::jsonb, NULL, false, NULL, 5000);

      SELECT array_agg((v)::uuid) INTO _ids
        FROM jsonb_array_elements_text(_vysledek->'reservation_ids') v;

      -- přecenění sazbou
      _pustil := true;
      BEGIN
        PERFORM public.uprav_sazbu_akce((_vysledek->>'event_id')::uuid, 900);
      EXCEPTION WHEN OTHERS THEN _pustil := false;
      END;
      IF _pustil THEN
        RAISE EXCEPTION 'uprav_sazbu_akce prošla nad pevnou cenou — musí skončit chybou.'
          USING ERRCODE = 'ZC002';
      END IF;

      -- změna typu akce
      _pustil := true;
      BEGIN
        PERFORM public.zmen_typ_akce((_vysledek->>'event_id')::uuid, 'commercial');
      EXCEPTION WHEN OTHERS THEN _pustil := false;
      END;
      IF _pustil THEN
        RAISE EXCEPTION 'zmen_typ_akce prošla nad pevnou cenou — musí skončit chybou.'
          USING ERRCODE = 'ZC002';
      END IF;

      -- přesun / prodloužení
      _pustil := true;
      BEGIN
        PERFORM public.move_booking(_ids[1],
          ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
            + interval '404 days' + interval '8 hours') AT TIME ZONE 'Europe/Prague'),
          ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
            + interval '404 days' + interval '14 hours') AT TIME ZONE 'Europe/Prague'), NULL);
      EXCEPTION WHEN OTHERS THEN _pustil := false;
      END;
      IF _pustil THEN
        RAISE EXCEPTION 'move_booking prošel nad pevnou cenou — musí skončit chybou.'
          USING ERRCODE = 'ZC002';
      END IF;

      -- ubrání/přidání dráhy
      _pustil := true;
      BEGIN
        PERFORM public.uprav_drahy_akce((_vysledek->>'event_id')::uuid, ARRAY[_sheet1, _sheet2]);
      EXCEPTION WHEN OTHERS THEN _pustil := false;
      END;
      IF _pustil THEN
        RAISE EXCEPTION 'uprav_drahy_akce prošla nad pevnou cenou — musí skončit chybou.'
          USING ERRCODE = 'ZC002';
      END IF;

      -- ČÁSTKA SE PŘITOM NESMĚLA POHNOUT ANI O HALÉŘ
      SELECT round(sum(r.amount), 2) INTO _soucet
        FROM public.reservations r WHERE r.id = ANY(_ids);
      IF _soucet <> 5000 THEN
        RAISE EXCEPTION 'Po zavřených cestách je částka % místo 5000.', _soucet
          USING ERRCODE = 'ZC002';
      END IF;

      -- ale ÚPRAVA NÁZVU projít MUSÍ — jinak nejde opravit ani překlep
      PERFORM public.update_booking(_ids[1], 'Nový název', NULL, NULL);

      -- STORNO JEDNÉ DRÁHY: potřebuje akci na DVOU drahách, protože
      -- u jednodráhové je `single` totéž co `event` a guard se schválně
      -- neuplatní. Bez téhle kontroly zůstal šestý guard nepokrytý.
      IF _sheet2 IS NOT NULL THEN
        _vysledek := public.create_booking(
          ARRAY[_sheet1, _sheet2], 'tournament', '__zkouska_storna_drahy__',
          ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
            + interval '405 days' + interval '8 hours') AT TIME ZONE 'Europe/Prague'),
          ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
            + interval '405 days' + interval '10 hours') AT TIME ZONE 'Europe/Prague'),
          _subj, NULL, '{}'::jsonb, NULL, false, NULL, 14000);

        SELECT array_agg((v)::uuid) INTO _ids
          FROM jsonb_array_elements_text(_vysledek->'reservation_ids') v;

        _pustil := true;
        BEGIN
          PERFORM public.cancel_booking(_ids[2], 'single', 'zkouška');
        EXCEPTION WHEN OTHERS THEN _pustil := false;
        END;
        IF _pustil THEN
          RAISE EXCEPTION 'cancel_booking(single) prošlo nad pevnou cenou na dvou drahách — musí skončit chybou.'
            USING ERRCODE = 'ZC002';
        END IF;

        SELECT round(sum(r.amount), 2) INTO _soucet
          FROM public.reservations r
         WHERE r.id = ANY(_ids) AND r.status = 'confirmed' AND r.deleted_at IS NULL;
        IF _soucet <> 14000 THEN
          RAISE EXCEPTION 'Po pokusu o storno dráhy je částka % místo 14000.', _soucet
            USING ERRCODE = 'ZC002';
        END IF;

        -- storno CELÉ akce ale projít MUSÍ, jinak ji nejde zrušit vůbec
        _pustil := true;
        BEGIN
          PERFORM public.cancel_booking(_ids[1], 'event', 'zkouška');
        EXCEPTION WHEN OTHERS THEN _pustil := false;
        END;
        IF NOT _pustil THEN
          RAISE EXCEPTION 'cancel_booking(event) neprošlo nad pevnou cenou — jediná cesta ven se zavřela.'
            USING ERRCODE = 'ZC002';
        END IF;

        -- A GUARD NESMÍ ZAVŘÍT VÍC, NEŽ MÁ.
        --
        -- U JEDNODRÁHOVÉ akce je `single` totéž co `event` — cenu nepůlí,
        -- ruší ji celou — takže tahle cesta zůstat otevřená MUSÍ. Bez téhle
        -- kontroly projde i guard zúžený na `p_scope = 'single' AND
        -- _res.cena_rucni` (tedy bez podmínky „existuje jiná živá dráha"),
        -- po kterém se jednodráhový paušál nedá stornovat vůbec. Testovat
        -- jen zavřený směr nestačí. (Nález brány migrací, ověřeno mutací.)
        _vysledek := public.create_booking(
          ARRAY[_sheet1], 'tournament', '__zkouska_storna_jedne_drahy__',
          ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
            + interval '406 days' + interval '8 hours') AT TIME ZONE 'Europe/Prague'),
          ((date_trunc('day', now() AT TIME ZONE 'Europe/Prague')
            + interval '406 days' + interval '10 hours') AT TIME ZONE 'Europe/Prague'),
          _subj, NULL, '{}'::jsonb, NULL, false, NULL, 3000);

        SELECT array_agg((v)::uuid) INTO _ids
          FROM jsonb_array_elements_text(_vysledek->'reservation_ids') v;

        _pustil := true;
        BEGIN
          PERFORM public.cancel_booking(_ids[1], 'single', 'zkouška');
        EXCEPTION WHEN OTHERS THEN _pustil := false;
        END;
        IF NOT _pustil THEN
          RAISE EXCEPTION 'cancel_booking(single) neprošlo u JEDNODRÁHOVÉ pevně oceněné akce — guard zavřel i cestu, která zůstat otevřená má.'
            USING ERRCODE = 'ZC002';
        END IF;
      END IF;

      RAISE EXCEPTION 'vraceni' USING ERRCODE = 'ZC001';
    EXCEPTION
      WHEN SQLSTATE 'ZC001' THEN NULL;
      WHEN SQLSTATE 'ZC002' THEN RAISE;
    END;
    PERFORM set_config('request.jwt.claims', NULL, true);
  END IF;

  -- Hláška MUSÍ ODPOVÍDAT tomu, co se opravdu proměřilo. Na prázdné databázi
  -- (lokální `db reset` — dráhy a klub zakládá až seed, tedy AŽ PO migracích)
  -- se kontrola chování přeskakuje, takže tvrdit „mutační cesty jsou zavřené"
  -- by bylo nepodložené. Kdo si guardy chce ověřit lokálně, spustí tenhle blok
  -- znovu nad naseedovanou databází, nebo pustí `supabase/tests/rucni_cena_test.sql`.
  IF _sheet1 IS NULL OR _subj IS NULL OR _admin IS NULL THEN
    RAISE NOTICE 'Ruční celková cena: tvar objektů OK (příznak, CHECKy, granty, podklady). Chování NEPROMĚŘENO — prázdná databáze.';
  ELSE
    RAISE NOTICE 'Ruční celková cena OK: rozpad sedí na haléř, částka se nepřepočítává, příznak je chráněný, podklady ho nesou a všech šest mutačních cest je zavřených.';
  END IF;
END $kontrola$;
