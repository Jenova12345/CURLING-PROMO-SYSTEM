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
}

/**
 * Tvar odpovědi `send-emails` — jen ta pole, podle kterých se tu rozhoduje.
 * Všechna jsou nepovinná schválně: kdyby funkce vrátila něco jiného, než
 * čekáme, musí to skončit jako NEÚSPĚCH, ne jako pád parseru.
 */
interface OdpovedSendEmails {
  rezim?: string;
  /** POČET odeslaných zpráv (ne boolean — na rozdíl od `Vysledek.odeslano`). */
  odeslano?: number;
  selhalo?: number;
  zapisSelhal?: number;
}

export interface Vysledek {
  odeslano: boolean;
  duvod: string;
  stav?: number;
  telo?: string;
}

/**
 * ⚠️ NAPLÁNOVANÁ FUNKCE NETLIFY MÁ TVRDÝ STROP 30 SEKUND.
 * Dokumentace: „Scheduled functions have a 30 second execution limit."
 *
 * Dřív tu stálo 60 000 s komentářem o „velké rezervě". Byla to nepravda
 * v obou směrech a našla ji brána code review 13. 9. 2026: strop je poloviční,
 * a hlavně se do něj plná dávka nevejde. `send-emails` čeká mezi voláními
 * Resendu `PAUZA_MS = 550` (Resend má limit 2 požadavky/s), takže dávka 50
 * e-mailů prospí 27,5 s ještě než započítáme síť — Netlify by běh uťalo
 * uprostřed odesílání.
 *
 * Vlastní timeout je proto POD platformním stropem: ať se v logu objeví naše
 * hláška, ne tiché zabití platformou.
 */
export const TIMEOUT_MS = 25_000;

/**
 * Kolik e-mailů si říct za jeden běh.
 *
 * 20 × 550 ms = 11 s prospaných pauz, do třicetisekundového okna se to vejde
 * i s rezervou na síť a na pomalou odpověď Resendu. Hlubší frontu doberou
 * další běhy — při tiknutí po 5 minutách odteče až 240 zpráv za hodinu.
 *
 * ⚠️ To číslo je CELKOVÝ odtok fronty, a nemá se s čím poměřovat: strop
 * `settings.email_max_za_hodinu` (výchozích 100) je na JEDNOHO uživatele,
 * takže dvě různá čísla o dvou různých věcech. Dřív tu stálo, že 240 je
 * „víc než 100", jako by z toho něco plynulo — neplyne. Našla brána code
 * review 13. 9. 2026. Obě meze platí vedle sebe: strop rozhoduje, co se
 * vůbec smí převzít, tahle dávka jen to, kolik se toho zvládne za jeden běh.
 */
export const DAVKA = 20;

/**
 * Rozhodne, jestli se má volat, a zavolá.
 *
 * `fetchFn` je parametr schválně: bez něj by se to nedalo otestovat jinak než
 * skutečným voláním produkce.
 */
