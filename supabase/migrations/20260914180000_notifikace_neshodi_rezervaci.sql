-- =============================================================================
-- Chyba notifikace nesmí shodit rezervaci
-- =============================================================================
-- CO SE MĚNÍ:
--   1) nová tabulka `notifikace_chyby` — kam se spolknutá chyba zapíše
--   2) nová funkce `zaloguj_chybu_notifikace()` — zápis, který sám nikdy nespadne
--   3) `notify_user()` dostává DVA vnořené EXCEPTION bloky
-- Žádná tabulka se neruší, žádná data se nemažou. Chování notifikací na
-- šťastné cestě se nemění ani o písmeno.
--
-- -----------------------------------------------------------------------------
-- PROČ: DOLOŽENÁ HAVÁRIE, NE OPATRNOST DO ZÁSOBY
-- -----------------------------------------------------------------------------
-- `notify_user` je SECURITY DEFINER funkce v ŽIVÉ CESTĚ zakládání rezervace:
--     create_booking → INSERT reservations → trg_reservations_notify_approval
--                    → notify_reservation_approval → notify_user
-- a nemá jediný EXCEPTION handler. Cokoli v ní selže, letí až nahoru.
--
-- ZMĚŘENO na replice produkce 14. 9. 2026 (chyba notifikace vyrobena přidáním
-- `CHECK (false) NOT VALID` na `notifications`, tedy bez sahání na kód):
--     člen klubu zakládá rezervaci → create_booking SPADLA
--     SQLSTATE P0001: „Rezervaci se nepodařilo uložit — zadané údaje neprošly
--                      kontrolou databáze."
-- Ta hláška je navíc NEPRAVDIVÁ a to je na tom nejhorší: uživatel nezadal nic
-- špatného, rozbila se notifikace. Člověk by opravoval formulář, ve kterém
-- žádná chyba není, a rezervace by nevznikla.
--
-- Riziko není hypotetické. `email_notifications_enabled = true` na produkci
-- (ověřeno), takže e-mailová větev se opravdu prochází, a vede přes
-- `email_sablona` → `settings.web_base_url` → `auth.users` → `email_outbox`.
-- Každý z těch kroků je jiný objekt, který může kdykoli chybět nebo změknout —
-- třeba špatně provedený revert migrace 20260914160000 udělá přesně tohle
-- (viz její sekce VRATNOST).
--
-- -----------------------------------------------------------------------------
-- PROČ DVA VNOŘENÉ BLOKY A NE JEDEN
-- -----------------------------------------------------------------------------
-- EXCEPTION blok v plpgsql je subtransakce: když se chytí výjimka, VRÁTÍ SE
-- všechno, co blok stihl udělat. Jeden blok kolem celé funkce by tedy při
-- selhání e-mailu zahodil i NOTIFIKACI V APLIKACI, která se povedla — a uživatel
-- by přišel o zprávu jen proto, že se nepodařilo odeslat e-mail.
--
--   vnější blok   kolem zápisu do `notifications`  → chrání rezervaci
--   vnitřní blok  jen kolem e-mailové části        → chrání notifikaci v appce
--
-- Takže: selže e-mail → notifikace v aplikaci zůstane, rezervace vznikne.
-- Selže i notifikace → rezervace pořád vznikne. Nic nespadne nahoru.
--
-- -----------------------------------------------------------------------------
-- SPOLKNUTÁ CHYBA, KTEROU NIKDO NEVIDÍ, JE HORŠÍ NEŽ PÁD
-- -----------------------------------------------------------------------------
-- Proto se každá spolknutá chyba zapisuje do `notifikace_chyby` (trvale,
-- čitelné adminovi) A ZÁROVEŇ jde jako `RAISE WARNING` do logu Postgresu.
-- Dvě cesty schválně: tabulka se dá číst z aplikace a přežije, log je vidět
-- hned v Supabase i kdyby zápis do tabulky sám selhal.
--
-- Zapisovací funkce má vlastní EXCEPTION blok, který spolkne úplně všechno.
-- Logování nesmí nikdy shodit to, co loguje — jinak by se z pojistky stala
-- nová příčina pádu.
--
-- -----------------------------------------------------------------------------
-- ⚠️ GRANTY: `REVOKE` MUSÍ JMENOVAT `authenticated`, NE JEN `PUBLIC` A `anon`
-- -----------------------------------------------------------------------------
-- Schéma `public` má DEFAULT PRIVILEGES, které roli `authenticated` (a `anon`)
-- dávají na KAŽDOU nově vzniklou tabulku `arwdxtm` a na každou funkci EXECUTE:
--     pg_default_acl: postgres/r → authenticated=arwdxtm, anon=arwdxtm
--                     postgres/f → authenticated=X,       anon=X
-- Samotný `GRANT SELECT` tedy práva NEZUŽUJE, jen přidává k tomu, co tam už je.
-- Přesně tahle past dneska otevřela zápis do ceníku komukoli přihlášenému
-- (viz hotfix 20260914150000) — proto se tu odvolává jmenovitě.
--
-- VRATNOST (v tomhle pořadí):
--   1) `notify_user` zpět ze ŽIVÉHO schématu přes `pg_get_functiondef`,
--      NE z téhle migrace; v původní podobě nemá žádný EXCEPTION blok
--   2) DROP FUNCTION public.zaloguj_chybu_notifikace(uuid,text,text,text,text,text,uuid,uuid);
--   3) DROP TABLE public.notifikace_chyby;
--
--   ⚠️ TOHLE POŘADÍ SI DATABÁZE NEVYNUTÍ. NIC Z NĚJ. Drží ho jedině kázeň toho,
--   kdo revert dělá. Dřívější znění tvrdilo, že kroky 2–3 jsou vynucené přes
--   `pg_depend` — NENÍ to pravda a bylo to změřeno (brána migrací, 14. 9. 2026):
--       počet vazeb `zaloguj_chybu_notifikace` → `notifikace_chyby` v pg_depend: 0
--       DROP TABLE prošel i s existující funkcí, která do tabulky zapisuje
--   Tělo plpgsql se nesleduje ANI JEDNÍM SMĚREM: jméno tabulky je v něm jen
--   řetězec, který se rozhodne až za běhu. Každý z těch tří kroků tedy projde
--   v libovolném pořadí a rozbije se až při prvním volání — tedy u kroku 1
--   a 2 zase pádem zakládání rezervací, přesně toho, co tahle migrace opravuje.
--   Kdo revertuje, ať po každém kroku založí zkušební rezervaci.
-- =============================================================================

