/**
 * Authentication Page
 * 
 * Security Features:
 * - Schema-based input validation with Zod
 * - Client-side rate limiting for login/register attempts
 * - Strict length limits on all inputs
 * - No sensitive data logged to console
 */

import { useState } from 'react';
import { Navigate, Link } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { 
  loginFormSchema, 
  registerFormSchema, 
  safeValidate,
  VALIDATION_LIMITS 
} from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';
import { BRAND } from '@/config/brand';

const Auth = () => {
  const { user, loading, signIn, signUp } = useAuth();
  const { toast } = useToast();
  const [isSubmitting, setIsSubmitting] = useState(false);
  
  // Rate limiting for auth actions
  const loginRateLimit = useRateLimit('login');
  const registerRateLimit = useRateLimit('register');
  
  // Login state
  const [loginEmail, setLoginEmail] = useState('');
  const [loginPassword, setLoginPassword] = useState('');
  
  // Register state
  const [registerEmail, setRegisterEmail] = useState('');
  const [registerPassword, setRegisterPassword] = useState('');
  const [registerName, setRegisterName] = useState('');

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
      </div>
    );
  }

  if (user) {
    return <Navigate to="/" replace />;
  }

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    
    // Check rate limit first
    if (!loginRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho pokusů',
        description: `Zkuste to znovu za ${loginRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }
    
    // Validate inputs with schema
    const validation = safeValidate(loginFormSchema, {
      email: loginEmail,
      password: loginPassword,
    });
    
    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }
    
    const validatedData = validation.data;
    setIsSubmitting(true);
    const { error } = await signIn(validatedData.email, validatedData.password);
    setIsSubmitting(false);

    if (error) {
      toast({
        title: 'Chyba přihlášení',
        description: error.message === 'Invalid login credentials' 
          ? 'Neplatné přihlašovací údaje' 
          : error.message,
        variant: 'destructive',
      });
    } else {
      // Reset rate limit on successful login
      loginRateLimit.reset();
    }
  };

  const handleRegister = async (e: React.FormEvent) => {
    e.preventDefault();
    
    // Check rate limit first
    if (!registerRateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho pokusů',
        description: `Zkuste to znovu za ${registerRateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }
    
    // Validate inputs with schema
    const validation = safeValidate(registerFormSchema, {
      name: registerName,
      email: registerEmail,
      password: registerPassword,
    });
    
    if (!validation.success) {
      toast({
        title: 'Chyba validace',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }
    
    const validatedData = validation.data;

    setIsSubmitting(true);
    const { error } = await signUp(
      validatedData.email, 
      validatedData.password, 
      validatedData.name
    );
    setIsSubmitting(false);

    if (error) {
      if (error.message.includes('already registered')) {
        toast({
          title: 'Účet již existuje',
          description: 'Uživatel s tímto e-mailem je již zaregistrován.',
          variant: 'destructive',
        });
      } else {
        toast({
          title: 'Chyba registrace',
          description: error.message,
          variant: 'destructive',
        });
      }
    } else {
      // Reset rate limit on successful registration
      registerRateLimit.reset();
      // Clear form
      setRegisterEmail('');
      setRegisterPassword('');
      setRegisterName('');
      toast({
        title: 'Registrace úspěšná!',
        description: 'Zkontrolujte prosím svůj email pro potvrzení registrace.',
        duration: 10000, // Show longer for important message
      });
    }
  };

  // Check if rate limited to disable buttons
  const isLoginDisabled = isSubmitting || loginRateLimit.isLimited;
  const isRegisterDisabled = isSubmitting || registerRateLimit.isLimited;

  return (
    <div className="flex min-h-screen items-center justify-center bg-gradient-to-br from-primary/5 via-background to-secondary/5 p-4">
      <Card className="w-full max-w-md shadow-xl">
        <CardHeader className="text-center">
          <div className="mx-auto mb-4">
            <img src="/logo-placeholder.svg" alt={BRAND.name} className="h-20 w-auto mx-auto" />
          </div>
          <CardTitle className="text-2xl font-bold">{BRAND.name}</CardTitle>
          <CardDescription>Systém pro správu curlingové haly</CardDescription>
        </CardHeader>
        <CardContent>
          <Tabs defaultValue="login" className="w-full">
            <TabsList className="grid w-full grid-cols-2">
              <TabsTrigger value="login">Přihlášení</TabsTrigger>
              <TabsTrigger value="register">Registrace</TabsTrigger>
            </TabsList>
            
            <TabsContent value="login">
              <form onSubmit={handleLogin} className="space-y-4">
                {loginRateLimit.isLimited && (
                  <div className="p-3 text-sm text-destructive bg-destructive/10 rounded-md">
                    Příliš mnoho pokusů. Zkuste to za {loginRateLimit.retryAfter}.
                  </div>
                )}
                <div className="space-y-2">
                  <Label htmlFor="login-email">E-mail</Label>
                  <Input
                    id="login-email"
                    type="email"
                    placeholder="vas@email.cz"
                    value={loginEmail}
                    onChange={(e) => setLoginEmail(e.target.value)}
                    maxLength={VALIDATION_LIMITS.EMAIL_MAX}
                    required
                    autoComplete="email"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="login-password">Heslo</Label>
                  <Input
                    id="login-password"
                    type="password"
                    placeholder="••••••••"
                    value={loginPassword}
                    onChange={(e) => setLoginPassword(e.target.value)}
                    maxLength={VALIDATION_LIMITS.PASSWORD_MAX}
                    required
                    autoComplete="current-password"
                  />
                </div>
                <Button type="submit" className="w-full" disabled={isLoginDisabled}>
                  {isSubmitting ? 'Přihlašování...' : 'Přihlásit se'}
                </Button>
                <div className="text-center">
                  <Link 
                    to="/forgot-password" 
                    className="text-sm text-muted-foreground hover:text-primary transition-colors"
                  >
                    Zapomněli jste heslo?
                  </Link>
                </div>
              </form>
            </TabsContent>
            
            <TabsContent value="register">
              <form onSubmit={handleRegister} className="space-y-4">
                {registerRateLimit.isLimited && (
                  <div className="p-3 text-sm text-destructive bg-destructive/10 rounded-md">
                    Příliš mnoho pokusů. Zkuste to za {registerRateLimit.retryAfter}.
                  </div>
                )}
                <div className="space-y-2">
                  <Label htmlFor="register-name">Celé jméno</Label>
                  <Input
                    id="register-name"
                    type="text"
                    placeholder="Jan Novák"
                    value={registerName}
                    onChange={(e) => setRegisterName(e.target.value)}
                    maxLength={VALIDATION_LIMITS.NAME_MAX}
                    required
                    autoComplete="name"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="register-email">E-mail</Label>
                  <Input
                    id="register-email"
                    type="email"
                    placeholder="vas@email.cz"
                    value={registerEmail}
                    onChange={(e) => setRegisterEmail(e.target.value)}
                    maxLength={VALIDATION_LIMITS.EMAIL_MAX}
                    required
                    autoComplete="email"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="register-password">Heslo</Label>
                  <Input
                    id="register-password"
                    type="password"
                    placeholder="••••••••"
                    value={registerPassword}
                    onChange={(e) => setRegisterPassword(e.target.value)}
                    maxLength={VALIDATION_LIMITS.PASSWORD_MAX}
                    required
                    autoComplete="new-password"
                  />
                  <p className="text-xs text-muted-foreground">
                    Minimálně {VALIDATION_LIMITS.PASSWORD_MIN} znaků
                  </p>
                </div>
                <Button type="submit" className="w-full" disabled={isRegisterDisabled}>
                  {isSubmitting ? 'Registrace...' : 'Zaregistrovat se'}
                </Button>
              </form>
            </TabsContent>
          </Tabs>
        </CardContent>
      </Card>
    </div>
  );
};

export default Auth;
