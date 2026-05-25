/**
 * Client-Side Rate Limiting Hook
 * 
 * OWASP Best Practices:
 * - Prevents rapid-fire requests to sensitive endpoints
 * - IP-agnostic (works per-browser session)
 * - Provides graceful 429-like feedback to users
 * - Configurable limits per action type
 * 
 * Security Notes:
 * - This is CLIENT-SIDE rate limiting as a first line of defense
 * - Server-side rate limiting (via Supabase/edge functions) is also required
 * - Uses sessionStorage to persist across page reloads
 * - Exponential backoff for repeated violations
 */

import { useState, useCallback, useRef, useEffect } from 'react';

// Rate limit configurations for different action types
export const RATE_LIMIT_CONFIG = {
  // Authentication - strict limits
  login: { maxAttempts: 5, windowMs: 60 * 1000, cooldownMs: 60 * 1000 },
  register: { maxAttempts: 3, windowMs: 60 * 1000, cooldownMs: 120 * 1000 },
  password_reset: { maxAttempts: 3, windowMs: 60 * 1000, cooldownMs: 120 * 1000 },
  
  // Data mutations - moderate limits
  createEvent: { maxAttempts: 10, windowMs: 60 * 1000, cooldownMs: 30 * 1000 },
  updateProfile: { maxAttempts: 10, windowMs: 60 * 1000, cooldownMs: 30 * 1000 },
  shiftAction: { maxAttempts: 20, windowMs: 60 * 1000, cooldownMs: 15 * 1000 },
  
  // Admin actions - moderate limits
  updateRole: { maxAttempts: 15, windowMs: 60 * 1000, cooldownMs: 20 * 1000 },
  createPayout: { maxAttempts: 10, windowMs: 60 * 1000, cooldownMs: 30 * 1000 },
  completeShift: { maxAttempts: 20, windowMs: 60 * 1000, cooldownMs: 15 * 1000 },
  assignShift: { maxAttempts: 15, windowMs: 60 * 1000, cooldownMs: 20 * 1000 },
  
  // General API calls - lenient limits
  default: { maxAttempts: 30, windowMs: 60 * 1000, cooldownMs: 10 * 1000 },
} as const;

type RateLimitAction = keyof typeof RATE_LIMIT_CONFIG;

interface RateLimitState {
  attempts: number;
  windowStart: number;
  cooldownUntil: number;
  violations: number;
}

interface RateLimitResult {
  allowed: boolean;
  remainingAttempts: number;
  retryAfterMs: number;
  retryAfterText: string;
}

/**
 * Get storage key for rate limit state
 */
function getStorageKey(action: RateLimitAction): string {
  return `rate_limit_${action}`;
}

/**
 * Get rate limit state from session storage
 */
function getState(action: RateLimitAction): RateLimitState {
  try {
    const stored = sessionStorage.getItem(getStorageKey(action));
    if (stored) {
      return JSON.parse(stored);
    }
  } catch {
    // Ignore storage errors
  }
  
  return {
    attempts: 0,
    windowStart: Date.now(),
    cooldownUntil: 0,
    violations: 0,
  };
}

/**
 * Save rate limit state to session storage
 */
function saveState(action: RateLimitAction, state: RateLimitState): void {
  try {
    sessionStorage.setItem(getStorageKey(action), JSON.stringify(state));
  } catch {
    // Ignore storage errors
  }
}

/**
 * Format milliseconds to human-readable Czech text
 */
function formatRetryTime(ms: number): string {
  if (ms <= 0) return '';
  
  const seconds = Math.ceil(ms / 1000);
  if (seconds < 60) {
    return `${seconds} sekund${seconds === 1 ? 'u' : seconds < 5 ? 'y' : ''}`;
  }
  
  const minutes = Math.ceil(seconds / 60);
  return `${minutes} minut${minutes === 1 ? 'u' : minutes < 5 ? 'y' : ''}`;
}

