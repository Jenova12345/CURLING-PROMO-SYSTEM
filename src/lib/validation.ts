/**
 * Centralized Validation Schemas
 * 
 * OWASP Best Practices:
 * - Schema-based validation with Zod
 * - Strict length limits to prevent buffer overflow and DoS
 * - Type checking and format validation
 * - Rejection of unexpected fields (via .strict() where applicable)
 * - Input sanitization via .trim()
 * 
 * Security Notes:
 * - All strings are trimmed to prevent whitespace attacks
 * - Email validation uses standard RFC format
 * - Phone numbers use Czech format validation
 * - URLs are validated and must use HTTPS for external links
 * - All text fields have max length limits
 */

import { z } from 'zod';

// ============= Constants for validation limits =============
export const VALIDATION_LIMITS = {
  // Authentication
  EMAIL_MAX: 255,
  PASSWORD_MIN: 6,
  PASSWORD_MAX: 128,
  NAME_MIN: 2,
  NAME_MAX: 100,
  
  // Profile
  PHONE_MAX: 20,
  BANK_ACCOUNT_MAX: 34, // IBAN max length
  
  // Content
  TITLE_MIN: 1,
  TITLE_MAX: 200,
  DESCRIPTION_MAX: 2000,
  NOTES_MAX: 1000,
  
  // URLs
  URL_MAX: 2048,
  
  // Numbers
  HOURS_MIN: 0.1,
  HOURS_MAX: 24,
  RATE_MIN: 1,
  RATE_MAX: 10000,
  AMOUNT_MIN: 1,
  AMOUNT_MAX: 1000000,
  STAFF_COUNT_MIN: 0,
  STAFF_COUNT_MAX: 50,
} as const;

// ============= Authentication Schemas =============

/**
 * Email validation - RFC compliant, trimmed, lowercase normalized
 */
export const emailSchema = z
  .string()
  .trim()
  .toLowerCase()
  .min(1, 'E-mail je povinný')
  .max(VALIDATION_LIMITS.EMAIL_MAX, `E-mail může mít maximálně ${VALIDATION_LIMITS.EMAIL_MAX} znaků`)
  .email('Neplatný formát e-mailu');

/**
 * Password validation - minimum length, no excessive length to prevent DoS
 */
export const passwordSchema = z
  .string()
  .min(VALIDATION_LIMITS.PASSWORD_MIN, `Heslo musí mít alespoň ${VALIDATION_LIMITS.PASSWORD_MIN} znaků`)
  .max(VALIDATION_LIMITS.PASSWORD_MAX, `Heslo může mít maximálně ${VALIDATION_LIMITS.PASSWORD_MAX} znaků`);

/**
 * Full name validation - trimmed, reasonable length
 */
export const nameSchema = z
  .string()
  .trim()
  .min(VALIDATION_LIMITS.NAME_MIN, `Jméno musí mít alespoň ${VALIDATION_LIMITS.NAME_MIN} znaky`)
  .max(VALIDATION_LIMITS.NAME_MAX, `Jméno může mít maximálně ${VALIDATION_LIMITS.NAME_MAX} znaků`);

/**
 * Optional name (for updates)
 */
export const optionalNameSchema = z
  .string()
  .trim()
  .max(VALIDATION_LIMITS.NAME_MAX, `Jméno může mít maximálně ${VALIDATION_LIMITS.NAME_MAX} znaků`)
  .optional()
  .or(z.literal(''));

// ============= Profile Schemas =============

/**
 * Phone validation - Czech format, optional
 */
export const phoneSchema = z
  .string()
  .trim()
  .max(VALIDATION_LIMITS.PHONE_MAX, `Telefon může mít maximálně ${VALIDATION_LIMITS.PHONE_MAX} znaků`)
  .regex(/^(\+420\s?)?\d{3}\s?\d{3}\s?\d{3}$|^$/, 'Neplatný formát telefonu (např. +420 123 456 789)')
  .optional()
  .or(z.literal(''));

/**
 * Bank account validation - Czech format or IBAN
 */
export const bankAccountSchema = z
  .string()
  .trim()
  .max(VALIDATION_LIMITS.BANK_ACCOUNT_MAX, `Číslo účtu může mít maximálně ${VALIDATION_LIMITS.BANK_ACCOUNT_MAX} znaků`)
  .regex(
    /^(\d{1,6}-?\d{2,10}\/\d{4}|CZ\d{22}|)$/,
    'Neplatný formát čísla účtu (např. 123456-1234567890/0100 nebo CZ6508000000192000145399)'
  )
  .optional()
  .or(z.literal(''));

// ============= Content Schemas =============

