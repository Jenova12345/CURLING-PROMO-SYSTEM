/**
 * Profile Page
 * 
 * Security Features:
 * - Schema-based validation for profile updates
 * - File type and size validation for avatar uploads
 * - Input length limits
 * - Rate limiting for profile updates
 */

import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useProfile } from '@/hooks/useProfile';
import { useShifts } from '@/hooks/useShifts';
import { usePayouts } from '@/hooks/usePayouts';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { User, Phone, Clock, TrendingUp, Wallet, CheckCircle, CreditCard } from 'lucide-react';
import ClenstviVKlubu from '@/components/profile/ClenstviVKlubu';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { 
  profileUpdateSchema, 
  safeValidate, 
  VALIDATION_LIMITS,
  sanitizeText 
} from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';

const Profile = () => {
  const { profile, role, isStaff } = useAuth();
  const { updateProfile, isUpdating } = useProfile();
  const { myShifts, totalHoursWorked, totalEarnings, unpaidEarnings } = useShifts();
  const { myPayouts } = usePayouts();
  const { toast } = useToast();
  const profileRateLimit = useRateLimit('updateProfile');

  const [fullName, setFullName] = useState(profile?.full_name || '');
  const [phone, setPhone] = useState(profile?.phone || '');
  const [bankAccount, setBankAccount] = useState(profile?.bank_account || '');
  const [validationError, setValidationError] = useState<string | null>(null);
  const [saveSuccess, setSaveSuccess] = useState(false);

  const roleLabels: Record<string, string> = {
    admin: 'Správce',
    trainer: 'Trenér',
    part_time_staff: 'Brigádník',
    pro_player: 'Profi hráč',
    hobby_player: 'Hobby hráč',
  };

  const handleSaveProfile = async () => {
    setValidationError(null);
    
    // Check rate limit
    if (!profileRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho pokusů',
        description: `Zkuste to znovu za ${profileRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }
    
    // Sanitize and validate input
    const sanitizedData = {
      fullName: sanitizeText(fullName),
      phone: phone.trim(),
      bankAccount: bankAccount.trim(),
    };
    
    // For staff, bank account is required
    if (isStaff && !sanitizedData.bankAccount) {
      setValidationError('Číslo účtu je povinné pro brigádníky.');
      toast({
        title: 'Chyba validace',
        description: 'Číslo účtu je povinné pro brigádníky.',
        variant: 'destructive',
      });
      return;
    }
    
    const validation = safeValidate(profileUpdateSchema, sanitizedData);
    
    if (!validation.success) {
      setValidationError(validation.error);
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }
    
    try {
      await updateProfile(validation.data);
      setSaveSuccess(true);
      toast({
        title: '✓ Profil uložen',
        description: 'Vaše údaje byly úspěšně aktualizovány.',
      });
      // Reset success state after animation
      setTimeout(() => setSaveSuccess(false), 2000);
    } catch {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se uložit profil.',
        variant: 'destructive',
      });
    }
  };

  const completedShifts = myShifts.filter(s => s.status === 'completed');

  const statusColors: Record<string, string> = {
    open: 'bg-green-500',
    pending: 'bg-yellow-500',
    claimed: 'bg-blue-500',
    completed: 'bg-gray-500',
  };

  return (
    <div className="p-4 md:p-6 space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl md:text-3xl font-bold">Můj profil</h1>
        <p className="text-muted-foreground mt-1">Správa osobních údajů a přehled statistik</p>
      </div>

      <div className="grid gap-6 md:grid-cols-3">
        {/* Profile Card */}
        <Card className="md:col-span-1">
          <CardHeader>
            <CardTitle>Osobní údaje</CardTitle>
            <CardDescription>Aktualizujte své kontaktní informace</CardDescription>
          </CardHeader>
          <CardContent className="space-y-6">
            {/* User Icon */}
            <div className="flex flex-col items-center">
              <div className="flex h-24 w-24 items-center justify-center rounded-full bg-primary text-primary-foreground">
                <User className="h-12 w-12" />
              </div>
              <Badge className="mt-3" variant="secondary">
                {role ? roleLabels[role] : 'Člen'}
              </Badge>
            </div>

            {/* Validation error */}
            {validationError && (
              <div className="p-3 text-sm text-destructive bg-destructive/10 rounded-md">
                {validationError}
              </div>
            )}

            {/* Rate limit warning */}
            {profileRateLimit.isLimited && (
              <div className="p-3 text-sm text-destructive bg-destructive/10 rounded-md">
                Příliš mnoho pokusů. Zkuste to za {profileRateLimit.retryAfter}.
              </div>
            )}

            {/* Form */}
            <div className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="fullName" className="flex items-center gap-2">
                  <User className="h-4 w-4" />
                  Jméno a příjmení
                </Label>
                <Input
                  id="fullName"
                  value={fullName}
                  onChange={(e) => {
                    setFullName(e.target.value);
                    setValidationError(null);
                  }}
                  placeholder="Jan Novák"
                  maxLength={VALIDATION_LIMITS.NAME_MAX}
                  autoComplete="name"
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="phone" className="flex items-center gap-2">
                  <Phone className="h-4 w-4" />
                  Telefon
                </Label>
                <Input
                  id="phone"
                  value={phone}
                  onChange={(e) => {
                    setPhone(e.target.value);
                    setValidationError(null);
                  }}
                  placeholder="+420 123 456 789"
                  maxLength={VALIDATION_LIMITS.PHONE_MAX}
                  autoComplete="tel"
                />
                <p className="text-xs text-muted-foreground">
                  Formát: +420 123 456 789
                </p>
              </div>

              {/* Bank Account - only for staff */}
              {isStaff && (
                <div className="space-y-2">
                  <Label htmlFor="bankAccount" className="flex items-center gap-2">
                    <CreditCard className="h-4 w-4" />
                    Číslo účtu <span className="text-destructive">*</span>
                  </Label>
                  <Input
                    id="bankAccount"
                    value={bankAccount}
                    onChange={(e) => {
                      setBankAccount(e.target.value);
                      setValidationError(null);
                    }}
                    placeholder="123456-1234567890/0100"
                    maxLength={VALIDATION_LIMITS.BANK_ACCOUNT_MAX}
                    autoComplete="off"
                  />
                  <p className="text-xs text-muted-foreground">
                    Formát: 123456-1234567890/0100 nebo IBAN
                  </p>
                </div>
              )}

              <Button 
                onClick={handleSaveProfile} 
                disabled={isUpdating || profileRateLimit.isLimited}
                className={`w-full transition-all duration-300 ${saveSuccess ? 'bg-green-600 hover:bg-green-600' : ''}`}
              >
                {isUpdating ? (
                  'Ukládání...'
                ) : saveSuccess ? (
                  <span className="flex items-center gap-2">
                    <CheckCircle className="h-4 w-4" />
                    Uloženo!
                  </span>
                ) : (
                  'Uložit změny'
                )}
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Stats & History */}
        <div className="md:col-span-2 space-y-6">
          {/* Členství v klubu — a cesta, jak o něj požádat, když si ho člověk
              nevybral při registraci. */}
          <ClenstviVKlubu />

          {/* Stats Cards */}
          <div className="grid gap-4 grid-cols-2 lg:grid-cols-4">
            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Směn celkem</CardTitle>
                <CheckCircle className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{completedShifts.length}</div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Odpracováno</CardTitle>
                <Clock className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{totalHoursWorked} h</div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Celkem vyděláno</CardTitle>
                <TrendingUp className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{totalEarnings.toLocaleString('cs-CZ')} Kč</div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">K výplatě</CardTitle>
                <Wallet className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold text-green-600">{unpaidEarnings.toLocaleString('cs-CZ')} Kč</div>
              </CardContent>
            </Card>
          </div>

          {/* History Tabs */}
          <Card>
            <CardHeader>
              <CardTitle>Historie</CardTitle>
            </CardHeader>
            <CardContent>
              <Tabs defaultValue="shifts">
                <TabsList className="mb-4">
                  <TabsTrigger value="shifts">Směny</TabsTrigger>
                  <TabsTrigger value="payouts">Výplaty</TabsTrigger>
                </TabsList>

                <TabsContent value="shifts" className="space-y-3">
                  {completedShifts.length === 0 ? (
                    <p className="text-muted-foreground text-center py-8">Zatím nemáte žádné dokončené směny.</p>
                  ) : (
                    completedShifts.slice(0, 10).map((shift) => (
                      <div key={shift.id} className="flex items-center justify-between p-3 rounded-lg bg-accent/50">
                        <div className="flex items-center gap-3">
                          <div className={`w-2 h-2 rounded-full ${statusColors[shift.status]}`} />
                          <div>
                            <p className="font-medium text-sm">{shift.event?.title}</p>
                            <p className="text-xs text-muted-foreground">
                              {shift.event && format(new Date(shift.event.start_time), 'd. MMM yyyy', { locale: cs })}
                            </p>
                          </div>
                        </div>
                        <div className="text-right">
                          <p className="font-medium text-sm">{shift.hours_worked} h</p>
                          <p className="text-xs text-muted-foreground">
                            {(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč
                          </p>
                        </div>
                      </div>
                    ))
                  )}
                </TabsContent>

                <TabsContent value="payouts" className="space-y-3">
                  {myPayouts.length === 0 ? (
                    <p className="text-muted-foreground text-center py-8">Zatím nemáte žádné výplaty.</p>
                  ) : (
                    myPayouts.map((payout) => (
                      <div key={payout.id} className="flex items-center justify-between p-3 rounded-lg bg-accent/50">
                        <div className="flex items-center gap-3">
                          <Wallet className="h-4 w-4 text-green-600" />
                          <div>
                            <p className="font-medium text-sm">Výplata</p>
                            <p className="text-xs text-muted-foreground">
                              {format(new Date(payout.paid_at), 'd. MMM yyyy', { locale: cs })}
                            </p>
                          </div>
                        </div>
                        <div className="text-right">
                          <p className="font-medium text-sm text-green-600">
                            +{Number(payout.amount).toLocaleString('cs-CZ')} Kč
                          </p>
                          {payout.notes && (
                            <p className="text-xs text-muted-foreground">{payout.notes}</p>
                          )}
                        </div>
                      </div>
                    ))
                  )}
                </TabsContent>
              </Tabs>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
};

export default Profile;
