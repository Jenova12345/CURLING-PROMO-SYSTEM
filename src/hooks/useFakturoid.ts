import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

/**
 * Vystavení dokladu do Fakturoidu (Etapa 3, varianta S2).
 *
 * ⚠️ TYPY SI TENHLE SOUBOR DEFINUJE SÁM A JE TO ZÁMĚR. Tvar odpovědi zná
 * `billing/`, jenže `src/` z `billing/` importovat NESMÍ — do `src/` sahá Vite
 * bundle a `FAKTUROID_CLIENT_SECRET` nesmí mít ani teoretickou cestu do
 * prohlížeče. Hlídá to `billing/hranice.test.ts`. Duplicita tvaru je levnější
 * než ta díra; když se odpověď Edge funkce změní, musí se to přepsat na obou
 * stranách — proto je na to test v `src/lib/branyFrontendu.test.ts`.
 *
 * REŽIM (`koncept` vs. `odeslat`) SE ODSUD NEPOSÍLÁ. Jediný zdroj je
 * `FAKTUROID_MODE` v prostředí Edge funkce a přebít ho polem v těle požadavku
 * nejde — rozeslaná faktura se nedá vzít zpět.
 */

/** Co se fakturuje. Přesně dvě cesty, které umí `fakturoid-invoice`. */
export type FakturoidPozadavek =
  | { druh: 'klub'; subjectId: string; obdobiOd: string; obdobiDo: string }
  | { druh: 'akce'; eventId: string };

export type FakturoidVarovani = { kod: string; zprava: string };

/**
 * Šest stavů, které Edge funkce umí vrátit. Vyjmenované jako sjednocení, aby
 * volajícího TypeScript donutil ošetřit všechny — „ať to nespadne tiše" je
 * požadavek zadání, ne dobrá vůle.
 */
export type FakturoidVysledek =
  /** Doklad vznikl teď. */
  | { stav: 'vystaveno'; cislo: string | null; variabilniSymbol: string | null;
      publicUrl: string | null; pdfPath: string | null; odeslano: boolean;
      varovani: FakturoidVarovani[] }
  /** Doklad už u Fakturoidu byl a sedí — druhý klik nic nevyrobil. */
  | { stav: 'existoval'; cislo: string | null; variabilniSymbol: string | null;
      publicUrl: string | null; pdfPath: string | null; odeslano: boolean;
      varovani: FakturoidVarovani[] }
  /** Není co fakturovat (všechno už je na dokladu, nebo podklad vyšel na 0 Kč). */
  | { stav: 'prazdne' }
  /** Zámek: rezervace už nese doklad, nebo ji právě vystavuje jiný běh. */
  | { stav: 'preskoceno'; duvod: string }
  /** Doklad u Fakturoidu existuje, ale NESEDÍ s naším podkladem. Patří člověku. */
  | { stav: 'nesedi'; cislo: string | null; duvod: string };

/**
 * Chyba, u které NEVÍME, jestli doklad vznikl.
 *
 * Síťový výpadek nebo timeout mezi naším POSTem a odpovědí Fakturoidu znamená,
 * že doklad MŮŽE existovat — a protože Fakturoid stav „koncept" nezná, byl by
 * rovnou ostrý. Uživateli se to musí říct jinak než „nepovedlo se": opakování
 * je bezpečné (drží zámky v `billing/pipeline.ts`), ale kontrola ve Fakturoidu
 * je na místě.
 */
export class FakturoidNejistaChyba extends Error {
  readonly nejiste = true as const;
}

/** Vytáhne tělo chybové odpovědi z `functions.invoke`. */
const teloChyby = async (error: unknown): Promise<Record<string, unknown> | null> => {
  // `functions.invoke` schová tělo non-2xx odpovědi do obecné hlášky
  // („Edge Function returned a non-2xx status code") a konkrétní důvod nechá
  // v `context`. Bez tohohle dolování by admin u 403 i 409 viděl tutéž větu
  // a neměl šanci zjistit, co se stalo. Vzor je z `useInvoices.ts`.
  const ctx = (error as { context?: Response }).context;
  if (!ctx || typeof ctx.json !== 'function') return null;
  try {
    return (await ctx.json()) as Record<string, unknown>;
  } catch {
    return null;
  }
};

