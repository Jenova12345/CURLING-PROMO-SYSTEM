import { useState, useRef } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useProfile } from '@/hooks/useProfile';
import { useShifts } from '@/hooks/useShifts';
import { usePayouts } from '@/hooks/usePayouts';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { User, Phone, Camera, Clock, TrendingUp, Wallet, CheckCircle, History } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';

const Profile = () => {
  const { profile, role } = useAuth();
  const { updateProfile, uploadAvatar, isUpdating } = useProfile();
  const { myShifts, totalHoursWorked, totalEarnings, unpaidEarnings } = useShifts();
  const { myPayouts } = usePayouts();
  const { toast } = useToast();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [fullName, setFullName] = useState(profile?.full_name || '');
  const [phone, setPhone] = useState(profile?.phone || '');
  const [isUploading, setIsUploading] = useState(false);

  const roleLabels: Record<string, string> = {
    admin: 'Správce',
    trainer: 'Trenér',
    part_time_staff: 'Brigádník',
    pro_player: 'Profi hráč',
    hobby_player: 'Hobby hráč',
  };

  const handleSaveProfile = async () => {
    try {
      await updateProfile({ fullName, phone });
      toast({
        title: 'Profil uložen',
        description: 'Vaše údaje byly aktualizovány.',
      });
    } catch (error) {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se uložit profil.',
        variant: 'destructive',
      });
    }
  };

  const handleAvatarClick = () => {
    fileInputRef.current?.click();
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    if (!file.type.startsWith('image/')) {
      toast({
        title: 'Chyba',
        description: 'Vyberte prosím obrázek.',
        variant: 'destructive',
      });
      return;
    }

    if (file.size > 5 * 1024 * 1024) {
      toast({
        title: 'Chyba',
        description: 'Obrázek je příliš velký. Maximum je 5 MB.',
        variant: 'destructive',
      });
      return;
    }

    setIsUploading(true);
    try {
      const avatarUrl = await uploadAvatar(file);
      await updateProfile({ avatarUrl });
      toast({
        title: 'Avatar nahrán',
        description: 'Vaše profilová fotka byla aktualizována.',
      });
    } catch (error) {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se nahrát obrázek.',
        variant: 'destructive',
      });
    } finally {
      setIsUploading(false);
    }
  };

  const completedShifts = myShifts.filter(s => s.status === 'completed');
  const paidEarnings = myPayouts.reduce((sum, p) => sum + Number(p.amount), 0);

  const statusColors: Record<string, string> = {
    open: 'bg-green-500',
    pending: 'bg-yellow-500',
    claimed: 'bg-blue-500',
    completed: 'bg-gray-500',
  };

  const statusLabels: Record<string, string> = {
    open: 'Volná',
    pending: 'Čeká na schválení',
    claimed: 'Schválená',
    completed: 'Dokončená',
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
            {/* Avatar */}
            <div className="flex flex-col items-center">
              <div className="relative">
                <Avatar className="h-24 w-24 cursor-pointer" onClick={handleAvatarClick}>
                  <AvatarImage src={profile?.avatar_url || undefined} />
                  <AvatarFallback className="text-2xl bg-primary text-primary-foreground">
                    {profile?.full_name?.charAt(0)?.toUpperCase() || 'U'}
                  </AvatarFallback>
                </Avatar>
                <button
                  onClick={handleAvatarClick}
                  disabled={isUploading}
                  className="absolute bottom-0 right-0 p-1.5 rounded-full bg-primary text-primary-foreground hover:bg-primary/90 transition-colors"
                >
                  <Camera className="h-4 w-4" />
                </button>
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={handleFileChange}
                />
              </div>
              {isUploading && (
                <p className="text-sm text-muted-foreground mt-2">Nahrávání...</p>
              )}
              <Badge className="mt-3" variant="secondary">
                {role ? roleLabels[role] : 'Člen'}
              </Badge>
            </div>

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
                  onChange={(e) => setFullName(e.target.value)}
                  placeholder="Jan Novák"
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
                  onChange={(e) => setPhone(e.target.value)}
                  placeholder="+420 123 456 789"
                />
              </div>

              <Button 
                onClick={handleSaveProfile} 
                disabled={isUpdating}
                className="w-full"
              >
                {isUpdating ? 'Ukládání...' : 'Uložit změny'}
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* Stats & History */}
        <div className="md:col-span-2 space-y-6">
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
