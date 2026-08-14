import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { BRAND } from '@/config/brand';
import { spaydQrSvg } from '@/lib/spayd';
import { otevriTiskovouStranku } from '@/lib/tiskoveOkno';
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

/**
 * Fakturační údaje haly pro podklad. Berou se z `billing_settings`, ne z `BRAND` —
 * riziko 5 v plánu: doklad musí ukazovat, co je nastavené, ne co je zadrátované
 * v konfiguraci frontendu. `BRAND` zůstává jako záloha, dokud nastavení nikdo
 * nevyplnil (typicky čerstvá databáze).
 */
export interface InvoiceBilling {
  supplier_name?: string | null;
  supplier_address?: string | null;
  supplier_ico?: string | null;
  supplier_dic?: string | null;
  bank_account?: string | null;
  bank_iban?: string | null;
  payment_message?: string | null;
  due_days?: number | null;
}

export interface InvoiceDraft {
  subject: InvoiceSubject;
  rows: InvoiceRow[];
  periodFrom: Date;
  periodTo: Date;
  billing?: InvoiceBilling | null;
}

/**
 * Účet, na který se vykreslí QR, když v nastavení žádný není.
 *
 * Samé nuly schválně: je to platný IBAN (projde mod-97, jinak by QR vůbec
 * nevzniklo), ale pro ČLOVĚKA na první pohled nesmyslný. Pro stroj nesmyslný
 * NENÍ — kontrolní součet projde a 0800 je reálná banka, takže čtečka QR nic
 * nepozná. Nezaměnitelnost stojí na varováních na stránce a na zprávě „NAVRH -
 * neplatit" uvnitř QR, ne na tom čísle samotném. Odpovídající české číslo účtu
 * `0000000000/0800` naopak neprojde kontrolou mod-11 ČNB, takže ruční opsání
 * banka odmítne. V ostrém provozu se sem nikdy nedostane, protože `issue_invoice`
 * vystavit doklad bez bankovního spojení odmítne; tohle je JEN pro podklad,
 * který se nikam neposílá a nese vodoznak „NÁVRH – UKÁZKA".
 */
export const DEMO_IBAN = 'CZ6108000000000000000000';
export const DEMO_UCET = '0000000000/0800';

/**
 * Ochrana proti rozbití stránky uživatelským textem (názvy akcí, adresy).
 * Exportované, protože týž doklad tiskne i `invoicePrint.ts` — dvě kopie
 * escapovací funkce jsou přesně ten způsob, jak jedna z nich časem zaostane.
 */
