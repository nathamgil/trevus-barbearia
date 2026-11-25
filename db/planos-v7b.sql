-- =====================================================================
--  v7b (25/11/2026) — Rodrigo Miller passa a marcar CORTE E BARBA.
--  Autorizado pelo Kelson (via Natham): o plano dele é diferente, mesmo
--  preço (R$ 140), 4 corte e barba por mês. Plano próprio para não mexer
--  em mais ninguém.
-- =====================================================================
insert into public.planos (slug, nome, preco_centavos, itens, cotas, destaque, ordem, ativo) values
  ('k-miller-140', '4 corte e barba · R$140', 14000, array['4 corte e barba por mês'], '{"corte":4,"barba":4}', false, 27, false)
on conflict (slug) do update set nome = excluded.nome, itens = excluded.itens, cotas = excluded.cotas, ativo = false;
update public.planos set multa_centavos = 0, sem_trava = true,
       pacote = array(select id from public.servicos where slug = 'corte-barba')
 where slug = 'k-miller-140';

update public.assinantes set plano_id = (select id from public.planos where slug = 'k-miller-140')
 where lower(email) = 'rodrigo.millerps@gmail.com';

-- conferência
select a.nome, p.nome plano, public.saldo_plano(a.id) saldo, a.vence_em,
       (select string_agg(s.nome || ' ' || s.duracao_min || 'min', ', ') from public.servicos s where s.id = any(p.pacote)) pacote
  from public.assinantes a join public.planos p on p.id = a.plano_id where lower(a.email) = 'rodrigo.millerps@gmail.com';
