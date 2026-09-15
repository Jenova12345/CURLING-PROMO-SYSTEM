// C5 — podepsaná URL ke stažení dokladu.
//
// Bucket `invoices` je privátní (R7): doklad nese jméno odběratele, adresu
// a částku. Klient si proto odkaz vyrobit nemůže — vydává ho tahle funkce,
// a jen tomu, kdo je opravdu správce haly.
//
// PROČ NE PŘÍMO Z PROHLÍŽEČE: dát `authenticated` právo číst bucket by
// znamenalo, že si každý přihlášený stáhne libovolný doklad, když uhodne cestu.
// Kontrola role musí proběhnout na serveru, na každý požadavek.
//
// HEZKÝ NÁZEV AŽ TADY: v úložišti je klíč `2026/20260001/v1.pdf` — ASCII, bez
// identity. Jméno souboru `0001_ck_ostravske_kameny_140826.pdf` se nastavuje
// parametrem `download` podepsané URL. Tím zmizí únik identity přes cestu
// i diakritika v klíči naráz.
//
// DVA ZDROJE DOKLADŮ, JEDNA DVEŘE (16. 9. 2026). Kromě interního enginu
// (`public.invoices`, dnes zamčený) ukládá svou kopii PDF i fakturoidí cesta —
// do TÉHOŽ bucketu, pod `fakturoid/<klíč>.pdf` (viz `fakturoid-invoice`,
// `pdfUloziste.uloz`). Bucket `invoices` má jedinou politiku,
// `invoices_bucket_service` pro `service_role` (migrace 20260818090000), takže
// podepsat URL může zase jen server — a druhá funkce, která by dělala totéž
// o řádek vedle, by tu jednu auditovatelnou cestu rozdvojila. Volá se to tedy
// buď s `invoice_id` (interní doklad), nebo s `fakturoid_invoice_id`.
//
// Rozhodně NE tak, že se bucket otevře `authenticated` politikou: kontrola
// role musí zůstat na serveru a na každý požadavek, viz odstavec výš. Bylo to
// zvažováno a zamítnuto — byl by to obchvat vlastního návrhu.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { nazevKeStazeni } from '../_shared/dokladDto.ts';

/** Krátká platnost: odkaz má posloužit ke stažení, ne kolovat e-mailem. */
const PLATNOST_S = 300;

