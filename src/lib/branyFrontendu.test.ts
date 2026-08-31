// Testy HRANICE, ne logiky — stejný žánr jako `billing/hranice.test.ts`.
//
// Dvě věci z brány (ultra review, 31. 8. 2026) se odehrávají v komponentách,
// a tenhle repo nemá jsdom ani testing-library, takže se nedají „kliknout".
// Obojí je ale POŘADÍ / VĚTEV, kterou jde spolehlivě přečíst ze zdrojáku —
// a přečíst ji je nekonečně lepší než na ni nemít nic.
//
// Kdyby sem někdo přidal komponentové testy, tyhle můžou zmizet. Do té doby
// jsou to jediné pojistky, které ty dvě opravy drží.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const KOREN = join(import.meta.dirname!, '..', '..');
const cti = (relativni: string) => readFileSync(join(KOREN, relativni), 'utf8');

describe('ReservationDialog: typ akce se mění PŘED sazbou', () => {
  // `zmen_typ_akce` nastaví `rate_per_hour = NULL` a nechá trigger ocenit
  // z ceníku. Když se tedy nejdřív uloží ruční sazba a teprve pak změní typ,
  // sazba se TIŠE ZAHODÍ — uživatel vidí „Rezervace upravena" a svoje číslo
  // ve formuláři, ale fakturuje se ceníková cena.
  it('zmenTypAkce je v ukládání dřív než upravSazbuAkce', () => {
    const zdroj = cti('src/components/reservations/ReservationDialog.tsx');

    const typ = zdroj.indexOf('api.zmenTypAkce(');
    const sazba = zdroj.indexOf('api.upravSazbuAkce(');

    expect(typ, 'volání api.zmenTypAkce v dialogu zmizelo').toBeGreaterThan(-1);
    expect(sazba, 'volání api.upravSazbuAkce v dialogu zmizelo').toBeGreaterThan(-1);
    expect(typ,
      'upravSazbuAkce se volá PŘED zmenTypAkce. Změna typu přecení akci z ceníku, ' +
      'takže ručně zadaná sazba se tím zahodí — a nikde to není vidět.',
    ).toBeLessThan(sazba);
  });
});

describe('Přihlášení: nenačtený profil = zavřeno', () => {
  const auth = cti('src/contexts/AuthContext.tsx');

  it('AuthContext hlásí nedostupný profil, když ho nedostal', () => {
    // Dřív se v téhle větvi nedělo nic, takže `profile` zůstal null,
    // `cekaNaSchvaleni` vyšlo false a uživatel prošel do aplikace, ve které
    // mu RLS nic nevydá — prázdný kalendář a prázdné menu.
    expect(auth).toContain('profilNedostupny');
    expect(auth.match(/setProfilOk\(false\)/g)?.length ?? 0,
      'chybí větev, která po neúspěšném načtení profilu zavře přístup',
    ).toBeGreaterThanOrEqual(2);   // prázdná odpověď + catch
  });

  it('AppLayout na nedostupný profil reaguje vlastní obrazovkou', () => {
    const layout = cti('src/components/layout/AppLayout.tsx');
    expect(layout).toContain('profilNedostupny');
    // Musí to být větev, která vrací UI, ne jen přečtená proměnná.
    expect(layout).toMatch(/if\s*\(profilNedostupny\)/);
  });
});

describe('Trenér se nečte ze `shifts`', () => {
  // `shifts` nemá SELECT politiku pro zástupce klubu, takže mu přímý dotaz
  // vrací nula řádků BEZ CHYBY — UI pak tvrdí „trenér nepřiřazen" i po
  // úspěšném přiřazení a zástupce přiřadí znovu (druhá placená směna).
  it('useReservations čte trenéra přes RPC trener_akce', () => {
    const hook = cti('src/hooks/useReservations.ts');
    expect(hook).toContain("supabase.rpc('trener_akce'");
    // Obsazenost štábu (`shiftFill`) ze `shifts` číst SMÍ — je vypnutá pro
    // kohokoli mimo admina a staff (`enabled`). Zakázaná je jen ta cesta,
    // která hledá TRENÉRA: ta se zástupci klubu tiše rozbije.
    expect(hook,
      'hook zase hledá trenérskou směnu přímo v tabulce shifts — zástupci ' +
      'klubu se tím trenér stane neviditelným.',
    ).not.toContain("required_role");
  });

  it('přání trenéra se ukládá přes RPC, ne přímým UPDATE sloupce', () => {
    const hook = cti('src/hooks/useReservations.ts');
    expect(hook).toContain("supabase.rpc('nastav_prani_trenera'");
    expect(hook).not.toMatch(/update\(\{\s*preferovany_trener/);
  });
});
