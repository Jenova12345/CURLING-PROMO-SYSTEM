-- =============================================================================
-- Přehled nesmí nabízet zrušené akce · `zrusene_akce()`
-- =============================================================================
-- CO SE MĚNÍ: přibývá jedna čtecí funkce. Nic se neruší, nic se nepřepisuje,
-- žádná tabulka ani politika se nedotýká.
--
-- PROČ: stránka Přehled (`src/pages/Dashboard.tsx`) čte „Nadcházející události"
-- přímo z `public.events` a filtruje je jen podle času. `events` ale o zrušení
-- NEVÍ NIC — nemá `status`, `cancelled_at` ani `deleted_at` (ověřeno na živém
-- schématu 14. 9. 2026). Zrušení žije na `reservations` a akce je zrušená tehdy,
-- když jsou všechny její rezervace `cancelled` nebo `deleted_at` — přesně to
-- odpovídá `public.akce_je_zrusena`.
--
-- Kalendář to řeší po svém (`useReservations` propouští jen `status='confirmed'`)
-- a Směny přes `zrusene_akce_se_smenami()`. Přehled neměl ani jedno, takže
-- ukazoval zrušené akce jako nadcházející.
--
-- ZMĚŘENO NA PRODUKCI 14. 9. 2026 (jen SELECT):
--     events celkem 375 · budoucích 351 · z toho ZRUŠENÝCH 36
-- Těch 36 svítí na Přehledu každému přihlášenému jako „nejbližší akce",
-- včetně dvou komerčních teambuildingů, které se nekonají.
--
-- PROČ NOVÁ FUNKCE A NE `zrusene_akce_se_smenami()`:
-- ta sesterská funkce vrací jen akce, KTERÉ MAJÍ SMĚNU — je to nabídkový filtr
-- pro brigádníky. Na Přehledu jde o akce jako takové; klubový trénink bez
-- štábu žádnou směnu nemá, takže by ze staré funkce nevypadl a zrušený trénink
-- by na Přehledu zůstal. Obě funkce stojí na témže `akce_je_zrusena`, takže se
-- nemají jak rozejít; liší se jen záběrem.
--
-- PROČ SECURITY DEFINER: `reservations` má RLS, která běžnému členovi pustí jen
-- rezervace vlastního subjektu — u cizí zrušené akce vidí NULA řádků (změřeno).
-- Kdyby si to frontend počítal sám, vyšla by mu jako zrušená každá cizí akce
-- a Přehled by zhasl celý. Táž úvaha jako u `akce_je_zrusena`.
--
-- PROČ `ucet_aktivni()` NAVÍC (nález bezpečnostní brány, 14. 9. 2026): bez něj
-- byla tahle funkce JEDINÝ článek řetězu bez default-deny brány z bloku C.
-- Změřeno pod JWT deaktivovaného účtu:
--     SELECT count(*) FROM events                 → 0   (RLS)
--     SELECT count(*) FROM reservations_calendar  → 0   (gate v těle pohledu)
--     SELECT count(*) FROM zrusene_akce()         → 52  ← jediná otevřená cesta
-- Účet, který čeká na schválení nebo mu ho admin vypnul, se tak dozvěděl, kolik
-- akcí se ruší. Škoda je malá (holá UUID si k ničemu nedohledá), ale je to
-- výjimka z pravidla, které jinde platí bez výjimky. Pro aktivní účet se nemění
-- nic — ten má `events` čitelné celé.
--
-- Servisní větev (`auth.uid() IS NULL AND SESSION_USER IN (postgres, …)`) je
-- doslovná kopie ze `settings_public` a je tu ze stejného důvodu: aby funkci
-- přečetly migrace a skripty jedoucí přímo v psql. Bez ní vracela `postgres`u
-- nula řádků (změřeno) a nešla by ověřit odjinud než z přihlášené session.
-- `authenticated` ani `anon` se přes ni nikam nedostanou — přes PostgREST je
-- `SESSION_USER` `authenticator`.
--
-- CO TO NEODHALUJE: vrací se pouze `id` akcí, které jsou zrušené. Tentýž fakt
-- už dnes vidí každý aktivní účet v `reservations_calendar` (má sloupce
-- `event_id`, `status`, `cancelled_at`) — žádná nová informace, žádná částka.
-- Ověřeno měřením pod řadovým členem: ID z RPC, která nejdou dohledat
-- v kalendáři = 0.
--
-- -----------------------------------------------------------------------------
-- PROČ SE TĚLO NEPTÁ `akce_je_zrusena()`, I KDYŽ MĚŘÍ TOTÉŽ
-- -----------------------------------------------------------------------------
-- Napoprvé tu stálo `SELECT e.id FROM events e WHERE akce_je_zrusena(e.id)`.
-- Je to čitelnější a měla to být JEDNA definice zrušené akce pro celý repo —
-- jenže je to korelovaný poddotaz a plánovač ho neumí rozbalit. Naměřeno na
-- replice produkce (375 akcí / 451 rezervací), pod `SET LOCAL ROLE authenticated`:
--
--     akce_je_zrusena je SECURITY DEFINER + SET search_path → NEJDE inlinovat,
--     takže se volá 375×, a vnitřní EXISTS nemá použitelný index
--     (`idx_reservations_event` je parciální přes `deleted_at`, plánovač
--     nedokáže pokrytí) → seq scan celých `reservations` na KAŽDOU akci.
--
--     stávající korelovaná:  7,72 ms, shared hit 5774
--     tahle (GROUP BY):      0,14 ms, shared hit 31       ← 54× / 186×
--
-- A hlavně to roste kvadraticky, změřeno na syntetických datech týchž poměrů:
--     375 akcí … 2,6 ms │ 1 000 … 12,4 ms │ 3 000 … 92 ms │ 10 000 … 981 ms
-- Volá se při KAŽDÉM načtení Přehledu KAŽDÝM přihlášeným. Osm milisekund dnes
-- blokér není, vteřina za pár let ano.
--
-- ⚠️ CENA, KTEROU TO STOJÍ: pravidlo „co je zrušená akce" je teď na DVOU
-- místech — tady a v `akce_je_zrusena`. Ta záruka se proto vrací MĚŘENÍM:
-- `supabase/tests/zrusene_akce_test.sql`, scénář 3b, porovnává obě definice
-- na všech akcích v databázi. Kdo sáhne na jednu, musí projít tím testem.
--
-- `event_id IS NOT NULL` není kosmetika: FK `reservations_event_id_fkey` je
-- `ON DELETE SET NULL`, takže osiřelé rezervace s prázdným `event_id` existovat
-- můžou a bez toho filtru by se vracelo NULL.
--
-- VRATNOST: `DROP FUNCTION IF EXISTS public.zrusene_akce();`
-- Revert DB musí jít SPOLU s revertem frontendu — ale ne proto, že by se něco
-- rozbilo: `useQuery` spadne do chybového stavu, uplatní se default `new Set()`
-- a Přehled se TIŠE vrátí k původní vadě. Tichý návrat bugu je horší než pád,
-- protože si ho nikdo nevšimne.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.zrusene_akce()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT r.event_id
    FROM public.reservations r
   WHERE (public.ucet_aktivni()
          OR (auth.uid() IS NULL AND SESSION_USER = ANY (ARRAY['postgres'::name, 'supabase_admin'::name])))
     AND r.event_id IS NOT NULL
   GROUP BY r.event_id
  HAVING count(*) FILTER (WHERE r.status <> 'cancelled' AND r.deleted_at IS NULL) = 0;
