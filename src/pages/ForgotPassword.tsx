/**
 * Forgot Password Page
 * 
 * Allows users to request a password reset email.
 * Includes rate limiting and input validation.
 */

import { useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { useToast } from '@/hooks/use-toast';
import { emailSchema, safeValidate, VALIDATION_LIMITS } from '@/lib/validation';
import { useRateLimit } from '@/hooks/useRateLimit';
import { supabase } from '@/integrations/supabase/client';
import { ArrowLeft, Mail, CheckCircle } from 'lucide-react';
import { BRAND } from '@/config/brand';

const ForgotPassword = () => {
  const { user, loading } = useAuth();
  const { toast } = useToast();
  const [email, setEmail] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isEmailSent, setIsEmailSent] = useState(false);
  
  // Rate limiting
  const rateLimit = useRateLimit('password_reset');

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

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    
    // Check rate limit
    if (!rateLimit.checkLimit()) {
      toast({
        title: 'Příliš mnoho pokusů',
        description: `Zkuste to znovu za ${rateLimit.retryAfter}.`,
        variant: 'destructive',
      });
      return;
    }
    
    // Validate email
    const validation = safeValidate(emailSchema, email);
    
    if (!validation.success) {
      toast({
        title: 'Neplatný email',
        description: validation.error,
        variant: 'destructive',
      });
      return;
    }
    
    setIsSubmitting(true);
    
    // Použij origin pro redirect - bude fungovat na jakékoliv doméně
    const redirectUrl = `${window.location.origin}/update-password`;
    
    const { error } = await supabase.auth.resetPasswordForEmail(validation.data, {
      redirectTo: redirectUrl,
    });
    
    setIsSubmitting(false);
    
    if (error) {
      toast({
        title: 'Chyba',
        description: error.message,
        variant: 'destructive',
      });
    } else {
      setIsEmailSent(true);
      rateLimit.reset();
    }
  };

  if (isEmailSent) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-gradient-to-br from-primary/5 via-background to-secondary/5 p-4">
        <Card className="w-full max-w-md shadow-xl">
          <CardHeader className="text-center">
            <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-primary/10">
              <CheckCircle className="h-8 w-8 text-primary" />
            </div>
            <CardTitle className="text-2xl font-bold">Email odeslán</CardTitle>
            <CardDescription>
              Na adresu <strong>{email}</strong> jsme odeslali odkaz pro obnovení hesla.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-muted-foreground text-center">
              Zkontrolujte svou emailovou schránku včetně složky se spamem.
            </p>
            <Link to="/auth">
              <Button variant="outline" className="w-full">
                <ArrowLeft className="mr-2 h-4 w-4" />
                Zpět na přihlášení
              </Button>
            </Link>
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gradient-to-br from-primary/5 via-background to-secondary/5 p-4">
      <Card className="w-full max-w-md shadow-xl">
        <CardHeader className="text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-primary/10">
            <Mail className="h-8 w-8 text-primary" />
          </div>
          <CardTitle className="text-2xl font-bold">Zapomenuté heslo</CardTitle>
          <CardDescription>
            Zadejte svůj email a my vám pošleme odkaz pro obnovení hesla.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-4">
            {rateLimit.isLimited && (
              <div className="p-3 text-sm text-destructive bg-destructive/10 rounded-md">
                Příliš mnoho pokusů. Zkuste to za {rateLimit.retryAfter}.
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="email">E-mail</Label>
              <Input
                id="email"
                type="email"
                placeholder="vas@email.cz"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                maxLength={VALIDATION_LIMITS.EMAIL_MAX}
                required
                autoComplete="email"
                autoFocus
              />
            </div>
            <Button 
              type="submit" 
              className="w-full" 
              disabled={isSubmitting || rateLimit.isLimited}
            >
              {isSubmitting ? 'Odesílání...' : 'Odeslat odkaz'}
            </Button>
            <Link to="/auth">
              <Button variant="ghost" className="w-full">
                <ArrowLeft className="mr-2 h-4 w-4" />
                Zpět na přihlášení
              </Button>
            </Link>
          </form>
        </CardContent>
      </Card>
    </div>
  );
};

export default ForgotPassword;
