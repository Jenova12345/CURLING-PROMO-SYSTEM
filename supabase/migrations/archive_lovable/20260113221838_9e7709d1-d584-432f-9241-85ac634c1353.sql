-- Add bank_account column to profiles table
ALTER TABLE public.profiles 
ADD COLUMN bank_account text;

-- Add comment for clarity
COMMENT ON COLUMN public.profiles.bank_account IS 'Bank account number for staff payouts';