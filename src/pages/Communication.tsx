/**
 * Communication Page - WhatsApp Groups Management
 * 
 * Security Features:
 * - Schema-based validation for chat group forms
 * - Strict URL validation (WhatsApp links only)
 * - Length limits on all text inputs
 * - XSS prevention via React's built-in escaping
 */

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
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Skeleton } from '@/components/ui/skeleton';
import { ExternalLink, Plus, Pencil, Trash2, icons } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import type { Database } from '@/integrations/supabase/types';
import { 
  chatGroupSchema, 
  safeValidate, 
  VALIDATION_LIMITS,
  sanitizeText 
} from '@/lib/validation';

type AppRole = Database['public']['Enums']['app_role'];

const ALL_ROLES: { value: AppRole; label: string }[] = [
  { value: 'admin', label: 'Správce' },
  { value: 'trainer', label: 'Trenér' },
  { value: 'part_time_staff', label: 'Brigádník' },
  { value: 'pro_player', label: 'Profi hráč' },
  { value: 'hobby_player', label: 'Hobby hráč' },
];

const AVAILABLE_ICONS = [
  { slug: 'message-circle', label: 'Chat' },
  { slug: 'users', label: 'Uživatelé' },
  { slug: 'briefcase', label: 'Práce' },
  { slug: 'target', label: 'Cíl' },
  { slug: 'trophy', label: 'Trofej' },
  { slug: 'megaphone', label: 'Oznámení' },
  { slug: 'heart', label: 'Srdce' },
  { slug: 'star', label: 'Hvězda' },
  { slug: 'zap', label: 'Energie' },
  { slug: 'shield', label: 'Štít' },
  { slug: 'info', label: 'Info' },
  { slug: 'bell', label: 'Zvon' },
  { slug: 'calendar', label: 'Kalendář' },
  { slug: 'settings', label: 'Nastavení' },
];

// Dynamic icon component
const DynamicIcon = ({ name, className }: { name: string; className?: string }) => {
  // Convert kebab-case to PascalCase for lucide icons lookup
  // Sanitize the name to prevent any injection
  const safeName = name.replace(/[^a-z-]/gi, '').slice(0, 50);
  const iconName = safeName
    .split('-')
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join('') as keyof typeof icons;
  
  const IconComponent = icons[iconName] || icons.MessageCircle;
  return <IconComponent className={className} />;
};

interface ChatGroupFormData {
  name: string;
  description: string;
  whatsapp_url: string;
  icon_slug: string;
  authorized_roles: AppRole[];
  isPublic: boolean;
}

const defaultFormData: ChatGroupFormData = {
  name: '',
  description: '',
  whatsapp_url: '',
  icon_slug: 'message-circle',
  authorized_roles: [],
  isPublic: false,
};

