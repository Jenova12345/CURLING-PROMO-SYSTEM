import { useEffect, useMemo, useState } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Switch } from '@/components/ui/switch';
import { Checkbox } from '@/components/ui/checkbox';
import { Textarea } from '@/components/ui/textarea';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/components/ui/use-toast';
import { useBillingSettings, type BillingSettingsUpdate, type VatMode } from '@/hooks/useBillingSettings';
import { formatujIban, ibanZUctu, overIban } from '@/lib/iban';

// Fakturační nastavení haly. Celý obsah je citlivý (IBAN, IČO), takže tahle karta
// se vykresluje jen adminovi — stránka Nastavení je za `isAdmin` a data hlídá RLS.

const REZIMY_DPH: [VatMode, string][] = [
  ['neplatce', 'Neplátce DPH'],
  ['identifikovana_osoba', 'Identifikovaná osoba (má DIČ, tuzemsku fakturuje bez DPH)'],
  ['platce', 'Plátce DPH'],
];

/** Prázdný řetězec z formuláře znamená v databázi NULL, ne „". */
const naNull = (v: string): string | null => (v.trim() ? v.trim() : null);

type Text = string;

export function BillingSettingsCard() {
  const { toast } = useToast();
  const { settings, isLoading, error, updateBillingSettings, isSaving } = useBillingSettings();

  // Dodavatel
  const [nazev, setNazev] = useState<Text>('');
  const [pravniForma, setPravniForma] = useState<Text>('');
  const [adresa, setAdresa] = useState<Text>('');
  const [ico, setIco] = useState<Text>('');
  const [dic, setDic] = useState<Text>('');
  const [rejstrik, setRejstrik] = useState<Text>('');

  // Banka
  const [ucet, setUcet] = useState<Text>('');
  const [iban, setIban] = useState<Text>('');
  const [bic, setBic] = useState<Text>('');
  const [zprava, setZprava] = useState<Text>('');
  const [ibanPotvrzen, setIbanPotvrzen] = useState(false);

  // Doklad
  const [rezimDph, setRezimDph] = useState<VatMode>('neplatce');
  const [splatnost, setSplatnost] = useState<Text>('14');
  const [oddeleneRady, setOddeleneRady] = useState(false);
  const [prefix, setPrefix] = useState<Text>('curling');

  // Automatika
  const [automatika, setAutomatika] = useState(false);
  const [rovnouVystavovat, setRovnouVystavovat] = useState(false);
  const [mesicniDen, setMesicniDen] = useState<Text>('1');
  const [mesicniHodina, setMesicniHodina] = useState<Text>('6');
  const [denniHodina, setDenniHodina] = useState<Text>('6');
  const [jenSchvalene, setJenSchvalene] = useState(true);

  useEffect(() => {
    if (!settings) return;
    setNazev(settings.supplier_name ?? '');
    setPravniForma(settings.supplier_legal_form ?? '');
    setAdresa(settings.supplier_address ?? '');
    setIco(settings.supplier_ico ?? '');
    setDic(settings.supplier_dic ?? '');
    setRejstrik(settings.supplier_registry ?? '');
    setUcet(settings.bank_account ?? '');
    setIban(settings.bank_iban ?? '');
    setBic(settings.bank_bic ?? '');
    setZprava(settings.payment_message ?? '');
    setRezimDph(settings.vat_mode);
    setSplatnost(String(settings.due_days));
    setOddeleneRady(settings.separate_series);
    setPrefix(settings.file_prefix);
    setAutomatika(settings.automation_enabled);
    setRovnouVystavovat(settings.auto_issue);
    setMesicniDen(String(settings.monthly_run_day));
    setMesicniHodina(String(settings.monthly_run_hour));
    setDenniHodina(String(settings.daily_run_hour));
    setJenSchvalene(settings.invoice_only_approved);
    // Uložený IBAN je už jednou potvrzený; znovu se ptáme až při změně.
    setIbanPotvrzen(true);
  }, [settings]);

  // Dopočet IBANu z čísla účtu. Schválně se NEZAPISUJE do pole automaticky —
  // admin ho musí vidět a potvrdit. Špatný IBAN pošle peníze jinam a zjistí se
  // to po týdnech, až se nikdo neozve s platbou.
  const dopocet = useMemo(() => ibanZUctu(ucet), [ucet]);
  const ibanSeLisi = !!dopocet.iban && dopocet.iban !== iban.replace(/\s/g, '').toUpperCase();
  const ibanJeNeplatny = !!iban.trim() && !overIban(iban);

  const prevzitDopocet = () => {
    if (!dopocet.iban) return;
    setIban(dopocet.iban);
    setIbanPotvrzen(false);   // převzetí není potvrzení — to je zvlášť, vědomě
  };

  const nutnePotvrdit = !!iban.trim() && !ibanPotvrzen;

  // Číslo účtu vyplněné, ale nerozluštitelné → na doklad by se vytisklo jak je.
  const ucetJeNeplatny = !!dopocet.chyba;

  // Vyplněné číslo účtu, jehož IBAN neodpovídá tomu v poli. Kontrolní součty
  // tohle nechytí — obě hodnoty můžou být samy o sobě platné a přesto patřit
  // jinam. Proto to blokuje uložení, ne jen upozorňuje.
  const dvojiceSeRozchazi = !!ucet.trim() && !!iban.trim() && ibanSeLisi;

  const uloz = async () => {
    if (!settings) {
      toast({ title: 'Nastavení se nenačetlo', description: 'Zkus stránku znovu načíst.', variant: 'destructive' });
      return;
    }
    if (ucetJeNeplatny) {
      toast({
        title: 'Číslo účtu není v pořádku',
        description: dopocet.chyba,
        variant: 'destructive',
      });
      return;
    }
    if (dvojiceSeRozchazi) {
      toast({
        title: 'Číslo účtu a IBAN si neodpovídají',
        description: 'Z čísla účtu vychází jiný IBAN, než je v poli. Převezmi dopočet, nebo oprav jedno z polí — jinak by doklad a QR platba mířily jinam.',
        variant: 'destructive',
      });
      return;
    }
    if (ibanJeNeplatny) {
      toast({
        title: 'IBAN neprošel kontrolou',
        description: 'Kontrolní číslice nesedí — je v něm překlep. Oprav ho, nebo nech pole prázdné.',
        variant: 'destructive',
      });
      return;
    }
    if (nutnePotvrdit) {
      toast({
        title: 'Potvrď IBAN',
        description: 'Na tenhle účet budou zákazníci posílat peníze. Zaškrtni, že souhlasí, teprve pak půjde uložit.',
        variant: 'destructive',
      });
      return;
    }

    // Meze zrcadlí CHECKy v migraci 20260812160000_billing_settings.sql. Bez nich
    // by uživatel dostal syrovou chybu Postgresu — a protože je to jeden atomický
    // UPDATE, jedno špatné pole shodí uložení všech ostatních.
    //
    // Prázdné pole se odmítá VÝSLOVNĚ: `Number('')` je 0 a `Number.isInteger(0)`
    // je true, takže by prošlo. U splatnosti by z toho bylo „splatné ihned",
    // u dne měsíčního běhu „poslední den v měsíci" — tedy tiše zapnutá varianta,
    // kterou PM vědomě zamítl.
    const cislo = (vstup: string, popis: string, min: number, max: number): number | null => {
      const text = vstup.trim();
      if (!text) { toast({ title: `Vyplň ${popis}`, description: 'Pole nesmí zůstat prázdné.', variant: 'destructive' }); return null; }
      if (!/^\d+$/.test(text)) { toast({ title: `Neplatná hodnota: ${popis}`, description: 'Zadej celé číslo.', variant: 'destructive' }); return null; }
      const n = Number(text);
      if (n < min || n > max) {
        toast({ title: `Neplatná hodnota: ${popis}`, description: `Povolený rozsah je ${min} až ${max}.`, variant: 'destructive' });
        return null;
      }
      return n;
    };
    const dny = cislo(splatnost, 'splatnost', 0, 365);
    const den = cislo(mesicniDen, 'den měsíčního běhu', 0, 31);
    const hodina = cislo(mesicniHodina, 'hodinu měsíčního běhu', 0, 23);
    const denni = cislo(denniHodina, 'hodinu denního běhu', 0, 23);
    if (dny === null || den === null || hodina === null || denni === null) return;

    // Prefix jde do názvu souboru; DB má na něj CHECK, tak ať se o tom uživatel
    // dozví tady a ne obecnou hláškou „nepodařilo se uložit".
    if (!/^[a-z0-9_-]{1,32}$/.test(prefix.trim())) {
      toast({
        title: 'Neplatný prefix názvu souboru',
        description: 'Povolená jsou malá písmena, číslice, pomlčka a podtržítko (1–32 znaků).',
        variant: 'destructive',
      });
      return;
    }

    const zmeny: BillingSettingsUpdate = {
      supplier_name: naNull(nazev),
      supplier_legal_form: naNull(pravniForma),
      supplier_address: naNull(adresa),
      supplier_ico: naNull(ico),
      supplier_dic: naNull(dic),
      supplier_registry: naNull(rejstrik),
      // Ukládá se bez mezer, stejně jako IBAN — jinak by se „19 - 2000145399 / 0800"
      // vytisklo na doklad přesně takhle.
      bank_account: naNull(ucet.replace(/[\s\u00a0]/g, '')),
      bank_iban: iban.trim() ? iban.replace(/\s/g, '').toUpperCase() : null,
      bank_bic: naNull(bic),
      payment_message: naNull(zprava),
      vat_mode: rezimDph,
      due_days: dny,
      // Řada a formát čísla jsou v databázi svázané CHECKem — posílají se spolu,
      // aby nevznikl stav „dvě řady, ale formát je neumí odlišit".
      separate_series: oddeleneRady,
      number_format: oddeleneRady ? 'RRRRSNNN' : 'RRRRNNNN',
      file_prefix: prefix.trim(),
      automation_enabled: automatika,
      auto_issue: rovnouVystavovat,
      monthly_run_day: den,
      monthly_run_hour: hodina,
      daily_run_hour: denni,
      invoice_only_approved: jenSchvalene,
    };

    try {
      await updateBillingSettings(zmeny);
      toast({ title: 'Fakturační nastavení uloženo' });
    } catch (e) {
      toast({ title: 'Chyba', description: e instanceof Error ? e.message : '', variant: 'destructive' });
    }
  };

  // Co ještě chybí, aby šlo vystavit ostrou fakturu. Není to blokace ukládání —
  // nastavení se má dát vyplňovat postupně — ale admin musí vidět, kde stojí.
  const chybejici = [
    !nazev.trim() && 'název dodavatele',
    !adresa.trim() && 'sídlo',
    !ico.trim() && 'IČO',
    !ucet.trim() && !iban.trim() && 'bankovní účet',
    rezimDph !== 'neplatce' && !dic.trim() && 'DIČ (u plátce i identifikované osoby je povinné)',
  ].filter(Boolean) as string[];

  if (isLoading) return <Card><CardContent className="pt-6 text-muted-foreground">Načítám fakturační nastavení…</CardContent></Card>;
  if (error) {
    return (
      <Card>
        <CardHeader><CardTitle>Fakturace</CardTitle></CardHeader>
        <CardContent className="text-destructive text-sm">
          Fakturační nastavení se nepodařilo načíst. Dokud se nenačte, radši ho neukládej —
          přepsalo by se prázdnými hodnotami.
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Fakturace</CardTitle>
        <CardDescription>
          Údaje, které půjdou na doklad, a nastavení automatiky. Vyplňovat se dá postupně —
          prázdná pole nic nerozbijí, jen zatím nejde vystavit ostrá faktura.
        </CardDescription>
      </CardHeader>

      <CardContent className="space-y-6">
        {chybejici.length > 0 && (
          <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
            <strong>K vystavení faktury ještě chybí:</strong> {chybejici.join(', ')}.
          </div>
        )}

        {/* ---- Dodavatel ---- */}
        <div className="space-y-3">
          <h3 className="text-sm font-semibold">Dodavatel</h3>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="bs-nazev">Název</Label>
              <Input id="bs-nazev" value={nazev} onChange={(e) => setNazev(e.target.value)} placeholder="Curling Promo Ostrava s.r.o." />
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-forma">Právní forma</Label>
              <Input id="bs-forma" value={pravniForma} onChange={(e) => setPravniForma(e.target.value)} placeholder="s.r.o. / spolek" />
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="bs-adresa">Sídlo</Label>
              <Input id="bs-adresa" value={adresa} onChange={(e) => setAdresa(e.target.value)} placeholder="Ulice 1, 700 30 Ostrava" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-ico">IČO</Label>
              <Input id="bs-ico" value={ico} onChange={(e) => setIco(e.target.value)} inputMode="numeric" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-dic">DIČ</Label>
              <Input id="bs-dic" value={dic} onChange={(e) => setDic(e.target.value)} placeholder="CZ…" />
            </div>
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="bs-rejstrik">Zápis v rejstříku</Label>
              <Input id="bs-rejstrik" value={rejstrik} onChange={(e) => setRejstrik(e.target.value)}
                placeholder="C 12345 vedená u Krajského soudu v Ostravě" />
              <p className="text-xs text-muted-foreground">
                Náležitost dokladu podle § 435 občanského zákoníku — z IČO ji nejde odvodit.
              </p>
            </div>
          </div>
        </div>

        {/* ---- Bankovní spojení ---- */}
        <div className="space-y-3 border-t pt-4">
          <h3 className="text-sm font-semibold">Bankovní spojení</h3>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="bs-ucet">Číslo účtu</Label>
              {/* Změna čísla účtu shazuje potvrzení stejně jako změna IBANu.
                  Bez toho by šlo uložit rozpojenou dvojici: na doklad by se
                  vytiskl jeden účet a do QR platby by šel druhý. */}
              <Input id="bs-ucet" value={ucet}
                onChange={(e) => { setUcet(e.target.value); setIbanPotvrzen(false); }}
                placeholder="19-2000145399/0800" />
              {dopocet.chyba && <p className="text-xs text-destructive">{dopocet.chyba}</p>}
              {dopocet.varovani && <p className="text-xs text-amber-700">{dopocet.varovani}</p>}
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-bic">BIC / SWIFT</Label>
              <Input id="bs-bic" value={bic} onChange={(e) => setBic(e.target.value)} placeholder="GIBACZPX" />
            </div>
          </div>

          <div className="space-y-1">
            <Label htmlFor="bs-iban">IBAN <span className="text-muted-foreground">(jde do QR platby)</span></Label>
            <Input id="bs-iban" value={iban}
              onChange={(e) => { setIban(e.target.value); setIbanPotvrzen(false); }}
              placeholder="CZ65 0800 0000 1920 0014 5399" />
            {ibanJeNeplatny && (
              <p className="text-xs text-destructive">
                Kontrolní číslice nesedí — v IBANu je překlep.
              </p>
            )}
          </div>

          {dopocet.iban && ibanSeLisi && (
            <div className="rounded-md border bg-muted/40 p-3 space-y-2">
              <div className="text-sm">
                Z čísla účtu vychází IBAN <strong className="font-mono">{formatujIban(dopocet.iban)}</strong>
              </div>
              <Button type="button" size="sm" variant="outline" onClick={prevzitDopocet}>Převzít do pole</Button>
            </div>
          )}

          {/* Potvrzení je povinné a schválně samostatné. Dopočet může být správný
              a číslo účtu přesto překlep — kontrolní součet pozná jen náhodné chyby,
              ne to, že admin napsal cizí, ale platný účet. */}
          {iban.trim() && (
            <label className="flex items-start gap-2 rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
              <Checkbox checked={ibanPotvrzen} onCheckedChange={(v) => setIbanPotvrzen(v === true)} className="mt-0.5" />
              <span>
                Ověřil jsem, že <strong className="font-mono">{formatujIban(iban)}</strong> je účet haly.
                Na tenhle účet budou zákazníci posílat peníze — bez potvrzení nejde uložit.
              </span>
            </label>
          )}

          <div className="space-y-1">
            <Label htmlFor="bs-zprava">Zpráva pro příjemce</Label>
            <Input id="bs-zprava" value={zprava} onChange={(e) => setZprava(e.target.value)} placeholder="Pronájem ledové plochy" />
          </div>
        </div>

        {/* ---- Doklad ---- */}
        <div className="space-y-3 border-t pt-4">
          <h3 className="text-sm font-semibold">Doklad</h3>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label>Režim DPH</Label>
              <Select value={rezimDph} onValueChange={(v) => setRezimDph(v as VatMode)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {REZIMY_DPH.map(([v, popis]) => <SelectItem key={v} value={v}>{popis}</SelectItem>)}
                </SelectContent>
              </Select>
              {rezimDph === 'neplatce' && (
                <p className="text-xs text-muted-foreground">
                  Neplátce nesmí na dokladu uvést sazbu ani výši DPH — jinak mu vzniká povinnost daň odvést.
                </p>
              )}
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-splatnost">Splatnost (dní)</Label>
              <Input id="bs-splatnost" value={splatnost} onChange={(e) => setSplatnost(e.target.value)} inputMode="numeric" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-prefix">Prefix názvu souboru</Label>
              <Input id="bs-prefix" value={prefix} onChange={(e) => setPrefix(e.target.value)} placeholder="curling" />
              <p className="text-xs text-muted-foreground">Malá písmena, číslice, pomlčka a podtržítko.</p>
            </div>
            <div className="space-y-2">
              <Label>Číselné řady</Label>
              <div className="flex items-center gap-2">
                <Switch checked={oddeleneRady} onCheckedChange={setOddeleneRady} />
                <span className="text-sm text-muted-foreground">
                  {oddeleneRady ? 'oddělené pro komerční a klubové' : 'jedna společná řada'}
                </span>
              </div>
              <p className="text-xs text-muted-foreground">
                Formát čísla: <span className="font-mono">{oddeleneRady ? 'RRRRSNNN' : 'RRRRNNNN'}</span>
                {' '}(např. <span className="font-mono">{oddeleneRady ? '20261001' : '20260001'}</span>)
              </p>
            </div>
          </div>
        </div>

        {/* ---- Automatika ---- */}
        <div className="space-y-3 border-t pt-4">
          <h3 className="text-sm font-semibold">Automatika</h3>
          <div className="space-y-2">
            <div className="flex items-center gap-2">
              <Switch checked={automatika} onCheckedChange={setAutomatika} />
              <span className="text-sm">Automatické vystavování zapnuto</span>
            </div>
            <div className="flex items-center gap-2">
              <Switch checked={rovnouVystavovat} onCheckedChange={setRovnouVystavovat} disabled={!automatika} />
              <span className="text-sm">
                Vystavovat rovnou
                <span className="text-muted-foreground"> — vypnuto znamená, že automat vyrobí jen koncepty ke kontrole</span>
              </span>
            </div>
            <div className="flex items-center gap-2">
              <Switch checked={jenSchvalene} onCheckedChange={setJenSchvalene} />
              <span className="text-sm">Fakturovat jen schválené rezervace</span>
            </div>
          </div>

          <div className="grid gap-3 sm:grid-cols-3">
            <div className="space-y-1">
              <Label htmlFor="bs-den">Měsíční běh — den</Label>
              <Input id="bs-den" value={mesicniDen} onChange={(e) => setMesicniDen(e.target.value)} inputMode="numeric" />
              <p className="text-xs text-muted-foreground">0 = poslední den v měsíci</p>
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-hodina">Měsíční běh — hodina</Label>
              <Input id="bs-hodina" value={mesicniHodina} onChange={(e) => setMesicniHodina(e.target.value)} inputMode="numeric" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="bs-denni">Denní běh — hodina</Label>
              <Input id="bs-denni" value={denniHodina} onChange={(e) => setDenniHodina(e.target.value)} inputMode="numeric" />
            </div>
          </div>
        </div>

        {/* ---- Náhled hlavičky dokladu ---- */}
        <div className="space-y-2 border-t pt-4">
          <h3 className="text-sm font-semibold">Náhled hlavičky dokladu</h3>
          <div className="rounded-md border bg-background p-4 text-sm space-y-1">
            <div className="font-semibold">{nazev.trim() || <span className="text-muted-foreground italic">(název dodavatele)</span>}</div>
            <div>{adresa.trim() || <span className="text-muted-foreground italic">(sídlo)</span>}</div>
            <div className="text-muted-foreground">
              IČO {ico.trim() || '—'}{rezimDph !== 'neplatce' && <> · DIČ {dic.trim() || '—'}</>}
            </div>
            {rejstrik.trim() && <div className="text-xs text-muted-foreground">{rejstrik}</div>}
            <div className="pt-2">
              Účet: <span className="font-mono">{ucet.trim() || '—'}</span>
              {iban.trim() && <> · IBAN <span className="font-mono">{formatujIban(iban)}</span></>}
            </div>
            <div className="text-muted-foreground">
              Splatnost {splatnost} dní · číslo dokladu např.{' '}
              <span className="font-mono">{oddeleneRady ? '20261001' : '20260001'}</span>
            </div>
            {rezimDph === 'neplatce' && <div className="pt-1 italic">Nejsme plátci DPH.</div>}
          </div>
        </div>

        <Button onClick={uloz} disabled={isSaving || nutnePotvrdit || ibanJeNeplatny || ucetJeNeplatny || dvojiceSeRozchazi}>
          Uložit fakturační nastavení
        </Button>
        {nutnePotvrdit && (
          <p className="text-xs text-muted-foreground">Uložení je odemčené až po potvrzení IBANu.</p>
        )}
        {dvojiceSeRozchazi && (
          <p className="text-xs text-destructive">
            Číslo účtu a IBAN si neodpovídají — převezmi dopočet, nebo oprav jedno z polí.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
