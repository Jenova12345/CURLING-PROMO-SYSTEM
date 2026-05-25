CREATE TABLE public.shift_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id uuid NOT NULL REFERENCES public.shifts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shift_id, user_id)
);

CREATE INDEX idx_shift_applications_shift ON public.shift_applications(shift_id);
CREATE INDEX idx_shift_applications_user ON public.shift_applications(user_id);

ALTER TABLE public.shift_applications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View own applications or admin"
  ON public.shift_applications FOR SELECT
  USING (user_id = auth.uid() OR has_role(auth.uid(), 'admin'::app_role));

CREATE POLICY "Users insert own applications"
  ON public.shift_applications FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users update own or admin updates any"
  ON public.shift_applications FOR UPDATE
  USING (user_id = auth.uid() OR has_role(auth.uid(), 'admin'::app_role));

CREATE POLICY "Admin delete applications"
  ON public.shift_applications FOR DELETE
  USING (has_role(auth.uid(), 'admin'::app_role));

CREATE TRIGGER trg_shift_applications_updated_at
  BEFORE UPDATE ON public.shift_applications
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();