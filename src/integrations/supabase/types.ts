export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      audit_log: {
        Row: {
          action: string
          changed_at: string
          changed_by: string | null
          id: string
          new_data: Json | null
          old_data: Json | null
          record_id: string | null
          table_name: string
        }
        Insert: {
          action: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          new_data?: Json | null
          old_data?: Json | null
          record_id?: string | null
          table_name: string
        }
        Update: {
          action?: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          new_data?: Json | null
          old_data?: Json | null
          record_id?: string | null
          table_name?: string
        }
        Relationships: []
      }
      billing_settings: {
        Row: {
          auto_issue: boolean
          automation_enabled: boolean
          bank_account: string | null
          bank_bic: string | null
          bank_iban: string | null
          created_at: string
          created_by: string | null
          daily_run_hour: number
          due_days: number
          file_prefix: string
          id: string
          invoice_only_approved: boolean
          monthly_run_day: number
          monthly_run_hour: number
          number_format: string
          payment_message: string | null
          separate_series: boolean
          singleton: boolean
          supplier_address: string | null
          supplier_dic: string | null
          supplier_ico: string | null
          supplier_legal_form: string | null
          supplier_name: string | null
          supplier_registry: string | null
          updated_at: string
          updated_by: string | null
          vat_mode: Database["public"]["Enums"]["vat_mode"]
        }
        Insert: {
          auto_issue?: boolean
          automation_enabled?: boolean
          bank_account?: string | null
          bank_bic?: string | null
          bank_iban?: string | null
          created_at?: string
          created_by?: string | null
          daily_run_hour?: number
          due_days?: number
          file_prefix?: string
          id?: string
          invoice_only_approved?: boolean
          monthly_run_day?: number
          monthly_run_hour?: number
          number_format?: string
          payment_message?: string | null
          separate_series?: boolean
          singleton?: boolean
          supplier_address?: string | null
          supplier_dic?: string | null
          supplier_ico?: string | null
          supplier_legal_form?: string | null
          supplier_name?: string | null
          supplier_registry?: string | null
          updated_at?: string
          updated_by?: string | null
          vat_mode?: Database["public"]["Enums"]["vat_mode"]
        }
        Update: {
          auto_issue?: boolean
          automation_enabled?: boolean
          bank_account?: string | null
          bank_bic?: string | null
          bank_iban?: string | null
          created_at?: string
          created_by?: string | null
          daily_run_hour?: number
          due_days?: number
          file_prefix?: string
          id?: string
          invoice_only_approved?: boolean
          monthly_run_day?: number
          monthly_run_hour?: number
          number_format?: string
          payment_message?: string | null
          separate_series?: boolean
          singleton?: boolean
          supplier_address?: string | null
          supplier_dic?: string | null
          supplier_ico?: string | null
          supplier_legal_form?: string | null
          supplier_name?: string | null
          supplier_registry?: string | null
          updated_at?: string
          updated_by?: string | null
          vat_mode?: Database["public"]["Enums"]["vat_mode"]
        }
        Relationships: [
          {
            foreignKeyName: "billing_settings_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "billing_settings_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "billing_settings_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "billing_settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "billing_settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "billing_settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      chat_groups: {
        Row: {
          authorized_roles: Database["public"]["Enums"]["app_role"][]
          created_at: string
          description: string | null
          icon: string | null
          icon_slug: string | null
          id: string
          name: string
          updated_at: string
          visible_to_user_ids: string[] | null
          whatsapp_url: string
        }
        Insert: {
          authorized_roles: Database["public"]["Enums"]["app_role"][]
          created_at?: string
          description?: string | null
          icon?: string | null
          icon_slug?: string | null
          id?: string
          name: string
          updated_at?: string
          visible_to_user_ids?: string[] | null
          whatsapp_url: string
        }
        Update: {
          authorized_roles?: Database["public"]["Enums"]["app_role"][]
          created_at?: string
          description?: string | null
          icon?: string | null
          icon_slug?: string | null
          id?: string
          name?: string
          updated_at?: string
          visible_to_user_ids?: string[] | null
          whatsapp_url?: string
        }
        Relationships: []
      }
      email_outbox: {
        Row: {
          attempts: number
          body: string
          created_at: string
          email: string
          id: string
          last_error: string | null
          notification_id: string | null
          sent_at: string | null
          status: string
          subject: string
          user_id: string | null
        }
        Insert: {
          attempts?: number
          body: string
          created_at?: string
          email: string
          id?: string
          last_error?: string | null
          notification_id?: string | null
          sent_at?: string | null
          status?: string
          subject: string
          user_id?: string | null
        }
        Update: {
          attempts?: number
          body?: string
          created_at?: string
          email?: string
          id?: string
          last_error?: string | null
          notification_id?: string | null
          sent_at?: string | null
          status?: string
          subject?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "email_outbox_notification_id_fkey"
            columns: ["notification_id"]
            isOneToOne: false
            referencedRelation: "notifications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "email_outbox_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "email_outbox_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "email_outbox_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      events: {
        Row: {
          created_at: string
          created_by: string | null
          description: string | null
          end_time: string
          event_type: Database["public"]["Enums"]["event_type"]
          id: string
          required_staff: number | null
          role_reqs: Json | null
          start_time: string
          title: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          end_time: string
          event_type?: Database["public"]["Enums"]["event_type"]
          id?: string
          required_staff?: number | null
          role_reqs?: Json | null
          start_time: string
          title: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          end_time?: string
          event_type?: Database["public"]["Enums"]["event_type"]
          id?: string
          required_staff?: number | null
          role_reqs?: Json | null
          start_time?: string
          title?: string
          updated_at?: string
        }
        Relationships: []
      }
      invoice_counter: {
        Row: {
          posledni: number
          rada: string
          rok: number
        }
        Insert: {
          posledni?: number
          rada: string
          rok: number
        }
        Update: {
          posledni?: number
          rada?: string
          rok?: number
        }
        Relationships: []
      }
      invoice_items: {
        Row: {
          cas_do: string | null
          cas_od: string | null
          created_at: string
          datum: string | null
          hodiny: number
          id: string
          invoice_id: string
          line_total: number
          popis: string
          poradi: number
          reservation_id: string | null
          sazba: number
          vat_amount: number | null
          vat_base: number | null
          vat_rate: number | null
        }
        Insert: {
          cas_do?: string | null
          cas_od?: string | null
          created_at?: string
          datum?: string | null
          hodiny: number
          id?: string
          invoice_id: string
          line_total: number
          popis: string
          poradi?: number
          reservation_id?: string | null
          sazba: number
          vat_amount?: number | null
          vat_base?: number | null
          vat_rate?: number | null
        }
        Update: {
          cas_do?: string | null
          cas_od?: string | null
          created_at?: string
          datum?: string | null
          hodiny?: number
          id?: string
          invoice_id?: string
          line_total?: number
          popis?: string
          poradi?: number
          reservation_id?: string | null
          sazba?: number
          vat_amount?: number | null
          vat_base?: number | null
          vat_rate?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoice_items_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_list"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: false
            referencedRelation: "reservations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: false
            referencedRelation: "reservations_billing"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: false
            referencedRelation: "reservations_calendar"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices: {
        Row: {
          cislo: string | null
          created_at: string
          created_by: string | null
          datum_splatnosti: string | null
          datum_uhrady: string | null
          datum_vystaveni: string | null
          dodavatel_adresa: string | null
          dodavatel_dic: string | null
          dodavatel_iban: string | null
          dodavatel_ico: string | null
          dodavatel_nazev: string | null
          dodavatel_rejstrik: string | null
          dodavatel_ucet: string | null
          dodavatel_zprava: string | null
          event_id: string | null
          id: string
          issued_at: string | null
          issued_by: string | null
          kind: Database["public"]["Enums"]["invoice_kind"]
          obdobi_do: string
          obdobi_od: string
          odberatel_adresa: string | null
          odberatel_dic: string | null
          odberatel_ico: string | null
          odberatel_nazev: string | null
          opravuje_id: string | null
          paid_at: string | null
          paid_by: string | null
          pdf_path: string | null
          pdf_sha256: string | null
          rounding_amount: number
          status: Database["public"]["Enums"]["invoice_status"]
          storno_duvod: string | null
          subject_id: string
          subtotal: number
          total: number
          total_rounded: number
          updated_at: string
          updated_by: string | null
          variabilni_symbol: string | null
          vat_mode: Database["public"]["Enums"]["vat_mode"]
        }
        Insert: {
          cislo?: string | null
          created_at?: string
          created_by?: string | null
          datum_splatnosti?: string | null
          datum_uhrady?: string | null
          datum_vystaveni?: string | null
          dodavatel_adresa?: string | null
          dodavatel_dic?: string | null
          dodavatel_iban?: string | null
          dodavatel_ico?: string | null
          dodavatel_nazev?: string | null
          dodavatel_rejstrik?: string | null
          dodavatel_ucet?: string | null
          dodavatel_zprava?: string | null
          event_id?: string | null
          id?: string
          issued_at?: string | null
          issued_by?: string | null
          kind: Database["public"]["Enums"]["invoice_kind"]
          obdobi_do: string
          obdobi_od: string
          odberatel_adresa?: string | null
          odberatel_dic?: string | null
          odberatel_ico?: string | null
          odberatel_nazev?: string | null
          opravuje_id?: string | null
          paid_at?: string | null
          paid_by?: string | null
          pdf_path?: string | null
          pdf_sha256?: string | null
          rounding_amount?: number
          status?: Database["public"]["Enums"]["invoice_status"]
          storno_duvod?: string | null
          subject_id: string
          subtotal?: number
          total?: number
          total_rounded?: number
          updated_at?: string
          updated_by?: string | null
          variabilni_symbol?: string | null
          vat_mode?: Database["public"]["Enums"]["vat_mode"]
        }
        Update: {
          cislo?: string | null
          created_at?: string
          created_by?: string | null
          datum_splatnosti?: string | null
          datum_uhrady?: string | null
          datum_vystaveni?: string | null
          dodavatel_adresa?: string | null
          dodavatel_dic?: string | null
          dodavatel_iban?: string | null
          dodavatel_ico?: string | null
          dodavatel_nazev?: string | null
          dodavatel_rejstrik?: string | null
          dodavatel_ucet?: string | null
          dodavatel_zprava?: string | null
          event_id?: string | null
          id?: string
          issued_at?: string | null
          issued_by?: string | null
          kind?: Database["public"]["Enums"]["invoice_kind"]
          obdobi_do?: string
          obdobi_od?: string
          odberatel_adresa?: string | null
          odberatel_dic?: string | null
          odberatel_ico?: string | null
          odberatel_nazev?: string | null
          opravuje_id?: string | null
          paid_at?: string | null
          paid_by?: string | null
          pdf_path?: string | null
          pdf_sha256?: string | null
          rounding_amount?: number
          status?: Database["public"]["Enums"]["invoice_status"]
          storno_duvod?: string | null
          subject_id?: string
          subtotal?: number
          total?: number
          total_rounded?: number
          updated_at?: string
          updated_by?: string | null
          variabilni_symbol?: string | null
          vat_mode?: Database["public"]["Enums"]["vat_mode"]
        }
        Relationships: [
          {
            foreignKeyName: "invoices_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_issued_by_fkey"
            columns: ["issued_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_issued_by_fkey"
            columns: ["issued_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_issued_by_fkey"
            columns: ["issued_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_opravuje_id_fkey"
            columns: ["opravuje_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_opravuje_id_fkey"
            columns: ["opravuje_id"]
            isOneToOne: false
            referencedRelation: "invoices_list"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_paid_by_fkey"
            columns: ["paid_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_paid_by_fkey"
            columns: ["paid_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_paid_by_fkey"
            columns: ["paid_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "invoices_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      migrace_log: {
        Row: {
          applied_at: string
          applied_by: string
          sha256: string | null
          version: string
        }
        Insert: {
          applied_at?: string
          applied_by?: string
          sha256?: string | null
          version: string
        }
        Update: {
          applied_at?: string
          applied_by?: string
          sha256?: string | null
          version?: string
        }
        Relationships: []
      }
      notifications: {
        Row: {
          body: string | null
          created_at: string
          created_by: string | null
          id: string
          link: string | null
          read_at: string | null
          reservation_id: string | null
          subject_id: string | null
          title: string
          type: string
          user_id: string
        }
        Insert: {
          body?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          link?: string | null
          read_at?: string | null
          reservation_id?: string | null
          subject_id?: string | null
          title: string
          type: string
          user_id: string
        }
        Update: {
          body?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          link?: string | null
          read_at?: string | null
          reservation_id?: string | null
          subject_id?: string | null
          title?: string
          type?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "notifications_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "notifications_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "notifications_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: false
            referencedRelation: "reservations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: false
            referencedRelation: "reservations_billing"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: false
            referencedRelation: "reservations_calendar"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "notifications_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "notifications_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      payouts: {
        Row: {
          amount: number
          created_at: string | null
          created_by: string | null
          id: string
          notes: string | null
          paid_at: string | null
          user_id: string
        }
        Insert: {
          amount: number
          created_at?: string | null
          created_by?: string | null
          id?: string
          notes?: string | null
          paid_at?: string | null
          user_id: string
        }
        Update: {
          amount?: number
          created_at?: string | null
          created_by?: string | null
          id?: string
          notes?: string | null
          paid_at?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payouts_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "payouts_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "payouts_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "payouts_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "payouts_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "payouts_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      profiles: {
        Row: {
          bank_account: string | null
          created_at: string
          full_name: string | null
          id: string
          phone: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          bank_account?: string | null
          created_at?: string
          full_name?: string | null
          id?: string
          phone?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          bank_account?: string | null
          created_at?: string
          full_name?: string | null
          id?: string
          phone?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      reservations: {
        Row: {
          amount: number | null
          approved_at: string | null
          approved_by: string | null
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          corrected_amount: number | null
          corrected_hours: number | null
          correction_reason: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          end_at: string
          event_id: string | null
          hours: number | null
          id: string
          invoice_id: string | null
          invoiced_at: string | null
          note: string | null
          rate_per_hour: number | null
          series_id: string | null
          sheet_id: string
          start_at: string
          status: Database["public"]["Enums"]["reservation_status"]
          subject_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount?: number | null
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          corrected_amount?: number | null
          corrected_hours?: number | null
          correction_reason?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          end_at: string
          event_id?: string | null
          hours?: number | null
          id?: string
          invoice_id?: string | null
          invoiced_at?: string | null
          note?: string | null
          rate_per_hour?: number | null
          series_id?: string | null
          sheet_id: string
          start_at: string
          status?: Database["public"]["Enums"]["reservation_status"]
          subject_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount?: number | null
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          corrected_amount?: number | null
          corrected_hours?: number | null
          correction_reason?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          end_at?: string
          event_id?: string | null
          hours?: number | null
          id?: string
          invoice_id?: string | null
          invoiced_at?: string | null
          note?: string | null
          rate_per_hour?: number | null
          series_id?: string | null
          sheet_id?: string
          start_at?: string
          status?: Database["public"]["Enums"]["reservation_status"]
          subject_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "reservations_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_list"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_sheet_id_fkey"
            columns: ["sheet_id"]
            isOneToOne: false
            referencedRelation: "sheets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      settings: {
        Row: {
          club_default_rate: number | null
          commercial_default_rate: number | null
          email_notifications_enabled: boolean
          id: string
          opening_hours: Json
          singleton: boolean
          tournament_rate: number | null
          training_rate: number | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          club_default_rate?: number | null
          commercial_default_rate?: number | null
          email_notifications_enabled?: boolean
          id?: string
          opening_hours: Json
          singleton?: boolean
          tournament_rate?: number | null
          training_rate?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          club_default_rate?: number | null
          commercial_default_rate?: number | null
          email_notifications_enabled?: boolean
          id?: string
          opening_hours?: Json
          singleton?: boolean
          tournament_rate?: number | null
          training_rate?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      sheets: {
        Row: {
          active: boolean
          created_at: string
          id: string
          name: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          name: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          name?: string
        }
        Relationships: []
      }
      shift_applications: {
        Row: {
          created_at: string
          id: string
          shift_id: string
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          shift_id: string
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          shift_id?: string
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shift_applications_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      shifts: {
        Row: {
          cancelled_at: string | null
          cancelled_by: string | null
          claimed_at: string | null
          claimed_by: string | null
          completed_at: string | null
          created_at: string
          event_id: string
          hourly_rate: number | null
          hours_worked: number | null
          id: string
          notes: string | null
          payout_id: string | null
          required_role: Database["public"]["Enums"]["app_role"] | null
          status: Database["public"]["Enums"]["shift_status"]
          updated_at: string
        }
        Insert: {
          cancelled_at?: string | null
          cancelled_by?: string | null
          claimed_at?: string | null
          claimed_by?: string | null
          completed_at?: string | null
          created_at?: string
          event_id: string
          hourly_rate?: number | null
          hours_worked?: number | null
          id?: string
          notes?: string | null
          payout_id?: string | null
          required_role?: Database["public"]["Enums"]["app_role"] | null
          status?: Database["public"]["Enums"]["shift_status"]
          updated_at?: string
        }
        Update: {
          cancelled_at?: string | null
          cancelled_by?: string | null
          claimed_at?: string | null
          claimed_by?: string | null
          completed_at?: string | null
          created_at?: string
          event_id?: string
          hourly_rate?: number | null
          hours_worked?: number | null
          id?: string
          notes?: string | null
          payout_id?: string | null
          required_role?: Database["public"]["Enums"]["app_role"] | null
          status?: Database["public"]["Enums"]["shift_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "shifts_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "shifts_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "shifts_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "shifts_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_payout_id_fkey"
            columns: ["payout_id"]
            isOneToOne: false
            referencedRelation: "payouts"
            referencedColumns: ["id"]
          },
        ]
      }
      subject_reps: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          level: Database["public"]["Enums"]["subject_rep_level"]
          subject_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          level?: Database["public"]["Enums"]["subject_rep_level"]
          subject_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          level?: Database["public"]["Enums"]["subject_rep_level"]
          subject_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "subject_reps_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_reps_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_reps_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_reps_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_reps_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_reps_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_reps_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_reps_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_reps_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      subject_requests: {
        Row: {
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_reason: string | null
          id: string
          poznamka: string | null
          status: Database["public"]["Enums"]["subject_request_status"]
          subject_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_reason?: string | null
          id?: string
          poznamka?: string | null
          status?: Database["public"]["Enums"]["subject_request_status"]
          subject_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_reason?: string | null
          id?: string
          poznamka?: string | null
          status?: Database["public"]["Enums"]["subject_request_status"]
          subject_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "subject_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_requests_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_requests_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_requests_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      subjects: {
        Row: {
          address: string | null
          created_at: string
          created_by: string | null
          default_rate: number | null
          deleted_at: string | null
          dic: string | null
          ico: string | null
          id: string
          name: string
          type: Database["public"]["Enums"]["subject_type"]
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          address?: string | null
          created_at?: string
          created_by?: string | null
          default_rate?: number | null
          deleted_at?: string | null
          dic?: string | null
          ico?: string | null
          id?: string
          name: string
          type: Database["public"]["Enums"]["subject_type"]
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          address?: string | null
          created_at?: string
          created_by?: string | null
          default_rate?: number | null
          deleted_at?: string | null
          dic?: string | null
          ico?: string | null
          id?: string
          name?: string
          type?: Database["public"]["Enums"]["subject_type"]
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "subjects_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subjects_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subjects_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subjects_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subjects_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subjects_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      user_roles: {
        Row: {
          created_at: string
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      clubs_public: {
        Row: {
          id: string | null
          name: string | null
        }
        Insert: {
          id?: string | null
          name?: string | null
        }
        Update: {
          id?: string | null
          name?: string | null
        }
        Relationships: []
      }
      invoices_list: {
        Row: {
          cislo: string | null
          created_at: string | null
          datum_splatnosti: string | null
          datum_uhrady: string | null
          datum_vystaveni: string | null
          id: string | null
          issued_at: string | null
          kind: Database["public"]["Enums"]["invoice_kind"] | null
          obdobi_do: string | null
          obdobi_od: string | null
          odberatel: string | null
          opravuje_cislo: string | null
          opravuje_id: string | null
          pdf_path: string | null
          po_splatnosti: boolean | null
          polozek: number | null
          status: Database["public"]["Enums"]["invoice_status"] | null
          storno_duvod: string | null
          stornovan_dokladem: string | null
          subject_id: string | null
          subtotal: number | null
          total: number | null
          total_rounded: number | null
          variabilni_symbol: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_opravuje_id_fkey"
            columns: ["opravuje_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_opravuje_id_fkey"
            columns: ["opravuje_id"]
            isOneToOne: false
            referencedRelation: "invoices_list"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles_public: {
        Row: {
          bank_account: string | null
          created_at: string | null
          full_name: string | null
          id: string | null
          phone: string | null
          updated_at: string | null
          user_id: string | null
        }
        Insert: {
          bank_account?: never
          created_at?: string | null
          full_name?: string | null
          id?: string | null
          phone?: never
          updated_at?: string | null
          user_id?: string | null
        }
        Update: {
          bank_account?: never
          created_at?: string | null
          full_name?: string | null
          id?: string | null
          phone?: never
          updated_at?: string | null
          user_id?: string | null
        }
        Relationships: []
      }
      profiles_self: {
        Row: {
          bank_account: string | null
          created_at: string | null
          full_name: string | null
          id: string | null
          phone: string | null
          smim_videt_udaje: boolean | null
          updated_at: string | null
          user_id: string | null
        }
        Insert: {
          bank_account?: never
          created_at?: string | null
          full_name?: string | null
          id?: string | null
          phone?: never
          smim_videt_udaje?: never
          updated_at?: string | null
          user_id?: string | null
        }
        Update: {
          bank_account?: never
          created_at?: string | null
          full_name?: string | null
          id?: string | null
          phone?: never
          smim_videt_udaje?: never
          updated_at?: string | null
          user_id?: string | null
        }
        Relationships: []
      }
      reservations_billing: {
        Row: {
          amount: number | null
          corrected_amount: number | null
          corrected_hours: number | null
          correction_reason: string | null
          created_by: string | null
          created_by_name: string | null
          end_at: string | null
          event_title: string | null
          event_type: Database["public"]["Enums"]["event_type"] | null
          hours: number | null
          id: string | null
          note: string | null
          rate_per_hour: number | null
          sheet_id: string | null
          sheet_name: string | null
          start_at: string | null
          subject_id: string | null
          subject_name: string | null
          subject_type: Database["public"]["Enums"]["subject_type"] | null
        }
        Relationships: [
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_sheet_id_fkey"
            columns: ["sheet_id"]
            isOneToOne: false
            referencedRelation: "sheets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
        ]
      }
      reservations_calendar: {
        Row: {
          amount: number | null
          approved_at: string | null
          can_approve: boolean | null
          can_manage: boolean | null
          can_see_amount: boolean | null
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          cancelled_by_name: string | null
          corrected_amount: number | null
          corrected_hours: number | null
          created_at: string | null
          created_by: string | null
          created_by_name: string | null
          end_at: string | null
          event_id: string | null
          event_title: string | null
          event_type: Database["public"]["Enums"]["event_type"] | null
          hours: number | null
          id: string | null
          note: string | null
          rate_per_hour: number | null
          series_id: string | null
          sheet_id: string | null
          start_at: string | null
          status: Database["public"]["Enums"]["reservation_status"] | null
          subject_id: string | null
          subject_name: string | null
          subject_type: Database["public"]["Enums"]["subject_type"] | null
        }
        Relationships: [
          {
            foreignKeyName: "reservations_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_sheet_id_fkey"
            columns: ["sheet_id"]
            isOneToOne: false
            referencedRelation: "sheets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
        ]
      }
      settings_public: {
        Row: {
          can_see_rates: boolean | null
          club_default_rate: number | null
          commercial_default_rate: number | null
          email_notifications_enabled: boolean | null
          id: string | null
          opening_hours: Json | null
          singleton: boolean | null
          tournament_rate: number | null
          training_rate: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          can_see_rates?: never
          club_default_rate?: never
          commercial_default_rate?: never
          email_notifications_enabled?: boolean | null
          id?: string | null
          opening_hours?: Json | null
          singleton?: boolean | null
          tournament_rate?: never
          training_rate?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          can_see_rates?: never
          club_default_rate?: never
          commercial_default_rate?: never
          email_notifications_enabled?: boolean | null
          id?: string | null
          opening_hours?: Json | null
          singleton?: boolean | null
          tournament_rate?: never
          training_rate?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "settings_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      subject_requests_list: {
        Row: {
          created_at: string | null
          decided_at: string | null
          decision_reason: string | null
          id: string | null
          klub: string | null
          poznamka: string | null
          status: Database["public"]["Enums"]["subject_request_status"] | null
          subject_id: string | null
          uroven: Database["public"]["Enums"]["subject_rep_level"] | null
          user_id: string | null
          zadatel: string | null
        }
        Relationships: [
          {
            foreignKeyName: "subject_requests_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "clubs_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_requests_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_requests_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_public"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "subject_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles_self"
            referencedColumns: ["user_id"]
          },
        ]
      }
      subjects_rates: {
        Row: {
          default_rate: number | null
          id: string | null
        }
        Insert: {
          default_rate?: number | null
          id?: string | null
        }
        Update: {
          default_rate?: number | null
          id?: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      approve_reservation: { Args: { p_reservation_id: string }; Returns: Json }
      approve_subject_request: {
        Args: {
          _level?: Database["public"]["Enums"]["subject_rep_level"]
          _request_id: string
        }
        Returns: Json
      }
      billing_health: {
        Args: never
        Returns: {
          opravne_nesedi: number
          polozky_mimo_obdobi: number
          posledni_vystaveni: string
          radky_bez_rezervace: number
          rozesle_castky: number
          rozesle_soucty: number
          spatna_cisla: number
          stare_koncepty: number
          vyfakturovane_zrusene: number
          zamek_bez_radku: number
        }[]
      }
      billing_reconcile: {
        Args: { _do: string; _od: string }
        Returns: {
          dluzi: number
          fakturovano: number
          k_fakturaci: number
          neschvalene: number
          rezervaci: number
          rozdil: number
          subject_id: string
          subjekt: string
          v_konceptu: number
          ve_stornu: number
        }[]
      }
      booking_priority: {
        Args: { _type: Database["public"]["Enums"]["event_type"] }
        Returns: number
      }
      can_manage_reservation: {
        Args: { _reservation: string }
        Returns: boolean
      }
      cancel_booking: {
        Args: { p_reason?: string; p_reservation_id: string; p_scope?: string }
        Returns: Json
      }
      check_booking_conflicts: {
        Args: {
          p_end: string
          p_ignore_event?: string
          p_ignore_reservation?: string
          p_kind?: string
          p_sheet_ids: string[]
          p_start: string
        }
        Returns: {
          can_override: boolean
          end_at: string
          event_title: string
          event_type: Database["public"]["Enums"]["event_type"]
          reservation_id: string
          sheet_id: string
          sheet_name: string
          start_at: string
          subject_name: string
        }[]
      }
      create_booking: {
        Args: {
          p_end: string
          p_kind: string
          p_note?: string
          p_override?: boolean
          p_rate?: number
          p_role_reqs?: Json
          p_series_id?: string
          p_sheet_ids: string[]
          p_start: string
          p_subject_id?: string
          p_title: string
        }
        Returns: Json
      }
      create_booking_series: {
        Args: {
          p_end: string
          p_kind: string
          p_note?: string
          p_rate?: number
          p_role_reqs?: Json
          p_sheet_ids: string[]
          p_start: string
          p_subject_id?: string
          p_title: string
          p_until: string
          p_weekdays: number[]
        }
        Returns: Json
      }
      create_invoice_draft_club: {
        Args: { _obdobi_do: string; _obdobi_od: string; _subject_id: string }
        Returns: string
      }
      create_invoice_draft_commercial: {
        Args: { _event_id: string }
        Returns: string
      }
      delete_invoice_draft: { Args: { _invoice_id: string }; Returns: number }
      fakturovatelne_rezervace: {
        Args: { _do: string; _od: string; _subject_id: string }
        Returns: {
          approved_at: string
          castka: number
          end_at: string
          event_title: string
          hodiny: number
          id: string
          invoice_id: string
          sazba: number
          sheet_name: string
          start_at: string
        }[]
      }
      find_subject_by_ico: {
        Args: { p_ico: string }
        Returns: {
          address: string
          dic: string
          ico: string
          id: string
          name: string
          type: Database["public"]["Enums"]["subject_type"]
        }[]
      }
      get_user_role: {
        Args: { _user_id: string }
        Returns: Database["public"]["Enums"]["app_role"]
      }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      iban_je_platny: { Args: { _iban: string }; Returns: boolean }
      is_subject_member: { Args: { _subject: string }; Returns: boolean }
      is_subject_rep: { Args: { _subject: string }; Returns: boolean }
      issue_invoice: { Args: { _invoice_id: string }; Returns: Json }
      mark_invoice_paid: {
        Args: { _datum?: string; _invoice_id: string }
        Returns: Json
      }
      move_booking: {
        Args: {
          p_end: string
          p_reservation_id: string
          p_sheet_id?: string
          p_start: string
        }
        Returns: Json
      }
      nevyfakturovane_akce: {
        Args: { _obdobi_do: string; _obdobi_od: string; _subject_id: string }
        Returns: {
          castka: number
          den: string
          event_id: string
          nazev: string
          rezervaci: number
        }[]
      }
      next_invoice_number: {
        Args: { _rada: string; _rok: number }
        Returns: string
      }
      notify_user: {
        Args: {
          _body: string
          _link?: string
          _reservation_id?: string
          _subject_id?: string
          _title: string
          _type: string
          _user: string
        }
        Returns: string
      }
      obdobi_hranice: {
        Args: { _do: string; _od: string }
        Returns: {
          konec: string
          zacatek: string
        }[]
      }
      reject_subject_request: {
        Args: { _duvod?: string; _request_id: string }
        Returns: undefined
      }
      request_subject_membership: {
        Args: { _poznamka?: string; _subject_id: string }
        Returns: string
      }
      reservation_priority: {
        Args: {
          _event_type: Database["public"]["Enums"]["event_type"]
          _subject_type: Database["public"]["Enums"]["subject_type"]
        }
        Returns: number
      }
      set_invoice_counter: {
        Args: { _hodnota: number; _rada: string; _rok: number }
        Returns: number
      }
      storno_invoice: {
        Args: { _duvod?: string; _invoice_id: string }
        Returns: Json
      }
      unmark_invoice_paid: { Args: { _invoice_id: string }; Returns: undefined }
      update_booking: {
        Args: {
          p_note?: string
          p_rate?: number
          p_reservation_id: string
          p_title?: string
        }
        Returns: undefined
      }
    }
    Enums: {
      app_role:
        | "admin"
        | "trainer"
        | "part_time_staff"
        | "pro_player"
        | "hobby_player"
        | "instructor"
        | "bar_staff"
        | "manager"
      event_type:
        | "commercial"
        | "training"
        | "maintenance"
        | "recruitment"
        | "tournament"
      invoice_kind: "klub" | "komercni"
      invoice_status: "koncept" | "vystaveno" | "zaplaceno" | "stornovano"
      reservation_status: "confirmed" | "cancelled"
      shift_status: "open" | "pending" | "claimed" | "completed" | "cancelled"
      subject_rep_level: "rep" | "member"
      subject_request_status: "ceka" | "schvalena" | "zamitnuta"
      subject_type: "club" | "commercial"
      vat_mode: "neplatce" | "identifikovana_osoba" | "platce"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      app_role: [
        "admin",
        "trainer",
        "part_time_staff",
        "pro_player",
        "hobby_player",
        "instructor",
        "bar_staff",
        "manager",
      ],
      event_type: [
        "commercial",
        "training",
        "maintenance",
        "recruitment",
        "tournament",
      ],
      invoice_kind: ["klub", "komercni"],
      invoice_status: ["koncept", "vystaveno", "zaplaceno", "stornovano"],
      reservation_status: ["confirmed", "cancelled"],
      shift_status: ["open", "pending", "claimed", "completed", "cancelled"],
      subject_rep_level: ["rep", "member"],
      subject_request_status: ["ceka", "schvalena", "zamitnuta"],
      subject_type: ["club", "commercial"],
      vat_mode: ["neplatce", "identifikovana_osoba", "platce"],
    },
  },
} as const

