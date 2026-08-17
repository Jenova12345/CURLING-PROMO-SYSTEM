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

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { nazevKeStazeni } from '../_shared/dokladDto.ts';

/** Krátká platnost: odkaz má posloužit ke stažení, ne kolovat e-mailem. */
const PLATNOST_S = 300;

Deno.serve(async (req: Request) => {
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
  try {
    invoiceId = (await req.json())?.invoice_id;
  } catch {
    return odpoved({ error: 'Čekal jsem JSON s `invoice_id`.' }, 400);
  }
  if (!invoiceId) return odpoved({ error: 'Chybí `invoice_id`.' }, 400);

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
    headers: { 'content-type': 'application/json' },
  });
}
