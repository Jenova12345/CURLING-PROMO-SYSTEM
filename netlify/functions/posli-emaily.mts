// ---------------------------------------------------------------------------
// Naplánovaná funkce: každých 5 minut vyprázdní frontu e-mailů
// ---------------------------------------------------------------------------
// PROČ ZVENČÍ A NE Z DATABÁZE: původní návrh plánoval `pg_cron` + `pg_net`
// přímo v Supabase. Brány 12. 9. 2026 změřily cenu: `CREATE EXTENSION pg_net`
// spustí supabasí event trigger `issue_pg_net_access`, který udělí `anon`
// i `authenticated` USAGE na schéma `net` a SELECT na `net._http_response`
// — a `postgres` ty granty odebrat NEUMÍ (udělil je `supabase_admin`).
// Produkce dnes `pg_net` nainstalovaný nemá, takže by ten push útočnou plochu
// teprve vytvořil. Rozhodnutí PM: časovač jde zvenčí, `pg_net` se na produkci
// neinstaluje.
//
// Vedlejší přínos: odpadá celý problém s tím, že hlavičky odchozích požadavků
// pg_netu leží v tabulce bez RLS. Servisní klíč tady žije v prostředí Netlify,
// kam se z databáze nikdo nedostane.
//
// ⚠️ PROMĚNNÁ PROSTŘEDÍ, KTEROU JE TŘEBA VLOŽIT DO NETLIFY (Site configuration
// → Environment variables), jméno je závazné, čte se přesně takhle:
//
//     SUPABASE_SERVICE_ROLE_KEY   servisní klíč produkčního projektu
//
// Nepovinně (jen pokud v Netlify není `VITE_SUPABASE_URL`, ze kterého se to
// jinak vezme):
//
//     SUPABASE_URL                https://<ref>.supabase.co
//
// Dokud klíč chybí, funkce se spustí, NIC NEVOLÁ a napíše do logu proč.
// To je záměr: lokál ani náhledová nasazení tak nikdy nesáhnou na produkci.
//
// ⚠️ Fronta se ani nenaplní, dokud admin nezapne `email_notifications_enabled`
// (na produkci je dnes `false`). Tahle funkce tedy může běžet naprázdno
// libovolně dlouho, aniž by cokoli odeslala.
// ---------------------------------------------------------------------------

import { vyprazdniFrontu } from "../lib/fronta-emailu.mts";

// Naplánování čte Netlify z tohohle exportu. Pět minut proto, že notifikace
// o rezervaci nemusí dorazit do vteřiny a každé tiknutí je jedno volání
// i s prázdnou frontou.
export const config = {
  schedule: "*/5 * * * *",
};

export default async () => {
  const vysledek = await vyprazdniFrontu(process.env as Record<string, string | undefined>);

  // Log je jediné místo, kde je vidět, že to jede. Klíč v něm není nikdy.
  console.log(
    `[fronta e-mailů] ${vysledek.odeslano ? "OK" : "NEODESLÁNO"}: ${vysledek.duvod}` +
      (vysledek.telo ? ` | odpověď: ${vysledek.telo}` : ""),
  );

  // Neúspěch se musí projevit jako neúspěšný běh, jinak by se tichá porucha
  // (zrotovaný klíč, neověřená doména) schovala mezi zelenými spuštěními.
  return new Response(vysledek.duvod, { status: vysledek.odeslano ? 200 : 500 });
};
