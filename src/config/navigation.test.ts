import { describe, expect, it } from 'vitest';
import { NAV_ITEMS, filterNavItemsByRoles } from './navigation';

const cesty = (roles: string[], jeZastupce = false) =>
  filterNavItemsByRoles(NAV_ITEMS, roles, jeZastupce).map((i) => i.path);

describe('filterNavItemsByRoles — Žádosti pro zástupce klubu', () => {
  it('správce haly „Žádosti" vidí (beze změny)', () => {
    expect(cesty(['admin'])).toContain('/requests');
  });

  it('správce klubu bez role admin „Žádosti" TAKY vidí', () => {
    expect(cesty(['hobby_player'], true)).toContain('/requests');
  });

  it('řadový člen „Žádosti" nevidí', () => {
    expect(cesty(['hobby_player'], false)).not.toContain('/requests');
  });

  it('ani trenér nebo instruktor je bez zástupcovství nevidí', () => {
    expect(cesty(['trainer'], false)).not.toContain('/requests');
    expect(cesty(['instructor'], false)).not.toContain('/requests');
  });

  it('zástupce klubu bez jediné aplikační role je vidí taky', () => {
    // Účet čeká na roli, ale zástupcem klubu už je — na frontu se dostat musí.
    expect(cesty([], true)).toContain('/requests');
  });

  it('„Můj klub" zůstává jen pro zástupce (vyzadujeZastupce nerozbito)', () => {
    expect(cesty(['hobby_player'], true)).toContain('/muj-klub');
    expect(cesty(['hobby_player'], false)).not.toContain('/muj-klub');
    expect(cesty(['admin'], false)).not.toContain('/muj-klub');
  });

  it('zástupcovství neotevírá nic dalšího, co je jen pro admina', () => {
    const jenAdmin = ['/subjects', '/settings', '/payouts', '/invoices', '/dues'];
    const videnyZastupcem = cesty(['hobby_player'], true);
    for (const p of jenAdmin) expect(videnyZastupcem).not.toContain(p);
  });
});