/**
 * Title validation - non-empty, trimmed
 */
export const titleSchema = z
  .string()
  .trim()
  .min(VALIDATION_LIMITS.TITLE_MIN, 'Název je povinný')
  .max(VALIDATION_LIMITS.TITLE_MAX, `Název může mít maximálně ${VALIDATION_LIMITS.TITLE_MAX} znaků`);

/**
 * Description validation - optional, trimmed, length limited
 */
export const descriptionSchema = z
  .string()
  .trim()
  .max(VALIDATION_LIMITS.DESCRIPTION_MAX, `Popis může mít maximálně ${VALIDATION_LIMITS.DESCRIPTION_MAX} znaků`)
  .optional()
  .or(z.literal(''));

/**
 * Notes validation - optional, trimmed, length limited
 */
export const notesSchema = z
  .string()
  .trim()
  .max(VALIDATION_LIMITS.NOTES_MAX, `Poznámky mohou mít maximálně ${VALIDATION_LIMITS.NOTES_MAX} znaků`)
  .optional()
  .or(z.literal(''));

// ============= URL Schemas =============

/**
 * WhatsApp URL validation - must be valid WhatsApp chat link
 */
export const whatsappUrlSchema = z
  .string()
  .trim()
  .min(1, 'WhatsApp odkaz je povinný')
  .max(VALIDATION_LIMITS.URL_MAX, `URL může mít maximálně ${VALIDATION_LIMITS.URL_MAX} znaků`)
  .url('Neplatný formát URL')
  .refine(
    (url) => url.startsWith('https://chat.whatsapp.com/') || url.startsWith('https://wa.me/'),
    'URL musí být platný WhatsApp odkaz (https://chat.whatsapp.com/... nebo https://wa.me/...)'
  );

/**
 * Generic HTTPS URL validation
 */
export const httpsUrlSchema = z
  .string()
  .trim()
  .max(VALIDATION_LIMITS.URL_MAX, `URL může mít maximálně ${VALIDATION_LIMITS.URL_MAX} znaků`)
  .url('Neplatný formát URL')
  .refine((url) => url.startsWith('https://'), 'URL musí používat HTTPS protokol');

// ============= Numeric Schemas =============

/**
 * Hours worked validation
 */
export const hoursWorkedSchema = z
  .number()
  .min(VALIDATION_LIMITS.HOURS_MIN, `Minimálně ${VALIDATION_LIMITS.HOURS_MIN} hodiny`)
  .max(VALIDATION_LIMITS.HOURS_MAX, `Maximálně ${VALIDATION_LIMITS.HOURS_MAX} hodin`);

/**
 * Hourly rate validation
 */
export const hourlyRateSchema = z
  .number()
  .min(VALIDATION_LIMITS.RATE_MIN, `Minimálně ${VALIDATION_LIMITS.RATE_MIN} Kč/h`)
  .max(VALIDATION_LIMITS.RATE_MAX, `Maximálně ${VALIDATION_LIMITS.RATE_MAX} Kč/h`);

/**
 * Payout amount validation
 */
export const amountSchema = z
  .number()
  .min(VALIDATION_LIMITS.AMOUNT_MIN, `Minimálně ${VALIDATION_LIMITS.AMOUNT_MIN} Kč`)
  .max(VALIDATION_LIMITS.AMOUNT_MAX, `Maximálně ${VALIDATION_LIMITS.AMOUNT_MAX} Kč`);

/**
 * Required staff count validation
 */
export const staffCountSchema = z
  .number()
  .int('Počet musí být celé číslo')
  .min(VALIDATION_LIMITS.STAFF_COUNT_MIN, `Minimálně ${VALIDATION_LIMITS.STAFF_COUNT_MIN}`)
  .max(VALIDATION_LIMITS.STAFF_COUNT_MAX, `Maximálně ${VALIDATION_LIMITS.STAFF_COUNT_MAX}`);

// ============= ID Schemas =============

/**
 * UUID validation for IDs
 */
export const uuidSchema = z
  .string()
  .uuid('Neplatný identifikátor');

// ============= Composite Schemas =============

/**
 * Login form validation
 */
export const loginFormSchema = z.object({
  email: emailSchema,
  password: z.string().min(1, 'Heslo je povinné'), // Don't apply max on login
});

/**
 * Registration form validation
 */
export const registerFormSchema = z.object({
  name: nameSchema,
  email: emailSchema,
  password: passwordSchema,
});

/**
 * Profile update validation
 */
export const profileUpdateSchema = z.object({
  fullName: optionalNameSchema,
  phone: phoneSchema,
  avatarUrl: httpsUrlSchema.optional().or(z.literal('')),
  bankAccount: bankAccountSchema,
});

