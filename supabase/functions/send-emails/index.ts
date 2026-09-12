// Supabase Edge Function: send-emails
// ---------------------------------------------------------------------------
// Odešle e-maily z fronty public.email_outbox přes Resend.
//
// STAV (11. 9. 2026): NENASAZENO. Funkce je hotová, ale fronta se ani neplní,
// dokud admin nezapne `settings.email_notifications_enabled` (na produkci je
// dnes `false` a fronta má 0 řádků), a bez RESEND_API_KEY se neodesílá nic.
//
// SECRETY (jména jsou závazná, čtou se přesně takhle):
//   RESEND_API_KEY      klíč z Resendu. Dokud chybí, běží funkce v režimu náhledu.
//   EMAIL_FROM          nepovinné; výchozí je odesílatel níž.
//   EMAIL_MOCK_ENABLED  nepovinné, JEN na lokále a demu. "true" povolí režim
//                       nanečisto. Na produkci se NENASTAVUJE.
//
//   supabase secrets set RESEND_API_KEY=re_xxx
//   supabase secrets set EMAIL_FROM="Curling Promo Ostrava <noreply@mail.curlingpromoostrava.cz>"
//   supabase functions deploy send-emails
// a naplánovat pravidelné volání (pg_cron / Supabase Scheduler, např. po 5 minutách).
//
// TŘI REŽIMY:
//   * ostrý      — má klíč, volá Resend, přepisuje stavy.
//   * náhled     — `{"dryRun": true}` nebo chybějící klíč. NIC nezapisuje,
//                  jen vrátí, co by odešlo (příjemce, předmět, tělo). Tímhle
//                  se dají zkontrolovat šablony ještě před získáním klíče.
//   * nanečisto  — `{"mock": true}`. Projde CELOU cestu včetně zamykání fronty,
//                  ale místo Resendu nevolá nic a řádky označí `skipped`.
//                  Schválně NE `sent`: řádek nesmí tvrdit, že e-mail odešel.
//
//                  ⚠️ `skipped` je TERMINÁLNÍ stav, nic ho nevrací do fronty.
//                  Jedno volání proti ostré frontě by tedy nevratně zahodilo
//                  čekající poštu, tiše a bez chyby. Proto se mock nespouští
//                  na slovo z těla požadavku: musí být nastavené
//                  EMAIL_MOCK_ENABLED=true A ZÁROVEŇ nesmí být RESEND_API_KEY.
//                  Jakmile klíč existuje, mock nemá důvod a odmítá se.
//
// POJISTKA PROTI DVOJÍMU ODESLÁNÍ je v databázi, ne tady:
//   `email_outbox_prevzit()` si dávku zamkne (FOR UPDATE SKIP LOCKED) a hned
//   přepíše na `sending`, takže souběžný běh týž řádek neuvidí. Dřív se tu
//   četlo prosté `status='pending'` a dva běhy poslaly každý svůj e-mail.
//
// ⚠️ VOLAJÍCÍ SE OVĚŘUJE, A TO ZDE. Platformní `verify_jwt` propustí i
// PUBLISHABLE klíč, který jede v každém prohlížeči, takže „přihlášený
// uživatel" tu není žádná závora. Bez téhle kontroly by frontu mohl vyprázdnit
// kdokoli.
//
// Ověřuje se ROLE, ne tvar klíče. Dřív tu (a pořád v `invoice-pdf`) stálo
// `auth.includes(SUPABASE_SERVICE_ROLE_KEY)`, což vypadá jako kontrola role,
// ale je to kontrola jedné konkrétní hodnoty. Produkce mezitím přešla na novou
// generaci klíčů (`sb_secret_…` místo legacy JWT), takže legitimní volání
// serveru začalo padat a nasazenou funkci nešlo spustit ani z Dashboardu.
// Seznam přijímaných tvarů klíče by tentýž problém jen odložil k další
// generaci nebo k první rotaci.
//
// `moje_role()` se místo toho zeptá databáze, KDO volá. PostgREST umí ověřit
// každou generaci klíčů sám, padělek k němu neprojde, a admin dostane
// 'authenticated' — admin totiž není servisní role.
// ---------------------------------------------------------------------------

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const BATCH = 50;
// ⚠️ Musí odpovídat rozpočtu pokusů v `email_outbox_prevzit` (`attempts < 5`
// ve výběru, `attempts >= 5` v úklidu). Změna jen tady znamená, že se běžná
// chyba vzdá jinde než chyba uvíznutá.
const MAX_POKUSU = 5;

