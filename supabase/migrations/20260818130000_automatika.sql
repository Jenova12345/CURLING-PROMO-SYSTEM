-- =============================================================================
-- Fáze D — automatika fakturace
-- =============================================================================
-- CO DĚLÁ
--   * DENNĚ: proběhlé komerční akce → koncept faktury na akci
--   * MĚSÍČNĚ (den podle `billing_settings.monthly_run_day`): souhrnná faktura
--     klubu za předchozí měsíc
--
-- DVA VYPÍNAČE, OBA VYPNUTÉ (rozhodnutí PM):
--   `automation_enabled = false` — plánovač smí tikat týdny naprázdno, ať je
--       vidět, že běží, DŘÍV než smí cokoli založit,
--   `auto_issue = false` — první měsíc jen KONCEPTY. Vystavení je nevratné
--       (spálí číslo v řadě, doklad je od té chvíle neměnný), takže si ho
--       automatika zaslouží až po tom, co si člověk její výstupy prohlédne.
--
-- HODINOVÝ TIK, NE „POSLEDNÍ DEN VE 2:00" (R6): pg_cron vyhodnocuje výrazy
-- v UTC a přes přechod na letní čas by se to rozešlo. Rozhodnutí „má se něco
-- stát?" dělá tahle funkce podle PRAŽSKÉHO času. Bonus: po výpadku se běh
-- dožene sám a chybějící tik je levný „mrtvý muž".
--
-- IDEMPOTENCE stojí na dvou nezávislých věcech, ne na jedné:
--   1) `reservations.invoice_id` — rezervace vyfakturovaná jednou se podruhé
--      nenabídne, takže dvojí běh nemůže vyrobit dvojí doklad ani při závodě,
--   2) `billing_runs` — evidence běhů, aby se stejná práce znovu ani nezkoušela
--      a aby bylo vidět, co automatika kdy udělala.
-- Kdyby platila jen evidence, stačil by její výpadek k dvojí fakturaci; kdyby
-- jen zámek, běh by se pokoušel donekonečna a nikdo by nevěděl proč.
--
-- INSTALACE pg_cron JE KROK NASAZENÍ, ne součást téhle migrace (pokyn PM):
-- rozšíření se zapíná na projektu a plán se zakládá zvlášť — viz konec souboru.
--
-- VRATNOST:
--   DROP FUNCTION IF EXISTS public.billing_automation_tick();
--   DROP TABLE IF EXISTS public.billing_runs;
--   -- a tři fakturační RPC zpět do znění bez větve pro cron
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Evidence běhů
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_runs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  druh        text NOT NULL CHECK (druh IN ('komercni_denni', 'kluby_mesicni')),
  -- Co přesně se tímhle během řešilo: u komerční akce její `event_id`,
  -- u měsíčního běhu období ve tvaru `2026-07`.
  klic        text NOT NULL,
  spusteno_at timestamptz NOT NULL DEFAULT now(),
  vytvoreno   integer NOT NULL DEFAULT 0,
  vystaveno   integer NOT NULL DEFAULT 0,
  preskoceno  integer NOT NULL DEFAULT 0,
  chyb        integer NOT NULL DEFAULT 0,
  poznamka    text
);

-- Jedna práce, jeden běh. Tohle je ta druhá pojistka proti dvojí fakturaci.
CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_runs_klic
  ON public.billing_runs (druh, klic);

CREATE INDEX IF NOT EXISTS idx_billing_runs_kdy ON public.billing_runs (spusteno_at DESC);

ALTER TABLE public.billing_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.billing_runs FROM anon, authenticated, public, service_role;
GRANT SELECT ON public.billing_runs TO authenticated;

DROP POLICY IF EXISTS billing_runs_select_admin ON public.billing_runs;
CREATE POLICY billing_runs_select_admin ON public.billing_runs
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'));

COMMENT ON TABLE public.billing_runs IS
  'Co automatika kdy udělala. Zároveň idempotenční klíč: unikátní (druh, klic) brání tomu, aby se tatáž práce spustila dvakrát.';

