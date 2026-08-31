-- =============================================================================
-- Komerční akce se oceňuje jako CELEK, ne po drahách
-- BUG 1 z 31. 8. 2026 · navazuje na pásmový ceník
-- =============================================================================
-- CO JE ŠPATNĚ DNES:
--
-- Komerční akce na dvou drahách je v databázi DVĚ rezervace pod jedním
-- `event_id`. `update_booking` ale přepisuje sazbu takhle:
--
--   UPDATE public.reservations SET ... rate_per_hour = ...
--    WHERE id = p_reservation_id;      ← JEDNA rezervace
--
-- Název akce se propaguje na celý `event`, sazba ne. Admin tedy změní cenu na
-- Dráze 1, Dráha 2 zůstane na staré — a akce má dvě různé sazby, aniž by to
-- kdokoli chtěl. Na dokladu se to projeví jako dva řádky s jinou cenou za touž
-- hodinu ledu.
--
-- -----------------------------------------------------------------------------
-- PROČ RPC A NE SMYČKA V UI
-- -----------------------------------------------------------------------------
-- Frontend by mohl zavolat `update_booking` pro každou rezervaci akce zvlášť.
-- Jenže to NENÍ ATOMICKÉ: když druhé volání selže (výpadek sítě, kolize práv),
-- zůstane akce půl přeceněná a „Kdo kolik dluží" se rozejde s tím, na čem se
-- admin s firmou domluvil. U peněz je to nepřijatelné, takže se celá akce
-- přeceňuje jedním příkazem v jedné transakci.
--
-- -----------------------------------------------------------------------------
-- CO SE NEMĚNÍ
-- -----------------------------------------------------------------------------
-- Sazba zůstává v CELÝCH KORUNÁCH a `amount` se dál počítá jako
-- `hodiny × sazba`. Tahle migrace tedy NEROZBÍJÍ žádný invariant a nedotýká se
-- fakturační vrstvy — doklad se skládá stejně jako dosud.
--
-- Celková cena za akci je pak `dráhy × hodiny × sazba`, protože každá dráha je
-- vlastní rezervace se stejnou sazbou. Pro 2 dráhy × 4 h × 5 000 to dá 40 000.
--
-- ⚠️ Ručně zadaná CELKOVÁ částka, která nevyjde na celé koruny za hodinu
-- (např. 10 000 Kč za 3 h = 3 333,33 Kč/h), tímhle možná NENÍ. Je to vědomé —
-- vyžadovalo by to rozbít `amount = hodiny × sazba` a přepsat i skládání
-- dokladu. Řeší se samostatně; UI zatím takovou částku nepustí a nabídne
-- nejbližší dosažitelnou.
--
-- -----------------------------------------------------------------------------
-- VRATNOST:
--   DROP FUNCTION IF EXISTS public.uprav_sazbu_akce(uuid, numeric);
-- Sazby, které se mezitím přepsaly, revert nevrací — jsou to snapshoty.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.uprav_sazbu_akce(
  _event_id uuid,
  _sazba    numeric
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
$$;

COMMENT ON FUNCTION public.uprav_sazbu_akce(uuid, numeric) IS
  'Přecení CELOU akci jednou sazbou — všechny dráhy naráz a atomicky. Řeší BUG 1: update_booking měnil sazbu jen na jedné rezervaci, takže akce na dvou drahách mohla mít dvě různé ceny. Částku dopočítá trigger z nové sazby; celková cena akce je dráhy × hodiny × sazba.';

REVOKE ALL ON FUNCTION public.uprav_sazbu_akce(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.uprav_sazbu_akce(uuid, numeric) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Kontrola
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM 1 FROM pg_proc WHERE oid = 'public.uprav_sazbu_akce(uuid, numeric)'::regprocedure;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'uprav_sazbu_akce se nevytvořila.';
  END IF;
  RAISE NOTICE 'Přecenění celé akce je na místě (uprav_sazbu_akce).';
END $$;
