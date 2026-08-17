import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Database } from '@/integrations/supabase/types';

export type InvoiceListRow = Database['public']['Views']['invoices_list']['Row'];
/**
 * Hlavička dokladu. `opravuje_cislo` není sloupec tabulky — dotahuje se
 * u opravného dokladu zvlášť, protože „ruší fakturu č. …" je věta, která na
 * dokladu musí být, a druhý dotaz kvůli jednomu číslu by byl zbytečný.
 */
export type Invoice = Database['public']['Tables']['invoices']['Row'] & {
  opravuje_cislo?: string | null;
};
export type InvoiceItem = Database['public']['Tables']['invoice_items']['Row'];

/**
 * Faktury — čtení přes RLS, zápis VÝHRADNĚ přes RPC.
 *
 * Do `invoices` a `invoice_items` se z klienta zapisovat nedá a je to schválně
 * (rozhodnutí R8): tabulky nemají jedinou zápisovou politiku a `PATCH
 * /rest/v1/invoices` skončí na „permission denied" bez ohledu na roli. Kdo by
 * sem chtěl přidat `supabase.from('invoices').update(...)`, naráží na zeď, která
 * chrání zákonnou neměnnost dokladu — ne na chybu v konfiguraci.
 *
 * Chybové hlášky z RPC se ukazují uživateli tak, jak přišly z databáze: jsou
 * české a napsané pro člověka („Fakturu nelze vystavit — chybí: IČO dodavatele").
 * Přebalit je do obecného „Něco se nepovedlo" by z nich udělalo slepou uličku.
 */
