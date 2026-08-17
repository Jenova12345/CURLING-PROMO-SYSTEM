-- =============================================================================
-- EVIDENCE PROBĚHLÝCH MIGRACÍ
-- =============================================================================
-- Bez tohohle se nedá nasazovat inkrementálně. Devět z migrací v repu NENÍ
-- znovuspustitelných (`CREATE TYPE`, `ADD COLUMN` bez `IF NOT EXISTS`, změna
-- návratového typu funkce…), takže „pusť všechno znovu" skončí chybou a
-- v půlce. Jediná bezpečná cesta je pouštět jen to, co ještě neproběhlo — a to
-- vyžaduje vědět, co proběhlo.
--
-- PROČ VLASTNÍ TABULKA A NE `supabase_migrations.schema_migrations`:
-- tu plní Supabase CLI při `db push`. Na demo se ale SQL pouští ručně přes
-- dashboard, takže by tam nic nebylo a evidence by lhala. Tahle tabulka
-- odpovídá tomu, jak se sem doopravdy nasazuje.
--
-- KDY TO SPUSTIT
--   * jednorázově na demu, které vzniklo resetem (tehdy proběhly VŠECHNY
--     migrace v repu — proto se rovnou všechny zapíšou jako proběhlé)
--   * dál už se plní samo, z upgrade skriptu
--
-- Spouští se pod databázovou rolí (dashboard běží jako `postgres`).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.migrace_log (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now(),
  applied_by text        NOT NULL DEFAULT current_user,
  sha256     text
);

COMMENT ON TABLE public.migrace_log IS
  'Které migrace už na téhle databázi proběhly. Řídí se tím inkrementální nasazení (scripts/build-upgrade-sql.sh) — bez toho by se na živá data pouštěly migrace, které nejsou znovuspustitelné.';

-- Čte ji jen nasazovací skript pod databázovou rolí; aplikace do ní nemá co mluvit.
ALTER TABLE public.migrace_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.migrace_log FROM anon, authenticated, public;

-- -----------------------------------------------------------------------------
-- Backfill: co všechno považovat za proběhlé
--
-- Seznam se doplňuje generátorem (`build-upgrade-sql.sh --backfill`), ať se
-- neopisuje ručně. Zápis je `ON CONFLICT DO NOTHING`, takže opakované spuštění
-- nic nepřepíše ani neposune datum.
-- -----------------------------------------------------------------------------
-- BACKFILL-ZACATEK (generované — needituj ručně)
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260715000000_baseline_production', 'd46a2c2ba6891e308b5e51cde9d4dd67cc831cd528e04059443ba331ec342034')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260716120000_auth_user_trigger', 'a34e94fe9d815305c255625fafbc416a889800fbf7024bc3770031a445fc2c58')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260716130000_etapa1_schema', 'd4e0e92257cb95f8ecacd5420adf9ab129d601e05293dce3a0acf9b4e919d135')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260716140000_etapa1_rls', '73622e6c51d290f1755cfbdadfe946689ec8a3bf772c73295422fee98652479f')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260717120000_unified_calendar', '0d234ea4658f0d2734d1dd3c70dc58a462cb4cd69a384c1a3a4664fdb5fe1f8c')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260718120000_membership_levels', 'a3bc1b806b4337a4ef5d63c9e629280ddc31c87b9173c9bc7ab3747514fd6b83')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260731090000_rebrand_drahy', '56580fbe32bf82e6fdb81f706fbb70c2743948422efc1f8ef99c6f190f47fee3')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260731100000_event_type_tournament', 'f2f505002a53f75d3767c108b8442c78b3027f7af68116e056e6d245a73992cc')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260731110000_booking_core', 'b7edb25da8ef3bf88af33d8d18b61ecaa2a760ad27b4caa5e0921f431d997055')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260731120000_booking_api', '5c4dd025b8f62ed1d89e3e09af35f3c415f05d6927e319ceb378eba155bd0715')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260804090000_group_actions_and_billing', '7009493219e446cd224b8a7ace014e6a3451fc28bf174f33da9af027512b7505')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260812120000_sazby_a_korekce_checks', '47f53b0e3d1e29fdb6454e6f3a9a6aae980c374643899901dbcf7350340cc4ed')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260812140000_cenik_jen_adminovi', '43639fb09e1682e2bd1f856edc0b41a309f4e9d9d5d7200c24302066465b1bed')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260812160000_billing_settings', 'b73f6341aa8e4c4509840fd44b1bd853a3d0b6e60185d70d9e20cf6a76ad1a02')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260812180000_fakturacni_udaje_checks', 'f925bfa26aa3ff45ec51237491624e74d372e1e655036d4633ada8fcb938ce91')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260812200000_security_hardening', 'a2c50c1dcf257df49e06fdd763dc95e48b5bf99321b33979ac27a0c681602f6f')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260813090000_faktury_zaklad', 'bf2dc76a09ee21c9f9551716ebb8540086912dd201d211e390f2b4ed956fa2ff')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260813120000_strop_sazby', 'b170d6fa45d2beb8b57484a09d47ff3974fefc7b60c6e630f1ef212b434cdf11')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260813140000_faktury_rpc', '00e71a30ac4cbd43b793a59cf9187f014bef2928af0859f03d3c4336bccaca15')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260813160000_billing_reconcile', 'db808dfe0ae4e97420228bfa973c5c2d61ccd28ad3acad816b3625c4e04815b4')
  ON CONFLICT (version) DO NOTHING;
INSERT INTO public.migrace_log (version, sha256) VALUES ('20260814120000_evidence_uhrady', '0a6e119e4ecc89841e7284f0a330137d44cbb767e019576a6b33eeb7f5135fdb')
  ON CONFLICT (version) DO NOTHING;
-- BACKFILL-KONEC
