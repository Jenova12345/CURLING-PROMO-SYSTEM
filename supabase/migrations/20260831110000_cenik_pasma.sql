-- =============================================================================
-- Ceník ledu: časová pásma pro kluby, komerční paušál
-- Blok ceníku ledu · rozhodnutí PM 31. 8. 2026
-- =============================================================================
-- CO SE MĚNÍ:
--
-- Klubová cena přestává být jedno číslo a začíná záviset na DENNÍ DOBĚ:
--
--   všední den   6–14   800 Kč/h        (ranní — ⚠️ ČEKÁ NA POTVRZENÍ KLIENTA)
--                14–17  1000 Kč/h
--                17–22  1200 Kč/h       (do zavírací doby, rozhodnutí PM)
--   víkend       kdykoli 1000 Kč/h
--
-- Všechno VČETNĚ DPH (klubový ceník je vedený s daní) a odstupňované po 200.
-- Komerční zákazník má dál jednu sazbu, nově 5 000 Kč/h BEZ DPH.
--
-- -----------------------------------------------------------------------------
-- ⚠️ OTÁZKA NA PM — NEZODPOVĚZENO, A MĚNÍ TO ÚČTOVANÉ ČÁSTKY
-- -----------------------------------------------------------------------------
-- Pásma se vztahují na VŠECHEN klubový led kromě komerčních akcí a náboru.
-- Tím pro kluby PŘESTÁVAJÍ platit `settings.training_rate` a `tournament_rate`,
-- které jsou dnes vyplněné (600 a 800 Kč/h) a v Nastavení dál vidět.
--
-- Změřeno na seedu:
--   klubový turnaj 17–19   dřív 2 × 800 = 1 600 Kč   → nově 2 × 1 200 = 2 400 Kč
--   klubový trénink večer  dřív     600 Kč/h         → nově      1 200 Kč/h
--
-- Vypadá to jako záměr (ceník podle denní doby by jinak na klubový led skoro
-- nedosáhl — trénink a turnaj JSOU ten klubový led), ale je to rozhodnutí
-- o cenách, ne technická věc. Do potvrzení PM platí, co je v kódu, a obě pole
-- jsou pro kluby MRTVÁ — ne rozbitá, jen se na ně nikdo neptá.
--
-- Až to PM potvrdí: buď se ta dvě pole označí v Nastavení za neúčinná pro
-- kluby, nebo se pásma zúží a `tournament_rate`/`training_rate` dostanou
-- přednost. Obojí je pár řádků v `set_reservation_pricing`.
--
-- -----------------------------------------------------------------------------
-- ROZHODNUTÍ PM: REZERVACE PŘES HRANICI PÁSMA SE POČÍTÁ PO HODINÁCH
-- -----------------------------------------------------------------------------
-- Rezervace 16:00–19:00 stojí 1×1000 + 2×1200 = 3 400 Kč, ne 3×1000.
-- NEDĚLÍ se přitom na dvě rezervace — v kalendáři zůstává jedna.
--
-- ⚠️ TÍM PŘESTÁVÁ PLATIT, ŽE `amount = hodiny × rate_per_hour`, a je potřeba
-- vědět proč: 3 400 / 3 h = 1 133,33… Kč/h, což NENÍ celá koruna. Dosavadní
-- pravidlo „sazba se zadává v celých korunách" na takovou rezervaci nesedí.
--
-- Není to obcházení pravidla, je to jiná veličina. Dosud byla sazba VSTUP
-- (admin ji zadal, částka se z ní spočítala). U pásem je vstupem ROZPIS
-- a `rate_per_hour` je z něj ODVOZENÝ průměr — informativní číslo do přehledů,
-- ne podklad pro výpočet. Autoritativní je nově `amount`.
--
-- Co z toho plyne a co tahle migrace zařizuje:
--   • `reservations.cenove_pasma` — rozpis po pásmech (jsonb). Bez něj by se
--     nedalo doložit, jak částka vznikla, ani vystavit poctivý doklad.
--   • `rate_per_hour` smí mít haléře, ale JEN u rezervace s rozpisem přes víc
--     pásem. Ručně zadaná sazba zůstává v celých korunách — překlep o řád má
--     pořád narazit.
--   • ŘÁDEK DOKLADU UŽ NENÍ „hodiny × sazba", ale jeden řádek NA PÁSMO. Jinak
--     by 3 × 1 133,33 dalo 3 399,99 a kontrolní součet by se rozešel o haléř
--     na každé takové faktuře. Dělá to mapovací vrstva (`billing/mapping.ts`);
--     tahle migrace k tomu jen uvolňuje `fakturoid_radku_sedi`.
--
-- -----------------------------------------------------------------------------
-- VRATNOST (v tomhle pořadí):
--   -- 1) Funkce, které se sem přepisovaly, zpátky ze ŽIVÉHO schématu
--   --    (pg_get_functiondef), ne ze starých migrací — jinak zmizí výjimky,
--   --    které do nich vložily migrace mezitím:
--   --      set_reservation_pricing, check_reservation_money,
--   --      fakturoid_podklady_klub (uuid,date,date), fakturoid_podklady_akce (uuid)
--   --    U OBOU RPC nezapomeň na REVOKE/GRANT — po DROPu se práva nedědí.
--   -- 2) Constrainty. POZOR: `... NOT VALID` je tu nutnost, ne opatrnost.
--   --    Pásmové rezervace mají `rate_per_hour` s haléři (odvozený průměr),
--   --    takže přísná verze constraintu je na existujících datech NEPLATNÁ
--   --    a `ADD CONSTRAINT` bez `NOT VALID` revert rovnou zastaví:
--   --      ERROR: check constraint "reservations_rate_per_hour_cele_koruny"
--   --             is violated by some row
--   --    S `NOT VALID` se pravidlo vztahuje na nové a měněné řádky, staré
--   --    projdou. Zvalidovat (`VALIDATE CONSTRAINT`) půjde teprve, až se ty
--   --    rezervace doúčtují nebo se jim sazba srovná na celé koruny.
--   ALTER TABLE public.reservations DROP CONSTRAINT IF EXISTS reservations_cenove_pasma_sedi;
--   ALTER TABLE public.reservations DROP CONSTRAINT IF EXISTS reservations_rate_per_hour_cele_koruny;
--   ALTER TABLE public.reservations ADD CONSTRAINT reservations_rate_per_hour_cele_koruny
--     CHECK (rate_per_hour IS NULL OR (rate_per_hour >= 0 AND rate_per_hour = round(rate_per_hour)))
--     NOT VALID;
--   ALTER TABLE public.fakturoid_invoices DROP CONSTRAINT IF EXISTS fakturoid_radku_sedi;
--   ALTER TABLE public.fakturoid_invoices ADD CONSTRAINT fakturoid_radku_sedi
--     CHECK (radku = cardinality(rezervace));
--   -- `fakturoid_radku_sedi` zpátky na rovnost projde jen tehdy, když se
--   -- mezitím nevystavil doklad s víc řádky než rezervacemi (pásmová faktura).
--   -- Když spadne, je to správně: takový doklad by rovnosti odporoval.
--   -- 3) Teprve pak sloupec a ceník. DROP COLUMN by jinak vzal s sebou
--   --    `reservations_rate_per_hour_cele_koruny` (závisí na něm) a pravidlo
--   --    o celých korunách by zmizelo úplně:
--   ALTER TABLE public.reservations DROP COLUMN IF EXISTS cenove_pasma;
--   DROP FUNCTION IF EXISTS public.cena_ledu(timestamptz, timestamptz);
--   DROP FUNCTION IF EXISTS public.cenove_pasma_sedi(jsonb, numeric);
--   DROP TABLE IF EXISTS public.cenik_pasma;
--   DROP TYPE IF EXISTS public.den_typ;
--   -- 4) A ceník komerčních zpátky, pokud ho admin mezitím nezměnil:
--   UPDATE public.settings SET commercial_default_rate = 1500
--    WHERE singleton AND commercial_default_rate = 5000;
--
-- ⚠️ POZOR NA SIGNATURU `cena_ledu`: je dvouparametrová. `DROP FUNCTION
-- IF EXISTS` se špatnou signaturou NESPADNE — jen tiše neudělá nic, a revert
-- by se tvářil jako hotový. (Dřívější znění téhle poznámky uvádělo tři
-- parametry, což byla přesně tahle past.)
--
-- Ceny už vzniklých rezervací revert NEPŘEPOČÍTÁ — jsou to snapshoty.
-- Rezervace založené pod pásmovým ceníkem si po revertu ponesou `rate_per_hour`
-- s haléři. Díky `NOT VALID` zůstanou uložené, ale jejich UPDATE už na
-- constraint narazí — dokud se jim sazba nesrovná. Je to vědomá daň za revert.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Pásma
--
-- KONFIGUROVATELNÁ SCHVÁLNĚ (zadání PM): ranní pásmo 6–14 čeká na potvrzení
-- klienta a musí jít změnit bez migrace. Proto tabulka, ne konstanty.
--
-- Interval je POLOOTEVŘENÝ [od, do): pásmo 14–17 platí pro hodiny 14, 15, 16.
-- Bez téhle dohody by hodina 17:00 patřila do dvou pásem a cena by závisela na
-- pořadí řádků.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type
                  WHERE typname = 'den_typ' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.den_typ AS ENUM ('vsedni', 'vikend');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.cenik_pasma (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  den_typ    public.den_typ NOT NULL,
  od_hodina  smallint NOT NULL,
  do_hodina  smallint NOT NULL,
  sazba      numeric(10,2) NOT NULL,
  popis      text NOT NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.profiles(user_id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.profiles(user_id),
  -- Zásada 2: nic nemazat natvrdo. Vyřazené pásmo se schová, ať se nedá ztratit
  -- historie toho, za co se kdy fakturovalo.
  deleted_at timestamptz,

  CONSTRAINT cenik_pasma_rozsah   CHECK (od_hodina >= 0 AND do_hodina <= 24 AND od_hodina < do_hodina),
  -- Táž mez jako u ceníku ledu jinde (`strop_sazby`, rozhodnutí PM): překlep
  -- o řád má narazit, ne se vyfakturovat.
  CONSTRAINT cenik_pasma_sazba    CHECK (sazba > 0 AND sazba <= 50000),
  -- Celé koruny — pásmová sazba je VSTUP, který zadává admin. Haléře smí mít
  -- až odvozený průměr na rezervaci, ne ceník.
  CONSTRAINT cenik_pasma_cele     CHECK (sazba = round(sazba)),
  CONSTRAINT cenik_pasma_popis    CHECK (btrim(popis) <> '')
);

-- PÁSMA SE NESMÍ PŘEKRÝVAT. Bez toho by hodina spadla do dvou pásem a cena by
-- závisela na tom, které vrátí plánovač dřív — tedy na ničem.
-- `int4range` s polootevřeným intervalem `[)` zrcadlí dohodu z komentáře výš.
ALTER TABLE public.cenik_pasma DROP CONSTRAINT IF EXISTS cenik_pasma_bez_prekryvu;
ALTER TABLE public.cenik_pasma ADD CONSTRAINT cenik_pasma_bez_prekryvu
  -- `den_typ` se do gistu dává PŘÍMO, ne přes `::text`: cast z enumu na text
  -- není IMMUTABLE a index ho nepřijme („functions in index expression must be
  -- marked IMMUTABLE"). Rovnost nad enumem umí `btree_gist`, které je v repu
  -- už kvůli `reservations_no_overlap`.
  EXCLUDE USING gist (
    den_typ WITH =,
    int4range(od_hodina::int, do_hodina::int, '[)') WITH &&
  )
  -- JEN NAD ŽIVÝMI PÁSMY. Bez tohohle by vyřazené pásmo dál blokovalo místo,
  -- které uvolnilo, a admin by na jeho hodiny už žádné nové nezaložil.
  WHERE (deleted_at IS NULL);

COMMENT ON TABLE public.cenik_pasma IS
  'Časová pásma klubového ceníku ledu. Ceny jsou VČETNĚ DPH. Interval je polootevřený [od, do) — pásmo 14–17 platí pro hodiny 14, 15 a 16. Pásma se v rámci téhož typu dne nesmí překrývat (exclusion constraint). Komerčních zákazníků se netýká, ti mají jednu sazbu v settings.commercial_default_rate. Vyřazuje se soft delete (deleted_at) — cena_ledu i exclusion constraint berou v potaz jen živá pásma.';

DROP TRIGGER IF EXISTS trg_cenik_pasma_updated ON public.cenik_pasma;
CREATE TRIGGER trg_cenik_pasma_updated
  BEFORE UPDATE ON public.cenik_pasma
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_fields();

DROP TRIGGER IF EXISTS trg_cenik_pasma_audit ON public.cenik_pasma;
CREATE TRIGGER trg_cenik_pasma_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.cenik_pasma
  FOR EACH ROW EXECUTE FUNCTION public.write_audit_log();

-- -----------------------------------------------------------------------------
-- 2) Sazby od PM
--
-- `ON CONFLICT DO NOTHING` nejde (není na čem), takže se vkládá jen tehdy,
-- když je tabulka prázdná. Opakovaný běh migrace tím admina nepřepíše zpátky
-- na výchozí — a přepsat ceník migrací je horší než migrace bez efektu.
-- -----------------------------------------------------------------------------
INSERT INTO public.cenik_pasma (den_typ, od_hodina, do_hodina, sazba, popis)
SELECT * FROM (VALUES
  ('vsedni'::public.den_typ,  6::smallint, 14::smallint,  800::numeric, 'Ranní (čeká na potvrzení klienta)'),
  ('vsedni'::public.den_typ, 14::smallint, 17::smallint, 1000::numeric, 'Odpolední'),
  ('vsedni'::public.den_typ, 17::smallint, 22::smallint, 1200::numeric, 'Večerní špička (do zavírací doby)'),
  ('vikend'::public.den_typ,  0::smallint, 24::smallint, 1000::numeric, 'Víkend kdykoliv')
) AS v(den_typ, od_hodina, do_hodina, sazba, popis)
WHERE NOT EXISTS (SELECT 1 FROM public.cenik_pasma WHERE deleted_at IS NULL);

-- -----------------------------------------------------------------------------
-- 3) Práva
--
-- Ceník ledu čte KAŽDÝ přihlášený? NE. Rozhodnutí klienta z 31. 7.: „obsazenost
-- a název klubu vidí všichni přihlášení, ČÁSTKU jen admin a autor." Sazby jsou
-- částky. Táž úvaha jako u `settings` v A2b — a `cenik_pasma_test.sql`, sekce 5e
-- na to má regresní test (běží pod `SET LOCAL ROLE authenticated`).
-- -----------------------------------------------------------------------------
ALTER TABLE public.cenik_pasma ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cenik_pasma FROM anon, authenticated, public;
GRANT SELECT ON public.cenik_pasma TO authenticated;
-- DELETE se NEUDĚLUJE (zásada 2). Vyřazení pásma se dělá `deleted_at`, ať se
-- nedá ztratit, za co se kdy fakturovalo. Audit log by natvrdo smazaný řádek
-- sice zachytil, ale ceník sám by o něm už nevěděl.
GRANT INSERT ON public.cenik_pasma TO authenticated;
GRANT UPDATE (den_typ, od_hodina, do_hodina, sazba, popis, deleted_at) ON public.cenik_pasma TO authenticated;

