import { useState, useEffect } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Checkbox } from '@/components/ui/checkbox';
import { useToast } from '@/hooks/use-toast';
import { Users, Search, Edit, User, Loader2 } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';

interface MemberWithRoles {
  id: string;
  user_id: string;
  full_name: string | null;
  phone: string | null;
  bank_account: string | null;
  created_at: string;
  updated_at: string;
  roles: string[];
}

const Members = () => {
  const { isAdmin } = useAuth();
  const { toast } = useToast();
  const queryClient = useQueryClient();
  
  const [searchQuery, setSearchQuery] = useState('');
  const [roleFilter, setRoleFilter] = useState<string>('all');
  const [editDialogOpen, setEditDialogOpen] = useState(false);
  const [selectedMember, setSelectedMember] = useState<MemberWithRoles | null>(null);
  const [selectedRoles, setSelectedRoles] = useState<string[]>([]);
  const [isUpdatingRoles, setIsUpdatingRoles] = useState(false);

  const roleLabels: Record<string, string> = {
    admin: 'Správce',
    trainer: 'Trenér',
    part_time_staff: 'Brigádník',
    instructor: 'Instruktor',
    bar_staff: 'Obsluha baru',
    manager: 'Provozní hospoda',
    pro_player: 'Profi hráč',
    hobby_player: 'Hobby hráč',
  };

  const roleColors: Record<string, string> = {
    admin: 'bg-red-500',
    trainer: 'bg-purple-500',
    part_time_staff: 'bg-blue-500',
    instructor: 'bg-teal-500',
    bar_staff: 'bg-amber-500',
    manager: 'bg-indigo-500',
    pro_player: 'bg-green-500',
    hobby_player: 'bg-gray-500',
  };

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

      // Map profiles to include ALL roles as array
      return profiles.map(profile => ({
        ...profile,
        roles: roles
          .filter(r => r.user_id === profile.user_id)
          .map(r => r.role),
      })) as MemberWithRoles[];
    },
    enabled: isAdmin,
  });

  // Sync selectedRoles when selectedMember changes
  useEffect(() => {
    if (selectedMember) {
      setSelectedRoles(selectedMember.roles);
    }
  }, [selectedMember]);

  const handleToggleRole = async (role: string, checked: boolean) => {
    if (!selectedMember) return;
    
    setIsUpdatingRoles(true);
    
    try {
      if (checked) {
        // INSERT new role - cast to handle new roles not yet in Supabase types
        const { error } = await supabase.from('user_roles').insert({ 
          user_id: selectedMember.user_id, 
          role: role as 'admin' | 'trainer' | 'part_time_staff' | 'pro_player' | 'hobby_player'
        });
        
        if (error) throw error;
        
        setSelectedRoles(prev => [...prev, role]);
        toast({
          title: 'Role přidána',
          description: `Role "${roleLabels[role]}" byla přidána.`,
        });
      } else {
        // Prevent removing last role
        if (selectedRoles.length <= 1) {
          toast({ 
            title: 'Nelze odebrat', 
            description: 'Uživatel musí mít alespoň jednu roli.',
            variant: 'destructive',
          });
          return;
        }
        
        // DELETE role - cast to handle new roles not yet in Supabase types
        const { error } = await supabase
          .from('user_roles')
          .delete()
          .eq('user_id', selectedMember.user_id)
          .eq('role', role as 'admin' | 'trainer' | 'part_time_staff' | 'pro_player' | 'hobby_player');
        
        if (error) throw error;
        
        setSelectedRoles(prev => prev.filter(r => r !== role));
        toast({
          title: 'Role odebrána',
          description: `Role "${roleLabels[role]}" byla odebrána.`,
        });
      }
      
      queryClient.invalidateQueries({ queryKey: ['members'] });
    } catch (error) {
      console.error('Error updating role:', error);
      toast({
        title: 'Chyba',
        description: 'Nepodařilo se změnit roli.',
        variant: 'destructive',
      });
    } finally {
      setIsUpdatingRoles(false);
    }
  };

  const openEditDialog = (member: MemberWithRoles) => {
    setSelectedMember(member);
    setSelectedRoles(member.roles);
    setEditDialogOpen(true);
  };

  const filteredMembers = members.filter(member => {
    const matchesSearch = member.full_name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
                         member.phone?.includes(searchQuery);
    const matchesRole = roleFilter === 'all' || member.roles.includes(roleFilter);
    return matchesSearch && matchesRole;
  });

  // Count members per role (including multi-role users in multiple counts)
  const getRoleCount = (role: string) => {
    return members.filter(m => m.roles.includes(role)).length;
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
      <div className="grid gap-2 grid-cols-4 md:grid-cols-8">
        {Object.keys(roleLabels).map((role) => (
          <Card key={role}>
            <CardContent className="flex items-center gap-2 p-3">
              <div className={`w-2.5 h-2.5 rounded-full ${roleColors[role]}`} />
              <div>
                <p className="text-lg md:text-2xl font-bold">
                  {getRoleCount(role)}
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
            {Object.keys(roleLabels).map((role) => (
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
                    <div className="flex flex-wrap gap-1">
                      {member.roles.map((role) => (
                        <Badge 
                          key={role} 
                          className={`${roleColors[role] || 'bg-gray-500'} text-white text-xs`}
                        >
                          {roleLabels[role] || role}
                        </Badge>
                      ))}
                    </div>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => openEditDialog(member)}
                      className="shrink-0"
                    >
                      <Edit className="h-4 w-4 sm:mr-1" />
                      <span className="hidden sm:inline">Upravit role</span>
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Edit Role Dialog - Multi-checkbox */}
      <Dialog open={editDialogOpen} onOpenChange={setEditDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Upravit role uživatele</DialogTitle>
            <DialogDescription>
              Spravujete role pro: {selectedMember?.full_name || 'Uživatel'}
            </DialogDescription>
          </DialogHeader>
          
          <div className="space-y-4 py-4">
            <p className="text-sm text-muted-foreground">
              Vyberte jednu nebo více rolí:
            </p>
            {Object.entries(roleLabels).map(([role, label]) => {
              const isChecked = selectedRoles.includes(role);
              const isLastRole = selectedRoles.length <= 1 && isChecked;
              
              return (
                <div key={role} className="flex items-center space-x-3">
                  <Checkbox 
                    id={`role-${role}`}
                    checked={isChecked}
                    onCheckedChange={(checked) => handleToggleRole(role, !!checked)}
                    disabled={isUpdatingRoles || isLastRole}
                  />
                  <label 
                    htmlFor={`role-${role}`} 
                    className="flex items-center gap-2 cursor-pointer text-sm"
                  >
                    <div className={`w-3 h-3 rounded-full ${roleColors[role]}`} />
                    {label}
                    {isLastRole && (
                      <span className="text-xs text-muted-foreground">(poslední role)</span>
                    )}
                  </label>
                  {isUpdatingRoles && (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  )}
                </div>
              );
            })}
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setEditDialogOpen(false)}>
              Zavřít
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Members;
