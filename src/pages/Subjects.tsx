import { useEffect, useRef, useState } from 'react';
import { Building2, Trash2, Plus, UserPlus, AlertTriangle } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter, DialogDescription,
} from '@/components/ui/dialog';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { useToast } from '@/components/ui/use-toast';
import { useAuth } from '@/contexts/AuthContext';
import { useSubjectsAdmin, type RepRow, type Subject, type RepLevel } from '@/hooks/useSubjectsAdmin';
import { parseSazba } from '@/lib/money';
import { PALETA_KLUBU } from '@/lib/barvaKlubu';
import { stavSeznamuLidi, stavUlozeniUdaju } from '@/lib/stavSubjektu';
import { cn } from '@/lib/utils';

const LEVELS: [RepLevel, string][] = [['rep', 'Správce klubu'], ['member', 'Člen']];

// Text ke každému stavu rozbalovátka. Samotné ROZHODOVÁNÍ je v
// `src/lib/stavSubjektu.ts`, protože tady by se nedalo otestovat — repo nemá
// jsdom. Tady zůstává jen překlad stavu na větu.
const HLASKY_SEZNAMU: Record<Exclude<ReturnType<typeof stavSeznamuLidi>, 'seznam'>, string> = {
  'nacita': 'Načítám lidi…',
  'chyba': 'Seznam lidí se nenačetl.',
  'nikdo-v-systemu': 'V systému zatím nikdo není.',
  'vse-prirazeno': 'Všichni už jsou přiřazeni.',
};

