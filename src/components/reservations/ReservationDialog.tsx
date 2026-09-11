import { useEffect, useMemo, useRef, useState } from 'react';
import { format } from 'date-fns';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter,
} from '@/components/ui/dialog';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Checkbox } from '@/components/ui/checkbox';
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group';
import { Switch } from '@/components/ui/switch';
import { Minus, Plus } from 'lucide-react';
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select';
import { useToast } from '@/components/ui/use-toast';
import { sanitizeText, VALIDATION_LIMITS } from '@/lib/validation';
import { nadpisSerie, souhrnSerie } from '@/lib/serie';
import { hoursForDay } from '@/lib/openingHours';
import { parseCelkovouCenu, parseSazba } from '@/lib/money';
import type {
  Sheet, Subject, NovaFirma, Settings, CalendarReservation, BookingKind, Conflict, NahledCeny,
  BookingInput, SeriesInput, SeriesResult, Membership,
} from '@/hooks/useReservations';

const STAFF_ROLES = [
  { key: 'instructor', label: 'Instruktor' },
  { key: 'bar_staff', label: 'Obsluha baru' },
  { key: 'manager', label: 'Provozní hospoda' },
];

const KIND_LABELS: Record<BookingKind, string> = {
  training: 'Trénink',
  tournament: 'Turnaj',
  commercial: 'Komerční akce',
  maintenance: 'Údržba ledu',
};

const WEEKDAYS: [number, string][] = [
  [1, 'Po'], [2, 'Út'], [3, 'St'], [4, 'Čt'], [5, 'Pá'], [6, 'So'], [7, 'Ne'],
];

export interface ReservationApi {
  createBooking: (input: BookingInput) => Promise<{ event_id: string; reservation_ids: string[] } | unknown>;
  createSeries: (input: SeriesInput) => Promise<SeriesResult>;
  updateBooking: (args: { id: string; title?: string; note?: string | null; rate_per_hour?: number | null }) => Promise<unknown>;
  /** Přecení CELOU akci (všechny dráhy) — jen komerční akce s `event_id`. */
  upravSazbuAkce: (args: { event_id: string; sazba: number }) => Promise<unknown>;
  /** Lidé s rolí trenéra — pro nezávazné přání u tréninku (R7, varianta D). */
  treneri: Array<{ user_id: string; jmeno: string }>;
  nastavPraniTrenera: (args: { reservation_ids: string[]; user_id: string | null }) => Promise<unknown>;
  /** Přidání/ubrání dráhy u existující akce (B). */
  upravDrahyAkce: (args: { event_id: string; sheet_ids: string[] }) => Promise<unknown>;
  /** Změna typu akce s přepočtem ceny (C) — jen admin. */
  zmenTypAkce: (args: { event_id: string; typ: BookingKind }) => Promise<unknown>;
  /** Změna odběratele (firmy) na všech drahách komerční akce — jen admin. */
  zmenFirmuAkce: (args: { event_id: string; subject_id: string })
    => Promise<{ schvaleni_prerazeno?: boolean; drah?: number; firma?: string }>;
  /** Název a poznámka na VŠECH BUDOUCÍCH termínech opakované série. */
  prejmenujSerii: (args: { id: string; title?: string; note?: string | null })
    => Promise<{ zmena?: boolean; terminu?: number; akci?: number }>;
  moveBooking: (args: { id: string; start_at: string; end_at: string; sheet_id?: string }) => Promise<unknown>;
  checkConflicts: (args: { sheet_ids: string[]; start_at: string; end_at: string; kind: BookingKind; ignore_event?: string }) => Promise<Conflict[]>;
  nahledCeny: (args: { subject_id: string | null; kind: BookingKind; start_at: string; end_at: string; drah: number }) => Promise<NahledCeny | null>;
  aresLookup: (ico: string) => Promise<{ name: string; address: string; dic: string }>;
  findSubjectByIco: (ico: string) => Promise<Subject | null>;
  createSubject: (s: { name: string; ico?: string; dic?: string; address?: string }) => Promise<NovaFirma>;
  isCreating: boolean;
  isUpdating: boolean;
}

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  isAdmin: boolean;
  sheets: Sheet[];
  subjects: Subject[];
  memberships: Membership[];
  settings: Settings | null;
  defaultSheetId?: string;
  defaultStart?: Date;
  editing?: CalendarReservation | null;
  /** kolik drah drží editovaná akce (u dvou nejde měnit dráha) */
  editingLanes?: number;
  /** Dráhy, na kterých upravovaná akce běží — aby šlo přidávat a ubírat (B). */
  editingSheetIds?: string[];
  api: ReservationApi;
}

const hh = (h: number) => `${String(h).padStart(2, '0')}:00`;

function kindOf(r: CalendarReservation): BookingKind {
  const t = r.event_type;
  if (t === 'commercial' || t === 'recruitment') return 'commercial';
  if (t === 'tournament') return 'tournament';
  if (t === 'maintenance') return 'maintenance';
  return 'training';
}