export function esc(value: unknown): string {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * Sestaví HTML podkladu. Exportované kvůli testům: podklad tiskne částky, QR
 * platbu a DEMO účet, a to jsou věci, které se musí dát ověřit bez prohlížeče.
 */
export function sestavPodklad({ subject, rows, periodFrom, periodTo, billing }: InvoiceDraft): string {
  // Součet je PŘESNÝ součet tištěných řádků (viz src/lib/money.ts). Na celé
  // koruny se zaokrouhluje stupňovitě až u částky k úhradě, a to z TÉHOŽ
  // kvantizovaného mezisoučtu, který je vytištěný — proto „součet sloupce ==
  // mezisoučet" i „mezisoučet + zaokrouhlení == k úhradě" platí triviálně,
  // ne shodou okolností. Zaokrouhlovací rozdíl je vidět vlastním řádkem.
  const mezisoucet = sumKc(rows.map((r) => r.amount));
  const zaokrouhleni = roundingDiff(mezisoucet);
  const kUhrade = roundCzk(mezisoucet);
  const totalHours = sumHodin(rows.map((r) => r.hours));
  const dnes = new Date();
  const vystaveno = format(dnes, 'd. M. yyyy', { locale: cs });
  // Splatnost podle nastavení haly (výchozí 14 dní, jako `billing_settings.due_days`).
  const dnuSplatnosti = billing?.due_days ?? 14;
  const splatnost = format(
    new Date(dnes.getFullYear(), dnes.getMonth(), dnes.getDate() + dnuSplatnosti),
    'd. M. yyyy', { locale: cs },
  );
  const obdobi = `${format(periodFrom, 'd. M. yyyy', { locale: cs })} – ${format(periodTo, 'd. M. yyyy', { locale: cs })}`;

  // Dokud klient nedodá své údaje, radši je netiskneme, než aby na ukázce svítilo
  // „IČO — doplnit". Přednost mají údaje z `billing_settings` před `BRAND`.
  const vyplneno = (v?: string | null) => (v && !/doplnit/i.test(v) ? v : null);
  //
  // Záloha na `BRAND` je VŠECHNO NEBO NIC. Po polích to byla past: hala s vyplněným
  // jménem a prázdnou adresou by vytiskla svoje jméno nad cizí adresou a cizím IČO.
  // Dnes to nevadí jen proto, že `BRAND.billing` má všude „doplnit" a filtr to
  // zahodí — jenže `brand.ts` příštího čtenáře vyzývá, ať tam doplní skutečné
  // údaje. To je přesně riziko 5 z plánu, jen o patro níž.
  const zNastaveni = vyplneno(billing?.supplier_name)
    ? {
        name: vyplneno(billing?.supplier_name)!,
        address: vyplneno(billing?.supplier_address),
        ico: vyplneno(billing?.supplier_ico),
        dic: vyplneno(billing?.supplier_dic),
      }
    : null;
  const dodavatel = zNastaveni ?? {
    name: BRAND.billing.name,
    address: vyplneno(BRAND.billing.address),
    ico: vyplneno(BRAND.billing.ico),
    dic: vyplneno(BRAND.billing.dic),
  };
  const dodavatelNazev = dodavatel.name;
  const dodavatelRadky = [
    dodavatel.address,
    dodavatel.ico ? `IČO: ${dodavatel.ico}` : null,
    dodavatel.dic ? `DIČ: ${dodavatel.dic}` : null,
  ].filter(Boolean).map((r) => `<div>${esc(r)}</div>`).join('')
    || '<div class="chybi">Fakturační údaje provozovatele zatím nejsou vyplněné.</div>';

  // ---- Platební údaje a QR ----------------------------------------------------
  //
  // TŘI STAVY, A KAŽDÝ MUSÍ BÝT POCTIVÝ. Původní verze měla `jeDemoUcet` odvozené
  // jen z IBANu, kdežto číslo účtu padalo na DEMO samostatně — při „IBAN vyplněný,
  // číslo účtu prázdné" (což formulář uložit dovolí) tiskl podklad VYMYŠLENÉ číslo
  // účtu bez jediného varování. Kdo platí převodem, opíše si ho.
  //
  //   1. nevyplněno nic   → DEMO účet i DEMO IBAN, QR se vykreslí, varování svítí
  //   2. IBAN vyplněný    → skutečný IBAN a QR; chybějící číslo účtu se NEVYMÝŠLÍ,
  //                         tiskne se „—" (tak to dělá i vystavený doklad)
  //   3. jen číslo účtu   → skutečné číslo účtu, ale ŽÁDNÉ QR. Dopočítat IBAN by
  //                         šlo (`iban.ts`), jenže rozhodnutí A4 žádá, aby dopočet
  //                         admin potvrdil — QR na nepotvrzený účet je přesně
  //                         riziko 4 z plánu („peníze jinam, zjistí se po týdnech").
  const ibanZNastaveni = vyplneno(billing?.bank_iban);
  const ucetZNastaveni = vyplneno(billing?.bank_account);
  const nicNeniVyplneno = !ibanZNastaveni && !ucetZNastaveni;

  const iban = ibanZNastaveni ?? (nicNeniVyplneno ? DEMO_IBAN : null);
  const ucet = ucetZNastaveni ?? (nicNeniVyplneno ? DEMO_UCET : null);
  const jeDemoUcet = nicNeniVyplneno;

  let qr = '';
  if (iban) {
    try {
      qr = spaydQrSvg({
        iban,
        amount: kUhrade,
        // Variabilní symbol podklad nemá: číslo se přiděluje až vystavením, a bez
        // něj by platba stejně nešla spárovat. Zpráva to říká rovnou, ať je to
        // vidět i tomu, kdo kód jen naskenuje a dál se nedívá.
        //
        // Prefix stojí 17 z 60 znaků, které SPAYD na zprávu má — na text
        // z nastavení tedy zbyde 42 a delší se ořízne. Je to vědomá výměna:
        // varování je důležitější než celá zpráva pro příjemce, a protože je
        // vpředu, ořízne se vždycky ta zpráva, ne ono.
        message: `NAVRH - neplatit; ${vyplneno(billing?.payment_message) ?? 'Pronajem ledove plochy'}`,
      });
    } catch {
      // Neplatný IBAN z nastavení — radši bez QR než QR mířící neznámo kam.
      qr = '';
    }
  }

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
<title>Faktura (návrh) — ${esc(subject.name)}</title>
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
  .cislo-dokladu { font-size: 16px; color: #475569; margin-bottom: 16px; }
  .cislo-navrh { font-style: italic; color: #94a3b8; }
  .udaje { display: flex; gap: 32px; margin-bottom: 20px; padding: 10px 0; border-top: 1px solid #e2e8f0; border-bottom: 1px solid #e2e8f0; }
  .udaje div span { display: block; font-size: 10px; text-transform: uppercase; letter-spacing: .04em; color: #64748b; }
  .udaje div b { font-size: 13px; }
  .platba { margin-top: 20px; padding: 12px; background: #f8fafc; border-radius: 6px; display: flex; gap: 16px; align-items: flex-start; justify-content: space-between; }
  .platba-text { flex: 1; }
  .platba h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; margin: 0 0 6px; }
  /* Varování u DEMO účtu musí být vidět i v tisku — proto rámeček, ne jen barva. */
  .neplatit { margin-top: 8px; padding: 6px 8px; border: 1px solid #b45309; border-radius: 4px; color: #b45309; font-weight: 600; }
  .demo-ucet { margin-top: 8px; padding: 6px 8px; border: 1px solid #dc2626; border-radius: 4px; color: #dc2626; font-weight: 600; }
  /* QR pod ~25 mm už čtečky z papíru nepřečtou. */
  .qr { text-align: center; }
  .qr svg { width: 30mm; height: 30mm; display: block; }
  .qr-popis { font-size: 10px; color: #64748b; margin-top: 2px; }
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

    <h1>Faktura za pronájem ledu</h1>
    <!-- ČÍSLO SE TU NEPŘIDĚLUJE, a je to podstatné: číselná řada musí být souvislá
         bez děr (spec, bod 4), takže číslo dostane doklad až vystavením. Kdyby si
         ho bral i podklad, každé kliknutí na náhled by spálilo jedno číslo. -->
    <div class="cislo-dokladu">č. <span class="cislo-navrh">přidělí se vystavením</span></div>

    <div class="udaje">
      <div><span>Datum vystavení</span><b>${esc(vystaveno)}</b></div>
      <div><span>Datum splatnosti</span><b>${esc(splatnost)}</b></div>
      <div><span>Období plnění</span><b>${esc(obdobi)}</b></div>
    </div>

    <div class="strany">
      <div class="strana">
        <h2>Dodavatel</h2>
        <div class="jmeno">${esc(dodavatelNazev)}</div>
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

    <div class="platba">
      <div class="platba-text">
        <h2>Platební údaje</h2>
        <div>Číslo účtu: <b>${esc(ucet ?? '—')}</b></div>
        <div>IBAN: <b>${esc(iban ?? '—')}</b></div>
        <div>Variabilní symbol: <b>přidělí se vystavením</b></div>
        <div class="neplatit">
          ⚠️ Podle tohoto podkladu se NEPLATÍ. Nemá přidělené číslo ani variabilní
          symbol, takže platbu nejde spárovat. Závazný je až vystavený doklad.
        </div>
        ${jeDemoUcet ? `
        <div class="demo-ucet">
          ⚠️ DEMO ÚČET — v nastavení haly zatím žádné bankovní spojení není.
          Číslo účtu i QR jsou vymyšlené. V ostrém provozu se vezmou
          z Nastavení → Fakturace.
        </div>` : ''}
        ${!iban && ucet ? `
        <div class="demo-ucet">
          QR platba se nevykreslila: v nastavení chybí IBAN. Doplň ho
          v Nastavení → Fakturace (dopočet z čísla účtu tam potvrdíš).
        </div>` : ''}
      </div>
      ${qr ? `<div class="qr">${qr}<div class="qr-popis">QR${jeDemoUcet ? ' (DEMO)' : ''} — jen náhled</div></div>` : ''}
    </div>

    <div class="patka">
      Ukázka podkladu z rezervačního systému — nemá přidělené číslo faktury ani další
      zákonné náležitosti. Slouží ke kontrole rozsahu a částek, ne k úhradě.
    </div>
  </div>
</body>
</html>`;
}

/**
 * Otevře podklad v novém okně a rovnou nabídne tisk (odtud „Uložit jako PDF").
 * Vrací false, když okno zablokoval blokovač vyskakovacích oken.
 *
 * Otevírání i spuštění tisku dělá `tiskoveOkno.ts`. Dřív to bylo tady a volalo
 * `okno.print()` z tohohle vlákna — druhé generování v jedné session tím zamrzlo
 * hlavní vlákno appky (P0, 14. 8. 2026).
 */
export function openInvoiceDraft(draft: InvoiceDraft): boolean {
  // HTML sestavujeme PŘED otevřením okna: kdyby na rozbitém datu spadl format(),
  // zůstalo by uživateli viset prázdné okno.
  return otevriTiskovouStranku(sestavPodklad(draft));
}
