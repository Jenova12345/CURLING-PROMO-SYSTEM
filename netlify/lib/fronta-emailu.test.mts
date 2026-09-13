import { describe, expect, it, vi } from "vitest";
import { vyprazdniFrontu, TIMEOUT_MS, DAVKA } from "./fronta-emailu.mts";

// =============================================================================
// TESTY: naplánované vyprazdňování fronty e-mailů zvenčí (Netlify)
// =============================================================================
// CO TENHLE SOUBOR HLÍDÁ: tohle je jediné místo v repu, kde z hostingu odchází
// SERVISNÍ KLÍČ. Nejcennější tvrzení nejsou o šťastné cestě, ale tři jiná:
//   * bez klíče se NEVOLÁ NIC (jinak by lokál a náhledy volaly produkci),
//   * klíč se nikdy neobjeví v tom, co funkce vrací (log hostingu),
//   * ÚSPĚCH SE POZNÁ Z TĚLA, NE ZE STAVOVÉHO KÓDU — `send-emails` vrací 200
//     i když neodešlo nic (chybí `RESEND_API_KEY` → režim náhledu) a i když
//     selhala všechna jednotlivá odeslání (`selhalo: 20`).
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
      // Přesně to, co vrací `send-emails` po ostrém běhu nad prázdnou frontou.
      // Ne náhodné JSON: kdyby tu chyběl `rezim`, braly by scénáře níž úspěch
      // z něčeho, co produkce nikdy nevrátí.
      text: async () => '{"rezim":"ostry","odeslano":0,"selhalo":0,"zapisSelhal":0}',
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
  it("JÁDRO: `Content-Type` je nosná hlavička, bez ní se dávka zahodí", async () => {
    // `send-emails` čte tělo JEN když hlavička sedí:
    //     if (req.headers.get("content-type")?.includes("application/json"))
    // Bez ní se `limit` tiše zahodí, funkce si vezme svých BATCH = 50
    // a 49 × 550 ms = 26,9 s přeteče náš timeout i platformní strop.
    // Hlídat samotné `body` tedy nestačí. Našla brána code review 13. 9. 2026.
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    const h = volani[0].init.headers as Record<string, string>;
    expect(h["Content-Type"], "bez téhle hlavičky send-emails `limit` ignoruje")
      .toBe("application/json");
  });

  it("JÁDRO: dávka i timeout se vejdou do 30sekundového okna Netlify", () => {
    const STROP_NETLIFY_MS = 30_000;
    const PAUZA_MS = 550; // musí odpovídat send-emails/index.ts

    expect(TIMEOUT_MS, "vlastní timeout je nad platformním stropem, takže nikdy nenastane")
      .toBeLessThan(STROP_NETLIFY_MS);
    expect(DAVKA * PAUZA_MS, "samotné pauzy mezi e-maily přetečou náš timeout")
      .toBeLessThan(TIMEOUT_MS);
  });

  it("JÁDRO: ostrý běh se opravdu utne na TIMEOUT_MS, ne na jiné hodnotě", async () => {
    // Scénář „timeout utne" níž si hodnotu vstřikuje parametrem a scénář
    // s aritmetikou čte jen konstantu — mezi nimi propadne to hlavní:
    // že se TIMEOUT_MS doopravdy použije, když parametr nikdo nepředá.
    // Zahardkódování 60 s zpátky do těla funkce by oběma prošlo.
    // Našla brána code review 13. 9. 2026.
    const spion = vi.spyOn(AbortSignal, "timeout");
    try {
      const { fn } = spionFetch();
      await vyprazdniFrontu(
        { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
        fn,
      );
      expect(spion, "timeout se vůbec nenastavil").toHaveBeenCalledTimes(1);
      expect(spion.mock.calls[0][0], "volání jede na jiné hodnotě než TIMEOUT_MS")
        .toBe(TIMEOUT_MS);
    } finally {
      spion.mockRestore();
    }
  });

  it("SUPABASE_URL má přednost před VITE_SUPABASE_URL", async () => {
    // Bez tohohle by testům vyhověla i záměna pořadí: `VITE_SUPABASE_URL`
    // je proměnná BUILDU a na produkční Netlify může mířit jinam než ta,
    // kterou pro plánovač nastavuje správce.
    const { fn, volani } = spionFetch();
    await vyprazdniFrontu(
      {
        SUPABASE_SERVICE_ROLE_KEY: KLIC,
        SUPABASE_URL: "https://spravna.supabase.co",
        VITE_SUPABASE_URL: "https://z-buildu.supabase.co",
      },
      fn,
    );
    expect(volani[0].url).toBe("https://spravna.supabase.co/functions/v1/send-emails");
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
  // ===========================================================================
  // ÚSPĚCH SE POZNÁ Z TĚLA, NE ZE STAVOVÉHO KÓDU
  // ===========================================================================
  // Bezpečnostní brána 13. 9. 2026: `send-emails` vrací HTTP 200 i na dvou
  // cestách, kde neodejde nic. Kdyby se tu soudilo podle `odpoved.ok`, tichá
  // porucha by v Netlify svítila zeleně — tedy přesně to, čemu měl návratový
  // stav zabránit.

  /** Odpověď `send-emails` jako text, ať scénáře níž nejsou samé uvozovky. */
  function telo(zprava: Record<string, unknown>) {
    return { text: async () => JSON.stringify(zprava) };
  }

  it("JÁDRO: režim náhledu (chybí RESEND_API_KEY) je NEÚSPĚCH, i když vrátí 200", async () => {
    const { fn } = spionFetch(telo({ rezim: "nahled", duvod: "RESEND_API_KEY neni nastaveny", ceka: 12 }));
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );

    expect(v.stav, "scénář nemá smysl, pokud netestuje právě dvoustovku").toBe(200);
    expect(v.odeslano, "zrotovaný klíč prošel jako úspěšný běh").toBe(false);
    expect(v.duvod).toContain("RESEND_API_KEY");
  });

  it("JÁDRO: selhalá odeslání jsou NEÚSPĚCH, i když vrátí 200", async () => {
    const { fn } = spionFetch(telo({ rezim: "ostry", odeslano: 0, selhalo: 20, zapisSelhal: 0 }));
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );

    expect(v.stav).toBe(200);
    expect(v.odeslano, "celá dávka selhala a běh se tvářil zeleně").toBe(false);
    expect(v.duvod).toContain("20");
  });

  it("JÁDRO: nezapsaný výsledek je NEÚSPĚCH (hrozí dvojí odeslání)", async () => {
    // `zapisSelhal` je horší než `selhalo`: e-mail odešel, ale fronta o tom
    // neví, takže ho úklid za 10 minut pošle znovu. Musí to být vidět.
    const { fn } = spionFetch(telo({ rezim: "ostry", odeslano: 5, selhalo: 0, zapisSelhal: 1 }));
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.odeslano).toBe(false);
  });

  it("režim nanečisto je taky NEÚSPĚCH (fronta se zahodí, nic neodejde)", async () => {
    const { fn } = spionFetch(telo({ rezim: "nanecisto", odeslano: 0, preskoceno: 20 }));
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.odeslano).toBe(false);
    expect(v.duvod).toContain("nanecisto");
  });

  it("nerozpoznaná odpověď je NEÚSPĚCH, ne pád", async () => {
    const { fn } = spionFetch({ text: async () => "<html>502 Bad Gateway</html>" });
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.odeslano).toBe(false);
    expect(v.duvod).toContain("nerozpoznaný");
  });

  // ROZLIŠUJÍCÍ PROTIPŘÍKLAD ke scénářům výš: bez něj by testům vyhověla
  // i funkce, která hlásí neúspěch VŽDYCKY.
  it("JÁDRO: povedený ostrý běh je úspěch a nese počet odeslaných", async () => {
    const { fn } = spionFetch(telo({ rezim: "ostry", odeslano: 7, selhalo: 0, zapisSelhal: 0 }));
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.odeslano).toBe(true);
    expect(v.duvod, "log neřekne, kolik jich odešlo").toContain("7");
  });

  it("rozhoduje CELÉ tělo, ne jen ořezaný začátek pro log", async () => {
    // Kdyby se parsoval `telo` (oříznutý na 300 znaků), JSON by tu nedal
    // parsovat a povedený běh by se hlásil jako porucha.
    const { fn } = spionFetch(telo({
      rezim: "ostry",
      vypln: "y".repeat(400),
      odeslano: 3,
      selhalo: 0,
      zapisSelhal: 0,
    }));
    const v = await vyprazdniFrontu(
      { SUPABASE_SERVICE_ROLE_KEY: KLIC, SUPABASE_URL: "https://x.supabase.co" },
      fn,
    );
    expect(v.odeslano, "rozhodovalo se z oříznutého těla").toBe(true);
    expect(v.telo!.length, "do logu šlo celé tělo").toBeLessThanOrEqual(300);
  });
});
