import { describe, it, expect } from 'vitest';
import { vlastniZadosti, cekajiciVlastni, posledniVyrizenaVlastni, ZadostOKlub } from './vlastniZadosti';

// Reálný tvar z produkce 4. 9. 2026: dvě čekající žádosti do klubu Mladé Kameny
// od lidí, kteří členy nejsou — a zástupce klubu, který JE potvrzený člen
// a obě je díky RLS vidí.
const JA = '30e86078-5435-445b-9a87-5f0c691c388f';   // zástupce klubu, potvrzený člen
const DANIEL = 'f76424ad-3a05-43d3-8c34-5310187f59fd';
const JAKUB = '9585a60d-f120-4759-9653-c441c31fea8d';

const z = (user_id: string, status: ZadostOKlub['status'], decided_at: string | null = null) =>
  ({ user_id, status, decided_at });

describe('vlastní žádosti o klub', () => {
  const fronta = [z(DANIEL, 'ceka'), z(JAKUB, 'ceka')];

  it('cizí čekající žádost se nevydává za moji (jádro Jakubova nálezu)', () => {
    // Tohle je ta věta, kvůli které modul vznikl. Bez filtru vrátí `find`
    // Danielovu žádost a karta potvrzenému členovi tvrdí „čeká na vyřízení",
    // navíc mu schová formulář na další klub.
    expect(cekajiciVlastni(fronta, JA)).toBeUndefined();
  });

  it('vlastní čekající žádost se najde i mezi cizími', () => {
    const s_mojí = [...fronta, z(JA, 'ceka')];
    expect(cekajiciVlastni(s_mojí, JA)?.user_id).toBe(JA);
  });

  it('bez známého uživatele nepřipisuje žádnou žádost', () => {
    // Opačná výchozí hodnota (vrátit všechno) je právě ta chyba, co se opravuje.
    expect(vlastniZadosti(fronta, undefined)).toEqual([]);
    expect(cekajiciVlastni(fronta, null)).toBeUndefined();
  });

  it('poslední vyřízená je moje, ne cizí — a je opravdu ta poslední', () => {
    const seznam = [
      z(DANIEL, 'zamitnuta', '2026-09-03T10:00:00Z'),   // cizí, novější
      z(JA, 'zamitnuta', '2026-09-01T10:00:00Z'),
      z(JA, 'schvalena', '2026-09-02T10:00:00Z'),       // moje, novější z mých
    ];
    const v = posledniVyrizenaVlastni(seznam, JA);
    expect(v?.user_id).toBe(JA);
    expect(v?.status).toBe('schvalena');
  });

  it('čekající se mezi vyřízené nepočítá', () => {
    expect(posledniVyrizenaVlastni([z(JA, 'ceka')], JA)).toBeUndefined();
  });
});
