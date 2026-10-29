-- =====================================================================
--  29/10/2026: dados completos dos assinantes do Hariel (lista que ele mandou).
--  Só grava nome, e-mail e WhatsApp. NÃO manda acesso (isso é feito depois,
--  pelo painel ou pela função pagamento?acao=convidar).
--  Ewerton Cainã é novo: Basic, mesmo ciclo dos outros (vence 05/11).
-- =====================================================================
with b as (select id from public.barbeiros where slug = 'hariel'),
dados(antigo, nome, email, tel) as (values
  ('Alan Ramos',    'Alan Ramos',        'fbialan@hotmail.com',               '71986603835'),
  ('Bruno',         'Bruno Tauã',        'brunomainvayne33@gmail.com',        '71987180892'),
  ('Claber',        'Cleber Souza',      'cleber.souza.oliver2020@gmail.com', '71986722575'),
  ('Caique R',      'Caique Ramos',      'ramoscaique403@gmail.com',          '71991504138'),
  ('Felipe Perna',  'Felipe Lima',       'felipe2950@outlook.com',            '71993209270'),
  ('Keven',         'Keven de Jesus',    'keventriploxxx@gmail.com',          '71982541373'),
  ('Leon Gringo',   'Leon Slavick',      'leonhiltner12@hotmail.com',         '71999265900'),
  ('Lucas Andrade', 'Lucas Andrade',     'lucasquilombotitanick@gmail.com',   '71999105044'),
  ('Matheus S',     'Matheus Santos',    'mt.18santos@gmail.com',             '71993256851'),
  ('Regi Silva',    'Reginaldo Neto',    'reginaldoneto531@gmail.com',        '71983941058'),
  ('Renan',         'Renan Silva',       'renandasilvacontato@gmail.com',     '71981227973'),
  ('Wallace',       'Wallace Paranhos',  'gabisofa@gmail.com',                '71987826401'),
  ('Wesley R',      'Wesley Ribeiro',    'wesley_rsf@hotmail.com',            '71991821335'),
  ('Gabriel P',     'Wesley Gabriel',    'gabrielfxp2005@gmail.com',          '71982349238'),
  ('Wellington',    'Wellington Pereira','wellpereira2005@gmail.com',         '71984802661')
)
update public.assinantes a
   set nome = d.nome, email = d.email, telefone = d.tel
  from dados d, b
 where a.barbeiro_id = b.id and lower(a.nome) = lower(d.antigo)
returning a.nome, a.email, a.telefone;

insert into public.assinantes (nome, email, telefone, plano_id, barbeiro_id, status, ciclo_inicio, vence_em, origem)
select 'Ewerton Cainã', 'ewertoncaina1011@gmail.com', '71997041533', p.id, b.id, 'ativo', date '2026-10-05', date '2026-11-05', 'balcao'
  from public.planos p, public.barbeiros b
 where p.slug = 'basic' and b.slug = 'hariel'
   and not exists (select 1 from public.assinantes where email = 'ewertoncaina1011@gmail.com')
returning nome, email, vence_em;

-- conferência
select a.nome, p.nome as plano, a.email, a.telefone, a.vence_em, a.user_id is not null as tem_login
  from public.assinantes a join public.planos p on p.id = a.plano_id
  join public.barbeiros b on b.id = a.barbeiro_id
 where b.slug = 'hariel' order by a.nome;
