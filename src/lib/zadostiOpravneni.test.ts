import { describe, expect, it } from 'vitest';
import { smiRozhodnout } from './zadostiOpravneni';

const KLUB_A = 'aaaa-1111';
const KLUB_B = 'bbbb-2222';

describe('smiRozhodnout', () => {
  it('správce haly smí rozhodnout o čemkoli', () => {
    expect(smiRozhodnout({ subject_id: KLUB_B }, true, [])).toBe(true);
  });

  it('správce klubu smí rozhodnout o žádosti do SVÉHO klubu', () => {
    expect(smiRozhodnout({ subject_id: KLUB_A }, false, [KLUB_A])).toBe(true);
  });

  it('správce klubu NESMÍ rozhodnout o žádosti do cizího klubu', () => {
    // Přesně ten řádek, který mu RLS pouští, protože je to jeho vlastní
    // žádost — vidět ho smí, rozhodnout o něm ne.
    expect(smiRozhodnout({ subject_id: KLUB_B }, false, [KLUB_A])).toBe(false);
  });

  it('řadový člen nesmí rozhodnout o ničem', () => {
    expect(smiRozhodnout({ subject_id: KLUB_A }, false, [])).toBe(false);
  });

  it('žádost bez klubu smí posoudit jen správce haly', () => {
    expect(smiRozhodnout({ subject_id: null }, false, [KLUB_A])).toBe(false);
    expect(smiRozhodnout({ subject_id: null }, true, [])).toBe(true);
  });

  it('správce více klubů rozhoduje o obou', () => {
    expect(smiRozhodnout({ subject_id: KLUB_A }, false, [KLUB_A, KLUB_B])).toBe(true);
    expect(smiRozhodnout({ subject_id: KLUB_B }, false, [KLUB_A, KLUB_B])).toBe(true);
  });
});
