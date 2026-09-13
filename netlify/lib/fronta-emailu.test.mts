import { describe, expect, it, vi } from "vitest";
import { vyprazdniFrontu, TIMEOUT_MS, DAVKA } from "./fronta-emailu.mts";

// =============================================================================
// TESTY: naplánované vyprazdňování fronty e-mailů zvenčí (Netlify)
// =============================================================================
// CO TENHLE SOUBOR HLÍDÁ: tohle je jediné místo v repu, kde z hostingu odchází
// SERVISNÍ KLÍČ. Nejcennější tvrzení nejsou o šťastné cestě, ale tři jiná:
//   * bez klíče se NEVOLÁ NIC (jinak by lokál a náhledy volaly produkci),
//   * mimo produkční kontext se NEVOLÁ NIC,
//   * klíč se nikdy neobjeví v tom, co funkce vrací (log hostingu).
// =============================================================================

const KLIC = "sb_secret_TESTOVACI_KLIC_NEPOUZIVAT";

/** fetch, který nic nevolá a jen zaznamená, s čím byl zavolán. */
function spionFetch(odpoved: Partial<Response> = {}) {
  const volani: { url: string; init: RequestInit }[] = [];
  const fn = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
    volani.push({ url: String(url), init: init ?? {} });
    return {
      ok: true,
      status: 200,
      text: async () => "{\"odeslano\":0}",
      ...odpoved,
    } as Response;
  });
  return { fn: fn as unknown as typeof fetch, volani };
}