// Resend má ve výchozím nastavení limit 2 požadavky/s. Padesát sekvenčních
// fetchů bez prodlevy ho spolehlivě překročí a část dávky by shořela na 429.
const PAUZA_MS = 550;

/**
 * Chyby, které se NETÝKAJÍ jednoho řádku, ale celé dávky: špatný nebo chybějící
 * klíč, neověřená doména, překročený limit, výpadek Resendu.
 *
 * Rozdíl je zásadní. Kdyby se braly jako chyba řádku, ubere každý běh cronu
 * jeden pokus a po pěti tiknutích (~25 minut) je první várka reálných
 * notifikací trvale `failed` — a po opravě klíče nebo ověření domény ji už
 * nic nepošle. Proto se při nich dávka PŘERUŠÍ a zbytek se vrátí do fronty
 * BEZ započteného pokusu.
 */
const CHYBA_DAVKY = new Set([401, 403, 408, 429, 500, 502, 503, 504]);

const pauza = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Porovnání dvou tajemství v konstantním čase.
 *
 * `a === b` skončí na prvním odlišném znaku, takže doba odpovědi prozrazuje,
 * kolik znaků souhlasilo. Přes síť je to nepraktické, ale je to zadarmo
 * a tohle je právě to místo, kde se porovnává tajemství.
 */
const shodaVKonstantnimCase = (a: string, b: string): boolean => {
  // ⚠️ Prázdné se nerovná NIČEMU, ani druhému prázdnému. Bez tohohle řádku
  // vrátí funkce pro dvě prázdné hodnoty `true` (cyklus se neprovede, rozdíl
  // zůstane nula) — tedy táž chyba jako kdysi `auth.includes('')`, jen jinak
  // zabalená. Stačilo by, aby servisní klíč vyšel prázdný (rotace, překlep
  // v `secrets set`) a anonym s prázdnou hlavičkou by frontu vyprázdnil.
  if (a.length === 0 || b.length === 0) return false;
  if (a.length !== b.length) return false;
  let rozdil = 0;
  for (let i = 0; i < a.length; i++) rozdil |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return rozdil === 0;
};

/** Nejdelší token, který má smysl vůbec zkoumat. */
const MAX_TOKEN = 8192;
/** Kolik čekat na databázi při ověřování role, než to vzdáme (a odmítneme). */
const TIMEOUT_OVERENI_MS = 5000;

const VYCHOZI_ODESILATEL =
  "Curling Promo Ostrava <noreply@mail.curlingpromoostrava.cz>";

/**
 * Táž hrubá kontrola jako `public.email_je_platny` v databázi. Je tu podruhé
 * schválně: do fronty mohl řádek přibýt dřív, než kontrola v SQL vznikla,
 * a Resend by takovou adresu odmítal pětkrát po sobě jako by šlo o poruchu.
 */
const adresaJePlatna = (email: string | null | undefined): boolean =>
  !!email &&
  email.length >= 6 &&
  email.length <= 254 &&
  /^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$/.test(email);

interface RadekFronty {
  id: string;
  email: string;
  subject: string;
  body: string;
  attempts: number;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  // ⚠️ `.trim()` NENÍ kosmetika. Secret vložený z proměnné nebo ze souboru
  // s sebou běžně nese KONCOVÝ NOVÝ ŘÁDEK, a ten v hlavičce `Authorization`
  // shodí celý `fetch` na
  //     TypeError: Failed to construct 'Request': 'headers' … not a valid ByteString
  // Přesně tohle se 12. 9. 2026 stalo na produkci při prvním ostrém odeslání.
  const apiKey = Deno.env.get("RESEND_API_KEY")?.trim();
  const from = (Deno.env.get("EMAIL_FROM") ?? VYCHOZI_ODESILATEL).trim();