/**
 * Chat group form validation
 */
export const chatGroupSchema = z.object({
  name: titleSchema,
  description: descriptionSchema,
  whatsapp_url: whatsappUrlSchema,
  icon_slug: z.string().max(50).optional(),
  authorized_roles: z.array(z.enum([
    'admin', 'trainer', 'part_time_staff', 'instructor', 
    'bar_staff', 'manager', 'pro_player', 'hobby_player'
  ])),
  visible_to_user_ids: z.array(z.string().uuid()).nullable().optional(),
});

/**
 * Event form validation with datetime refinement
 * Validates that end_time is after start_time
 */
export const eventSchema = z.object({
  title: titleSchema,
  description: descriptionSchema,
  event_type: z.enum(['commercial', 'training', 'maintenance', 'recruitment']),
  start_time: z.string().refine((val) => !isNaN(Date.parse(val)), 'Neplatný formát data/času'),
  end_time: z.string().refine((val) => !isNaN(Date.parse(val)), 'Neplatný formát data/času'),
  required_staff: staffCountSchema.optional(),
}).refine(
  (data) => new Date(data.end_time) > new Date(data.start_time),
  { message: 'Konec události musí být po jejím začátku', path: ['end_time'] }
);

/**
 * Reservation form validation (rezervace ledu)
 * Validates that end_at is after start_at
 */
export const reservationSchema = z.object({
  sheet_id: uuidSchema,
  subject_id: uuidSchema,
  start_at: z.string().refine((val) => !isNaN(Date.parse(val)), 'Neplatný formát data/času'),
  end_at: z.string().refine((val) => !isNaN(Date.parse(val)), 'Neplatný formát data/času'),
  note: notesSchema,
}).refine(
  (data) => new Date(data.end_at) > new Date(data.start_at),
  { message: 'Konec rezervace musí být po jejím začátku', path: ['end_at'] }
);

/**
 * Complete shift form validation
 */
export const completeShiftSchema = z.object({
  shiftId: uuidSchema,
  hoursWorked: hoursWorkedSchema,
  hourlyRate: hourlyRateSchema,
  notes: notesSchema,
});

/**
 * Payout form validation
 */
export const payoutSchema = z.object({
  userId: uuidSchema,
  amount: amountSchema,
  notes: notesSchema,
});

// ============= Role & Assignment Schemas =============

/**
 * Valid app roles enum - updated with all roles
 */
export const appRoleSchema = z.enum([
  'admin',
  'trainer',
  'part_time_staff',
  'instructor',
  'bar_staff',
  'manager',
  'pro_player',
  'hobby_player',
]);

/**
 * Role update validation - for admin changing user roles
 */
export const roleUpdateSchema = z.object({
  userId: uuidSchema,
  role: appRoleSchema,
});

/**
 * Shift assignment validation - for admin assigning staff to shifts
 */
export const assignShiftSchema = z.object({
  shiftId: uuidSchema,
  staffId: uuidSchema,
});

/**
 * Shift request validation - for staff requesting shifts
 */
export const shiftRequestSchema = z.object({
  shiftId: uuidSchema,
});

// ============= Utility Functions =============

/**
 * Safe parse with error message extraction
 * Returns { success: true, data } or { success: false, error: string }
 */
export function safeValidate<T>(
  schema: z.ZodSchema<T>,
  data: unknown
): { success: true; data: T; error?: undefined } | { success: false; error: string; data?: undefined } {
  const result = schema.safeParse(data);
  
  if (result.success) {
    return { success: true, data: result.data };
  }
  
  // Get the first error message
  const firstError = result.error.errors[0];
  return { success: false, error: firstError?.message || 'Neplatný vstup' };
}

/**
 * Sanitize string input - trim and remove control characters
 * Use before storing text that might contain user input
 */
export function sanitizeText(input: string): string {
  if (typeof input !== 'string') return '';
  
  return input
    .trim()
    // Remove null bytes and control characters (except newlines/tabs)
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '')
    // Limit consecutive whitespace
    .replace(/\s{3,}/g, '  ');
}

/**
 * Validate and sanitize a numeric string input
 */
export function parseNumericInput(input: string, fallback: number = 0): number {
  const trimmed = input.trim();
  if (!trimmed) return fallback;
  
  // Parse with comma as decimal separator (Czech format)
  const normalized = trimmed.replace(',', '.');
  const parsed = parseFloat(normalized);
  
  if (isNaN(parsed) || !isFinite(parsed)) {
    return fallback;
  }
  
  return parsed;
}
