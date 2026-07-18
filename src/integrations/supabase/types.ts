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
          note: string | null
          rate_per_hour: number | null
          sheet_id: string
          start_at: string
          status: Database["public"]["Enums"]["reservation_status"]
          subject_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount?: number | null
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
          note?: string | null
          rate_per_hour?: number | null
          sheet_id: string
          start_at: string
          status?: Database["public"]["Enums"]["reservation_status"]
          subject_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount?: number | null
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
          note?: string | null
          rate_per_hour?: number | null
          sheet_id?: string
          start_at?: string
          status?: Database["public"]["Enums"]["reservation_status"]
          subject_id?: string | null
          updated_at?: string
          updated_by?: string | null
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
            referencedRelation: "subjects"
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
        ]
      }
      settings: {
        Row: {
          club_default_rate: number | null
          commercial_default_rate: number | null
          id: string
          opening_hours: Json
          singleton: boolean
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          club_default_rate?: number | null
          commercial_default_rate?: number | null
          id?: string
          opening_hours: Json
          singleton?: boolean
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          club_default_rate?: number | null
          commercial_default_rate?: number | null
          id?: string
          opening_hours?: Json
          singleton?: boolean
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
            foreignKeyName: "subject_reps_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
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
          phone?: string | null
          updated_at?: string | null
          user_id?: string | null
        }
        Update: {
          bank_account?: never
          created_at?: string | null
          full_name?: string | null
          id?: string | null
          phone?: string | null
          updated_at?: string | null
          user_id?: string | null
        }
        Relationships: []
      }
      reservations_calendar: {
        Row: {
          end_at: string | null
          sheet_id: string | null
          start_at: string | null
          status: Database["public"]["Enums"]["reservation_status"] | null
        }
        Insert: {
          end_at?: string | null
          sheet_id?: string | null
          start_at?: string | null
          status?: Database["public"]["Enums"]["reservation_status"] | null
        }
        Update: {
          end_at?: string | null
          sheet_id?: string | null
          start_at?: string | null
          status?: Database["public"]["Enums"]["reservation_status"] | null
        }
        Relationships: [
          {
            foreignKeyName: "reservations_sheet_id_fkey"
            columns: ["sheet_id"]
            isOneToOne: false
            referencedRelation: "sheets"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
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
      is_subject_member: { Args: { _subject: string }; Returns: boolean }
      is_subject_rep: { Args: { _subject: string }; Returns: boolean }
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
      event_type: "commercial" | "training" | "maintenance" | "recruitment"
      reservation_status: "confirmed" | "cancelled"
      shift_status: "open" | "pending" | "claimed" | "completed" | "cancelled"
      subject_rep_level: "rep" | "member"
      subject_type: "club" | "commercial"
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
      event_type: ["commercial", "training", "maintenance", "recruitment"],
      reservation_status: ["confirmed", "cancelled"],
      shift_status: ["open", "pending", "claimed", "completed", "cancelled"],
      subject_rep_level: ["rep", "member"],
      subject_type: ["club", "commercial"],
    },
  },
} as const