const Communication = () => {
  const { isAdmin } = useAuth();
  const { chatGroups, isLoading, createGroup, updateGroup, deleteGroup } = useChatGroups();
  const { toast } = useToast();
  const [isDialogOpen, setIsDialogOpen] = useState(false);
  const [editingGroup, setEditingGroup] = useState<string | null>(null);
  const [formData, setFormData] = useState<ChatGroupFormData>(defaultFormData);
  const [validationError, setValidationError] = useState<string | null>(null);

  const handleOpenWhatsApp = (url: string) => {
    // Validate URL before opening - security check
    if (!url.startsWith('https://chat.whatsapp.com/') && !url.startsWith('https://wa.me/')) {
      toast({
        title: 'Neplatný odkaz',
        description: 'Tento odkaz není platný WhatsApp odkaz.',
        variant: 'destructive',
      });
      return;
    }
    window.open(url, '_blank', 'noopener,noreferrer');
  };

  const handleCreateOrUpdate = async () => {
    // Clear previous validation error
    setValidationError(null);
    
    // If public, authorized_roles should be empty array
    const authorizedRoles = formData.isPublic ? [] : formData.authorized_roles;

    // Validate: either public or has at least one role
    if (!formData.isPublic && authorizedRoles.length === 0) {
      setValidationError('Vyberte alespoň jednu roli nebo označte skupinu jako veřejnou.');
      return;
    }

    // Prepare payload with sanitized data
    const payload = {
      name: sanitizeText(formData.name),
      description: sanitizeText(formData.description),
      whatsapp_url: formData.whatsapp_url.trim(),
      icon_slug: formData.icon_slug,
      authorized_roles: authorizedRoles,
    };

    // Validate with schema
    const validation = safeValidate(chatGroupSchema, payload);
    
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
      // Type assertion - validation passed so data is valid
      const validData = validation.data as {
        name: string;
        description?: string;
        whatsapp_url: string;
        icon_slug?: string;
        authorized_roles: AppRole[];
      };
      
      if (editingGroup) {
        await updateGroup.mutateAsync({
          id: editingGroup,
          ...validData,
        });
      } else {
        await createGroup.mutateAsync(validData);
      }

      setIsDialogOpen(false);
      setEditingGroup(null);
      setFormData(defaultFormData);
      setValidationError(null);
    } catch {
      // Error is handled by the hook
    }
  };

  const handleEdit = (group: typeof chatGroups[0]) => {
    const isPublic = group.authorized_roles.length === 0;
    setFormData({
      name: group.name,
      description: group.description || '',
      whatsapp_url: group.whatsapp_url,
      icon_slug: group.icon_slug || 'message-circle',
      authorized_roles: group.authorized_roles,
      isPublic,
    });
    setEditingGroup(group.id);
    setValidationError(null);
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
    setValidationError(null);
  };

  const handlePublicToggle = (checked: boolean) => {
    setFormData(prev => ({
      ...prev,
      isPublic: checked,
      // Clear roles when making public
      authorized_roles: checked ? [] : prev.authorized_roles,
    }));
    setValidationError(null);
  };

  const handleCloseDialog = () => {
    setIsDialogOpen(false);
    setEditingGroup(null);
    setFormData(defaultFormData);
    setValidationError(null);
  };

  const isFormValid = formData.name.trim() && formData.whatsapp_url.trim() && (formData.isPublic || formData.authorized_roles.length > 0);

  if (isLoading) {
    return (
      <div className="p-4 md:p-6 space-y-6">
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
    <div className="p-4 md:p-6 space-y-4 md:space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl md:text-3xl font-bold tracking-tight">Komunikace</h1>
          <p className="text-muted-foreground text-sm md:text-base">
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
            <DialogContent className="sm:max-w-[425px] max-h-[90vh] overflow-y-auto">
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
              
              {validationError && (
                <div className="p-3 text-sm text-destructive bg-destructive/10 rounded-md">
                  {validationError}
                </div>
              )}
              
              <div className="grid gap-4 py-4">
                <div className="grid gap-2">
                  <Label>Ikona skupiny</Label>
                  <Select 
                    value={formData.icon_slug} 
                    onValueChange={(value) => setFormData(prev => ({ ...prev, icon_slug: value }))}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Vyberte ikonu">
                        <div className="flex items-center gap-2">
                          <DynamicIcon name={formData.icon_slug} className="h-4 w-4" />
                          <span>{AVAILABLE_ICONS.find(i => i.slug === formData.icon_slug)?.label || 'Chat'}</span>
                        </div>
                      </SelectValue>
                    </SelectTrigger>
                    <SelectContent>
                      {AVAILABLE_ICONS.map(icon => (
                        <SelectItem key={icon.slug} value={icon.slug}>
                          <div className="flex items-center gap-2">
                            <DynamicIcon name={icon.slug} className="h-4 w-4" />
                            <span>{icon.label}</span>
                          </div>
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="name">Název skupiny *</Label>
                  <Input
                    id="name"
                    value={formData.name}
                    onChange={(e) => {
                      setFormData(prev => ({ ...prev, name: e.target.value }));
                      setValidationError(null);
                    }}
                    placeholder="Např. Brigádníci"
                    maxLength={VALIDATION_LIMITS.TITLE_MAX}
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
                    maxLength={VALIDATION_LIMITS.DESCRIPTION_MAX}
                  />
                </div>
                <div className="grid gap-2">
                  <Label htmlFor="whatsapp_url">WhatsApp odkaz *</Label>
                  <Input
                    id="whatsapp_url"
                    value={formData.whatsapp_url}
                    onChange={(e) => {
                      setFormData(prev => ({ ...prev, whatsapp_url: e.target.value }));
                      setValidationError(null);
                    }}
                    placeholder="https://chat.whatsapp.com/..."
                    maxLength={VALIDATION_LIMITS.URL_MAX}
                  />
                  <p className="text-xs text-muted-foreground">
                    Musí být ve formátu https://chat.whatsapp.com/... nebo https://wa.me/...
                  </p>
                </div>
                <div className="grid gap-2">
                  <Label>Přístup ke skupině *</Label>
                  <div className="space-y-3">
                    <div className="flex items-center space-x-2 p-3 border rounded-lg bg-muted/50">
                      <Checkbox
                        id="public"
                        checked={formData.isPublic}
                        onCheckedChange={handlePublicToggle}
                      />
                      <Label htmlFor="public" className="font-normal cursor-pointer flex-1">
                        <span className="font-medium">Veřejná skupina</span>
                        <p className="text-xs text-muted-foreground">
                          Viditelná pro všechny přihlášené uživatele
                        </p>
                      </Label>
                    </div>
                    
                    {!formData.isPublic && (
                      <div className="space-y-2 pl-1">
                        <span className="text-sm text-muted-foreground">Nebo vyberte oprávněné role:</span>
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
                    )}
                  </div>
                </div>
              </div>
              <DialogFooter>
                <Button variant="outline" onClick={handleCloseDialog}>
                  Zrušit
                </Button>
                <Button 
                  onClick={handleCreateOrUpdate}
                  disabled={!isFormValid}
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
            <div className="p-3 rounded-full bg-muted mb-4">
              <DynamicIcon name="message-circle" className="h-8 w-8 text-muted-foreground" />
            </div>
            <h3 className="text-lg font-medium mb-1">Žádné skupiny</h3>
            <p className="text-muted-foreground text-center">
              {isAdmin 
                ? 'Zatím nejsou vytvořeny žádné WhatsApp skupiny. Přidejte první skupinu.' 
                : 'Pro vaši roli nejsou dostupné žádné WhatsApp skupiny.'}
            </p>
          </CardContent>
        </Card>
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 md:gap-4">
          {chatGroups.map(group => (
            <Card key={group.id} className="group relative hover:shadow-md transition-shadow">
              {isAdmin && (
                <div className="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity flex gap-1 z-10">
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8 bg-background/80 backdrop-blur-sm"
                    onClick={() => handleEdit(group)}
                  >
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <AlertDialog>
                    <AlertDialogTrigger asChild>
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-8 w-8 text-destructive hover:text-destructive bg-background/80 backdrop-blur-sm"
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
                  <div className="p-2.5 rounded-lg bg-primary/10 shrink-0">
                    <DynamicIcon 
                      name={group.icon_slug || 'message-circle'} 
                      className="h-6 w-6 text-primary" 
                    />
                  </div>
                  <div className="min-w-0">
                    <CardTitle className="text-lg truncate">{group.name}</CardTitle>
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
                  Otevřít chat
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
