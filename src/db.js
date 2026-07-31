import { createClient } from '@supabase/supabase-js';

const { SUPABASE_URL, SUPABASE_SERVICE_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
  throw new Error('Faltan SUPABASE_URL o SUPABASE_SERVICE_KEY. Revisa tu .env');
}

export const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false },
});

export const BUCKET = process.env.SUPABASE_BUCKET ?? 'shots';
export const today = () => new Date().toISOString().slice(0, 10);
