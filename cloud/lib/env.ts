/**
 * Every environment variable Navi Cloud reads, in one place. Read lazily so
 * `next build` and the tests never need a configured environment.
 */

function str(name: string): string | undefined {
  const v = process.env[name];
  return v && v.length > 0 ? v : undefined;
}

function flag(name: string): boolean {
  const v = process.env[name];
  return v === "1" || v === "true" || v === "yes";
}

export const env = {
  // Public base URL of this deployment (used for auth redirects and the billing bridge).
  get baseUrl(): string {
    return str("NAVI_CLOUD_BASE_URL") ?? (str("VERCEL_URL") ? `https://${str("VERCEL_URL")}` : "http://localhost:3100");
  },

  // Supabase
  get supabaseUrl() { return str("SUPABASE_URL") ?? str("NEXT_PUBLIC_SUPABASE_URL"); },
  get supabaseAnonKey() { return str("SUPABASE_ANON_KEY") ?? str("NEXT_PUBLIC_SUPABASE_ANON_KEY"); },
  get supabaseServiceKey() { return str("SUPABASE_SERVICE_ROLE_KEY") ?? str("SUPABASE_SERVICE_KEY"); },
  /** HS256 secret from Supabase → Settings → API → JWT Secret. */
  get supabaseJwtSecret() { return str("SUPABASE_JWT_SECRET"); },
  /** Optional: JWKS URL for projects on asymmetric (ES256/RS256) signing keys. */
  get supabaseJwksUrl() { return str("SUPABASE_JWKS_URL"); },

  /** "supabase" when SUPABASE_URL is set, else "memory" (dev only). `DB_DRIVER` forces it. */
  get dbDriver(): "supabase" | "memory" {
    const forced = str("DB_DRIVER");
    if (forced === "memory" || forced === "supabase") return forced;
    return str("SUPABASE_URL") ? "supabase" : "memory";
  },

  // Vendors (server-side only — never reach the app)
  get typesafeApiKey() { return str("TYPESAFE_API_KEY"); },
  get anthropicApiKey() { return str("ANTHROPIC_API_KEY"); },
  get geminiApiKey() { return str("GEMINI_API_KEY"); },
  get typesafeUrl() { return str("TYPESAFE_API_URL") ?? "https://api.typesafe.ai/v1/systemone"; },
  get anthropicUrl() { return str("ANTHROPIC_API_URL") ?? "https://api.anthropic.com/v1/messages"; },
  get geminiBaseUrl() { return str("GEMINI_API_URL") ?? "https://generativelanguage.googleapis.com/v1beta/models"; },
  get geminiDefaultModel() { return str("GEMINI_DIGEST_MODEL") ?? "gemini-2.5-flash-lite"; },

  /** Canned upstream responses so the app can be tested without vendor keys. */
  get mockUpstream() { return flag("MOCK_UPSTREAM"); },

  // Stripe
  get stripeSecretKey() { return str("STRIPE_SECRET_KEY"); },
  get stripeWebhookSecret() { return str("STRIPE_WEBHOOK_SECRET"); },
  get stripePrices() {
    return {
      pro_month: str("STRIPE_PRICE_PRO_MONTH"),
      pro_year: str("STRIPE_PRICE_PRO_YEAR"),
      pro_recall_month: str("STRIPE_PRICE_PRO_RECALL_MONTH"),
      pro_recall_year: str("STRIPE_PRICE_PRO_RECALL_YEAR"),
    };
  },

  // Google OAuth is configured in the Supabase dashboard; these only toggle the button.
  get googleConfigured() { return Boolean(str("GOOGLE_CLIENT_ID") && str("GOOGLE_CLIENT_SECRET")); },

  /** When set, `POST /auth/dev-login` exists. Never set this in production. */
  get devLoginSecret() { return str("DEV_LOGIN_SECRET"); },
  /** HS256 secret used to mint tokens when no Supabase JWT secret is configured (memory driver). */
  get devJwtSecret() { return str("DEV_JWT_SECRET") ?? "navi-dev-jwt-secret-change-me"; },

  get isProduction() { return process.env.NODE_ENV === "production" && Boolean(str("VERCEL_ENV") === "production"); },
};

export type Env = typeof env;