$function$;

COMMENT ON FUNCTION public.zrusene_akce() IS
  'ID akcí, které jsou zrušené (všechny jejich rezervace jsou cancelled nebo smazané). '
  'Pro Přehled. Sesterská zrusene_akce_se_smenami() vrací jen podmnožinu s rozpisem směn.';

-- Práva se po CREATE OR REPLACE NEDĚDÍ jistě (u nové funkce platí default
-- `EXECUTE TO PUBLIC`), takže se nastavují výslovně.
--
-- `service_role` tu SCHVÁLNĚ NENÍ, i když ho sestry mají. Gate stojí na
-- `ucet_aktivni()`, tedy na `auth.uid()` — a volání se service key žádný claim
-- `sub` nenese, takže by funkce vrátila PRÁZDNO. Ne chybu, prázdno: filtr na
-- druhé straně by se choval fail-open a zrušené akce by se zase objevily, aniž
-- by kdekoli cokoli spadlo. Servisní větev v těle to nespraví — přes PostgREST
-- je `SESSION_USER` `authenticator`, ne `postgres`, takže ta větev pomáhá jen
-- migracím a skriptům jedoucím přímo v psql (a proto tam je). Grant, který
-- mlčky nefunguje, je horší než žádný: zastaví to příštího čtenáře dřív, než
-- na něm postaví edge funkci. Kdyby ji serverová cesta někdy potřebovat měla,
-- je to jiná úloha — funkce by musela dostat user_id parametrem.
REVOKE ALL ON FUNCTION public.zrusene_akce() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.zrusene_akce() TO authenticated;