DROP POLICY IF EXISTS cenik_pasma_admin ON public.cenik_pasma;
CREATE POLICY cenik_pasma_admin ON public.cenik_pasma
  FOR ALL TO authenticated
  USING (has_role(auth.uid(), 'admin'))
  WITH CHECK (has_role(auth.uid(), 'admin'));

-- -----------------------------------------------------------------------------
-- 4) Výpočet ceny po hodinách
--
-- Vrací ROZPIS, ne jen částku. Rozpis je to podstatné: z něj se skládá řádek
-- dokladu (jeden na pásmo) a jen díky němu jde doložit, jak částka vznikla.
--
-- Čas se převádí do PRAŽSKÉHO pásma. `start_at` je `timestamptz`, takže bez
-- převodu by se pásma posunula o hodinu podle letního času — a rezervace na
-- 17:00 by se v zimě ocenila jako odpolední.
--
-- IMMUTABLE být NEMŮŽE (čte tabulku), takže ani do CHECKu nepatří — a nepatří
-- tam ani významově: cena je snapshot v okamžiku vzniku, ne invariant řádku.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cena_ledu(
  _start timestamptz,
  _end   timestamptz
)
 RETURNS TABLE (castka numeric, rozpis jsonb)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _h        timestamptz;
  _hodina   int;
  _je_vikend boolean;
  _sazba    numeric;
  _po_sazbach jsonb := '{}'::jsonb;
  _klic     text;