-- `SET`, ne `SET LOCAL`: `supabase db push` migrace do transakce NEBALÍ, takže
-- `SET LOCAL` by tu neudělal nic a Postgres by na to jen zahlásil
-- `WARNING 25P01` (změřeno při ostrém nasazení 20260914160000). Cena za to je,
-- že nastavení přežije tenhle soubor, pokud CLI session recykluje — proto se
-- na konci souboru uklízí `RESET lock_timeout`. (Nález code-review brány.)
SET lock_timeout = '5s';

-- ⚠️ POŘADÍ KROKŮ 1 → 2 → 3 JE ZÁVAZNÉ, a tentokrát to není jen konvence.
-- `supabase db push` migrace do transakce NEBALÍ (změřeno 14. 9. 2026 varováním
-- 25P01 při ostrém nasazení migrace 20260914160000), takže když tenhle soubor
-- selže uprostřed, zůstane půlka aplikovaná. V pořadí tabulka → zapisovací
-- funkce → `notify_user` je každý mezistav BEZPEČNÝ: dokud nedojde na krok 3,
-- běží pořád stará `notify_user` a notifikace fungují jako dosud.
--
-- Obráceně by to bezpečné nebylo. Kdyby se `notify_user` nahradila dřív, než
-- existuje `zaloguj_chybu_notifikace`, prošlo by to TIŠE (těla plpgsql se při
-- vytvoření nekontrolují) a rozbilo by se až za běhu — v handleru, tedy přesně
-- v okamžiku, kdy má pojistka zabrat. Chyba notifikace by pak shodila rezervaci
-- úplně stejně jako před migrací, jen by se to hůř hledalo.
--
-- OPAKOVÁNÍ SOUBORU JE TU ZAMÝŠLENÁ CESTA VEN, NE NOUZOVÝ HACK. Všechny tři
-- kroky jsou idempotentní (`CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE`,
-- `DROP POLICY IF EXISTS` + `CREATE POLICY`, a `REVOKE`/`GRANT` z podstaty),
-- takže po pádu uprostřed stačí soubor pustit znovu. Ověřeno code-review bránou
-- 14. 9. 2026: dvojí běh za sebou, oba čisté — bez erroru i bez warningu —
-- a sada testů po nich 17/17.

