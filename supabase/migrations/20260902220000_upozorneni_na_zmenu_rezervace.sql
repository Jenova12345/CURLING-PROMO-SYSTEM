-- =============================================================================
-- Upozornění majiteli, když mu někdo jiný rezervaci upraví nebo zruší
-- =============================================================================
-- KROK 0 (2. 9. 2026) zjistil, že se to dosud nedělo vůbec:
--
--   * `trg_reservations_notify_approval` pokrývá jen dvě situace — člen podal
--     rezervaci (zástupci) a zástupce ji potvrdil (autorovi).
--   * `reservation_overridden` vzniká jen tehdy, když NOVÁ rezervace přebije
--     starou (v `create_booking`).
--   * `reservation_cancelled` je vypsané v komentáři u `notifications.type`
--     JAKO BY existovalo, ale nezakládá ho nic. Na produkci jsou dnes jen typy
--     `reservation_needs_approval`, `reservation_approved`
--     a `subject_request_approved`.
--
-- Prakticky: správce mohl klubu posunout trénink na jiný den nebo ho zrušit
-- a klub se to dozvěděl, jen když si sám všiml změny v kalendáři.
--
-- Systém e-maily ani SMS neposílá (`email_notifications_enabled` je vypnuté),
-- takže tohle je upozornění V APLIKACI. `notify_user` frontu e-mailů plní jen
-- při zapnutém odesílání, což se tímhle nemění.
--
-- KOMU: autorovi rezervace (`created_by`), tedy tomu, kdo ji zadal.
-- KDY NE: když si ji upravuje sám — vlastní akci si člověk oznamovat nemusí.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.notify_reservation_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  _subject text;
  _sheet   text;
  _kdo     text;
  _kdy     text;
  _kdy_pred text;
  _typ     text;
  _titulek text;
  _text    text;
  _klic    text;
BEGIN
  -- Bez autora není komu psát.
  IF NEW.created_by IS NULL THEN RETURN NULL; END IF;

  -- Vlastní úprava se neoznamuje.
  IF auth.uid() IS NOT DISTINCT FROM NEW.created_by THEN RETURN NULL; END IF;

  -- Zásah bez přihlášeného člověka = migrace, seed nebo servisní skript.
  -- Ty by jinak při každém hromadném přepočtu vyrobily klubům desítky
  -- upozornění na změnu, kterou nikdo neudělal.
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;

  -- ---- O co jde: storno, nebo přesun? --------------------------------------
  IF OLD.status <> 'cancelled' AND NEW.status = 'cancelled' THEN
    _typ := 'reservation_cancelled';
  ELSIF NEW.status <> 'cancelled'
        AND (NEW.sheet_id  IS DISTINCT FROM OLD.sheet_id
          OR NEW.start_at  IS DISTINCT FROM OLD.start_at
          OR NEW.end_at    IS DISTINCT FROM OLD.end_at) THEN
    _typ := 'reservation_changed';
  ELSE
    RETURN NULL;                      -- jiná změna (poznámka, razítka) neupozorňuje
  END IF;

  -- ---- Jedna zpráva na akci, ne na každou dráhu ----------------------------
  -- Akce přes obě dráhy jsou dva řádky a `move_booking` je posouvá SPOLU,
  -- v jedné transakci — trigger tedy proběhne dvakrát a klub by dostal dvě
  -- hlášky o jedné změně.
  --
  -- Značka je transakčně lokální (`set_config(..., true)`), takže platí přesně
  -- pro tenhle jeden zásah a další úprava téže akce (jiná transakce) upozorní
  -- znovu. Dřív tu stálo `created_at >= now()`; vycházelo to jen proto, že
  -- `now()` je čas ZAČÁTKU transakce, a v testu (jedna dlouhá transakce) to
  -- umlčelo i změny, které spolu vůbec nesouvisely. Značka říká totéž nahlas.
  _klic := 'app.zmena_' || replace(COALESCE(NEW.event_id, NEW.series_id, NEW.id)::text, '-', '')
           || '_' || _typ;
  IF current_setting(_klic, true) = 'on' THEN
    RETURN NULL;
  END IF;
  PERFORM set_config(_klic, 'on', true);

  SELECT s.name INTO _subject FROM public.subjects s  WHERE s.id = NEW.subject_id;
  SELECT sh.name INTO _sheet  FROM public.sheets sh   WHERE sh.id = NEW.sheet_id;
  SELECT p.full_name INTO _kdo FROM public.profiles p WHERE p.user_id = auth.uid();

  _kdy := to_char(NEW.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
          || '–' || to_char(NEW.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI');

  IF _typ = 'reservation_cancelled' THEN
    _titulek := 'Rezervace byla zrušena';
    _text := 'Vaši rezervaci za ' || COALESCE(_subject, 'klub') || ' ('
             || COALESCE(_sheet, 'dráha') || ', ' || _kdy || ') zrušil(a) '
             || COALESCE(_kdo, 'správce haly') || '.'
             -- Důvod storna je pro klub ta nejdůležitější informace; bez něj
             -- vypadá zrušení jako svévole.
             || COALESCE(' Důvod: ' || NULLIF(NEW.cancel_reason, '') || '.', '');
  ELSE
    _kdy_pred := to_char(OLD.start_at AT TIME ZONE 'Europe/Prague', 'DD.MM.YYYY HH24:MI')
                 || '–' || to_char(OLD.end_at AT TIME ZONE 'Europe/Prague', 'HH24:MI');
    _titulek := 'Rezervace byla upravena';
    _text := COALESCE(_kdo, 'Správce haly') || ' upravil(a) vaši rezervaci za '
             || COALESCE(_subject, 'klub') || '. Původně: ' || _kdy_pred
             || '. Nově: ' || COALESCE(_sheet, 'dráha') || ', ' || _kdy || '.';
  END IF;

  PERFORM public.notify_user(
    NEW.created_by, _typ, _titulek, _text, '/calendar', NEW.id, NEW.subject_id);

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.notify_reservation_changed() IS
  'Upozorní autora rezervace, když ji upraví nebo zruší někdo jiný. Vlastní zásah a servisní zápisy (auth.uid() IS NULL) neupozorňují.';

DROP TRIGGER IF EXISTS trg_reservations_notify_change ON public.reservations;
CREATE TRIGGER trg_reservations_notify_change
  AFTER UPDATE OF sheet_id, start_at, end_at, status ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.notify_reservation_changed();

-- Komentář u sloupce lhal: `reservation_cancelled` v něm bylo vypsané od
-- začátku, ale nic ho nezakládalo. Teď už sedí, a přibyl `reservation_changed`.
COMMENT ON COLUMN public.notifications.type IS
  'reservation_overridden | reservation_needs_approval | reservation_approved | reservation_cancelled | reservation_changed | subject_request_approved';

-- ---- Sebekontrola ----------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.reservations'::regclass
                    AND tgname = 'trg_reservations_notify_change') THEN
    RAISE EXCEPTION 'Trigger upozornění na změnu rezervace nevznikl.';
  END IF;
  RAISE NOTICE 'Úprava i zrušení rezervace teď dají majiteli vědět.';
END $$;
