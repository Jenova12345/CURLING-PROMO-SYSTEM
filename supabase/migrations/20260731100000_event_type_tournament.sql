-- =============================================================================
-- Nový typ akce: „Turnaj" (tournament)
-- =============================================================================
-- Zákazník chce vedle Komerční akce a Interní (trénink/údržba) i TURNAJ, s vlastní
-- prioritou při kolizi (komerční > turnaj > trénink) a vlastní sazbou.
--
-- ⚠️ SAMOSTATNÁ MIGRACE ZÁMĚRNĚ: Postgres nedovolí novou hodnotu enumu POUŽÍT
-- ve stejné transakci, ve které vznikla. Další migrace (a seed) s ní už pracují,
-- takže musí běžet v jiné transakci. Ze stejného důvodu má generátor demo_setup.sql
-- za tímto souborem explicitní COMMIT.
-- =============================================================================

ALTER TYPE public.event_type ADD VALUE IF NOT EXISTS 'tournament';