export function ReservationDialog({
  open, onOpenChange, isAdmin, sheets, subjects, memberships, settings,
  defaultSheetId, defaultStart, editing, editingLanes = 1, editingSheetIds = [], api,
}: Props) {
  const { toast } = useToast();
  const isEdit = !!editing;
  // ROZSAH PŘEJMENOVÁNÍ u akce, která je součástí opakované série.
  // Výchozí je 'tato' — hromadná změna se musí zvolit vědomě, ne se stát omylem.
  const [rozsahNazvu, setRozsahNazvu] = useState<'tato' | 'serie'>('tato');
  // Volba se ukazuje jen tam, kde dává smysl: úprava akce, která do série patří.
  const jeSerie = Boolean(isEdit && editing?.series_id);

  const clubs = useMemo(() => subjects.filter((s) => s.type === 'club'), [subjects]);
  const commercials = useMemo(() => subjects.filter((s) => s.type === 'commercial'), [subjects]);

  // Kluby, za které smím rezervovat (člen i zástupce). Admin může za kterýkoli.
  const myClubs = useMemo(
    () => (isAdmin ? clubs : clubs.filter((c) => memberships.some((m) => m.subject_id === c.id))),
    [clubs, memberships, isAdmin],
  );

  const kinds: BookingKind[] = isAdmin
    ? ['training', 'tournament', 'commercial', 'maintenance']
    : ['training', 'tournament'];

  const [kind, setKind] = useState<BookingKind>('training');
  const [subjectId, setSubjectId] = useState('');
  const [sheetIds, setSheetIds] = useState<string[]>([]);
  const [date, setDate] = useState('');
  const [startHour, setStartHour] = useState(17);
  const [endHour, setEndHour] = useState(19);
  const [note, setNote] = useState('');
  const [title, setTitle] = useState('');
  const [titleTouched, setTitleTouched] = useState(false);
  const [roleCounts, setRoleCounts] = useState<Record<string, number>>({ instructor: 1, bar_staff: 0, manager: 0 });
  const [instructorsTouched, setInstructorsTouched] = useState(false);
  const [rate, setRate] = useState('');
  // JAKÁ SAZBA PŘIŠLA Z DATABÁZE.
  //
  // U pevné ceny (a u pásmové taky) je `rate_per_hour` ODVOZENÝ PRŮMĚR
  // `round(amount / hodiny, 2)` — 7 000 Kč na 13 h je 538,46. Takovou sazbu
  // `parseSazba` odmítne („v celých korunách, bez haléřů"), a protože se pole
  // předvyplňuje z rezervace, zastavila ta chyba uložení i tehdy, když admin
  // do sazby vůbec nesáhl: nešlo opravit ani překlep v názvu. Databáze přitom
  // haléře u ruční i pásmové ceny výslovně povoluje.
  const [puvodniRate, setPuvodniRate] = useState('');

  // opakování
  const [repeat, setRepeat] = useState(false);
  const [weekdays, setWeekdays] = useState<number[]>([]);
  const [until, setUntil] = useState('');

  // ARES / nová firma
  const [newFirm, setNewFirm] = useState(false);
  const [ico, setIco] = useState('');
  const [firmName, setFirmName] = useState('');
  const [firmAddress, setFirmAddress] = useState('');
  const [firmDic, setFirmDic] = useState('');
  const [aresLoading, setAresLoading] = useState(false);

  // potvrzení vědomého přebití
  const [conflicts, setConflicts] = useState<Conflict[] | null>(null);

  const { open: openHour, close: closeHour } = hoursForDay(settings?.opening_hours, date);

  // PŘEDVYPLNĚNÁ SAZBA U KLUBOVÉHO LEDU BY PÁSMOVÝ CENÍK VYPNULA.
  //
  // Formulář posílá `rate_per_hour` (řádek níž v `submit`), a trigger
  // `set_reservation_pricing` sáhne po pásmech jen tehdy, když sazba PŘIJDE
  // PRÁZDNÁ — vyplněná sazba je pro něj vědomé rozhodnutí admina a má přednost.
  // Kdyby se sem tedy dál předvyplňovala klubová sazba, admin by klubový
  // trénink založil za 600 Kč/h a pásmový ceník by se na jeho rezervace vůbec
  // nedostal. Necháváme prázdno („z ceníku") a cenu spočítá databáze.
  //
  // Komerční sazba se předvyplňuje dál — ta pásmová není a jedno číslo za
  // hodinu je tam pořád ta správná odpověď.
  const defaultRateFor = (k: BookingKind, sid: string): string => {
    if (k === 'maintenance') return '';
    const subj = subjects.find((s) => s.id === sid);
    // Individuálně dohodnutá sazba subjektu přebíjí ceník i pásma.
    if (subj?.default_rate != null) return String(subj.default_rate);
    if (k === 'commercial' || subj?.type === 'commercial') {
      const r = settings?.commercial_default_rate;
      return r != null ? String(r) : '';
    }
    // Klubový led (trénink i turnaj) — ocení ho pásmový ceník v databázi.
    return '';
  };

  useEffect(() => {
    if (!open) return;
    setCelkemTouched(false);
    if (editing) {
      const start = new Date(editing.start_at!);
      const end = new Date(editing.end_at!);
      setKind(kindOf(editing));
      setSubjectId(editing.subject_id ?? '');
      // Předvyplní se VŠECHNY dráhy akce (B). Dřív jen ta jedna, na kterou se
      // kliklo — takže uložení úpravy by ostatní tiše odebralo.
      setSheetIds(editingSheetIds.length ? editingSheetIds : (editing.sheet_id ? [editing.sheet_id] : []));
      setDate(format(start, 'yyyy-MM-dd'));
      setStartHour(start.getHours());
      // Konec o půlnoci (starší data z doby před validací) posuneme na 23:00 —
      // „24:00" by se do formuláře ani do data nedalo přeložit.
      setEndHour(end.getHours() === 0 ? 23 : end.getHours());
      setNote(editing.note ?? '');
      setTitle(editing.event_title ?? '');
      setTitleTouched(true);
      const rateZDb = editing.rate_per_hour != null ? String(editing.rate_per_hour) : '';
      setRate(rateZDb);
      setPuvodniRate(rateZDb);
      setPraniTrenera(editing.preferovany_trener ?? '');
      setRepeat(false);
      setRozsahNazvu('tato');
    } else {
      const start = defaultStart ?? new Date();
      const sh = Math.max(openHour, Math.min(start.getHours(), closeHour - 1));
      const firstClub = myClubs.length === 1 ? myClubs[0].id : '';
      setKind('training');
      setSubjectId(firstClub);
      setSheetIds(defaultSheetId ? [defaultSheetId] : sheets[0] ? [sheets[0].id] : []);
      setDate(format(start, 'yyyy-MM-dd'));
      setStartHour(sh);
      setEndHour(Math.min(sh + 2, closeHour));
      setNote(''); setTitle(''); setTitleTouched(false);
      setRoleCounts({ instructor: 1, bar_staff: 0, manager: 0 });
      setInstructorsTouched(false);
      setRate(defaultRateFor('training', firstClub));
      setPuvodniRate('');
      setRepeat(false); setWeekdays([]); setUntil('');
    }
    setNewFirm(false); setIco(''); setFirmName(''); setFirmAddress(''); setFirmDic('');
    setConflicts(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, editing, defaultStart, defaultSheetId]);

  // přepnutí typu (jen nová rezervace): předvyplň subjekt + sazbu
  useEffect(() => {
    if (isEdit || !open) return;
    const sid =
      kind === 'commercial' ? (commercials.length === 1 ? commercials[0].id : '')
      : kind === 'maintenance' ? ''
      : (myClubs.length === 1 ? myClubs[0].id : '');
    setSubjectId(sid);
    setRate(defaultRateFor(kind, sid));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [kind]);

  // změna subjektu → sazba + automatický název u komerční akce („Teambuilding <firma>")
  useEffect(() => {
    if (isEdit || !open) return;
    setRate(defaultRateFor(kind, subjectId));
    if (kind === 'commercial' && subjectId && !titleTouched) {
      const firm = commercials.find((s) => s.id === subjectId);
      if (firm) setTitle(`Teambuilding ${firm.name}`);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [subjectId, kind]);

  // počet instruktorů se předvyplní podle počtu drah (dokud do toho uživatel nesáhne)
  useEffect(() => {
    if (isEdit || !open || kind !== 'commercial' || instructorsTouched) return;
    setRoleCounts((p) => ({ ...p, instructor: Math.max(1, sheetIds.length) }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sheetIds, kind]);

  // čas musí zůstat uvnitř otevírací doby vybraného dne
  useEffect(() => {
    if (!open) return;
    setStartHour((h) => Math.min(Math.max(h, openHour), closeHour - 1));
    setEndHour((h) => Math.min(Math.max(h, Math.max(startHour, openHour) + 1), closeHour));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [date, openHour, closeHour]);

  const toggleSheet = (id: string) =>
    setSheetIds((prev) => (prev.includes(id) ? prev.filter((s) => s !== id) : [...prev, id]));

  const toggleWeekday = (d: number) =>
    setWeekdays((prev) => (prev.includes(d) ? prev.filter((x) => x !== d) : [...prev, d].sort()));

  const adjust = (role: string, delta: number) => {
    if (role === 'instructor') setInstructorsTouched(true);
    setRoleCounts((p) => ({
      ...p,
      [role]: Math.max(0, Math.min(VALIDATION_LIMITS.STAFF_COUNT_MAX, (p[role] ?? 0) + delta)),
    }));
  };

  // Jedna politika sazeb pro celou appku (viz src/lib/money.ts) — prázdné pole
  // znamená „z ceníku", ne chybu.
  // CELKOVÁ CENA AKCE (jen komerční). Komerční akce na dvou drahách je JEDNA
  // akce s jednou cenou: celkem = dráhy × hodiny × sazba. Sazba i celková cena
  // jsou editovatelné a přepočítávají se navzájem.
  const [celkem, setCelkem] = useState('');
  /**
   * Kde se ukazuje pole „Celková cena" a co v něm ta částka znamená.
   *
   * KOMERCE (`kalkulacka`): dvě okna do jedné pravdy. Částka se přepočítá na
   * hodinovou sazbu, do databáze jde sazba a `amount` se dopočítá jako
   * `hodiny × sazba` — proto tam nevyjde každé číslo na celé koruny.
   *
   * TRÉNINK A TURNAJ (`pevna`): částka JE cena akce. Posílá se jako částka,
   * uloží se napevno a rozdělí mezi dráhy tak, aby součet seděl na haléř.
   * Jakub tak zadá turnaj za 14 000 bez ohledu na délku a počet drah.
   */
  const rezimCeny: 'kalkulacka' | 'pevna' | null =
    kind === 'commercial' ? 'kalkulacka'
    : (kind === 'training' || kind === 'tournament') ? 'pevna'
    : null;
  // PEVNÁ CENA SE PO ZALOŽENÍ NEEDITUJE.
  //
  // Větev `isEdit` v `handleSubmit` neposílá `celkova_cena` nikam — a poslat
  // ji nemá kam: v databázi je paušál zamčený ve všech pěti mutačních RPC
  // (`uprav_sazbu_akce`, `zmen_typ_akce`, `uprav_drahy_akce`, `move_booking`,
  // `update_booking`), skutečný editor paušálu je samostatný ticket. Kdyby
  // pole zůstalo v editaci zapsatelné, admin by napsal 14 000, dostal
  // „Rezervace upravena" a cena by se nezměnila — tichá změna ceny, přesně
  // to, co zbytek téhle změny všude jinde zavírá.
  const pevnaVEditaci = isEdit && rezimCeny === 'pevna';
  // Sáhl už admin do celkové ceny? Pak ji dopočet nesmí přepisovat pod rukama.
  // Týž vzor jako `titleTouched` a `instructorsTouched` výš.
  const [celkemTouched, setCelkemTouched] = useState(false);
  // Nezávazné přání, koho by si hráč přál jako trenéra. Nic nespouští a nic
  // nestojí — placenou směnu zakládá až přiřazení v detailu akce.
  const [praniTrenera, setPraniTrenera] = useState('');
  const hodinAkce = Math.max(0, endHour - startHour);
  const drahAkce = Math.max(1, isEdit ? editingLanes : sheetIds.length);
  const jednotek = hodinAkce * drahAkce;   // „dráhohodiny" — z nich se počítá celková cena

  const sazba = parseSazba(rate);
  const rateNum = sazba.hodnota != null ? sazba.hodnota : undefined;

  // ---- CENA: sazba ⇄ celková ---------------------------------------------
  //
  // Jedna pravda, dvě okna. Celková cena je `sazba × dráhohodiny`, takže se
  // z každé strany dopočítá ta druhá. Nedrží se to v useEffectu schválně —
  // ten by při psaní přepisoval pole pod rukama.

  // POJISTKA JE UVNITŘ OBOU FUNKCÍ, ne na volajících místech.
  //
  // Dopočet dává smysl jen v režimu kalkulačky (komerce), kde jsou sazba
  // a celková cena dvě okna do jedné pravdy. V pevném režimu je částka SAMA
  // vstupem a dopočet ji rozbíjí z obou stran: napsáním sazby 900 se do pole
  // „Celková cena" nasype 5 400 a odešle se jako PEVNÁ částka, kterou nikdo
  // nezadal — a naopak sáhnutím na pole Sazba se zadaných 14 000 bez hlášky
  // smaže. Kdyby pojistka visela na volajícím, přibude časem třetí volání
  // a díra se vrátí.

  /** Sazba → celková. Prázdná nebo neplatná sazba nechá celkovou prázdnou. */
  const prepocitejCelkem = (novaSazba: string) => {
    if (rezimCeny !== 'kalkulacka') return;
    const v = parseSazba(novaSazba);
    if (v.chyba || v.hodnota == null || jednotek <= 0) { setCelkem(''); return; }
    setCelkem(String(v.hodnota * jednotek));
  };

  /** Celková → sazba. */
  const prepocitejSazbu = (novaCelkem: string) => {
    if (rezimCeny !== 'kalkulacka') return;
    const v = parseSazba(novaCelkem);
    if (v.chyba || v.hodnota == null || jednotek <= 0) { setRate(''); return; }
    setRate(String(v.hodnota / jednotek));
  };

  // Vyjde zadaná celková cena na CELÉ KORUNY za hodinu?
  //
  // `amount` v databázi je `hodiny × sazba` a sazba musí být celá koruna, takže
  // ne každá celková částka je dosažitelná: 10 000 Kč za 3 h by dalo
  // 3 333,33 Kč/h a databáze to odmítne. Radši to řekneme dopředu a nabídneme
  // nejbližší možné, než aby admin dostal chybu až při ukládání.
  // U PEVNÉ CENY SE ČÁSTKA ČTE VLASTNÍM PARSEREM, ne `parseSazba`.
  //
  // `parseSazba` je parser HODINOVÉ sazby: chce celé koruny a strop 50 000 Kč/h.
  // Na cenu za celou akci se to nehodí — 14 000,50 databáze bere a 60 000 za
  // víkendový turnaj je běžné číslo. Chyba se navíc dřív ztrácela (`?? null`),
  // takže se částka tiše zahodila a rezervace vznikla za ceníkovou cenu, zatímco
  // admin viděl svoje číslo v poli a hlášku „Rezervace vytvořena".
  const celkemVysledek = rezimCeny === 'pevna'
    ? parseCelkovouCenu(celkem, jednotek)
    : parseSazba(celkem);
  const celkemNum = celkemVysledek.hodnota ?? null;
  const sazbaZCelkem = celkemNum != null && jednotek > 0 ? celkemNum / jednotek : null;
  // Jen u komerce: tam se z částky počítá sazba a ta musí vyjít na celé koruny.
  // U pevné ceny se sazba neukládá jako vstup, takže projde jakákoli částka.
  const celkemNevychazi = rezimCeny === 'kalkulacka'
    && sazbaZCelkem != null && Math.abs(sazbaZCelkem - Math.round(sazbaZCelkem)) > 1e-9;
  const nejblizsiCelkem = celkemNevychazi && sazbaZCelkem != null
    ? [Math.floor(sazbaZCelkem) * jednotek, Math.ceil(sazbaZCelkem) * jednotek]
    : null;

  // Celková cena se dopočítá, když se změní počet drah nebo hodin — tedy když
  // se změnil jmenovatel, ne když admin píše do některého z polí. Psaní si
  // pole dopočítávají navzájem samy (`prepocitejCelkem` / `prepocitejSazbu`);
  // efekt nad `rate` by je přepisoval pod rukama.
  // Když se změní POČET DRAH nebo HODIN, změní se jmenovatel — a jedno z polí
  // se musí dopočítat, jinak si začnou odporovat (sazba × dráhohodiny ≠ celkem).
  //
  // Které z nich je kotva, rozhoduje to, do čeho admin naposledy psal:
  //   • psal celkovou → celková platí, dopočítá se sazba (dohodnutá cena za akci),
  //   • jinak → platí sazba a dopočítá se celková.
  // ČÁSTKA SE VYNULUJE PŘI KAŽDÉM OTEVŘENÍ DIALOGU I PŘI ZMĚNĚ TYPU AKCE.
  //
  // Dvě různé díry, jeden kořen — do `celkem` zapisoval kód patřícího jiné
  // situaci a `buildInput` mu věřil:
  //
  // 1) DIALOG SE NEODMONTOVÁVÁ. V kalendáři je mountnutý trvale a `open` jen
  //    přepíná Radix, takže `useState` přežije zavření. Admin založil trénink
  //    za 14 000, otevřel jiný volný slot — a v poli pořád svítělo 14 000.
  //    Cizí rezervace tak dostala napevno částku, kterou pro ni nikdo nezadal,
  //    a `cena_rucni` zařídilo, že se už nikdy nepřepočítá.
  // 2) PŘEPNUTÍ TYPU MĚNÍ VÝZNAM POLE. U komerce je to kalkulačka (přepočítá se
  //    na sazbu), u tréninku a turnaje pevná částka. Číslo, které přepnutí
  //    přežije, začne znamenat něco jiného: 14 000 z turnaje se po přepnutí na
  //    komerci uloží jako sazba z ceníku, zatímco v poli dál svítí 14 000.
  //
  // Vynulování je schválně TVRDÉ, ne přepočet: převádět „14 000 napevno" na
  // ekvivalentní sazbu by znamenalo rozhodnout za admina, že tu cenu chtěl
  // i pro jinou akci a jiný typ. Ať ji zadá znovu — je to jedno pole.
  //
  // K čemu jsou ty dva refy: dnes NIC nezmění. Pole závislostí `[rezimCeny,
  // open]` samo zařídí, že se efekt pustí jen při skutečné změne, takže se
  // stráž trefí jedině při mountu — a tam potlačí reset na hodnoty, které
  // stejně platí. Jsou to POJISTKY PROTI BUDOUCÍ ÚPRAVĚ: kdyby někdo pole
  // závislostí zúžil nebo odstranil, stráž udrží chování správné a částka,
  // kterou admin právě píše, se při překreslení nesmaže. (Dřívější znění
  // tohohle komentáře tvrdilo, že proti překreslení chrání už dnes — nechrání,
  // to dělá pole závislostí o osm řádků níž. Nález brány code review.)
  const rezimMinule = useRef(rezimCeny);
  const otevreniMinule = useRef(open);
  useEffect(() => {
    if (rezimMinule.current === rezimCeny && otevreniMinule.current === open) return;
    rezimMinule.current = rezimCeny;
    otevreniMinule.current = open;
    setCelkem('');
    setCelkemTouched(false);
  }, [rezimCeny, open]);

  useEffect(() => {
    if (rezimCeny === null) { setCelkem(''); return; }
    // U pevné ceny se PŘEPOČÍTÁVAT NESMÍ: 14 000 zůstává 14 000, i když admin
    // přidá dráhu nebo prodlouží akci. To je celý smysl toho pole.
    if (rezimCeny === 'pevna') return;
    if (celkemTouched) prepocitejSazbu(celkem);
    else prepocitejCelkem(rate);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [jednotek]);

  // Změna sazby (z ceníku, z typu akce, z výběru subjektu) dopočítá celkovou —
  // dokud do ní admin sám nesáhl.
  useEffect(() => {
    if (rezimCeny === null) { setCelkem(''); return; }
    if (rezimCeny === 'pevna') return;   // pevná částka se ze sazby neodvozuje
    if (celkemTouched) return;
    prepocitejCelkem(rate);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rate, kind, open, celkemTouched, rezimCeny]);


  const busy = api.isCreating || api.isUpdating || aresLoading;
  const needsSubject = kind !== 'maintenance';
  const startOptions = Array.from({ length: Math.max(closeHour - openHour, 1) }, (_, i) => openHour + i);
  const endOptions = Array.from({ length: Math.max(closeHour - startHour, 1) }, (_, i) => startHour + 1 + i);
  const subjectOptions = kind === 'commercial' ? commercials : myClubs;

  // ZMĚNA ODBĚRATELE U KOMERČNÍ AKCE — jediný případ, kdy se výběr subjektu při
  // úpravě odemyká. Podmínky musí platit všechny zároveň:
  //   • admin (server to ověřuje taky, tohle je jen o tom, komu se pole nabídne),
  //   • akce má `event_id` — mění se přes RPC nad celou akcí, ne nad rezervací,
  //   • akce JE komerční (`kindOf(editing)`) — u klubového tréninku je odběratel
  //     klub a přepsat ho na firmu by ho odpojilo od členství i klubového ceníku,
  //   • a ZŮSTÁVÁ komerční (`kind`), tedy admin ji v témž formuláři nepřepnul
  //     na něco jiného.
  //
  // Ta poslední podmínka tu není pro parádu. Bez ní zůstal select odemčený i po
  // přepnutí typu na trénink — jen se v něm místo firem nabídly kluby. Kdyby
  // admin v tom stavu klub vybral, `zmenTypAkce` by PROŠLA A ZAPSALA SE a až
  // `zmenFirmuAkce` by spadla na „lze měnit jen u komerční akce". Každé RPC je
  // vlastní požadavek, tedy vlastní transakce — uživatel by dostal červený toast
  // nad úpravou, která je z půlky uložená (typ změněný a přeceněný).
  // Fail-closed to bylo i tak, ale polovičatě uložený stav je matoucí.
  // (Nález brány code review a bezpečnostní brány, 10. 9. 2026.)
  const lzeZmenitFirmu = Boolean(
    isAdmin && isEdit && editing?.event_id
      && kindOf(editing) === 'commercial' && kind === 'commercial',
  );

  const toIso = (h: number) => new Date(`${date}T${hh(h)}`).toISOString();

  // ---- NÁHLED CENY: kolik to bude stát, NEŽ to člověk potvrdí ----------------
  //
  // Klubový led (trénink, turnaj) se oceňuje pásmovým ceníkem až v databázi,
  // takže pole „Sazba" zůstává schválně prázdné („z ceníku") — a do téhle chvíle
  // cenu před potvrzením NEVIDĚL NIKDO, ani admin. Ptáme se proto databáze,
  // která ji spočítá TOUŽ funkcí, jakou pak použije při zápisu.
  //
  // Ptá se to jen tehdy, když je sazba prázdná: vyplněnou sazbu si člověk
  // dopočítá sám v poli „Celková cena" a druhý (a možná jiný) údaj vedle by jen
  // mátl.
  const [cena, setCena] = useState<NahledCeny | null>(null);
  const [cenaChyba, setCenaChyba] = useState<string | null>(null);
  // Vyplněná pevná cena náhled vypíná: dvě různá čísla na jedné obrazovce
  // ve chvíli potvrzení jsou horší než žádné. Uloží se to zadané, ale oko
  // padne na to větší v rámečku pod formulářem.
  const cenaZCeniku = needsSubject && !rate.trim()
    && !(rezimCeny === 'pevna' && celkem.trim());

  useEffect(() => {
    if (!open || !cenaZCeniku || !subjectId || hodinAkce <= 0) {
      setCena(null); setCenaChyba(null); return;
    }
    let zivy = true;
    // Krátká prodleva: hodiny se přepínají klikáním a bez ní by každý klik
    // poslal dotaz, který stejně přepíše ten další.
    const t = setTimeout(() => {
      api.nahledCeny({
        subject_id: subjectId, kind,
        start_at: toIso(startHour), end_at: toIso(endHour), drah: drahAkce,
      })
        .then((v) => { if (zivy) { setCena(v); setCenaChyba(null); } })
        // Hláška z databáze je česká a konkrétní („Led na víkend v 5 h nemá
        // v ceníku cenu…"), tak se ukazuje tak, jak přišla — je to pro člověka
        // důležitější než ticho.
        .catch((e: Error) => { if (zivy) { setCena(null); setCenaChyba(e.message); } });
    }, 250);
    return () => { zivy = false; clearTimeout(t); };
    // `api` se schválně nesleduje — je to nová reference při každém renderu
    // rodiče a efekt by se pouštěl pořád dokola.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, cenaZCeniku, subjectId, kind, date, startHour, endHour, drahAkce, hodinAkce]);

  // ---- ARES ------------------------------------------------------------------
  const handleAres = async () => {
    const clean = ico.trim();
    if (!/^\d{8}$/.test(clean)) {
      toast({ title: 'Neplatné IČO', description: 'Zadejte 8 číslic.', variant: 'destructive' });
      return;
    }
    setAresLoading(true);
    try {
      // Nejdřív ověříme, jestli firmu už nemáme — ať nevznikají duplicity.
      const existing = await api.findSubjectByIco(clean);
      if (existing) {
        setNewFirm(false);
        setSubjectId(existing.id);
        setRate(defaultRateFor('commercial', existing.id));
        if (!titleTouched) setTitle(`Teambuilding ${existing.name}`);
        toast({ title: 'Firma už v systému je', description: `Použil jsem existující záznam: ${existing.name}` });
        return;
      }
      const d = await api.aresLookup(clean);
      setFirmName(d.name); setFirmAddress(d.address); setFirmDic(d.dic);
      toast({ title: 'Načteno z ARESu', description: d.name });
    } catch (e) {
      toast({ title: 'ARES', description: e instanceof Error ? e.message : 'Načtení selhalo.', variant: 'destructive' });
    } finally {
      setAresLoading(false);
    }
  };

  const handleCreateFirm = async () => {
    if (!firmName.trim()) { toast({ title: 'Vyplňte název firmy', variant: 'destructive' }); return; }
    try {
      const subj = await api.createSubject({
        name: sanitizeText(firmName), ico: ico.trim() || undefined,
        dic: firmDic || undefined, address: firmAddress || undefined,
      });
      setNewFirm(false); setSubjectId(subj.id); setRate(defaultRateFor('commercial', subj.id));
      if (!titleTouched) setTitle(`Teambuilding ${subj.name}`);
      toast({ title: 'Firma založena', description: subj.name });
    } catch (e) {
      toast({ title: 'Chyba', description: e instanceof Error ? e.message : 'Nepodařilo se založit firmu.', variant: 'destructive' });
    }
  };

  // ---- odeslání --------------------------------------------------------------
  const validate = (): string | null => {
    if (!date) return 'Vyberte datum.';
    if (!sheetIds.length) return 'Vyberte aspoň jednu dráhu.';
    if (endHour <= startHour) return 'Konec musí být po začátku.';
    if (startHour < openHour || endHour > closeHour) return `Mimo otevírací dobu (${hh(openHour)}–${hh(closeHour)}).`;
    if (!title.trim()) return 'Vyplňte název akce.';
    if (needsSubject && !subjectId) return kind === 'commercial' ? 'Vyberte firmu.' : 'Vyberte klub.';
    if (kind === 'commercial' && (roleCounts.instructor ?? 0) < 1) return 'Komerční akce potřebuje aspoň jednoho instruktora.';
    // Jen když admin do sazby SÁHL. Nedotčený odvozený průměr s haléři
    // (538,46 u paušálu) není chyba, kterou by měl opravovat — a neodešle se:
    // `parseSazba` z něj vrátí `hodnota: undefined`, takže `meniSazbu` vyjde
    // `false` a `rate_per_hour` se do `update_booking` vůbec nepošle.
    if (isAdmin && kind !== 'maintenance' && sazba.chyba && rate !== puvodniRate) {
      return `${sazba.chyba} Prázdné pole znamená sazbu z ceníku.`;
    }
    // CHYBA V CELKOVÉ CENĚ MUSÍ ZASTAVIT ULOŽENÍ.
    //
    // Dokud se tady neptalo, nepřečtená částka se jen zahodila a rezervace
    // vznikla za ceníkovou cenu — admin přitom viděl svoje číslo v poli
    // a dostal „Rezervace vytvořena". Tichý rozdíl mezi zobrazenou
    // a fakturovanou cenou je to nejhorší, co peněžní vrstva umí.
    if (isAdmin && rezimCeny && celkemVysledek.chyba) {
      return `${celkemVysledek.chyba} Prázdné pole znamená cenu z ceníku.`;
    }
    // POJISTKA K `pevnaVEditaci`.
    //
    // Pole je v editaci readOnly, takže sem se za normálních okolností nedá
    // dojít. Kontrola tu je pro případ, že readOnly někdo v budoucnu sundá:
    // u peněz musí být poslední slovo hlasitá chyba, ne tiché zahození.
    if (pevnaVEditaci && celkemTouched && celkemNum != null) {
      return 'Pevnou celkovou cenu už po založení nejde změnit. '
        + 'Když má akce stát jinak, stornujte ji a založte znovu.';
    }
    // PEVNÁ CENA A OPAKOVÁNÍ SE ZATÍM VYLUČUJÍ.
    //
    // `create_booking_series` parametr `p_celkem` nezná, takže by série
    // s vyplněnou částkou skončila nesrozumitelným „Sérii se nepodařilo
    // založit". A co paušál u série vlastně znamená — 14 000 za každý termín,
    // nebo za celou řadu? — je otázka na PM, ne věc, kterou má rozhodnout
    // formulář. Do té doby se ta kombinace nenabízí.
    if (repeat && rezimCeny === 'pevna' && celkemNum != null) {
      return 'Opakovanou akci zatím nejde zadat s pevnou celkovou cenou. '
        + 'Buď vypněte opakování, nebo nechte cenu prázdnou (spočítá se z ceníku).';
    }
    if (repeat) {
      if (!weekdays.length) return 'Vyberte dny v týdnu, kdy se má opakovat.';
      if (!until) return 'Vyplňte, do kdy se má opakovat.';
      if (new Date(until) < new Date(date)) return 'Datum konce opakování musí být po prvním termínu.';
    }
    return null;
  };

  // POSÍLÁ SE JEN ČÁSTKA, KTEROU ADMIN DOOPRAVDY NAPSAL.
  //
  // `celkemTouched` je tu jako druhá pojistka vedle vynulování při otevření
  // a při změně typu: co do pole nasypal dopočet nebo zbytek z minula, není
  // rozhodnutí admina a nemá se ukládat napevno. Jedna hodnota, jedno místo —
  // ať se `rate_per_hour` a `celkova_cena` nerozhodují každá podle jiné
  // podmínky (na tom se ty dvě větve dřív rozcházely).
  const pevnaCena = isAdmin && rezimCeny === 'pevna' && celkemTouched ? celkemNum : null;

  const buildInput = (): BookingInput => ({
    sheet_ids: sheetIds,
    kind,
    title: sanitizeText(title),
    start_at: toIso(startHour),
    end_at: toIso(endHour),
    subject_id: needsSubject ? subjectId : null,
    note: note ? sanitizeText(note) : undefined,
    role_reqs: kind === 'commercial'
      ? Object.fromEntries(Object.entries(roleCounts).filter(([, c]) => c > 0))
      : {},
    // Sazba a pevná celková cena se navzájem vylučují — server takový rozpor
    // odmítne. U pevného režimu proto sazbu neposíláme vůbec: admin do ní
    // v tomhle režimu nepíše a případná zděděná hodnota (z ceníku, ze subjektu)
    // by zadání shodila hláškou „zadejte buď sazbu, nebo celkovou cenu".
    rate_per_hour: pevnaCena != null
      ? null
      : (isAdmin && rateNum !== undefined ? rateNum : null),
    // Pevná cena akce (trénink, turnaj). Jen admin; u komerce se posílá sazba,
    // protože tam je „celková cena" jen dopočet a engine se nemění.
    celkova_cena: pevnaCena,
  });

  const submitBooking = async (override: boolean) => {
    try {
      if (repeat) {
        const res = await api.createSeries({ ...buildInput(), weekdays, until });
        toast({
          title: nadpisSerie(res),
          description: souhrnSerie(res),
          // Přeskočené termíny musí zůstat na obrazovce dýl: uživatel si podle
          // nich shání náhradní časy a čtyřsekundový toast na to nestačí.
          duration: res.skipped?.length ? 12000 : 4000,
        });
      } else {
        const vysledek = await api.createBooking({ ...buildInput(), override }) as
          { reservation_ids?: string[] } | undefined;
        // Přání se ukládá až po založení — `create_booking` ho nezná a přepisovat
        // kvůli nezávaznému údaji celou tu funkci by bylo horší než jeden dotaz navíc.
        if (kind === 'training' && praniTrenera && vysledek?.reservation_ids?.length) {
          await api.nastavPraniTrenera({
            reservation_ids: vysledek.reservation_ids,
            user_id: praniTrenera,
          });
        }
        toast({ title: override ? 'Rezervace založena, kolidující akce byly zrušeny' : 'Rezervace vytvořena' });
      }
      setConflicts(null);
      onOpenChange(false);
    } catch (error) {
      setConflicts(null);
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Operace selhala.', variant: 'destructive' });
    }
  };

  const handleSubmit = async () => {
    const problem = validate();
    if (problem) { toast({ title: 'Zkontrolujte formulář', description: problem, variant: 'destructive' }); return; }

    try {
      // EDITACE — název/poznámka/sazba + případný přesun času nebo dráhy
      if (isEdit && editing) {
        // Porovnáváme okamžiky, ne řetězce — z databáze chodí jiný formát než z toISOString().
        const sameMoment = (a: string, b: string) => new Date(a).getTime() === new Date(b).getTime();
        const movedTime =
          !sameMoment(toIso(startHour), editing.start_at!) || !sameMoment(toIso(endHour), editing.end_at!);
        // Přesun dráhy řeší `moveBooking` jen u JEDNODRÁHOVÉ akce, kde se
        // nemění počet drah. Když se počet mění, je to práce pro
        // `upravDrahyAkce` níž — jinak by si ty dvě cesty přepisovaly výsledek.
        const movedSheet = editingSheetIds.length === 1 && sheetIds.length === 1
          && sheetIds[0] !== editing.sheet_id;
        if (movedTime || (movedSheet && editingLanes === 1)) {
          await api.moveBooking({
            id: editing.id!,
            start_at: toIso(startHour),
            end_at: toIso(endHour),
            sheet_id: editingLanes > 1 ? undefined : sheetIds[0],
          });
        }
        // SAZBA SE MĚNÍ PŘES CELOU AKCI, ne přes jednu rezervaci.
        //
        // `update_booking` přepíše sazbu jen na tom jednom řádku, takže akce na
        // dvou drahách by skončila se dvěma různými cenami (BUG 1). Když má
        // rezervace `event_id`, jde přecenění přes `uprav_sazbu_akce`, které
        // sáhne na všechny dráhy atomicky.
        const meniSazbu = isAdmin && rateNum !== undefined
          && rateNum !== (editing.rate_per_hour ?? undefined);
        const rozsahSerie = jeSerie && rozsahNazvu === 'serie';

        await api.updateBooking({
          id: editing.id!,
          // U ROZSAHU „CELÁ SÉRIE" se název ani poznámka přes `update_booking`
          // neposílají — sáhla by na tenhle jeden termín a hromadná změna níž
          // by pak jen přepisovala, co tahle zapsala. Sazba, čas a dráhy jdou
          // touhle cestou dál, ty se hromadně neměnní (a nemají).
          title: rozsahSerie ? undefined : sanitizeText(title),
          // prázdný řetězec = „smaž poznámku" (null by znamenalo „neměň")
          note: rozsahSerie ? undefined : (note ? sanitizeText(note) : ''),
          // U akce se sazba pošle zvlášť (níž), aby se propsala na všechny dráhy.
          rate_per_hour: meniSazbu && !editing.event_id ? rateNum : undefined,
        });

        // PŘEJMENOVÁNÍ CELÉ SÉRIE — jen když si to uživatel vybral.
        // Server si práva ověří sám a je fail-closed: kdo nesmí na jediný
        // budoucí termín, nepřejmenuje žádný.
        let zmenaSerie: { terminu?: number } | null = null;
        let poznamkaZmenena = false;
        if (rozsahSerie) {
          // POZNÁMKA SE POSÍLÁ, JEN KDYŽ SE OPRAVDU ZMĚNILA.
          //
          // `''` znamená na serveru „smaž poznámku". Kdyby se posílala vždycky,
          // stačilo by otevřít termín s prázdnou poznámkou, opravit překlep
          // v názvu a zvolit „celá série" — a poznámky by zmizely VŠEM ostatním
          // budoucím termínům, aniž by o tom kdokoli věděl. `undefined` je
          // „neměň". (Nález brány code review, 11. 9. 2026.)
          poznamkaZmenena = sanitizeText(note) !== (editing.note ?? '');
          zmenaSerie = await api.prejmenujSerii({
            id: editing.id!,
            title: sanitizeText(title),
            note: poznamkaZmenena ? (note ? sanitizeText(note) : '') : undefined,
          });
        }

        // ZMĚNA TYPU AKCE (C) JDE PRVNÍ, protože přepočítá cenu podle nového
        // typu — a ručně zadaná sazba níž pak platí NAD ním.
        //
        // Obráceně to bylo tiché zahození peněz: `zmen_typ_akce` nastaví
        // `rate_per_hour = NULL` a nechá trigger ocenit z ceníku, takže sazba
        // uložená o pár řádků dřív zmizela a akce se vyfakturovala za ceníkovou
        // cenu. Uživatel přitom viděl „Rezervace upravena" a svoje číslo
        // v poli. Komentář na tomhle místě to popisoval správně, kód ne.
        if (isAdmin && editing.event_id && kind !== kindOf(editing)) {
          await api.zmenTypAkce({ event_id: editing.event_id, typ: kind });
        }

        if (meniSazbu && editing.event_id) {
          await api.upravSazbuAkce({ event_id: editing.event_id, sazba: rateNum! });
        }

        // DRÁHY (B) — přidání i ubrání jedním voláním nad celou akcí.
        if (editing.event_id) {
          const puvodni = [...editingSheetIds].sort().join(',');
          const nove = [...sheetIds].sort().join(',');
          if (puvodni !== nove && sheetIds.length > 0) {
            await api.upravDrahyAkce({ event_id: editing.event_id, sheet_ids: sheetIds });
          }
        }

        // ZMĚNA ODBĚRATELE — až ZA dráhami, aby nová firma sedla i na dráhu,
        // která právě přibyla. Jde to jedním RPC nad celou akcí; cenu to nemění
        // a nad vystaveným dokladem server odmítne (hlášku ukážeme, jak přišla).
        let zmenaFirmy: { schvaleni_prerazeno?: boolean; drah?: number } | null = null;
        if (lzeZmenitFirmu && subjectId && subjectId !== editing.subject_id) {
          zmenaFirmy = await api.zmenFirmuAkce({
            event_id: editing.event_id!, subject_id: subjectId,
          });
        }

        if (kind === 'training' && (editing.preferovany_trener ?? '') !== praniTrenera) {
          await api.nastavPraniTrenera({
            reservation_ids: [editing.id!],
            user_id: praniTrenera || null,
          });
        }
        // U změny odběratele se řekne i to, co se stalo s potvrzením. Razítko
        // teď podepsal admin, který změnu udělal — je to údaj o tom, kdo pod
        // akcí stojí ve fakturaci, a generické „Rezervace upravena" by ho
        // spolklo. (Nález brány code review, 10. 9. 2026.)
        //
        // Když se ale razítko nepřerazilo, NESMÍ se to tvrdit — u neschválené
        // akce žádné není a funkce ho nevyrábí. Mlčet ale taky nejde: uživatel
        // právě přepsal odběratele, tedy to, komu se bude fakturovat.
        // (Druhý nález téže brány.)
        const drah = zmenaFirmy?.drah && zmenaFirmy.drah > 1
          ? `Odběratel je přepsaný na všech ${zmenaFirmy.drah} drahách akce. `
          : '';
        toast(zmenaFirmy
          ? {
              title: 'Firma změněna',
              description: zmenaFirmy.schvaleni_prerazeno
                ? `${drah}Cena zůstala beze změny a potvrzení akce je nově podepsané vámi.`
                : `${drah}Cena zůstala beze změny.`,
            }
          : zmenaSerie
            ? {
                title: 'Série přejmenována',
                // Hláška říká JEN TO, CO SE OPRAVDU POSLALO: poznámka se
                // u nezměněného textu vůbec neposílá, a tvrdit, že se propsala,
                // by bylo nepravdivé. (Nález brány code review, 11. 9. 2026.)
                description: `${poznamkaZmenena ? 'Název i poznámka se propsaly' : 'Název se propsal'}`
                  + ` na ${zmenaSerie.terminu ?? 0} budoucích termínů.`
                  + ' Minulé termíny si nechaly původní název.',
              }
            : { title: 'Rezervace upravena' });
        onOpenChange(false);
        return;
      }

      // NOVÁ — nejdřív se serveru zeptáme, co by se přebilo
      const found = await api.checkConflicts({
        sheet_ids: sheetIds, start_at: toIso(startHour), end_at: toIso(endHour), kind,
      });
      if (found.length && !repeat) {
        if (!isAdmin || found.some((c) => !c.can_override)) {
          const c = found[0];
          toast({
            title: 'Termín je obsazený',
            description: `${c.sheet_name}: ${c.event_title ?? c.subject_name ?? 'rezervace'} ${format(new Date(c.start_at), 'HH:mm')}–${format(new Date(c.end_at), 'HH:mm')}. Vyberte jiný čas nebo dráhu.`,
            variant: 'destructive',
          });
          return;
        }
        setConflicts(found);   // admin → nabídneme vědomé přebití
        return;
      }
      await submitBooking(false);
    } catch (error) {
      toast({ title: 'Chyba', description: error instanceof Error ? error.message : 'Operace selhala.', variant: 'destructive' });
    }
  };

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="max-w-md max-h-[90vh] flex flex-col">
          <DialogHeader className="flex-shrink-0">
            <DialogTitle>{isEdit ? 'Upravit rezervaci' : 'Nová rezervace'}</DialogTitle>
            <DialogDescription>
              {isEdit
                ? 'Upravte údaje rezervace. Čas jde posunout i tažením v kalendáři.'
                : 'Rezervuje se na celé hodiny. U komerční akce se rovnou založí i směny.'}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 overflow-y-auto flex-1 pr-2">
            {/* typ akce */}
            <div className="space-y-2">
              <Label>Typ akce</Label>
              <div className="flex flex-wrap gap-1">
                {kinds.map((k) => (
                  <Button
                    key={k} type="button" size="sm"
                    variant={kind === k ? 'default' : 'outline'}
                    // TYP AKCE JDE ZMĚNIT I V ÚPRAVĚ (C) — ale jen adminovi,
                    // protože typ hýbe cenou (klub → pásma, komerční → sazba).
                    // Bez akce (`event_id`) není co přepínat.
                    disabled={isEdit && (!isAdmin || !editing?.event_id)}
                    onClick={() => setKind(k)}
                  >
                    {KIND_LABELS[k]}
                  </Button>
                ))}
              </div>
            </div>

            {/* subjekt */}
            {needsSubject && !newFirm && (
              <div className="space-y-2">
                <Label>{kind === 'commercial' ? 'Firma (zákazník)' : 'Klub'}</Label>
                <Select value={subjectId} onValueChange={setSubjectId} disabled={isEdit && !lzeZmenitFirmu}>
                  <SelectTrigger><SelectValue placeholder={kind === 'commercial' ? 'Vyberte firmu' : 'Vyberte klub'} /></SelectTrigger>
                  <SelectContent>
                    {subjectOptions.map((s) => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
                  </SelectContent>
                </Select>
                {lzeZmenitFirmu && (
                  <p className="text-xs text-muted-foreground">
                    Přepsat jde jen odběratele — cena akce zůstane, jaká je. Nad akcí,
                    která už je na vystaveném dokladu, změna neprojde.
                  </p>
                )}
                {kind === 'commercial' && isAdmin && !isEdit && (
                  <Button type="button" variant="link" size="sm" className="h-auto p-0" onClick={() => setNewFirm(true)}>
                    + Přidat novou firmu (ARES)
                  </Button>
                )}
              </div>
            )}

            {/* nová firma přes ARES */}
            {kind === 'commercial' && newFirm && !isEdit && (
              <div className="space-y-2 rounded-md border p-3">
                <Label>Nová firma podle IČO</Label>
                <div className="flex gap-2">
                  <Input value={ico} onChange={(e) => setIco(e.target.value)} placeholder="IČO (8 číslic)" inputMode="numeric" />
                  <Button type="button" variant="outline" onClick={handleAres} disabled={aresLoading}>
                    {aresLoading ? '…' : 'Načíst z ARESu'}
                  </Button>
                </div>
                <Input value={firmName} onChange={(e) => setFirmName(e.target.value)} placeholder="Název firmy" />
                <Input value={firmAddress} onChange={(e) => setFirmAddress(e.target.value)} placeholder="Adresa" />
                <Input value={firmDic} onChange={(e) => setFirmDic(e.target.value)} placeholder="DIČ" />
                <div className="flex gap-2">
                  <Button type="button" size="sm" onClick={handleCreateFirm}>Založit a použít</Button>
                  <Button type="button" size="sm" variant="ghost" onClick={() => setNewFirm(false)}>Zpět na výběr</Button>
                </div>
              </div>
            )}

            {/* název akce */}
            <div className="space-y-2">
              <Label htmlFor="res-title">Název akce</Label>
              <Input
                id="res-title" value={title} maxLength={VALIDATION_LIMITS.TITLE_MAX}
                placeholder={kind === 'training' ? 'Např. Trénink A-tým' : kind === 'tournament' ? 'Např. Podzimní turnaj' : 'Např. Teambuilding'}
                onChange={(e) => { setTitle(e.target.value); setTitleTouched(true); }}
              />

              {/* ROZSAH U OPAKOVANÉ SÉRIE — platí JEN na název a poznámku.
                  Čas, dráhy ani cena se hromadně měnit nedají a nabízet to tu
                  by slibovalo něco, co server neumí (a schválně neumí: kolize
                  a ceník se u každého termínu řeší zvlášť). */}
              {jeSerie && (
                <div className="space-y-2 rounded-md border bg-muted/40 p-3">
                  <Label className="text-sm">Název a poznámku změnit u</Label>
                  <RadioGroup
                    value={rozsahNazvu}
                    onValueChange={(v) => setRozsahNazvu(v as 'tato' | 'serie')}
                    className="gap-2"
                  >
                    <label className="flex items-center gap-2 text-sm">
                      <RadioGroupItem value="tato" id="rozsah-tato" />
                      jen této akce
                    </label>
                    <label className="flex items-center gap-2 text-sm">
                      <RadioGroupItem value="serie" id="rozsah-serie" />
                      celé série (budoucí termíny)
                    </label>
                  </RadioGroup>
                  <p className="text-xs text-muted-foreground">
                    Změna se u série propíše jen na termíny, které ještě nebyly —
                    minulé si název nechávají, protože je na dokladech. Čas, dráhy
                    ani cena se hromadně nemění.
                  </p>
                </div>
              )}
            </div>

            {/* dráhy */}
            <div className="space-y-2">
              <Label>Dráhy</Label>
              <div className="flex flex-wrap gap-4">
                {sheets.map((s) => (
                  <label key={s.id} className="flex items-center gap-2 text-sm">
                    <Checkbox
                      checked={sheetIds.includes(s.id)}
                      // I V ÚPRAVĚ SE DRÁHY PŘEPÍNAJÍ VOLNĚ (B).
                      // Dřív tu bylo `setSheetIds([s.id])`, takže zaškrtnutí
                      // druhé dráhy tu první vyplo a akce zůstala jednodráhová.
                      onCheckedChange={() => toggleSheet(s.id)}
                    />
                    {s.name}
                  </label>
                ))}
              </div>
              {!isEdit && sheetIds.length > 1 && (
                <p className="text-xs text-muted-foreground">Rezervace vznikne na obou drahách (stejný čas i akce).</p>
              )}
              {isEdit && (
                <p className="text-xs text-muted-foreground">
                  Přidaná dráha se založí pod touhle akcí se stejným časem i sazbou;
                  odebraná se skryje, nesmaže.
                </p>
              )}
            </div>

            {/* datum a čas — roletky po celých hodinách */}
            <div className="space-y-2">
              <Label htmlFor="res-date">Datum</Label>
              <Input id="res-date" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label>Od</Label>
                <Select value={String(startHour)} onValueChange={(v) => {
                  const h = Number(v);
                  setStartHour(h);
                  if (endHour <= h) setEndHour(Math.min(h + 1, closeHour));
                }}>
                  <SelectTrigger className="h-11"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    {startOptions.map((h) => <SelectItem key={h} value={String(h)}>{hh(h)}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label>Do</Label>
                <Select value={String(endHour)} onValueChange={(v) => setEndHour(Number(v))}>
                  <SelectTrigger className="h-11"><SelectValue /></SelectTrigger>
                  <SelectContent>
                    {endOptions.map((h) => <SelectItem key={h} value={String(h)}>{hh(h)}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              Led je v tento den k dispozici {hh(openHour)}–{hh(closeHour)}. Rezervuje se po celých hodinách.
            </p>

            {/* opakování */}
            {!isEdit && (
              <div className="space-y-2 rounded-md border p-3">
                <div className="flex items-center justify-between">
                  <Label htmlFor="res-repeat">Opakovat každý týden</Label>
                  <Switch id="res-repeat" checked={repeat} onCheckedChange={(v) => {
                    setRepeat(v);
                    if (v && !weekdays.length && date) {
                      const d = new Date(`${date}T00:00`);
                      setWeekdays([d.getDay() === 0 ? 7 : d.getDay()]);
                    }
                  }} />
                </div>
                {repeat && (
                  <>
                    <div className="flex flex-wrap gap-1">
                      {WEEKDAYS.map(([d, label]) => (
                        <Button
                          key={d} type="button" size="sm"
                          variant={weekdays.includes(d) ? 'default' : 'outline'}
                          onClick={() => toggleWeekday(d)}
                        >
                          {label}
                        </Button>
                      ))}
                    </div>
                    <div className="space-y-1">
                      <Label htmlFor="res-until">Opakovat do</Label>
                      <Input id="res-until" type="date" value={until} min={date} onChange={(e) => setUntil(e.target.value)} />
                    </div>
                    <p className="text-xs text-muted-foreground">
                      Termíny, které kolidují s jinou akcí, se přeskočí — na konci uvidíte které.
                    </p>
                  </>
                )}
              </div>
            )}

            {/* sazba (+ celková cena u komerční akce) */}
            {kind !== 'maintenance' && (
              <div className="space-y-2">
                <div className={rezimCeny ? 'grid grid-cols-2 gap-3' : undefined}>
                  <div className="space-y-2">
                    <Label htmlFor="res-rate">Sazba (Kč/h)</Label>
                    <Input
                      id="res-rate" value={rate}
                      onChange={(e) => { setRate(e.target.value); prepocitejCelkem(e.target.value); }}
                      readOnly={!isAdmin} inputMode="numeric" placeholder={rate ? undefined : 'z ceníku'}
                    />
                  </div>

                  {/* CELKOVÁ CENA — komerce, trénink i turnaj. U údržby ne:
                      tam není komu fakturovat. */}
                  {rezimCeny && (
                    <div className="space-y-2">
                      <Label htmlFor="res-celkem">Celková cena (Kč)</Label>
                      <Input
                        id="res-celkem" value={celkem}
                        onChange={(e) => {
                          setCelkemTouched(true);
                          setCelkem(e.target.value);
                          // Jen kalkulačka (komerce) dopočítává sazbu. U pevné
                          // ceny je částka sama vstupem a sazbu by jen rozbila.
                          if (rezimCeny === 'kalkulacka') prepocitejSazbu(e.target.value);
                        }}
                        readOnly={!isAdmin || pevnaVEditaci} inputMode="numeric"
                        placeholder={pevnaVEditaci ? 'po založení už nejde změnit'
                          : rezimCeny === 'pevna' ? 'nechte prázdné = z ceníku'
                          : jednotek > 0 ? 'dopočítá se ze sazby' : undefined}
                      />
                    </div>
                  )}
                </div>

                {rezimCeny === 'kalkulacka' && jednotek > 0 && (
                  <p className="text-xs text-muted-foreground">
                    {drahAkce} {drahAkce === 1 ? 'dráha' : drahAkce < 5 ? 'dráhy' : 'drah'} × {hodinAkce} h
                    {' '}= {jednotek} dráhohodin. Cena platí pro celou akci, tedy pro všechny dráhy dohromady.
                  </p>
                )}

                {rezimCeny === 'pevna' && isAdmin && (
                  <p className="text-xs text-muted-foreground">
                    {pevnaVEditaci
                      ? 'Pevnou celkovou cenu už po založení nejde změnit. Když má akce stát jinak, '
                        + 'stornujte ji a založte znovu.'
                      : 'Celková cena platí pro celou akci — všechny dráhy i celou délku dohromady, '
                        + 'ať trvá jakkoli dlouho. Když ji necháte prázdnou, spočítá se cena z ceníku.'}
                  </p>
                )}

                {celkemNevychazi && nejblizsiCelkem && (
                  <p className="text-xs text-amber-700">
                    Tahle částka nevyjde na celé koruny za hodinu
                    ({(sazbaZCelkem ?? 0).toFixed(2)} Kč/h) a databáze ji nepřijme.
                    {' '}Nejbližší možné: <strong>{nejblizsiCelkem[0]} Kč</strong>
                    {' '}nebo <strong>{nejblizsiCelkem[1]} Kč</strong>.
                  </p>
                )}

                {/* CENA PŘED POTVRZENÍM.
                    Klubový led se oceňuje pásmy až v databázi, takže tohle je
                    jediné místo, kde se člověk cenu dozví dřív, než rezervaci
                    potvrdí. Číslo počítá `nahled_ceny_ledu` toutéž funkcí,
                    jakou pak použije zápis — proto se smí ukázat jako cena,
                    ne jako odhad. */}
                {cena?.celkem != null && (
                  <div className="rounded-md border bg-muted/40 p-3 text-sm">
                    <div className="flex items-baseline justify-between gap-3">
                      <span>Cena za {hodinAkce} h{drahAkce > 1 ? ` × ${drahAkce} dráhy` : ''}</span>
                      <strong className="text-base">
                        {cena.celkem.toLocaleString('cs-CZ')} Kč
                      </strong>
                    </div>
                    <p className="text-muted-foreground text-xs mt-1">
                      {cena.bez_dph ? 'Bez DPH.' : 'Včetně DPH.'}
                      {cena.zdroj === 'pasma' && cena.rozpis?.length
                        ? ` Podle ceníku ledu: ${cena.rozpis
                            .map((r) => `${r.hodin} h × ${r.sazba} Kč`)
                            .join(' + ')}.`
                        : cena.sazba != null ? ` Sazba ${cena.sazba.toLocaleString('cs-CZ')} Kč/h.` : ''}
                      {drahAkce > 1 ? ' Cena platí za všechny dráhy dohromady.' : ''}
                    </p>
                  </div>
                )}

                {/* Když ceník nepokrývá zvolenou hodinu, databáze to řekne
                    konkrétně — a je lepší to vědět teď než při potvrzení. */}
                {cenaChyba && (
                  <p className="text-xs text-amber-700">{cenaChyba}</p>
                )}

                {/* Cena je vidět rovnou nad tímhle řádkem, tak už neříkáme
                    „sazbu určuje správce" (znělo to, jako by se cena teprve
                    někde dohadovala). Zbývá jen vysvětlit, proč do ní nejde
                    sáhnout — a co dělat, když nesedí. */}
                {!isAdmin && (
                  <p className="text-xs text-muted-foreground">
                    {/* Větví se podle `zdroj`, ne podle toho, jestli cena vyšla.
                        Klub s dohodnutou `subjects.default_rate` dostane
                        `zdroj='sazba_subjektu'` — tam by věta o „ceníku ledu"
                        lhala a odporovala si s řádkem nad sebou, který v tom
                        případě píše jen „Sazba X Kč/h". Dnes takový klub není
                        ani jeden, ale první dohodnutá cena by to zlomila. */}
                    {cena?.zdroj === 'pasma'
                      ? 'Cena je z platného ceníku ledu a měnit ji může jen správce haly.'
                      : cena?.celkem != null
                        ? 'Cenu určuje sazba sjednaná pro váš klub; měnit ji může jen správce haly.'
                        : 'Cenu spočítá systém podle ceníku; měnit ji může jen správce haly.'}
                  </p>
                )}
              </div>
            )}

            {/* PŘÁNÍ TRENÉRA — jen u tréninku, nezávazné (R7, varianta D).
                Zachytí, koho by si hráč přál, aby to správce klubu nemusel
                obvolávat. Skutečné přiřazení dělá admin nebo správce
                v detailu akce a teprve TÍM vzniká placená směna. */}
            {kind === 'training' && api.treneri.length > 0 && (
              <div className="space-y-2">
                <Label htmlFor="res-trener">Preferovaný trenér (nepovinné)</Label>
                <select
                  id="res-trener"
                  className="h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={praniTrenera}
                  onChange={(e) => setPraniTrenera(e.target.value)}
                >
                  <option value="">Bez přání</option>
                  {api.treneri.map((t) => (
                    <option key={t.user_id} value={t.user_id}>{t.jmeno}</option>
                  ))}
                </select>
                <p className="text-xs text-muted-foreground">
                  Je to jen přání — trenéra přiřazuje správce haly nebo správce klubu.
                </p>
              </div>
            )}

            {/* obsazení štábu */}
            {kind === 'commercial' && !isEdit && (
              <div className="space-y-2">
                <Label>Obsazení (směny)</Label>
                <p className="text-xs text-muted-foreground">
                  Počet instruktorů se předvyplnil podle počtu drah — můžete ho změnit. Bez instruktora akci nelze založit.
                </p>
                {STAFF_ROLES.map(({ key, label }) => (
                  <div key={key} className="flex items-center justify-between rounded-lg bg-muted/50 p-2">
                    <span className="text-sm font-medium">{label}</span>
                    <div className="flex items-center gap-3">
                      <Button type="button" variant="outline" size="icon" className="h-7 w-7"
                        onClick={() => adjust(key, -1)} disabled={(roleCounts[key] ?? 0) <= 0}><Minus className="h-4 w-4" /></Button>
                      <span className="w-6 text-center font-semibold">{roleCounts[key] ?? 0}</span>
                      <Button type="button" variant="outline" size="icon" className="h-7 w-7"
                        onClick={() => adjust(key, 1)}><Plus className="h-4 w-4" /></Button>
                    </div>
                  </div>
                ))}
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="res-note">Poznámka (nepovinné)</Label>
              <Textarea id="res-note" value={note} maxLength={VALIDATION_LIMITS.NOTES_MAX} onChange={(e) => setNote(e.target.value)} />
            </div>
          </div>

          <DialogFooter className="flex-shrink-0">
            <Button variant="outline" onClick={() => onOpenChange(false)}>Zrušit</Button>
            <Button onClick={handleSubmit} disabled={busy}>
              {busy ? 'Ukládám…' : isEdit ? 'Uložit' : repeat ? 'Založit sérii' : 'Rezervovat'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Vědomé přebití — jen admin a jen akcí vyšší priority */}
      <AlertDialog open={!!conflicts} onOpenChange={(o) => !o && setConflicts(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Termín je obsazený — přebít?</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2 text-sm">
                <p>Založením této akce se zruší:</p>
                <ul className="list-disc pl-5">
                  {(conflicts ?? []).map((c) => (
                    <li key={c.reservation_id}>
                      <strong>{c.event_title ?? c.subject_name ?? 'Rezervace'}</strong> — {c.sheet_name},{' '}
                      {format(new Date(c.start_at), 'd. M. HH:mm')}–{format(new Date(c.end_at), 'HH:mm')}
                    </li>
                  ))}
                </ul>
                <p className="text-muted-foreground">
                  Dotčený klub dostane upozornění, že jeho akce byla zrušena kvůli komerční události.
                </p>
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Zpět</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={(e) => { e.preventDefault(); submitBooking(true); }}
            >
              Přebít a rezervovat
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
