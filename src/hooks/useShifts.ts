import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { popisChybySmeny } from '@/lib/chybySmen';
import { useAuth } from '@/contexts/AuthContext';
import { bezZrusenychAkci, jenNeskoncene } from '@/lib/nabidkySmen';
import {
  spoctiObsazenost, volnoProRoli, smenaPatriRoli, type Obsazenost,
} from '@/lib/obsazenostAkce';

export const useShifts = () => {
  const { user, isAdmin, isStaff, roles } = useAuth();
  const queryClient = useQueryClient();

  // Akce, které jsou zrušené. Chodí z RPC, protože brigádník na `reservations`
  // nevidí a sám by si to spočítat nemohl — viz `src/lib/nabidkySmen.ts`.
  const { data: zruseneAkce = new Set<string>() } = useQuery({
    queryKey: ['zrusene-akce-se-smenami'],
    queryFn: async () => {
      const { data, error } = await (supabase as any).rpc('zrusene_akce_se_smenami');
      if (error) throw error;
      return new Set<string>(((data || []) as string[]).filter(Boolean));
    },
    enabled: !!user && (isAdmin || isStaff),
  });

  // Fetch all staff (all staff roles) for admin to assign shifts
  const { data: availableStaff = [] } = useQuery({
    queryKey: ['available-staff', isAdmin],
    queryFn: async () => {
      // Only fetch if admin
      if (!isAdmin) return [];
      
      // Query for ALL staff roles, not just part_time_staff
      // Use type assertion to handle new roles not yet in Supabase types
      const { data: roleData, error: rolesError } = await supabase
        .from('user_roles')
        .select('user_id')
        .or('role.eq.part_time_staff,role.eq.instructor,role.eq.bar_staff,role.eq.manager');

      if (rolesError) throw rolesError;

      // Get unique user IDs
      const userIds = [...new Set(roleData.map(r => r.user_id))];
      if (userIds.length === 0) return [];

      const { data: profiles, error: profilesError } = await supabase
        .from('profiles')
        .select('user_id, full_name')
        .in('user_id', userIds);

      if (profilesError) throw profilesError;

      return profiles.map(p => ({
        userId: p.user_id,
        fullName: p.full_name || 'Neznámý',
      }));
    },
    enabled: !!user,
  });

  const { data: shifts = [], isLoading } = useQuery({
    queryKey: ['shifts'],
    queryFn: async () => {
      // First get shifts with events
      const { data: shiftsData, error } = await supabase
        .from('shifts')
        .select(`
          *,
          event:events(*)
        `)
        // ŘADÍ SE PODLE DATA AKCE, ne podle pořadí zadání. `created_at` je
        // okamžik, kdy někdo řádek založil — pro brigádníka i pro rozpis je to
        // nezajímavé číslo, které navíc míchá dohromady směny z různých dnů.
        // Vzestupně: nejbližší akce nahoře, ať je vidět, co je na řadě.
        .order('start_time', { referencedTable: 'events', ascending: true });

      if (error) throw error;
      
      // Potřebná jména: kdo směnu vzal, kdo akci založil a kdo ji případně zrušil (audit)
      const userIds = [...new Set(
        shiftsData.flatMap(s => [
          s.claimed_by,
          s.cancelled_by,
          (s.event as { created_by?: string | null } | null)?.created_by,
        ]).filter(Boolean) as string[],
      )];
      
      // Fetch profiles for those users
      let profilesMap: Record<string, { full_name: string; bank_account: string | null }> = {};
      if (userIds.length > 0) {
        // Use profiles_public view which securely hides bank_account from non-admins
        const { data: profiles } = await supabase
          .from('profiles_public')
          .select('user_id, full_name, bank_account')
          .in('user_id', userIds);
        
        if (profiles) {
          profilesMap = profiles.reduce((acc, p) => {
            acc[p.user_id] = { 
              full_name: p.full_name || 'Neznámý',
              bank_account: p.bank_account 
            };
            return acc;
          }, {} as Record<string, { full_name: string; bank_account: string | null }>);
        }
      }
      
      // Merge profile names into shifts
      return shiftsData.map(shift => ({
        ...shift,
        claimed_profile: shift.claimed_by ? {
          full_name: profilesMap[shift.claimed_by]?.full_name || 'Neznámý',
          bank_account: profilesMap[shift.claimed_by]?.bank_account || null
        } : null,
        // audit: „kdo akci zadal" a „kdo směnu zrušil" (požadavek zákazníka)
        created_by_name: (shift.event as { created_by?: string | null } | null)?.created_by
          ? profilesMap[(shift.event as { created_by: string }).created_by]?.full_name || 'Neznámý'
          : null,
        cancelled_by_name: shift.cancelled_by
          ? profilesMap[shift.cancelled_by]?.full_name || 'Neznámý'
          : null,
      }));
    },
    enabled: !!user && (isAdmin || isStaff),
  });

  // Staff requests a shift (open -> pending)
  const requestShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'pending',
          claimed_by: user?.id,
          claimed_at: new Date().toISOString(),
        })
        .eq('id', shiftId)
        .eq('status', 'open')
        .select()
        .single();

      if (error) {
        // Hláška z databáze se propouští, protože nese důvod, který uživatel
        // jinak nemá odkud vzít: obecné „nepodařilo se" u zrušené akce vypadá
        // jako výpadek, ne jako pravidlo. Seznam propouštěných vět a důvod,
        // proč je to na jednom místě, je v `@/lib/chybySmen`.
        //
        // Dřív tu stály tři ručně psané větve a jedna z nich („již máte jinou
        // směnu") hlídala text, který databáze od 1. 9. 2026 neposílá — byla
        // přes dva týdny mrtvá a uživatel místo důvodu dostával obecnou větu.
        throw new Error(popisChybySmeny(
          error.message, 'Nepodařilo se přihlásit na směnu.', 'sam'));
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
    onError: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Admin approves shift (pending -> claimed)
  const approveShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'claimed',
        })
        .eq('id', shiftId)
        .eq('status', 'pending')
        .select()
        .single();

      if (error) {
        throw new Error(popisChybySmeny(error.message, 'Nepodařilo se schválit směnu.'));
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Admin rejects shift (pending -> open)
  const rejectShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'open',
          claimed_by: null,
          claimed_at: null,
        })
        .eq('id', shiftId)
        .eq('status', 'pending')
        .select()
        .single();

      if (error) {
        throw new Error('Nepodařilo se odmítnout přihlášku.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Admin completes shift (claimed -> completed)
  const completeShift = useMutation({
    mutationFn: async ({ shiftId, hoursWorked, hourlyRate, notes }: { 
      shiftId: string; 
      hoursWorked: number;
      hourlyRate: number;
      notes?: string;
    }) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'completed',
          hours_worked: hoursWorked,
          hourly_rate: hourlyRate,
          notes,
          completed_at: new Date().toISOString(),
        })
        .eq('id', shiftId)
        .eq('status', 'claimed')
        .select()
        .single();

      if (error) {
        if (error.message.includes('Pouze admin')) {
          throw new Error('Pouze admin může dokončit směnu.');
        }
        if (error.message.includes('odpracované hodiny')) {
          throw new Error('Musíte zadat odpracované hodiny.');
        }
        throw new Error('Nepodařilo se dokončit směnu.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Admin completes multiple shifts with individual values for each
  const completeShiftsIndividually = useMutation({
    mutationFn: async ({ 
      shiftsData, 
      notes 
    }: { 
      shiftsData: Array<{
        shiftId: string;
        hoursWorked: number;
        hourlyRate: number;
        manualAmount?: number; // Optional: if set, we store rate calculated back from manual amount
      }>;
      notes?: string;
    }) => {
      // Update each shift individually
      const updates = shiftsData.map(async (shift) => {
        // If manual amount is provided, calculate hourly_rate back from it for consistency
        const finalHourlyRate = shift.manualAmount 
          ? (shift.hoursWorked > 0 ? shift.manualAmount / shift.hoursWorked : shift.hourlyRate)
          : shift.hourlyRate;

        const { data, error } = await supabase
          .from('shifts')
          .update({
            status: 'completed',
            hours_worked: shift.hoursWorked,
            hourly_rate: finalHourlyRate,
            notes,
            completed_at: new Date().toISOString(),
          })
          .eq('id', shift.shiftId)
          .eq('status', 'claimed')
          .select()
          .single();
        
        if (error) throw error;
        return data;
      });
      
      return Promise.all(updates);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Staff cancels their pending request
  const cancelRequest = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'open',
          claimed_by: null,
          claimed_at: null,
        })
        .eq('id', shiftId)
        .select()
        .single();

      if (error) {
        if (error.message.includes('cizí přihlášku')) {
          throw new Error('Nemůžete zrušit cizí přihlášku.');
        }
        throw new Error('Nepodařilo se zrušit přihlášku.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
    onError: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Cancel claimed shift
  const cancelShift = useMutation({
    mutationFn: async (shiftId: string) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'open',
          claimed_by: null,
          claimed_at: null,
        })
        .eq('id', shiftId)
        .select()
        .single();

      if (error) {
        if (error.message.includes('cizí směnu')) {
          throw new Error('Nemůžete zrušit cizí směnu.');
        }
        throw new Error('Nepodařilo se zrušit směnu.');
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
    onError: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  // Admin directly assigns a staff member to a shift (open -> claimed, bypassing pending)
  const assignShift = useMutation({
    mutationFn: async ({ shiftId, staffId }: { shiftId: string; staffId: string }) => {
      const { data, error } = await supabase
        .from('shifts')
        .update({
          status: 'claimed',
          claimed_by: staffId,
          claimed_at: new Date().toISOString(),
        })
        .eq('id', shiftId)
        .eq('status', 'open')
        .select()
        .single();

      if (error) {
        // TOHLE MÍSTO HLÁŠKU Z DATABÁZE ZAHAZOVALO ÚPLNĚ.
        // `assignShift` je druhá cesta `open -> claimed` (první je schvalování
        // přihlášky) a admin tu po migraci 20260914200000 může narazit na
        // „Tenhle člověk už na této akci tuhle roli má." — s původní obecnou
        // větou by hledal výpadek místo pravidla.
        throw new Error(popisChybySmeny(error.message, 'Nepodařilo se přiřadit směnu.'));
      }
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['shifts'] });
    },
  });

  const myShifts = shifts.filter(s => s.claimed_by === user?.id);
  
  // My pending shifts (waiting for admin approval)
  const myPendingShifts = myShifts.filter(s => s.status === 'pending');
  
  // My confirmed shifts (only claimed, upcoming)
  const myConfirmedShifts = myShifts.filter(s => s.status === 'claimed');
  
  // Get event IDs where the user already has a pending, claimed or completed shift
  const myEventIds = new Set(
    myShifts
      .filter(s => s.status === 'pending' || s.status === 'claimed' || s.status === 'completed')
      .map(s => s.event_id)
  );
  
  // Filter open shifts - exclude events where user already has a shift
  // Staff sees only shifts matching their roles (or shifts without required_role for backward compat)
  //
  // Směny zrušených akcí se nenabízejí (Jakubův nález 3. 9. 2026). Je to druhá
  // pojistka — po migraci 20260903120000 je taková směna v databázi `cancelled`,
  // takže sem nedojde. Filtr chrání případ, kdy by se sem starší řádek dostal
  // dřív, než ho invariant zavře.
  //
  // VOLNÁ SMĚNA NA AKCI, KTERÁ UŽ SKONČILA, NENÍ NABÍDKA. Do 14. 9. 2026 se tu
  // filtroval jen stav a role, takže neobsazená směna visela v nabídce navždycky —
  // brigádníkovi mezi tím, na co se může přihlásit (a přihlásit se nedá, akce
  // byla), a adminovi v „Směny kde chybí brigádníci" jako úkol, který už nejde
  // splnit. Na produkci to 14. 9. 2026 ještě nebylo vidět (0 volných směn na
  // skončených akcích — hala je v provozu krátce), ale stane se to první akcí,
  // která proběhne neobsazená.
  //
  // Filtr sedí ZDE, v jednom zdroji: `openShifts` živí nabídku brigádníka,
  // adminský seznam i čítač na Přehledu. Kdyby se filtrovalo až v komponentě,
  // kryla by se jedna z těch tří cest a zbylé dvě by ukazovaly jiné číslo.
  //
  // Podmínku „smím tuhle roli vzít?" drží `smenaPatriRoli` v `@/lib/obsazenostAkce`,
  // protože TÝŽ predikát potřebuje i čítač „Volné pro tvoji roli". Dokud byl
  // opsaný tady, počítala nabídka jedno a čítač druhé (ticket Hyundai, 15. 9. 2026).
  const kdoSeDiva = { role: roles, isAdmin };
  const openShifts = jenNeskoncene(bezZrusenychAkci(shifts, zruseneAkce)).filter(s => {
    if (s.status !== 'open') return false;
    if (myEventIds.has(s.event_id)) return false;
    return smenaPatriRoli((s as { required_role?: string | null }).required_role, kdoSeDiva);
  });

  // Group open shifts by event_id for staff view (show one entry per event)
  //
  // ČÍTAČ UŽ SE TU NESKLÁDÁ. Dřív tu vedle sebe stály `openCount` (volné směny
  // PO filtru rolí) a `totalSlots` (`shifts.filter(...).length`, tedy BEZ filtru).
  // Instruktorovi z toho u akce se třemi pozicemi vycházelo „2/3", zatímco
  // kalendář u téže akce hlásil „0/3" — dvě čísla ze dvou různých výpočtů.
  // Teď jde obojí ze `spoctiObsazenost` nad VŠEMI směnami akce, stejně jako
  // v kalendáři; role řeší jen doplňkové `volnoProMe`.
  const openShiftsByEvent = Object.values(
    openShifts.reduce((acc, shift) => {
      const eventId = shift.event_id;
      if (!acc[eventId]) {
        const obsazenost = spoctiObsazenost(
          shifts.filter(s => s.event_id === eventId) as { status?: string | null; required_role?: string | null }[],
        );
        acc[eventId] = {
          eventId,
          event: shift.event,
          hourlyRate: shift.hourly_rate,
          availableShiftIds: [],
          availableShifts: [],  // Include shift data for role display
          obsazenost,
          volnoProMe: volnoProRoli(obsazenost, kdoSeDiva),
        };
      }
      acc[eventId].availableShiftIds.push(shift.id);
      acc[eventId].availableShifts.push(shift);
      return acc;
    }, {} as Record<string, { eventId: string; event: any; hourlyRate: number | null; availableShiftIds: string[]; availableShifts: any[]; obsazenost: Obsazenost; volnoProMe: number }>)
  ).sort((a, b) => {
    const aTime = a.event?.start_time ? new Date(a.event.start_time).getTime() : 0;
    const bTime = b.event?.start_time ? new Date(b.event.start_time).getTime() : 0;
    return aTime - bTime;
  });
  
  // Pending shifts for admin approval - sorted by nearest event
  const pendingShifts = shifts
    .filter(s => s.status === 'pending')
    .sort((a, b) => {
      const aTime = a.event?.start_time ? new Date(a.event.start_time).getTime() : 0;
      const bTime = b.event?.start_time ? new Date(b.event.start_time).getTime() : 0;
      return aTime - bTime;
    });
  
  // Claimed shifts ready to be completed (event has passed)
  const shiftsToComplete = shifts.filter(s => {
    if (s.status !== 'claimed') return false;
    if (!s.event?.end_time) return false;
    return new Date(s.event.end_time) < new Date();
  });

  // Group shifts to complete by event (for admin to complete whole events at once) - sorted by earliest end time
  const eventsToComplete = Object.values(
    shiftsToComplete.reduce((acc, shift) => {
      const eventId = shift.event_id;
      if (!acc[eventId]) {
        acc[eventId] = {
          eventId,
          event: shift.event,
          hourlyRate: shift.hourly_rate,
          shifts: [],
          staffNames: [],
        };
      }
      acc[eventId].shifts.push(shift);
      if (shift.claimed_profile?.full_name) {
        acc[eventId].staffNames.push(shift.claimed_profile.full_name);
      }
      return acc;
    }, {} as Record<string, { eventId: string; event: any; hourlyRate: number | null; shifts: any[]; staffNames: string[] }>)
  ).sort((a, b) => {
    const aTime = a.event?.end_time ? new Date(a.event.end_time).getTime() : 0;
    const bTime = b.event?.end_time ? new Date(b.event.end_time).getTime() : 0;
    return aTime - bTime;
  });

  // Upcoming shifts - future events with staff assigned (claimed or completed)
  const upcomingShifts = shifts
    .filter(s => {
      if (!s.event?.start_time) return false;
      const isFuture = new Date(s.event.start_time) > new Date();
      const hasStaff = s.status === 'claimed' || s.status === 'completed';
      return isFuture && hasStaff;
    })
    .sort((a, b) => {
      const aTime = new Date(a.event!.start_time).getTime();
      const bTime = new Date(b.event!.start_time).getTime();
      return aTime - bTime;
    });

  // Group upcoming shifts by event
  const upcomingShiftsByEvent = Object.values(
    upcomingShifts.reduce((acc, shift) => {
      const eventId = shift.event_id;
      if (!acc[eventId]) {
        acc[eventId] = {
          eventId,
          event: shift.event,
          shifts: [],
          staffNames: [],
        };
      }
      acc[eventId].shifts.push(shift);
      if (shift.claimed_profile?.full_name) {
        acc[eventId].staffNames.push(shift.claimed_profile.full_name);
      }
      return acc;
    }, {} as Record<string, { eventId: string; event: any; shifts: any[]; staffNames: string[] }>)
  ).sort((a, b) => {
    const aTime = a.event?.start_time ? new Date(a.event.start_time).getTime() : 0;
    const bTime = b.event?.start_time ? new Date(b.event.start_time).getTime() : 0;
    return aTime - bTime;
  });

  // History shifts - completed shifts from last 2 months
  const twoMonthsAgo = new Date();
  twoMonthsAgo.setMonth(twoMonthsAgo.getMonth() - 2);
  
  const historyShifts = shifts
    .filter(s => {
      if (s.status !== 'completed') return false;
      if (!s.event?.start_time) return false;
      return new Date(s.event.start_time) >= twoMonthsAgo;
    })
    .sort((a, b) => {
      const aTime = new Date(a.event!.start_time).getTime();
      const bTime = new Date(b.event!.start_time).getTime();
      return bTime - aTime; // Newest first
    });
  
  // My completed unpaid shifts
  const myUnpaidShifts = myShifts.filter(s => s.status === 'completed' && !s.payout_id);
  
  const myCompletedShifts = myShifts.filter(s => s.status === 'completed');
  
  const totalHoursWorked = myCompletedShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0), 
    0
  );
  
  // Unpaid earnings (only completed shifts without payout_id)
  const unpaidEarnings = myUnpaidShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0) * (Number(shift.hourly_rate) || 150),
    0
  );
  
  // Total earnings (all completed shifts)
  const totalEarnings = myCompletedShifts.reduce(
    (sum, shift) => sum + (Number(shift.hours_worked) || 0) * (Number(shift.hourly_rate) || 150),
    0
  );

  // Get unpaid amounts per staff member (for admin)
  const staffUnpaidAmounts = shifts
    .filter(s => s.status === 'completed' && !s.payout_id && s.claimed_by)
    .reduce((acc, shift) => {
      const staffId = shift.claimed_by!;
      const amount = (Number(shift.hours_worked) || 0) * (Number(shift.hourly_rate) || 150);
      if (!acc[staffId]) {
        acc[staffId] = {
          staffId,
          staffName: shift.claimed_profile?.full_name || 'Neznámý',
          bankAccount: shift.claimed_profile?.bank_account || null,
          amount: 0,
          shiftCount: 0,
        };
      }
      acc[staffId].amount += amount;
      acc[staffId].shiftCount += 1;
      return acc;
    }, {} as Record<string, { staffId: string; staffName: string; bankAccount: string | null; amount: number; shiftCount: number }>);

  // Admin statistics
  const allCompletedShifts = shifts.filter(s => s.status === 'completed');
  
  const adminStats = {
    totalPaidOut: 0, // Will be calculated from payouts in component
    totalHoursAllStaff: allCompletedShifts.reduce((sum, s) => sum + (Number(s.hours_worked) || 0), 0),
    totalEarningsAllStaff: allCompletedShifts.reduce((sum, s) => sum + (Number(s.hours_worked) || 0) * (Number(s.hourly_rate) || 150), 0),
    unpaidTotal: allCompletedShifts.filter(s => !s.payout_id).reduce((sum, s) => sum + (Number(s.hours_worked) || 0) * (Number(s.hourly_rate) || 150), 0),
    activeStaffCount: new Set(allCompletedShifts.map(s => s.claimed_by)).size,
    completedShiftsCount: allCompletedShifts.length,
    
    // Per-staff breakdown
    staffStats: allCompletedShifts.reduce((acc, shift) => {
      const staffId = shift.claimed_by;
      if (!staffId) return acc;
      
      const hours = Number(shift.hours_worked) || 0;
      const earnings = hours * (Number(shift.hourly_rate) || 150);
      const isPaid = !!shift.payout_id;
      
      if (!acc[staffId]) {
        acc[staffId] = {
          staffId,
          staffName: shift.claimed_profile?.full_name || 'Neznámý',
          shiftsCount: 0,
          hoursWorked: 0,
          totalEarnings: 0,
          paidAmount: 0,
          unpaidAmount: 0,
        };
      }
      
      acc[staffId].shiftsCount += 1;
      acc[staffId].hoursWorked += hours;
      acc[staffId].totalEarnings += earnings;
      if (isPaid) {
        acc[staffId].paidAmount += earnings;
      } else {
        acc[staffId].unpaidAmount += earnings;
      }
      
      return acc;
    }, {} as Record<string, { staffId: string; staffName: string; shiftsCount: number; hoursWorked: number; totalEarnings: number; paidAmount: number; unpaidAmount: number }>),
  };

  return {
    shifts,
    // Ven kvůli kalendáři: `IceCalendar` si staví vlastní seznam nabídek
    // z `shifts`, takže potřebuje tentýž filtr. Kdyby ho neměl, pojistka by
    // kryla jen jednu ze dvou cest, kterými se brigádníkovi směna nabídne.
    zruseneAkce,
    openShifts,
    openShiftsByEvent,
    availableStaff,
    myShifts,
    myPendingShifts,
    myConfirmedShifts,
    myCompletedShifts,
    myUnpaidShifts,
    pendingShifts,
    shiftsToComplete,
    eventsToComplete,
    upcomingShifts,
    upcomingShiftsByEvent,
    historyShifts,
    staffUnpaidAmounts: Object.values(staffUnpaidAmounts),
    adminStats: {
      ...adminStats,
      staffStats: Object.values(adminStats.staffStats),
    },
    isLoading,
    requestShift: requestShift.mutateAsync,
    approveShift: approveShift.mutateAsync,
    rejectShift: rejectShift.mutateAsync,
    completeShift: completeShift.mutateAsync,
    completeShiftsIndividually: completeShiftsIndividually.mutateAsync,
    cancelRequest: cancelRequest.mutateAsync,
    cancelShift: cancelShift.mutateAsync,
    assignShift: assignShift.mutateAsync,
    isRequesting: requestShift.isPending,
    isApproving: approveShift.isPending,
    isRejecting: rejectShift.isPending,
    isCompleting: completeShift.isPending || completeShiftsIndividually.isPending,
    isAssigning: assignShift.isPending,
    totalHoursWorked,
    unpaidEarnings,
    totalEarnings,
  };
};
