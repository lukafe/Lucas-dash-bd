# Lucas-dash-bd

Monitor pessoal de BD do Lucas (CertiK). Lê o Supabase (projeto GTM-RAISE) com o login do próprio Lucas;
as regras de acesso (RLS) só liberam leitura para o email dele.

## v1: Aurora · Fundraising
- Campanhas de email e Telegram: quota do dia, contas e pessoas abordadas, respostas, bounces, cadência.
- Alertas: inscrições pausadas e bounce de email acima de 3% em 7 dias.
- Atividade de 30 dias, contas de envio, saúde do sistema (pipeline, rotinas e syncs), respostas classificadas,
  contas, últimos toques e fila de reativação.

## Rodar
1. Variáveis (Vercel → Settings → Environment Variables), ver `.env.example`:
   `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_ANON_KEY` (chave pública; a chave secreta nunca vai para cá).
2. Supabase → Authentication → URL Configuration: Site URL = domínio da Vercel e Redirect URL `https://<domínio>/auth/callback`.
3. Entrar com o link mágico enviado ao email. Depois do primeiro login, desligar "Allow new users to sign up".

## Banco
As migrations ficam em `supabase/migrations` e são aplicadas no projeto `eiyjwmckmoyhfidabizu`.
