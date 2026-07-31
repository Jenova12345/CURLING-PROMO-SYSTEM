import { useState } from 'react';
import { Building2, Trash2, Plus, UserPlus } from 'lucide-react';
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
import { useSubjectsAdmin, type Subject, type RepLevel } from '@/hooks/useSubjectsAdmin';

const LEVELS: [RepLevel, string][] = [['rep', 'Zástupce'], ['member', 'Člen']];

const Subjects = () => {
  const { toast } = useToast();
  const { isAdmin } = useAuth();
  const s = useSubjectsAdmin();
  const [createOpen, setCreateOpen] = useState(false);
  const [delSubject, setDelSubject] = useState<Subject | null>(null);

  if (!isAdmin) return <div className="p-6 text-muted-foreground">Subjekty může spravovat jen správce.</div>;

  const err = (e: unknown) => toast({ title: 'Chyba', description: e instanceof Error ? e.message : '', variant: 'destructive' });

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold flex items-center gap-2"><Building2 className="h-6 w-6" /> Subjekty</h1>
          <p className="text-muted-foreground mt-1 text-sm md:text-base">Kluby a komerční zákazníci + přiřazení lidí.</p>
        </div>
        <Button onClick={() => setCreateOpen(true)}><Plus className="h-4 w-4 mr-2" /> Nový subjekt</Button>
      </div>

      {s.isLoading ? <div className="text-muted-foreground">Načítám…</div> : (
        <div className="grid gap-4 md:grid-cols-2">
          {s.subjects.map((subj) => (
            <SubjectCard key={subj.id} subject={subj} admin={s} onDelete={() => setDelSubject(subj)} onErr={err} />
          ))}
          {s.subjects.length === 0 && <div className="text-muted-foreground">Zatím žádné subjekty.</div>}
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
  const [addUser, setAddUser] = useState('');
  const [addLevel, setAddLevel] = useState<RepLevel>('member');
  const subjectReps = admin.reps.filter((r) => r.subject_id === subject.id);
  const available = admin.profiles.filter((p) => !subjectReps.some((r) => r.user_id === p.user_id));

  const saveMeta = async () => {
    try {
      const r = rate.trim() ? Number(rate.replace(',', '.')) : null;
      if (r != null && (isNaN(r) || r <= 0)) { onErr(new Error('Neplatná sazba.')); return; }
      await admin.updateSubject({ id: subject.id, fields: { name: name.trim() || subject.name, default_rate: r } });
      toast({ title: 'Uloženo' });
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
          <Button size="sm" variant="outline" onClick={saveMeta} disabled={admin.isBusy}>Uložit</Button>
        </div>

        <div className="space-y-1 border-t pt-2">
          <div className="text-xs font-medium">Přiřazení lidé</div>
          {subjectReps.length === 0 && <div className="text-xs text-muted-foreground">Nikdo přiřazen.</div>}
          {subjectReps.map((r) => (
            <div key={r.id} className="flex items-center justify-between gap-2">
              <span className="truncate">{r.member_name}</span>
              <div className="flex items-center gap-1">
                <Select value={r.level} onValueChange={(v) => admin.updateRep({ id: r.id, level: v as RepLevel }).catch(onErr)}>
                  <SelectTrigger className="h-7 w-28 text-xs"><SelectValue /></SelectTrigger>
                  <SelectContent>{LEVELS.map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}</SelectContent>
                </Select>
                <Button size="icon" variant="ghost" className="h-7 w-7 text-destructive" onClick={() => admin.removeRep(r.id).catch(onErr)}><Trash2 className="h-3.5 w-3.5" /></Button>
              </div>
            </div>
          ))}
          <div className="flex items-center gap-1 pt-1">
            <Select value={addUser} onValueChange={setAddUser}>
              <SelectTrigger className="h-7 flex-1 text-xs"><SelectValue placeholder="Přidat člověka…" /></SelectTrigger>
              <SelectContent>{available.map((p) => <SelectItem key={p.user_id} value={p.user_id}>{p.full_name || p.user_id.slice(0, 8)}</SelectItem>)}</SelectContent>
            </Select>
            <Select value={addLevel} onValueChange={(v) => setAddLevel(v as RepLevel)}>
              <SelectTrigger className="h-7 w-24 text-xs"><SelectValue /></SelectTrigger>
              <SelectContent>{LEVELS.map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}</SelectContent>
            </Select>
            <Button size="icon" variant="outline" className="h-7 w-7" disabled={!addUser || admin.isBusy}
              onClick={async () => { try { await admin.addRep({ subject_id: subject.id, user_id: addUser, level: addLevel }); setAddUser(''); } catch (e) { onErr(e); } }}>
              <UserPlus className="h-3.5 w-3.5" />
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
    const r = rate.trim() ? Number(rate.replace(',', '.')) : null;
    if (r != null && (isNaN(r) || r <= 0)) { onErr(new Error('Neplatná sazba.')); return; }
    try {
      await admin.createSubject({ type, name: name.trim(), ico: ico.trim() || undefined, dic: dic || undefined, address: address || undefined, default_rate: r });
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

export default Subjects;