-- -----------------------------------------------------------------------------
-- 2) Fakturační RPC musí jít zavolat i z plánovače
--
-- Dnes se ptají na `has_role(auth.uid(), 'admin')`, jenže pod `pg_cron` žádný
-- token není a `auth.uid()` je NULL — automatika by tedy neprošla ani k prvnímu
-- konceptu. Přidává se TÁŽ výjimka, jakou už používá `billing_reconcile`:
-- běh bez tokenu POD DATABÁZOVOU ROLÍ. Z webu je nedosažitelná — PostgREST se
-- připojuje jako `authenticator`, takže `session_user` nikdy nebude `postgres`.
--
-- Těla se berou z `pg_get_functiondef` živého schématu (pravidlo 7); vkládá se
-- jen tahle jedna podmínka.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  _fn text;
  _def text;
  _puvodni text;
  _novy text;
  _funkce text[] := ARRAY[
    'public.create_invoice_draft_club(uuid,date,date)',
    'public.create_invoice_draft_commercial(uuid)',
    'public.issue_invoice(uuid)'
  ];
BEGIN
  FOREACH _fn IN ARRAY _funkce LOOP
    _def := pg_get_functiondef(_fn::regprocedure);
    CONTINUE WHEN position('session_user' in _def) > 0;   -- už upravené

    _puvodni := '  IF NOT has_role(_uid, ''admin'') THEN';
    _novy := '  -- Výjimka pro plánovač: běh BEZ tokenu a pod databázovou rolí.'
          || E'\n' || '  -- Z webu nedosažitelná (PostgREST se připojuje jako `authenticator`).'
          || E'\n' || '  IF NOT (_uid IS NULL AND session_user IN (''postgres'', ''supabase_admin''))'
          || E'\n' || '     AND NOT has_role(_uid, ''admin'') THEN';

    IF position(_puvodni in _def) = 0 THEN
      RAISE EXCEPTION 'V %(...) nenacházím očekávanou kontrolu admina — nechci hádat, kam zásah patří.', _fn;
    END IF;

    EXECUTE replace(_def, _puvodni, _novy);
  END LOOP;
END $$;

-- Kontrola, že zásah opravdu sedí. Bez ní by se tichá neúspěšná náhrada
-- projevila až tím, že automatika nikdy nic nevytvoří.
DO $$
DECLARE _fn text;
BEGIN
  FOREACH _fn IN ARRAY ARRAY['public.create_invoice_draft_club(uuid,date,date)',
                             'public.create_invoice_draft_commercial(uuid)',
                             'public.issue_invoice(uuid)'] LOOP
    IF position('session_user' in pg_get_functiondef(_fn::regprocedure)) = 0 THEN
      RAISE EXCEPTION '%(...) nemá větev pro plánovač — automatika by neudělala nic.', _fn;
    END IF;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 3) Tik automatiky
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.billing_automation_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _bs        record;
  _dnes      date := (now() AT TIME ZONE 'Europe/Prague')::date;
  _mesic_od  date;
  _mesic_do  date;
  _klic      text;
  _r         record;
  _fid       uuid;
  _vytvoreno int := 0;
  _vystaveno int := 0;
  _preskoceno int := 0;
  _chyb      int := 0;
  _poznamky  text[] := ARRAY[]::text[];
  _souhrn    jsonb := '[]'::jsonb;
