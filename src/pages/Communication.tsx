import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useChatGroups } from '@/hooks/useChatGroups';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog';
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger } from '@/components/ui/alert-dialog';
import { Skeleton } from '@/components/ui/skeleton';
import { ExternalLink, Plus, Pencil, Trash2, MessageCircle } from 'lucide-react';
import type { Database } from '@/integrations/supabase/types';

type AppRole = Database['public']['Enums']['app_role'];

const ALL_ROLES: { value: AppRole; label: string }[] = [
  { value: 'admin', label: 'Správce' },
  { value: 'trainer', label: 'Trenér' },
  { value: 'part_time_staff', label: 'Brigádník' },
  { value: 'pro_player', label: 'Profi hráč' },
  { value: 'hobby_player', label: 'Hobby hráč' },
];

interface ChatGroupFormData {
  name: string;
  description: string;
  whatsapp_url: string;
  icon: string;
  authorized_roles: AppRole[];
}

const defaultFormData: ChatGroupFormData = {
  name: '',
  description: '',
  whatsapp_url: '',
  icon: '💬',
  authorized_roles: [],
};

const Communication = () => {
  const { isAdmin } = useAuth();
  const { chatGroups, isLoading, createGroup, updateGroup, deleteGroup } = useChatGroups();
  const [isDialogOpen, setIsDialogOpen] = useState(false);
  const [editingGroup, setEditingGroup] = useState<string | null>(null);
  const [formData, setFormData] = useState<ChatGroupFormData>(defaultFormData);

  const handleOpenWhatsApp = (url: string) => {
    window.open(url, '_blank', 'noopener,noreferrer');
  };

  const handleCreateOrUpdate = async () => {
    if (!formData.name || !formData.whatsapp_url || formData.authorized_roles.length === 0) {
      return;
    }

    if (editingGroup) {
      await updateGroup.mutateAsync({
        id: editingGroup,
        ...formData,
      });
    } else {
      await createGroup.mutateAsync(formData);
    }

    setIsDialogOpen(false);
    setEditingGroup(null);
    setFormData(defaultFormData);
  };

  const handleEdit = (group: typeof chatGroups[0]) => {
    setFormData({
      name: group.name,
      description: group.description || '',
      whatsapp_url: group.whatsapp_url,
      icon: group.icon || '💬',
      authorized_roles: group.authorized_roles,
    });
    setEditingGroup(group.id);
    setIsDialogOpen(true);
  };

  const handleDelete = async (id: string) => {
    await deleteGroup.mutateAsync(id);
  };

  const handleRoleToggle = (role: AppRole) => {
    setFormData(prev => ({
      ...prev,
      authorized_roles: prev.authorized_roles.includes(role)
        ? prev.authorized_roles.filter(r => r !== role)
        : [...prev.authorized_roles, role],
    }));
  };

  const handleCloseDialog = () => {
    setIsDialogOpen(false);
    setEditingGroup(null);
    setFormData(defaultFormData);
  };

  if (isLoading) {
    return (
      <div className="space-y-6">
        <div>
          <Skeleton className="h-8 w-48 mb-2" />
          <Skeleton className="h-4 w-72" />
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {[1, 2, 3].map(i => (
            <Skeleton key={i} className="h-40" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Komunikace</h1>
          <p className="text-muted-foreground">
            WhatsApp skupiny pro rychlou komunikaci
          </p>
        </div>
        {isAdmin && (
          <Dialog open={isDialogOpen} onOpenChange={(open) => {
            if (!open) handleCloseDialog();
            else setIsDialogOpen(true);
          }}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4 mr-2" />
                Přidat skupinu
              </Button>
            </DialogTrigger>
            <DialogContent className="sm:max-w-[425px]">
              <DialogHeader>
                <DialogTitle>
                  {editingGroup ? 'Upravit skupinu' : 'Nová skupina'}
                </DialogTitle>
                <DialogDescription>
                  {editingGroup 
                    ? 'Upravte informace o WhatsApp skupině' 
                    : 'Přidejte odkaz na novou WhatsApp skupinu'}
                </DialogDescription>
              </DialogHeader>
              <div className="grid gap-4 py-4">
                <div className="grid gap-2">
                  <Label htmlFor="icon">Ikona (emoji)</Label>
                  <Input
                    id="icon"
                    value={formData.icon}
                    onChange={(e) => setFormData(prev => ({ ...prev, icon: e.target.value }))}
                    placeholder="💬"
                    className="w-20"
                  />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="name">Název skupiny *</Label>
                  <Input
                    id="name"
                    value={formData.name}
                    onChange={(e) => setFormData(prev => ({ ...prev, name: e.target.value }))}
                    placeholder="Např. Brigádníci"
                  />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="description">Popis</Label>
                  <Textarea
                    id="description"
                    value={formData.description}
                    onChange={(e) => setFormData(prev => ({ ...prev, description: e.target.value }))}
                    placeholder="Krátký popis skupiny..."
                    rows={2}
                  />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="whatsapp_url">WhatsApp odkaz *</Label>
                  <Input
                    id="whatsapp_url"
                    value={formData.whatsapp_url}
                    onChange={(e) => setFormData(prev => ({ ...prev, whatsapp_url: e.target.value }))}
                    placeholder="https://chat.whatsapp.com/..."
                  />
                </div>
                <div className="grid gap-2">
                  <Label>Oprávněné role *</Label>
                  <div className="space-y-2">
                    {ALL_ROLES.map(role => (
                      <div key={role.value} className="flex items-center space-x-2">
                        <Checkbox
                          id={role.value}
                          checked={formData.authorized_roles.includes(role.value)}
                          onCheckedChange={() => handleRoleToggle(role.value)}
                        />
                        <Label htmlFor={role.value} className="font-normal cursor-pointer">
                          {role.label}
                        </Label>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
              <DialogFooter>
                <Button variant="outline" onClick={handleCloseDialog}>
                  Zrušit
                </Button>
                <Button 
                  onClick={handleCreateOrUpdate}
                  disabled={!formData.name || !formData.whatsapp_url || formData.authorized_roles.length === 0}
                >
                  {editingGroup ? 'Uložit' : 'Vytvořit'}
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        )}
      </div>

      {/* Groups Grid */}
      {chatGroups.length === 0 ? (
        <Card>
          <CardContent className="flex flex-col items-center justify-center py-12">
            <MessageCircle className="h-12 w-12 text-muted-foreground mb-4" />
            <h3 className="text-lg font-medium mb-1">Žádné skupiny</h3>
            <p className="text-muted-foreground text-center">
              {isAdmin 
                ? 'Zatím nejsou vytvořeny žádné WhatsApp skupiny. Přidejte první skupinu.' 
                : 'Pro vaši roli nejsou dostupné žádné WhatsApp skupiny.'}
            </p>
          </CardContent>
        </Card>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {chatGroups.map(group => (
            <Card key={group.id} className="group relative hover:shadow-md transition-shadow">
              {isAdmin && (
                <div className="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity flex gap-1">
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    onClick={() => handleEdit(group)}
                  >
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <AlertDialog>
                    <AlertDialogTrigger asChild>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-8 w-8 text-destructive hover:text-destructive"
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </AlertDialogTrigger>
                    <AlertDialogContent>
                      <AlertDialogHeader>
                        <AlertDialogTitle>Smazat skupinu?</AlertDialogTitle>
                        <AlertDialogDescription>
                          Opravdu chcete smazat skupinu "{group.name}"? Tuto akci nelze vrátit.
                        </AlertDialogDescription>
                      </AlertDialogHeader>
                      <AlertDialogFooter>
                        <AlertDialogCancel>Zrušit</AlertDialogCancel>
                        <AlertDialogAction
                          onClick={() => handleDelete(group.id)}
                          className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
                        >
                          Smazat
                        </AlertDialogAction>
                      </AlertDialogFooter>
                    </AlertDialogContent>
                  </AlertDialog>
                </div>
              )}
              <CardHeader className="pb-2">
                <div className="flex items-center gap-3">
                  <span className="text-3xl">{group.icon || '💬'}</span>
                  <div>
                    <CardTitle className="text-lg">{group.name}</CardTitle>
                    {group.description && (
                      <CardDescription className="line-clamp-2">
                        {group.description}
                      </CardDescription>
                    )}
                  </div>
                </div>
              </CardHeader>
              <CardContent>
                <Button
                  className="w-full"
                  variant="outline"
                  onClick={() => handleOpenWhatsApp(group.whatsapp_url)}
                >
                  <ExternalLink className="h-4 w-4 mr-2" />
                  Otevřít WhatsApp
                </Button>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
};

export default Communication;
