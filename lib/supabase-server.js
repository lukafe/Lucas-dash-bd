import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

export function envProblem() {
  const missing = ["NEXT_PUBLIC_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_ANON_KEY"].filter(
    (k) => !process.env[k]?.trim()
  );
  return missing.length
    ? `Faltam variáveis de ambiente na Vercel: ${missing.join(", ")}. ` +
        "Adicione em Settings → Environment Variables e faça Redeploy."
    : null;
}

/** Cliente do Supabase no servidor, com a sessão do usuário logado (RLS vale). */
export function supabaseServer() {
  const store = cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll: () => store.getAll(),
        setAll: (list) => {
          try {
            list.forEach(({ name, value, options }) => store.set(name, value, options));
          } catch {
            // Chamado de Server Component: o middleware já renova a sessão.
          }
        },
      },
    }
  );
}
