// Otevření tisknutelné stránky v samostatném okně — jedno místo pro podklad
// (`invoiceDraft.ts`) i pro doklad (`invoicePrint.ts`).
//
// PROČ TENHLE MODUL VZNIKL: obě cesty si to dělaly samy a obě stejně špatně.
// Druhé generování v jedné session zamrzlo hlavní vlákno appky (P0, 14. 8. 2026).
//
// DVĚ CHYBY, KTERÉ SE SEŠLY:
//
// 1) **`okno.print()` se volalo ze stacku hlavního okna.** Tiskový dialog je
//    modální a blokuje celý renderer proces — a same-origin popup otevřený
//    appkou ten proces s appkou sdílí. Volat ho odtud znamená zastavit i appku.
//    Tisk proto spouští stránka SAMA, ze svého `load`, tedy na svém vlastním
//    event loopu.
//
// 2) **Předchozí okno se nezavíralo.** Každé kliknutí nechalo viset další popup
//    se svým tiskovým kontextem; při druhém se to zaseklo natrvalo. Držíme proto
//    referenci na poslední okno a před otevřením dalšího ho zavřeme.
//
// POZOR NA BUDOUCÍ CSP (fáze E5): tisk spouští vložený `<script>` uvnitř
// vygenerované stránky. Popup dědí CSP otvírajícího dokumentu, takže přísná
// politika bez `'unsafe-inline'` ho umlčí. Nebude to tichý regres — stránka se
// vykreslí a zůstane v ní tlačítko „Uložit jako PDF", jen se dialog neotevře sám.
// Kdo bude E5 psát, ať na to myslí.

/** Co z okna doopravdy potřebujeme. Užší typ než `Window` schválně — jde otestovat. */
export interface TiskoveOkno {
  document: { write(html: string): void; close(): void };
  focus(): void;
  close(): void;
  readonly closed: boolean;
}

export type Otevirac = (url: string, cil: string, parametry: string) => TiskoveOkno | null;

const VYCHOZI_OTEVIRAC: Otevirac = (url, cil, parametry) =>
  // Bez „noopener" schválně: s ním vrací `window.open` podle specifikace null,
  // takže by se do stránky nedalo nic zapsat. Obsah je náš a ve stejném originu.
  (typeof window === 'undefined' ? null : (window.open(url, cil, parametry) as TiskoveOkno | null));

/**
 * Poslední otevřené okno. Modulová proměnná schválně: okno přežívá mezi voláními
 * a nikdo jiný než tenhle modul ho neuklidí.
 */
let posledni: TiskoveOkno | null = null;

/** Jen pro testy — ať jedno tvrzení neovlivňuje další. */
export function zapomenPosledniOkno(): void {
  posledni = null;
}

/**
 * Vloží do stránky spouštěč tisku. Běží až po `load`, aby se v PDF neztratily
 * styly, a po vytištění okno zavře — jinak by se popupy hromadily i tak.
 *
 * `onafterprint` neumí každý prohlížeč spolehlivě; když nedorazí, okno prostě
 * zůstane otevřené a uživatel ho zavře sám. To je přijatelné, protože další
 * generování ho zavře za něj.
 */
const SPOUSTEC_TISKU = `
<script>
  window.addEventListener('load', function () {
    window.addEventListener('afterprint', function () { window.close(); });
    // setTimeout(0) pustí prohlížeč dokreslit, než se otevře modální dialog.
    setTimeout(function () { window.print(); }, 0);
  });
</script>`;

/**
 * Vloží spouštěč před `</body>`. Kdyby ho tam šablona neměla, připojí ho na
 * konec — jinak by se tisk tiše nespustil a vypadalo by to jako ta samá chyba,
 * kterou tenhle modul opravuje.
 *
 * Náhrada jde přes funkci schválně: v řetězcové náhradě mají `$&`, `$1` a spol.
 * zvláštní význam, takže by budoucí `$` ve spouštěči tiše sežral kus HTML.
 */
function vlozSpoustec(html: string): string {
  if (!html.includes('</body>')) return html + SPOUSTEC_TISKU;
  return html.replace('</body>', () => `${SPOUSTEC_TISKU}</body>`);
}

/**
 * Otevře stránku k tisku. Vrací false, když okno zablokoval blokovač
 * vyskakovacích oken — volající pak uživateli řekne, co s tím.
 */
export function otevriTiskovouStranku(html: string, otevri: Otevirac = VYCHOZI_OTEVIRAC): boolean {
  // Zavřít předchozí PŘED otevřením dalšího. Bez tohohle kroku se okna hromadila
  // a druhý tisk zamrzl (P0). `closed` čteme opatrně: u zavřeného okna z jiného
  // kontextu může přístup vyhodit.
  try {
    if (posledni && !posledni.closed) posledni.close();
  } catch {
    /* okno už zavřel uživatel nebo prohlížeč — není co uklízet */
  } finally {
    posledni = null;
  }

  const okno = otevri('', '_blank', 'width=900,height=1000');
  if (!okno) return false;

  try {
    // Spouštěč patří do stránky, ne sem: `okno.print()` z tohohle vlákna by
    // zablokoval appku (viz hlavička).
    okno.document.write(vlozSpoustec(html));
    okno.document.close();
    okno.focus();
    posledni = okno;
    return true;
  } catch {
    // Když se do okna nepodařilo zapsat, ať po sobě nezůstane prázdný popup.
    try {
      okno.close();
    } catch {
      /* nic lepšího už udělat nejde */
    }
    posledni = null;
    return false;
  }
}
