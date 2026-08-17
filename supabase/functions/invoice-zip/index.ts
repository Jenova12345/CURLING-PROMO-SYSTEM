// E3 — měsíční ZIP export dokladů pro účetní.
//
// LEVEL 0 (bez komprese) SCHVÁLNĚ: PDF už komprimované je, takže by deflate
// jen spálil CPU a soubor zmenšil o jednotky procent. Edge funkce má strop ~2 s
// CPU a stahování třiceti souborů z úložiště do něj musí vejít i s balením.
//
// ARCHIV OBSAHUJE I ROZCESTNÍK (`prehled.csv`) — a v něm i doklady, které se do
// ZIPu nedostaly, protože jim ještě nevzniklo PDF. Mlčky vynechaný doklad je
// horší než chybějící soubor: archiv by vypadal úplně a chyběl by v něm doklad,
// na který se přijde až při kontrole.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { zipSync, strToU8 } from 'npm:fflate@0.8.2';

import {
  hraniceMesice, nazevArchivu, nazevVArchivu, prehledCsv,
  type DokladProExport,
} from '../_shared/mesicniExport.ts';

/** Strop na jeden archiv. Radši useknout a říct to, než spadnout na limitu. */
const MAX_DOKLADU = 200;

/**
 * Tvar řádku, který si tahle funkce vybírá.
 *
 * Vypsaný ručně schválně: seznam sloupců se skládá z několika řetězců (aby se
 * vešel na řádek) a typový odvozovač supabase-js si s tím neporadí — bez tohohle
 * mu z dotazu vyjde `GenericStringError` a přístup ke sloupcům přestane typovat.
 */
interface RadekExportu {
  cislo: string | null;
  odberatel_nazev: string | null;
  datum_vystaveni: string | null;
  datum_splatnosti: string | null;
  datum_uhrady: string | null;
  status: string;
  total_rounded: number | string;
  pdf_status: string | null;
  pdf_path: string | null;
  opravuje_id: string | null;
}

