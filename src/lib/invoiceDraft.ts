import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { BRAND } from '@/config/brand';
import { fmtHodin, fmtKc, fmtSazba, roundCzk, roundingDiff, sumHodin, sumKc } from '@/lib/money';

// Podklad k fakturaci ve formě tisknutelné stránky.
//
// Proč tisk do PDF a ne knihovna: potřebujeme české diakritice odpovídající text
// (jsPDF by na ě/š/č/ř/ž potřeboval doembedovat font) a nechceme kvůli ukázce
// tahat do buildu další závislost. Prohlížeč umí „Uložit jako PDF" z tiskového
// dialogu, což pro NÁVRH bohatě stačí. Nic se neukládá na server.
//
// ⚠️ Tohle NENÍ daňový doklad: nemá číslo faktury, DPH ani zákonné náležitosti.
// Sériové číslování, DPH a archivace přijdou v další etapě.

export interface InvoiceSubject {
  name: string;
  address?: string | null;
  ico?: string | null;
  dic?: string | null;
}

export interface InvoiceRow {
  start_at: string;
  end_at: string;
  /** kdo rezervaci objednal (jméno) */
  ordered_by?: string | null;
  /** název akce, když ho rezervace má */
  event_title?: string | null;
  sheet_name?: string | null;
  hours: number;
  rate: number | null;
  amount: number;
}

export interface InvoiceDraft {
  subject: InvoiceSubject;
  rows: InvoiceRow[];
  periodFrom: Date;
  periodTo: Date;
}

