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

const DAYS = [['1', 'Pondělí'], ['2', 'Úterý'], ['3', 'Středa'], ['4', 'Čtvrtek'], ['5', 'Pátek'], ['6', 'Sobota'], ['7', 'Neděle']];

const Settings = () => {
  const { toast } = useToast();
  const { isAdmin } = useAuth();
  const { settings, sheets, isLoading, updateSettings, addSheet, updateSheet, isSaving } = useSettings();

  const [club, setClub] = useState('');
  const [commercial, setCommercial] = useState('');
  const [hours, setHours] = useState<OpeningHours>({});
  const [newSheet, setNewSheet] = useState('');

  useEffect(() => {
    if (!settings) return;
    setClub(settings.club_default_rate != null ? String(settings.club_default_rate) : '');
    setCommercial(settings.commercial_default_rate != null ? String(settings.commercial_default_rate) : '');
    setHours((settings.opening_hours as OpeningHours) ?? {});
  }, [settings]);

  const err = (e: unknown) => toast({ title: 'Chyba', description: e instanceof Error ? e.message : 'Uložení selhalo.', variant: 'destructive' });

  if (!isAdmin) return <div className="p-6 text-muted-foreground">Nastavení může spravovat jen správce.</div>;

  const saveRates = async () => {
    const c = club.trim() ? Number(club.replace(',', '.')) : null;
    const k = commercial.trim() ? Number(commercial.replace(',', '.')) : null;
    if ((c != null && (isNaN(c) || c <= 0)) || (k != null && (isNaN(k) || k <= 0))) {
      toast({ title: 'Neplatná sazba', description: 'Zadej kladná čísla.', variant: 'destructive' }); return;
    }
    try { await updateSettings({ club_default_rate: c, commercial_default_rate: k }); toast({ title: 'Ceník uložen' }); }
    catch (e) { toast({ title: 'Chyba', description: e instanceof Error ? e.message : '', variant: 'destructive' }); }
  };

  const saveHours = async () => {
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
        <p className="text-muted-foreground mt-1 text-sm md:text-base">Ceník, otevírací doba a plátna.</p>
      </div>

      {isLoading ? <div className="text-muted-foreground">Načítám…</div> : (
        <>
          <Card>
            <CardHeader><CardTitle>Ceník (výchozí sazby)</CardTitle>
              <CardDescription>Použije se, pokud subjekt nemá vlastní sazbu. Sazba se u rezervace uloží jako snapshot.</CardDescription></CardHeader>
            <CardContent className="space-y-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div className="space-y-2"><Label htmlFor="rate-club">Klub (Kč/h)</Label>
                  <Input id="rate-club" value={club} inputMode="numeric" onChange={(e) => setClub(e.target.value)} /></div>
                <div className="space-y-2"><Label htmlFor="rate-com">Komerční (Kč/h)</Label>
                  <Input id="rate-com" value={commercial} inputMode="numeric" onChange={(e) => setCommercial(e.target.value)} /></div>
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
            <CardHeader><CardTitle>Plátna</CardTitle><CardDescription>Ledové plochy k rezervaci.</CardDescription></CardHeader>
            <CardContent className="space-y-3">
              {sheets.map((s) => (
                <div key={s.id} className="flex items-center gap-3">
                  <Input className="max-w-xs" defaultValue={s.name}
                    onBlur={(e) => { if (e.target.value.trim() && e.target.value !== s.name) updateSheet({ id: s.id, fields: { name: e.target.value.trim() } }).then(() => toast({ title: 'Plátno uloženo' })).catch(err); }} />
                  <div className="flex items-center gap-2">
                    <Switch checked={s.active} onCheckedChange={(v) => updateSheet({ id: s.id, fields: { active: v } }).catch(err)} />
                    <span className="text-sm text-muted-foreground">{s.active ? 'aktivní' : 'neaktivní'}</span>
                  </div>
                </div>
              ))}
              <div className="flex items-center gap-2 pt-2">
                <Input className="max-w-xs" placeholder="Název nového plátna" value={newSheet} onChange={(e) => setNewSheet(e.target.value)} />
                <Button variant="outline" disabled={!newSheet.trim() || isSaving}
                  onClick={async () => { try { await addSheet(newSheet.trim()); setNewSheet(''); toast({ title: 'Plátno přidáno' }); } catch (e) { err(e); } }}>Přidat</Button>
              </div>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
};

export default Settings;
