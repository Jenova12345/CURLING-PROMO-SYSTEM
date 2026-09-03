# 🟡 Ticket: nové helpery kolem zrušených akcí nekontrolují aktivní účet

**Zapsáno:** 3. 9. 2026 · **Stav:** ⏸ otevřené, NEOPRAVENO
**Závažnost:** nízká (únik metadat, ne dat) · **Původ:** zavedeno opravou z 3. 9. 2026 (`0faac1b`)

> Našla to bezpečnostní brána při review migrace `20260903120000`.
> Na rozdíl od [dvou definic zrušené akce](TICKET-zrusena-akce-dve-definice.md)
> **tohle je nové** — přišlo to s mou opravou. Neopravilo se hned proto, že to
> není exploit a chtěl jsem to rozhodnutí nechat na PM: jde o to, kdo má vidět
> které akce, což je produktová otázka, ne technická.

---

## O co jde

Migrace `20260903120000` zavedla čtyři `SECURITY DEFINER` funkce a všem dala
`GRANT EXECUTE ... TO authenticated` bez kontroly, jestli je účet aktivní.
Ověřeno na produkci 3. 9. 2026:

| funkce | `authenticated` | `anon` |
|---|---|---|
| `akce_je_zrusena(uuid)` | ✅ smí | ❌ nesmí |
| `smena_je_na_zrusene_akci(uuid)` | ✅ smí | ❌ nesmí |
| `smena_prijima_prihlasky(uuid)` | ✅ smí | ❌ nesmí |
| `zrusene_akce_se_smenami()` | ✅ smí | ❌ nesmí |

Zbytek repa přitom od migrací `20260831235000` (čekající účet nevidí nic)
a `20260901120000` (deaktivovaný účet nemá práva) drží bránu `ucet_aktivni()` —
na produkci ji má **10 politik**.

## Co z toho plyne

Kdokoli **přihlášený** — včetně účtu, který ještě čeká na schválení, i toho,
který byl deaktivován — si může:

- na libovolné `event_id` zjistit, jestli je akce zrušená
  (`akce_je_zrusena`), a to i u akce cizího klubu, na jejíž rezervaci
  přes RLS nevidí;
- vytáhnout **rovnou celou množinu** zrušených akcí, které mají směny
  (`zrusene_akce_se_smenami()`, bez parametru).

Přesně tomu má `SECURITY DEFINER` u těch funkcí sloužit — bez něj by brána
nefungovala na toho, koho má zastavit — takže definer je správně; chybí jen
kontrola, kdo se smí ptát.

## Proč to není vážné

- Vrací se **boolean nebo seznam `event_id`**, nikdy řádek rezervace: žádný
  subjekt, cena, čas ani jméno.
- Nerozliší „akce má jen zrušené rezervace" od „akce nemá žádnou rezervaci" —
  obojí je `false`.
- Aktivní přihlášený uživatel `events` stejně vidí.

Zbývá tedy jen to, že **publikum je širší, než odpovídá zbytku repa**: čekající
účet, který podle `20260831235000` nemá vidět nic, si tudy vytáhne množinu
id zrušených akcí.

## Návrh opravy

1. Do těla `zrusene_akce_se_smenami()` přidat `AND public.ucet_aktivni()`
   (nebo rovnou `IF NOT ucet_aktivni() THEN RETURN; END IF;`). To je ta
   funkce, kterou volá frontend, a jediná, kde má kontrola smysl.
2. U zbylých tří **prověřit, jestli grant pro `authenticated` vůbec
   potřebují**. Volají se ze dvou míst:
   - z triggerů (`SECURITY DEFINER` kontext) — tam grant potřeba není,
   - z výrazů RLS politik — **tady se to musí odměřit, ne odhadnout.**
     Bezpečnostní brána tvrdila, že politiky vyhodnocuje vlastník tabulky,
     takže grant netřeba; to je ale v rozporu s tím, že výrazy politik běží
     s právy dotazujícího se uživatele. **Ověřit pokusem na replice**
     (odebrat grant → zkusit přihlášku i uvolnění směny pod rolí
     `authenticated`), ne úvahou.
3. Pozor na `ucet_aktivni()` uvnitř funkcí volaných z politiky — hrozí
   zacyklení nebo zbytečné dotazy navíc u každého řádku. Změřit.

## Na co nezapomenout

- Mutační test: po přidání `ucet_aktivni()` musí zčervenat scénář, kde se
  deaktivovaný účet ptá — a **nesmí** zčervenat scénáře 1–12 v
  `supabase/tests/zrusena_akce_nenabizi_test.sql`.
- Hlavně scénář 5 (na živé akci všechno dál funguje) a 12 (RPC vidí
  neadmin) — tam se pozná, jestli se kontrolou nezavřel i běžný provoz.