export const useInvoices = () => {
  const { user, isAdmin } = useAuth();
  const qc = useQueryClient();

  const { data: invoices = [], isLoading, error } = useQuery({
    queryKey: ['invoices'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('invoices_list')
        .select('*')
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []) as InvoiceListRow[];
    },
    enabled: !!user && isAdmin,
  });

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['invoices'] });
    // „Kdo dluží" se mění spolu s fakturami: vyfakturovaná rezervace tam zůstane
    // vidět, ale zámek `invoice_id` rozhoduje, co půjde vyfakturovat příště.
    qc.invalidateQueries({ queryKey: ['dues'] });
    qc.invalidateQueries({ queryKey: ['invoice-detail'] });
    // Kontrolní součet se mění s KAŽDOU akcí nad fakturou — bez tohohle by na
    // obrazovce zůstal starý verdikt „sedí to" nad daty, která už sedět nemusí.
    qc.invalidateQueries({ queryKey: ['billing-reconcile'] });
  };

  /** Chyba z PostgREST → text pro uživatele. RPC mluví česky, tak ji neschováváme. */
  const chyba = (e: { message?: string } | null, nahradni: string) =>
    new Error(e?.message?.trim() || nahradni);

  const createClubDraft = useMutation({
    mutationFn: async (p: { subjectId: string; from: string; to: string }) => {
      const { data, error } = await supabase.rpc('create_invoice_draft_club', {
        _subject_id: p.subjectId,
        _obdobi_od: p.from,
        _obdobi_do: p.to,
      });
      if (error) throw chyba(error, 'Koncept faktury se nepodařilo založit.');
      return data as string;
    },
    onSuccess: invalidate,
  });

  const createCommercialDraft = useMutation({
    mutationFn: async (eventId: string) => {
      const { data, error } = await supabase.rpc('create_invoice_draft_commercial', {
        _event_id: eventId,
      });
      if (error) throw chyba(error, 'Koncept faktury se nepodařilo založit.');
      return data as string;
    },
    onSuccess: invalidate,
  });

  const issue = useMutation({
    mutationFn: async (invoiceId: string) => {
      const { data, error } = await supabase.rpc('issue_invoice', { _invoice_id: invoiceId });
      if (error) throw chyba(error, 'Fakturu se nepodařilo vystavit.');
      return data as { cislo: string; total_rounded: number; datum_splatnosti: string };
    },
    onSuccess: invalidate,
  });

  const markPaid = useMutation({
    mutationFn: async (p: { invoiceId: string; datum: string }) => {
      const { data, error } = await supabase.rpc('mark_invoice_paid', {
        _invoice_id: p.invoiceId, _datum: p.datum,
      });
      if (error) throw chyba(error, 'Úhradu se nepodařilo zapsat.');
      return data as { cislo: string; datum_uhrady: string };
    },
    onSuccess: invalidate,
  });

  const unmarkPaid = useMutation({
    mutationFn: async (invoiceId: string) => {
      const { error } = await supabase.rpc('unmark_invoice_paid', { _invoice_id: invoiceId });
      if (error) throw chyba(error, 'Označení úhrady se nepodařilo zrušit.');
    },
    onSuccess: invalidate,
  });

  const deleteDraft = useMutation({
    mutationFn: async (invoiceId: string) => {
      const { data, error } = await supabase.rpc('delete_invoice_draft', { _invoice_id: invoiceId });
      if (error) throw chyba(error, 'Koncept se nepodařilo zahodit.');
      return data as number;
    },
    onSuccess: invalidate,
  });

  /**
   * Odkaz ke stažení serverového PDF.
   *
   * Bucket je privátní, takže odkaz podepisuje Edge funkce — klient si ho
   * vyrobit nemůže a ani nemá. Platnost je krátká (5 minut): má posloužit ke
   * stažení, ne kolovat e-mailem.
   */
  const stahnoutPdf = useMutation({
    mutationFn: async (invoiceId: string) => {
      const { data, error } = await supabase.functions.invoke('invoice-pdf-url', {
        body: { invoice_id: invoiceId },
      });
      // `functions.invoke` schová tělo chybové odpovědi do obecné hlášky, takže
      // se z něj konkrétní důvod („PDF se ještě generuje") dolovává ručně —
      // jinak by admin viděl jen „Edge Function returned a non-2xx status code".
      if (error) {
        let duvod = '';
        const ctx = (error as { context?: Response }).context;
        if (ctx && typeof ctx.json === 'function') {
          try { duvod = (await ctx.json())?.error ?? ''; } catch { duvod = ''; }
        }
        throw new Error(duvod || 'Odkaz ke stažení se nepodařilo získat.');
      }
      return (data as { url: string }).url;
    },
  });

  /**
   * Měsíční ZIP pro účetní. Vrací bajty, ne odkaz: archiv se skládá až na
   * vyžádání a nemá kde ležet.
   */
  const mesicniZip = useMutation({
    mutationFn: async (p: { rok: number; mesic: number }) => {
      const { data, error } = await supabase.functions.invoke('invoice-zip', {
        body: { rok: p.rok, mesic: p.mesic },
      });
      if (error) {
        let duvod = '';
        const ctx = (error as { context?: Response }).context;
        if (ctx && typeof ctx.json === 'function') {
          try { duvod = (await ctx.json())?.error ?? ''; } catch { duvod = ''; }
        }
        throw new Error(duvod || 'Export se nepodařilo sestavit.');
      }
      return data as Blob;
    },
  });

  /** Vrátí doklad do fronty na PDF (po opravě příčiny selhání). */
  const znovuPdf = useMutation({
    mutationFn: async (invoiceId: string) => {
      const { error } = await supabase.rpc('retry_invoice_pdf', { _invoice_id: invoiceId });
      if (error) throw chyba(error, 'Generování se nepodařilo spustit.');
    },
    onSuccess: invalidate,
  });

  /**
   * Storno vystaveného dokladu. Nemaže nic — vystaví OPRAVNÝ DOKLAD, převede
   * originál do stavu „stornováno" a uvolní rezervace zpět k fakturaci.
   */
  const storno = useMutation({
    mutationFn: async (p: { invoiceId: string; duvod?: string }) => {
      const { data, error } = await supabase.rpc('storno_invoice', {
        _invoice_id: p.invoiceId, _duvod: p.duvod ?? undefined,
      });
      if (error) throw chyba(error, 'Doklad se nepodařilo stornovat.');
      return data as {
        opravny_id: string; opravny_cislo: string;
        stornovane_cislo: string; castka: number; uvolneno_rezervaci: number;
      };
    },
    // Storno sahá i na rezervace (uvolní zámek), takže kalendář a přehledy
    // postavené nad nimi jsou po něm staré.
    onSuccess: () => {
      invalidate();
      qc.invalidateQueries({ queryKey: ['reservations'] });
      qc.invalidateQueries({ queryKey: ['billing-reconcile'] });
    },
  });

  return {
    invoices,
    isLoading,
    // Chyba se MUSÍ dostat ven: `useQuery` ji jinak spolkne do `data = []` a
    // stránka pak výpadek sítě nebo zavřenou RLS ukáže jako „zatím tu nic není".
    error: error as Error | null,
    createClubDraft: createClubDraft.mutateAsync,
    createCommercialDraft: createCommercialDraft.mutateAsync,
    issue: issue.mutateAsync,
    deleteDraft: deleteDraft.mutateAsync,
    markPaid: markPaid.mutateAsync,
    unmarkPaid: unmarkPaid.mutateAsync,
    storno: storno.mutateAsync,
    stahnoutPdf: stahnoutPdf.mutateAsync,
    znovuPdf: znovuPdf.mutateAsync,
    mesicniZip: mesicniZip.mutateAsync,
    isBusy: createClubDraft.isPending || createCommercialDraft.isPending
      || issue.isPending || deleteDraft.isPending
      || markPaid.isPending || unmarkPaid.isPending || storno.isPending
      || stahnoutPdf.isPending || znovuPdf.isPending || mesicniZip.isPending,
  };
};

