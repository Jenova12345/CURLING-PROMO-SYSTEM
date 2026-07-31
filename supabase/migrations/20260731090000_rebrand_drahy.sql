-- =============================================================================
-- Rebrand terminologie: „plátno" → „dráha"
-- =============================================================================
-- Zákazník (Jakub) používá pro ledovou plochu slovo „dráha". Tabulka se dál jmenuje
-- `sheets` (přejmenování tabulky by rozbilo FK/politiky/typy bez užitku) — mění se jen
-- zobrazovaný název v datech. Texty v UI jsou přepsané v aplikaci.
-- Bezpečné a idempotentní: přepíše jen řádky, které ještě mají starý název.
-- =============================================================================

UPDATE public.sheets
   SET name = replace(name, 'Plátno', 'Dráha')
 WHERE name LIKE 'Plátno%';
