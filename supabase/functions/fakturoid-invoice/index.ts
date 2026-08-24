// Etapa 3 / PR 4 — odeslání podkladů do Fakturoidu (varianta S2).
//
// ROZDĚLENÍ ZODPOVĚDNOSTI (stejné jako u `invoice-pdf`)
//   `@/billing/mapping`   — co se fakturuje (čisté, testované z Node)
//   `@/billing/pipeline`  — zámky a pořadí kroků (čisté)
//   `@/billing/providers` — překlad do Fakturoidu (čisté, injektovaný fetch)
//   tenhle soubor         — HTTP, tajemství, Storage. Co nejmíň rozhodování.
//
// PROČ TU NENÍ ŽÁDNÁ LOGIKA IDEMPOTENCE: je celá v `pipeline.ts` a v migraci
// `20260824120000_fakturoid_vazba.sql`. Za tři kola bran se v aplikační vrstvě
// našly čtyři různé cesty k duplicitní faktuře — pátou tady nezaložíme tím, že
// si sem někdo přepíše „jen malý" kousek rozhodování.
//
// TAJEMSTVÍ: `FAKTUROID_CLIENT_SECRET` se čte z prostředí Edge funkce
// (`supabase secrets set`), NIKDY z `VITE_*`. Do odpovědi klientovi se posílá
// jen `uzivatelskaZprava()` — interní hlášky téhle vrstvy nesou sazby, částky
// a jména proměnných, které podle CLAUDE.md neadmin vidět nesmí.

import { createClient } from 'jsr:@supabase/supabase-js@2';

import { nactiConfig } from '@/billing/providers/fakturoid/config.ts';
import { FakturoidProvider } from '@/billing/providers/fakturoid/index.ts';
import { SupabaseStore, type RpcKlient } from '@/billing/supabaseStore.ts';
import { vystavDoklad } from '@/billing/pipeline.ts';
import {
  mapujKlubMesicne, mapujKomercniAkci,
  type BillableReservation, type SubjectForBilling,
} from '@/billing/mapping.ts';
import { proUzivatele } from '@/billing/errors.ts';

const BUCKET = 'invoices';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

const sha256hex = async (data: Uint8Array): Promise<string> => {
  // Kopie do vlastního bufferu: `crypto.subtle` sdílené buffery nebere.
  const kopie = new Uint8Array(data.byteLength);
  kopie.set(data);
  const h = await crypto.subtle.digest('SHA-256', kopie.buffer);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('');
};

interface Pozadavek {
  druh: 'klub' | 'akce';
  subjectId?: string;
  obdobiOd?: string;
  obdobiDo?: string;
  eventId?: string;
}

