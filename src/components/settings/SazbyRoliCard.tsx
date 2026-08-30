import { useEffect, useState } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/components/ui/use-toast';
import { useSazbyRoli, type AppRole } from '@/hooks/useSazbyRoli';
import { parseSazba, SAZBA_SMENY_STROP } from '@/lib/money';

// Ceník hodinových sazeb podle role (rozhodnutí PM R9, 27. 8. 2026).
// Sazby platí jednotně pro celou halu, ne per klub.
//
// Karta se vykresluje jen adminovi — stránka Nastavení je za `isAdmin` a data
// hlídá RLS. Ne-admin by tu stejně viděl prázdný seznam.

export function SazbyRoliCard() {
  const { toast } = useToast();
  const { sazby, isLoading, error, updateSazba, isSaving } = useSazbyRoli();

  // Rozepsané hodnoty formuláře, klíčované rolí. `Record`, ne pole: pořadí
  // v seznamu je věc databáze (`poradi`) a poziční mapování by po jeho změně
  // tiše uložilo sazbu trenéra jako sazbu instruktora.
  const [hodnoty, setHodnoty] = useState<Record<string, string>>({});

  // `?? ` je tu podstatné, ne opatrnost navíc. Ukládá se PO ŘÁDCÍCH a každé
  // uložení zneplatní dotaz, takže `sazby` dorazí znovu — a přepis všech polí by
  // zahodil sazby rozepsané v ostatních řádcích. `BillingSettingsCard` tenhle
  // problém nemá, protože ukládá celý formulář najednou; zavádí ho až tlačítko
  // na řádek. Cenou je, že změna od jiného admina se nepromítne do pole, do
  // kterého se už psalo — což je správně: rozepsaný text patří tomu, kdo píše.
  useEffect(() => {
    if (!sazby.length) return;
    setHodnoty((h) =>
      Object.fromEntries(sazby.map((s) => [s.role, h[s.role] ?? String(Number(s.sazba))])),
    );
  }, [sazby]);

  const uloz = async (role: AppRole, popis: string) => {
    const vstup = hodnoty[role] ?? '';

    // Prázdné pole je pro `parseSazba` platný vstup („vezmi z ceníku"), tady ale
    // ceník JE — prázdná sazba nemá kam spadnout a databáze ji odmítne jako NOT
    // NULL. Odchytáváme to dřív, ať hláška mluví o sazbě, ne o sloupci.
    if (!vstup.trim()) {
      toast({ title: `Chybí sazba: ${popis}`, description: 'Sazba nesmí zůstat prázdná.', variant: 'destructive' });
      return;
    }

    // Mez se předává do `parseSazba`, ne kontroluje až po ní. Jinak by se pro
    // vstup 60000 první ukázala hláška „nejvýš 50 000 Kč/h" — mez ceny LEDU,
    // která pro tohle pole vůbec neplatí, a uživatel by hledal chybu jinde.
    const v = parseSazba(vstup, SAZBA_SMENY_STROP);
    if (v.chyba || v.hodnota == null) {
      toast({ title: `Neplatná sazba: ${popis}`, description: v.chyba ?? 'Sazba musí být číslo.', variant: 'destructive' });
      return;
    }

    try {
      await updateSazba({ role, sazba: v.hodnota });
      toast({ title: `Sazba uložena: ${popis}` });
    } catch (e) {
      toast({ title: 'Chyba', description: e instanceof Error ? e.message : 'Uložení selhalo.', variant: 'destructive' });
    }
  };

  if (isLoading) {
    return (
      <Card>
        <CardHeader><CardTitle>Sazby podle role</CardTitle></CardHeader>
        <CardContent><div className="text-muted-foreground">Načítám…</div></CardContent>
      </Card>
    );
  }

  if (error || !sazby.length) {
    return (
      <Card>
        <CardHeader><CardTitle>Sazby podle role</CardTitle></CardHeader>
        <CardContent>
          <div className="text-muted-foreground text-sm">
            Ceník sazeb se nenačetl. Zkus stránku znovu načíst — dokud se nenačte, nejde uložit,
            aby se nepřepsal prázdnými hodnotami.
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Sazby podle role (Kč/h)</CardTitle>
        <CardDescription>
          Sazba se u směny předvyplní podle požadované role a uloží se jako snapshot — pozdější
          změna ceníku nepřepočítá směny, které už vznikly. U konkrétní směny jde sazbu pořád
          přepsat ručně. Platí jednotně pro celou halu.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {sazby.map((s) => (
          <div key={s.role} className="flex flex-wrap items-end gap-3">
            <div className="space-y-2">
              <Label htmlFor={`sazba-${s.role}`}>{s.popis}</Label>
              <Input
                id={`sazba-${s.role}`}
                className="w-32"
                inputMode="numeric"
                value={hodnoty[s.role] ?? ''}
                onChange={(e) => setHodnoty((h) => ({ ...h, [s.role]: e.target.value }))}
              />
            </div>
            <Button variant="outline" disabled={isSaving} onClick={() => uloz(s.role, s.popis)}>
              Uložit
            </Button>
            {s.poznamka && <span className="text-sm text-muted-foreground pb-2">{s.poznamka}</span>}
          </div>
        ))}
        <p className="text-sm text-muted-foreground">
          Seznam rolí je pevný. Přidat další placenou roli je rozhodnutí, ne nastavení — dělá se
          migrací, aby se nestalo, že někomu vzniknou náklady omylem.
        </p>
      </CardContent>
    </Card>
  );
}