export async function vyprazdniFrontu(
  env: Prostredi,
  fetchFn: typeof fetch = fetch,
  // Timeout je parametr jen proto, aby šel OTESTOVAT. `AbortSignal.timeout()`
  // nejde zkoumat zvenčí (nedá se z něj přečíst, na kolik je nastavený)
  // a nepodléhá ani falešným časovačům vitestu — test s ním tedy neuměl
  // rozeznat 25 sekund od jedné milisekundy. Brána code review 13. 9. 2026.
  timeoutMs: number = TIMEOUT_MS,
): Promise<Vysledek> {
  // ⚠️ ŽÁDNÁ KONTROLA KONTEXTU TU NENÍ, A JE TO ZÁMĚR PODLOŽENÝ DOKUMENTACÍ.
  //
  // Chvíli tu stálo `if (env.CONTEXT !== "production")` s komentářem, že to
  // brání `netlify dev` sáhnout na produkci. Brána code review 13. 9. 2026
  // upozornila, že to nejspíš nic nedělá, a dokumentace Netlify to potvrdila:
  // ve funkcích jsou za běhu dostupné JEN `URL`, `SITE_NAME` a `SITE_ID`
  // („only the following variables are available to serverless functions
  // during runtime"). `CONTEXT` je proměnná BUILDU. Podmínka tedy nikdy
  // nevyšla a selhávala OTEVŘENĚ — horší než žádná, protože budila dojem
  // ochrany. Testy si `CONTEXT` dosazovaly ručně, takže to nechytily.
  //
  // Co plochu doopravdy drží:
  //   * plán běží jen na publikovaných nasazeních („Scheduled functions only
  //     run on their schedule for published deploys — Deploy Previews and
  //     branch deploys won't trigger them automatically"),
  //   * servisní klíč existuje jen v prostředí Netlify.
  //
  // Co tím pádem ZBÝVÁ jako vědomé riziko: tlačítko „Run now" v Netlify UI
  // spustí funkci i z náhledu, a `netlify dev` s načtenými produkčními
  // proměnnými zavolá produkci z notebooku. Obojí je vědomý úkon člověka,
  // který k Netlify má přístup — tedy totéž, co platí o každém servisním klíči.

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
      // ⚠️ `limit` se posílá VÝSLOVNĚ, ať se dávka vejde do 30sekundového okna
      // Netlify (viz `DAVKA` výš). Bez něj si `send-emails` vezme svých 50
      // a běh by platforma uťala uprostřed odesílání.
      body: JSON.stringify({ limit: DAVKA }),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    // ⚠️ Chybu NEPOUŠTĚT ven celou. Kdyby `fetch` padl na špatné hlavičce,
    // nese její text kus klíče. Stačí druh chyby.
    const druh = e instanceof Error ? e.name : "neznámá chyba";
    return { odeslano: false, duvod: `Volání send-emails selhalo (${druh}).` };
  }

  // ⚠️ HTTP 200 OD `send-emails` NEZNAMENÁ, ŽE SE ODESLALO. Dvě cesty vracejí
  // dvoustovku, i když neodejde nic:
  //   * chybí (nebo se zrotoval) `RESEND_API_KEY` → funkce spadne do větve
  //     NÁHLEDU, vrátí `rezim: "nahled"` a jen vypíše, co ve frontě leží;
  //   * jednotlivá odeslání selžou → `selhalo: 20`, ale stavový kód se odvozuje
  //     jen z `potiz` a `zapisSelhal`, takže je pořád 200.
  // Kdyby se tu soudilo podle `odpoved.ok`, prošel by zeleně přesně ten případ,
  // kvůli kterému návratový stav vznikl. Našla bezpečnostní brána 13. 9. 2026.
  // Rozhoduje proto TĚLO odpovědi.
  const surove = await odpoved.text().catch(() => "");

  // Ořez až tady: parsuje se CELÉ tělo, do logu jde jen začátek. Odpověď
  // v režimu náhledu může nést adresy a texty zpráv a ty do logu hostingu
  // nepatří.
  const telo = surove.slice(0, 300);
  const stav = odpoved.status;

  if (!odpoved.ok) {
    return { odeslano: false, duvod: `send-emails vrátilo ${stav}.`, stav, telo };
  }

  let zprava: OdpovedSendEmails | null;
  try {
    zprava = JSON.parse(surove) as OdpovedSendEmails;
  } catch {
    zprava = null;
  }

  // Cokoli jiného než ostré odeslání je vada NASTAVENÍ, ne úspěšný běh.
  if (zprava?.rezim !== "ostry") {
    return {
      odeslano: false,
      duvod: zprava?.rezim === "nahled"
        ? "send-emails běželo v režimu NÁHLEDU a nic neodeslalo — chybí RESEND_API_KEY."
        : `send-emails neběželo naostro (režim: ${zprava?.rezim ?? "nerozpoznaný"}).`,
      stav,
      telo,
    };
  }

  const selhalo = Number(zprava.selhalo ?? 0);
  // `zapisSelhal` je horší než `selhalo`: e-mail nejspíš ODEŠEL, ale fronta
  // o tom neví, takže ho úklid za 10 minut pošle znovu. Musí být vidět.
  const zapisSelhal = Number(zprava.zapisSelhal ?? 0);
  if (selhalo > 0 || zapisSelhal > 0) {
    return {
      odeslano: false,
      duvod: `send-emails hlásí neúspěch: selhalo ${selhalo}, nezapsáno ${zapisSelhal}.`,
      stav,
      telo,
    };
  }

  return {
    odeslano: true,
    duvod: `Fronta zpracována, odesláno ${Number(zprava.odeslano ?? 0)}.`,
    stav,
    telo,
  };
}
