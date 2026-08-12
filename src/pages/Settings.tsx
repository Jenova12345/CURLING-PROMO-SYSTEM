import { useEffect, useState } from 'react';
import { Settings as SettingsIcon } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Switch } from '@/components/ui/switch';
import { useToast } from '@/components/ui/use-toast';
import { useAuth } from '@/contexts/AuthContext';
import { useSettings, type OpeningHours } from '@/hooks/useSettings';
import { parseSazba } from '@/lib/money';

const DAYS = [['1', 'Pondělí'], ['2', 'Úterý'], ['3', 'Středa'], ['4', 'Čtvrtek'], ['5', 'Pátek'], ['6', 'Sobota'], ['7', 'Neděle']];

const Settings = () => {
  const { toast } = useToast();
  const { isAdmin } = useAuth();
  const { settings, sheets, isLoading, updateSettings, addSheet, updateSheet, isSaving } = useSettings();

  const [club, setClub] = useState('');
  const [commercial, setCommercial] = useState('');
  const [training, setTraining] = useState('');
  const [tournament, setTournament] = useState('');
  const [hours, setHours] = useState<OpeningHours>({});
  const [newSheet, setNewSheet] = useState('');

  useEffect(() => {
    if (!settings) return;
    setClub(settings.club_default_rate != null ? String(settings.club_default_rate) : '');
    setCommercial(settings.commercial_default_rate != null ? String(settings.commercial_default_rate) : '');
    setTraining(settings.training_rate != null ? String(settings.training_rate) : '');
    setTournament(settings.tournament_rate != null ? String(settings.tournament_rate) : '');
    setHours((settings.opening_hours as OpeningHours) ?? {});
  }, [settings]);

  const err = (e: unknown) => toast({ title: 'Chyba', description: e instanceof Error ? e.message : 'Uložení selhalo.', variant: 'destructive' });

  if (!isAdmin) return <div className="p-6 text-muted-foreground">Nastavení může spravovat jen správce.</div>;

  const saveRates = async () => {
    // POJISTKA PROTI TICHÉMU SMAZÁNÍ CENÍKU. Prázdné pole je pro `parseSazba`
    // platný vstup („vezmi z ceníku"), takže prázdný formulář by uložil samé NULL.
    // Formulář přitom může být prázdný, aniž by to admin způsobil:
    //   • dotaz selhal → `settings` je null, ale `isLoading` už false, takže se
    //     místo „Načítám…" vykreslí prázdná pole;
    //   • po přepnutí účtu (SPA, bez reloadu) drží react-query pod klíčem
    //     ['reservation-settings'] ještě řádek předchozího uživatele, kde jsou
    //     sazby maskované na NULL — a refetch nemusí doběhnout.
    // `can_see_rates` obě situace odliší od poctivě prázdného ceníku.
    if (!settings || settings.can_see_rates !== true) {
      toast({
        title: 'Ceník se nenačetl',
        description: 'Než ho půjde uložit, musí se načíst současné hodnoty — jinak by se přepsaly prázdnými. Zkus stránku znovu načíst.',
        variant: 'destructive',
      });
      return;
    }

    // Pole se ověřují jmenovitě, ať hláška řekne, které z nich je špatně —
    // ceník má čtyři sazby a „Neplatná sazba" bez upřesnění je hádanka.
    // Klíčované, ne poziční: kdyby se pole někdy přeházela, poziční mapování
    // by tiše uložilo sazbu tréninku jako sazbu klubu. Typ `Cenik` je tu proto,
    // aby překlep v názvu sloupce neprošel — `Record<string, …>` by ho pustil.
    type Cenik = {
      club_default_rate?: number | null;
      commercial_default_rate?: number | null;
      training_rate?: number | null;
      tournament_rate?: number | null;
    };
    const pole: Array<{ sloupec: keyof Cenik; popis: string; vstup: string }> = [
      { sloupec: 'club_default_rate', popis: 'Klub — výchozí', vstup: club },
      { sloupec: 'commercial_default_rate', popis: 'Komerční akce', vstup: commercial },
      { sloupec: 'training_rate', popis: 'Trénink', vstup: training },
      { sloupec: 'tournament_rate', popis: 'Turnaj', vstup: tournament },
    ];

    const values: Cenik = {};
    for (const { sloupec, popis, vstup } of pole) {
      const v = parseSazba(vstup);
      if (v.chyba) {
        toast({ title: `Neplatná sazba: ${popis}`, description: v.chyba, variant: 'destructive' });
        return;
      }
      values[sloupec] = v.hodnota;
    }
    try { await updateSettings(values); toast({ title: 'Ceník uložen' }); }
    catch (e) { toast({ title: 'Chyba', description: e instanceof Error ? e.message : '', variant: 'destructive' }); }
  };

  const saveHours = async () => {
    // Napůl vyplněný den (jen „od" nebo jen „do") je horší než nevyplněný:
    // databáze na prázdný čas spadne technickou hláškou a kalendář by den
    // vykreslil od půlnoci. Pustíme tedy jen obě pole, nebo žádné.
    const half = DAYS.find(([d]) => { const h = hours[d]; return !!h?.open !== !!h?.close; });
    if (half) {
      toast({ title: 'Neúplná otevírací doba', description: `${half[1]}: vyplňte začátek i konec, nebo nechte obě pole prázdná.`, variant: 'destructive' });
      return;
    }
    const bad = DAYS.find(([d]) => { const h = hours[d]; return h?.open && h?.close && h.open >= h.close; });
    if (bad) { toast({ title: 'Neplatná otevírací doba', description: `${bad[1]}: konec musí být po začátku.`, variant: 'destructive' }); return; }
    try { await updateSettings({ opening_hours: hours }); toast({ title: 'Otevírací doba uložena' }); }
    catch (e) { err(e); }
  };

  const setDay = (d: string, key: 'open' | 'close', val: string) =>
    setHours((h) => ({ ...h, [d]: { open: h[d]?.open ?? '08:00', close: h[d]?.close ?? '22:00', [key]: val } }));

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div>
        <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2"><SettingsIcon className="h-6 w-6" /> Nastavení</h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">Ceník, otevírací doba a dráhy.</p>
      </div>

      {isLoading ? <div className="text-muted-foreground">Načítám…</div> : (
        <>
          <Card>
            <CardHeader><CardTitle>Ceník (výchozí sazby podle typu akce)</CardTitle>
              <CardDescription>
                Sazba se u rezervace předvyplní podle typu akce a uloží se jako snapshot (pozdější změna ceníku
                nepřepočítá starší rezervace). Vlastní sazba subjektu má přednost. Prázdné pole u tréninku
                a turnaje znamená „použij sazbu klubu".
              </CardDescription></CardHeader>
            <CardContent className="space-y-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div className="space-y-2"><Label htmlFor="rate-training">Trénink (Kč/h)</Label>
                  <Input id="rate-training" value={training} inputMode="numeric" placeholder="jako klub" onChange={(e) => setTraining(e.target.value)} /></div>
                <div className="space-y-2"><Label htmlFor="rate-tournament">Turnaj (Kč/h)</Label>
                  <Input id="rate-tournament" value={tournament} inputMode="numeric" placeholder="jako klub" onChange={(e) => setTournament(e.target.value)} /></div>
                <div className="space-y-2"><Label htmlFor="rate-com">Komerční akce (Kč/h)</Label>
                  <Input id="rate-com" value={commercial} inputMode="numeric" onChange={(e) => setCommercial(e.target.value)} /></div>
                <div className="space-y-2"><Label htmlFor="rate-club">Klub — výchozí (Kč/h)</Label>
                  <Input id="rate-club" value={club} inputMode="numeric" onChange={(e) => setClub(e.target.value)} /></div>
              </div>
              <Button onClick={saveRates} disabled={isSaving}>Uložit ceník</Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Otevírací doba</CardTitle><CardDescription>Určuje rozsah časové osy v kalendáři.</CardDescription></CardHeader>
            <CardContent className="space-y-3">
              {DAYS.map(([d, label]) => (
                <div key={d} className="flex items-center gap-3">
                  <span className="w-24 text-sm">{label}</span>
                  <Input type="time" className="w-32" value={hours[d]?.open ?? '08:00'} onChange={(e) => setDay(d, 'open', e.target.value)} />
                  <span className="text-muted-foreground">–</span>
                  <Input type="time" className="w-32" value={hours[d]?.close ?? '22:00'} onChange={(e) => setDay(d, 'close', e.target.value)} />
                </div>
              ))}
              <Button onClick={saveHours} disabled={isSaving}>Uložit otevírací dobu</Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Dráhy</CardTitle><CardDescription>Ledové plochy k rezervaci.</CardDescription></CardHeader>
            <CardContent className="space-y-3">
              {sheets.map((s) => (
                <div key={s.id} className="flex items-center gap-3">
                  <Input className="max-w-xs" defaultValue={s.name}
                    onBlur={(e) => { if (e.target.value.trim() && e.target.value !== s.name) updateSheet({ id: s.id, fields: { name: e.target.value.trim() } }).then(() => toast({ title: 'Dráha uložena' })).catch(err); }} />
                  <div className="flex items-center gap-2">
                    <Switch checked={s.active} onCheckedChange={(v) => updateSheet({ id: s.id, fields: { active: v } }).catch(err)} />
                    <span className="text-sm text-muted-foreground">{s.active ? 'aktivní' : 'neaktivní'}</span>
                  </div>
                </div>
              ))}
              <div className="flex items-center gap-2 pt-2">
                <Input className="max-w-xs" placeholder="Název nové dráhy" value={newSheet} onChange={(e) => setNewSheet(e.target.value)} />
                <Button variant="outline" disabled={!newSheet.trim() || isSaving}
                  onClick={async () => { try { await addSheet(newSheet.trim()); setNewSheet(''); toast({ title: 'Dráha přidána' }); } catch (e) { err(e); } }}>Přidat</Button>
              </div>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
};

export default Settings;
