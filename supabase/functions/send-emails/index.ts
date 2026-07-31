// Supabase Edge Function: send-emails
// ---------------------------------------------------------------------------
// Odešle e-maily z fronty public.email_outbox (stav 'pending').
//
// ⚠️ ZATÍM NEAKTIVNÍ — vědomé rozhodnutí (viz zadání klienta):
//   1) Fronta se ani neplní, dokud admin nezapne settings.email_notifications_enabled.
//   2) Tahle funkce bez proměnné RESEND_API_KEY nic neodešle a jen to oznámí.
// Až bude vybraný poskytovatel (Resend / SMTP) a doména, stačí:
//   supabase secrets set RESEND_API_KEY=… EMAIL_FROM="Curling Promo Ostrava <rezervace@…>"
//   supabase functions deploy send-emails
// a naplánovat pravidelné volání (pg_cron / Supabase Scheduler, např. každých 5 minut).
//
// Volá se servisním klíčem (service_role) — RLS na email_outbox pouští jen admina.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const apiKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("EMAIL_FROM") ?? "Curling Promo Ostrava <onboarding@resend.dev>";

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data: queue, error } = await supabase
    .from("email_outbox")
    .select("id, email, subject, body, attempts")
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(BATCH);

  if (error) return json({ error: "Frontu se nepodařilo načíst.", detail: error.message }, 500);
  if (!queue?.length) return json({ sent: 0, skipped: 0, note: "Fronta je prázdná." });

  // Bez klíče nic neodesíláme — ale ani frontu nezahazujeme, jen to řekneme nahlas.
  if (!apiKey) {
    return json({
      sent: 0,
      pending: queue.length,
      note: "RESEND_API_KEY není nastavený — odesílání e-mailů je vypnuté. Fronta zůstává beze změny.",
    });
  }

  let sent = 0;
  let failed = 0;

  for (const mail of queue) {
    try {
      const resp = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from,
          to: [mail.email],
          subject: mail.subject,
          text: mail.body,
        }),
      });

      if (resp.ok) {
        await supabase.from("email_outbox")
          .update({ status: "sent", sent_at: new Date().toISOString(), attempts: mail.attempts + 1 })
          .eq("id", mail.id);
        sent++;
      } else {
        const detail = await resp.text();
        const attempts = mail.attempts + 1;
        await supabase.from("email_outbox")
          .update({
            // po 5 pokusech to vzdáme, ať fronta nebobtná donekonečna
            status: attempts >= 5 ? "failed" : "pending",
            attempts,
            last_error: detail.slice(0, 500),
          })
          .eq("id", mail.id);
        failed++;
      }
    } catch (e) {
      const attempts = mail.attempts + 1;
      await supabase.from("email_outbox")
        .update({
          status: attempts >= 5 ? "failed" : "pending",
          attempts,
          last_error: String(e).slice(0, 500),
        })
        .eq("id", mail.id);
      failed++;
    }
  }

  return json({ sent, failed });
});
