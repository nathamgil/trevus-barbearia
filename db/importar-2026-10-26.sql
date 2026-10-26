-- =====================================================================
--  Importação única (26/10/2026): assinantes do Hariel que já tinham plano
--  antes do sistema. Sem e-mail e sem WhatsApp por enquanto: o painel
--  completa depois e manda o acesso. Todos vencem dia 5.
--  Valor -> plano: 115 = Basic · 170 = Hyper · 230 = Mega.
--  Não repete quem já existe (mesmo nome com o mesmo barbeiro).
-- =====================================================================
insert into public.assinantes (nome, plano_id, barbeiro_id, status, ciclo_inicio, vence_em, origem)
select x.nome, p.id, b.id, 'ativo', date '2026-10-05', date '2026-11-05', 'balcao'
  from (values
    ('Lucas Andrade', 170), ('Keven', 230), ('Bruno', 230), ('Leon Gringo', 230), ('Wallace', 170),
    ('Felipe Perna', 170), ('Wellington', 170), ('Matheus S', 115), ('Claber', 115), ('Renan', 170),
    ('Regi Silva', 170), ('Alan Ramos', 115), ('Wesley R', 170), ('Gabriel P', 115), ('Caique R', 170)
  ) as x(nome, valor)
  join public.planos p on p.preco_centavos = x.valor * 100 and p.slug in ('basic','hyper','mega')
  join public.barbeiros b on b.slug = 'hariel'
 where not exists (select 1 from public.assinantes a where lower(a.nome) = lower(x.nome) and a.barbeiro_id = b.id)
returning nome, (select nome from public.planos where id = plano_id) as plano, vence_em;
