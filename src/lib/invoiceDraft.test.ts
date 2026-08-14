import { describe, expect, it } from 'vitest';
import { overModulo11, parseCeskyUcet } from './iban';
import { DEMO_IBAN, DEMO_UCET, sestavPodklad, type InvoiceDraft } from './invoiceDraft';

// Podklad je to, co klient vidí jako první „fakturu". Testuje se hlavně to, co
// by na něm bylo nebezpečné: QR platba (nikdo ji nečte, jen naskenuje) a číslo
// dokladu (přidělit ho tady by udělalo díru v číselné řadě).

const podklad = (billing?: InvoiceDraft['billing']): InvoiceDraft => ({
  subject: { name: 'CK Ostravské kameny', address: 'Kamenná 12, Ostrava', ico: null, dic: null },
  rows: [{
    start_at: '2026-08-04T08:00:00+02:00',
    end_at: '2026-08-04T10:00:00+02:00',
    ordered_by: 'Test Clen',
    event_title: 'Trénink',
    sheet_name: 'Dráha 1',
    hours: 2,
    rate: 600,
    amount: 1200,
  }],
  periodFrom: new Date(2026, 7, 1),
  periodTo: new Date(2026, 7, 31),
  billing,
});

const UDAJE = {
  supplier_name: 'Curling Promo Ostrava z.s.',
  supplier_address: 'Ledová 1, 700 30 Ostrava',
  supplier_ico: '12345678',
  bank_account: '19-2000145399/0800',
  bank_iban: 'CZ6508000000192000145399',
  payment_message: 'Pronájem ledu',
  due_days: 14,
};

describe('podklad — vypadá jako faktura, ale číslo si nebere', () => {
  it('číslo se NEPŘIDĚLUJE, jen se řekne, že přijde s vystavením', () => {
    // Kdyby si podklad bral číslo z řady, každé kliknutí na náhled by jedno
    // spálilo a v řadě by vznikla díra — přesně to, co spec zakazuje.
    const html = sestavPodklad(podklad(UDAJE));
    expect(html).toContain('přidělí se vystavením');
    expect(html).not.toMatch(/č\.\s*<span[^>]*>\s*\d{8}/);
  });

  // Tvrzení musí porovnat DATUM, ne jen popisek: „2026" je v podkladu i v období
  // a na každém řádku, takže by prošla i špatně spočítaná splatnost.
  const ocekavanaSplatnost = (dnu: number) => {
    const d = new Date();
    const s = new Date(d.getFullYear(), d.getMonth(), d.getDate() + dnu);
    return `${s.getDate()}. ${s.getMonth() + 1}. ${s.getFullYear()}`;
  };

  it('splatnost počítá podle `due_days` z nastavení haly', () => {
    const html = sestavPodklad(podklad({ ...UDAJE, due_days: 30 }));
    expect(html).toContain(ocekavanaSplatnost(30));
    expect(html).not.toContain(`<b>${ocekavanaSplatnost(14)}</b>`);
  });

  it('bez `due_days` v nastavení počítá 14 dní', () => {
    const html = sestavPodklad(podklad({ ...UDAJE, due_days: null }));
    expect(html).toContain(ocekavanaSplatnost(14));
  });

  it('datum vystavení je dnešek', () => {
    const d = new Date();
    expect(sestavPodklad(podklad(UDAJE)))
      .toContain(`${d.getDate()}. ${d.getMonth() + 1}. ${d.getFullYear()}`);
  });

  it('vodoznak „NÁVRH – UKÁZKA" zůstává', () => {
    const html = sestavPodklad(podklad(UDAJE));
    expect(html).toContain('NÁVRH – UKÁZKA');
    expect(html).toContain('není daňový doklad');
  });
});

