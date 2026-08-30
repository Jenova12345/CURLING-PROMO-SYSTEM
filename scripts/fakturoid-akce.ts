/**
 * Vystaví koncept-fakturu do Fakturoidu za JEDNU komerční akci.
 *
 *   npm run fakturoid:akce              — vypíše akce, které jdou vyfakturovat
 *   npm run fakturoid:akce -- <eventId> — vystaví doklad za tuhle akci
 *
 * PROČ SKRIPT A NE TLAČÍTKO: napojení na Fakturoid zatím nemá UI (viz
 * docs/ETAPA3-STAV.md). Tenhle skript NEOBSAHUJE žádnou vlastní fakturační
 * logiku — jen posbírá podklady a zavolá `vystavDoklad`, tedy přesně tu cestu,
 * kterou pojede Edge funkce. Kdyby si tu někdo „na rychlo" dopsal vlastní
 * rozhodování, obešel by tím tři zámky idempotence.
 *
 * MÍŘÍ NA LOKÁLNÍ DATABÁZI (`supabase status`) a na Fakturoid účet z `.env`.
 * Doklad se ZALOŽÍ, ale NEODEŠLE — režim `koncept`.
 */
import { execSync } from 'node:child_process';
import { loadEnv } from 'vite';
import { createClient } from '@supabase/supabase-js';

import { nactiConfig } from '../billing/providers/fakturoid/config.ts';
import { FakturoidProvider } from '../billing/providers/fakturoid/index.ts';
import { SupabaseStore, type RpcKlient } from '../billing/supabaseStore.ts';
import { vystavDoklad } from '../billing/pipeline.ts';
import { mapujKomercniAkci, soucetRadku, type BillableReservation, type SubjectForBilling }
  from '../billing/mapping.ts';
import { proUzivatele } from '../billing/errors.ts';
import { roundCzk } from '../src/lib/money.ts';

const KC = (v: number) => `${v.toLocaleString('cs-CZ')} Kč`;