// BEZ TOHOHLE SE FUNKCE Z PROHLÍŽEČE NEDOVOLÁ (nález bezpečnostní brány
// 16. 9. 2026 🔴). `supabase.functions.invoke` posílá `authorization`, `apikey`
// i `content-type: application/json` — non-safelisted trojici, na kterou
// prohlížeč vyšle preflight `OPTIONS`. Ten sem dorazí BEZ hlavičky
// `Authorization`, spadl by na 401 bez CORS hlaviček a prohlížeč by celý
// požadavek zahodil dřív, než by odešel. Admin by viděl jen obecné
// „Odkaz ke stažení se nepodařilo získat" a hledal chybu ve svém dokladu.
//
// Proč to nikdy nevadilo: jediným volajícím byla stránka Faktury nad tabulkou
// `invoices`, která má nula řádků — ta cesta se z prohlížeče nejspíš nikdy
// neprošla. Sesterské funkce (`fakturoid-invoice`, `ares-lookup`,
// `send-emails`) tohle mají; `invoice-pdf-url` a `invoice-zip` ne.
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const url = Deno.env.get('SUPABASE_URL');
  const servisni = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !servisni || !anon) {
    return odpoved({ error: 'Chybí konfigurace prostředí.' }, 500);
  }

  const autorizace = req.headers.get('Authorization') ?? '';
  if (!autorizace.startsWith('Bearer ')) {
    return odpoved({ error: 'Chybí přihlášení.' }, 401);
  }

  let invoiceId: string | undefined;
  let fakturoidId: string | undefined;
  try {
    const telo = await req.json();
    invoiceId = telo?.invoice_id;
    fakturoidId = telo?.fakturoid_invoice_id;
  } catch {
    return odpoved({ error: 'Čekal jsem JSON s `invoice_id` nebo `fakturoid_invoice_id`.' }, 400);
  }
  if (!invoiceId && !fakturoidId) {
    return odpoved({ error: 'Chybí `invoice_id` i `fakturoid_invoice_id`.' }, 400);
  }
  // Obojí naráz je programátorská chyba, ne volba — odmítnout ji je levnější
  // než tiše vybrat jedno a vydat odkaz na doklad, o který volající nežádal.
  if (invoiceId && fakturoidId) {
    return odpoved({ error: 'Pošli buď `invoice_id`, nebo `fakturoid_invoice_id`, ne obojí.' }, 400);
  }

  // KDO SE PTÁ. Klient se vytvoří s tokenem volajícího, takže platí JEHO RLS —
  // `has_role` se počítá z jeho `auth.uid()`, ne z toho, co pošle v těle
  // požadavku. Podvrhnout cizí identitu tudy nejde.
  const jakoUzivatel = createClient(url, anon, {
    global: { headers: { Authorization: autorizace } },
    auth: { persistSession: false },
  });

  const { data: jeAdmin, error: chybaRole } = await jakoUzivatel.rpc('has_role', {
    _user_id: (await jakoUzivatel.auth.getUser()).data.user?.id, _role: 'admin',
  });
  if (chybaRole) return odpoved({ error: chybaRole.message }, 500);
  if (!jeAdmin) return odpoved({ error: 'Doklady stahuje jen správce haly.' }, 403);

  // Až teď servisním klíčem: čtení bucketu a podpis odkazu.
  const server = createClient(url, servisni, { auth: { persistSession: false } });

  // NAŠE KOPIE DOKLADU VYSTAVENÉHO FAKTUROIDEM.
  //
  // METADATA ČTE KLIENT VOLAJÍCÍHO, NE SERVISNÍ — a není to elegance, je to
  // jediná varianta, která vůbec funguje. `service_role` NEMÁ SELECT ani na
  // `fakturoid_invoices`, ani na pohled nad ní: migrace 20260824120000 dělá
  // `REVOKE ALL … FROM anon, authenticated, public, service_role` a grantuje
  // zpátky jen `authenticated`. Ověřeno na produkci 16. 9. 2026
  // (`has_table_privilege('service_role','public.fakturoid_invoices','SELECT')`
  // = false). Servisním klientem by tahle větev vracela 500 „permission denied"
  // pokaždé. Zbytek fakturoidí vrstvy se tabulky nikdy přímo nedotýká — chodí
  // přes RPC grantovaná `service_role` — takže se na to dosud nepřišlo.
  //
  // Vedle toho, že to funguje, je to i lepší: pohled `fakturoid_invoices_list`
  // má `security_invoker = on`, takže platí RLS volajícího (admin, ověřený
  // o pár řádků výš), a SÁM filtruje `deleted_at IS NULL AND uvolneno_at IS NULL
  // AND provider_invoice_id IS NOT NULL`. Ty podmínky se tu tedy neopisují
  // ručně a nemůžou se s pohledem rozejít. Servisní klíč zůstává na to jediné,
  // na co ho je potřeba: podpis URL do privátního bucketu.
  if (fakturoidId) {
    const { data: fd, error: chybaFd } = await jakoUzivatel
      .from('fakturoid_invoices_list')
      .select('cislo, pdf_path, vystaveno_at, subjekt')
      .eq('id', fakturoidId)
      .maybeSingle();
    // Syrový text Postgresu ven NEJDE. Endpoint je sice admin-only, ale cizí
    // chybové hlášky v prohlížeči jsou přesně ten tvar, který přežije, až se
    // endpoint jednou otevře víc lidem — týž důvod, jaký má `fakturoid-invoice`
    // u skládání odpovědi. Detail patří do logu funkce.
    if (chybaFd) {
      console.error('[invoice-pdf-url] čtení fakturoid_invoices_list', chybaFd.message);
      return odpoved({ error: 'Doklad se nepodařilo načíst. Detail je v provozním logu.' }, 500);
    }
    // Pohled nevydá doklad smazaný, uvolněný ani nedokončený — a uvolněný claim
    // je doklad, který u Fakturoidu NEVZNIKL. Vydat na něj odkaz by znamenalo
    // nabízet PDF, které nikomu nepatří.
    if (!fd) return odpoved({ error: 'Doklad neexistuje.' }, 404);

    // Doklad u Fakturoidu JE, jen naše kopie se neuložila (výpadek Storage při
    // vystavení — pipeline to nese jako varování, ne jako chybu). Hláška to musí
    // říct přesně: originál je ve Fakturoidu a admin si ho má stáhnout tam.
    if (!fd.pdf_path) {
      return odpoved({
        error: 'Naše kopie PDF u tohohle dokladu není — stáhni si originál ve Fakturoidu.',
      }, 409);
    }

    // PREFIX SE OVĚŘUJE, i když dnes utéct nejde. `fakturoid_zapis_pdf` bere
    // `_cesta` jako volný `text` bez CHECK a má `GRANT EXECUTE TO authenticated`
    // (brána `fakturoid_smi_volat` pouští admina), takže admin si přes PostgREST
    // může `pdf_path` přepsat na jiný objekt v témže bucketu — třeba na interní
    // doklad `2026/…/v1.pdf`. Bucket je jeden a čte ho jen tenhle admin-only
    // endpoint, takže to není díra; tahle podmínka je levnější než spoléhat na
    // to, že tak zůstane.
    if (!fd.pdf_path.startsWith('fakturoid/')) {
      console.error('[invoice-pdf-url] pdf_path mimo prefix', fd.pdf_path);
      return odpoved({ error: 'Naše kopie PDF u tohohle dokladu není — stáhni si originál ve Fakturoidu.' }, 409);
    }

    // DATUM V PRAŽSKÉM ČASE, ne v UTC. `vystaveno_at` je `timestamptz`, takže
    // `slice(0, 10)` by vzalo UTC — a doklad 2026-001, vystavený 16. 9. v 00:51
    // pražského času, by se stáhl jako `…150926.pdf`, zatímco tabulka o řádek
    // výš ukazuje 16. 9. Obrazovka a soubor by si u data dokladu odporovaly.
    // (Interní větev níž tenhle problém nemá: `datum_vystaveni` je `date`.)
    // `sv-SE` je tu kvůli tvaru `RRRR-MM-DD`, ne kvůli švédštině.
    const datum = fd.vystaveno_at
      ? new Date(fd.vystaveno_at).toLocaleDateString('sv-SE', { timeZone: 'Europe/Prague' })
      : '';
    const { data: podpisFd, error: chybaPodpisuFd } = await server.storage
      .from('invoices')
      .createSignedUrl(fd.pdf_path, PLATNOST_S, {
        download: nazevKeStazeni(fd.cislo ?? '', fd.subjekt ?? '', datum),
      });
    if (chybaPodpisuFd) {
      console.error('[invoice-pdf-url] podpis URL', chybaPodpisuFd.message);
      return odpoved({ error: 'Odkaz ke stažení se nepodařilo vytvořit. Detail je v provozním logu.' }, 500);
    }

    return odpoved({ url: podpisFd.signedUrl, platnost_s: PLATNOST_S });
  }

  const { data: f, error: chybaDokladu } = await server
    .from('invoices')
    .select('cislo, odberatel_nazev, datum_vystaveni, pdf_path, pdf_status')
    .eq('id', invoiceId)
    .maybeSingle();
  if (chybaDokladu) return odpoved({ error: chybaDokladu.message }, 500);
  if (!f) return odpoved({ error: 'Doklad neexistuje.' }, 404);

  // Rozlišené hlášky schválně: „ještě se generuje" a „selhalo" vedou admina
  // jinam než „doklad neexistuje".
  if (f.pdf_status !== 'ready' || !f.pdf_path) {
    return odpoved({
      error: f.pdf_status === 'failed'
        ? 'Generování PDF selhalo. Zkus ho spustit znovu, nebo použij tisk z obrazovky.'
        : 'PDF se ještě generuje. Za chvíli to zkus znovu, nebo použij tisk z obrazovky.',
      pdf_status: f.pdf_status,
    }, 409);
  }

  const { data: podpis, error: chybaPodpisu } = await server.storage
    .from('invoices')
    .createSignedUrl(f.pdf_path, PLATNOST_S, {
      download: nazevKeStazeni(f.cislo ?? '', f.odberatel_nazev ?? '', f.datum_vystaveni ?? ''),
    });
  if (chybaPodpisu) return odpoved({ error: chybaPodpisu.message }, 500);

  return odpoved({ url: podpis.signedUrl, platnost_s: PLATNOST_S });
});

function odpoved(telo: unknown, status = 200): Response {
  return new Response(JSON.stringify(telo), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json' },
  });
}