  const url = Deno.env.get("SUPABASE_URL");
  const servisniKlic = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !servisniKlic) {
    return json({ error: "Chybí SUPABASE_URL nebo SERVICE_ROLE_KEY." }, 500);
  }

  // Servisní klíč obchází RLS, takže tahle funkce nesmí být volatelná zvenčí
  // bez něj. `verify_jwt` na to nestačí, vyhoví mu i publishable klíč z bundlu.
  const odmitnout = () =>
    json({ error: "Frontu e-mailů obsluhuje jen server." }, 401);

  const token = (req.headers.get("Authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();

  // Tvar a strop JEŠTĚ PŘED síťovým voláním. Rychlá cesta níž se útočníkovým
  // tokenem nikdy netrefí, takže by každý anonymní požadavek z internetu
  // propadl až k dotazu do databáze — jedno spojení na požadavek zadarmo.
  if (!token || token.length > MAX_TOKEN || !/^[A-Za-z0-9._-]+$/.test(token)) {
    return odmitnout();
  }

  // Rychlá cesta: volající poslal přesně ten klíč, který má funkce sama.
  let jeServer = shodaVKonstantnimCase(token, servisniKlic);

  // Jinak se zeptáme databáze, na jakou roli PostgREST volajícího přepnul.
  // Tohle je ta část, která nezávisí na generaci ani na rotaci klíče.
  //
  // `apikey` je publishable klíč projektu (jen říká, KTERÝ projekt), zatímco
  // `Authorization` nese pověření VOLAJÍCÍHO a rozhoduje o roli. Kdyby se do
  // obojího dal cizí token, odmítne ho brána dřív a ověření by nikdy nedalo
  // `service_role` — tedy fail-closed, ale ze špatného důvodu.
  if (!jeServer) {
    try {
      const klientVolajiciho = createClient(url, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
        auth: { persistSession: false },
        global: { headers: { Authorization: `Bearer ${token}` } },
      });
      // `.rpc()` nemá výchozí timeout: bez tohohle by ověření viselo na
      // nedostupné databázi, dokud požadavek nezabije platforma.
      const { data, error } = await klientVolajiciho
        .rpc("moje_role")
        .abortSignal(AbortSignal.timeout(TIMEOUT_OVERENI_MS));

      // Tvrdá kontrola typu, ne truthy test. `anon` sem dorazí jako chyba
      // 42501 (na `moje_role` nemá EXECUTE) a to je ODMÍTNUTÍ, ne „nevím".
      // A kdyby se návratový typ funkce někdy změnil na tabulku, přišlo by
      // pole `['service_role']`, které by `if (data)` propustilo.
      jeServer = !error && typeof data === "string" && data === "service_role";
    } catch {
      // Nedostupná databáze, timeout ani rozbitá hlavička neotevírají dveře.
      jeServer = false;
    }
  }

  if (!jeServer) return odmitnout();

  let volba: { dryRun?: boolean; mock?: boolean; limit?: number } = {};
  try {
    if (req.headers.get("content-type")?.includes("application/json")) {
      volba = await req.json();
    }
  } catch {
    // prázdné nebo nečitelné tělo = výchozí chování, ne chyba
  }

  const limit = Math.min(Math.max(Number(volba.limit) || BATCH, 1), 200);

  // Mock zahazuje frontu do terminálního `skipped`, takže ho nesmí spustit
  // pouhé slovo v těle požadavku. Dvě nezávislé podmínky:
  //   1) prostředí si o něj výslovně řeklo (na produkci se ta proměnná nenastaví),
  //   2) neexistuje klíč — jakmile umíme odesílat doopravdy, mock nemá důvod.
  const mockPovolen = Deno.env.get("EMAIL_MOCK_ENABLED") === "true" && !apiKey;
  if (volba.mock === true && !mockPovolen) {
    return json({
      error: "Režim nanečisto není v tomhle prostředí povolený.",
      duvod: apiKey
        ? "RESEND_API_KEY je nastavený, takže se dá testovat naostro."
        : "Chybí EMAIL_MOCK_ENABLED=true.",
    }, 400);
  }
  const nanecisto = volba.mock === true;

  // Bez klíče se nikdy neodesílá. Místo dřívějšího „nic nedělám" vrátíme
  // rovnou náhled, ať se dají šablony zkontrolovat před získáním klíče.
  // `mock` má přednost, jinak by ho náhled spolkl právě tehdy, kdy je
  // nejvíc potřeba, tedy dokud klíč ještě nemáme.
  const nahled = volba.dryRun === true || (!apiKey && !nanecisto);

  const supabase = createClient(url, servisniKlic, { auth: { persistSession: false } });

  // ---- Náhled: jen čte, nic nezamyká a nic nepřepisuje ---------------------
  if (nahled) {
    const { data, error } = await supabase
      .from("email_outbox")
      .select("id, email, subject, body, attempts, status")
      .eq("status", "pending")
      .order("created_at", { ascending: true })
      .limit(limit);

    if (error) {
      return json({ error: "Frontu se nepodařilo načíst.", detail: error.message }, 500);
    }

    return json({
      rezim: "nahled",
      duvod: apiKey ? "vyzadano parametrem dryRun" : "RESEND_API_KEY neni nastaveny",
      odesilatel: from,
      ceka: data?.length ?? 0,
      // Fronta zůstává beze změny, tohle je jen ukázka.
      nahledy: (data ?? []).map((m) => ({
        id: m.id,
        prijemce: m.email,
        adresaPlatna: adresaJePlatna(m.email),
        predmet: m.subject,
        telo: m.body,
      })),
    });
  }

  // ---- Ostrý i nanečisto: dávku si zamkneme přes RPC ----------------------
  const { data: davka, error: chybaPrevzeti } = await supabase
    .rpc("email_outbox_prevzit", { _limit: limit });

  if (chybaPrevzeti) {
    return json(
      { error: "Dávku se nepodařilo převzít.", detail: chybaPrevzeti.message },
      500,
    );
  }

  const fronta = (davka ?? []) as RadekFronty[];
  if (!fronta.length) {
    return json({ rezim: nanecisto ? "nanecisto" : "ostry", odeslano: 0, note: "Fronta je prázdná." });
  }

  // Klíč, který se nevejde do HTTP hlavičky, je vada NASTAVENÍ, ne vada řádku.
  // Kdyby se to zjišťovalo až uvnitř smyčky, spolkne každý běh cronu jeden
  // pokus u každého řádku a po pěti tiknutích je celá fronta trvale `failed` —
  // a po opravě secretu už ji nic nepošle. Proto se to rozhoduje jednou, tady,
  // a celá dávka se vrací do fronty bez započteného pokusu.
  const hlavickaJeCista = (v: string) => /^[\t\x20-\x7e\x80-\xff]*$/.test(v);

  let odeslano = 0;
  let preskoceno = 0;
  let selhalo = 0;
  let vraceno = 0;
  let zapisSelhal = 0;
  let preskoceno422 = 0;
  let potiz: string | null = apiKey && !hlavickaJeCista(apiKey)
    ? "RESEND_API_KEY obsahuje znak, který nesmí do HTTP hlavičky (typicky " +
      "koncový nový řádek). Nastav secret znovu, bez bílých znaků na konci."
    : null;

  /**
   * Dopíše výsledek jednoho řádku. Vrací `false`, když se zápis nepovedl.
   *
   * Tohle NENÍ kosmetika. supabase-js chybu nehází, vrací ji v `{ error }` —
   * kdyby se ignorovala, zůstal by úspěšně odeslaný řádek ve stavu `sending`,
   * po deseti minutách by ho úklid vrátil do fronty a e-mail by odešel PODRUHÉ.
   */
  const dokonci = async (id: string, zmeny: Record<string, unknown>): Promise<boolean> => {
    const { error } = await supabase.from("email_outbox").update(zmeny).eq("id", id);
    if (error) {
      zapisSelhal++;
      potiz ??= `Stav řádku se nepodařilo zapsat: ${error.message}`;
      return false;
    }
    return true;
  };

  /** Vrátí řádek do fronty BEZ započteného pokusu (chyba nebyla jeho vina). */
  const vratDoFronty = async (mail: RadekFronty, duvod: string) => {
    await dokonci(mail.id, {
      status: "pending",
      // Pokus se odečítá zpět: rozpočet pěti pokusů je na chyby TOHOTO řádku,
      // ne na výpadek Resendu nebo špatně nastavený klíč.
      attempts: Math.max(mail.attempts - 1, 0),
      claimed_at: null,
      last_error: duvod.slice(0, 500),
    });
    vraceno++;
  };

  for (let i = 0; i < fronta.length; i++) {
    const mail = fronta[i];

    // Dávku přerušila chyba, která se netýká řádků: zbytek vracíme netknutý.
    if (potiz !== null && !nanecisto) {
      await vratDoFronty(mail, potiz);
      continue;
    }

    // Neplatná adresa se tiše přeskočí. Není to porucha odesílání, opakování
    // by nepomohlo a `failed` by v přehledu vypadalo jako výpadek pošty.
    if (!adresaJePlatna(mail.email)) {
      await dokonci(mail.id, {
        status: "skipped",
        last_error: "Neplatná adresa příjemce, e-mail se neodesílal.",
      });
      preskoceno++;
      continue;
    }

    if (nanecisto) {
      await dokonci(mail.id, {
        status: "skipped",
        last_error: "MOCK: běh nanečisto, e-mail se neodesílal.",
      });
      preskoceno++;
      continue;
    }

    let resp: Response;
    try {
      if (i > 0) await pauza(PAUZA_MS);
      resp = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from,
          to: [mail.email],
          subject: mail.subject,
          text: mail.body,
        }),
      });
    } catch (e) {
      // Síť selhala, e-mail tedy s jistotou neodešel. Tady se pokus počítá:
      // je to normální přechodná chyba, na kterou je rozpočet pěti pokusů.
      await dokonci(mail.id, {
        status: mail.attempts >= MAX_POKUSU ? "failed" : "pending",
        claimed_at: null,
        last_error: String(e).slice(0, 500),
      });
      selhalo++;
      continue;
    }

    if (resp.ok) {
      // ⚠️ Zápis „odesláno" je SCHVÁLNĚ MIMO try/catch kolem fetche.
      // Kdyby byl uvnitř a selhal, spadlo by to do větve pro NEODESLANÝ
      // e-mail, řádek by se vrátil do fronty a Resend by ho poslal podruhé.
      //
      // Když se zápis nepovede, e-mail přesto odešel, takže se počítá jako
      // odeslaný. Ale je to tichá cesta k druhému odeslání (úklid takový
      // řádek za deset minut vrátí do fronty), proto to `dokonci` započítá
      // do `zapisSelhal` a odpověď skončí chybou, ať to není vidět jen v logu.
      await dokonci(mail.id, {
        status: "sent",
        sent_at: new Date().toISOString(),
        last_error: null,
      });
      odeslano++;
      continue;
    }

    const detail = (await resp.text()).slice(0, 500);

    // Chyba celé dávky: špatný klíč, neověřená doména, limit, výpadek.
    // Přerušit, zbytek vrátit bez započteného pokusu, nahlásit.
    if (CHYBA_DAVKY.has(resp.status)) {
      potiz = `Resend odmítl dávku (HTTP ${resp.status}): ${detail}`;
      await vratDoFronty(mail, potiz);
      continue;
    }

    // 422 je `validation_error`. U JEDNOHO řádku to znamená adresu, kterou
    // opakování nespraví, takže se tiše odloží. Kdyby ho ale vracel každý
    // řádek, není to adresami: typicky je špatně `EMAIL_FROM`, a zahodit
    // kvůli tomu celou frontu (a zapsat k tomu „Resend adresu odmítl") by
    // bylo horší než chyba, protože to ukazuje vinu na klienta.
    if (resp.status === 422) {
      if (preskoceno422 >= 2 && odeslano === 0) {
        potiz = `Resend odmítá dávku jako neplatnou, pravděpodobně EMAIL_FROM: ${detail}`;
        await vratDoFronty(mail, potiz);
        continue;
      }
      await dokonci(mail.id, {
        status: "skipped",
        last_error: `Resend adresu odmítl: ${detail}`,
      });
      preskoceno++;
      preskoceno422++;
      continue;
    }

    // Zbytek (typicky 4xx na konkrétním řádku): počítá se jako pokus.
    // `attempts` už zvýšilo převzetí, takže se tu jen rozhoduje, jestli se
    // řádek vrátí do fronty, nebo to vzdáme.
    await dokonci(mail.id, {
      status: mail.attempts >= MAX_POKUSU ? "failed" : "pending",
      claimed_at: null,
      last_error: detail,
    });
    selhalo++;
  }

  return json({
    rezim: nanecisto ? "nanecisto" : "ostry",
    odesilatel: from,
    prevzato: fronta.length,
    odeslano,
    preskoceno,
    selhalo,
    // Vrácené do fronty bez započteného pokusu (chyba dávky, ne řádku).
    vraceno,
    // Řádky, u kterých se nepovedlo zapsat výsledek. Nenulová hodnota znamená
    // riziko dvojího odeslání, protože úklid je za 10 minut vrátí do fronty.
    zapisSelhal,
    potiz,
  }, potiz === null && zapisSelhal === 0 ? 200 : 500);
});
