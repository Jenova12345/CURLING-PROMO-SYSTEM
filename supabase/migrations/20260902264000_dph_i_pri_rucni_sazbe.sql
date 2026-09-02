-- =============================================================================
-- Daňový význam ceny se určí i tehdy, když sazbu zadal admin (nález F3)
-- =============================================================================
-- KROK 0 — CO PLATÍ DNES (změřeno na produkci 2. 9. 2026):
--
-- `set_reservation_pricing()` má celý blok, který VYBÍRÁ SAZBU a zároveň
-- v posledním řádku určuje `cena_bez_dph`, podmíněný takto:
--
--     IF (TG_OP='INSERT' OR app.preceneni='on') AND NEW.rate_per_hour IS NULL
--
-- Když sazba přijde zvenčí, blok se přeskočí CELÝ — i ten poslední řádek.
-- `cena_bez_dph` pak zůstane na DEFAULTU sloupce (`false`), což znamená
-- „v `amount` už daň je". U komerčního zákazníka je to opačně: komerční sazba
-- (5 000 Kč/h) je vedená BEZ DPH.
--
-- Cesta, kudy sazba zvenčí chodí, je jediná a legitimní:
--   `create_booking(..., p_rate)` → `CASE WHEN _is_admin THEN p_rate ELSE NULL END`
-- Tedy: rezervaci, které admin při zakládání vyplnil cenu, se daňový příznak
-- nikdy nespočítal.
--
-- ZMĚŘENÝ DOPAD — 3 živé potvrzené rezervace:
--   c8f69733  Deloitte      10 000 Kč   → chybí 1 200 Kč DPH
--   21afc4b2  ZŠ Poruba      1 000 Kč   → chybí   120 Kč DPH
--   1defa008  ZŠ Poruba      1 000 Kč   → chybí   120 Kč DPH
--                                   celkem 1 440 Kč
-- (plus 1 zrušená, Hybridní vzdělávání — dnes bez dopadu, opraví se s nimi,
-- ať se nerozjede, kdyby ji někdo oživil)
--
-- Všechny mají `subject_type='commercial'` i `event_type='commercial'`, takže
-- `cena_je_bez_dph()` na nich dnes vrací `true`, kdežto uloženo mají `false`.
--
-- -----------------------------------------------------------------------------
-- CO SE MĚNÍ — a co schválně NE
-- -----------------------------------------------------------------------------
-- Podmínka se ROZDĚLÍ. Vnější zůstává „rezervace vzniká, nebo se vědomě
-- přeceňuje". Vnitřní `IF NEW.rate_per_hour IS NULL` řeší už jen VÝBĚR SAZBY.
-- Daňový příznak se určuje v obou větvích — je to vlastnost toho, KOMU a NA CO
-- se účtuje, ne toho, odkud se vzalo číslo.
--
-- ⚠️ NA UPDATE SE NESAHÁ. Mimo `app.preceneni` se dál drží
-- `NEW.cena_bez_dph := OLD.cena_bez_dph`, tedy snapshot. `uprav_sazbu_akce()`
-- přeceňuje BEZ `app.preceneni`, takže si daňový význam z okamžiku vzniku
-- ponechá — a to je správně: doklad už mohl odejít.
--
-- ⚠️ `zmen_typ_akce()` se nemění a nic se mu nerozbije: před přeceněním sazbu
-- nuluje (`SET rate_per_hour = NULL, cenove_pasma = NULL`), takže jde dál
-- vnitřní větví, přesně jako dosud.
--
-- MUTAČNÍ ZKOUŠKA: vrať `AND NEW.rate_per_hour IS NULL` zpátky na vnější
-- podmínku a pusť `supabase/tests/dph_rucni_sazba_test.sql` — musí zčervenat.
--
-- VRATNOST: funkce zpátky z 20260831231000_dph_jedno_misto.sql. Datová část
--   vratná není a nemá být — vrací příznaky do souladu s pravidlem.
-- =============================================================================

-- Radši spadnout na zámku než čekat za dlouhou transakcí: migrace mění
-- politiky a funkce za provozu a `AccessExclusiveLock` by mezitím blokoval
-- zápisy uživatelů. Tři vteřiny stačí, na klidné databázi se to neprojeví.
--
-- Schválně BEZ `LOCAL`: žádná migrace v tomhle repu si transakci neotvírá
-- sama, takže `SET LOCAL` by mimo transakční blok jen vypsal WARNING
-- a NEPLATIL. Na konci souboru se to vrací `RESET`em.
SET lock_timeout = '3s';

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
$function$