const jakoVarovani = (x: unknown): FakturoidVarovani[] =>
  Array.isArray(x)
    ? x.filter((v): v is FakturoidVarovani =>
        !!v && typeof (v as FakturoidVarovani).kod === 'string'
            && typeof (v as FakturoidVarovani).zprava === 'string')
    : [];

const jakoVysledek = (data: Record<string, unknown>): FakturoidVysledek | null => {
  const stav = data.stav;
  if (stav === 'vystaveno' || stav === 'existoval') {
    return {
      stav,
      cislo: (data.cislo as string) ?? null,
      variabilniSymbol: (data.variabilniSymbol as string) ?? null,
      publicUrl: (data.publicUrl as string) ?? null,
      pdfPath: (data.pdfPath as string) ?? null,
      odeslano: Boolean(data.odeslano),
      varovani: jakoVarovani(data.varovani),
    };
  }
  if (stav === 'prazdne') return { stav: 'prazdne' };
  if (stav === 'preskoceno') {
    return { stav: 'preskoceno', duvod: (data.duvod as string) ?? 'Doklad se právě vystavuje jinde.' };
  }
  if (stav === 'nesedi') {
    return {
      stav: 'nesedi',
      cislo: (data.cislo as string) ?? null,
      duvod: (data.duvod as string) ?? 'Doklad u Fakturoidu nesedí s naším podkladem.',
    };
  }
  return null;
};

export type FakturoidDoklad = Database['public']['Views']['fakturoid_invoices_list']['Row'];

