import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { denZDb } from '@/lib/datum';
import { esc } from '@/lib/invoiceDraft';
import { fmtHodin, fmtKc, fmtSazba } from '@/lib/money';
import { spaydQrSvg } from '@/lib/spayd';
import { otevriTiskovouStranku } from '@/lib/tiskoveOkno';
import type { Invoice, InvoiceItem } from '@/hooks/useInvoices';

// Tisk VYSTAVENÉHO dokladu.
//
// ROZDÍL PROTI `invoiceDraft.ts`, který stojí vedle: tamten tiskne PODKLAD
// („NÁVRH – UKÁZKA", bez čísla, bez zákonných náležitostí). Tenhle tiskne
// DOKLAD — má číslo, variabilní symbol, splatnost a doložku o režimu DPH.
// Dva soubory schválně: kdyby to byl jeden s přepínačem, dřív nebo později
// se ukázka vytiskne jako doklad nebo naopak.
//
// ⚠️ ÚDAJE SE BEROU ZE SNAPSHOTU NA FAKTUŘE, ne z `BRAND` ani z aktuálního
// nastavení (riziko 5 v docs/etapa2-fakturace-plan.md). Doklad je obrazem stavu
// v okamžiku vystavení; kdyby si tahal dnešní údaje, změna adresy nebo účtu by
// zpětně přepsala faktury staré rok.
//
// PROČ TISK Z PROHLÍŽEČE: serverový render PDF (`pdf-lib` v Edge funkci) je
// fáze C. Tohle je cesta, která funguje bez něj — prohlížeč umí „Uložit jako
// PDF" z tiskového dialogu a výsledek má správnou diakritiku i rozvržení.

/**
 * Doložka o režimu DPH.
 *
 * POZOR NA TU NEJDRAŽŠÍ CHYBU: neplátce, který na dokladu VYČÍSLÍ daň, ji musí
 * odvést (§ 108 ZDPH). Proto tahle větev netiskne sazbu ani částku daně —
 * jen větu, že hala plátcem není. Sama věta „Nejsme plátci DPH." slovo DPH
 * obsahuje a obsahovat MUSÍ: náležitostí dokladu je sdělení režimu, zakázané
 * je vyčíslení daně.
 */
function dolozkaDph(vatMode: Invoice['vat_mode']): string {
  if (vatMode === 'neplatce') return 'Nejsme plátci DPH.';
  if (vatMode === 'identifikovana_osoba') {
    // Identifikovaná osoba má DIČ, ale v tuzemsku fakturuje bez daně (§ 6g–6l ZDPH).
    return 'Jsme identifikovaná osoba. Plnění v tuzemsku není zatíženo DPH.';
  }
  // Plátcovská větev zatím nemá co tisknout: sloupce `vat_*` na položkách jsou
  // prázdné místo, dokud nepadne odpověď na otázku Q7 (agregace daně). Radši
  // prázdno než vymyšlené číslo.
  return '';
}