BEGIN
  IF _start IS NULL OR _end IS NULL OR _end <= _start THEN
    RAISE EXCEPTION 'Neplatný časový rozsah pro výpočet ceny.';
  END IF;

  -- Po hodinách. Rezervace jsou od `validate_reservation_slot` celé hodiny,
  -- takže smyčka vždycky vyjde přesně; kdyby se to někdy uvolnilo, poslední
  -- neúplná hodina by se sem nedostala a bylo by to vidět na součtu.
  _h := _start;
  WHILE _h < _end LOOP
    _hodina := extract(hour FROM (_h AT TIME ZONE 'Europe/Prague'))::int;
    _je_vikend := extract(isodow FROM (_h AT TIME ZONE 'Europe/Prague')) >= 6;

    SELECT p.sazba INTO _sazba
      FROM public.cenik_pasma p
     WHERE p.den_typ = (CASE WHEN _je_vikend THEN 'vikend' ELSE 'vsedni' END)::public.den_typ
       AND _hodina >= p.od_hodina AND _hodina < p.do_hodina
       AND p.deleted_at IS NULL;

    IF _sazba IS NULL THEN
      -- RADŠI NEVYSTAVIT NEŽ OCENIT NAPRÁZDNO. Hodina bez pásma znamená, že
      -- se rozešla otevírací doba s ceníkem — a tichá nula nebo pád na výchozí
      -- sazbu by se projevily až na faktuře.
      RAISE EXCEPTION 'Hodina % (% ) nemá v ceníku pásmo. Doplň ho v Nastavení, nebo uprav otevírací dobu.',
        _hodina, CASE WHEN _je_vikend THEN 'víkend' ELSE 'všední den' END;
    END IF;

    -- Sčítá se PO SAZBÁCH, ne po hodinách: doklad má mít jeden řádek na sazbu
    -- („2 h × 1 200"), ne řádek na každou hodinu.
    _klic := _sazba::text;
    _po_sazbach := jsonb_set(_po_sazbach, ARRAY[_klic],
      to_jsonb(COALESCE((_po_sazbach ->> _klic)::numeric, 0) + 1));

    _h := _h + interval '1 hour';
  END LOOP;

  SELECT
    -- Přesný součet, nic se průběžně nezaokrouhluje (pravidlo R3).
    COALESCE(sum((k.key)::numeric * (k.value)::numeric), 0),
    COALESCE(jsonb_agg(jsonb_build_object('sazba', (k.key)::numeric, 'hodin', (k.value)::numeric)
                       ORDER BY (k.key)::numeric), '[]'::jsonb)
    INTO castka, rozpis
    FROM jsonb_each_text(_po_sazbach) AS k;

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.cena_ledu(timestamptz, timestamptz) IS
  'Cena pronájmu ledu po hodinách podle cenik_pasma. Vrací částku a ROZPIS po sazbách — z rozpisu se skládají řádky dokladu (jeden na sazbu), aby 3 h přes dvě pásma nedaly na faktuře 3 × průměr. Hodina bez pásma je chyba, ne nula.';

-- PRÁVA: NIKOMU. Volá ji jen `set_reservation_pricing`, což je SECURITY DEFINER
-- trigger — ten běží pod vlastníkem a žádný grant k tomu nepotřebuje.
--
-- A hlavně: s grantem pro `authenticated` by tahle funkce OBEŠLA RLS na
-- `cenik_pasma`. Ta pouští ceník jen adminovi (sazby jsou částky, rozhodnutí
-- klienta z 31. 7.), jenže SECURITY DEFINER funkce čte tabulku pod vlastníkem —
-- takže by si člen klubu vyjel cenu hodinu po hodině a složil celý ceník.
-- Ověřeno: bez tohohle REVOKE vrátí `cena_ledu` členovi 1 200 Kč tam, kde mu
-- `SELECT * FROM cenik_pasma` vrátí nula řádků. Regresní test je
-- v `cenik_pasma_test.sql`.
--
-- Týž vzorec jako u `fakturovatelne_rezervace`, která má EXECUTE odebrané i
-- `service_role` právě proto, že se volá jen z jiné SECURITY DEFINER funkce.
REVOKE ALL ON FUNCTION public.cena_ledu(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5) Rozpis na rezervaci
-- -----------------------------------------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS cenove_pasma jsonb;

COMMENT ON COLUMN public.reservations.cenove_pasma IS
  'Rozpis ceny po sazbách, snapshot z doby vzniku: [{"sazba":1000,"hodin":1},{"sazba":1200,"hodin":2}]. Vyplněné jen u klubových rezervací oceněných pásmovým ceníkem. Z tohohle rozpisu se skládají řádky dokladu — `hodiny × rate_per_hour` u rezervace přes víc pásem nedá přesnou částku, protože rate_per_hour je odvozený průměr.';

-- -----------------------------------------------------------------------------
-- 5b) Záruku dává CHECK, ne jen trigger
--
-- Zásada projektu: „záruku dávají CHECK constrainty, trigger jen mluví dřív."
-- U rozpisu to platí dvojnásob — rozhoduje o tom, co se vyfakturuje, a sloupec
-- je pro `authenticated` zapisovatelný (tabulkové granty na `reservations`).
--
-- Hlídají se dvě věci: TVAR (pole objektů s kladnými hodinami a nezápornou
-- sazbou) a SOUČET — rozpis musí dát přesně `amount`. Tím je vyloučené, že by
-- na dokladu stálo něco jiného než v „Kdo kolik dluží", ať už omylem nebo
-- naschvál.
--
-- Funkce musí být IMMUTABLE, aby šla do CHECKu; nesahá na žádnou tabulku,
-- takže to sedí i významově.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cenove_pasma_sedi(_rozpis jsonb, _amount numeric)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $$
  SELECT _rozpis IS NULL
      OR (jsonb_typeof(_rozpis) = 'array'
          AND jsonb_array_length(_rozpis) > 0
          AND _amount IS NOT NULL
          AND NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(_rozpis) p
                 WHERE jsonb_typeof(p) <> 'object'
                    OR jsonb_typeof(p -> 'sazba') <> 'number'
                    OR jsonb_typeof(p -> 'hodin') <> 'number'
                    OR (p ->> 'sazba')::numeric < 0
                    OR (p ->> 'hodin')::numeric <= 0)
          AND (SELECT round(sum((p ->> 'sazba')::numeric * (p ->> 'hodin')::numeric), 2)
                 FROM jsonb_array_elements(_rozpis) p) = round(_amount, 2));