const Subjects = () => {
  const { toast } = useToast();
  const { isAdmin } = useAuth();
  const s = useSubjectsAdmin();
  const [createOpen, setCreateOpen] = useState(false);
  const [delSubject, setDelSubject] = useState<Subject | null>(null);

  if (!isAdmin) return <div className="p-6 text-muted-foreground">Subjekty může spravovat jen správce.</div>;

  // `instanceof Error` samo nestačí. `PostgrestError` sice od `Error` dědí, ale
  // jako TŘÍDA se konstruuje jen v cestě `.throwOnError()`; v cestě
  // `{ data, error }`, kterou používá celý tenhle hook, je to prostý objekt
  // z `JSON.parse` — má `.message`, ale `instanceof Error` na něm neplatí.
  // Dnes sem chodí jen `new Error` z mutací, ale kdo sem jednou pošle chybu
  // ze `s.chyba`, dostal by „Chyba" bez důvodu. (Nález code-review brány.)
  const popisChyby = (e: unknown): string =>
    e instanceof Error ? e.message
      : typeof e === 'object' && e !== null && typeof (e as { message?: unknown }).message === 'string'
        ? (e as { message: string }).message
        : '';
  const err = (e: unknown) => toast({ title: 'Chyba', description: popisChyby(e), variant: 'destructive' });

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2"><Building2 className="h-6 w-6" /> Subjekty</h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">Kluby a komerční zákazníci + přiřazení lidí.</p>
        </div>
        <Button onClick={() => setCreateOpen(true)}><Plus className="h-4 w-4 mr-2" /> Nový subjekt</Button>
      </div>

      {/* Bez tohohle vypadá výpadek čtení jako prázdná data: žádné subjekty,
          nikdo přiřazen, prázdné rozbalovátko „Přidat člověka…". Admin pak hlásí
          „nejde přidat člověka do klubu" a hledá chybu tam, kde není. */}
      {s.chyba && (
        <div className="flex items-start gap-2 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
          <span>
            Data se nepodařilo načíst, takže seznamy níž mohou být neúplné nebo prázdné.
            Zkus stránku znovu načíst. ({s.chyba.message})
          </span>
        </div>
      )}

      {s.isLoading ? <div className="text-muted-foreground">Načítám…</div> : (
        <div className="grid gap-4 md:grid-cols-2">
          {s.subjects.map((subj) => (
            <SubjectCard key={subj.id} subject={subj} admin={s} onDelete={() => setDelSubject(subj)} onErr={err} />
          ))}
          {/* `&& !s.chyba`: při selhání dotazu jde `isLoading` na false a `subjects`
              zůstane prázdné, takže by se pod červeným bannerem vykreslilo
              „Zatím žádné subjekty." — a admin čte to spodní. Je to táž lež,
              jakou tohle kolo zavíralo v rozbalovátku, jen o patro výš. */}
          {s.subjects.length === 0 && !s.chyba && <div className="text-muted-foreground">Zatím žádné subjekty.</div>}
        </div>
      )}

      <CreateSubjectDialog open={createOpen} onOpenChange={setCreateOpen} admin={s} onErr={err} />

      <AlertDialog open={!!delSubject} onOpenChange={(o) => !o && setDelSubject(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Smazat subjekt „{delSubject?.name}"?</AlertDialogTitle>
            <AlertDialogDescription>Subjekt se skryje (soft-delete). Existující rezervace zůstanou.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zrušit</AlertDialogCancel>
            <AlertDialogAction className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={async (e) => { e.preventDefault(); if (!delSubject) return; try { await s.deleteSubject(delSubject.id); toast({ title: 'Subjekt smazán' }); setDelSubject(null); } catch (er) { err(er); } }}>
              Smazat
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

function SubjectCard({ subject, admin, onDelete, onErr }: {
  subject: Subject; admin: ReturnType<typeof useSubjectsAdmin>; onDelete: () => void; onErr: (e: unknown) => void;
}) {
  const { toast } = useToast();
  const [rate, setRate] = useState(subject.default_rate != null ? String(subject.default_rate) : '');
  const [name, setName] = useState(subject.name);
  const [barva, setBarva] = useState(subject.barva ?? '');
  const [addUser, setAddUser] = useState('');
  const [addLevel, setAddLevel] = useState<RepLevel>('member');
  const subjectReps = admin.reps.filter((r) => r.subject_id === subject.id);
  const available = admin.profiles.filter((p) => !subjectReps.some((r) => r.user_id === p.user_id));

  const saveMeta = async () => {
    try {
      const sazba = parseSazba(rate);
      if (sazba.chyba) { onErr(new Error(sazba.chyba)); return; }
      // Barva se posílá jen u klubů — komerční subjekty ji podle zadání nemají
      // mít, ať je v kalendáři na první pohled poznat, co je klubový led.
      await admin.updateSubject({
        id: subject.id,
        fields: {
          name: name.trim() || subject.name,
          default_rate: sazba.hodnota,
          ...(subject.type === 'club' ? { barva: barva || null } : null),
        },
      });
      // ZPRÁVA ŘÍKÁ, CO SE ULOŽILO. Dřív tu stálo jen „Uloženo" — a protože
      // tohle tlačítko NEUKLÁDÁ přiřazení lidí, dostal admin potvrzení úspěchu
      // za krok, který neproběhl. Přesně tak vznikl nález „nejde přidat člověka
      // do klubu ani po kliknutí na Uložit": člověk se vybral v rozbalovátku,
      // stisklo se jediné tlačítko, které vypadá jako uložení, a systém řekl OK.
      //
      // JEDEN TOAST, NE DVA. `TOAST_LIMIT` v `use-toast.ts` je 1 a reducer dělá
      // `[nový, ...staré].slice(0, 1)`, takže druhé volání ten první vyhodí
      // dřív, než se vykreslí. Dvě volání za sebou by tu vyrobila přesně tentýž
      // tichý úspěch, jen z druhé strany: admin s vybraným člověkem by uviděl
      // varování a ŽÁDNÉ potvrzení, že se přejmenování uložilo.
      toast(stavUlozeniUdaju({ vybranyClovek: addUser }) === 'ulozeno-ale-clovek-ne'
        ? {
            title: 'Uloženo — ale jen údaje',
            description: 'Název, sazba a barva. Vybraného člověka přidáš tlačítkem „Přidat" dole.',
          }
        : { title: 'Uloženo', description: 'Název, sazba a barva.' });
    } catch (e) { onErr(e); }
  };

  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="flex items-center justify-between text-base">
          <span className="flex items-center gap-2">
            <Input value={name} onChange={(e) => setName(e.target.value)} className="h-8 max-w-[12rem]" />
            <Badge variant="secondary">{subject.type === 'club' ? 'Klub' : 'Komerční'}</Badge>
          </span>
          <Button size="icon" variant="ghost" className="h-8 w-8 text-destructive" onClick={onDelete}><Trash2 className="h-4 w-4" /></Button>
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        {subject.type === 'commercial' && (subject.ico || subject.address) && (
          <div className="text-xs text-muted-foreground">
            {subject.ico && <div>IČO {subject.ico}{subject.dic ? ` · DIČ ${subject.dic}` : ''}</div>}
            {subject.address && <div>{subject.address}</div>}
          </div>
        )}
        <div className="flex items-end gap-2">
          <div className="space-y-1">
            <Label className="text-xs">Sazba (Kč/h, nepovinné)</Label>
            <Input value={rate} onChange={(e) => setRate(e.target.value)} className="h-8 w-32" placeholder="z ceníku" inputMode="numeric" />
          </div>
          {subject.type === 'club' && (
            <div className="space-y-1">
              <Label className="text-xs" htmlFor={`barva-${subject.id}`}>Barva v kalendáři</Label>
              <div className="flex items-center gap-1.5" role="group" aria-label={`Barva klubu ${subject.name}`}>
                {/* Vlastní odstín — nativní paleta prohlížeče. Vrací vždy #rrggbb,
                    což je přesně tvar, který drží CHECK v databázi. */}
                <input
                  id={`barva-${subject.id}`}
                  type="color"
                  value={barva || '#2563eb'}
                  onChange={(e) => setBarva(e.target.value)}
                  className="h-8 w-10 cursor-pointer rounded border bg-background p-0.5"
                  aria-label={`Vlastní barva klubu ${subject.name}`}
                />
                {/* Rychlá volba z palety — stejné barvy, jaké rozdala migrace. */}
                {PALETA_KLUBU.map((b) => (
                  <button
                    key={b.hex}
                    type="button"
                    title={b.nazev}
                    aria-label={`${b.nazev} — ${subject.name}`}
                    aria-pressed={barva.toLowerCase() === b.hex}
                    onClick={() => setBarva(b.hex)}
                    className={cn(
                      'h-5 w-5 rounded-full border transition',
                      barva.toLowerCase() === b.hex && 'ring-2 ring-ring ring-offset-1',
                    )}
                    style={{ backgroundColor: b.hex }}
                  />
                ))}
                {/* Barvu musí jít i sundat: NULL je platný stav (= neutrální blok),
                    ale nativní `type="color"` prázdnou hodnotu nezná a paleta jen
                    nastavuje. Bez tohohle tlačítka by se jednou zvolená barva
                    nedala odebrat. */}
                <Button
                  size="sm"
                  variant="ghost"
                  className="h-7 px-2 text-xs"
                  disabled={!barva}
                  onClick={() => setBarva('')}
                >Bez barvy</Button>
              </div>
              {/* Bez tohohle by admin viděl u klubu bez barvy modrý čtvereček
                  (výchozí hodnota inputu), v kalendáři šedý blok — a neměl by jak
                  poznat, že barva ve skutečnosti nastavená není. */}
              {!barva && (
                <p className="text-xs text-muted-foreground">
                  Nenastaveno — v kalendáři bude neutrální šedá.
                </p>
              )}
            </div>
          )}
          {/* „Uložit údaje", ne holé „Uložit": na kartě jsou dvě nezávislá uložení
              (údaje subjektu a přiřazení lidí) a obecný popisek sváděl k tomu
              číst ho jako „ulož všechno na kartě". */}
          <Button size="sm" variant="outline" onClick={saveMeta} disabled={admin.isBusy}>Uložit údaje</Button>
        </div>

        <div className="space-y-1 border-t pt-2">
          <div className="text-xs font-medium">Přiřazení lidé</div>
          {subjectReps.length === 0 && <div className="text-xs text-muted-foreground">Nikdo přiřazen.</div>}
          {subjectReps.map((r) => (
            <RepRadek key={r.id} rep={r} admin={admin} onErr={onErr} />
          ))}
          <div className="flex items-center gap-1 pt-1">
            <Select value={addUser} onValueChange={setAddUser}>
              <SelectTrigger className="h-7 flex-1 text-xs"><SelectValue placeholder="Přidat člověka…" /></SelectTrigger>
              <SelectContent>
                {/* `s.isLoading` pokrývá jen `subjects-admin`; lidi vozí
                    samostatný dotaz, proto se jeho stav rozlišuje zvlášť.
                    Čtyři větve, protože „načítá se", „nenačetlo se" a „nikdo tu
                    není" jsou tři různé věci a splynout nesmějí. */}
                {(() => {
                  const stav = stavSeznamuLidi({
                    nacitaSe: admin.profilyNacitaji,
                    chyba: admin.chybaProfilu,
                    pocetProfilu: admin.profiles.length,
                    pocetDostupnych: available.length,
                  });
                  if (stav === 'seznam') {
                    return available.map((p) => (
                      <SelectItem key={p.user_id} value={p.user_id}>{p.full_name || p.user_id.slice(0, 8)}</SelectItem>
                    ));
                  }
                  return (
                    <div className="px-2 py-1.5 text-xs text-muted-foreground">
                      {HLASKY_SEZNAMU[stav]}
                    </div>
                  );
                })()}
              </SelectContent>
            </Select>
            <Select value={addLevel} onValueChange={(v) => setAddLevel(v as RepLevel)}>
              <SelectTrigger className="h-7 w-24 text-xs"><SelectValue /></SelectTrigger>
              <SelectContent>{LEVELS.map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}</SelectContent>
            </Select>
            {/* POPSANÉ TLAČÍTKO, NE HOLÁ IKONA. Tohle je jediný způsob, jak se
                člověk do klubu přidá, a do 14. 9. 2026 to byl bezejmenný panáček
                vedle rozbalovátka — vedle toho svítilo tlačítko „Uložit", které
                dělá něco jiného. Kdo hledal, čím přiřazení potvrdit, sáhl po tom
                druhém a dostal „Uloženo". */}
            <Button size="sm" variant="outline" className="h-7 shrink-0 px-2 text-xs" disabled={!addUser || admin.isBusy}
              aria-label={`Přidat vybraného člověka do subjektu ${subject.name}`}
              onClick={async () => {
                try {
                  // Týž fallback jako v rozbalovátku o pár řádků výš: kdo tam
                  // svítil jako zkrácené UUID, ať je pod tímtéž jménem i v toastu.
                  const vybrany = admin.profiles.find((p) => p.user_id === addUser);
                  const kdo = vybrany?.full_name || addUser.slice(0, 8);
                  await admin.addRep({ subject_id: subject.id, user_id: addUser, level: addLevel });
                  setAddUser('');
                  // Potvrzení po úspěchu tu dřív nebylo vůbec: jediným signálem
                  // bylo, že se jméno objeví v seznamu nad tím — což při pomalém
                  // refetchi vypadá, jako by se nestalo nic.
                  toast({ title: 'Přidáno', description: `${kdo} → ${subject.name}` });
                } catch (e) { onErr(e); }
              }}>
              <UserPlus className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> Přidat
            </Button>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

function CreateSubjectDialog({ open, onOpenChange, admin, onErr }: {
  open: boolean; onOpenChange: (o: boolean) => void; admin: ReturnType<typeof useSubjectsAdmin>; onErr: (e: unknown) => void;
}) {
  const { toast } = useToast();
  const [type, setType] = useState<'club' | 'commercial'>('club');
  const [name, setName] = useState(''); const [rate, setRate] = useState('');
  const [ico, setIco] = useState(''); const [dic, setDic] = useState(''); const [address, setAddress] = useState('');
  const [aresLoading, setAresLoading] = useState(false);

  const reset = () => { setType('club'); setName(''); setRate(''); setIco(''); setDic(''); setAddress(''); };

  const ares = async () => {
    const clean = ico.trim();
    if (!/^\d{8}$/.test(clean)) { onErr(new Error('IČO musí mít 8 číslic.')); return; }
    setAresLoading(true);
    try {
      // Nejdřív kontrola duplicity — stejné IČO nesmí v systému vzniknout dvakrát.
      const existing = await admin.findSubjectByIco(clean);
      if (existing) {
        toast({
          title: 'Subjekt s tímto IČO už existuje',
          description: `${existing.name} — použijte stávající záznam, nezakládejte nový.`,
        });
        return;
      }
      const d = await admin.aresLookup(clean);
      setName(d.name); setAddress(d.address); setDic(d.dic);
      toast({ title: 'Načteno z ARESu' });
    }
    catch (e) { onErr(e); } finally { setAresLoading(false); }
  };

  const submit = async () => {
    if (!name.trim()) { onErr(new Error('Vyplň název.')); return; }
    const sazba = parseSazba(rate);
    if (sazba.chyba) { onErr(new Error(sazba.chyba)); return; }
    try {
      await admin.createSubject({ type, name: name.trim(), ico: ico.trim() || undefined, dic: dic || undefined, address: address || undefined, default_rate: sazba.hodnota });
      toast({ title: 'Subjekt založen' }); reset(); onOpenChange(false);
    } catch (e) { onErr(e); }
  };

  return (
    <Dialog open={open} onOpenChange={(o) => { onOpenChange(o); if (!o) reset(); }}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>Nový subjekt</DialogTitle><DialogDescription>Klub, nebo komerční zákazník (načtení z ARESu).</DialogDescription></DialogHeader>
        <div className="space-y-3">
          <div className="flex gap-1">
            {(['club', 'commercial'] as const).map((t) => (
              <Button key={t} type="button" size="sm" variant={type === t ? 'default' : 'outline'} onClick={() => setType(t)}>{t === 'club' ? 'Klub' : 'Komerční'}</Button>
            ))}
          </div>
          {type === 'commercial' && (
            <div className="flex gap-2">
              <Input value={ico} onChange={(e) => setIco(e.target.value)} placeholder="IČO (8 číslic)" inputMode="numeric" />
              <Button type="button" variant="outline" onClick={ares} disabled={aresLoading}>{aresLoading ? '…' : 'Načíst z ARESu'}</Button>
            </div>
          )}
          <div className="space-y-1"><Label>Název</Label><Input value={name} onChange={(e) => setName(e.target.value)} /></div>
          {type === 'commercial' && (
            <>
              <div className="space-y-1"><Label>Adresa</Label><Input value={address} onChange={(e) => setAddress(e.target.value)} /></div>
              <div className="space-y-1"><Label>DIČ</Label><Input value={dic} onChange={(e) => setDic(e.target.value)} /></div>
            </>
          )}
          <div className="space-y-1"><Label>Sazba (Kč/h, nepovinné)</Label><Input value={rate} onChange={(e) => setRate(e.target.value)} placeholder="z ceníku" inputMode="numeric" /></div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Zrušit</Button>
          <Button onClick={submit} disabled={admin.isBusy || aresLoading}>Založit</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/**
 * Jeden přiřazený člověk: jeho úroveň a tlačítko na odebrání.
 *
 * ÚROVEŇ DRŽÍ LOKÁLNÍ STAV, NE SERVEROVÁ DATA. Dřív tu bylo
 * `<Select value={r.level} onValueChange={… admin.updateRep(…)}>`, tedy
 * rozbalovátko řízené přímo tím, co přišlo ze serveru. Po kliknutí na „Správce
 * klubu" se proto okamžitě vrátilo na „Člen" a drželo to tam, dokud nedoběhl
 * refetch — vypadalo to, že se změna neuložila, a admin klikal znovu.
 *
 * Je to táž vada jako tichý úspěch u tlačítka „Uložit", jen obrácená: falešné
 * SELHÁNÍ místo falešného úspěchu. Proto se hodnota přepne hned, po úspěchu se
 * potvrdí toastem, a při chybě se vrátí zpátky na to, co říká server.
 */
function RepRadek({ rep, admin, onErr }: {
  rep: RepRow; admin: ReturnType<typeof useSubjectsAdmin>; onErr: (e: unknown) => void;
}) {
  const { toast } = useToast();
  const [level, setLevel] = useState<RepLevel>(rep.level);
  // Zámek po dobu zápisu. Bez něj by stačilo, aby během letu naší mutace dorazil
  // refetch vyvolaný něčím jiným na stránce (`invalidate()` obnovuje celý
  // `subject-reps-admin`): přinesl by ještě STAROU úroveň, useEffect by ji
  // vnutil rozbalovátku a to by na okamžik skočilo zpátky. Tedy přesně ten
  // blikot, kvůli kterému tahle komponenta vznikla, jen užší.
  const zapisujeme = useRef(false);

  // Srovnat se serverem, když data dorazí jinak, než čekáme — po refetchi,
  // po cizí změně, nebo když se náš zápis neuložil. Během vlastního zápisu ne:
  // tam je pravdou to, co uživatel právě vybral.
  useEffect(() => {
    if (!zapisujeme.current) setLevel(rep.level);
  }, [rep.level]);

  const zmenUroven = async (v: RepLevel) => {
    const puvodni = level;
    setLevel(v);
    zapisujeme.current = true;
    try {
      await admin.updateRep({ id: rep.id, level: v });
      toast({
        title: 'Úroveň změněna',
        description: `${rep.member_name}: ${LEVELS.find(([k]) => k === v)?.[1] ?? v}`,
      });
    } catch (e) {
      setLevel(puvodni);   // neuložilo se — ať rozbalovátko nelže
      onErr(e);
    } finally {
      zapisujeme.current = false;
    }
  };

  return (
    <div className="flex items-center justify-between gap-2">
      <span className="truncate">{rep.member_name}</span>
      <div className="flex items-center gap-1">
        {/* `aria-label` musí nést i HODNOTU. Sám o sobě přebije jméno vybrané
            položky, takže odečítačka ohlásila „Úroveň: Jan Novák" a už ne, jestli
            je Člen nebo Správce — proti stavu před touhle dávkou to byl krok
            zpátky. `disabled` tu je ze stejného důvodu jako u koše: rychlý
            dvojklik jinak pustí dvě `updateRep` naráz a vyhraje ta, která
            commitne později, ne ta, kterou člověk vybral jako poslední. */}
        <Select value={level} onValueChange={(v) => zmenUroven(v as RepLevel)} disabled={admin.isBusy}>
          <SelectTrigger className="h-7 w-28 text-xs"
            aria-label={`Úroveň: ${rep.member_name} — ${LEVELS.find(([k]) => k === level)?.[1] ?? level}`}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>{LEVELS.map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}</SelectContent>
        </Select>
        {/* Poslední tichá mutace na stránce. Řádek po kliknutí zmizí až
            s refetchem, takže na pomalé síti vypadá odebrání stejně jako
            „nestalo se nic" — přesně ten příznak, kvůli kterému tahle
            komponenta vznikla. Jméno se bere do proměnné dřív, než řádek
            zmizí. */}
        <Button size="icon" variant="ghost" className="h-7 w-7 text-destructive"
          disabled={admin.isBusy}
          aria-label={`Odebrat ze subjektu: ${rep.member_name}`}
          onClick={async () => {
            const kdo = rep.member_name;
            try {
              await admin.removeRep(rep.id);
              toast({ title: 'Odebráno', description: `${kdo} už u subjektu není.` });
            } catch (e) { onErr(e); }
          }}>
          <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
        </Button>
      </div>
    </div>
  );
}

export default Subjects;
