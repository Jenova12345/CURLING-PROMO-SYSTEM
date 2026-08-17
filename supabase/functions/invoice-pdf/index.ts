// C4/C5 — worker fronty PDF.
//
// Vezme si z fronty vystavené doklady, vysází je, uloží do privátního bucketu
// a zapíše k faktuře cestu i otisk. Volá se z `pg_cron` (hodinový tik) nebo
// ručně z Nastavení; obojí přes servisní klíč.
//
// ROZDĚLENÍ ZODPOVĚDNOSTI
//   `pdfDoklad.ts`  — kreslí (čisté, testované z Node)
//   `dokladDto.ts`  — rozhoduje, co se kreslí (čisté, testované z Node)
//   tenhle soubor   — HTTP, databáze, Storage. Co nejmíň rozhodování.
//
// PROČ PO JEDNOM A S LIMITEM: Edge funkce má strop ~2 s CPU na požadavek a
// render jednoho dokladu je desítky až stovky ms. Dávka se proto omezuje a
// zbytek se dobere dalším tikem — fronta, ne kolona (R4).
//
// CO SE STANE, KDYŽ TO SPADNE: `fail_invoice_pdf` vrátí doklad do fronty
// a připočte pokus; po pátém ho označí `failed` a čeká na člověka. Faktura
// bez PDF je pořád platný doklad — číslo dostala při vystavení (R5).

import { createClient } from 'jsr:@supabase/supabase-js@2';

import { renderInvoice } from '../_shared/pdfDoklad.ts';
import {
  klicObjektu, maMitQr, sestavDto,
  type FakturaRadek, type PolozkaRadek,
} from '../_shared/dokladDto.ts';
import { buildSpayd } from '../_shared/spayd.ts';
import { denZDb } from '@/lib/datum';

const BUCKET = 'invoices';
const DAVKA = 5;

const sha256hex = async (data: Uint8Array): Promise<string> => {
  // Kopie do vlastního `ArrayBuffer`: `pdf-lib` vrací pohled, jehož buffer může
  // být sdílený, a `crypto.subtle` sdílené buffery nebere.
  const kopie = new Uint8Array(data.byteLength);
  kopie.set(data);
  const h = await crypto.subtle.digest('SHA-256', kopie.buffer);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('');
};

Deno.serve(async (req: Request) => {
  const url = Deno.env.get('SUPABASE_URL');
  const klic = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !klic) {
    return new Response(JSON.stringify({ error: 'Chybí SUPABASE_URL nebo SERVICE_ROLE_KEY.' }),
      { status: 500, headers: { 'content-type': 'application/json' } });
  }

  // Servisní klíč obchází RLS, takže tahle funkce NESMÍ být volatelná zvenčí
  // bez něj. Supabase ověřuje `Authorization` sám (`verify_jwt`), tohle je
  // druhá závora: bez servisní role se nepokračuje ani omylem.
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.includes(klic)) {
    return new Response(JSON.stringify({ error: 'Frontu PDF obsluhuje jen server.' }),
      { status: 401, headers: { 'content-type': 'application/json' } });
  }

  const db = createClient(url, klic, { auth: { persistSession: false } });

  const { data: fronta, error: chybaFronty } = await db.rpc('claim_invoice_pdf', { _limit: DAVKA });
  if (chybaFronty) {
    return new Response(JSON.stringify({ error: chybaFronty.message }),
      { status: 500, headers: { 'content-type': 'application/json' } });
  }

  const vysledky: Array<{ cislo: string | null; stav: string; chyba?: string }> = [];

  for (const polozka of (fronta ?? []) as Array<{ id: string; cislo: string | null }>) {
    try {
      const { data: f, error: e1 } = await db.from('invoices').select('*').eq('id', polozka.id).single();
      if (e1 || !f) throw new Error(e1?.message ?? 'Faktura zmizela z databáze.');

      const { data: polozky, error: e2 } = await db.from('invoice_items')
        .select('popis, datum, hodiny, sazba, line_total, vat_rate, vat_base, vat_amount, poradi')
        .eq('invoice_id', polozka.id);
      if (e2) throw new Error(e2.message);

      // Číslo opravovaného dokladu — jen u opravného dokladu.
      let opravujeCislo: string | null = null;
      if (f.opravuje_id) {
        const { data: p } = await db.from('invoices').select('cislo').eq('id', f.opravuje_id).maybeSingle();
        opravujeCislo = p?.cislo ?? null;
      }

      const dto = sestavDto(f as FakturaRadek, (polozky ?? []) as PolozkaRadek[], opravujeCislo);

      // QR se skládá TÝMŽ modulem jako tisk z obrazovky. Kdyby měl worker
      // vlastní, mohly by se rozejít — a QR je jediné místo na dokladu, které
      // zákazník nečte, jen naskenuje.
      let spayd: string | null = null;
      if (maMitQr(dto)) {
        try {
          spayd = buildSpayd({
            iban: dto.dodavatel_iban!,
            amount: dto.total_rounded,
            variableSymbol: dto.variabilni_symbol,
            // `denZDb`, ne `new Date(...)`: `buildSpayd` čte z data MÍSTNÍ složky
            // (`getDate()`), takže holé `RRRR-MM-DD` jako půlnoc UTC by v pásmu
            // za UTC posunulo splatnost v QR o den dozadu.
            dueDate: denZDb(dto.datum_splatnosti),
            recipientName: dto.dodavatel_nazev,
            message: dto.dodavatel_zprava,
          });
        } catch {
          // Vadný IBAN ve snapshotu nesmí shodit celý doklad — platební údaje
          // jsou na něm i textem. Radši doklad bez QR než žádný doklad.
          spayd = null;
        }
      }

      const bytes = await renderInvoice(dto, spayd);
      const cesta = klicObjektu(dto.cislo, dto.datum_vystaveni);
      const otisk = await sha256hex(bytes);

      const { error: e3 } = await db.storage.from(BUCKET).upload(cesta, bytes, {
        contentType: 'application/pdf',
        upsert: true,   // opakovaný pokus přepíše svůj vlastní nedokončený soubor
      });
      if (e3) throw new Error(`Upload selhal: ${e3.message}`);

      const { error: e4 } = await db.rpc('finish_invoice_pdf', {
        _invoice_id: polozka.id, _path: cesta, _sha256: otisk, _bytes: bytes.byteLength,
      });
      if (e4) throw new Error(e4.message);

      vysledky.push({ cislo: polozka.cislo, stav: 'ready' });
    } catch (err) {
      const zprava = err instanceof Error ? err.message : String(err);
      await db.rpc('fail_invoice_pdf', { _invoice_id: polozka.id, _chyba: zprava });
      vysledky.push({ cislo: polozka.cislo, stav: 'chyba', chyba: zprava });
    }
  }

  return new Response(JSON.stringify({ zpracovano: vysledky.length, vysledky }),
    { headers: { 'content-type': 'application/json' } });
});
