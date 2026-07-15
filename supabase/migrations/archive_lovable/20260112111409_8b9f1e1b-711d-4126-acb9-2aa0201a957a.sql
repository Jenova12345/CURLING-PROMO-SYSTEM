-- Add foreign key from payouts to profiles for user_id and created_by
ALTER TABLE public.payouts 
ADD CONSTRAINT payouts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(user_id) ON DELETE CASCADE,
ADD CONSTRAINT payouts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(user_id);