Deno.serve(async (req: Request) => {
  const url = Deno.env.get('SUPABASE_URL');
  const servisni = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !servisni || !anon) return chyba('Chybí konfigurace prostředí.', 500);

  const autorizace = req.headers.get('Authorization') ?? '';
  if (!autorizace.startsWith('Bearer ')) return chyba('Chybí přihlášení.', 401);

  let rok: number, mesic: number;
  try {
    const telo = await req.json();
    rok = Number(telo?.rok);
    mesic = Number(telo?.mesic);
  } catch {
    return chyba('Čekal jsem JSON s `rok` a `mesic`.', 400);
  }

  let obdobi: { od: string; do: string };
  try {
    obdobi = hraniceMesice(rok, mesic);
  } catch (e) {
    return chyba(e instanceof Error ? e.message : 'Neplatné období.', 400);
  }

  // KDO SE PTÁ: klient s tokenem volajícího, takže roli počítá databáze z jeho
  // `auth.uid()`, ne z toho, co přijde v těle požadavku.
  const jakoUzivatel = createClient(url, anon, {
    global: { headers: { Authorization: autorizace } },
    auth: { persistSession: false },
  });
  const { data: jeAdmin, error: chybaRole } = await jakoUzivatel.rpc('has_role', {
    _user_id: (await jakoUzivatel.auth.getUser()).data.user?.id, _role: 'admin',
  });
  if (chybaRole) return chyba(chybaRole.message, 500);
  if (!jeAdmin) return chyba('Měsíční export stahuje jen správce haly.', 403);

  const server = createClient(url, servisni, { auth: { persistSession: false } });

  // Doklady se berou podle DATA VYSTAVENÍ, ne podle období plnění: účetní
  // uzavírá měsíc podle toho, kdy doklad vznikl.
  const { data: syrove, error: chybaDotazu } = await server
    .from('invoices')
    .select('cislo, odberatel_nazev, datum_vystaveni, datum_splatnosti, datum_uhrady,'
          + ' status, total_rounded, pdf_status, pdf_path, opravuje_id')
    .neq('status', 'koncept')
    .gte('datum_vystaveni', obdobi.od)
    .lte('datum_vystaveni', obdobi.do)
    .order('cislo', { ascending: true })
    .limit(MAX_DOKLADU + 1);
  if (chybaDotazu) return chyba(chybaDotazu.message, 500);
  const doklady = (syrove ?? []) as unknown as RadekExportu[];

  if (!doklady.length) {
    return chyba(`Za ${mesic}/${rok} není vystavený žádný doklad.`, 404);
  }

  const useknuto = doklady.length > MAX_DOKLADU;
  const vybrane = doklady.slice(0, MAX_DOKLADU);

  // Čísla opravovaných dokladů: aby šlo v přehledu poznat, co je opravný doklad.
  const opravujeIds = [...new Set(vybrane.map((d) => d.opravuje_id).filter(Boolean))] as string[];
  const cislaPodleId = new Map<string, string>();
  if (opravujeIds.length) {
    const { data: puvodni } = await server.from('invoices').select('id, cislo').in('id', opravujeIds);
    for (const p of (puvodni ?? []) as Array<{ id: string; cislo: string | null }>) {
      cislaPodleId.set(p.id, p.cislo ?? '');
    }
  }

  const proExport: DokladProExport[] = vybrane.map((d) => ({
    cislo: d.cislo,
    odberatel: d.odberatel_nazev,
    datum_vystaveni: d.datum_vystaveni,
    datum_splatnosti: d.datum_splatnosti,
    datum_uhrady: d.datum_uhrady,
    status: d.status,
    total_rounded: d.total_rounded,
    pdf_status: d.pdf_status,
    pdf_path: d.pdf_path,
    opravuje_cislo: d.opravuje_id ? (cislaPodleId.get(d.opravuje_id) ?? '?') : null,
  }));

  const soubory: Record<string, Uint8Array> = {};
  const nestazeno: string[] = [];

  for (const d of proExport) {
    if (d.pdf_status !== 'ready' || !d.pdf_path) continue;   // je v přehledu jako „NE"
    const { data, error } = await server.storage.from('invoices').download(d.pdf_path);
    if (error || !data) {
      // Soubor v evidenci je, ale v úložišti chybí. Do archivu ho dát nejde
      // a je to vada, ne drobnost — proto se vypíše, ne přeskočí mlčky.
      nestazeno.push(`${d.cislo}: ${error?.message ?? 'soubor nenalezen'}`);
      continue;
    }
    soubory[nazevVArchivu(d)] = new Uint8Array(await data.arrayBuffer());
  }

  soubory['prehled.csv'] = strToU8(prehledCsv(proExport));

  if (nestazeno.length || useknuto) {
    // Poznámka do archivu, ne jen do odpovědi: odpověď si nikdo neuloží,
    // ZIP putuje k účetní a měl by o svých mezerách mluvit sám.
    soubory['UPOZORNENI.txt'] = strToU8([
      `Export ${mesic}/${rok}`,
      useknuto
        ? `POZOR: dokladů je víc než ${MAX_DOKLADU}, archiv obsahuje jen prvních ${MAX_DOKLADU} podle čísla.`
        : '',
      nestazeno.length ? 'Doklady, jejichž PDF se nepodařilo stáhnout:' : '',
      ...nestazeno,
      '',
      'Doklady bez vygenerovaného PDF jsou v prehled.csv se sloupcem v_archivu = NE.',
    ].filter(Boolean).join('\r\n'));
  }

  const zip = zipSync(soubory, { level: 0 });
  // Kopie do vlastního bufferu: `Response` chce `BufferSource` a pohled ze
  // `zipSync` může sedět na sdíleném bufferu (týž případ jako sha256 u renderu).
  const telo = new Uint8Array(zip.byteLength);
  telo.set(zip);

  return new Response(telo, {
    headers: {
      'content-type': 'application/zip',
      'content-disposition': `attachment; filename="${nazevArchivu(rok, mesic)}"`,
      'x-dokladu': String(proExport.length),
      'x-v-archivu': String(Object.keys(soubory).filter((k) => k.endsWith('.pdf')).length),
    },
  });
});

function chyba(zprava: string, status: number): Response {
  return new Response(JSON.stringify({ error: zprava }), {
    status, headers: { 'content-type': 'application/json' },
  });
}
