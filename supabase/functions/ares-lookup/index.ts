// Supabase Edge Function: ares-lookup
// Načte ekonomický subjekt z ARES podle IČO a vrátí { name, address, dic }.
// Serverově (bez CORS/klíče vůči ARES). IČO se validuje na 8 číslic → žádné SSRF.
// Volá se z frontendu: supabase.functions.invoke('ares-lookup', { body: { ico } })

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { ico } = await req.json().catch(() => ({ ico: "" }));
    const clean = String(ico ?? "").trim();

    // ARES používá 8místné IČO (validace zároveň brání SSRF — do URL jde jen 8 číslic).
    // Chyby vracíme jako HTTP 200 s {error}, aby je frontend (supabase.functions.invoke)
    // spolehlivě přečetl z `data` (non-2xx by se schovalo do generického `error`).
    if (!/^\d{8}$/.test(clean)) {
      return json({ error: "Neplatné IČO — zadejte 8 číslic." });
    }

    const url = `https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/ekonomicke-subjekty/${clean}`;
    const resp = await fetch(url, { headers: { Accept: "application/json" } });

    if (resp.status === 404) return json({ error: "Firma s tímto IČO nebyla v ARESu nalezena." });
    if (!resp.ok) return json({ error: "ARES je momentálně nedostupný, zkuste to později." });

    const data = await resp.json();
    return json({
      name: data?.obchodniJmeno ?? "",
      address: data?.sidlo?.textovaAdresa ?? "",
      dic: data?.dic ?? "",
      ico: clean,
    });
  } catch (_e) {
    return json({ error: "Načtení z ARESu selhalo." });
  }
});
