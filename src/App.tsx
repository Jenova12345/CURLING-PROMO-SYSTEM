import { Toaster } from "@/components/ui/toaster";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { AuthProvider } from "@/contexts/AuthContext";
import AppLayout from "@/components/layout/AppLayout";
import Auth from "./pages/Auth";
import ForgotPassword from "./pages/ForgotPassword";
import UpdatePassword from "./pages/UpdatePassword";
import Dashboard from "./pages/Dashboard";
import Calendar from "./pages/Calendar";
import Cenik from "./pages/Cenik";
import Dues from "./pages/Dues";
import Requests from "./pages/Requests";
import MujKlub from "./pages/MujKlub";
import Subjects from "./pages/Subjects";
import Settings from "./pages/Settings";
import Portal from "./pages/Portal";
import Shifts from "./pages/Shifts";
import Payouts from "./pages/Payouts";
import Profile from "./pages/Profile";
import Members from "./pages/Members";
import Communication from "./pages/Communication";
import Help from "./pages/Help";
import NotFound from "./pages/NotFound";

const queryClient = new QueryClient();

const App = () => (
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <AuthProvider>
        <Toaster />
        <Sonner />
        <BrowserRouter>
          <Routes>
            <Route path="/portal" element={<Portal />} />
            <Route path="/auth" element={<Auth />} />
            <Route path="/forgot-password" element={<ForgotPassword />} />
            <Route path="/update-password" element={<UpdatePassword />} />
            <Route element={<AppLayout />}>
              <Route path="/" element={<Dashboard />} />
              <Route path="/calendar" element={<Calendar />} />
              {/* Rezervace sloučeny do Kalendáře — starý odkaz přesměruj */}
              <Route path="/reservations" element={<Navigate to="/calendar" replace />} />
              <Route path="/cenik" element={<Cenik />} />
              <Route path="/shifts" element={<Shifts />} />
              <Route path="/dues" element={<Dues />} />
              {/* Stránka Faktury zrušena 16. 9. 2026 — ostré doklady vystavuje
                  Fakturoid a interní engine je zamčený. Kontrolní součet, jediná
                  živá věc, co na ní byla, je teď v Přehledu fakturace. Odkaz
                  přesměrováváme, ne zahazujeme: kdo má „/invoices" v záložkách,
                  má dojít tam, kam se obsah přestěhoval, ne na „nenalezeno". */}
              <Route path="/invoices" element={<Navigate to="/dues" replace />} />
              <Route path="/requests" element={<Requests />} />
              <Route path="/muj-klub" element={<MujKlub />} />
              <Route path="/subjects" element={<Subjects />} />
              <Route path="/settings" element={<Settings />} />
              <Route path="/payouts" element={<Payouts />} />
              <Route path="/profile" element={<Profile />} />
              <Route path="/members" element={<Members />} />
              <Route path="/communication" element={<Communication />} />
              <Route path="/help" element={<Help />} />
            </Route>
            <Route path="*" element={<NotFound />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </TooltipProvider>
  </QueryClientProvider>
);

export default App;
