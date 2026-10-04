-- Textos padrão do Telegram (aprovados pelo Lucas em 04/out, a partir das mensagens dele).
-- Já aplicada no Supabase como "telegram_campaign_templates".
alter table public.campaigns add column if not exists followup_template text;

update public.campaigns
set template = 'Hey {first_name}, love what you guys are building. Congratulations! I work in Business Development at CertiK and I was curious: are audits or pen testing in the pipeline for you right now?',
    followup_template = 'Hey {first_name}, hope you''re doing well! Just reviving our chat in case it''s useful: if you need an audit or pentest down the line, I''m around. And if licensing in any jurisdiction is in your plans, our compliance team at CertiK can help there too.'
where name = 'Raises e ICO · Telegram';
