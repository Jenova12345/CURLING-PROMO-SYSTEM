import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { useToast } from '@/hooks/use-toast';
import { Users, Search, Edit, User } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { Database } from '@/integrations/supabase/types';
import { roleUpdateSchema, safeValidate } from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';

type AppRole = Database['public']['Enums']['app_role'];

const Members = () => {
  const { isAdmin } = useAuth();
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const { isLimited, retryAfter, checkLimit } = useRateLimit('updateRole');
  
  const [searchQuery, setSearchQuery] = useState('');
  const [roleFilter, setRoleFilter] = useState<string>('all');
  const [editDialogOpen, setEditDialogOpen] = useState(false);
  const [selectedMember, setSelectedMember] = useState<{
    user_id: string;
    full_name: string | null;
    role: AppRole;
  } | null>(null);
  const [newRole, setNewRole] = useState<AppRole>('hobby_player');

  const { data: members = [], isLoading } = useQuery({
    queryKey: ['members'],
    queryFn: async () => {
      const { data: profiles, error: profilesError } = await supabase
        .from('profiles')
        .select('*')
        .order('created_at', { ascending: false });

      if (profilesError) throw profilesError;

      const { data: roles, error: rolesError } = await supabase
        .from('user_roles')
        .select('*');

      if (rolesError) throw rolesError;

      return profiles.map(profile => ({
        ...profile,
        role: roles.find(r => r.user_id === profile.user_id)?.role || 'hobby_player',
      }));
    },
    enabled: isAdmin,
  });

  const updateRole = useMutation({
    mutationFn: async ({ userId, role }: { userId: string; role: AppRole }) => {
      // First delete existing role
      await supabase
        .from('user_roles')
        .delete()
        .eq('user_id', userId);

      // Then insert new role
      const { error } = await supabase
        .from('user_roles')
        .insert({ user_id: userId, role });

      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['members'] });
      toast({
        title: 'Role aktualizována',
        description: 'Uživatelská role byla úspěšně změněna.',
      });
      setEditDialogOpen(false);
    },
    onError: () => {
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se změnit roli.',
        variant: 'destructive',
      });
    },
  });

  const roleLabels: Record<AppRole, string> = {
    admin: 'Správce',
    trainer: 'Trenér',
    part_time_staff: 'Brigádník',
    pro_player: 'Profi hráč',
    hobby_player: 'Hobby hráč',
  };

  const roleColors: Record<AppRole, string> = {
    admin: 'bg-red-500',
    trainer: 'bg-purple-500',
    part_time_staff: 'bg-blue-500',
    pro_player: 'bg-green-500',
    hobby_player: 'bg-gray-500',
  };

  const filteredMembers = members.filter(member => {
    const matchesSearch = member.full_name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
                         member.phone?.includes(searchQuery);
    const matchesRole = roleFilter === 'all' || member.role === roleFilter;
    return matchesSearch && matchesRole;
  });

  const openEditDialog = (member: typeof members[0]) => {
    setSelectedMember({
      user_id: member.user_id,
      full_name: member.full_name,
      role: member.role as AppRole,
    });
    setNewRole(member.role as AppRole);
    setEditDialogOpen(true);
  };

  const handleUpdateRole = () => {
    if (!selectedMember) return;
    
    // Rate limiting check
    if (!checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    // Validate input
    const validation = safeValidate(roleUpdateSchema, {
      userId: selectedMember.user_id,
      role: newRole,
    });

    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }

    updateRole.mutate({ userId: validation.data.userId, role: validation.data.role });
  };

  if (!isAdmin) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-muted-foreground">Nemáte oprávnění k zobrazení této stránky.</p>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
      </div>
    );
  }

  return (
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl md:text-3xl font-bold">Správa členů</h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          Přehled všech registrovaných uživatelů
        </p>
      </div>

      {/* Stats */}
      <div className="grid gap-2 grid-cols-3 md:grid-cols-5">
        {(Object.keys(roleLabels) as AppRole[]).map((role) => (
          <Card key={role}>
            <CardContent className="flex items-center gap-2 p-3">
              <div className={`w-2.5 h-2.5 rounded-full ${roleColors[role]}`} />
              <div>
                <p className="text-lg md:text-2xl font-bold">
                  {members.filter(m => m.role === role).length}
                </p>
                <p className="text-[10px] md:text-xs text-muted-foreground">{roleLabels[role]}</p>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      {/* Filters */}
      <div className="flex flex-col sm:flex-row gap-3">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Hledat..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="pl-10"
          />
        </div>
        <Select value={roleFilter} onValueChange={setRoleFilter}>
          <SelectTrigger className="w-full sm:w-40">
            <SelectValue placeholder="Role" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Všechny role</SelectItem>
            {(Object.keys(roleLabels) as AppRole[]).map((role) => (
              <SelectItem key={role} value={role}>
                {roleLabels[role]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {/* Members List */}
      <Card>
        <CardHeader>
          <CardTitle>Seznam členů ({filteredMembers.length})</CardTitle>
          <CardDescription>Všichni registrovaní uživatelé v systému</CardDescription>
        </CardHeader>
        <CardContent>
          {filteredMembers.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-12">
              <Users className="h-12 w-12 text-muted-foreground mb-4" />
              <p className="text-muted-foreground">Žádní členové nenalezeni</p>
            </div>
          ) : (
            <div className="space-y-4">
              {filteredMembers.map((member) => (
                <div
                  key={member.id}
                  className="flex flex-col sm:flex-row sm:items-center sm:justify-between p-4 rounded-lg bg-accent/50 gap-3"
                >
                  <div className="flex items-center gap-3">
                    <div className="flex h-10 w-10 sm:h-12 sm:w-12 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground">
                      <User className="h-5 w-5 sm:h-6 sm:w-6" />
                    </div>
                    <div className="min-w-0">
                      <p className="font-medium truncate">{member.full_name || 'Bez jména'}</p>
                      <p className="text-sm text-muted-foreground truncate">
                        {member.phone || 'Bez telefonu'}
                      </p>
                      <p className="text-xs text-muted-foreground">
                        {format(new Date(member.created_at), 'd. M. yyyy', { locale: cs })}
                      </p>
                    </div>
                  </div>
                  
                  <div className="flex items-center justify-between sm:justify-end gap-2 sm:gap-3">
                    <Badge className={`${roleColors[member.role as AppRole]} text-white text-xs`}>
                      {roleLabels[member.role as AppRole]}
                    </Badge>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => openEditDialog(member)}
                      className="shrink-0"
                    >
                      <Edit className="h-4 w-4 sm:mr-1" />
                      <span className="hidden sm:inline">Upravit roli</span>
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Edit Role Dialog */}
      <Dialog open={editDialogOpen} onOpenChange={setEditDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Změnit roli uživatele</DialogTitle>
            <DialogDescription>
              Měníte roli pro: {selectedMember?.full_name || 'Uživatel'}
            </DialogDescription>
          </DialogHeader>
          
          <div className="space-y-4">
            <Select value={newRole} onValueChange={(v) => setNewRole(v as AppRole)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {(Object.keys(roleLabels) as AppRole[]).map((role) => (
                  <SelectItem key={role} value={role}>
                    {roleLabels[role]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setEditDialogOpen(false)}>
              Zrušit
            </Button>
            <Button 
              onClick={handleUpdateRole}
              disabled={updateRole.isPending}
            >
              {updateRole.isPending ? 'Ukládání...' : 'Uložit změny'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Members;