-- -----------------------------------------------------------------------------
-- 1) Kam se spolknutá chyba zapíše
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notifikace_chyby (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at     timestamptz NOT NULL DEFAULT now(),
  user_id        uuid,          -- komu se zpráva nedoručila (bez FK: účet může zmizet)
  typ            text,          -- `_type` notifikace, např. 'reservation_pending'
  faze           text NOT NULL, -- 'notifikace' = zápis do appky, 'email' = fronta
  sqlstate       text,
  chyba          text,          -- MESSAGE_TEXT: hláška Postgresu, bez hodnot sloupců
  kontext        text,          -- PG_EXCEPTION_CONTEXT: kde přesně to spadlo
  reservation_id uuid,
  subject_id     uuid,
  -- Vědomý důsledek: kdyby sem někdo příště poslal překlepnutou `faze`, INSERT
  -- selže, spolkne ho vlastní handler v `zaloguj_chybu_notifikace` a zbude jen
  -- `RAISE WARNING` v logu Supabase. Tenhle CHECK proto rozšiřuj VŽDY zároveň
  -- s voláním, které novou fázi posílá — jinak se chyba ztratí právě ve chvíli,
  -- kdy ji potřebuješ vidět. (Nález code-review brány.)
  CONSTRAINT notifikace_chyby_faze_chk CHECK (faze IN ('notifikace', 'email'))
);

COMMENT ON TABLE public.notifikace_chyby IS
  'Chyby notifikací, které byly SPOLKNUTY, aby neshodily rezervaci. '
  'Prázdná tabulka = notifikace jedou. Řádek znamená, že se někomu nedoručila '
  'ASPOŇ JEDNA zpráva, i když jeho rezervace vznikla — NENÍ to počítadlo '
  'nedoručených zpráv, viz komentář u notify_user. Čti je, nenech je ležet. '
  'Sloupec deleted_at tu SCHVÁLNĚ NENÍ a nedoplňuj ho: zásada „nic nemazat '
  'natvrdo" chrání data klienta, kdežto tohle je diagnostický záznam. '
  'Soft delete by u něj znamenal jen tiše schovaný důkaz o poruše.';