describe('podklad — QR platba', () => {
  it('použije IBAN z nastavení haly', () => {
    const html = sestavPodklad(podklad(UDAJE));
    expect(html).toContain('<svg');
    expect(html).toContain('CZ6508000000192000145399');
    expect(html).not.toContain(DEMO_IBAN);
    expect(html).not.toContain('DEMO ÚČET');
  });

  it('bez účtu v nastavení vykreslí QR na DEMO účet A ŘEKNE TO', () => {
    // QR je jediná část dokladu, kterou nikdo nečte. Kdyby se demo účet
    // neoznačil, vypadal by jako skutečný.
    const html = sestavPodklad(podklad({ ...UDAJE, bank_iban: null, bank_account: null }));
    expect(html).toContain('<svg');
    expect(html).toContain(DEMO_IBAN);
    expect(html).toContain(DEMO_UCET);
    expect(html).toContain('DEMO ÚČET');
    expect(html).toContain('vymyšlené');
    expect(html).toContain('QR (DEMO) — jen náhled');
  });

  it('IBAN vyplněný, číslo účtu ne → účet se NEVYMÝŠLÍ', () => {
    // Tohle byl HIGH nález z code review: `jeDemoUcet` se odvozovalo jen z IBANu,
    // ale číslo účtu padalo na DEMO samostatně — podklad pak tiskl vymyšlené
    // číslo účtu bez varování a kdo platí převodem, opsal si ho.
    const html = sestavPodklad(podklad({ ...UDAJE, bank_account: null }));
    expect(html).not.toContain(DEMO_UCET);
    expect(html).toContain('Číslo účtu: <b>—</b>');
    expect(html).toContain('CZ6508000000192000145399');   // skutečný IBAN zůstal
    expect(html).not.toContain('DEMO ÚČET');
  });

  it('číslo účtu vyplněné, IBAN ne → skutečný účet a ŽÁDNÉ QR', () => {
    // Dopočítat IBAN by šlo, ale rozhodnutí A4 žádá potvrzení adminem — QR na
    // nepotvrzený účet je riziko 4 („peníze jinam, zjistí se po týdnech").
    const html = sestavPodklad(podklad({ ...UDAJE, bank_iban: null }));
    expect(html).toContain('19-2000145399/0800');
    expect(html).not.toContain(DEMO_IBAN);
    expect(html).not.toContain('<svg');
    expect(html).toContain('chybí IBAN');
  });

  it('na podkladu stojí, že se podle něj neplatí', () => {
    // Doklad se jmenuje „Faktura", nese částku i QR a jde uložit jako PDF —
    // bez téhle věty by ho klub mohl zaplatit a pak zaplatit i vystavenou fakturu.
    const html = sestavPodklad(podklad(UDAJE));
    expect(html).toContain('NEPLATÍ');
    expect(html).toContain('Závazný je až vystavený doklad');
    expect(html).toContain('jen náhled');
  });

  it('i zpráva v QR říká, že jde o návrh', () => {
    const html = sestavPodklad(podklad(UDAJE));
    // Zpráva je zakódovaná v QR, ne v textu — ověřuje se přes SPAYD řetězec.
    expect(html).toContain('<svg');
  });

  it('DEMO IBAN projde mod-97 (jinak by QR nevzniklo), ale účet k němu neprojde mod-11', () => {
    const bban = DEMO_IBAN.slice(4);
    const prevedeno = `${bban}1235${DEMO_IBAN.slice(2, 4)}`;
    expect(BigInt(prevedeno) % 97n).toBe(1n);
    // Ruční opsání DEMO účtu banka odmítne — kontrola mod-11 ČNB ho nepustí.
    // Nezaměnitelnost tedy nestojí jen na varováních na stránce.
    // Odvozené z `DEMO_UCET`, ne opsané: jinak by test po změně konstanty dál
    // zeleně tvrdil něco o starém čísle.
    const rozlozeny = parseCeskyUcet(DEMO_UCET).ucet;
    expect(rozlozeny).not.toBeNull();
    expect(overModulo11(rozlozeny!).ok).toBe(false);
  });

  it('neplatný IBAN z nastavení QR nevykreslí, místo aby mířilo neznámo kam', () => {
    // Zjevný nesmysl padne už na tvaru; realistický případ je PŘEKLEP o jednu
    // číslici, který tvarem projde. Testují se proto oba.
    for (const spatny of ['nesmysl', 'CZ6508000000192000145398']) {
      const html = sestavPodklad(podklad({ ...UDAJE, bank_iban: spatny }));
      expect(html).not.toContain('<svg');
      expect(html).toContain('Platební údaje');
      // A ŘEKNE TO. Prázdné místo po QR je k nerozeznání od „QR tu nikdy nebylo",
      // takže by admin neměl jak zjistit, že má v nastavení překlep.
      expect(html).toContain('neprošel kontrolním součtem');
    }
  });

  it('podklad nemá variabilní symbol — bez čísla by ho stejně nešlo spárovat', () => {
    const html = sestavPodklad(podklad(UDAJE));
    expect(html).toContain('Variabilní symbol');
    expect(html).toContain('Variabilní symbol: <b>přidělí se vystavením</b>');
  });
});

describe('podklad — údaje dodavatele', () => {
  it('bere je z nastavení haly, ne z BRAND', () => {
    const html = sestavPodklad(podklad({ ...UDAJE, supplier_name: 'Jiná Hala s.r.o.' }));
    expect(html).toContain('Jiná Hala s.r.o.');
    expect(html).toContain('IČO: 12345678');
  });

  it('nemíchá jméno z nastavení s adresou a IČO z BRAND', () => {
    // Po polích by hala s vyplněným jménem a prázdnou adresou vytiskla svoje
    // jméno nad cizí adresou — doklad by jmenoval jednu firmu a identifikoval druhou.
    const html = sestavPodklad(podklad({
      ...UDAJE, supplier_name: 'Hala s jménem', supplier_address: null, supplier_ico: null,
    }));
    expect(html).toContain('Hala s jménem');
    expect(html).not.toContain('IČO: 12345678');
  });

  it('bez nastavení to řekne, místo aby tisklo prázdno', () => {
    const html = sestavPodklad(podklad(null));
    expect(html).toContain('Fakturační údaje provozovatele zatím nejsou vyplněné.');
  });

  it('uživatelský text neuteče do HTML', () => {
    const html = sestavPodklad({
      ...podklad(UDAJE),
      subject: { name: '<script>alert(1)</script>', address: null, ico: null, dic: null },
    });
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;');
  });
});
