-- =====================================================================
--  Trevus Barbearia — PLANOS v2 (26/10/2026)
--  Rode DEPOIS de schema.sql e planos.sql. Pode rodar de novo.
--
--    · Assinante importado sem e-mail/WhatsApp (o painel completa depois).
--    · Plano sem barbeiro fixo (marca com qualquer um) e plano de cortesia
--      (não cobra, renova sozinho): o plano de parceria do Natham (Zync).
--    · Gestor (painel master): vê tudo e os números de cada barbeiro.
--    · O barbeiro marca horário pelo plano no painel (cliente sem login).
-- =====================================================================

alter table public.assinantes alter column email drop not null;
alter table public.assinantes alter column telefone drop not null;
alter table public.assinantes alter column barbeiro_id drop not null;   -- nulo = qualquer barbeiro
alter table public.assinantes add column if not exists cortesia boolean not null default false;
alter table public.planos drop constraint if exists planos_preco_centavos_check;
alter table public.planos add constraint planos_preco_centavos_check check (preco_centavos >= 0);

-- ---------------------------------------------------------------------
-- Gestores: entram no painel e veem tudo. Identificados pelo e-mail do login.
-- ---------------------------------------------------------------------
create table if not exists public.gestores (email text primary key, nome text);
alter table public.gestores enable row level security;   -- sem policy: só as funções leem

create or replace function public.e_gestor()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.gestores g join auth.users u on lower(u.email) = lower(g.email) where u.id = auth.uid());
$$;

create or replace function public.e_socio()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.barbeiros where user_id = auth.uid()) or public.e_gestor();
$$;

