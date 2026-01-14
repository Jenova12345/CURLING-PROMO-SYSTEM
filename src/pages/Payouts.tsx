import { useState } from 'react';
import { useAuth } from '@/contexts/AuthContext';
import { useShifts } from '@/hooks/useShifts';
import { usePayouts } from '@/hooks/usePayouts';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';
import { Clock, CheckCircle, TrendingUp, Wallet, DollarSign, History, Users, BarChart3, Download, Landmark, Copy, AlertCircle } from 'lucide-react';
import { format } from 'date-fns';
import { cs } from 'date-fns/locale';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, PieChart, Pie, Cell } from 'recharts';
import { payoutSchema, safeValidate, sanitizeText } from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';
import { Navigate } from 'react-router-dom';

const Payouts = () => {
  const { isAdmin, loading: isAuthLoading } = useAuth();
  const { 
    shifts,
    staffUnpaidAmounts,
    adminStats,
  } = useShifts();
  const { payouts, createPayout, isCreatingPayout } = usePayouts();
  const { toast } = useToast();

  const payoutRateLimit = useRateLimit('createPayout');

  // Payout dialog
  const [payoutDialogOpen, setPayoutDialogOpen] = useState(false);
  const [selectedStaff, setSelectedStaff] = useState<{ staffId: string; staffName: string; amount: number; bankAccount: string | null } | null>(null);
  const [payoutNotes, setPayoutNotes] = useState('');

  // Staff payout history dialog
  const [staffHistoryDialogOpen, setStaffHistoryDialogOpen] = useState(false);
  const [selectedStaffHistory, setSelectedStaffHistory] = useState<{ staffId: string; staffName: string } | null>(null);

  const [activeTab, setActiveTab] = useState('unpaid');

  // Redirect non-admins
  if (!isAuthLoading && !isAdmin) {
    return <Navigate to="/" replace />;
  }

  const openPayoutDialog = (staff: { staffId: string; staffName: string; amount: number; bankAccount: string | null }) => {
    setSelectedStaff(staff);
    setPayoutNotes('');
    setPayoutDialogOpen(true);
  };

  const handlePayout = async () => {
    if (!selectedStaff) return;

    if (!payoutRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho požadavků',
        description: `Zkuste to znovu za ${payoutRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }

    const validation = safeValidate(payoutSchema, {
      userId: selectedStaff.staffId,
      amount: selectedStaff.amount,
      notes: sanitizeText(payoutNotes) || undefined,
    });

    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }

    try {
      await createPayout({
        userId: validation.data.userId,
        amount: validation.data.amount,
        notes: validation.data.notes,
      });
      toast({
        title: 'Výplata provedena!',
        description: `${selectedStaff.staffName} obdržel ${selectedStaff.amount.toLocaleString('cs-CZ')} Kč.`,
      });
      setPayoutDialogOpen(false);
      setSelectedStaff(null);
      setPayoutNotes('');
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Nepodařilo se provést výplatu.';
      toast({
        title: 'Chyba',
        description: message,
        variant: 'destructive',
      });
    }
  };

  const openStaffHistoryDialog = (staffId: string, staffName: string) => {
    setSelectedStaffHistory({ staffId, staffName });
    setStaffHistoryDialogOpen(true);
  };

  const getStaffPayouts = (staffId: string) => {
    return payouts.filter(p => p.user_id === staffId);
  };

  const getStaffCompletedShifts = (staffId: string) => {
    return shifts.filter(s => s.claimed_by === staffId && s.status === 'completed');
  };

  if (isAuthLoading) {
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
        <h1 className="text-2xl md:text-3xl font-bold">Výplaty</h1>
        <p className="text-muted-foreground mt-1 text-sm md:text-base">
          Správa výplat a statistiky brigádníků
        </p>
      </div>

      {/* Tabs */}
      <Tabs value={activeTab} onValueChange={setActiveTab} className="w-full">
        {/* Mobile: Select dropdown for tabs */}
        <div className="sm:hidden mb-4">
          <Select value={activeTab} onValueChange={setActiveTab}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder="Vyberte sekci" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="unpaid">K vyplacení {staffUnpaidAmounts.length > 0 && `(${staffUnpaidAmounts.length})`}</SelectItem>
              <SelectItem value="stats">Statistiky</SelectItem>
              <SelectItem value="history">Historie výplat</SelectItem>
            </SelectContent>
          </Select>
        </div>

        {/* Desktop: Horizontal tabs */}
        <TabsList className="hidden sm:flex w-auto">
          <TabsTrigger value="unpaid" className="text-sm relative">
            K vyplacení
            {staffUnpaidAmounts.length > 0 && (
              <span className="ml-1 inline-flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-green-500 rounded-full">
                {staffUnpaidAmounts.length}
              </span>
            )}
          </TabsTrigger>
          <TabsTrigger value="stats" className="text-sm">Statistiky</TabsTrigger>
          <TabsTrigger value="history" className="text-sm">Historie výplat</TabsTrigger>
        </TabsList>

        {/* K vyplacení */}
        <TabsContent value="unpaid" className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <DollarSign className="h-5 w-5 text-green-500" />
                K vyplacení
              </CardTitle>
              <CardDescription>Brigádníci s nevyplacenými směnami</CardDescription>
            </CardHeader>
            <CardContent>
              {staffUnpaidAmounts.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-8">
                  <Wallet className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Všichni brigádníci jsou vyplaceni.</p>
                </div>
              ) : (
                <div className="space-y-3">
                  {staffUnpaidAmounts.map((staff) => (
                    <div key={staff.staffId} className="flex flex-col sm:flex-row sm:items-center justify-between p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900 gap-4">
                      <div>
                        <p className="font-medium">{staff.staffName}</p>
                        <p className="text-sm text-muted-foreground">
                          {staff.shiftCount} dokončených směn
                        </p>
                        <p className="text-lg font-bold text-green-600 mt-1">
                          {staff.amount.toLocaleString('cs-CZ')} Kč
                        </p>
                      </div>
                      <Button 
                        onClick={() => openPayoutDialog(staff)}
                        className="bg-green-600 hover:bg-green-700"
                      >
                        <Wallet className="h-4 w-4 mr-1" />
                        Vyplatit
                      </Button>
                    </div>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* Statistiky */}
        <TabsContent value="stats" className="space-y-6">
          {/* Overview Cards */}
          <div className="grid gap-4 grid-cols-2 lg:grid-cols-4">
            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Celkem vyplaceno</CardTitle>
                <DollarSign className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold text-green-600">
                  {payouts.reduce((sum, p) => sum + Number(p.amount), 0).toLocaleString('cs-CZ')} Kč
                </div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Celkem odpracováno</CardTitle>
                <Clock className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{adminStats.totalHoursAllStaff} h</div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">K vyplacení</CardTitle>
                <Wallet className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold text-orange-600">
                  {adminStats.unpaidTotal.toLocaleString('cs-CZ')} Kč
                </div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
                <CardTitle className="text-sm font-medium">Aktivní brigádníci</CardTitle>
                <Users className="h-4 w-4 text-muted-foreground" />
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-bold">{adminStats.activeStaffCount}</div>
                <p className="text-xs text-muted-foreground">{adminStats.completedShiftsCount} směn celkem</p>
              </CardContent>
            </Card>
          </div>

          {/* Charts */}
          <div className="grid gap-6 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <BarChart3 className="h-5 w-5" />
                  Odpracované hodiny
                </CardTitle>
                <CardDescription>Rozložení hodin mezi brigádníky</CardDescription>
              </CardHeader>
              <CardContent>
                {adminStats.staffStats.length === 0 ? (
                  <p className="text-muted-foreground text-center py-8">Zatím nejsou žádná data.</p>
                ) : (
                  <ResponsiveContainer width="100%" height={250}>
                    <BarChart data={adminStats.staffStats}>
                      <CartesianGrid strokeDasharray="3 3" />
                      <XAxis dataKey="staffName" tick={{ fontSize: 12 }} />
                      <YAxis tick={{ fontSize: 12 }} />
                      <Tooltip 
                        formatter={(value: number) => [`${value} h`, 'Hodiny']}
                        labelFormatter={(label) => label}
                      />
                      <Bar dataKey="hoursWorked" fill="hsl(var(--primary))" radius={[4, 4, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <TrendingUp className="h-5 w-5" />
                  Výdělky brigádníků
                </CardTitle>
                <CardDescription>Rozdělení celkových výdělků</CardDescription>
              </CardHeader>
              <CardContent>
                {adminStats.staffStats.length === 0 ? (
                  <p className="text-muted-foreground text-center py-8">Zatím nejsou žádná data.</p>
                ) : (
                  <ResponsiveContainer width="100%" height={250}>
                    <PieChart>
                      <Pie
                        data={adminStats.staffStats}
                        dataKey="totalEarnings"
                        nameKey="staffName"
                        cx="50%"
                        cy="50%"
                        outerRadius={80}
                        label={({ staffName, percent }) => `${staffName}: ${(percent * 100).toFixed(0)}%`}
                      >
                        {adminStats.staffStats.map((_, index) => (
                          <Cell 
                            key={`cell-${index}`} 
                            fill={[
                              'hsl(var(--primary))',
                              'hsl(var(--secondary))',
                              '#22c55e',
                              '#f59e0b',
                              '#ef4444',
                              '#8b5cf6',
                            ][index % 6]} 
                          />
                        ))}
                      </Pie>
                      <Tooltip formatter={(value: number) => `${value.toLocaleString('cs-CZ')} Kč`} />
                    </PieChart>
                  </ResponsiveContainer>
                )}
              </CardContent>
            </Card>
          </div>

          {/* Staff Table */}
          <Card>
            <CardHeader className="flex flex-row items-center justify-between">
              <div>
                <CardTitle>Přehled brigádníků</CardTitle>
                <CardDescription>Detailní statistiky pro každého brigádníka</CardDescription>
              </div>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  const csv = [
                    ['Brigádník', 'Směn', 'Hodin', 'Celkem Kč', 'Vyplaceno Kč', 'K výplatě Kč'],
                    ...adminStats.staffStats.map(s => [
                      s.staffName,
                      s.shiftsCount,
                      s.hoursWorked,
                      s.totalEarnings,
                      s.paidAmount,
                      s.unpaidAmount,
                    ])
                  ].map(row => row.join(',')).join('\n');
                  
                  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
                  const link = document.createElement('a');
                  link.href = URL.createObjectURL(blob);
                  link.download = `brigádníci-statistiky-${format(new Date(), 'yyyy-MM-dd')}.csv`;
                  link.click();
                }}
              >
                <Download className="h-4 w-4 mr-1" />
                Export CSV
              </Button>
            </CardHeader>
            <CardContent>
              {adminStats.staffStats.length === 0 ? (
                <p className="text-muted-foreground text-center py-8">Zatím nejsou žádní brigádníci s dokončenými směnami.</p>
              ) : (
                <div className="overflow-x-auto">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Brigádník</TableHead>
                        <TableHead className="text-right">Směn</TableHead>
                        <TableHead className="text-right">Hodin</TableHead>
                        <TableHead className="text-right">Celkem</TableHead>
                        <TableHead className="text-right">Vyplaceno</TableHead>
                        <TableHead className="text-right">K výplatě</TableHead>
                        <TableHead className="text-right">Akce</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {adminStats.staffStats.map((staff) => (
                        <TableRow 
                          key={staff.staffId}
                          className="cursor-pointer hover:bg-accent/70"
                          onClick={() => openStaffHistoryDialog(staff.staffId, staff.staffName)}
                        >
                          <TableCell className="font-medium">{staff.staffName}</TableCell>
                          <TableCell className="text-right">{staff.shiftsCount}</TableCell>
                          <TableCell className="text-right">{staff.hoursWorked} h</TableCell>
                          <TableCell className="text-right">{staff.totalEarnings.toLocaleString('cs-CZ')} Kč</TableCell>
                          <TableCell className="text-right text-green-600">{staff.paidAmount.toLocaleString('cs-CZ')} Kč</TableCell>
                          <TableCell className="text-right">
                            {staff.unpaidAmount > 0 ? (
                              <span className="text-orange-600 font-medium">{staff.unpaidAmount.toLocaleString('cs-CZ')} Kč</span>
                            ) : (
                              <span className="text-muted-foreground">0 Kč</span>
                            )}
                          </TableCell>
                          <TableCell className="text-right">
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={(e) => {
                                e.stopPropagation();
                                openStaffHistoryDialog(staff.staffId, staff.staffName);
                              }}
                            >
                              <History className="h-4 w-4" />
                            </Button>
                          </TableCell>
                        </TableRow>
                      ))}
                      <TableRow className="font-bold bg-accent/50">
                        <TableCell>Celkem</TableCell>
                        <TableCell className="text-right">{adminStats.completedShiftsCount}</TableCell>
                        <TableCell className="text-right">{adminStats.totalHoursAllStaff} h</TableCell>
                        <TableCell className="text-right">{adminStats.totalEarningsAllStaff.toLocaleString('cs-CZ')} Kč</TableCell>
                        <TableCell className="text-right text-green-600">
                          {payouts.reduce((sum, p) => sum + Number(p.amount), 0).toLocaleString('cs-CZ')} Kč
                        </TableCell>
                        <TableCell className="text-right text-orange-600">
                          {adminStats.unpaidTotal.toLocaleString('cs-CZ')} Kč
                        </TableCell>
                        <TableCell></TableCell>
                      </TableRow>
                    </TableBody>
                  </Table>
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* Historie výplat */}
        <TabsContent value="history" className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <History className="h-5 w-5" />
                Historie výplat
              </CardTitle>
              <CardDescription>Přehled všech provedených výplat</CardDescription>
            </CardHeader>
            <CardContent>
              {payouts.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-8">
                  <History className="h-12 w-12 text-muted-foreground mb-4" />
                  <p className="text-muted-foreground">Zatím nebyly provedeny žádné výplaty.</p>
                </div>
              ) : (
                <div className="space-y-3">
                  {payouts.map((payout) => (
                    <div key={payout.id} className="flex items-center justify-between p-4 rounded-lg bg-accent/50">
                      <div>
                        <p className="font-medium">{(payout as any).profile?.full_name || 'Neznámý'}</p>
                        <p className="text-sm text-muted-foreground">
                          {format(new Date(payout.paid_at!), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                        </p>
                        {payout.notes && (
                          <p className="text-xs text-muted-foreground mt-1">{payout.notes}</p>
                        )}
                      </div>
                      <div className="text-right">
                        <p className="text-lg font-bold">{Number(payout.amount).toLocaleString('cs-CZ')} Kč</p>
                        <p className="text-xs text-muted-foreground">
                          vyplatil: {(payout as any).created_by_profile?.full_name || 'Systém'}
                        </p>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      {/* Payout Dialog */}
      <Dialog open={payoutDialogOpen} onOpenChange={setPayoutDialogOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Vyplatit brigádníka</DialogTitle>
            <DialogDescription>
              Potvrďte výplatu pro brigádníka. Všechny jeho nevyplacené směny budou označeny jako vyplacené.
            </DialogDescription>
          </DialogHeader>
          
          {selectedStaff && (
            <div className="space-y-4">
              <div className="p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900">
                <p className="font-medium text-lg">{selectedStaff.staffName}</p>
                <p className="text-3xl font-bold text-green-600 mt-2">
                  {selectedStaff.amount.toLocaleString('cs-CZ')} Kč
                </p>
              </div>

              <div className="space-y-2">
                <Label className="flex items-center gap-2">
                  <Landmark className="h-4 w-4" />
                  Číslo účtu
                </Label>
                {selectedStaff.bankAccount ? (
                  <div className="flex items-center gap-2 p-3 rounded-lg bg-accent/50 border">
                    <span className="font-mono text-base flex-1">{selectedStaff.bankAccount}</span>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-8 w-8"
                      onClick={() => {
                        navigator.clipboard.writeText(selectedStaff.bankAccount!);
                        toast({
                          title: 'Zkopírováno',
                          description: 'Číslo účtu bylo zkopírováno do schránky.',
                        });
                      }}
                    >
                      <Copy className="h-4 w-4" />
                    </Button>
                  </div>
                ) : (
                  <div className="p-3 rounded-lg bg-orange-50 dark:bg-orange-950/20 border border-orange-200 dark:border-orange-900 flex items-center gap-2">
                    <AlertCircle className="h-4 w-4 text-orange-600" />
                    <span className="text-sm text-orange-700 dark:text-orange-400">
                      Brigádník nemá vyplněné číslo účtu!
                    </span>
                  </div>
                )}
              </div>
              
              <div className="space-y-2">
                <Label htmlFor="payoutNotes">Poznámka k výplatě (volitelné)</Label>
                <Textarea
                  id="payoutNotes"
                  value={payoutNotes}
                  onChange={(e) => setPayoutNotes(e.target.value)}
                  placeholder="Např. Výplata za leden 2026..."
                />
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setPayoutDialogOpen(false)}>
              Zrušit
            </Button>
            <Button 
              onClick={handlePayout} 
              disabled={isCreatingPayout}
              className="bg-green-600 hover:bg-green-700"
            >
              {isCreatingPayout ? 'Zpracování...' : 'Potvrdit výplatu'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Staff Payout History Dialog */}
      <Dialog open={staffHistoryDialogOpen} onOpenChange={setStaffHistoryDialogOpen}>
        <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <History className="h-5 w-5" />
              Historie výplat - {selectedStaffHistory?.staffName}
            </DialogTitle>
            <DialogDescription>
              Detailní přehled všech výplat a dokončených směn brigádníka
            </DialogDescription>
          </DialogHeader>

          {selectedStaffHistory && (
            <div className="space-y-6">
              <div className="grid grid-cols-2 gap-4">
                <div className="p-4 rounded-lg bg-green-50 dark:bg-green-950/20 border border-green-200 dark:border-green-900">
                  <p className="text-sm text-muted-foreground">Celkem vyplaceno</p>
                  <p className="text-2xl font-bold text-green-600">
                    {getStaffPayouts(selectedStaffHistory.staffId)
                      .reduce((sum, p) => sum + Number(p.amount), 0)
                      .toLocaleString('cs-CZ')} Kč
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {getStaffPayouts(selectedStaffHistory.staffId).length} výplat
                  </p>
                </div>
                <div className="p-4 rounded-lg bg-accent/50 border">
                  <p className="text-sm text-muted-foreground">Dokončené směny</p>
                  <p className="text-2xl font-bold">
                    {getStaffCompletedShifts(selectedStaffHistory.staffId).length}
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    {getStaffCompletedShifts(selectedStaffHistory.staffId)
                      .reduce((sum, s) => sum + (Number(s.hours_worked) || 0), 0)
                      .toFixed(1)} h odpracováno
                  </p>
                </div>
              </div>

              <div>
                <h4 className="font-medium mb-3 flex items-center gap-2">
                  <Wallet className="h-4 w-4" />
                  Výplaty
                </h4>
                {getStaffPayouts(selectedStaffHistory.staffId).length === 0 ? (
                  <p className="text-muted-foreground text-sm py-4 text-center">Zatím žádné výplaty.</p>
                ) : (
                  <div className="space-y-2">
                    {getStaffPayouts(selectedStaffHistory.staffId).map((payout) => (
                      <div key={payout.id} className="flex items-center justify-between p-3 rounded-lg bg-accent/50">
                        <div>
                          <p className="font-medium">{Number(payout.amount).toLocaleString('cs-CZ')} Kč</p>
                          <p className="text-xs text-muted-foreground">
                            {format(new Date(payout.paid_at!), 'd. MMMM yyyy, HH:mm', { locale: cs })}
                          </p>
                          {payout.notes && (
                            <p className="text-xs text-muted-foreground mt-1">{payout.notes}</p>
                          )}
                        </div>
                        <Badge variant="outline" className="border-green-500 text-green-600">
                          <CheckCircle className="h-3 w-3 mr-1" />
                          Vyplaceno
                        </Badge>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              <div>
                <h4 className="font-medium mb-3 flex items-center gap-2">
                  <Clock className="h-4 w-4" />
                  Dokončené směny
                </h4>
                {getStaffCompletedShifts(selectedStaffHistory.staffId).length === 0 ? (
                  <p className="text-muted-foreground text-sm py-4 text-center">Zatím žádné dokončené směny.</p>
                ) : (
                  <div className="space-y-2 max-h-60 overflow-y-auto">
                    {getStaffCompletedShifts(selectedStaffHistory.staffId).map((shift) => (
                      <div key={shift.id} className="flex items-center justify-between p-3 rounded-lg bg-accent/30 border">
                        <div>
                          <p className="font-medium text-sm">{shift.event?.title || 'Směna'}</p>
                          <p className="text-xs text-muted-foreground">
                            {shift.event && format(new Date(shift.event.start_time), 'd. MMM yyyy', { locale: cs })}
                          </p>
                        </div>
                        <div className="text-right">
                          <p className="font-medium text-sm">
                            {(Number(shift.hours_worked) * Number(shift.hourly_rate)).toLocaleString('cs-CZ')} Kč
                          </p>
                          <p className="text-xs text-muted-foreground">
                            {shift.hours_worked} h × {shift.hourly_rate} Kč
                          </p>
                          {shift.payout_id ? (
                            <Badge variant="outline" className="text-[10px] mt-1 border-green-500 text-green-600">
                              Vyplaceno
                            </Badge>
                          ) : (
                            <Badge variant="outline" className="text-[10px] mt-1 border-orange-500 text-orange-600">
                              Čeká
                            </Badge>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setStaffHistoryDialogOpen(false)}>
              Zavřít
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Payouts;