BEGIN
  IF NOT (auth.uid() IS NULL AND session_user IN ('postgres', 'supabase_admin'))
     AND NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Automatiku spouští jen plánovač nebo správce haly.';
  END IF;

  SELECT * INTO _bs FROM public.billing_settings LIMIT 1;

  -- MRTVÝ MUŽ: tik proběhne, i když je automatika vypnutá, a je to vidět.
  -- Vypínač v datech (ne v migraci) umožňuje nechat plánovač týdny běžet
  -- naprázdno a teprve pak mu dovolit zakládat doklady.
  IF NOT COALESCE(_bs.automation_enabled, false) THEN
    RETURN jsonb_build_object('tik', now(), 'stav', 'vypnuto',
      'poznamka', 'automation_enabled = false — plánovač běží, ale nic nezakládá');
  END IF;

  -- ---------------------------------------------------------------------------
  -- A) DENNĚ: proběhlé komerční akce
  --
  -- „Proběhlá" = skončila PŘED dneškem (pražsky). Akci, která právě běží nebo
  -- skončila dnes, se schválně nefakturuje: doúčtování a opravy se dělají týž
  -- den a doklad by vznikl dřív, než se ustálí, co se vlastně stalo.
  -- ---------------------------------------------------------------------------
  FOR _r IN
    SELECT e.id AS event_id, e.title, max(r.start_at) AS konec
      FROM public.events e
      JOIN public.reservations r ON r.event_id = e.id
     WHERE e.event_type = 'commercial'
       AND r.status = 'confirmed'
       AND r.deleted_at IS NULL
       AND r.invoice_id IS NULL
       AND r.subject_id IS NOT NULL
       AND COALESCE(r.corrected_amount, r.amount) > 0
       AND (e.end_time AT TIME ZONE 'Europe/Prague')::date < _dnes
     GROUP BY e.id, e.title
     ORDER BY max(r.start_at)
  LOOP
    _klic := _r.event_id::text;
    -- Evidence PŘED prací: když se totéž spustí podruhé, unikátní index to
    -- zastaví tady a ne až u dokladu.
    BEGIN
      INSERT INTO public.billing_runs (druh, klic) VALUES ('komercni_denni', _klic);
    EXCEPTION WHEN unique_violation THEN
      _preskoceno := _preskoceno + 1;
      CONTINUE;
    END;

    BEGIN
      _fid := public.create_invoice_draft_commercial(_r.event_id);
      _vytvoreno := _vytvoreno + 1;

      IF COALESCE(_bs.auto_issue, false) THEN
        PERFORM public.issue_invoice(_fid);
        _vystaveno := _vystaveno + 1;
      END IF;

      UPDATE public.billing_runs
         SET vytvoreno = 1, vystaveno = CASE WHEN COALESCE(_bs.auto_issue, false) THEN 1 ELSE 0 END,
             poznamka = _r.title
       WHERE druh = 'komercni_denni' AND klic = _klic;
    EXCEPTION WHEN OTHERS THEN
      -- Jedna vadná akce NESMÍ zastavit zbytek běhu — přesně jako u série
      -- rezervací. Důvod se uloží k běhu, ať je co číst ráno.
      _chyb := _chyb + 1;
      _poznamky := array_append(_poznamky, format('%s: %s', _r.title, SQLERRM));
      UPDATE public.billing_runs SET chyb = 1, poznamka = left(SQLERRM, 400)
       WHERE druh = 'komercni_denni' AND klic = _klic;
    END;
  END LOOP;

  _souhrn := _souhrn || jsonb_build_object('druh', 'komercni_denni',
    'vytvoreno', _vytvoreno, 'vystaveno', _vystaveno,
    'preskoceno', _preskoceno, 'chyb', _chyb);

  -- ---------------------------------------------------------------------------
  -- B) MĚSÍČNĚ: souhrnné faktury klubům za PŘEDCHOZÍ měsíc
  -- ---------------------------------------------------------------------------
  IF EXTRACT(day FROM _dnes)::int = COALESCE(_bs.monthly_run_day, 1) THEN
    _mesic_od := date_trunc('month', _dnes - interval '1 month')::date;
    _mesic_do := (date_trunc('month', _dnes) - interval '1 day')::date;
    _klic := to_char(_mesic_od, 'YYYY-MM');

    _vytvoreno := 0; _vystaveno := 0; _preskoceno := 0; _chyb := 0;

    BEGIN
      INSERT INTO public.billing_runs (druh, klic) VALUES ('kluby_mesicni', _klic);

      FOR _r IN
        SELECT r.subject_id, s.name
          FROM public.reservations r
          JOIN public.subjects s ON s.id = r.subject_id
         WHERE r.status = 'confirmed'
           AND r.deleted_at IS NULL
           AND r.invoice_id IS NULL
           AND s.type = 'club'
           AND s.deleted_at IS NULL
           AND COALESCE(r.corrected_amount, r.amount) > 0
           AND r.start_at >= (_mesic_od::timestamp AT TIME ZONE 'Europe/Prague')
           AND r.start_at <  ((_mesic_do + 1)::timestamp AT TIME ZONE 'Europe/Prague')
           -- Neschválené rezervace se NEFAKTURUJÍ automaticky: dokud je
           -- zástupce klubu nepotvrdil, není jisté, že se mají účtovat.
           AND r.approved_at IS NOT NULL
         GROUP BY r.subject_id, s.name
         ORDER BY s.name
      LOOP
        BEGIN
          _fid := public.create_invoice_draft_club(_r.subject_id, _mesic_od, _mesic_do);
          _vytvoreno := _vytvoreno + 1;
          IF COALESCE(_bs.auto_issue, false) THEN
            PERFORM public.issue_invoice(_fid);
            _vystaveno := _vystaveno + 1;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          _chyb := _chyb + 1;
          _poznamky := array_append(_poznamky, format('%s: %s', _r.name, SQLERRM));
        END;
      END LOOP;

      UPDATE public.billing_runs
         SET vytvoreno = _vytvoreno, vystaveno = _vystaveno, chyb = _chyb,
             poznamka = nullif(array_to_string(_poznamky, ' | '), '')
       WHERE druh = 'kluby_mesicni' AND klic = _klic;

      _souhrn := _souhrn || jsonb_build_object('druh', 'kluby_mesicni', 'obdobi', _klic,
        'vytvoreno', _vytvoreno, 'vystaveno', _vystaveno, 'chyb', _chyb);
    EXCEPTION WHEN unique_violation THEN
      _souhrn := _souhrn || jsonb_build_object('druh', 'kluby_mesicni', 'obdobi', _klic,
        'preskoceno', true, 'poznamka', 'tenhle měsíc už proběhl');
    END;
  END IF;

  RETURN jsonb_build_object(
    'tik', now(),
    'stav', 'ok',
    'auto_issue', COALESCE(_bs.auto_issue, false),
    'behy', _souhrn,
    'chyby', to_jsonb(_poznamky));