;

-- =============================================================================
-- DATOVÁ NÁPRAVA — rezervace, které vznikly, než se to opravilo
-- =============================================================================
-- Neopravuje se výčtem ID, ale PRAVIDLEM: srovnej uložený příznak s tím, co
-- `cena_je_bez_dph()` říká dnes. Výčet by minul cokoli, co mezitím vzniklo
-- toutéž cestou (a mezi nálezem a nasazením je den).
--
-- Zapisuje se PŘES TRIGGER, ne přímým `SET cena_bez_dph`: ať pravidlo zůstane
-- na jednom místě. `app.preceneni` je jediný povolený způsob, jak snapshot
-- přepsat. Sazba ani částka se tím nehnou — `rate_per_hour` je vyplněná, takže
-- se jen dopočítá `amount = hours × rate`, což dá totéž číslo.
--
-- Razítko schválení přežije: `zrus_schvaleni_pri_uprave()` se dívá na
-- (start, end, sheet, subject, rate, amount, cenove_pasma) a žádné z nich se
-- nemění.
DO $$
DECLARE _dotcenych int; _na_dokladu int; _zbyva int; _bez_sazby int;
BEGIN
  -- ZASTÁVKA: rezervaci, která už visí na dokladu, takhle přepsat NELZE.
  -- Posunout základ daně pod vystaveným dokladem se opravuje dobropisem,
  -- ne migrací. Dnes je dokladů nula, takže se to nestane — ale kdyby ano,
  -- ať to spadne a někdo se na to podívá, místo tichého přepsání.
  SELECT count(*) INTO _na_dokladu
    FROM public.reservations r
    JOIN public.subjects s ON s.id = r.subject_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.deleted_at IS NULL
     AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate)
     AND (r.invoice_id IS NOT NULL
          OR EXISTS (SELECT 1 FROM public.fakturoid_invoice_reservations f
                      WHERE f.reservation_id = r.id));
  IF _na_dokladu > 0 THEN
    RAISE EXCEPTION 'ZASTAVENO: % rezervací s vadným příznakem DPH už visí na dokladu. To se řeší dobropisem, ne migrací.', _na_dokladu;
  END IF;

  -- ZASTÁVKA DRUHÁ: rezervace BEZ sazby se tímhle zápisem nepřeznačí, ale
  -- PŘECENÍ. `SET rate_per_hour = r.rate_per_hour` je no-op jen tehdy, když
  -- sazba není NULL; u NULL projde zápis vnitřní větví `IF NEW.rate_per_hour
  -- IS NULL` a odvodí sazbu i částku z DNEŠNÍHO ceníku — a `zrus_schvaleni_
  -- pri_uprave()` to uvidí jako přecenění a shodí razítko.
  --
  -- Změřeno na odrolované kopii: rezervace za 1 000 Kč vyšla po nápravě na
  -- 9 000 Kč. Koncová kontrola `_zbyva` to NECHYTÍ — příznak by seděl a migrace
  -- by to ohlásila jako úspěch.
  --
  -- Na produkci dnes takový řádek není (ověřeno 2. 9. 2026: rezervací se
  -- subjektem a bez sazby je nula, všechny čtyři k nápravě sazbu mají), takže
  -- tahle zastávka nesmí nic zdržet. Je tu proto, že se ta situace nemá řešit
  -- tiše, ale rukama.
  SELECT count(*) INTO _bez_sazby
    FROM public.reservations r
    JOIN public.subjects s ON s.id = r.subject_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.deleted_at IS NULL
     AND r.rate_per_hour IS NULL
     AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate);
  IF _bez_sazby > 0 THEN
    RAISE EXCEPTION 'ZASTAVENO: % rezervací k nápravě nemá sazbu. Tenhle zápis by je přecenil dnešním ceníkem a shodil razítko schválení — musí se to udělat jinak.', _bez_sazby;
  END IF;

  PERFORM set_config('app.preceneni', 'on', true);

  -- `updated_by`/`updated_at` NECHÁVÁME BÝT. `set_updated_fields` je
  -- nepodmíněný a zapsal by `auth.uid()`, což je v migraci NULL — čtyřem
  -- peněžním řádkům by tím zmizelo, kdo s nimi naposledy hnul (dnes Jakub
  -- a Petr). To je proti zásadě 3 z CLAUDE.md a `audit_log` sice změnu
  -- zaznamená, ale sloupec sám by informaci ztratil. Řádek navíc nikdo
  -- needitoval — mění se odvozený příznak, ne zadaná hodnota.
  ALTER TABLE public.reservations DISABLE TRIGGER trg_reservations_updated;

  WITH k_naprave AS (
    SELECT r.id
      FROM public.reservations r
      JOIN public.subjects s ON s.id = r.subject_id
      LEFT JOIN public.events e ON e.id = r.event_id
     WHERE r.deleted_at IS NULL
       AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate)
  )
  -- Zápis bez skutečné změny hodnoty; jde o to nechat proběhnout trigger,
  -- který příznak dopočítá podle pravidla.
  UPDATE public.reservations r
     SET rate_per_hour = r.rate_per_hour
    FROM k_naprave k
   WHERE r.id = k.id;
  GET DIAGNOSTICS _dotcenych = ROW_COUNT;

  ALTER TABLE public.reservations ENABLE TRIGGER trg_reservations_updated;
  PERFORM set_config('app.preceneni', 'off', true);

  SELECT count(*) INTO _zbyva
    FROM public.reservations r
    JOIN public.subjects s ON s.id = r.subject_id
    LEFT JOIN public.events e ON e.id = r.event_id
   WHERE r.deleted_at IS NULL
     AND r.cena_bez_dph IS DISTINCT FROM public.cena_je_bez_dph(s.type, e.event_type, s.default_rate);

  IF _zbyva > 0 THEN
    RAISE EXCEPTION 'ZASTAVENO: po nápravě zbývá % rezervací, u kterých příznak DPH pořád nesedí s pravidlem.', _zbyva;
  END IF;

  RAISE NOTICE 'Příznak DPH srovnán u % rezervací; nesouhlasných zůstalo 0.', _dotcenych;
