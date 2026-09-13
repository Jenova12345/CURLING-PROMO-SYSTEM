import { describe, expect, it, vi } from "vitest";
import { vyprazdniFrontu, TIMEOUT_MS } from "./fronta-emailu.mts";

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

  it("JÁDRO: mimo produkční kontext nevolá nic (netlify dev by jinak sáhl na produkci)", async () => {
    const { fn, volani } = spionFetch();
    for (const kontext of ["dev", "deploy-preview", "branch-deploy"]) {
      const v = await vyprazdniFrontu(
        { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co", CONTEXT: kontext },
        fn,
      );
      expect(v.odeslano, `kontext ${kontext} prošel`).toBe(false);
      expect(v.duvod).toContain(kontext);
    }
    expect(volani, "mimo produkci se volalo").toHaveLength(0);
  });

  // ROZLIŠUJÍCÍ PROTIPŘÍKLAD: bez něj by testu vyhověla i funkce, která
  // nevolá NIKDY — tedy naplánovaná úloha, co tiše nedělá nic.
  it("JÁDRO: v produkci s klíčem zavolá send-emails správným způsobem", async () => {
    const { fn, volani } = spionFetch();
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co", CONTEXT: "production" },
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

  it("URL s koncovým lomítkem nevyrobí dvojité", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co/", CONTEXT: "production" },
      fn,
    );
    expect(volani[0].url).toBe("https://x.supabase.co/functions/v1/send-emails");
  });

  it("klíč s koncovým novým řádkem se ořízne (jinak `fetch` spadne na ByteString)", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: `${KLIC}\n`, SUPABASE_URL: "https://x.supabase.co", CONTEXT: "production" },
      fn,
    );
    const h = volani[0].init.headers as Record<string, string>;
    expect(h.Authorization).toBe(`Bearer ${KLIC}`);
  });

  it("URL se bere z VITE_SUPABASE_URL, když SUPABASE_URL chybí", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, VITE_SUPABASE_URL: "https://z.supabase.co", CONTEXT: "production" },
      fn,
    );
    expect(volani[0].url).toBe("https://z.supabase.co/functions/v1/send-emails");
  });

  it("JÁDRO: neúspěch se hlásí jako neúspěch, ne jako tichý běh", async () => {
    const { fn } = spionFetch({ ok: false, status: 401, text: async () => "Frontu obsluhuje jen server." });
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co", CONTEXT: "production" },
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
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co", CONTEXT: "production" },
      fn,
    );
    expect(v.odeslano).toBe(false);
    expect(JSON.stringify(v), "klíč prosákl do výsledku, a tím do logu hostingu").not.toContain(KLIC);
  });

  it("odpověď se do logu ořezává (může nést adresy a texty zpráv)", async () => {
    const dlouhe = "x".repeat(5000);
    const { fn } = spionFetch({ text: async () => dlouhe });
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co", CONTEXT: "production" },
      fn,
    );
    expect(v.telo!.length).toBeLessThanOrEqual(300);
  });

  it("timeout je nastavený (bez něj by běh visel na nedostupné funkci)", async () => {
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co", CONTEXT: "production" },
      fn,
    );
    expect(volani[0].init.signal).toBeDefined();
    expect(TIMEOUT_MS).toBeGreaterThan(0);
  });
});