END;
$$;

REVOKE ALL ON FUNCTION public.billing_automation_tick() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.billing_automation_tick() TO authenticated, service_role;

COMMENT ON FUNCTION public.billing_automation_tick() IS
  'Hodinový tik automatiky: denně proběhlé komerční akce, měsíčně souhrnné faktury klubům. Řídí se billing_settings.automation_enabled a auto_issue; při vypnuté automatice jen ohlásí, že běží.';

-- -----------------------------------------------------------------------------
-- 4) Plánovač — KROK NASAZENÍ, ne součást migrace (pokyn PM 18. 8. 2026)
--
-- Rozšíření `pg_cron` se zapíná na projektu (Dashboard → Database → Extensions)
-- a plán se zakládá zvlášť. Migrace ho schválně NEZAKLÁDÁ: zapnout plánovač je
-- provozní rozhodnutí, ne změna schématu, a na lokálním Dockeru by stejně jen
-- tiše nic nedělal.
--
-- Až se bude nasazovat, pustit na projektu tohle:
--
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   SELECT cron.schedule(
--     'fakturace-tik', '7 * * * *',
--     $cron$ SELECT public.billing_automation_tick(); $cron$);
--
-- Kontrola, že tiká:  SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
-- Vypnutí:            SELECT cron.unschedule('fakturace-tik');
--
-- POŘADÍ ZAPÍNÁNÍ (a nepřeskakovat):
--   1. založit plán a nechat ho TÝDNY běžet s `automation_enabled = false`
--      — ověří se, že tiká, a přitom nemůže nic založit
--   2. `automation_enabled = true`, pořád `auto_issue = false` → měsíc jen
--      koncepty, které si člověk prohlédne
--   3. teprve pak zvážit `auto_issue = true`
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron je nainstalovaný — plán založ ručně (viz komentář v migraci).';
  ELSE
    RAISE NOTICE 'pg_cron zatím není. Automatika je připravená, ale nikdo ji nespouští — to je při nasazení další krok.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 5) Dohledatelnost a cesta zpět