/** Hlavička a položky jedné faktury — načítá se až při otevření detailu. */
export const useInvoiceDetail = (invoiceId: string | null) => {
  const { user, isAdmin } = useAuth();

  return useQuery({
    queryKey: ['invoice-detail', invoiceId],
    queryFn: async () => {
      const [hlavicka, polozky] = await Promise.all([
        supabase.from('invoices').select('*').eq('id', invoiceId!).single(),
        supabase.from('invoice_items').select('*').eq('invoice_id', invoiceId!)
          .order('poradi', { ascending: true }),
      ]);
      if (hlavicka.error) throw hlavicka.error;
      if (polozky.error) throw polozky.error;

      // Číslo opravované faktury. Jen u opravného dokladu, a chyba se nechá
      // spolknout: bez čísla se doklad vytiskne s pomlčkou, kdežto rozbitý
      // detail by adminovi vzal i to, co načíst šlo.
      let opravuje_cislo: string | null = null;
      const h = hlavicka.data as Invoice;
      if (h.opravuje_id) {
        const { data } = await supabase.from('invoices')
          .select('cislo').eq('id', h.opravuje_id).maybeSingle();
        opravuje_cislo = data?.cislo ?? null;
      }

      return {
        invoice: { ...h, opravuje_cislo } as Invoice,
        items: (polozky.data ?? []) as InvoiceItem[],
      };
    },
    enabled: !!user && isAdmin && !!invoiceId,
  });
};

/**
 * Kontrolní součet za období (B6). Sloupec `rozdil` musí být u všech subjektů
 * nula — cokoli jiného je vada, ne stav, a patří na obrazovku, ne do logu.
 */
export const useBillingReconcile = (range: { from: string; to: string } | null) => {
  const { user, isAdmin } = useAuth();

  return useQuery({
    queryKey: ['billing-reconcile', range?.from, range?.to],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('billing_reconcile', {
        _od: range!.from,
        _do: range!.to,
      });
      if (error) throw error;
      return (data ?? []) as Database['public']['Functions']['billing_reconcile']['Returns'];
    },
    enabled: !!user && isAdmin && !!range,
  });
};