function buildHtml(invoice: Invoice, items: InvoiceItem[]): string {
  // `denZDb`, ne `new Date`: holé `RRRR-MM-DD` je podle specifikace půlnoc UTC,
  // takže by se západně od Greenwiche vytisklo o den míň.
  const den = (d: string | null) => {
    const datum = denZDb(d);
    return datum ? format(datum, 'd. M. yyyy', { locale: cs }) : '—';
  };

  const dodavatel = [
    invoice.dodavatel_adresa,
    invoice.dodavatel_ico ? `IČO: ${invoice.dodavatel_ico}` : null,
    invoice.dodavatel_dic ? `DIČ: ${invoice.dodavatel_dic}` : null,
    invoice.dodavatel_rejstrik,
  ].filter(Boolean).map((r) => `<div>${esc(r)}</div>`).join('');

  const odberatel = [
    invoice.odberatel_adresa || 'Adresa neuvedena',
    invoice.odberatel_ico ? `IČO: ${invoice.odberatel_ico}` : null,
    invoice.odberatel_dic ? `DIČ: ${invoice.odberatel_dic}` : null,
  ].filter(Boolean).map((r) => `<div>${esc(r)}</div>`).join('');

  const radky = items.map((it) => {
    const cas = it.cas_od && it.cas_do
      ? `${format(new Date(it.cas_od), 'HH:mm')}–${format(new Date(it.cas_do), 'HH:mm')}`
      : '—';
    return `
      <tr>
        <td>${esc(den(it.datum))}</td>
        <td>${esc(cas)}</td>
        <td>${esc(it.popis)}</td>
        <td class="cislo">${esc(fmtHodin(Number(it.hodiny)))}</td>
        <td class="cislo">${esc(fmtSazba(Number(it.sazba)))}</td>
        <td class="cislo">${esc(fmtKc(Number(it.line_total)))}</td>
      </tr>`;
  }).join('');

  // Součty se NEPOČÍTAJÍ znovu — jsou uložené na faktuře a dopočítala je databáze
  // z položek (trigger `recalc_invoice_totals`). Přepočítat je tady v prohlížeči
  // by znamenalo druhou peněžní politiku vedle té v `money.ts`.
  const zaokrouhleni = Number(invoice.rounding_amount);
  const dolozka = dolozkaDph(invoice.vat_mode);

  // QR platba jen tehdy, když je z čeho ji sestavit. Nevykreslit ji je v pořádku
  // (platební údaje jsou na dokladu textem), ale vykreslit ji ŠPATNĚ by poslalo
  // peníze jinam — proto se chyba spolkne do „bez QR", ne do prázdného obrázku.
  //
  // Do QR jde `total_rounded`: zákazník platí zaokrouhlenou částku, ne přesný součet.
  let qr = '';
  let qrChyba = '';
  if (invoice.dodavatel_iban) {
    try {
      qr = spaydQrSvg({
        iban: invoice.dodavatel_iban,
        amount: Number(invoice.total_rounded),
        variableSymbol: invoice.variabilni_symbol,
        dueDate: denZDb(invoice.datum_splatnosti),
        recipientName: invoice.dodavatel_nazev,
        message: invoice.dodavatel_zprava,
      });
    } catch {
      // Ticho by tady bylo horší než na podkladu: `invoices.dodavatel_iban` je
      // snapshot bez CHECKu, takže vadná hodnota se do vystaveného (a tedy
      // neměnného) dokladu dostat může — a chybějící QR by vypadalo jako záměr.
      qr = '';
      qrChyba = 'QR platba se nevykreslila: IBAN na dokladu neprošel kontrolním součtem. '
        + 'Zaplať podle čísla účtu a variabilního symbolu výš.';
    }
  }

  return `<!doctype html>
<html lang="cs">
<head>
<meta charset="utf-8">
<title>Faktura ${esc(invoice.cislo ?? '')} — ${esc(invoice.odberatel_nazev ?? '')}</title>
<style>
  @page { size: A4; margin: 16mm; }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
    color: #0f172a; margin: 0; padding: 24px; font-size: 12px; line-height: 1.45;
  }
  h1 { font-size: 22px; margin: 0 0 2px; }
  .cislo-dokladu { font-size: 16px; color: #475569; margin-bottom: 20px; }
  .strany { display: flex; gap: 32px; margin-bottom: 20px; }
  .strana { flex: 1; }
  .strana h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; margin: 0 0 6px; }
  .strana .jmeno { font-weight: 700; font-size: 14px; }
  .udaje { display: flex; gap: 32px; margin-bottom: 20px; padding: 10px 0; border-top: 1px solid #e2e8f0; border-bottom: 1px solid #e2e8f0; }
  .udaje div span { display: block; font-size: 10px; text-transform: uppercase; letter-spacing: .04em; color: #64748b; }
  .udaje div b { font-size: 13px; }
  table { width: 100%; border-collapse: collapse; margin-top: 8px; }
  th, td { padding: 6px 8px; border-bottom: 1px solid #e2e8f0; text-align: left; vertical-align: top; }
  th { background: #f8fafc; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: #475569; }
  td.cislo, th.cislo { text-align: right; white-space: nowrap; }
  tfoot td { font-weight: 700; border-bottom: none; font-size: 13px; }
  tfoot tr:first-child td { border-top: 2px solid #0f172a; }
  tfoot tr.mezisoucet td { font-weight: 400; font-size: 12px; color: #475569; }
  tfoot tr.uhrada td { font-size: 16px; }
  .platba { margin-top: 20px; padding: 12px; background: #f8fafc; border-radius: 6px; display: flex; gap: 16px; align-items: flex-start; justify-content: space-between; }
  .platba-text { flex: 1; }
  /* QR se v tisku nesmí zmenšit pod ~25 mm, jinak ho čtečky z papíru nepřečtou. */
  .qr { text-align: center; }
  .qr svg { width: 30mm; height: 30mm; display: block; }
  .qr-popis { font-size: 10px; color: #64748b; margin-top: 2px; }
  .qr-chyba { margin-top: 8px; padding: 6px 8px; border: 1px solid #b45309; border-radius: 4px; color: #b45309; font-weight: 600; }
  .platba h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; margin: 0 0 6px; }
  .dolozka { margin-top: 16px; font-weight: 600; }
  .patka { margin-top: 20px; color: #64748b; font-size: 11px; }
  .tisk { margin-bottom: 20px; }
  .tisk button { font: inherit; padding: 8px 14px; border-radius: 6px; border: 1px solid #0f172a; background: #0f172a; color: #fff; cursor: pointer; }
  @media print { .tisk { display: none; } body { padding: 0; } }
</style>
</head>
<body>
  <div class="tisk"><button onclick="window.print()">Uložit jako PDF / vytisknout</button></div>

  <h1>Faktura</h1>
  <div class="cislo-dokladu">č. ${esc(invoice.cislo ?? '(koncept)')}</div>

  <div class="strany">
    <div class="strana">
      <h2>Dodavatel</h2>
      <div class="jmeno">${esc(invoice.dodavatel_nazev ?? '')}</div>
      ${dodavatel}
    </div>
    <div class="strana">
      <h2>Odběratel</h2>
      <div class="jmeno">${esc(invoice.odberatel_nazev ?? '')}</div>
      ${odberatel}
    </div>
  </div>

  <div class="udaje">
    <div><span>Datum vystavení</span><b>${esc(den(invoice.datum_vystaveni))}</b></div>
    <div><span>Datum splatnosti</span><b>${esc(den(invoice.datum_splatnosti))}</b></div>
    <div><span>Variabilní symbol</span><b>${esc(invoice.variabilni_symbol ?? '—')}</b></div>
    <div><span>Období plnění</span><b>${esc(den(invoice.obdobi_od))} – ${esc(den(invoice.obdobi_do))}</b></div>
  </div>

  <table>
    <thead>
      <tr>
        <th>Datum</th><th>Čas</th><th>Popis plnění</th>
        <th class="cislo">Hodiny</th><th class="cislo">Sazba</th><th class="cislo">Cena</th>
      </tr>
    </thead>
    <tbody>
      ${radky || '<tr><td colspan="6">Doklad nemá žádné položky.</td></tr>'}
    </tbody>
    <tfoot>
      <tr class="mezisoucet">
        <td colspan="5">Mezisoučet</td>
        <td class="cislo">${esc(fmtKc(Number(invoice.subtotal)))}</td>
      </tr>
      ${zaokrouhleni !== 0 ? `
      <tr class="mezisoucet">
        <td colspan="5">Zaokrouhlení na celé koruny</td>
        <td class="cislo">${zaokrouhleni > 0 ? '+' : ''}${esc(fmtKc(zaokrouhleni))}</td>
      </tr>` : ''}
      <tr class="uhrada">
        <td colspan="5">Celkem k úhradě</td>
        <td class="cislo">${esc(fmtKc(Number(invoice.total_rounded)))}</td>
      </tr>
    </tfoot>
  </table>

  <div class="platba">
    <div class="platba-text">
      <h2>Platební údaje</h2>
      <div>Číslo účtu: <b>${esc(invoice.dodavatel_ucet ?? '—')}</b></div>
      ${invoice.dodavatel_iban ? `<div>IBAN: <b>${esc(invoice.dodavatel_iban)}</b></div>` : ''}
      <div>Variabilní symbol: <b>${esc(invoice.variabilni_symbol ?? '—')}</b></div>
      ${invoice.dodavatel_zprava ? `<div>Zpráva pro příjemce: ${esc(invoice.dodavatel_zprava)}</div>` : ''}
      ${qrChyba ? `<div class="qr-chyba">${esc(qrChyba)}</div>` : ''}
    </div>
    ${qr ? `<div class="qr">${qr}<div class="qr-popis">QR Platba</div></div>` : ''}
  </div>

  ${dolozka ? `<div class="dolozka">${esc(dolozka)}</div>` : ''}

  <div class="patka">
    Vystaveno rezervačním systémem Curling Promo Ostrava.
  </div>
</body>
</html>`;
}

/**
 * Otevře doklad v novém okně a nabídne tisk (odtud „Uložit jako PDF").
 * Vrací false, když okno zablokoval blokovač vyskakovacích oken.
 */
export function openInvoicePrint(invoice: Invoice, items: InvoiceItem[]): boolean {
  // HTML se sestavuje PŘED otevřením okna: kdyby na rozbitém datu spadl format(),
  // zůstalo by uživateli viset prázdné okno. Zbytek řeší `tiskoveOkno.ts` —
  // včetně toho, že se předchozí okno zavře a tisk spouští stránka sama.
  return otevriTiskovouStranku(buildHtml(invoice, items));
}
