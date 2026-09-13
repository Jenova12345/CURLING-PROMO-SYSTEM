// ---------------------------------------------------------------------------
// Vyprázdnění fronty e-mailů: rozhodovací část, oddělená od Netlify
// ---------------------------------------------------------------------------
// Proč vlastní modul a ne všechno v handleru: tohle je jediné místo, kde se
// z Netlify posílá SERVISNÍ KLÍČ, a to si zaslouží test. Handler kolem toho
// dělá jen obálku, kterou testovat nejde bez běžícího Netlify.
//
// ⚠️ TENHLE MODUL SE NESMÍ DOSTAT DO `src/`. Do `src/` sahá Vite bundle,
// takže by servisní klíč měl teoretickou cestu do prohlížeče. Je to týž důvod,
// proč je mimo `src/` i `billing/` (viz vitest.config.ts).
// ---------------------------------------------------------------------------

export interface Prostredi {
  /** Servisní klíč Supabase. Jméno proměnné je závazné, viz README níž. */
  SUPABASE_SERVICE_ROLE_KEY?: string;
  /** URL projektu. Když chybí, zkusí se `VITE_SUPABASE_URL` z buildu. */
  SUPABASE_URL?: string;
  VITE_SUPABASE_URL?: string;
  /** Netlify: 'production' | 'deploy-preview' | 'branch-deploy' | 'dev'. */
  CONTEXT?: string;
}

export interface Vysledek {
  odeslano: boolean;
  duvod: string;
  stav?: number;
  telo?: string;
}

/** Kolik čekat na edge funkci, než to vzdáme. Dávka 50 e-mailů s pauzami
 *  mezi voláními Resendu se vejde do půl minuty s velkou rezervou. */
export const TIMEOUT_MS = 60_000;

/**
 * Rozhodne, jestli se má volat, a zavolá.
 *
 * `fetchFn` je parametr schválně: bez něj by se to nedalo otestovat jinak než
 * skutečným voláním produkce.
 */
export async function vyprazdniFrontu(
  env: Prostredi,
  fetchFn: typeof fetch = fetch,
): Promise<Vysledek> {
  // ⚠️ JEN PRODUKČNÍ NASAZENÍ. Naplánované funkce sice Netlify pouští jen
  // v produkci, ale `netlify dev` na lokále má tytéž proměnné — a kdyby si je
  // někdo načetl, volal by ostrou produkci z notebooku. Když `CONTEXT` chybí
  // (test, cizí prostředí), nerozhoduje se podle něj.
  if (env.CONTEXT && env.CONTEXT !== "production") {
    return { odeslano: false, duvod: `Kontext '${env.CONTEXT}' není produkce, nevolám nic.` };
  }

  const klic = env.SUPABASE_SERVICE_ROLE_KEY?.trim();
  // `.trim()` NENÍ kosmetika. Secret vložený přes schránku s sebou běžně nese
  // koncový nový řádek a ten shodí celý `fetch` na
  //     TypeError: Failed to construct 'Request': 'headers' … not a valid ByteString
  // Přesně tohle se 12. 9. 2026 stalo v edge funkci při prvním ostrém odeslání.
  const url = (env.SUPABASE_URL ?? env.VITE_SUPABASE_URL)?.trim().replace(/\/+$/, "");

  // Bez tajemství se MLČÍ, ale hlásí se to jako chyba: naplánovaná funkce,
  // která tiše nedělá nic, je horší než ta, která spadne viditelně.
  if (!klic) {
    return { odeslano: false, duvod: "Chybí SUPABASE_SERVICE_ROLE_KEY v prostředí Netlify." };
  }
  if (!url) {
    return { odeslano: false, duvod: "Chybí SUPABASE_URL (ani VITE_SUPABASE_URL) v prostředí Netlify." };
  }

  let odpoved: Response;
  try {
    odpoved = await fetchFn(`${url}/functions/v1/send-emails`, {
      method: "POST",
      headers: {
        // `Authorization` rozhoduje o roli, `apikey` říká, KTERÝ projekt.
        // Platformní brána Supabase bez `Authorization` požadavek k funkci
        // vůbec nepustí (ověřeno: 401 UNAUTHORIZED_NO_AUTH_HEADER).
        Authorization: `Bearer ${klic}`,
        apikey: klic,
        "Content-Type": "application/json",
      },
      body: "{}",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    // ⚠️ Chybu NEPOUŠTĚT ven celou. Kdyby `fetch` padl na špatné hlavičce,
    // nese její text kus klíče. Stačí druh chyby.
    const druh = e instanceof Error ? e.name : "neznámá chyba";
    return { odeslano: false, duvod: `Volání send-emails selhalo (${druh}).` };
  }

  // Tělo se čte kvůli logu, ale ořezané: odpověď v režimu náhledu může nést
  // adresy a texty zpráv a ty nepatří do logu hostingu.
  const telo = (await odpoved.text().catch(() => "")).slice(0, 300);

  return {
    odeslano: odpoved.ok,
    duvod: odpoved.ok ? "Fronta zpracována." : `send-emails vrátilo ${odpoved.status}.`,
    stav: odpoved.status,
    telo,
  };
}
