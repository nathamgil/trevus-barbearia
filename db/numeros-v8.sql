-- =====================================================================
--  v8 (25/11/2026) — "Meus números": cada barbeiro vê o próprio mês.
--  Faturamento (feito e a receber), planos recebidos, comparação com o
--  período anterior, dia a dia, serviços, dias da semana e os clientes
--  que mais vêm (para mimo/brinde). Barbeiro só vê o dele; o gestor
--  escolhe de quem ver.
-- =====================================================================
create or replace function public.meus_numeros(p_ini date, p_fim date, p_barbeiro uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_b public.barbeiros%rowtype;
  v_hoje date := public.agora_bahia()::date;
  v_dias int := p_fim - p_ini + 1;
  v_ini_ant date := p_ini - (p_fim - p_ini + 1);
  v_fim_ant date := p_ini - 1;
  v jsonb;
begin
  if p_fim < p_ini then raise exception 'PERIODO_INVALIDO'; end if;
  if public.e_gestor() and p_barbeiro is not null then
    select * into v_b from public.barbeiros where id = p_barbeiro;
  else
    select * into v_b from public.barbeiros where user_id = auth.uid();
  end if;
  if v_b.id is null then
    if public.e_gestor() then select * into v_b from public.barbeiros where ativo order by ordem limit 1;
    else raise exception 'SO_BARBEIRO' using hint = 'Só o barbeiro vê os próprios números.'; end if;
  end if;
  perform public.atualiza_ciclos();

  with ag as (
    select a.*,
           a.sinal_status = 'plano' as do_plano,
           a.data <= v_hoje as ja_foi,
           coalesce(a.assinante_id::text,
                    nullif(case when length(regexp_replace(a.cliente_telefone, '\D', '', 'g')) >= 10
                                then right(regexp_replace(a.cliente_telefone, '\D', '', 'g'), 11) end, ''),
                    lower(trim(a.cliente_nome))) as cli
      from public.agendamentos a
     where a.barbeiro_id = v_b.id
  ),
  per as (select * from ag where data between p_ini and p_fim),
  val as (select * from per where status in ('confirmado','concluido')),
  ant as (select * from ag where data between v_ini_ant and v_fim_ant and status in ('confirmado','concluido')),
  pp as (
    select pg.valor_centavos, (pg.pago_em at time zone 'America/Bahia')::date dia
      from public.pagamentos_plano pg join public.assinantes s on s.id = pg.assinante_id
     where s.barbeiro_id = v_b.id and pg.status = 'pago'
  ),
  clientes as (
    select cli,
           (array_agg(cliente_nome order by data desc, inicio desc))[1] nome,
           (array_agg(nullif(cliente_telefone, '') order by data desc, inicio desc) filter (where nullif(cliente_telefone, '') is not null))[1] telefone,
           count(*) visitas,
           coalesce(sum(preco_centavos) filter (where not do_plano), 0) gasto,
           max(data) ultima,
           bool_or(assinante_id is not null) assinante
      from val where ja_foi group by cli
  ),
  primeira as (select cli, min(data) d from ag where status in ('confirmado','concluido') group by cli)
  select jsonb_build_object(
    'barbeiro', jsonb_build_object('id', v_b.id, 'nome', v_b.nome, 'foto', v_b.foto),
    'ini', p_ini, 'fim', p_fim, 'hoje', v_hoje, 'dias', v_dias,
    'feito',      (select coalesce(sum(preco_centavos), 0) from val where ja_foi and not do_plano),
    'a_receber',  (select coalesce(sum(preco_centavos), 0) from val where not ja_foi and not do_plano),
    'planos',     (select coalesce(sum(valor_centavos), 0) from pp where dia between p_ini and p_fim),
    'anterior',   (select coalesce(sum(preco_centavos), 0) from ant where not do_plano)
                + (select coalesce(sum(valor_centavos), 0) from pp where dia between v_ini_ant and v_fim_ant),
    'atendimentos', (select count(*) from val where ja_foi),
    'avulsos',      (select count(*) from val where ja_foi and not do_plano),
    'pelo_plano',   (select count(*) from val where ja_foi and do_plano),
    'agendados',    (select count(*) from val where not ja_foi),
    'faltas',       (select count(*) from per where status = 'faltou'),
    'cancelados',   (select count(*) from per where status = 'cancelado'),
    'clientes',     (select count(*) from clientes),
    'novos',        (select count(*) from clientes c join primeira f on f.cli = c.cli where f.d between p_ini and p_fim),
    'assinantes_ativos',   (select count(*) from public.assinantes s where s.barbeiro_id = v_b.id and s.status = 'ativo'),
    'assinantes_vencidos', (select count(*) from public.assinantes s where s.barbeiro_id = v_b.id and s.status = 'vencido'),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', d::date,
                  'valor', (select coalesce(sum(preco_centavos), 0) from val where data = d::date and not do_plano)
                         + (select coalesce(sum(valor_centavos), 0) from pp where pp.dia = d::date),
                  'qtd',   (select count(*) from val where data = d::date)) order by d), '[]')
                  from generate_series(p_ini, p_fim, interval '1 day') d),
    'por_servico', (select coalesce(jsonb_agg(x order by x.qtd desc, x.valor desc), '[]') from (
                  select servico_nome nome, count(*) qtd, coalesce(sum(preco_centavos) filter (where not do_plano), 0) valor
                    from val group by servico_nome order by count(*) desc limit 8) x),
    'por_semana', (select coalesce(jsonb_agg(jsonb_build_object('dow', w, 'qtd',
                  (select count(*) from val where extract(dow from data) = w)) order by w), '[]') from generate_series(0, 6) w),
    'por_hora', (select coalesce(jsonb_agg(jsonb_build_object('h', h, 'qtd', n) order by h), '[]') from (
                  select extract(hour from inicio)::int h, count(*) n from val group by 1) y),
    'top_clientes', (select coalesce(jsonb_agg(to_jsonb(t) - 'cli' order by t.visitas desc, t.gasto desc, t.ultima desc), '[]') from (
                  select * from clientes order by visitas desc, gasto desc, ultima desc limit 10) t)
  ) into v;
  return v;
end;
$$;

revoke all on function public.meus_numeros(date,date,uuid) from public, anon, authenticated;
grant execute on function public.meus_numeros(date,date,uuid) to authenticated;