--
-- Evidence běhů je TRVALÁ: co automatika jednou zpracovala, znovu nezkusí.
-- Je to schválně — u peněz je „radši nic než dvakrát" správná strana. Má to ale
-- důsledek, který se snadno přehlédne: když admin koncept ZAHODÍ, rezervace se
-- uvolní, ale automatika je už podruhé nenabídne. Tick to hlásí jako
-- `preskoceno`, jenže souhrn tiku nikdo denně nečte.
--
-- Proto dvě věci: u běhu se drží `invoice_id`, aby šlo dohledat, co z něj
-- vzniklo, a admin má tlačítko, kterým běh „zapomene" a nechá automatiku
-- zkusit to znovu.
-- -----------------------------------------------------------------------------
ALTER TABLE public.billing_runs
  ADD COLUMN IF NOT EXISTS invoice_id uuid REFERENCES public.invoices(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.billing_runs.invoice_id IS
  'Doklad, který z běhu vznikl. `ON DELETE SET NULL`: zahozený koncept se smaže, ale záznam o běhu zůstává — a prázdné `invoice_id` je právě ten signál, že automatika něco udělala a výsledek už neexistuje.';

CREATE OR REPLACE FUNCTION public.forget_billing_run(_druh text, _klic text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _fid uuid;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Běhy automatiky spravuje jen správce haly.';
  END IF;

  SELECT invoice_id INTO _fid FROM public.billing_runs WHERE druh = _druh AND klic = _klic;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Takový běh automatiky neexistuje.';
  END IF;

  -- Když doklad z běhu POŘÁD EXISTUJE, zapomenutí by vedlo k druhému dokladu
  -- na tutéž věc. Nejdřív ho zahoď (nebo stornuj), teprve pak tohle.
  IF _fid IS NOT NULL AND EXISTS (SELECT 1 FROM public.invoices WHERE id = _fid) THEN
    RAISE EXCEPTION 'Doklad z tohohle běhu pořád existuje — zahoď ho nebo stornuj dřív, než pustíš automatiku znovu.'
      USING HINT = 'Jinak by vznikl druhý doklad na tutéž akci.';
  END IF;

  DELETE FROM public.billing_runs WHERE druh = _druh AND klic = _klic;
END;
$$;

REVOKE ALL ON FUNCTION public.forget_billing_run(text, text) FROM public, anon, service_role;
GRANT EXECUTE ON FUNCTION public.forget_billing_run(text, text) TO authenticated;

COMMENT ON FUNCTION public.forget_billing_run(text, text) IS
  'Zapomene běh automatiky, aby ho šlo spustit znovu (typicky po zahození konceptu). Odmítne to, dokud doklad z původního běhu existuje — jinak by vznikl druhý doklad na tutéž věc.';

-- Zapisovat `invoice_id` do evidence.
DO $$
DECLARE _def text;
BEGIN
  _def := pg_get_functiondef('public.billing_automation_tick()'::regprocedure);
  IF position('invoice_id = _fid' in _def) = 0 THEN
    _def := replace(_def,
      $stare$         SET vytvoreno = 1, vystaveno = CASE WHEN COALESCE(_bs.auto_issue, false) THEN 1 ELSE 0 END,
             poznamka = _r.title$stare$,
      $nove$         SET vytvoreno = 1, vystaveno = CASE WHEN COALESCE(_bs.auto_issue, false) THEN 1 ELSE 0 END,
             invoice_id = _fid,
             poznamka = _r.title$nove$);
    EXECUTE _def;
  END IF;
  IF position('invoice_id = _fid' in pg_get_functiondef('public.billing_automation_tick()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Doplnění invoice_id do evidence běhů se nepovedlo.';
  END IF;
END $$;