END $$;

-- =============================================================================
-- SEBEKONTROLA — peněžní funkce se přepisuje celá, tak ať se nic neztratí
-- =============================================================================
-- `set_reservation_pricing()` je nejdelší funkce v peněžní vrstvě a přepisuje
-- se `CREATE OR REPLACE`, tedy celým tělem. Tenhle blok tvrdí, že v ní po
-- přepisu pořád jsou všechny obrany, kvůli kterým tam přibyly.
DO $kontrola$
DECLARE _telo text;
BEGIN
  SELECT prosrc INTO _telo FROM pg_proc
   WHERE oid = 'public.set_reservation_pricing()'::regprocedure;

  IF _telo NOT LIKE '%NEW.cenove_pasma := NULL%' THEN
    RAISE EXCEPTION 'Zahazování podstrčeného rozpisu pásem zmizelo.';
  END IF;
  IF _telo NOT LIKE '%NEW.cena_bez_dph := OLD.cena_bez_dph%' THEN
    RAISE EXCEPTION 'Držení daňového snapshotu na UPDATE zmizelo — příznak by šlo podstrčit zvenčí.';
  END IF;
  IF _telo NOT LIKE '%app.preceneni%' THEN
    RAISE EXCEPTION 'Brána přecenění (app.preceneni) zmizela.';
  END IF;
  IF _telo NOT LIKE '%Sazba není nastavena%'
     OR _telo NOT LIKE '%nesmí zůstat prázdná%' THEN
    RAISE EXCEPTION 'Některá z pojistek proti rezervaci bez sazby zmizela.';
  END IF;
  IF _telo NOT LIKE '%cena_je_bez_dph%' THEN
    RAISE EXCEPTION 'Určení daňového významu ceny zmizelo.';
  END IF;

  -- Jádro téhle migrace: příznak se musí určit v OBOU větvích, tedy dvakrát.
  IF (length(_telo) - length(replace(_telo, 'NEW.cena_bez_dph := public.cena_je_bez_dph', '')))
     / length('NEW.cena_bez_dph := public.cena_je_bez_dph') <> 2 THEN
    RAISE EXCEPTION 'Daňový příznak se neurčuje v obou větvích — oprava F3 se nezapsala celá.';
  END IF;

  RAISE NOTICE 'set_reservation_pricing(): obrany na místě, daňový příznak se určuje i při ruční sazbě.';
END $kontrola$;

RESET lock_timeout;
