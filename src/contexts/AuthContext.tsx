// Auth context for managing user authentication state
import React, { createContext, useContext, useEffect, useState, useCallback } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { User, Session } from '@supabase/supabase-js';
import { supabase } from '@/integrations/supabase/client';

type AppRole = 'admin' | 'trainer' | 'part_time_staff' | 'instructor' | 'bar_staff' | 'manager' | 'pro_player' | 'hobby_player';

// Role priority for determining primary role
const ROLE_PRIORITY: AppRole[] = [
  'admin', 'trainer', 'manager', 'instructor', 'bar_staff', 
  'part_time_staff', 'pro_player', 'hobby_player'
];

const getPrimaryRole = (userRoles: AppRole[]): AppRole => {
  for (const r of ROLE_PRIORITY) {
    if (userRoles.includes(r)) return r;
  }
  return 'hobby_player';
};

interface Profile {
  id: string;
  user_id: string;
  full_name: string | null;
  phone: string | null;
  bank_account: string | null;
}

interface AuthContextType {
  user: User | null;
  session: Session | null;
  profile: Profile | null;
  role: AppRole | null;           // Primary role (backward compat)
  roles: AppRole[];               // All user roles
  loading: boolean;
  signIn: (email: string, password: string) => Promise<{ error: Error | null }>;
  signUp: (email: string, password: string, fullName: string) => Promise<{ error: Error | null }>;
  signOut: () => Promise<void>;
  hasAnyRole: (allowedRoles: string[]) => boolean;
  isAdmin: boolean;
  isTrainer: boolean;
  isStaff: boolean;
  isMember: boolean;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  // `AuthProvider` je uvnitř `QueryClientProvider` (App.tsx), takže tenhle hook
  // tu je dostupný — a odhlášení díky němu umí vyprázdnit i cache dotazů.
  const qc = useQueryClient();
  const [user, setUser] = useState<User | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [role, setRole] = useState<AppRole | null>(null);
  const [roles, setRoles] = useState<AppRole[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchUserData = async (userId: string) => {
    console.log('[AuthContext] fetchUserData started for:', userId);
    
    try {
      // Fetch profile
      const { data: profileData, error: profileError } = await supabase
      // Čte se z pohledu, ne z tabulky: telefon a bankovní účet jsou po A5
      // v `profiles` nečitelné napřímo a pohled je vydá jen vlastníkovi
      // a adminovi. Zápis dál míří na tabulku, kde ho hlídá RLS.
        .from('profiles_self')
        .select('*')
        .eq('user_id', userId)
        .single();
      
      // Schválně se neloguje celý `profileData` — je v něm `bank_account`,
      // takže by si každý uživatel při každém přihlášení vypsal do konzole
      // vlastní číslo účtu. Pro ladění stačí vědět, že profil dorazil.
      console.log('[AuthContext] Profile fetch result:', { nalezen: !!profileData, profileError });
      
      if (profileData) {
        setProfile(profileData);
      }

      // Fetch ALL roles for user
      const { data: rolesData, error: roleError } = await supabase
        .from('user_roles')
        .select('role')
        .eq('user_id', userId);
      
      console.log('[AuthContext] Roles fetch result:', { rolesData, roleError });
      
      if (rolesData && rolesData.length > 0) {
        const userRoles = rolesData.map(r => r.role as AppRole);
        setRoles(userRoles);
        const primaryRole = getPrimaryRole(userRoles);
        setRole(primaryRole);
        console.log('[AuthContext] Roles successfully set to:', userRoles, 'Primary:', primaryRole);
      } else {
        console.warn('[AuthContext] No roles found for user, defaulting to hobby_player');
        setRoles(['hobby_player']);
        setRole('hobby_player');
      }
    } catch (error) {
      console.error('[AuthContext] Error fetching user data:', error);
      setRoles(['hobby_player']);
      setRole('hobby_player');
    }
  };

  useEffect(() => {
    let mounted = true;

    // Set up auth state listener FIRST
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (event, session) => {
        console.log('[AuthContext] Auth state changed:', event);
        
        setSession(session);
        setUser(session?.user ?? null);
        
        if (session?.user) {
          // Use setTimeout to avoid Supabase auth deadlock
          setTimeout(() => {
            fetchUserData(session.user.id).finally(() => {
              if (mounted) {
                setLoading(false);
              }
            });
          }, 0);
        } else {
          setProfile(null);
          setRole(null);
          setRoles([]);
          if (mounted) {
            setLoading(false);
          }
        }
      }
    );

    // THEN check for existing session
    supabase.auth.getSession().then(({ data: { session } }) => {
      console.log('[AuthContext] Initial session check:', session?.user?.id);
      
      setSession(session);
      setUser(session?.user ?? null);
      
      if (session?.user) {
        fetchUserData(session.user.id).finally(() => {
          if (mounted) {
            setLoading(false);
          }
        });
      } else {
        if (mounted) {
          setLoading(false);
        }
      }
    });

    return () => {
      mounted = false;
      subscription.unsubscribe();
    };
  }, []);

  const signIn = async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });
    return { error: error as Error | null };
  };

  const signUp = async (email: string, password: string, fullName: string) => {
    const redirectUrl = `${window.location.origin}/`;
    
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        emailRedirectTo: redirectUrl,
        data: {
          full_name: fullName,
        },
      },
    });
    return { error: error as Error | null };
  };

  const signOut = async () => {
    await supabase.auth.signOut();
    // POŘADÍ JE ZÁMĚRNÉ: nejdřív se srovná stav, teprve pak se sahá na cache.
    // `qc.clear()` je jediný cizí kód mezi odhlášením a resetem — kdyby vyhodil
    // dřív, zůstal by uživatel v UI přihlášený nad mrtvou session a odhlásit by
    // se už nedokázal, protože ta cesta padá na témže řádku.
    setUser(null);
    setSession(null);
    setProfile(null);
    setRole(null);
    setRoles([]);
    try {
      // Vyprázdnit i cache dotazů: `billing-settings` s IBANem a IČEM by jinak
      // zůstalo v paměti ještě několik minut po odhlášení. Dalšímu uživateli se
      // nezobrazí (uid je součástí klíče), ale data by přežila přihlašovací údaj,
      // který je autorizoval. Dotazy jsou v tu chvíli už vypnuté (`enabled`
      // závisí na `user`), takže se tím nic znovu nenačte.
      qc.clear();
    } catch {
      /* odhlášení je důležitější než úklid cache — ta zmizí nejpozději s reloadem */
    }
  };

  const hasAnyRole = useCallback((allowedRoles: string[]): boolean => {
    return roles.some(r => allowedRoles.includes(r));
  }, [roles]);

  // Derived values using roles array
  const isAdmin = roles.includes('admin');
  const isTrainer = roles.includes('trainer');
  const isStaff = roles.some(r => 
    ['part_time_staff', 'instructor', 'bar_staff', 'manager'].includes(r)
  );
  const isMember = roles.some(r => ['hobby_player', 'pro_player'].includes(r));

  return (
    <AuthContext.Provider
      value={{
        user,
        session,
        profile,
        role,
        roles,
        loading,
        signIn,
        signUp,
        signOut,
        hasAnyRole,
        isAdmin,
        isTrainer,
        isStaff,
        isMember,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
};
