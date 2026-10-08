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
      accounts: {
        Row: {
          account_code: string
          bank_code: string
          created_at: string
          credit_limit: number | null
          currency: string
          cycle_close_day: number | null
          kind: string
          nickname: string | null
          product_name: string | null
          profile_code: string
          status: string
          updated_at: string
        }
        Insert: {
          account_code?: string
          bank_code: string
          created_at?: string
          credit_limit?: number | null
          currency?: string
          cycle_close_day?: number | null
          kind?: string
          nickname?: string | null
          product_name?: string | null
          profile_code: string
          status?: string
          updated_at?: string
        }
        Update: {
          account_code?: string
          bank_code?: string
          created_at?: string
          credit_limit?: number | null
          currency?: string
          cycle_close_day?: number | null
          kind?: string
          nickname?: string | null
          product_name?: string | null
          profile_code?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "accounts_bank_code_fkey"
            columns: ["bank_code"]
            isOneToOne: false
            referencedRelation: "banks"
            referencedColumns: ["bank_code"]
          },
          {
            foreignKeyName: "accounts_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      audit_events: {
        Row: {
          action: string
          actor: string | null
          at: string
          entity: string
          entity_code: string | null
          event_code: string
          payload: Json
          profile_code: string | null
        }
        Insert: {
          action: string
          actor?: string | null
          at?: string
          entity: string
          entity_code?: string | null
          event_code?: string
          payload?: Json
          profile_code?: string | null
        }
        Update: {
          action?: string
          actor?: string | null
          at?: string
          entity?: string
          entity_code?: string | null
          event_code?: string
          payload?: Json
          profile_code?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_events_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      banks: {
        Row: {
          bank_code: string
          created_at: string
          name: string
          sms_senders: string[]
        }
        Insert: {
          bank_code: string
          created_at?: string
          name: string
          sms_senders?: string[]
        }
        Update: {
          bank_code?: string
          created_at?: string
          name?: string
          sms_senders?: string[]
        }
        Relationships: []
      }
      budgets: {
        Row: {
          amount_aed: number
          budget_code: string
          category_code: string | null
          created_at: string
          effective_from: string
          effective_to: string | null
          profile_code: string
          updated_at: string
        }
        Insert: {
          amount_aed: number
          budget_code?: string
          category_code?: string | null
          created_at?: string
          effective_from: string
          effective_to?: string | null
          profile_code: string
          updated_at?: string
        }
        Update: {
          amount_aed?: number
          budget_code?: string
          category_code?: string | null
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          profile_code?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "budgets_profile_code_category_code_fkey"
            columns: ["profile_code", "category_code"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["profile_code", "category_code"]
          },
          {
            foreignKeyName: "budgets_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      cards: {
        Row: {
          account_code: string
          bank_code: string
          card_code: string
          created_at: string
          holder_name: string | null
          is_supplementary: boolean
          last4: string
          profile_code: string
          status: string
          updated_at: string
        }
        Insert: {
          account_code: string
          bank_code: string
          card_code?: string
          created_at?: string
          holder_name?: string | null
          is_supplementary?: boolean
          last4: string
          profile_code: string
          status?: string
          updated_at?: string
        }
        Update: {
          account_code?: string
          bank_code?: string
          card_code?: string
          created_at?: string
          holder_name?: string | null
          is_supplementary?: boolean
          last4?: string
          profile_code?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "cards_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "cards_bank_code_fkey"
            columns: ["bank_code"]
            isOneToOne: false
            referencedRelation: "banks"
            referencedColumns: ["bank_code"]
          },
          {
            foreignKeyName: "cards_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      categories: {
        Row: {
          archived_at: string | null
          category_code: string
          color_token: string | null
          created_at: string
          icon: string | null
          kind: string
          name: string
          parent_code: string | null
          profile_code: string
          sort_order: number
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          category_code?: string
          color_token?: string | null
          created_at?: string
          icon?: string | null
          kind?: string
          name: string
          parent_code?: string | null
          profile_code: string
          sort_order?: number
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          category_code?: string
          color_token?: string | null
          created_at?: string
          icon?: string | null
          kind?: string
          name?: string
          parent_code?: string | null
          profile_code?: string
          sort_order?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "categories_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "categories_profile_code_parent_code_fkey"
            columns: ["profile_code", "parent_code"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["profile_code", "category_code"]
          },
        ]
      }
      category_rules: {
        Row: {
          active: boolean
          category_code: string
          conditions: Json
          created_at: string
          match_type: string
          name: string | null
          pattern: string
          pattern_upper: string | null
          priority: number
          profile_code: string
          rule_code: string
          source: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          category_code: string
          conditions?: Json
          created_at?: string
          match_type: string
          name?: string | null
          pattern: string
          pattern_upper?: string | null
          priority?: number
          profile_code: string
          rule_code?: string
          source?: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          category_code?: string
          conditions?: Json
          created_at?: string
          match_type?: string
          name?: string | null
          pattern?: string
          pattern_upper?: string | null
          priority?: number
          profile_code?: string
          rule_code?: string
          source?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "category_rules_profile_code_category_code_fkey"
            columns: ["profile_code", "category_code"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["profile_code", "category_code"]
          },
          {
            foreignKeyName: "category_rules_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      documents: {
        Row: {
          bank_code: string | null
          created_at: string
          doc_code: string
          kind: string | null
          original_filename: string
          parse_attempts: number
          parse_error: string | null
          parse_error_code: string | null
          parse_status: string
          parse_warnings: Json
          parsed_at: string | null
          parser_version: string | null
          profile_code: string
          sha256: string
          size_bytes: number
          source: string
          source_ref: string | null
          storage_path: string
          updated_at: string
        }
        Insert: {
          bank_code?: string | null
          created_at?: string
          doc_code?: string
          kind?: string | null
          original_filename: string
          parse_attempts?: number
          parse_error?: string | null
          parse_error_code?: string | null
          parse_status?: string
          parse_warnings?: Json
          parsed_at?: string | null
          parser_version?: string | null
          profile_code: string
          sha256: string
          size_bytes: number
          source: string
          source_ref?: string | null
          storage_path: string
          updated_at?: string
        }
        Update: {
          bank_code?: string | null
          created_at?: string
          doc_code?: string
          kind?: string | null
          original_filename?: string
          parse_attempts?: number
          parse_error?: string | null
          parse_error_code?: string | null
          parse_status?: string
          parse_warnings?: Json
          parsed_at?: string | null
          parser_version?: string | null
          profile_code?: string
          sha256?: string
          size_bytes?: number
          source?: string
          source_ref?: string | null
          storage_path?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "documents_bank_code_fkey"
            columns: ["bank_code"]
            isOneToOne: false
            referencedRelation: "banks"
            referencedColumns: ["bank_code"]
          },
          {
            foreignKeyName: "documents_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      email_events: {
        Row: {
          attachment_filename: string | null
          attachment_sha256: string | null
          created_at: string
          detail: string | null
          doc_code: string | null
          event_code: string
          profile_code: string
          provider_attachment_id: string
          provider_message_id: string
          route_code: string | null
          status: string
        }
        Insert: {
          attachment_filename?: string | null
          attachment_sha256?: string | null
          created_at?: string
          detail?: string | null
          doc_code?: string | null
          event_code?: string
          profile_code: string
          provider_attachment_id: string
          provider_message_id: string
          route_code?: string | null
          status: string
        }
        Update: {
          attachment_filename?: string | null
          attachment_sha256?: string | null
          created_at?: string
          detail?: string | null
          doc_code?: string | null
          event_code?: string
          profile_code?: string
          provider_attachment_id?: string
          provider_message_id?: string
          route_code?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "email_events_doc_fkey"
            columns: ["profile_code", "doc_code"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["profile_code", "doc_code"]
          },
          {
            foreignKeyName: "email_events_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "email_events_route_fkey"
            columns: ["profile_code", "route_code"]
            isOneToOne: false
            referencedRelation: "email_routes"
            referencedColumns: ["profile_code", "route_code"]
          },
        ]
      }
      email_mailboxes: {
        Row: {
          created_at: string
          enabled: boolean
          last_synced_at: string | null
          mailbox_code: string
          mailbox_email: string
          profile_code: string
          provider: string
          sync_state: Json
          updated_at: string
          watch_expires_at: string | null
        }
        Insert: {
          created_at?: string
          enabled?: boolean
          last_synced_at?: string | null
          mailbox_code?: string
          mailbox_email: string
          profile_code: string
          provider: string
          sync_state?: Json
          updated_at?: string
          watch_expires_at?: string | null
        }
        Update: {
          created_at?: string
          enabled?: boolean
          last_synced_at?: string | null
          mailbox_code?: string
          mailbox_email?: string
          profile_code?: string
          provider?: string
          sync_state?: Json
          updated_at?: string
          watch_expires_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "email_mailboxes_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      email_routes: {
        Row: {
          attachment_filename_regex: string | null
          bank_code: string
          created_at: string
          enabled: boolean
          gmail_label_filter: string[]
          mailbox_code: string
          profile_code: string
          route_code: string
          sender_allowlist: string[]
          subject_keywords: string[]
          updated_at: string
        }
        Insert: {
          attachment_filename_regex?: string | null
          bank_code: string
          created_at?: string
          enabled?: boolean
          gmail_label_filter?: string[]
          mailbox_code: string
          profile_code: string
          route_code?: string
          sender_allowlist?: string[]
          subject_keywords?: string[]
          updated_at?: string
        }
        Update: {
          attachment_filename_regex?: string | null
          bank_code?: string
          created_at?: string
          enabled?: boolean
          gmail_label_filter?: string[]
          mailbox_code?: string
          profile_code?: string
          route_code?: string
          sender_allowlist?: string[]
          subject_keywords?: string[]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "email_routes_bank_code_fkey"
            columns: ["bank_code"]
            isOneToOne: false
            referencedRelation: "banks"
            referencedColumns: ["bank_code"]
          },
          {
            foreignKeyName: "email_routes_mailbox_fkey"
            columns: ["profile_code", "mailbox_code"]
            isOneToOne: false
            referencedRelation: "email_mailboxes"
            referencedColumns: ["profile_code", "mailbox_code"]
          },
          {
            foreignKeyName: "email_routes_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      fx_rates: {
        Row: {
          aed_per_unit: number
          as_of: string
          currency: string
          source: string
          updated_at: string
        }
        Insert: {
          aed_per_unit: number
          as_of: string
          currency: string
          source: string
          updated_at?: string
        }
        Update: {
          aed_per_unit?: number
          as_of?: string
          currency?: string
          source?: string
          updated_at?: string
        }
        Relationships: []
      }
      insights: {
        Row: {
          body: string
          created_at: string
          data: Json
          dedupe_key: string
          dismissed_at: string | null
          insight_code: string
          kind: string
          profile_code: string
          severity: string
          title: string
          valid_until: string | null
        }
        Insert: {
          body: string
          created_at?: string
          data?: Json
          dedupe_key: string
          dismissed_at?: string | null
          insight_code?: string
          kind: string
          profile_code: string
          severity?: string
          title: string
          valid_until?: string | null
        }
        Update: {
          body?: string
          created_at?: string
          data?: Json
          dedupe_key?: string
          dismissed_at?: string | null
          insight_code?: string
          kind?: string
          profile_code?: string
          severity?: string
          title?: string
          valid_until?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "insights_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      match_reviews: {
        Row: {
          account_code: string | null
          candidates: Json
          created_at: string
          profile_code: string
          reason: string
          resolution: Json | null
          resolved_at: string | null
          resolved_by: string | null
          review_code: string
          status: string
          subject_code: string
          subject_type: string
        }
        Insert: {
          account_code?: string | null
          candidates?: Json
          created_at?: string
          profile_code: string
          reason: string
          resolution?: Json | null
          resolved_at?: string | null
          resolved_by?: string | null
          review_code?: string
          status?: string
          subject_code: string
          subject_type: string
        }
        Update: {
          account_code?: string | null
          candidates?: Json
          created_at?: string
          profile_code?: string
          reason?: string
          resolution?: Json | null
          resolved_at?: string | null
          resolved_by?: string | null
          review_code?: string
          status?: string
          subject_code?: string
          subject_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "match_reviews_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "match_reviews_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      merchant_aliases: {
        Row: {
          alias_key: string
          created_at: string
          merchant_code: string
          source: string
        }
        Insert: {
          alias_key: string
          created_at?: string
          merchant_code: string
          source?: string
        }
        Update: {
          alias_key?: string
          created_at?: string
          merchant_code?: string
          source?: string
        }
        Relationships: [
          {
            foreignKeyName: "merchant_aliases_merchant_code_fkey"
            columns: ["merchant_code"]
            isOneToOne: false
            referencedRelation: "merchants"
            referencedColumns: ["merchant_code"]
          },
        ]
      }
      merchant_profile_category: {
        Row: {
          category_code: string
          category_set_hash: string | null
          confidence: number | null
          created_at: string
          merchant_code: string
          model: string | null
          profile_code: string
          source: string
          updated_at: string
        }
        Insert: {
          category_code: string
          category_set_hash?: string | null
          confidence?: number | null
          created_at?: string
          merchant_code: string
          model?: string | null
          profile_code: string
          source: string
          updated_at?: string
        }
        Update: {
          category_code?: string
          category_set_hash?: string | null
          confidence?: number | null
          created_at?: string
          merchant_code?: string
          model?: string | null
          profile_code?: string
          source?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "merchant_profile_category_merchant_code_fkey"
            columns: ["merchant_code"]
            isOneToOne: false
            referencedRelation: "merchants"
            referencedColumns: ["merchant_code"]
          },
          {
            foreignKeyName: "merchant_profile_category_profile_code_category_code_fkey"
            columns: ["profile_code", "category_code"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["profile_code", "category_code"]
          },
          {
            foreignKeyName: "merchant_profile_category_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      merchants: {
        Row: {
          created_at: string
          display_name: string
          merchant_code: string
          merchant_key: string
          variable_amount: boolean
        }
        Insert: {
          created_at?: string
          display_name: string
          merchant_code?: string
          merchant_key: string
          variable_amount?: boolean
        }
        Update: {
          created_at?: string
          display_name?: string
          merchant_code?: string
          merchant_key?: string
          variable_amount?: boolean
        }
        Relationships: []
      }
      profile_members: {
        Row: {
          created_at: string
          profile_code: string
          role: string
          user_id: string
        }
        Insert: {
          created_at?: string
          profile_code: string
          role?: string
          user_id: string
        }
        Update: {
          created_at?: string
          profile_code?: string
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "profile_members_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      profile_state: {
        Row: {
          profile_code: string
          rules_version: number
          updated_at: string
        }
        Insert: {
          profile_code: string
          rules_version?: number
          updated_at?: string
        }
        Update: {
          profile_code?: string
          rules_version?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "profile_state_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      profiles: {
        Row: {
          base_currency: string
          created_at: string
          key: string
          name: string
          profile_code: string
          timezone: string
          updated_at: string
        }
        Insert: {
          base_currency?: string
          created_at?: string
          key: string
          name: string
          profile_code?: string
          timezone?: string
          updated_at?: string
        }
        Update: {
          base_currency?: string
          created_at?: string
          key?: string
          name?: string
          profile_code?: string
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      recurring_series: {
        Row: {
          amount_cv: number | null
          cadence: string
          created_at: string
          detected_by: string
          expected_amount: number
          first_date: string
          last_amount: number
          last_date: string
          merchant_code: string
          next_expected: string
          occurrences: number
          profile_code: string
          recurring_code: string
          status: string
          updated_at: string
        }
        Insert: {
          amount_cv?: number | null
          cadence: string
          created_at?: string
          detected_by?: string
          expected_amount: number
          first_date: string
          last_amount: number
          last_date: string
          merchant_code: string
          next_expected: string
          occurrences: number
          profile_code: string
          recurring_code?: string
          status?: string
          updated_at?: string
        }
        Update: {
          amount_cv?: number | null
          cadence?: string
          created_at?: string
          detected_by?: string
          expected_amount?: number
          first_date?: string
          last_amount?: number
          last_date?: string
          merchant_code?: string
          next_expected?: string
          occurrences?: number
          profile_code?: string
          recurring_code?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "recurring_series_merchant_code_fkey"
            columns: ["merchant_code"]
            isOneToOne: false
            referencedRelation: "merchants"
            referencedColumns: ["merchant_code"]
          },
          {
            foreignKeyName: "recurring_series_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      service_tokens: {
        Row: {
          created_at: string
          last_used_at: string | null
          name: string
          profile_code: string
          revoked_at: string | null
          scopes: string[]
          token_code: string
          token_hash: string
          token_prefix: string
        }
        Insert: {
          created_at?: string
          last_used_at?: string | null
          name: string
          profile_code: string
          revoked_at?: string | null
          scopes: string[]
          token_code?: string
          token_hash: string
          token_prefix: string
        }
        Update: {
          created_at?: string
          last_used_at?: string | null
          name?: string
          profile_code?: string
          revoked_at?: string | null
          scopes?: string[]
          token_code?: string
          token_hash?: string
          token_prefix?: string
        }
        Relationships: [
          {
            foreignKeyName: "service_tokens_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      sms_messages: {
        Row: {
          account_code: string | null
          amount: number | null
          available_limit: number | null
          bank_code: string | null
          body: string
          body_hash: string
          card_code: string | null
          card_last4: string | null
          client_msg_id: string
          created_at: string
          currency: string | null
          description: string | null
          event_at: string | null
          ignore_reason: string | null
          merchant_raw: string | null
          msg_kind: string | null
          parse_status: string
          parsed_fields: Json
          profile_code: string
          received_at: string
          sender: string
          sms_code: string
          template_code: string | null
          template_version: number | null
          updated_at: string
        }
        Insert: {
          account_code?: string | null
          amount?: number | null
          available_limit?: number | null
          bank_code?: string | null
          body: string
          body_hash: string
          card_code?: string | null
          card_last4?: string | null
          client_msg_id: string
          created_at?: string
          currency?: string | null
          description?: string | null
          event_at?: string | null
          ignore_reason?: string | null
          merchant_raw?: string | null
          msg_kind?: string | null
          parse_status?: string
          parsed_fields?: Json
          profile_code: string
          received_at: string
          sender: string
          sms_code?: string
          template_code?: string | null
          template_version?: number | null
          updated_at?: string
        }
        Update: {
          account_code?: string | null
          amount?: number | null
          available_limit?: number | null
          bank_code?: string | null
          body?: string
          body_hash?: string
          card_code?: string | null
          card_last4?: string | null
          client_msg_id?: string
          created_at?: string
          currency?: string | null
          description?: string | null
          event_at?: string | null
          ignore_reason?: string | null
          merchant_raw?: string | null
          msg_kind?: string | null
          parse_status?: string
          parsed_fields?: Json
          profile_code?: string
          received_at?: string
          sender?: string
          sms_code?: string
          template_code?: string | null
          template_version?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "sms_messages_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "sms_messages_bank_code_fkey"
            columns: ["bank_code"]
            isOneToOne: false
            referencedRelation: "banks"
            referencedColumns: ["bank_code"]
          },
          {
            foreignKeyName: "sms_messages_card_fkey"
            columns: ["profile_code", "card_code"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["profile_code", "card_code"]
          },
          {
            foreignKeyName: "sms_messages_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "sms_messages_template_code_fkey"
            columns: ["template_code"]
            isOneToOne: false
            referencedRelation: "sms_templates"
            referencedColumns: ["template_code"]
          },
        ]
      }
      sms_templates: {
        Row: {
          active: boolean
          bank_code: string
          body_pattern: string
          created_at: string
          date_format: string | null
          examples: Json
          field_groups: Json
          msg_kind: string
          name: string
          priority: number
          sender_pattern: string
          source: string
          template_code: string
          updated_at: string
          version: number
        }
        Insert: {
          active?: boolean
          bank_code: string
          body_pattern: string
          created_at?: string
          date_format?: string | null
          examples?: Json
          field_groups: Json
          msg_kind: string
          name: string
          priority?: number
          sender_pattern?: string
          source?: string
          template_code?: string
          updated_at?: string
          version?: number
        }
        Update: {
          active?: boolean
          bank_code?: string
          body_pattern?: string
          created_at?: string
          date_format?: string | null
          examples?: Json
          field_groups?: Json
          msg_kind?: string
          name?: string
          priority?: number
          sender_pattern?: string
          source?: string
          template_code?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "sms_templates_bank_code_fkey"
            columns: ["bank_code"]
            isOneToOne: false
            referencedRelation: "banks"
            referencedColumns: ["bank_code"]
          },
        ]
      }
      statement_lines: {
        Row: {
          account_code: string
          amount_aed: number | null
          amount_original: number
          card_code: string | null
          card_last4: string | null
          country_code: string | null
          created_at: string
          currency_original: string
          description: string
          description_raw: string
          direction: string
          evidence_type: string
          fx_rate: number | null
          is_current: boolean
          kind: string
          legacy_fingerprint: string | null
          line_code: string
          line_key: string
          line_no: number
          occurrence: number
          posting_date: string | null
          profile_code: string
          raw: Json
          source_doc_codes: string[]
          stmt_code: string
          superseded_at: string | null
          txn_date: string
          txn_time: string | null
        }
        Insert: {
          account_code: string
          amount_aed?: number | null
          amount_original: number
          card_code?: string | null
          card_last4?: string | null
          country_code?: string | null
          created_at?: string
          currency_original: string
          description: string
          description_raw: string
          direction: string
          evidence_type: string
          fx_rate?: number | null
          is_current?: boolean
          kind: string
          legacy_fingerprint?: string | null
          line_code?: string
          line_key: string
          line_no: number
          occurrence?: number
          posting_date?: string | null
          profile_code: string
          raw?: Json
          source_doc_codes?: string[]
          stmt_code: string
          superseded_at?: string | null
          txn_date: string
          txn_time?: string | null
        }
        Update: {
          account_code?: string
          amount_aed?: number | null
          amount_original?: number
          card_code?: string | null
          card_last4?: string | null
          country_code?: string | null
          created_at?: string
          currency_original?: string
          description?: string
          description_raw?: string
          direction?: string
          evidence_type?: string
          fx_rate?: number | null
          is_current?: boolean
          kind?: string
          legacy_fingerprint?: string | null
          line_code?: string
          line_key?: string
          line_no?: number
          occurrence?: number
          posting_date?: string | null
          profile_code?: string
          raw?: Json
          source_doc_codes?: string[]
          stmt_code?: string
          superseded_at?: string | null
          txn_date?: string
          txn_time?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "statement_lines_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "statement_lines_card_fkey"
            columns: ["profile_code", "card_code"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["profile_code", "card_code"]
          },
          {
            foreignKeyName: "statement_lines_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "statement_lines_stmt_fkey"
            columns: ["profile_code", "stmt_code"]
            isOneToOne: false
            referencedRelation: "statements"
            referencedColumns: ["profile_code", "stmt_code"]
          },
        ]
      }
      statement_recon: {
        Row: {
          checks: Json
          computed_at: string
          profile_code: string
          status: string
          stmt_code: string
        }
        Insert: {
          checks: Json
          computed_at?: string
          profile_code: string
          status: string
          stmt_code: string
        }
        Update: {
          checks?: Json
          computed_at?: string
          profile_code?: string
          status?: string
          stmt_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "statement_recon_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "statement_recon_stmt_fkey"
            columns: ["profile_code", "stmt_code"]
            isOneToOne: false
            referencedRelation: "statements"
            referencedColumns: ["profile_code", "stmt_code"]
          },
        ]
      }
      statements: {
        Row: {
          account_code: string
          card_holder: string | null
          card_type: string | null
          closing_balance: number | null
          created_at: string
          credit_limit: number | null
          doc_code: string | null
          due_date: string | null
          kind: string
          metadata: Json
          min_due: number | null
          opening_balance: number | null
          parser_version: string | null
          period_end: string | null
          period_start: string | null
          primary_card_last4: string | null
          profile_code: string
          reference_source: string | null
          statement_date: string
          statement_reference: string | null
          status: string
          stmt_code: string
          superseded_by: string | null
          total_credits: number | null
          total_debits: number | null
          updated_at: string
          warnings: Json
        }
        Insert: {
          account_code: string
          card_holder?: string | null
          card_type?: string | null
          closing_balance?: number | null
          created_at?: string
          credit_limit?: number | null
          doc_code?: string | null
          due_date?: string | null
          kind: string
          metadata?: Json
          min_due?: number | null
          opening_balance?: number | null
          parser_version?: string | null
          period_end?: string | null
          period_start?: string | null
          primary_card_last4?: string | null
          profile_code: string
          reference_source?: string | null
          statement_date: string
          statement_reference?: string | null
          status?: string
          stmt_code?: string
          superseded_by?: string | null
          total_credits?: number | null
          total_debits?: number | null
          updated_at?: string
          warnings?: Json
        }
        Update: {
          account_code?: string
          card_holder?: string | null
          card_type?: string | null
          closing_balance?: number | null
          created_at?: string
          credit_limit?: number | null
          doc_code?: string | null
          due_date?: string | null
          kind?: string
          metadata?: Json
          min_due?: number | null
          opening_balance?: number | null
          parser_version?: string | null
          period_end?: string | null
          period_start?: string | null
          primary_card_last4?: string | null
          profile_code?: string
          reference_source?: string | null
          statement_date?: string
          statement_reference?: string | null
          status?: string
          stmt_code?: string
          superseded_by?: string | null
          total_credits?: number | null
          total_debits?: number | null
          updated_at?: string
          warnings?: Json
        }
        Relationships: [
          {
            foreignKeyName: "statements_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "statements_doc_fkey"
            columns: ["profile_code", "doc_code"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["profile_code", "doc_code"]
          },
          {
            foreignKeyName: "statements_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "statements_superseded_by_fkey"
            columns: ["profile_code", "superseded_by"]
            isOneToOne: false
            referencedRelation: "statements"
            referencedColumns: ["profile_code", "stmt_code"]
          },
        ]
      }
      transaction_evidence: {
        Row: {
          created_at: string
          deactivated_at: string | null
          evidence_code: string
          evidence_type: string
          is_active: boolean
          is_locked: boolean
          line_code: string | null
          method: string
          profile_code: string
          role: string
          score: number | null
          sms_code: string | null
          txn_code: string
        }
        Insert: {
          created_at?: string
          deactivated_at?: string | null
          evidence_code?: string
          evidence_type: string
          is_active?: boolean
          is_locked?: boolean
          line_code?: string | null
          method: string
          profile_code: string
          role?: string
          score?: number | null
          sms_code?: string | null
          txn_code: string
        }
        Update: {
          created_at?: string
          deactivated_at?: string | null
          evidence_code?: string
          evidence_type?: string
          is_active?: boolean
          is_locked?: boolean
          line_code?: string | null
          method?: string
          profile_code?: string
          role?: string
          score?: number | null
          sms_code?: string | null
          txn_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "transaction_evidence_line_fkey"
            columns: ["profile_code", "line_code"]
            isOneToOne: false
            referencedRelation: "statement_lines"
            referencedColumns: ["profile_code", "line_code"]
          },
          {
            foreignKeyName: "transaction_evidence_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "transaction_evidence_sms_fkey"
            columns: ["profile_code", "sms_code"]
            isOneToOne: false
            referencedRelation: "sms_messages"
            referencedColumns: ["profile_code", "sms_code"]
          },
          {
            foreignKeyName: "transaction_evidence_txn_fkey"
            columns: ["profile_code", "txn_code"]
            isOneToOne: false
            referencedRelation: "transactions"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transaction_evidence_txn_fkey"
            columns: ["profile_code", "txn_code"]
            isOneToOne: false
            referencedRelation: "v_spend"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transaction_evidence_txn_fkey"
            columns: ["profile_code", "txn_code"]
            isOneToOne: false
            referencedRelation: "v_transactions"
            referencedColumns: ["profile_code", "txn_code"]
          },
        ]
      }
      transactions: {
        Row: {
          account_code: string
          amount_aed: number | null
          amount_aed_is_estimate: boolean
          amount_original: number
          amount_source: string
          auth_amount: number | null
          card_code: string | null
          created_at: string
          currency_original: string
          description: string
          direction: string
          effective_category_code: string | null
          exclude_from_spend: boolean
          fx_rate: number | null
          kind: string
          manual_at: string | null
          manual_category_code: string | null
          merchant_category_code: string | null
          merchant_category_source: string | null
          merchant_code: string | null
          notes: string | null
          posting_date: string | null
          profile_code: string
          recurring_code: string | null
          related_txn_code: string | null
          rule_category_code: string | null
          rule_code: string | null
          rules_version: number
          status: string
          stmt_code: string | null
          txn_at: string | null
          txn_code: string
          txn_date: string
          updated_at: string
          void_reason: string | null
          voided_at: string | null
        }
        Insert: {
          account_code: string
          amount_aed?: number | null
          amount_aed_is_estimate?: boolean
          amount_original: number
          amount_source: string
          auth_amount?: number | null
          card_code?: string | null
          created_at?: string
          currency_original: string
          description: string
          direction: string
          effective_category_code?: string | null
          exclude_from_spend?: boolean
          fx_rate?: number | null
          kind: string
          manual_at?: string | null
          manual_category_code?: string | null
          merchant_category_code?: string | null
          merchant_category_source?: string | null
          merchant_code?: string | null
          notes?: string | null
          posting_date?: string | null
          profile_code: string
          recurring_code?: string | null
          related_txn_code?: string | null
          rule_category_code?: string | null
          rule_code?: string | null
          rules_version?: number
          status?: string
          stmt_code?: string | null
          txn_at?: string | null
          txn_code?: string
          txn_date: string
          updated_at?: string
          void_reason?: string | null
          voided_at?: string | null
        }
        Update: {
          account_code?: string
          amount_aed?: number | null
          amount_aed_is_estimate?: boolean
          amount_original?: number
          amount_source?: string
          auth_amount?: number | null
          card_code?: string | null
          created_at?: string
          currency_original?: string
          description?: string
          direction?: string
          effective_category_code?: string | null
          exclude_from_spend?: boolean
          fx_rate?: number | null
          kind?: string
          manual_at?: string | null
          manual_category_code?: string | null
          merchant_category_code?: string | null
          merchant_category_source?: string | null
          merchant_code?: string | null
          notes?: string | null
          posting_date?: string | null
          profile_code?: string
          recurring_code?: string | null
          related_txn_code?: string | null
          rule_category_code?: string | null
          rule_code?: string | null
          rules_version?: number
          status?: string
          stmt_code?: string | null
          txn_at?: string | null
          txn_code?: string
          txn_date?: string
          updated_at?: string
          void_reason?: string | null
          voided_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "transactions_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "transactions_card_fkey"
            columns: ["profile_code", "card_code"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["profile_code", "card_code"]
          },
          {
            foreignKeyName: "transactions_merchant_code_fkey"
            columns: ["merchant_code"]
            isOneToOne: false
            referencedRelation: "merchants"
            referencedColumns: ["merchant_code"]
          },
          {
            foreignKeyName: "transactions_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "transactions_profile_code_manual_category_code_fkey"
            columns: ["profile_code", "manual_category_code"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["profile_code", "category_code"]
          },
          {
            foreignKeyName: "transactions_profile_code_merchant_category_code_fkey"
            columns: ["profile_code", "merchant_category_code"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["profile_code", "category_code"]
          },
          {
            foreignKeyName: "transactions_profile_code_rule_category_code_fkey"
            columns: ["profile_code", "rule_category_code"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["profile_code", "category_code"]
          },
          {
            foreignKeyName: "transactions_recurring_fkey"
            columns: ["profile_code", "recurring_code"]
            isOneToOne: false
            referencedRelation: "recurring_series"
            referencedColumns: ["profile_code", "recurring_code"]
          },
          {
            foreignKeyName: "transactions_related_txn_fkey"
            columns: ["profile_code", "related_txn_code"]
            isOneToOne: false
            referencedRelation: "transactions"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transactions_related_txn_fkey"
            columns: ["profile_code", "related_txn_code"]
            isOneToOne: false
            referencedRelation: "v_spend"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transactions_related_txn_fkey"
            columns: ["profile_code", "related_txn_code"]
            isOneToOne: false
            referencedRelation: "v_transactions"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transactions_rule_fkey"
            columns: ["profile_code", "rule_code"]
            isOneToOne: false
            referencedRelation: "category_rules"
            referencedColumns: ["profile_code", "rule_code"]
          },
          {
            foreignKeyName: "transactions_stmt_fkey"
            columns: ["profile_code", "stmt_code"]
            isOneToOne: false
            referencedRelation: "statements"
            referencedColumns: ["profile_code", "stmt_code"]
          },
        ]
      }
    }
    Views: {
      v_spend: {
        Row: {
          account_code: string | null
          amount_aed_is_estimate: boolean | null
          amount_original: number | null
          card_code: string | null
          category_code: string | null
          currency_original: string | null
          description: string | null
          kind: string | null
          merchant_code: string | null
          profile_code: string | null
          spend_aed: number | null
          status: string | null
          txn_at: string | null
          txn_code: string | null
          txn_date: string | null
        }
        Relationships: [
          {
            foreignKeyName: "transactions_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "transactions_card_fkey"
            columns: ["profile_code", "card_code"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["profile_code", "card_code"]
          },
          {
            foreignKeyName: "transactions_merchant_code_fkey"
            columns: ["merchant_code"]
            isOneToOne: false
            referencedRelation: "merchants"
            referencedColumns: ["merchant_code"]
          },
          {
            foreignKeyName: "transactions_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
        ]
      }
      v_transactions: {
        Row: {
          account_code: string | null
          account_nickname: string | null
          amount_aed: number | null
          amount_aed_is_estimate: boolean | null
          amount_original: number | null
          amount_source: string | null
          auth_amount: number | null
          bank_code: string | null
          card_code: string | null
          card_last4: string | null
          category_code: string | null
          category_color: string | null
          category_kind: string | null
          category_name: string | null
          category_source: string | null
          created_at: string | null
          currency_original: string | null
          description: string | null
          direction: string | null
          exclude_from_spend: boolean | null
          fx_rate: number | null
          has_sms: boolean | null
          has_statement: boolean | null
          kind: string | null
          merchant_code: string | null
          merchant_name: string | null
          notes: string | null
          posting_date: string | null
          profile_code: string | null
          related_txn_code: string | null
          status: string | null
          stmt_code: string | null
          txn_at: string | null
          txn_code: string | null
          txn_date: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "accounts_bank_code_fkey"
            columns: ["bank_code"]
            isOneToOne: false
            referencedRelation: "banks"
            referencedColumns: ["bank_code"]
          },
          {
            foreignKeyName: "transactions_account_fkey"
            columns: ["profile_code", "account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["profile_code", "account_code"]
          },
          {
            foreignKeyName: "transactions_card_fkey"
            columns: ["profile_code", "card_code"]
            isOneToOne: false
            referencedRelation: "cards"
            referencedColumns: ["profile_code", "card_code"]
          },
          {
            foreignKeyName: "transactions_merchant_code_fkey"
            columns: ["merchant_code"]
            isOneToOne: false
            referencedRelation: "merchants"
            referencedColumns: ["merchant_code"]
          },
          {
            foreignKeyName: "transactions_profile_code_fkey"
            columns: ["profile_code"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["profile_code"]
          },
          {
            foreignKeyName: "transactions_related_txn_fkey"
            columns: ["profile_code", "related_txn_code"]
            isOneToOne: false
            referencedRelation: "transactions"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transactions_related_txn_fkey"
            columns: ["profile_code", "related_txn_code"]
            isOneToOne: false
            referencedRelation: "v_spend"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transactions_related_txn_fkey"
            columns: ["profile_code", "related_txn_code"]
            isOneToOne: false
            referencedRelation: "v_transactions"
            referencedColumns: ["profile_code", "txn_code"]
          },
          {
            foreignKeyName: "transactions_stmt_fkey"
            columns: ["profile_code", "stmt_code"]
            isOneToOne: false
            referencedRelation: "statements"
            referencedColumns: ["profile_code", "stmt_code"]
          },
        ]
      }
    }
    Functions: {
      add_profile_member: {
        Args: { p_email: string; p_profile_code: string; p_role?: string }
        Returns: string
      }
      anomalies: {
        Args: { p_from: string; p_profile_code: string; p_to: string }
        Returns: {
          amount: number
          baseline_mean: number
          baseline_sd: number
          description: string
          reason: string
          txn_code: string
          txn_date: string
        }[]
      }
      apply_llm_suggestions: {
        Args: {
          p_category_set_hash: string
          p_model: string
          p_profile_code: string
          p_suggestions: Json
        }
        Returns: number
      }
      authenticate_service_token: {
        Args: { p_profile_key?: string; p_scope: string; p_token: string }
        Returns: string
      }
      budget_status: {
        Args: { p_month?: string; p_profile_code: string }
        Returns: {
          budget_aed: number
          budget_code: string
          category_code: string
          category_name: string
          color_token: string
          projected_aed: number
          share_used: number
          spent_aed: number
        }[]
      }
      cancel_profile_invite: {
        Args: { p_email: string; p_profile_code: string }
        Returns: undefined
      }
      category_breakdown: {
        Args: { p_from: string; p_profile_code: string; p_to: string }
        Returns: {
          amount: number
          category_code: string
          change: number
          color_token: string
          name: string
          prev_amount: number
          share: number
          txn_count: number
        }[]
      }
      create_profile: {
        Args: { p_key: string; p_name: string }
        Returns: string
      }
      create_service_token: {
        Args: { p_name: string; p_profile_code: string; p_scopes: string[] }
        Returns: Json
      }
      daily_spend: {
        Args: { p_from: string; p_profile_code: string; p_to: string }
        Returns: {
          amount: number
          day: string
          txn_count: number
        }[]
      }
      dubai_date: { Args: { ts: string }; Returns: string }
      fail_document: {
        Args: {
          p_doc_code: string
          p_error: string
          p_error_code: string
          p_permanent: boolean
        }
        Returns: undefined
      }
      filter_meta: { Args: { p_profile_code: string }; Returns: Json }
      fx_spend: {
        Args: { p_from: string; p_profile_code: string; p_to: string }
        Returns: {
          amount_aed: number
          amount_original: number
          currency: string
          estimated_share: number
          implied_rate: number
          txn_count: number
        }[]
      }
      gen_code: { Args: { prefix: string }; Returns: string }
      hour_weekday_pattern: {
        Args: { p_from: string; p_profile_code: string; p_to: string }
        Returns: {
          amount: number
          dow: number
          hour: number
          txn_count: number
        }[]
      }
      ingest_parsed_document: {
        Args: { p_doc_code: string; p_payload: Json }
        Returns: Json
      }
      ingest_sms: {
        Args: { p_messages: Json; p_profile_code: string }
        Returns: Json
      }
      list_profile_members: {
        Args: { p_profile_code: string }
        Returns: {
          created_at: string
          email: string
          pending: boolean
          role: string
          user_id: string
        }[]
      }
      list_profile_secrets: {
        Args: { p_profile_code: string }
        Returns: {
          key: string
          updated_at: string
        }[]
      }
      merchant_key: { Args: { p: string }; Returns: string }
      merchant_leaderboard: {
        Args: {
          p_from: string
          p_limit?: number
          p_profile_code: string
          p_to: string
        }
        Returns: {
          amount: number
          avg_amount: number
          category_code: string
          category_name: string
          last_date: string
          merchant_code: string
          merchant_name: string
          txn_count: number
        }[]
      }
      merchant_search: {
        Args: {
          p_limit?: number
          p_offset?: number
          p_profile_code: string
          p_q: string
        }
        Returns: {
          display_name: string
          last_date: string
          manual_category_code: string
          merchant_code: string
          merchant_key: string
          txn_count: number
        }[]
      }
      ops_health: { Args: never; Returns: Json }
      overview: {
        Args: { p_month?: string; p_profile_code: string }
        Returns: Json
      }
      preview_rule: {
        Args: {
          p_category_code: string
          p_conditions?: Json
          p_match_type: string
          p_pattern: string
          p_priority?: number
          p_profile_code: string
        }
        Returns: Json
      }
      propose_sms_template: {
        Args: { p_sms_code: string; p_template: Json }
        Returns: string
      }
      queue_delete: {
        Args: { p_msg_id: number; p_queue: string }
        Returns: boolean
      }
      queue_read: {
        Args: { p_qty: number; p_queue: string; p_vt: number }
        Returns: {
          message: Json
          msg_id: number
          read_ct: number
        }[]
      }
      queue_send: {
        Args: { p_delay?: number; p_message: Json; p_queue: string }
        Returns: number
      }
      queue_to_dlq: {
        Args: {
          p_message: Json
          p_msg_id: number
          p_queue: string
          p_reason: string
        }
        Returns: undefined
      }
      recurring_list: {
        Args: { p_profile_code: string }
        Returns: {
          annual_cost: number
          cadence: string
          category_name: string
          expected_amount: number
          last_amount: number
          last_date: string
          merchant_code: string
          merchant_name: string
          next_expected: string
          occurrences: number
          price_change: number
          recurring_code: string
          status: string
        }[]
      }
      remove_profile_member: {
        Args: { p_profile_code: string; p_user_id: string }
        Returns: undefined
      }
      requeue_documents: {
        Args: { p_doc_codes?: string[]; p_profile_code: string }
        Returns: number
      }
      resolve_review: {
        Args: { p_action: Json; p_review_code: string }
        Returns: Json
      }
      retry_sms_fallback: {
        Args: { p_review_code: string }
        Returns: undefined
      }
      revoke_service_token: {
        Args: { p_token_code: string }
        Returns: undefined
      }
      set_mailbox_secret: {
        Args: { p_key: string; p_mailbox_code: string; p_value: string }
        Returns: undefined
      }
      set_profile_secret: {
        Args: { p_key: string; p_profile_code: string; p_value: string }
        Returns: undefined
      }
      set_sms_template_active: {
        Args: { p_active: boolean; p_template_code: string }
        Returns: undefined
      }
      set_transaction_category: {
        Args: {
          p_apply_to_merchant?: boolean
          p_category_code: string
          p_txn_code: string
        }
        Returns: undefined
      }
      set_transactions_category: {
        Args: { p_category_code: string; p_txn_codes: string[] }
        Returns: number
      }
      spend_series: {
        Args: {
          p_from: string
          p_grain?: string
          p_group?: string
          p_profile_code: string
          p_to: string
          p_top?: number
        }
        Returns: {
          amount: number
          bucket: string
          color_token: string
          group_key: string
          group_label: string
          txn_count: number
        }[]
      }
      statement_cycles: {
        Args: { p_limit?: number; p_profile_code: string }
        Returns: {
          account_code: string
          bank_code: string
          card_last4: string
          closing_balance: number
          credit_limit: number
          credits: number
          debits: number
          doc_code: string
          due_date: string
          kind: string
          line_count: number
          min_due: number
          period_end: string
          period_start: string
          recon_checks: Json
          recon_status: string
          statement_date: string
          stmt_code: string
          utilisation: number
        }[]
      }
      upsert_fx_rates: {
        Args: { p_as_of: string; p_rates: Json; p_source: string }
        Returns: Json
      }
      worker_document_context: { Args: { p_doc_code: string }; Returns: Json }
      worker_llm_context: {
        Args: { p_merchant_codes: string[]; p_profile_code: string }
        Returns: Json
      }
      worker_mailbox_secret: {
        Args: { p_key: string; p_mailbox_code: string }
        Returns: string
      }
      worker_sms_context: { Args: { p_sms_code: string }; Returns: Json }
      yoy_compare: {
        Args: { p_profile_code: string; p_year?: number }
        Returns: {
          last_year: number
          month: number
          this_year: number
        }[]
      }
    }
    Enums: {
      [_ in never]: never
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
    Enums: {},
  },
} as const

