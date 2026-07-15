-- Add 'pending' status to shift_status enum
ALTER TYPE shift_status ADD VALUE 'pending' BEFORE 'claimed';