export const useFakturoid = () => {
  const { user, isAdmin } = useAuth();
  const qc = useQueryClient();

  /**
   * Přehled toho, co už do Fakturoidu odešlo. Pohled `fakturoid_invoices_list`
   * ukazuje jen DOKONČENÉ doklady (`provider_invoice_id IS NOT NULL`), takže
   * rozpracovaný claim v něm není — a je to tak správně: dokud doklad u
   * Fakturoidu nevznikl, není co ukazovat.
   */
  const { data: doklady = [], isLoading: nacitamDoklady, error: chybaDokladu } = useQuery({
    queryKey: ['fakturoid-doklady'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('fakturoid_invoices_list')
        .select('*')
        .order('vystaveno_at', { ascending: false });
      if (error) throw error;
      return (data ?? []) as FakturoidDoklad[];
    },
    enabled: !!user && isAdmin,
  });

  const vystavit = useMutation({
    mutationFn: async (pozadavek: FakturoidPozadavek): Promise<FakturoidVysledek> => {
      const { data, error } = await supabase.functions.invoke('fakturoid-invoice', {
        body: pozadavek,
      });

      if (error) {
        const telo = await teloChyby(error);

        // 409 `nesedi` PŘICHÁZÍ JAKO CHYBA, ale není to porucha — je to nález,
        // který patří člověku. Kdyby propadl do obecného `throw`, ztratil by se
        // `duvod` (částky a počty řádků), tedy to jediné, podle čeho se dá
        // rozdíl dohledat.
        if (telo) {
          const vysledek = jakoVysledek(telo);
          if (vysledek) return vysledek;
          if (typeof telo.error === 'string' && telo.error) throw new Error(telo.error);
        }

        // 4xx UŽ VÍME: požadavek odmítla naše strana (vypršená session,
        // chybějící pole, ne-admin), takže se k Fakturoidu vůbec nedostal
        // a doklad nevznikl. Poslat sem admina kontrolovat do Fakturoidu by byl
        // falešný poplach — a falešné poplachy znehodnotí ten jeden pravý níž.
        // (Tuhle větev umí vyrobit i platformní brána `verify_jwt`: vrací
        // `{"code":401,"message":…}`, tedy tělo bez `stav` i bez `error`.)
        const ctx = (error as { context?: Response }).context;
        const urciteNevznikl = typeof ctx?.status === 'number' && ctx.status >= 400 && ctx.status < 500;
        if (urciteNevznikl) {
          throw new Error('Doklad se nevystavil — požadavek se k Fakturoidu nedostal. Přihlas se prosím znovu a zkus to.');
        }

        // Tělo se přečíst nedalo a nešlo o 4xx. Buď spadla síť, nebo funkce
        // nedoběhla — a v obou případech NEVÍME, jestli u Fakturoidu doklad vznikl.
        throw new FakturoidNejistaChyba(
          'Spojení s Fakturoidem se přerušilo, takže nevíme, jestli doklad vznikl. '
          + 'Zkontroluj ho prosím ve Fakturoidu — opakované kliknutí duplicitu nevyrobí.',
        );
      }

      const vysledek = jakoVysledek((data ?? {}) as Record<string, unknown>);
      if (!vysledek) {
        throw new Error('Fakturoid vrátil odpověď, které nerozumíme. Zkontroluj doklad ve Fakturoidu.');
      }
      return vysledek;
    },
    onSuccess: (vysledek) => {
      // Přehledy se přepočítají jen tehdy, když doklad opravdu vznikl.
      // Po `prazdne` ani `nesedi` se nic nezměnilo a zbytečné invalidace
      // překreslí tabulku pod rukama zrovna čtoucího člověka.
      if (vysledek.stav === 'vystaveno' || vysledek.stav === 'existoval') {
        qc.invalidateQueries({ queryKey: ['fakturoid-doklady'] });
        qc.invalidateQueries({ queryKey: ['dues'] });
      }
    },
  });

  /**
   * Podepsaný odkaz na NAŠI kopii PDF.
   *
   * Fakturoid drží originál a `public_url` na něj vede — tohle je ta druhá,
   * naše kopie, kterou si při vystavení ukládáme do privátního bucketu
   * `invoices` (`fakturoid/<klíč>.pdf`). Má cenu právě tehdy, když ta první
   * cesta selže: účet u Fakturoidu vyprší, doklad tam někdo smaže, nebo se
   * jen řeší, co přesně jsme v ten den poslali.
   *
   * ODKAZ PODEPISUJE SERVER, ne my. Bucket má jedinou politiku
   * (`invoices_bucket_service` pro `service_role`), takže z prohlížeče se do
   * něj nedá ani nahlédnout — a je to tak schválně: kontrola role probíhá
   * v Edge funkci na každý požadavek, ne jednou při přihlášení.
   */
  const kopiePdf = useMutation({
    mutationFn: async (fakturoidInvoiceId: string) => {
      const { data, error } = await supabase.functions.invoke('invoice-pdf-url', {
        body: { fakturoid_invoice_id: fakturoidInvoiceId },
      });
      if (error) {
        // TÝŽ `teloChyby` jako u vystavení, ne druhá kopie. `functions.invoke`
        // schová tělo do obecné hlášky, takže by se konkrétní důvod („Naše kopie
        // PDF u tohohle dokladu není…") jinak nikdy neukázal — a dvě
        // implementace téhož dolování v jednom souboru se rozejdou při první
        // opravě. (Nález code review 16. 9. 2026.)
        const telo = await teloChyby(error);
        const duvod = typeof telo?.error === 'string' ? telo.error : '';
        if (duvod) throw new Error(duvod);

        // Platformní brána `verify_jwt` vrací `{"code":401,"message":…}`, tedy
        // tělo BEZ `error` — vypršelá session je u admina, který má stránku
        // otevřenou přes oběd, ten nejpravděpodobnější případ ze všech. Bez
        // tohohle rozlišení by dostal obecné „nepodařilo se získat" a hledal
        // chybu ve svém dokladu.
        const ctx = (error as { context?: Response }).context;
        if (typeof ctx?.status === 'number' && ctx.status === 401) {
          throw new Error('Přihlášení vypršelo. Přihlas se prosím znovu a zkus to.');
        }
        throw new Error('Odkaz ke stažení se nepodařilo získat.');
      }
      const url = (data as { url?: string } | null)?.url;
      if (typeof url !== 'string' || !url) {
        throw new Error('Odkaz ke stažení se nepodařilo získat.');
      }
      return url;
    },
  });

  return {
    doklady,
    nacitamDoklady,
    // MUSÍ JÍT VEN. Bez něj je `doklady = []` při selhání SELECTu
    // nerozeznatelné od „nic nebylo vystaveno" — a na jediné obrazovce, která
    // adminovi říká, co odešlo do OSTRÉ číselné řady, je tahle záměna ta
    // nejhorší možná.
    chybaDokladu,
    vystavit: vystavit.mutateAsync,
    vystavuje: vystavit.isPending,
    kopiePdf: kopiePdf.mutateAsync,
    stahujeKopii: kopiePdf.isPending,
  };
};