$$;

COMMENT ON FUNCTION public.cenove_pasma_sedi(jsonb, numeric) IS
  'Platí rozpis po pásmech pro danou částku? Hlídá tvar (pole objektů, kladné hodiny, nezáporná sazba) a hlavně součet — rozpis musí dát přesně `amount`, jinak by doklad ukázal jinou částku než „Kdo kolik dluží". IMMUTABLE, aby šla použít v CHECK constraintu.';

ALTER TABLE public.reservations DROP CONSTRAINT IF EXISTS reservations_cenove_pasma_sedi;
ALTER TABLE public.reservations ADD CONSTRAINT reservations_cenove_pasma_sedi
  CHECK (public.cenove_pasma_sedi(cenove_pasma, amount));

COMMENT ON CONSTRAINT reservations_cenove_pasma_sedi ON public.reservations IS
  'Rozpis po pásmech musí sedět na `amount`. Existující rezervace bez rozpisu projdou — NULL je povolené.';

-- -----------------------------------------------------------------------------
-- 6) Napojení na rezervace
--
-- CELÉ TĚLO JE VYGENEROVANÉ Z `pg_get_functiondef` ŽIVÉHO SCHÉMATU (pravidlo 7
-- z CLAUDE.md). Zásahy jsou tři a diff proti živé verzi byl kontrolovaný:
--   • pásmová větev pro kluby (před dosavadní logikou sazeb),
--   • `amount` se u pásmové ceny NEPŘEPOČÍTÁVÁ z `hodiny × sazba` při UPDATE,
--   • ale PŘESUN/PRODLOUŽENÍ rezervaci přecení z ceníku (jinak by na novém
--     čase zůstala stará cena a rozpis by se rozešel s hodinami),
--   • dvě nové proměnné.
-- Jediný ubraný řádek je ten, který se nahradil svou podmíněnou verzí.
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

  IF NEW.subject_id IS NULL THEN
    NEW.rate_per_hour    := NULL;
    NEW.amount           := NULL;
    NEW.corrected_amount := NULL;
    NEW.hours := round((extract(epoch FROM (NEW.end_at - NEW.start_at)) / 3600.0)::numeric, 2);
    RETURN NEW;
  END IF;

  -- Snapshot sazby jen při vzniku; pozdější změna ceníku nepřepočítává minulé rezervace.
  IF TG_OP = 'INSERT' AND NEW.rate_per_hour IS NULL THEN
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
-- 7) Sazba s haléři — jen u pásmové ceny
--
-- `check_reservation_money` dosud trvala na celých korunách u KAŽDÉ sazby.
-- U pásmové ceny je ale `rate_per_hour` odvozený průměr (3 400 / 3 h), takže
-- celá koruna z principu nevyjde. Pravidlo se proto neruší, jen se zužuje na
-- to, čeho se doopravdy týkalo: na sazbu, kterou ZADAL ČLOVĚK.
--
-- Překlep o řád tím pádem pořád narazí všude, kde se sazba zadává —
-- v ceníku (`cenik_pasma_cele`), u subjektu, i u ruční sazby na rezervaci.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_reservation_money()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    IF NEW.cenove_pasma IS NULL AND NEW.rate_per_hour <> round(NEW.rate_per_hour) THEN
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
$$;