/** Ochrana proti rozbití stránky uživatelským textem (názvy akcí, adresy). */
function esc(value: unknown): string {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function buildHtml({ subject, rows, periodFrom, periodTo }: InvoiceDraft): string {
  // Součet je PŘESNÝ součet tištěných řádků (viz src/lib/money.ts). Na celé
  // koruny se zaokrouhluje stupňovitě až u částky k úhradě, a to z TÉHOŽ
  // kvantizovaného mezisoučtu, který je vytištěný — proto „součet sloupce ==
  // mezisoučet" i „mezisoučet + zaokrouhlení == k úhradě" platí triviálně,
  // ne shodou okolností. Zaokrouhlovací rozdíl je vidět vlastním řádkem.
  const mezisoucet = sumKc(rows.map((r) => r.amount));
  const zaokrouhleni = roundingDiff(mezisoucet);
  const kUhrade = roundCzk(mezisoucet);
  const totalHours = sumHodin(rows.map((r) => r.hours));
  const vystaveno = format(new Date(), 'd. M. yyyy', { locale: cs });
  const obdobi = `${format(periodFrom, 'd. M. yyyy', { locale: cs })} – ${format(periodTo, 'd. M. yyyy', { locale: cs })}`;

  // Dokud klient nedodá své údaje, radši je netiskneme, než aby na ukázce svítilo
  // „IČO — doplnit".
  const vyplneno = (v: string) => (v && !/doplnit/i.test(v) ? v : null);
  const dodavatelRadky = [
    vyplneno(BRAND.billing.address),
    vyplneno(BRAND.billing.ico) ? `IČO: ${vyplneno(BRAND.billing.ico)}` : null,
    vyplneno(BRAND.billing.dic) ? `DIČ: ${vyplneno(BRAND.billing.dic)}` : null,
  ].filter(Boolean).map((r) => `<div>${esc(r)}</div>`).join('')
    || '<div class="chybi">Fakturační údaje provozovatele zatím nejsou vyplněné.</div>';

  const radky = rows.map((r) => {
    const zacatek = new Date(r.start_at);
    const konec = new Date(r.end_at);
    const popis = [r.event_title, r.sheet_name].filter(Boolean).map(esc).join(' · ');
    return `
      <tr>
        <td>${esc(format(zacatek, 'd. M. yyyy', { locale: cs }))}</td>
        <td>${esc(format(zacatek, 'HH:mm'))}–${esc(format(konec, 'HH:mm'))}</td>
        <td>${popis || '—'}</td>
        <td>${esc(r.ordered_by ?? '—')}</td>
        <td class="cislo">${esc(fmtHodin(r.hours))}</td>
        <td class="cislo">${r.rate != null ? esc(fmtSazba(r.rate)) : '—'}</td>
        <td class="cislo">${esc(fmtKc(r.amount))}</td>
      </tr>`;
  }).join('');

  return `<!doctype html>
<html lang="cs">
<head>
<meta charset="utf-8">
<title>Podklad k fakturaci — ${esc(subject.name)}</title>
<style>
  @page { size: A4; margin: 16mm; }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
    color: #0f172a; margin: 0; padding: 24px; font-size: 12px; line-height: 1.45;
    position: relative;
  }
  .navrh {
    position: fixed; inset: 0; display: flex; align-items: center; justify-content: center;
    font-size: 84px; font-weight: 800; color: rgba(220, 38, 38, .10);
    transform: rotate(-24deg); letter-spacing: 6px; pointer-events: none; z-index: 0;
  }
  .obsah { position: relative; z-index: 1; }
  .stitek {
    display: inline-block; border: 2px solid #dc2626; color: #dc2626; font-weight: 700;
    padding: 4px 10px; border-radius: 4px; letter-spacing: 1px; margin-bottom: 16px;
  }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .podnadpis { color: #475569; margin-bottom: 20px; }
  .strany { display: flex; gap: 32px; margin-bottom: 24px; }
  .strana { flex: 1; }
  .strana h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; margin: 0 0 6px; }
  .strana .jmeno { font-weight: 700; font-size: 14px; }
  table { width: 100%; border-collapse: collapse; margin-top: 8px; }
  th, td { padding: 6px 8px; border-bottom: 1px solid #e2e8f0; text-align: left; vertical-align: top; }
  th { background: #f8fafc; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: #475569; }
  td.cislo, th.cislo { text-align: right; white-space: nowrap; }
  /* Silná linka jen nad prvním řádkem patky; mezisoučet a zaokrouhlení jsou tišší
     než konečná částka k úhradě, ať je na dokladu vidět, co se má zaplatit. */
  tfoot td { font-weight: 700; border-bottom: none; font-size: 13px; }
  tfoot tr:first-child td { border-top: 2px solid #0f172a; }
  tfoot tr.mezisoucet td { font-weight: 400; font-size: 12px; color: #475569; }
  .chybi { color: #94a3b8; font-style: italic; }
  .patka { margin-top: 24px; color: #64748b; font-size: 11px; }
  .tisk { margin-bottom: 20px; }
  .tisk button {
    font: inherit; padding: 8px 14px; border-radius: 6px; border: 1px solid #0f172a;
    background: #0f172a; color: #fff; cursor: pointer;
  }
  @media print { .tisk { display: none; } body { padding: 0; } }
</style>
</head>
<body>
  <div class="navrh" aria-hidden="true">NÁVRH – UKÁZKA</div>
  <div class="obsah">
    <div class="tisk"><button onclick="window.print()">Uložit jako PDF / vytisknout</button></div>
    <div class="stitek">NÁVRH – UKÁZKA (není daňový doklad)</div>

    <h1>Podklad k fakturaci za pronájem ledu</h1>
    <div class="podnadpis">Období: ${esc(obdobi)} &middot; Vystaveno: ${esc(vystaveno)}</div>

    <div class="strany">
      <div class="strana">
        <h2>Dodavatel</h2>
        <div class="jmeno">${esc(BRAND.billing.name)}</div>
        ${dodavatelRadky}
      </div>
      <div class="strana">
        <h2>Odběratel</h2>
        <div class="jmeno">${esc(subject.name)}</div>
        <div>${esc(subject.address || 'Adresa neuvedena')}</div>
        <div>${subject.ico ? 'IČO: ' + esc(subject.ico) : 'IČO neuvedeno'}</div>
        <div>${subject.dic ? 'DIČ: ' + esc(subject.dic) : ''}</div>
      </div>
    </div>

    <table>
      <thead>
        <tr>
          <th>Datum</th><th>Čas</th><th>Akce / dráha</th><th>Objednal</th>
          <th class="cislo">Hodiny</th><th class="cislo">Sazba</th><th class="cislo">Cena</th>
        </tr>
      </thead>
      <tbody>
        ${radky || '<tr><td colspan="7">V tomto období nejsou žádné účtovatelné rezervace.</td></tr>'}
      </tbody>
      <tfoot>
        <tr class="mezisoucet">
          <td colspan="4">Mezisoučet</td>
          <td class="cislo">${esc(fmtHodin(totalHours))}</td>
          <td class="cislo"></td>
          <td class="cislo">${esc(fmtKc(mezisoucet))}</td>
        </tr>
        ${zaokrouhleni !== 0 ? `
        <tr class="mezisoucet">
          <td colspan="6">Zaokrouhlení na celé koruny</td>
          <td class="cislo">${zaokrouhleni > 0 ? '+' : ''}${esc(fmtKc(zaokrouhleni))}</td>
        </tr>` : ''}
        <tr>
          <td colspan="6">Celkem k úhradě</td>
          <td class="cislo">${esc(fmtKc(kUhrade))}</td>
        </tr>
      </tfoot>
    </table>

    <div class="patka">
      Ukázka podkladu z rezervačního systému — bez čísla faktury, DPH a dalších zákonných
      náležitostí. Slouží ke kontrole rozsahu a částek, ne k úhradě.
    </div>
  </div>
</body>
</html>`;
}

/**
 * Otevře podklad v novém okně a rovnou nabídne tisk (odtud „Uložit jako PDF").
 * Vrací false, když okno zablokoval blokovač vyskakovacích oken.
 */
export function openInvoiceDraft(draft: InvoiceDraft): boolean {
  // HTML sestavujeme PŘED otevřením okna: kdyby na rozbitém datu spadl format(),
  // zůstalo by uživateli viset prázdné okno.
  const html = buildHtml(draft);

  // Pozor na windowFeatures: s „noopener" vrací window.open podle specifikace null,
  // takže by se podklad nikdy nevykreslil. Obsah je náš a ve stejném originu.
  const okno = window.open('', '_blank', 'width=900,height=1000');
  if (!okno) return false;

  okno.document.write(html);
  okno.document.close();
  okno.focus();

  // Tisk až po vykreslení, ať v PDF nechybí styly. Uživatel mohl okno mezitím zavřít.
  setTimeout(() => {
    try {
      if (!okno.closed) okno.print();
    } catch {
      /* zavřené okno nebo blokovaný tisk — podklad je vykreslený, vytiskne se ručně */
    }
  }, 250);
  return true;
}
