-- =====================================================================
--  v7 (25/11/2026) — Carlos Eduardo Nogueira Bahiano (cliente do Kelson,
--  corte a domicílio). Pedido do Kelson em áudio, 21/11:
--    · plano de 3 atendimentos por mês, ativado em 21/11;
--    · serviço próprio de 1h (meia hora de corte, raspar + barba, e o
--      resto é o deslocamento do Kelson);
--    · valor novo da mensalidade: AINDA NÃO INFORMADO → preço 0 = "acerte
--      com o Kelson" (sem botão de pagar e sem e-mail de cobrança).
-- =====================================================================

-- 1. Serviço só de plano: não aparece no site nem no cardápio
alter table public.servicos add column if not exists so_plano boolean not null default false;

insert into public.servicos (slug, nome, descricao, categoria, preco_centavos, duracao_min, ordem, ativo, so_barbeiros, consome, so_plano)
select 'domicilio', 'Corte a domicílio', 'Atendimento em casa (inclui o deslocamento).', 'Plano',
       0, 60, 99, true, array[b.id], '{"corte":1}'::jsonb, true
  from public.barbeiros b where b.slug = 'kelson'
on conflict (slug) do update set nome = excluded.nome, descricao = excluded.descricao, duracao_min = 60,
  ativo = true, so_barbeiros = excluded.so_barbeiros, consome = excluded.consome, so_plano = true;

-- 2. Plano personalizado do Carlos (escondido do site, sem trava, sem multa)
insert into public.planos (slug, nome, preco_centavos, itens, cotas, destaque, ordem, ativo) values
  ('k-domicilio', '3 cortes a domicílio', 0, array['3 atendimentos a domicílio por mês (1h cada)'], '{"corte":3}', false, 26, false)
on conflict (slug) do update set nome = excluded.nome, itens = excluded.itens, cotas = excluded.cotas, ativo = false;
update public.planos set multa_centavos = 0, sem_trava = true,
       pacote = array(select id from public.servicos where slug = 'domicilio')
 where slug = 'k-domicilio';

-- 3. Assinante
insert into public.assinantes (nome, email, telefone, plano_id, barbeiro_id, status, ciclo_inicio, vence_em, origem, proximo_pago)
select 'Carlos Eduardo Nogueira Bahiano', 'cbahiano@gmail.com', '71999880438', p.id, b.id, 'ativo',
       date '2026-11-21', date '2026-12-21', 'balcao', false
  from public.planos p, public.barbeiros b where p.slug = 'k-domicilio' and b.slug = 'kelson'
on conflict ((lower(email))) do update set
  nome = excluded.nome, telefone = excluded.telefone, plano_id = excluded.plano_id, barbeiro_id = excluded.barbeiro_id,
  status = 'ativo', ciclo_inicio = excluded.ciclo_inicio, vence_em = excluded.vence_em, proximo_pago = false;

-- 4. Plano com preço 0 (valor a combinar) não recebe e-mail de cobrança
create or replace function public.avisos_planos()
returns table (assinante_id uuid, tipo text, chave text)
language plpgsql volatile security definer set search_path = public as $$
declare v_hoje date := public.agora_bahia()::date;
begin
  perform public.atualiza_ciclos();
  return query
    select a.id, t.tipo, a.vence_em::text || ':' || t.tipo
      from public.assinantes a
      join public.planos p on p.id = a.plano_id
      cross join lateral (select case
          when a.status = 'ativo' and not a.proximo_pago and a.vence_em - v_hoje = 3 then 'd3'
          when a.status = 'ativo' and not a.proximo_pago and a.vence_em - v_hoje = 1 and not p.sem_trava then 'd1'
          when a.status = 'vencido' and v_hoje - a.vence_em between 0 and 2 then 'venceu'
        end as tipo) t
     where t.tipo is not null and not a.cortesia and a.email is not null and p.preco_centavos > 0
       and coalesce(a.ultimo_aviso, '') <> a.vence_em::text || ':' || t.tipo;
end;
$$;
grant execute on function public.avisos_planos() to service_role;

-- conferência
select a.nome, a.email, p.nome plano, p.preco_centavos, public.saldo_plano(a.id) saldo, a.vence_em,
       (select string_agg(s.nome || ' ' || s.duracao_min || 'min', ', ') from public.servicos s where s.id = any(p.pacote)) pacote
  from public.assinantes a join public.planos p on p.id = a.plano_id where lower(a.email) = 'cbahiano@gmail.com';