// REŽIM SE Z TĚLA POŽADAVKU PŘEBÍT NEDÁ. Bylo by to lákavé („pošli tenhle jeden
// rovnou"), ale rozjezdový režim `koncept` má smysl jen tehdy, když ho nejde
// obejít jedním polem v JSONu — a rozeslaná faktura se nedá vzít zpět.
// Jediný zdroj je `FAKTUROID_MODE` v prostředí funkce.

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const url = Deno.env.get('SUPABASE_URL');
    const servisni = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const anon = Deno.env.get('SUPABASE_ANON_KEY');
    if (!url || !servisni || !anon) return json({ error: 'Chybí konfigurace prostředí.' }, 500);

    // ---- KDO SE PTÁ ------------------------------------------------------
    //
    // Dvě oddělená spojení, přesně jako v `invoice-zip`. Nesloučit je:
    // předat token volajícího do klienta se SERVISNÍM klíčem je past —
    // když hlavička chybí nebo je prázdná, supabase-js spadne zpět na servisní
    // klíč a požadavek projde s plnými právy BEZ volajícího. `verify_jwt` by
    // to sice zachytil, ale spoléhat na nastavení mimo repo se u fakturace
    // nevyplácí: tahle funkce zakládá doklady v OSTRÉ číselné řadě.
    const autorizace = req.headers.get('Authorization') ?? '';
    if (!autorizace.startsWith('Bearer ')) return json({ error: 'Chybí přihlášení.' }, 401);

    const jakoUzivatel = createClient(url, anon, {
      global: { headers: { Authorization: autorizace } },
      auth: { persistSession: false },
    });
    const { data: uzivatel } = await jakoUzivatel.auth.getUser();
    const { data: jeAdmin, error: chybaRole } = await jakoUzivatel.rpc('has_role', {
      _user_id: uzivatel.user?.id, _role: 'admin',
    });
    if (chybaRole) return json({ error: 'Nepodařilo se ověřit oprávnění.' }, 500);
    if (!jeAdmin) return json({ error: 'Doklady do Fakturoidu posílá jen správce haly.' }, 403);

    const config = nactiConfig(Deno.env.toObject());

    // Práci dělá servisní spojení — RPC si přesto práva ověřují znovu
    // (`fakturoid_smi_volat`). Dvě nezávislé kontroly, ne jedna.
    const db = createClient(url, servisni, { auth: { persistSession: false } });

    const telo = await req.json().catch(() => ({})) as Pozadavek;
    // `as unknown as RpcKlient`: `SupabaseStore` potřebuje jen `.rpc`, ale
    // generiky `createClient` bez typů schématu se s tím úzkým rozhraním
    // strukturálně neshodnou. Zúžení je tu vědomé a jednosměrné.
    const store = new SupabaseStore(db as unknown as RpcKlient);
    const provider = new FakturoidProvider({ config, fetch: globalThis.fetch as never });

    // ---- Podklady --------------------------------------------------------
    let rezervace: BillableReservation[];
    let subjectId: string;
    let draft;

    if (telo.druh === 'akce') {
      if (!telo.eventId) return json({ error: 'Chybí eventId.' }, 400);

      const { data, error } = await db.rpc('fakturoid_podklady_akce', { _event: telo.eventId });
      if (error) throw new Error(`fakturoid_podklady_akce: ${error.message}`);
      rezervace = (data ?? []) as BillableReservation[];
      if (rezervace.length === 0) return json({ stav: 'prazdne' });

      // Akce může teoreticky nést rezervace víc subjektů; doklad zní na jeden.
      subjectId = (data as Array<{ subject_id: string }>)[0].subject_id;
      const cizi = (data as Array<{ subject_id: string }>).some((r) => r.subject_id !== subjectId);
      if (cizi) {
        return json({
          error: 'Akce má rezervace víc odběratelů — doklad na ni nejde vystavit automaticky.',
        }, 409);
      }

      const subjekt = await nactiSubjekt(db as unknown as RpcKlient, subjectId);
      draft = mapujKomercniAkci({
        eventId: telo.eventId, subjekt, rezervace,
        jePlatceDph: config.jePlatceDph, dueInDays: config.dueDays,
      });
    } else {
      if (!telo.subjectId || !telo.obdobiOd || !telo.obdobiDo) {
        return json({ error: 'Chybí subjectId, obdobiOd nebo obdobiDo.' }, 400);
      }
      subjectId = telo.subjectId;

      const { data, error } = await db.rpc('fakturoid_podklady_klub', {
        _subject: subjectId, _od: telo.obdobiOd, _do: telo.obdobiDo,
      });
      if (error) throw new Error(`fakturoid_podklady_klub: ${error.message}`);
      rezervace = (data ?? []) as BillableReservation[];
      if (rezervace.length === 0) return json({ stav: 'prazdne' });

      const subjekt = await nactiSubjekt(db as unknown as RpcKlient, subjectId);
      draft = mapujKlubMesicne({
        subjekt, obdobiOd: telo.obdobiOd, obdobiDo: telo.obdobiDo, rezervace,
        jePlatceDph: config.jePlatceDph, dueInDays: config.dueDays,
      });
    }

    // ---- Vystavení -------------------------------------------------------
    const vysledek = await vystavDoklad({
      draft,
      provider,
      store,
      rezim: config.rezim,
      pdfUloziste: {
        // Jen nahraje a spočítá otisk; zápis do evidence dělá pipeline jedním
        // voláním `zapisPdf`. Dřív se sem psalo i do databáze a druhý zápis
        // z pipeline pak otisk přepsal na NULL.
        uloz: async (klic, pdf) => {
          const cesta = `fakturoid/${klic}.pdf`;
          const { error } = await db.storage.from(BUCKET).upload(cesta, pdf, {
            contentType: 'application/pdf', upsert: true,
          });
          if (error) throw new Error(`Uložení PDF selhalo: ${error.message}`);
          return { cesta, sha256: await sha256hex(pdf) };
        },
      },
    });

    // ---- Odpověď ---------------------------------------------------------
    //
    // Skládá se VÝSLOVNĚ, pole po poli. Vrátit `vysledek` celý by poslalo ven
    // i `result.providerLines[].unitPrice`, tedy SAZBU — a interní hlášky
    // z `varovani[].interni`, které nesou text Postgresu a Storage.
    //
    // Endpoint je sice admin-only (výš je 401/403), takže částky tu vadit
    // nemohou — ale cizí chybové texty v prohlížeči ano, a „vrať to celé"
    // je přesně ten tvar, který přežije, až se endpoint jednou otevře víc lidem.
    if (vysledek.stav === 'vystaveno' || vysledek.stav === 'existoval') {
      for (const v of vysledek.varovani ?? []) {
        if (v.interni) console.error('[fakturoid-invoice] varování', v.kod, v.interni);
      }
      const varovani = (vysledek.varovani ?? []).map((v) => ({ kod: v.kod, zprava: v.zprava }));

      return json({
        stav: vysledek.stav,
        cislo: vysledek.link.result.number,
        variabilniSymbol: vysledek.link.result.variableSymbol,
        publicUrl: vysledek.link.result.publicUrl,
        pdfPath: vysledek.link.pdfPath,
        odeslano: Boolean(vysledek.link.odeslanoAt),
        varovani,
      });
    }
    if (vysledek.stav === 'nesedi') {
      return json({
        stav: 'nesedi',
        cislo: vysledek.result.number,
        // `duvod` nese částky a počty řádků — pro admina je to ta podstatná
        // informace. `result` jako celek ven NEJDE.
        duvod: vysledek.duvod,
      }, 409);
    }
    return json(vysledek.stav === 'preskoceno'
      ? { stav: 'preskoceno', duvod: vysledek.duvod }
      : { stav: vysledek.stav });

  } catch (chyba) {
    const { kod, zprava, interni } = proUzivatele(chyba);
    // Interní znění JEN do logu funkce. Ven jde pevný text bez sazeb a částek.
    console.error('[fakturoid-invoice]', kod, interni);
    return json({ error: zprava, kod }, 500);
  }
});

// Bere `RpcKlient`, ne `SupabaseClient`: potřebuje jen `.rpc` a generiky
// klienta se v Denu neshodnou s tím, co vrací `createClient` bez typů schématu.
const nactiSubjekt = async (db: RpcKlient, id: string): Promise<SubjectForBilling> => {
  const { data, error } = await db.rpc('fakturoid_subjekt', { _id: id });
  if (error) throw new Error(`fakturoid_subjekt: ${error.message}`);
  const s = (Array.isArray(data) ? data : [])[0] as SubjectForBilling | undefined;
  if (!s) throw new Error(`Subjekt ${id} nenalezen.`);
  return s;
};
