# Lucas-dash-bd

Monitor pessoal de BD do Lucas (CertiK). Lê o Supabase (projeto GTM-RAISE) pela função `dash_snapshot()`,
que devolve só o que a página mostra; as tabelas seguem fechadas pelo RLS.

**Hoje a página está aberta, sem login (decisão do Lucas, out/2026).** Para voltar a exigir login:
1. Supabase: `update public.source_state set value = 'false' where key = 'dash_public';`
2. Vercel: variável `DASH_REQUIRE_LOGIN=true` e Redeploy.

## v1: Aurora · Fundraising
- Campanhas de email e Telegram: quota do dia, contas e pessoas abordadas, respostas, bounces, cadência.
- Alertas: inscrições pausadas e bounce de email acima de 3% em 7 dias.
- Atividade de 30 dias, contas de envio, saúde do sistema (pipeline, rotinas e syncs), respostas classificadas,
  contas, últimos toques e fila de reativação.

## Stack
Next.js 16 (App Router) + React 19 + Tailwind 3 + `@supabase/ssr`, Node 20.9 ou mais novo. O login é checado em
`proxy.js` (o antigo middleware) e de novo pelo RLS no banco.

## Rodar
1. Variáveis (Vercel → Settings → Environment Variables), ver `.env.example`:
   `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_ANON_KEY` (chave pública; a chave secreta nunca vai para cá).
2. Supabase → Authentication → URL Configuration: Site URL = domínio da Vercel e Redirect URL `https://<domínio>/auth/callback`.
3. Entrar com o link mágico enviado ao email. Depois do primeiro login, desligar "Allow new users to sign up".

## Banco
As migrations ficam em `supabase/migrations` e são aplicadas no projeto `eiyjwmckmoyhfidabizu`.