const lokalniKlient = () => {
  const stav = execSync('supabase status -o env', { encoding: 'utf8' });
  const val = (k: string) => {
    const m = stav.match(new RegExp(`^${k}="?([^"\n]+)"?$`, 'm'));
    if (!m) throw new Error(`V \`supabase status\` chybí ${k}. Běží lokální Supabase?`);
    return m[1];
  };
  return createClient(val('API_URL'), val('SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
};

const main = async () => {
  const config = nactiConfig({ ...loadEnv('', process.cwd(), ''), ...process.env });
  const db = lokalniKlient();
  const eventId = process.argv[2];

  // ---- Bez argumentu: nabídka ---------------------------------------------
  if (!eventId) {
    const { data, error } = await db
      .from('events')
      .select('id, title, start_time')
      .eq('event_type', 'commercial')
      .order('start_time', { ascending: false })
      .limit(30);
    if (error) throw new Error(error.message);

    // Co je k fakturaci NEROZHODUJE tenhle skript — ptá se na to
    // `fakturoid_podklady_akce`, tedy tatáž funkce, kterou použije Edge funkce.
    // Vlastní filtr by se s ní časem rozešel a vypadalo by to jako chyba
    // ve fakturaci.
    const radky: string[] = [];
    for (const e of (data ?? []) as Array<{ id: string; title: string; start_time: string }>) {
      const { data: p } = await db.rpc('fakturoid_podklady_akce', { _event: e.id });
      const rez = (p ?? []) as Array<BillableReservation & { subject_id: string }>;
      if (rez.length === 0) continue;

      const { data: subj } = await db.rpc('fakturoid_subjekt', { _id: rez[0].subject_id });
      const firma = ((subj ?? []) as SubjectForBilling[])[0]?.name ?? '?';
      const castka = rez.reduce((a, r) => a + Number(r.castka), 0);
      const den = new Intl.DateTimeFormat('cs-CZ', {
        timeZone: 'Europe/Prague', day: '2-digit', month: '2-digit', year: 'numeric',
      }).format(new Date(e.start_time));

      radky.push(`  ${e.id}\n     ${den}  ${e.title}  ·  ${firma}  ·  ${rez.length}× dráha  ·  ${KC(castka)}`);
    }

    if (radky.length === 0) {
      console.log('Žádná komerční akce k vyfakturování.');
      console.log('Buď už všechny doklad mají, nebo jejich rezervace čekají na schválení.');
      return;
    }
    console.log('Komerční akce, které jdou vyfakturovat:\n');
    console.log(radky.join('\n\n'));
    console.log('\nVystavíš ji příkazem:\n  npm run fakturoid:akce -- <id akce>');
    return;
  }

  // ---- S argumentem: vystavení --------------------------------------------
  const { data: rez, error: chybaPodkladu } = await db.rpc('fakturoid_podklady_akce', { _event: eventId });
  if (chybaPodkladu) throw new Error(chybaPodkladu.message);
  const rezervace = (rez ?? []) as Array<BillableReservation & { subject_id: string }>;

  if (rezervace.length === 0) {
    console.log('Za tuhle akci není co fakturovat.');
    console.log('Buď doklad už má, nebo rezervace čekají na schválení (fakturují se jen schválené).');
    return;
  }

  const subjectId = rezervace[0].subject_id;
  if (rezervace.some((r) => r.subject_id !== subjectId)) {
    console.log('Akce má rezervace víc odběratelů — doklad na ni nejde vystavit automaticky.');
    return;
  }

  const { data: subj, error: chybaSubjektu } = await db.rpc('fakturoid_subjekt', { _id: subjectId });
  if (chybaSubjektu) throw new Error(chybaSubjektu.message);
  const subjekt = ((subj ?? []) as SubjectForBilling[])[0];
  if (!subjekt) throw new Error(`Subjekt ${subjectId} nenalezen.`);

  const draft = mapujKomercniAkci({
    eventId, subjekt, rezervace, jePlatceDph: config.jePlatceDph, dueInDays: config.dueDays,
  });
  if (!draft) { console.log('Za tuhle akci není co fakturovat.'); return; }

  console.log('── POSÍLÁME DO FAKTUROIDU ─────────────────────────────');
  console.log(`  odběratel:  ${draft.party.name}${draft.party.registrationNo ? `  IČO ${draft.party.registrationNo}` : ''}`);
  console.log(`  adresa:     ${draft.party.street ?? '—'}`);
  console.log(`  splatnost:  ${draft.dueInDays} dní`);
  console.log(`  režim:      ${config.rezim}${config.rezim === 'koncept' ? '  (doklad se založí, e-mail SE NEPOSÍLÁ)' : '  (doklad se ODEŠLE odběrateli!)'}`);
  console.log(`  účet:       ${config.slug}`);
  console.log('  řádky:');
  for (const l of draft.lines) console.log(`     ${l.quantity} ${l.unitName} × ${KC(l.unitPrice)}   ${l.name}`);
  // DPH SE MUSÍ VYPSAT PODLE SKUTEČNOSTI, ne natvrdo.
  //
  // Tenhle výpis je POSLEDNÍ, co operátor vidí, než vznikne doklad v ostré
  // číselné řadě — a ten se opravuje dobropisem, ne přepnutím zpátky. Dřív tu
  // stálo natvrdo „neposíláme (neplátce)", takže po zapnutí `IS_VAT_PAYER` by
  // skript poslal sazbu 12 % a u toho operátorovi napsal, že žádnou DPH
  // neposílá. Našla to bezpečnostní brána.
  //
  // A „celkem" u komerční akce taky lhalo: pod plátcem je `soucetRadku` ZÁKLAD
  // bez daně, takže operátor viděl 5 000 Kč a odběrateli přišla faktura na
  // 5 600 Kč. Popisek se proto řídí tím, co `pricesIncludeVat` znamená.
  const soucet = roundCzk(soucetRadku(draft.lines));
  const sazba = draft.lines.find((l) => l.vatRate !== undefined)?.vatRate;

  if (sazba === undefined) {
    console.log(`  celkem:     ${KC(soucet)}`);
    console.log('  DPH:        neposíláme (neplátce)   ·   číslo a VS přiděluje Fakturoid\n');
  } else if (draft.pricesIncludeVat) {
    console.log(`  celkem:     ${KC(soucet)}   (ceny VČETNĚ DPH)`);
    console.log(`  DPH:        ${sazba} % · ceny na řádcích jsou S DANÍ (vat_price_mode=from_total_with_vat)`);
    console.log('              číslo a VS přiděluje Fakturoid\n');
  } else {
    // Dopočet je JEN pro výpis, na doklad se neposílá — daň počítá Fakturoid.
    // Proto „≈": naše zaokrouhlení nemusí sedět s jeho na haléř.
    const sDani = roundCzk(soucet * (1 + sazba / 100));
    console.log(`  základ:     ${KC(soucet)}   (ceny BEZ DPH)`);
    console.log(`  s daní:     ≈ ${KC(sDani)}   ← tolik zaplatí odběratel`);
    console.log(`  DPH:        ${sazba} % · ceny na řádcích jsou BEZ DANĚ (vat_price_mode=without_vat)`);
    console.log('              číslo a VS přiděluje Fakturoid\n');
  }

  const v = await vystavDoklad({
    draft,
    provider: new FakturoidProvider({ config, fetch: globalThis.fetch as never }),
    store: new SupabaseStore(db as unknown as RpcKlient),
    rezim: config.rezim,
  });

  console.log('── VÝSLEDEK ───────────────────────────────────────────');
  if (v.stav === 'vystaveno' || v.stav === 'existoval') {
    const r = v.link.result;
    console.log(v.stav === 'vystaveno' ? '  ✓ Doklad vystaven' : '  ✓ Doklad už existoval — vazba jen dorovnána');
    console.log(`  číslo:      ${r.number}`);
    console.log(`  VS:         ${r.variableSymbol}`);
    console.log(`  celkem:     ${KC(Number(r.providerTotal ?? 0))}`);
    console.log(`  odkaz:      ${r.publicUrl ?? '—'}`);
    for (const w of v.varovani ?? []) console.log(`  ⚠ [${w.kod}] ${w.zprava}`);
  } else if (v.stav === 'preskoceno') {
    console.log(`  Přeskočeno: ${v.duvod}`);
  } else if (v.stav === 'nesedi') {
    console.log(`  ⚠ Doklad u Fakturoidu NEODPOVÍDÁ podkladu, vazba se nezapsala:`);
    console.log(`     ${v.duvod}`);
  } else {
    console.log('  Není co fakturovat.');
  }
};

main().catch((e) => {
  const { kod, interni } = proUzivatele(e);
  console.error(`\n✗ Nepovedlo se [${kod}]: ${interni}`);
  process.exit(1);
});
