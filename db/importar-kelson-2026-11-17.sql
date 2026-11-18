-- =====================================================================
--  Importação (17/11/2026): assinantes do KELSON que já tinham plano
--  antes do sistema. Cada um paga um valor próprio, então ganham planos
--  personalizados escondidos do site (ativo = false), todos SEM TRAVA
--  (o saldo renova no dia mesmo sem pagamento, sem multa).
--
--  Fonte: nota do Kelson + respostas dele ao vivo em 17/11.
--    · Vencimento dia 10 (Endel dia 13, Lucas dia 11). Todos pagaram o mês.
--    · Já usados no ciclo atual: Thiago 1, Nivisson 1, Michel 1, Endel 1,
--      Jean 1 (acho que um corte e barba), Miller 0, Lucas 0.
--    · Jean: 3 corte e barba + 2 "paliativos" = acabamento do pé (15 min).
--    · Carlos ficou de fora (corte a domicílio).
-- =====================================================================

-- 1. Acabamento passa a contar em plano (só cobre quem tiver cota de acabamento)
update public.servicos set consome = '{"acabamento":1}' where slug = 'acabamento';

-- 2. Planos personalizados (não aparecem no site, sem multa, sem trava)
insert into public.planos (slug, nome, preco_centavos, itens, cotas, destaque, ordem, ativo) values
  ('k-3cortes-140', '3 cortes · R$140',                     14000, array['3 cortes por mês'],                            '{"corte":3}',                           false, 20, false),
  ('k-4cortes-140', '4 cortes · R$140',                     14000, array['4 cortes por mês'],                            '{"corte":4}',                           false, 21, false),
  ('k-4cortes-120', '4 cortes · R$120',                     12000, array['4 cortes por mês'],                            '{"corte":4}',                           false, 22, false),
  ('k-4cortes-100', '4 cortes · R$100',                     10000, array['4 cortes por mês'],                            '{"corte":4}',                           false, 23, false),
  ('k-cbs-160',     'Corte, barba e sobrancelha · R$160',   16000, array['6 cortes, 6 barbas e 6 sobrancelhas por mês'], '{"corte":6,"barba":6,"sobrancelha":6}',  false, 24, false),
  ('k-jean-130',    '3 corte e barba + 2 acabamentos · R$130', 13000, array['3 corte e barba por mês','2 acabamentos (pé) por mês'], '{"corte":3,"barba":3,"acabamento":2}', false, 25, false)
on conflict (slug) do update set nome = excluded.nome, preco_centavos = excluded.preco_centavos, itens = excluded.itens,
  cotas = excluded.cotas, ordem = excluded.ordem, ativo = false;

update public.planos set multa_centavos = 0, sem_trava = true where slug like 'k-%';
update public.planos set pacote = array(select id from public.servicos where slug = 'corte')
 where slug in ('k-3cortes-140','k-4cortes-140','k-4cortes-120','k-4cortes-100');
update public.planos set pacote = array(select id from public.servicos where slug in ('corte-barba','sobrancelha') order by ordem)
 where slug = 'k-cbs-160';
update public.planos set pacote = null where slug = 'k-jean-130';   -- escolhe: corte e barba ou acabamento

-- 3. Assinantes (se o e-mail já existir, atualiza)
insert into public.assinantes (nome, email, plano_id, barbeiro_id, status, ciclo_inicio, vence_em, origem, proximo_pago, ajuste, ajuste_ciclo)
select x.nome, x.email, p.id, b.id, 'ativo', x.ini, (x.ini + interval '1 month')::date, 'balcao', false, x.ajuste::jsonb, x.ini
  from (values
    ('Thiago',           'xthbf@outlook.com',                'k-3cortes-140', date '2026-11-10', '{"corte":-1}'),
    ('Rodrigo Nivisson', 'rodrigo.0809@hotmail.com',         'k-3cortes-140', date '2026-11-10', '{"corte":-1}'),
    ('Rodrigo Miller',   'rodrigo.millerps@gmail.com',       'k-4cortes-140', date '2026-11-10', '{}'),
    ('Michel Fonseca',   'professormichelfonseca@gmail.com', 'k-4cortes-120', date '2026-11-10', '{"corte":-1}'),
    ('Endel Sena',       'endelsena4@gmail.com',             'k-4cortes-100', date '2026-11-13', '{"corte":-1}'),
    ('Jean',             'jeananalista@hotmail.com',         'k-jean-130',    date '2026-11-10', '{"corte":-1,"barba":-1}'),
    ('Lucas',            'lucasoli7@gmail.com',              'k-cbs-160',     date '2026-11-11', '{}')
  ) as x(nome, email, plano, ini, ajuste)
  join public.planos p on p.slug = x.plano
  join public.barbeiros b on b.slug = 'kelson'
on conflict ((lower(email))) do update set
  nome = excluded.nome, plano_id = excluded.plano_id, barbeiro_id = excluded.barbeiro_id, status = 'ativo',
  ciclo_inicio = excluded.ciclo_inicio, vence_em = excluded.vence_em, origem = 'balcao', proximo_pago = false,
  ajuste = excluded.ajuste, ajuste_ciclo = excluded.ajuste_ciclo;

-- 4. Cobranças antigas em aberto desses clientes (ex.: Hyper do Miller, 24/10) viram canceladas
update public.pagamentos_plano pg set status = 'cancelado'
  from public.assinantes a
 where a.id = pg.assinante_id and pg.status = 'pendente'
   and lower(a.email) in ('xthbf@outlook.com','rodrigo.0809@hotmail.com','rodrigo.millerps@gmail.com',
                          'professormichelfonseca@gmail.com','endelsena4@gmail.com','jeananalista@hotmail.com','lucasoli7@gmail.com');

-- 5. Conferência
select a.nome, a.email, p.nome as plano, p.preco_centavos / 100 as valor, public.saldo_plano(a.id) as saldo,
       a.status, a.vence_em, a.user_id is not null as tem_acesso
  from public.assinantes a join public.planos p on p.id = a.plano_id join public.barbeiros b on b.id = a.barbeiro_id
 where b.slug = 'kelson' order by a.nome;