/**
 * Check if an action is rate limited and record the attempt
 */
export function checkRateLimit(action: RateLimitAction = 'default'): RateLimitResult {
  const config = RATE_LIMIT_CONFIG[action];
  const now = Date.now();
  let state = getState(action);
  
  // Check if in cooldown
  if (state.cooldownUntil > now) {
    const retryAfterMs = state.cooldownUntil - now;
    return {
      allowed: false,
      remainingAttempts: 0,
      retryAfterMs,
      retryAfterText: formatRetryTime(retryAfterMs),
    };
  }
  
  // Reset window if expired
  if (now - state.windowStart > config.windowMs) {
    state = {
      attempts: 0,
      windowStart: now,
      cooldownUntil: 0,
      violations: state.violations, // Keep violation count for exponential backoff
    };
  }
  
  // Check if limit exceeded
  if (state.attempts >= config.maxAttempts) {
    // Apply exponential backoff based on violations
    const backoffMultiplier = Math.min(Math.pow(2, state.violations), 8);
    const cooldownMs = config.cooldownMs * backoffMultiplier;
    
    state.cooldownUntil = now + cooldownMs;
    state.violations += 1;
    saveState(action, state);
    
    return {
      allowed: false,
      remainingAttempts: 0,
      retryAfterMs: cooldownMs,
      retryAfterText: formatRetryTime(cooldownMs),
    };
  }
  
  // Record attempt
  state.attempts += 1;
  saveState(action, state);
  
  return {
    allowed: true,
    remainingAttempts: config.maxAttempts - state.attempts,
    retryAfterMs: 0,
    retryAfterText: '',
  };
}

/**
 * Reset rate limit for an action (e.g., after successful login)
 */
export function resetRateLimit(action: RateLimitAction): void {
  try {
    sessionStorage.removeItem(getStorageKey(action));
  } catch {
    // Ignore storage errors
  }
}

/**
 * React hook for rate limiting
 */
export function useRateLimit(action: RateLimitAction = 'default') {
  const [isLimited, setIsLimited] = useState(false);
  const [retryAfter, setRetryAfter] = useState('');
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  
  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (timerRef.current) {
        clearTimeout(timerRef.current);
      }
    };
  }, []);
  
  /**
   * Check rate limit before performing an action
   * Returns true if allowed, false if rate limited
   */
  const checkLimit = useCallback((): boolean => {
    const result = checkRateLimit(action);
    
    if (!result.allowed) {
      setIsLimited(true);
      setRetryAfter(result.retryAfterText);
      
      // Clear the limited state after cooldown
      if (timerRef.current) {
        clearTimeout(timerRef.current);
      }
      timerRef.current = setTimeout(() => {
        setIsLimited(false);
        setRetryAfter('');
      }, result.retryAfterMs);
      
      return false;
    }
    
    return true;
  }, [action]);
  
  /**
   * Reset the rate limit (e.g., after successful action)
   */
  const reset = useCallback(() => {
    resetRateLimit(action);
    setIsLimited(false);
    setRetryAfter('');
    
    if (timerRef.current) {
      clearTimeout(timerRef.current);
    }
  }, [action]);
  
  return {
    isLimited,
    retryAfter,
    checkLimit,
    reset,
  };
}

/**
 * Higher-order function to wrap async actions with rate limiting
 */
export function withRateLimit<T extends (...args: unknown[]) => Promise<unknown>>(
  action: RateLimitAction,
  fn: T,
  onLimited?: (retryAfter: string) => void
): T {
  return (async (...args: Parameters<T>) => {
    const result = checkRateLimit(action);
    
    if (!result.allowed) {
      if (onLimited) {
        onLimited(result.retryAfterText);
      }
      throw new Error(`Příliš mnoho pokusů. Zkuste to znovu za ${result.retryAfterText}.`);
    }
    
    return fn(...args);
  }) as T;
}