COMMENT ON FUNCTION public.check_reservation_money() IS
  'Srozumitelné české hlášky pro peněžní pravidla (A2 + A5: strop korekce 24 h a povinný důvod; + strop sazby 50 000 Kč/h). Od pásmového ceníku se celé koruny vyžadují jen u sazby BEZ rozpisu — s rozpisem je rate_per_hour odvozený průměr. Záruku dávají CHECK constrainty, tenhle trigger jen mluví dřív — hlavně kvůli RPC.';

-- A totéž v CHECK constraintu, který drží tutéž věc na úrovni schématu.
ALTER TABLE public.reservations DROP CONSTRAINT IF EXISTS reservations_rate_per_hour_cele_koruny;
ALTER TABLE public.reservations ADD CONSTRAINT reservations_rate_per_hour_cele_koruny
  CHECK (rate_per_hour IS NULL
         OR (rate_per_hour >= 0
             AND (cenove_pasma IS NOT NULL OR rate_per_hour = round(rate_per_hour))
             AND rate_per_hour = round(rate_per_hour, 2)));

-- -----------------------------------------------------------------------------
-- 8) Komerční sazba 5 000 Kč/h BEZ DPH (rozhodnutí PM)
--
-- `WHERE commercial_default_rate = 1500` schválně: přepíše se jen dosavadní
-- výchozí hodnota. Kdyby ji admin mezitím změnil na něco jiného, migrace mu to
-- nepřepíše — přepsat ceník migrací je horší než migrace bez efektu.
-- -----------------------------------------------------------------------------
UPDATE public.settings SET commercial_default_rate = 5000
 WHERE singleton AND commercial_default_rate = 1500;