describe("vyprazdniFrontu", () => {
  it("JÁDRO: bez servisního klíče nevolá vůbec nic", async () => {
    const { fn, volani } = spionFetch();
    const v = await vyprazdniFrontu({ SUPABASE_URL: "https://x.supabase.co" }, fn);

    expect(volani, "bez klíče se přesto někam volalo").toHaveLength(0);
    expect(v.odeslano).toBe(false);
    expect(v.duvod).toContain("SUPABASE_SERVICE_ROLE_KEY");
  });

  it("JÁDRO: bez URL nevolá vůbec nic", async () => {
    const { fn, volani } = spionFetch();
    const v = await vyprazdniFrontu({ SUPABASE_SERVICE_ROLE_KEY: KLIC }, fn);

    expect(volani).toHaveLength(0);
    expect(v.odeslano).toBe(false);
    expect(v.duvod).toContain("SUPABASE_URL");
  });

  // ⚠️ SCÉNÁŘ NA `CONTEXT` TU BYL A JE PRYČ. Tvrdil, že mimo produkci se
  // nevolá nic, ale `CONTEXT` ve funkcích Netlify za běhu VŮBEC NEEXISTUJE
  // (dokumentace: dostupné jsou jen `URL`, `SITE_NAME`, `SITE_ID`). Test si ho
  // dosazoval ručně, takže měřil vlastní výmysl — zelený a bezcenný. Brána
  // code review 13. 9. 2026.

  // ROZLIŠUJÍCÍ PROTIPŘÍKLAD: bez něj by testu vyhověla i funkce, která
  // nevolá NIKDY — tedy naplánovaná úloha, co tiše nedělá nic.
  it("JÁDRO: v produkci s klíčem zavolá send-emails správným způsobem", async () => {
    const { fn, volani } = spionFetch();
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );

    expect(volani).toHaveLength(1);
    expect(volani[0].url).toBe("https://x.supabase.co/functions/v1/send-emails");
    expect(volani[0].init.method).toBe("POST");
    const h = volani[0].init.headers as Record<string, string>;
    // Bez `Authorization` požadavek k funkci vůbec nedojde: platformní brána
    // Supabase ho odmítne dřív (401 UNAUTHORIZED_NO_AUTH_HEADER).
    expect(h.Authorization).toBe(`Bearer ${KLIC}`);
    expect(h.apikey).toBe(KLIC);
    expect(v.odeslano).toBe(true);
  });

  // ⚠️ TĚLO POŽADAVKU NIKDO NEHLÍDAL. Brána code review 13. 9. 2026 změřila,
  // že záměna `{"limit":20}` za `{"dryRun":true}` nechá všechna ostatní
  // tvrzení zelená — a systém by přitom neodeslal nikdy nic a hlásil
  // „Fronta zpracována."
  it("JÁDRO: požadavek si říká o ODESLÁNÍ dávky, ne o náhled", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    const telo = JSON.parse(String(volani[0].init.body));
    expect(telo.limit, "dávka se neposílá, send-emails si vezme svých 50").toBe(DAVKA);
    expect(telo.dryRun, "posílá se náhled místo odeslání — nic by neodešlo").toBeUndefined();
    expect(telo.mock, "posílá se režim nanečisto — fronta by se zahodila").toBeUndefined();
  });

  // Naplánovaná funkce Netlify má tvrdý strop 30 s a `send-emails` čeká mezi
  // voláními Resendu 550 ms. Dávka se do okna musí vejít i s naším timeoutem,
  // jinak platforma běh utne uprostřed odesílání.
  it("JÁDRO: dávka i timeout se vejdou do 30sekundového okna Netlify", () => {
    const STROP_NETLIFY_MS = 30_000;
    const PAUZA_MS = 550; // musí odpovídat send-emails/index.ts

    expect(TIMEOUT_MS, "vlastní timeout je nad platformním stropem, takže nikdy nenastane")
      .toBeLessThan(STROP_NETLIFY_MS);
    expect(DAVKA * PAUZA_MS, "samotné pauzy mezi e-maily přetečou náš timeout")
      .toBeLessThan(TIMEOUT_MS);
  });

  it("URL s koncovým lomítkem nevyrobí dvojité", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co/" },
      fn,
    );
    expect(volani[0].url).toBe("https://x.supabase.co/functions/v1/send-emails");
  });

  it("klíč s koncovým novým řádkem se ořízne (jinak `fetch` spadne na ByteString)", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: `${KLIC}\n`, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    const h = volani[0].init.headers as Record<string, string>;
    expect(h.Authorization).toBe(`Bearer ${KLIC}`);
  });

  it("URL se bere z VITE_SUPABASE_URL, když SUPABASE_URL chybí", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, VITE_SUPABASE_URL: "https://z.supabase.co" },
      fn,
    );
    expect(volani[0].url).toBe("https://z.supabase.co/functions/v1/send-emails");
  });

  it("JÁDRO: neúspěch se hlásí jako neúspěch, ne jako tichý běh", async () => {
    const { fn } = spionFetch({ ok: false, status: 401, text: async () => "Frontu obsluhuje jen server." });
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.odeslano).toBe(false);
    expect(v.duvod).toContain("401");
  });

  it("JÁDRO: klíč se nikdy nedostane do toho, co jde do logu", async () => {
    // Padající `fetch` je ta nejnebezpečnější cesta: chyba o špatné hlavičce
    // nese kus jejího obsahu, tedy kus klíče.
    const fn = (async () => {
      throw new TypeError(`Failed to construct 'Request': ${KLIC} is not a valid ByteString`);
    }) as unknown as typeof fetch;

    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.odeslano).toBe(false);
    expect(JSON.stringify(v), "klíč prosákl do výsledku, a tím do logu hostingu").not.toContain(KLIC);
  });

  it("odpověď se do logu ořezává (může nést adresy a texty zpráv)", async () => {
    const dlouhe = "x".repeat(5000);
    const { fn } = spionFetch({ text: async () => dlouhe });
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.telo!.length).toBeLessThanOrEqual(300);
  });

  // ⚠️ Dřív tu stálo jen „signal je definovaný a TIMEOUT_MS > 0". To projde
  // i pro `AbortSignal.timeout(1)`, tedy pro funkci, která se utne dřív, než
  // stihne cokoli. Brána code review 13. 9. 2026. Měří se proto SKUTEČNÉ
  // přerušení: `fetch`, který nikdy neodpoví, musí na timeoutu spadnout.
  it("JÁDRO: timeout požadavek opravdu utne, ne jen visí", async () => {
    const nikdyNeodpovi = ((_url: string, init?: RequestInit) =>
      new Promise<Response>((_vyres, zamitni) => {
        init?.signal?.addEventListener("abort", () => zamitni(new DOMException("Aborted", "TimeoutError")));
      })) as unknown as typeof fetch;

    const zacatek = Date.now();
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      nikdyNeodpovi,
      30, // krátký timeout jen pro test; ostrá hodnota je TIMEOUT_MS
    );
    const trvalo = Date.now() - zacatek;

    expect(v.odeslano, "nedostupná funkce se tváří jako úspěch").toBe(false);
    expect(trvalo, "požadavek nevisel na timeoutu, skončil jinak").toBeGreaterThanOrEqual(25);
    expect(trvalo, "timeout se neuplatnil, běželo to dál").toBeLessThan(5_000);
    expect(JSON.stringify(v), "klíč prosákl do výsledku").not.toContain(KLIC);
  });
});
