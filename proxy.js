import { createServerClient } from "@supabase/ssr";
import { NextResponse } from "next/server";

const PUBLIC = ["/login", "/auth/callback"];

// Login desligado por enquanto (decisão do Lucas, out/2026). Para voltar a exigir, DASH_REQUIRE_LOGIN=true na Vercel.
const REQUIRE_LOGIN = () => process.env.DASH_REQUIRE_LOGIN === "true";

export async function proxy(request) {
  let response = NextResponse.next({ request });
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return response; // a página mostra o aviso de configuração

  const supabase = createServerClient(url, key, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const isPublic = PUBLIC.some((p) => request.nextUrl.pathname.startsWith(p));
  if (REQUIRE_LOGIN() && !user && !isPublic) {
    const login = request.nextUrl.clone();
    login.pathname = "/login";
    return NextResponse.redirect(login);
  }
  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|ico)$).*)"],
};