-- ---------------------------------------------------------------------
-- Ciclo: cortesia vira o mês sozinha, sem pagamento
-- ---------------------------------------------------------------------
create or replace function public.atualiza_ciclo(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a public.assinantes%rowtype; v_hoje date := public.agora_bahia()::date;
begin
  select * into a from public.assinantes where id = p_id for update;
  if not found or a.status <> 'ativo' then return; end if;
  while a.vence_em is not null and v_hoje >= a.vence_em loop
    if a.proximo_pago or a.cortesia then
      a.ciclo_inicio := a.vence_em;
      a.vence_em     := (a.vence_em + interval '1 month')::date;
      a.proximo_pago := false;
    else
      a.status := 'vencido';
      exit;
    end if;
  end loop;
  update public.assinantes set status = a.status, ciclo_inicio = a.ciclo_inicio,
         vence_em = a.vence_em, proximo_pago = a.proximo_pago where id = a.id;
end;
$$;

create or replace function public.cobranca_aberta(p_assinante uuid)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare a public.assinantes%rowtype; v uuid;
begin
  perform public.atualiza_ciclo(p_assinante);
  select * into a from public.assinantes where id = p_assinante;
  if not found or a.status = 'cancelado' or a.cortesia then return null; end if;
  if a.status = 'ativo' and a.proximo_pago then return null; end if;
  select id into v from public.pagamentos_plano where assinante_id = a.id and status = 'pendente' order by criado_em desc limit 1;
  if v is null then
    insert into public.pagamentos_plano (assinante_id, valor_centavos)
    select a.id, p.preco_centavos from public.planos p where p.id = a.plano_id returning id into v;
  end if;
  return v;
end;
$$;

-- lembrete por e-mail só para quem tem e-mail e paga
create or replace function public.avisos_planos()
returns table (assinante_id uuid, tipo text, chave text)
language plpgsql volatile security definer set search_path = public as $$
declare v_hoje date := public.agora_bahia()::date;
begin
  perform public.atualiza_ciclos();
  return query
    select a.id, t.tipo, a.vence_em::text || ':' || t.tipo
      from public.assinantes a
      cross join lateral (select case
          when a.status = 'ativo' and not a.proximo_pago and a.vence_em - v_hoje = 3 then 'd3'
          when a.status = 'ativo' and not a.proximo_pago and a.vence_em - v_hoje = 1 then 'd1'
          when a.status = 'vencido' and v_hoje - a.vence_em between 0 and 2 then 'venceu'
        end as tipo) t
     where t.tipo is not null and not a.cortesia and a.email is not null
       and coalesce(a.ultimo_aviso, '') <> a.vence_em::text || ':' || t.tipo;
end;
$$;

-- ---------------------------------------------------------------------
-- Área do assinante
-- ---------------------------------------------------------------------
drop function if exists public.meu_plano();
create or replace function public.meu_plano()
returns table (id uuid, nome text, email text, telefone text, foto text, status text, ciclo_inicio date, vence_em date,
               proximo_pago boolean, plano text, plano_preco integer, cotas jsonb, saldo jsonb,
               barbeiro_id uuid, barbeiro text, barbeiro_foto text, socio boolean, pacote uuid[], cortesia boolean)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare v_id uuid;
begin
  select a.id into v_id from public.assinantes a where a.user_id = auth.uid();
  if v_id is not null then perform public.atualiza_ciclo(v_id); end if;
  return query
    select a.id, a.nome, a.email, a.telefone, a.foto, a.status, a.ciclo_inicio, a.vence_em, a.proximo_pago,
           p.nome, p.preco_centavos, p.cotas,
           case when a.status = 'ativo' then public.saldo_plano(a.id) else '{}'::jsonb end,
           b.id, b.nome, b.foto, public.e_socio(), p.pacote, a.cortesia
      from public.assinantes a
      join public.planos p on p.id = a.plano_id
      left join public.barbeiros b on b.id = a.barbeiro_id
     where a.id = v_id;
end;
$$;

-- Núcleo da marcação pelo plano (usado pelo site e pelo painel).
create or replace function public.marca_plano(a_id uuid, p_servicos uuid[], p_barbeiro uuid, p_data date, p_inicio time,
                                              p_dur integer, p_obs text, p_origem text, p_checa_grade boolean)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare
  a public.assinantes%rowtype; p public.planos%rowtype; v_barb uuid;
  v_lista jsonb; v_nomes text; v_total integer; v_dur integer; v_consumo jsonb := '{}'; v_saldo jsonb;
  s record; k text; v_id uuid; v_limite date;
begin
  perform public.atualiza_ciclo(a_id);
  select * into a from public.assinantes where id = a_id;
  if not found then raise exception 'SEM_PLANO' using hint = 'Assinante não encontrado.'; end if;
  if a.status <> 'ativo' then
    raise exception 'PLANO_TRAVADO' using hint = 'O plano está com a mensalidade em aberto. Pague para voltar a marcar.';
  end if;
  v_limite := case when a.proximo_pago or a.cortesia then (a.vence_em + interval '1 month')::date else a.vence_em end;
  if p_data >= v_limite then
    raise exception 'FORA_DO_CICLO' using hint = 'Esse dia já cai no próximo mês do plano. Pague a mensalidade para liberar.';
  end if;
  v_barb := coalesce(a.barbeiro_id, p_barbeiro);
  if v_barb is null then raise exception 'BARBEIRO_INVALIDO' using hint = 'Escolha o barbeiro.'; end if;
  if a.barbeiro_id is not null and p_barbeiro is not null and p_barbeiro <> a.barbeiro_id and p_checa_grade then
    raise exception 'BARBEIRO_INVALIDO' using hint = 'Esse plano é com outro barbeiro.';
  end if;

  select * into p from public.planos where id = a.plano_id;
  if p.pacote is not null then p_servicos := p.pacote; end if;

  for s in select * from public.servicos sv where sv.ativo and sv.id = any(p_servicos) loop
    if s.consome is null then
      raise exception 'NAO_COBERTO' using hint = s.nome || ' não está no plano.';
    end if;
    for k in select jsonb_object_keys(s.consome) loop
      if coalesce((p.cotas->>k)::integer, 0) = 0 then raise exception 'NAO_COBERTO' using hint = s.nome || ' não está no plano.'; end if;
      v_consumo := v_consumo || jsonb_build_object(k, coalesce((v_consumo->>k)::integer, 0) + (s.consome->>k)::integer);
    end loop;
  end loop;
  if v_consumo = '{}'::jsonb then raise exception 'SERVICO_INVALIDO' using hint = 'Escolha pelo menos um serviço.'; end if;

  v_saldo := public.saldo_plano(a.id, p_data);
  for k in select jsonb_object_keys(v_consumo) loop
    if (v_consumo->>k)::integer > coalesce((v_saldo->>k)::integer, 0) then
      raise exception 'SEM_SALDO' using hint = 'O saldo deste mês do plano acabou.';
    end if;
  end loop;
  if not public.barbeiro_faz(p_servicos, v_barb) then
    raise exception 'SERVICO_INVALIDO' using hint = 'Esse barbeiro não faz um desses serviços.';
  end if;

  select jsonb_agg(jsonb_build_object('id', sv.id, 'nome', sv.nome, 'preco_centavos', sv.preco_centavos, 'duracao_min', sv.duracao_min) order by sv.ordem),
         string_agg(sv.nome, ' + ' order by sv.ordem), sum(sv.preco_centavos)::integer, sum(sv.duracao_min)::integer
    into v_lista, v_nomes, v_total, v_dur
    from public.servicos sv where sv.ativo and sv.id = any(p_servicos);
  v_dur := coalesce(p_dur, v_dur);

  if p_checa_grade and not exists (select 1 from public.slots_barbeiro(p_data, v_dur, v_barb) x where x = p_inicio) then
    raise exception 'HORARIO_INDISPONIVEL' using hint = 'Esse horário acabou de ser ocupado. Escolha outro.';
  end if;

  begin
    insert into public.agendamentos (codigo, barbeiro_id, barbeiro_nome, servicos, servico_nome, preco_centavos, duracao_min,
      sinal_centavos, sinal_status, cliente_nome, cliente_telefone, cliente_email, data, inicio, fim, status,
      observacao, assinante_id, consumo, origem)
    select public.novo_codigo(), b.id, b.nome, v_lista, v_nomes, v_total, v_dur,
           0, 'plano', a.nome, coalesce(a.telefone, ''), a.email, p_data, p_inicio, p_inicio + make_interval(mins => v_dur), 'confirmado',
           nullif(btrim(p_obs), ''), a.id, v_consumo, p_origem
      from public.barbeiros b where b.id = v_barb
    returning agendamentos.id into v_id;
  exception when exclusion_violation then
    raise exception 'HORARIO_INDISPONIVEL' using hint = 'Esse barbeiro já tem cliente nesse horário.';
  end;
  return v_id;
end;
$$;

-- pelo site (cliente logado)
drop function if exists public.agendar_pelo_plano(uuid[],date,time,text);
create or replace function public.agendar_pelo_plano(p_servicos uuid[], p_data date, p_inicio time, p_obs text default null, p_barbeiro uuid default null)
returns table (id uuid, codigo text, barbeiro text, servico text, dia date, inicio time, fim time)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare v_ass uuid; v_id uuid;
begin
  select a.id into v_ass from public.assinantes a where a.user_id = auth.uid();
  if v_ass is null then raise exception 'SEM_PLANO' using hint = 'Essa conta não tem plano.'; end if;
  v_id := public.marca_plano(v_ass, p_servicos, p_barbeiro, p_data, p_inicio, null, p_obs, 'site', true);
  return query select ag.id, ag.codigo, ag.barbeiro_nome, ag.servico_nome, ag.data, ag.inicio, ag.fim
                 from public.agendamentos ag where ag.id = v_id;
end;
$$;

-- pelo painel (barbeiro marca para o cliente; vale fora da grade, como o balcão)
create or replace function public.agendar_plano_painel(p_assinante uuid, p_barbeiro uuid, p_data date, p_inicio time, p_dur integer default null)
returns uuid language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  if p_dur is not null and (p_dur < 5 or p_dur > 480) then raise exception 'DURACAO_INVALIDA' using hint = 'A duração vai de 5 a 480 minutos.'; end if;
  return public.marca_plano(p_assinante, null, p_barbeiro, p_data, p_inicio, p_dur, null, 'balcao', false);
end;
$$;

-- ---------------------------------------------------------------------
-- Painel: lista de assinantes (sem barbeiro fixo = "Qualquer barbeiro")
-- ---------------------------------------------------------------------
drop function if exists public.lista_assinantes();
create or replace function public.lista_assinantes()
returns table (id uuid, nome text, telefone text, email text, foto text, status text, vence_em date, proximo_pago boolean,
               plano text, barbeiro_id uuid, barbeiro text, saldo jsonb, cotas jsonb, tem_acesso boolean, origem text, cortesia boolean)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  perform public.atualiza_ciclos();
  return query
    select a.id, a.nome, a.telefone, a.email, a.foto, a.status, a.vence_em, a.proximo_pago, p.nome, a.barbeiro_id,
           coalesce(b.nome, 'Qualquer barbeiro'),
           case when a.status = 'ativo' then public.saldo_plano(a.id) else '{}'::jsonb end, p.cotas,
           a.user_id is not null, a.origem, a.cortesia
      from public.assinantes a join public.planos p on p.id = a.plano_id left join public.barbeiros b on b.id = a.barbeiro_id
     where a.status <> 'aguardando_pagamento'
     order by case a.status when 'vencido' then 0 when 'ativo' then 1 else 2 end, a.vence_em nulls last, a.nome;
end;
$$;

-- ---------------------------------------------------------------------
-- Painel master: números do período, por barbeiro
-- ---------------------------------------------------------------------
create or replace function public.e_gestor_rpc() returns boolean language sql stable security definer set search_path = public as $$
  select public.e_gestor();
$$;

create or replace function public.painel_master(p_ini date, p_fim date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.e_gestor() then raise exception 'SO_GESTOR' using hint = 'Só o gestor vê o painel master.'; end if;
  perform public.atualiza_ciclos();
  with ag as (
    select a.*,
           (a.status = 'aguardando_pagamento' and a.expira_em < now()) or a.status = 'expirado' as abandonado
      from public.agendamentos a where a.data between p_ini and p_fim
  ), pb as (
    select b.id, b.nome, b.foto, b.ordem,
      (select count(*) from ag where ag.barbeiro_id = b.id and ag.status in ('confirmado','concluido','faltou')) as marcados,
      (select count(*) from ag where ag.barbeiro_id = b.id and ag.status = 'concluido') as atendidos,
      (select count(*) from ag where ag.barbeiro_id = b.id and ag.status = 'faltou') as faltas,
      (select count(*) from ag where ag.barbeiro_id = b.id and ag.status = 'cancelado') as cancelados,
      (select count(*) from ag where ag.barbeiro_id = b.id and ag.abandonado) as pix_abandonados,
      (select count(*) from ag where ag.barbeiro_id = b.id and ag.sinal_status = 'plano' and ag.status in ('confirmado','concluido','faltou')) as pelo_plano,
      (select count(*) from ag where ag.barbeiro_id = b.id and ag.origem = 'balcao' and ag.status in ('confirmado','concluido')) as balcao,
      (select coalesce(sum(ag.preco_centavos), 0) from ag where ag.barbeiro_id = b.id and ag.status in ('confirmado','concluido') and ag.sinal_status <> 'plano') as faturamento,
      (select coalesce(sum(ag.sinal_centavos - ag.credito_usado), 0) from ag where ag.barbeiro_id = b.id and ag.sinal_status in ('pago','retido')) as sinais,
      (select count(*) from public.assinantes s where s.barbeiro_id = b.id and s.status = 'ativo') as assinantes_ativos,
      (select count(*) from public.assinantes s where s.barbeiro_id = b.id and s.status = 'vencido') as assinantes_vencidos,
      (select coalesce(sum(pg.valor_centavos), 0) from public.pagamentos_plano pg join public.assinantes s on s.id = pg.assinante_id
        where s.barbeiro_id = b.id and pg.status = 'pago' and (pg.pago_em at time zone 'America/Bahia')::date between p_ini and p_fim) as receita_planos
      from public.barbeiros b where b.ativo
  )
  select jsonb_build_object(
    'barbeiros', (select coalesce(jsonb_agg(to_jsonb(pb) order by pb.ordem), '[]') from pb),
    'agendamentos', (select coalesce(jsonb_agg(jsonb_build_object('nome', ag.cliente_nome, 'telefone', ag.cliente_telefone,
        'barbeiro', ag.barbeiro_nome, 'data', ag.data, 'inicio', to_char(ag.inicio, 'HH24:MI'), 'servico', ag.servico_nome,
        'preco', ag.preco_centavos, 'status', case when ag.abandonado then 'pix_abandonado' else ag.status end,
        'sinal_status', ag.sinal_status, 'origem', ag.origem) order by ag.data desc, ag.inicio desc), '[]')
        from ag),
    'assinantes', (select coalesce(jsonb_agg(jsonb_build_object('nome', s.nome, 'barbeiro', coalesce(b.nome, 'Qualquer'),
        'plano', p.nome, 'status', s.status, 'vence_em', s.vence_em, 'cortesia', s.cortesia,
        'saldo', case when s.status = 'ativo' then public.saldo_plano(s.id) else '{}'::jsonb end, 'cotas', p.cotas,
        'usou_no_periodo', (select count(*) from public.agendamentos x where x.assinante_id = s.id and x.data between p_ini and p_fim
                             and x.status in ('confirmado','concluido','faltou'))) order by b.ordem nulls first, s.nome), '[]')
        from public.assinantes s join public.planos p on p.id = s.plano_id left join public.barbeiros b on b.id = s.barbeiro_id
       where s.status in ('ativo','vencido'))
  ) into v;
  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array['e_gestor()', 'e_gestor_rpc()', 'e_socio()', 'atualiza_ciclo(uuid)', 'cobranca_aberta(uuid)', 'avisos_planos()',
    'meu_plano()', 'marca_plano(uuid,uuid[],uuid,date,time,integer,text,text,boolean)',
    'agendar_pelo_plano(uuid[],date,time,text,uuid)', 'agendar_plano_painel(uuid,uuid,date,time,integer)',
    'lista_assinantes()', 'painel_master(date,date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;
grant execute on function public.e_socio()                                        to authenticated;
grant execute on function public.e_gestor_rpc()                                   to authenticated;
grant execute on function public.meu_plano()                                      to authenticated;
grant execute on function public.agendar_pelo_plano(uuid[],date,time,text,uuid)    to authenticated;
grant execute on function public.agendar_plano_painel(uuid,uuid,date,time,integer) to authenticated;
grant execute on function public.lista_assinantes()                               to authenticated;
grant execute on function public.painel_master(date,date)                         to authenticated;
grant execute on function public.cobranca_aberta(uuid)                            to service_role;
grant execute on function public.avisos_planos()                                  to service_role;

-- ---------------------------------------------------------------------
-- Dados
-- ---------------------------------------------------------------------
insert into public.gestores (email, nome) values ('nathamgil10@gmail.com', 'Natham') on conflict (email) do nothing;

-- plano de parceria (Zync): não aparece no site, não cobra
insert into public.planos (slug, nome, preco_centavos, itens, cotas, destaque, ordem, ativo) values
  ('parceria', 'Parceria Zync', 0, array['3 cortes, 3 barbas e 3 sobrancelhas por mês'], '{"corte":3,"barba":3,"sobrancelha":3}', false, 9, false)
on conflict (slug) do update set nome = excluded.nome, preco_centavos = excluded.preco_centavos, itens = excluded.itens,
  cotas = excluded.cotas, ativo = false;
update public.planos set pacote = array(select id from public.servicos where slug in ('corte-barba','sobrancelha') order by ordem)
 where slug = 'parceria';

insert into public.assinantes (nome, email, plano_id, barbeiro_id, status, ciclo_inicio, vence_em, origem, cortesia)
select 'Natham', 'nathamgil10@gmail.com', p.id, null, 'ativo', date '2026-10-26', date '2026-11-26', 'balcao', true
  from public.planos p where p.slug = 'parceria'
on conflict ((lower(email))) do nothing;
