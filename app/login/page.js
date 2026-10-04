import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { envProblem, supabaseServer } from "@/lib/supabase-server";

async function sendLink(formData) {
  "use server";
  const email = String(formData.get("email") || "").trim().toLowerCase();
  if (!email) redirect("/login?erro=vazio");
  const h = await headers();
  const origin = `${h.get("x-forwarded-proto") ?? "https"}://${h.get("host")}`;
  const { error } = await (await supabaseServer()).auth.signInWithOtp({
    email,
    options: { emailRedirectTo: `${origin}/auth/callback`, shouldCreateUser: true },
  });
  redirect(error ? `/login?erro=envio` : `/login?enviado=1`);
}

export const dynamic = "force-dynamic";

const MSG = {
  vazio: "Digite seu email.",
  envio: "Não consegui enviar o link. Confira o email e tente de novo.",
  link: "O link expirou ou já foi usado. Peça um novo.",
};

export default async function Login({ searchParams }) {
  const sp = (await searchParams) ?? {};
  const problem = envProblem();
  return (
    <main className="min-h-screen grid place-items-center px-4">
      <div className="w-full max-w-sm rounded-xl border border-line bg-surface p-6">
        <div className="text-[11px] font-semibold uppercase tracking-[0.08em] text-muted">Aurora</div>
        <h1 className="mt-1 text-xl font-bold">Monitor de outreach</h1>
        {problem ? (
          <p className="mt-4 rounded-lg bg-warn/10 p-3 text-sm text-warn">{problem}</p>
        ) : sp.enviado ? (
          <p className="mt-4 text-sm text-muted">Link enviado. Abra o email e clique para entrar.</p>
        ) : (
          <form action={sendLink} className="mt-4 flex flex-col gap-3">
            <label htmlFor="email" className="text-sm text-muted">Email</label>
            <input
              id="email" name="email" type="email" required autoComplete="email"
              className="rounded-lg border border-line bg-ground px-3 py-2 outline-none focus:border-accent"
              placeholder="voce@certik.com"
            />
            {sp.erro && <p className="text-sm text-bad">{MSG[sp.erro] ?? MSG.envio}</p>}
            <button className="rounded-lg bg-accent px-3 py-2 font-medium text-white">Enviar link de acesso</button>
          </form>
        )}
      </div>
    </main>
  );
}
