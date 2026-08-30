// =============================================================================
// Úklid testovacích dokladů na účtu Fakturoidu
// =============================================================================
// Integrační testy zakládají doklady a od teď je po sobě uklízejí samy
// (`afterAll` v `fakturoid.integration.test.ts`). Tenhle skript je na to, co
// zbylo z doby, kdy to neuměly — a jako záchrana, když teardown selže.
//
// ⚠️ MAŽE DOKLADY. Proto tři nezávislé pojistky, ne jedna:
//   1. `FAKTUROID_SLUG` se MUSÍ shodovat s `FAKTUROID_TEST_SLUG`. Kdo si do
//      obou zkopíruje produkční slug, obejde ji — ale to už je vědomý úkon,
//      ne nehoda. Táž pojistka jako u integračních testů.
//   2. Maže se jen podle VZORU v `custom_id`, ne podle stáří nebo čísla.
//      Doklad bez `custom_id` nebo s cizím tvarem se nesmaže nikdy.
//   3. Bez `--smazat` se jen VYPÍŠE, co by se smazalo. Výchozí běh je nanečisto.
//
// PROČ TO NENÍ V `billing/`: produkční kód nesmí umět doklad smazat ani omylem.
// V ostré číselné řadě se doklad NEMAŽE, jen dobropisuje — metoda `smazDoklad`
// na `InvoiceProvider` by byla nabitá zbraň ležící na stole. Tady je to skript,
// který se do bundlu nedostane a musí se spustit rukou.
//
// Spuštění:
//   npx vite-node scripts/fakturoid-uklid-testy.ts              # jen vypíše
//   npx vite-node scripts/fakturoid-uklid-testy.ts --smazat     # doopravdy smaže
// =============================================================================
import { loadEnv } from 'vite';

import { nactiConfig, zakladUrl } from '../billing/providers/fakturoid/config.ts';
import { TOKEN_URL, basicHlavicka } from '../billing/providers/fakturoid/auth.ts';

const env = { ...loadEnv('', process.cwd(), ''), ...process.env };
const config = nactiConfig(env as Record<string, string | undefined>);
const povolenyUcet = (env.FAKTUROID_TEST_SLUG ?? '').trim();
const smazat = process.argv.includes('--smazat');

/**
 * Co se považuje za testovací doklad.
 *
 * `-test-` pokrývá klíče, které vyrábějí integrační testy (`klub-test-{běh}`,
 * `akce-test-{běh}`), `mereni-` ruční měření. ZÁMĚRNĚ to NENÍ „začíná na test-":
 * klíče začínají druhem dokladu, ne prefixem, a kdo by je hledal podle začátku,
 * nenajde nic — což byl přesně nález code review.
 */
const jeTestovaci = (customId: unknown): boolean =>
  typeof customId === 'string' && (customId.includes('-test-') || customId.startsWith('mereni-'));

interface FDoklad { id: number; number: string | null; custom_id: string | null; total: string | number | null }

const hlavni = async (): Promise<void> => {
  if (!povolenyUcet || config.slug !== povolenyUcet) {
    console.error(
      `ODMÍTNUTO: účet „${config.slug}" se neshoduje s FAKTUROID_TEST_SLUG.\n` +
      'Tenhle skript maže doklady a smí běžet jen proti testovacímu účtu.',
    );
    process.exit(1);
  }

  const tokenOdpoved = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: {
      Authorization: basicHlavicka(config.clientId, config.clientSecret),
      'Content-Type': 'application/json',
      Accept: 'application/json',
      'User-Agent': config.userAgent,
    },
    body: JSON.stringify({ grant_type: 'client_credentials' }),
  });
  if (!tokenOdpoved.ok) {
    console.error(`Přihlášení k Fakturoidu selhalo (HTTP ${tokenOdpoved.status}).`);
    process.exit(1);
  }
  const token = ((await tokenOdpoved.json()) as { access_token: string }).access_token;
  const zaklad = zakladUrl(config.slug);
  const hlavicky = { Authorization: `Bearer ${token}`, 'User-Agent': config.userAgent, Accept: 'application/json' };

  // Stránkuje se, dokud něco chodí. Strop je pojistka proti nekonečné smyčce
  // při neočekávané odpovědi, ne odhad velikosti účtu.
  const vse: FDoklad[] = [];
  for (let stranka = 1; stranka <= 50; stranka++) {
    const r = await fetch(`${zaklad}/invoices.json?page=${stranka}`, { headers: hlavicky });
    if (!r.ok) { console.error(`Výpis dokladů selhal (HTTP ${r.status}).`); process.exit(1); }
    const davka = await r.json() as FDoklad[];
    if (!Array.isArray(davka) || davka.length === 0) break;
    // Deduplikace podle `id`: kdyby API `page` ignorovalo, sesbírala by se
    // padesátkrát táž stránka a výpis by lhal o počtech. Smazat by se kvůli
    // tomu nic špatného nemohlo, ale číslo, kterému se nedá věřit, je horší
    // než žádné.
    const nove = davka.filter((f) => !vse.some((x) => x.id === f.id));
    if (nove.length === 0) break;
    vse.push(...nove);
  }

  const testovaci = vse.filter((f) => jeTestovaci(f.custom_id));
  const ostatni = vse.filter((f) => !jeTestovaci(f.custom_id));

  console.log(`\núčet: ${config.slug}  ·  dokladů celkem: ${vse.length}`);
  console.log(`testovacích: ${testovaci.length}  ·  ostatních (nedotýkáme se jich): ${ostatni.length}\n`);

  if (testovaci.length === 0) { console.log('Není co uklízet.'); return; }

  for (const f of testovaci) {
    console.log(`  ${String(f.number).padEnd(12)} ${String(f.custom_id).padEnd(36)} ${f.total} Kč`);
  }

  if (!smazat) {
    console.log(`\nNANEČISTO — nic se nesmazalo. Doopravdy: --smazat\n`);
    return;
  }

  console.log('\nMAŽU…');
  let smazano = 0;
  for (const f of testovaci) {
    const d = await fetch(`${zaklad}/invoices/${f.id}.json`, { method: 'DELETE', headers: hlavicky });
    if (d.ok) { smazano++; console.log(`  ✓ ${f.number}`); }
    else console.log(`  ✗ ${f.number} → HTTP ${d.status}`);
  }
  console.log(`\nSmazáno ${smazano} z ${testovaci.length}.\n`);
};

await hlavni();