-- -----------------------------------------------------------------------------
-- 9) Doklad smí mít víc řádků než rezervací
--
-- `fakturoid_radku_sedi` tvrdil `radku = cardinality(rezervace)` — jeden řádek
-- na rezervaci. Od pásmového ceníku to neplatí: rezervace 16–19 dá DVA řádky
-- (1 h × 1 000 a 2 h × 1 200), protože jinak by 3 × průměr nedalo přesnou
-- částku a kontrolní součet by se rozešel o haléř na každé takové faktuře.
--
-- Constraint se NERUŠÍ, jen se z rovnosti stává minimum: řádků musí být aspoň
-- tolik co rezervací. Míň by pořád znamenalo, že se rezervace na doklad
-- nedostala — a to je ta chyba, kterou původně hlídal.
-- -----------------------------------------------------------------------------
ALTER TABLE public.fakturoid_invoices DROP CONSTRAINT IF EXISTS fakturoid_radku_sedi;
ALTER TABLE public.fakturoid_invoices ADD CONSTRAINT fakturoid_radku_sedi
  CHECK (radku >= cardinality(rezervace));

-- -----------------------------------------------------------------------------
-- 11) Rozpis se musí dostat až k dokladu
--
-- Bez tohohle je celý pásmový rozpis slepá ulička: `mapping.ts` ho umí, ale
-- `fakturoid_podklady_klub` ho nevracela, takže by se klubová faktura složila
-- z `hodiny × průměr` = 3 399,99 proti částce 3 400 — a mapovací vrstva by ji
-- ODMÍTLA. Klubový doklad s rezervací přes dvě pásma by nešel vystavit vůbec.
--
-- Návratový typ funkce se mění, takže DROP + CREATE (`CREATE OR REPLACE` umí
-- změnit tělo, ne signaturu). Těla jsou vygenerovaná z `pg_get_functiondef`
-- živého schématu (pravidlo 7) — zásah je jen přidaný sloupec a join.
--
-- VRATNOST: obě funkce zpátky z migrace 20260824120000_fakturoid_vazba.sql
-- (v revertu nezapomeň na REVOKE/GRANT níž).
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fakturoid_podklady_klub(uuid, date, date);
CREATE OR REPLACE FUNCTION public.fakturoid_podklady_klub(_subject uuid, _od date, _do date)
 RETURNS TABLE(id uuid, start_at timestamp with time zone, end_at timestamp with time zone, sheet_name text, event_title text, hodiny numeric, sazba numeric, castka numeric, cenove_pasma jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE _zac timestamptz; _kon timestamptz;
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturační podklady.';
  END IF;

  -- Období v PRAŽSKÉM čase, jedním sdíleným místem. Kdyby si to tahle cesta
  -- počítala po svém, „srpen" pro Fakturoid a „srpen" pro kontrolní součet
  -- by se rozešly o dvě hodiny — a projevilo by se to jen u rezervací kolem
  -- půlnoci na přelomu měsíce, tedy tam, kde si toho nikdo nevšimne.
  SELECT h.zacatek, h.konec INTO _zac, _kon FROM public.obdobi_hranice(_od, _do) h;

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
     WHERE NOT EXISTS (
             SELECT 1 FROM public.fakturoid_invoice_reservations fr
              WHERE fr.reservation_id = f.id
           )
     ORDER BY f.start_at, f.id;
END;
$function$;

DROP FUNCTION IF EXISTS public.fakturoid_podklady_akce(uuid);
CREATE OR REPLACE FUNCTION public.fakturoid_podklady_akce(_event uuid)
 RETURNS TABLE(id uuid, start_at timestamp with time zone, end_at timestamp with time zone, sheet_name text, event_title text, hodiny numeric, sazba numeric, castka numeric, subject_id uuid, cenove_pasma jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT COALESCE(fakturoid_smi_volat(), false) THEN
    RAISE EXCEPTION 'Nemáte oprávnění číst fakturační podklady.';
  END IF;

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
     ORDER BY r.start_at, r.id;
END;
$function$;

-- COMMENTy taky nepřežijí DROP — bez tohohle by z obou funkcí zmizel popis
-- z migrace 20260824120000_fakturoid_vazba.sql.
COMMENT ON FUNCTION public.fakturoid_podklady_klub(uuid,date,date) IS
  'Podklady pro měsíční klubový doklad: potvrzené a schválené rezervace subjektu za období, které ještě nejsou na žádném dokladu. Vrací i `cenove_pasma` — rozpis, ze kterého se skládají řádky (jeden na sazbu). U rezervace s korekcí se rozpis NEVRACÍ, protože částka je pak z korekce a na původní rozpis nesedí.';
COMMENT ON FUNCTION public.fakturoid_podklady_akce(uuid) IS
  'Podklady pro doklad za komerční akci: potvrzené a schválené rezervace akce, které ještě nejsou na žádném dokladu. `cenove_pasma` je tu pro úplnost — komerční akce se pásmově neoceňují.';

-- Práva se po DROPu nedědí — bez tohohle by Edge funkce dostala „permission denied".
REVOKE ALL ON FUNCTION public.fakturoid_podklady_klub(uuid,date,date) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_podklady_klub(uuid,date,date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fakturoid_podklady_akce(uuid) FROM anon, authenticated, public, service_role;
GRANT EXECUTE ON FUNCTION public.fakturoid_podklady_akce(uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 10) Kontrola
--
-- Tvrzení jsou schválně DVOJÍ:
--   • strukturální platí pro JAKÝKOLI ceník — rozpis musí sednout na částku
--     a pokrýt všechny hodiny. To je invariant, na kterém stojí celý doklad.
--   • konkrétní částky (3 400 / 3 000 Kč) se ověřují JEN tehdy, když je ceník
--     pořád ve výchozím stavu od PM.
--
-- Proč to rozdělení: ceník je KONFIGUROVATELNÝ a migrace ho adminovi vědomě
-- nepřepisuje. S natvrdo zadanými částkami by druhý běh na databázi, kde si
-- admin ceník upravil, skončil hláškou „pásmový ceník je rozbitý", přestože je
-- všechno v pořádku — a zbytek migrace je přitom opakovatelný schválně.
-- -----------------------------------------------------------------------------
DO $$
DECLARE _c numeric; _r jsonb; _vychozi boolean;
BEGIN
  -- Strukturální kontrola: platí bez ohledu na sazby v ceníku.
  SELECT castka, rozpis INTO _c, _r
    FROM public.cena_ledu('2026-09-02 16:00+02', '2026-09-02 19:00+02');

  IF (SELECT sum((p ->> 'sazba')::numeric * (p ->> 'hodin')::numeric)
        FROM jsonb_array_elements(_r) p) <> _c THEN
    RAISE EXCEPTION 'Pásmový ceník: součet rozpisu nesedí na částku (% Kč). Doklad by ukázal jiné číslo než „Kdo kolik dluží".', _c;
  END IF;

  IF (SELECT sum((p ->> 'hodin')::numeric) FROM jsonb_array_elements(_r) p) <> 3 THEN
    RAISE EXCEPTION 'Pásmový ceník: rozpis nepokrývá všechny 3 hodiny — nějaká by se nevyfakturovala.';
  END IF;

  -- Konkrétní částky jen na nedotčeném ceníku od PM.
  SELECT count(*) = 4 INTO _vychozi FROM public.cenik_pasma
   WHERE deleted_at IS NULL
     AND (den_typ, od_hodina, do_hodina, sazba) IN (
           ('vsedni'::public.den_typ,  6::smallint, 14::smallint,  800::numeric),
           ('vsedni'::public.den_typ, 14::smallint, 17::smallint, 1000::numeric),
           ('vsedni'::public.den_typ, 17::smallint, 22::smallint, 1200::numeric),
           ('vikend'::public.den_typ,  0::smallint, 24::smallint, 1000::numeric));

  IF NOT _vychozi THEN
    RAISE NOTICE 'Pásmový ceník je funkční (rozpis sedí na částku). Konkrétní částky se nekontrolovaly — ceník už není ve výchozím stavu, což je v pořádku.';
    RETURN;
  END IF;

  IF _c <> 3400 THEN
    RAISE EXCEPTION 'Pásmový ceník: 16–19 ve všední den má dát 3 400 Kč, dal %.', _c;
  END IF;
  IF jsonb_array_length(_r) <> 2 THEN
    RAISE EXCEPTION 'Pásmový ceník: 16–19 má mít rozpis ze dvou sazeb, má %.', jsonb_array_length(_r);
  END IF;

  SELECT castka INTO _c FROM public.cena_ledu('2026-09-05 16:00+02', '2026-09-05 19:00+02');
  IF _c <> 3000 THEN
    RAISE EXCEPTION 'Pásmový ceník: sobota 16–19 má dát 3 000 Kč, dala %.', _c;
  END IF;

  RAISE NOTICE 'Pásmový ceník je funkční (16–19 všední = 3 400 Kč ze dvou pásem, sobota = 3 000 Kč).';
END $$;