-- ⚠️ `PG_EXCEPTION_DETAIL` SE ZÁMĚRNĚ NEZACHYTÁVÁ, NEDOPLŇUJ HO.
-- `MESSAGE_TEXT` nese jen hlášku Postgresu („new row for relation … violates
-- check constraint …"), kdežto `DETAIL` nese HODNOTY SLOUPCŮ toho řádku —
-- tedy u notifikace její tělo, u e-mailu adresu příjemce. Tahle tabulka je
-- sice jen pro admina, ale jde o data, která do diagnostického logu nepatří
-- a k odhalení příčiny nejsou potřeba. (Ověřeno bezpečnostní bránou na
-- skutečných řádcích, ne odhadem.)
--
-- Bez FK schválně: tahle tabulka je poslední záchranná síť, takže nesmí mít
-- důvod odmítnout zápis. Cizí klíč na `auth.users` nebo `reservations` by při
-- závodu s mazáním z pojistky udělal další zdroj chyb.
CREATE INDEX IF NOT EXISTS idx_notifikace_chyby_created_at
  ON public.notifikace_chyby (created_at DESC);

ALTER TABLE public.notifikace_chyby ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifikace_chyby_select_admin ON public.notifikace_chyby;
CREATE POLICY notifikace_chyby_select_admin ON public.notifikace_chyby
  FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin'::public.app_role));

-- Viz varování v hlavičce: `authenticated` a `anon` je nutné jmenovat.
REVOKE ALL ON public.notifikace_chyby FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.notifikace_chyby TO authenticated;
GRANT ALL ON public.notifikace_chyby TO service_role;

-- -----------------------------------------------------------------------------
-- 2) Zápis chyby, který sám nikdy nespadne
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.zaloguj_chybu_notifikace(
  _user           uuid,
  _typ            text,
  _faze           text,
  _sqlstate       text,
  _chyba          text,
  _kontext        text,
  _reservation_id uuid DEFAULT NULL,
  _subject_id     uuid DEFAULT NULL
) RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Vlastní EXCEPTION blok je tu to podstatné. Tahle funkce se volá Z HANDLERU
  -- jiné chyby; kdyby spadla, propadla by výjimka dál a shodila by rezervaci —
  -- tedy přesně to, čemu má celá migrace zabránit.
  BEGIN
    INSERT INTO public.notifikace_chyby
      (user_id, typ, faze, sqlstate, chyba, kontext, reservation_id, subject_id)
    VALUES
      (_user, _typ, _faze, _sqlstate,
       left(_chyba, 4000), left(_kontext, 4000), _reservation_id, _subject_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- ani tohle nesmí nikoho shodit
  END;

  -- Druhá, nezávislá cesta ven. Kdyby zápis výš selhal, tohle je jediná stopa —
  -- a v Supabase je vidět hned, bez dotazu do databáze.
  RAISE WARNING 'notify_user: fáze % selhala (%): %', _faze, _sqlstate, _chyba;
END;
$function$;

REVOKE ALL ON FUNCTION public.zaloguj_chybu_notifikace(uuid,text,text,text,text,text,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.zaloguj_chybu_notifikace(uuid,text,text,text,text,text,uuid,uuid)
  TO service_role;

-- -----------------------------------------------------------------------------
-- 3) notify_user: dva vnořené EXCEPTION bloky
-- -----------------------------------------------------------------------------
-- Tělo níž je vygenerované z `pg_get_functiondef` živého schématu a vložen do
-- něj JEN tenhle zásah (pravidlo 7 v CLAUDE.md). Logika notifikací se nemění:
-- na šťastné cestě dělá funkce přesně to co dřív, ve stejném pořadí.
--
-- ⚠️ POZNÁMKA K SUBTRANSAKCÍM — ZMĚŘENO, A VYCHÁZÍ TO HŮŘ, NEŽ BY SE CHTĚLO.
--
-- Každý EXCEPTION blok zakládá subtransakci a každá, která něco zapíše, dostane
-- vlastní XID. Postgres si jich v backendu cachuje 64 (`PGPROC_MAX_CACHED_SUBXIDS`);
-- nad tím se cache „přelije" a cizí backendy musí viditelnost řádků té transakce
-- dohledávat v `pg_subtrans`. Není to chyba ani ztráta dat — je to zpomalení,
-- které nesnáší jen ta transakce, ale celý cluster po dobu, co drží snapshot.
--
-- SPOTŘEBA NA JEDNO VOLÁNÍ — 2,00 subxid (změřeno dvakrát nezávisle:
-- bezpečnostní bránou a znovu 14. 9. 2026 nad nečinnou replikou, delta
-- `pg_snapshot_xmax` z odděleného sezení; N=1 → 3, N=5 → 11, N=20 → 41, tedy
-- směrnice přesně 2 a intercept 1 = samotný top-level XID):
--     vnější blok za INSERT do `notifications`, vnitřní za INSERT do
--     `email_outbox`. PŘED touhle migrací to bylo 0 — spotřebu zavádí ona.
-- PRÁH JE TEDY 32 VOLÁNÍ `notify_user` v jedné transakci.
--
-- KOLIK JICH PRODUKCE UDĚLÁ: nejdelší cesta je smyčka `reservation_overridden`
-- v `create_booking`. Jede přes `subject_reps` zasažených klubů `GROUP BY
-- user_id, subject_id` a NEFILTRUJE PODLE ÚROVNĚ — jsou v ní tedy i `member`,
-- nejen `rep`. Změřeno na produkci 14. 9. 2026:
--     Curling Ostrava 18 řádků (3 rep + 15 member)
--     Mladé Kameny    16 řádků (4 rep + 12 member)
--     Český svaz 1, Curling Brno 1                      celkem 36
--
-- ⚠️ ZÁVĚR: jedna komerční akce, která přebije led OBĚMA velkým klubům, udělá
-- 34 volání = 68 subxid, a to je UŽ DNES NAD CACHE (64). Není tu tedy žádná
-- rezerva — hranice je překročená, ne blízko. Dřívější znění tohohle komentáře
-- tvrdilo „~84 % cache" (počítal jsem z členů jednoho klubu) a brána migrací
-- zase „4 repy" (filtrovala `level='rep'`, který v dotazu není); OBOJÍ BYLO
-- ŠPATNĚ, obojí jinam.
--
-- PROČ SE PŘESTO NASAZUJE: alternativa není „žádné subxid", ale „rezervace
-- padá", a to se děje doopravdy (viz hlavička). Přelitá cache je zpomalení
-- krátké transakce — 500 volání, ze kterých všechna selhala, proběhlo za 17 ms.
-- Pád zakládání rezervace je výpadek funkce s nepravdivou hláškou.
--
-- CO S TÍM, AŽ SE NA TO PŘIJDE: kdyby se hlásilo, že přebíjení ledu trvá dlouho
-- nebo že v tu chvíli zlobí celý systém, tohle je první podezřelý. Řešení není
-- odebrat handlery, ale nevolat `notify_user` 34× v jedné transakci — zprávy
-- zakládat dávkově (jeden INSERT ... SELECT), nebo smyčku vytáhnout z transakce.
CREATE OR REPLACE FUNCTION public.notify_user(_user uuid, _type text, _title text, _body text, _link text DEFAULT '/calendar'::text, _reservation_id uuid DEFAULT NULL::uuid, _subject_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _id      uuid;
  _email   text;
  _enabled boolean;
  _predmet text;
  _telo    text;
  -- Pro GET STACKED DIAGNOSTICS v obou handlerech níž.
  _stav    text;
  _chyba   text;
  _kontext text;
BEGIN
  IF _user IS NULL THEN RETURN NULL; END IF;

  -- VNĚJŠÍ BLOK: chrání REZERVACI. `notify_user` visí na triggeru v živé cestě
  -- `create_booking`, takže cokoli odsud vyletí, shodí zakládání rezervace —
  -- a uživateli se navíc ukáže „zadané údaje neprošly kontrolou databáze",
  -- což je nepravda. Změřeno 14. 9. 2026, viz hlavička migrace.
  BEGIN
    INSERT INTO public.notifications (user_id, type, title, body, link, reservation_id, subject_id, created_by)
    VALUES (_user, _type, _title, _body, _link, _reservation_id, _subject_id, auth.uid())
    RETURNING id INTO _id;

    -- VNITŘNÍ BLOK: chrání NOTIFIKACI V APLIKACI. EXCEPTION blok je subtransakce,
    -- takže jeden společný blok by při selhání e-mailu vrátil i zápis do
    -- `notifications` výš — uživatel by přišel o zprávu jen proto, že se
    -- nepodařilo poslat e-mail. Proto má e-mailová část blok sama pro sebe.
    BEGIN
      SELECT email_notifications_enabled INTO _enabled FROM public.settings LIMIT 1;
      IF COALESCE(_enabled, false) THEN
        -- Allowlist: typ bez šablony jde jen do aplikace, do pošty ne.
        SELECT s.subject, s.body INTO _predmet, _telo
          FROM public.email_sablona(_type, _title, _body, _link) s;

        IF _predmet IS NOT NULL THEN
          SELECT u.email INTO _email FROM auth.users u WHERE u.id = _user;

          -- Prázdná ani nesmyslná adresa není chyba, jen se nepošle.
          IF public.email_je_platny(_email) THEN
            INSERT INTO public.email_outbox (notification_id, user_id, email, subject, body)
            VALUES (_id, _user, _email, _predmet, _telo)
            ON CONFLICT (notification_id) WHERE notification_id IS NOT NULL DO NOTHING;
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS
        _stav = RETURNED_SQLSTATE, _chyba = MESSAGE_TEXT, _kontext = PG_EXCEPTION_CONTEXT;
      PERFORM public.zaloguj_chybu_notifikace(
        _user, _type, 'email', _stav, _chyba, _kontext, _reservation_id, _subject_id);
    END;

  EXCEPTION WHEN OTHERS THEN
    -- Sem se dojde, jen když selhal i zápis do `notifications`. Ten je tím
    -- pádem vrácený, takže `_id` musí jít na NULL — jinak by funkce vrátila
    -- ID řádku, který v databázi není.
    --
    -- ⚠️ TENHLE ŘÁDEK NEHLÍDÁ ŽÁDNÝ TEST. Brána migrací ho zkusila smazat
    -- a celá sada zůstala zelená (15/15). Není to opomenutí, kterým by se dalo
    -- něco rozbít potichu: všech 6 reálných volání na produkci je
    -- `PERFORM public.notify_user(...)`, takže návratovou hodnotu dnes nikdo
    -- nečte (ověřeno bránou). Kdo `notify_user` začne volat do proměnné,
    -- ať tenhle řádek ohlídá testem — od té chvíle na něm bude záležet.
    _id := NULL;
    GET STACKED DIAGNOSTICS
      _stav = RETURNED_SQLSTATE, _chyba = MESSAGE_TEXT, _kontext = PG_EXCEPTION_CONTEXT;
    PERFORM public.zaloguj_chybu_notifikace(
      _user, _type, 'notifikace', _stav, _chyba, _kontext, _reservation_id, _subject_id);
  END;

  -- Všech 6 volání ve 4 funkcích používá `PERFORM public.notify_user(...)`,
  -- takže NULL nikomu nevadí. Ověřeno dotazem na produkci 14. 9. 2026:
  --   create_booking 1×, approve_subject_request 1×,
  --   notify_reservation_approval 3×, notify_reservation_changed 1×
  -- a ani jedno z nich návratovou hodnotu nečte.
  RETURN _id;
END;
$function$;

-- Úklid: viz poznámka u `SET lock_timeout` na začátku souboru.
RESET lock_timeout;
