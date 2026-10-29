-- =====================================================================
--  Trevus Barbearia — PLANOS v3 (29/10/2026)
--  Rode DEPOIS de planos-v2.sql. Pode rodar de novo.
--
--    · Editar assinante pelo painel: dados, plano, barbeiro, vencimento,
--      situação, "próximo mês pago", observação e saldo do mês.
--    · Saldo: o ajuste vale só para o ciclo em que foi feito.
--    · A lista do painel mostra também quem comprou no site e não pagou.
--    · Excluir assinante (só quem nunca marcou horário pelo plano).
-- =====================================================================

alter table public.assinantes add column if not exists obs text;
alter table public.assinantes add column if not exists ajuste jsonb not null default '{}';
alter table public.assinantes add column if not exists ajuste_ciclo date;

-- saldo sem o piso de zero (usado para calcular o ajuste)
create or replace function public.saldo_bruto(p_assinante uuid, p_data date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.assinantes%rowtype; p public.planos%rowtype; v_ini date; v_fim date; v_uso jsonb; k text; v_out jsonb := '{}';
        v_aj jsonb;
begin
  select * into a from public.assinantes where id = p_assinante;
  if not found or a.ciclo_inicio is null then return '{}'; end if;
  select * into p from public.planos where id = a.plano_id;
  p_data := coalesce(p_data, public.agora_bahia()::date);
  if p_data >= a.vence_em then
    v_ini := a.vence_em; v_fim := (a.vence_em + interval '1 month')::date;
  else
    v_ini := a.ciclo_inicio; v_fim := a.vence_em;
  end if;
  v_aj := case when a.ajuste_ciclo = v_ini then coalesce(a.ajuste, '{}') else '{}' end;
  select coalesce(jsonb_object_agg(chave, total), '{}') into v_uso from (
    select c.key as chave, sum(c.value::integer) as total
      from public.agendamentos ag, jsonb_each_text(coalesce(ag.consumo, '{}')) c
     where ag.assinante_id = a.id and ag.data >= v_ini and ag.data < v_fim
       and ag.status in ('confirmado','concluido','faltou')
     group by c.key) x;
  for k in select jsonb_object_keys(p.cotas) loop
    v_out := v_out || jsonb_build_object(k, (p.cotas->>k)::integer + coalesce((v_aj->>k)::integer, 0) - coalesce((v_uso->>k)::integer, 0));
  end loop;
  return v_out;
end;
$$;

create or replace function public.saldo_plano(p_assinante uuid, p_data date default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(key, greatest(0, value::integer)), '{}')
    from jsonb_each_text(public.saldo_bruto(p_assinante, p_data));
$$;

-- ---------------------------------------------------------------------
-- Lista do painel (agora com tudo que a edição precisa)
-- ---------------------------------------------------------------------
drop function if exists public.lista_assinantes();
create or replace function public.lista_assinantes()
returns table (id uuid, nome text, telefone text, email text, foto text, status text, vence_em date, proximo_pago boolean,
               plano text, barbeiro_id uuid, barbeiro text, saldo jsonb, cotas jsonb, tem_acesso boolean, origem text, cortesia boolean,
               plano_id uuid, ciclo_inicio date, obs text, criado_em timestamptz)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  perform public.atualiza_ciclos();
  return query
    select a.id, a.nome, a.telefone, a.email, a.foto, a.status, a.vence_em, a.proximo_pago, p.nome, a.barbeiro_id,
           coalesce(b.nome, 'Qualquer barbeiro'),
           case when a.status = 'ativo' then public.saldo_plano(a.id) else '{}'::jsonb end, p.cotas,
           a.user_id is not null, a.origem, a.cortesia, a.plano_id, a.ciclo_inicio, a.obs, a.criado_em
      from public.assinantes a join public.planos p on p.id = a.plano_id left join public.barbeiros b on b.id = a.barbeiro_id
     order by case a.status when 'vencido' then 0 when 'ativo' then 1 when 'aguardando_pagamento' then 2 else 3 end,
              a.vence_em nulls last, a.nome;
end;
$$;

-- ---------------------------------------------------------------------
-- Editar assinante (painel). p_saldo = saldo que deve ficar no mês atual
-- (nulo = não mexe). Devolve true se o e-mail foi cadastrado agora.
-- ---------------------------------------------------------------------
drop function if exists public.editar_assinante(uuid,text,text,text,uuid,uuid,date,text,boolean,text,jsonb);
create or replace function public.editar_assinante(
  p_id uuid, p_nome text, p_telefone text, p_email text, p_plano uuid, p_barbeiro uuid,
  p_vence date, p_status text, p_proximo_pago boolean, p_obs text, p_saldo jsonb default null)
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare a public.assinantes%rowtype; v_hoje date := public.agora_bahia()::date;
        v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
        v_tel text := nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), '');
        v_atual jsonb; v_aj jsonb; k text; v_novo boolean;
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  select * into a from public.assinantes where id = p_id for update;
  if not found then raise exception 'NAO_ACHEI' using hint = 'Assinante não encontrado.'; end if;
  if length(trim(coalesce(p_nome, ''))) < 2 then raise exception 'NOME' using hint = 'Escreva o nome.'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'EMAIL' using hint = 'Esse e-mail não parece certo.'; end if;
  if v_email is not null and exists (select 1 from public.assinantes where lower(email) = v_email and id <> p_id) then
    raise exception 'EMAIL_DUP' using hint = 'Esse e-mail já está em outro assinante.'; end if;
  if v_tel is not null and (length(v_tel) < 10 or length(v_tel) > 13) then raise exception 'TEL' using hint = 'WhatsApp com DDD, só números.'; end if;
  if p_status not in ('ativo','vencido','cancelado','aguardando_pagamento') then raise exception 'STATUS'; end if;
  if not exists (select 1 from public.planos where id = p_plano) then raise exception 'PLANO' using hint = 'Escolha o plano.'; end if;
  if p_barbeiro is not null and not exists (select 1 from public.barbeiros where id = p_barbeiro) then raise exception 'BARBEIRO'; end if;
  if p_status = 'ativo' and (p_vence is null or p_vence <= v_hoje) then
    raise exception 'VENCE' using hint = 'Para deixar ativo, o vencimento tem que ser depois de hoje.'; end if;

  v_novo := v_email is not null and a.email is null and a.user_id is null;
  update public.assinantes set
    nome = trim(p_nome), telefone = v_tel, email = v_email, plano_id = p_plano, barbeiro_id = p_barbeiro,
    status = p_status, proximo_pago = coalesce(p_proximo_pago, false) and p_status = 'ativo',
    vence_em = p_vence,
    ciclo_inicio = case when p_vence is null then null
                        when p_vence is distinct from a.vence_em or a.ciclo_inicio is null then (p_vence - interval '1 month')::date
                        else a.ciclo_inicio end,
    obs = nullif(trim(coalesce(p_obs, '')), ''),
    ultimo_aviso = case when p_vence is distinct from a.vence_em then null else ultimo_aviso end
  where id = p_id;

  if p_saldo is not null and p_status = 'ativo' then
    select * into a from public.assinantes where id = p_id;
    v_atual := public.saldo_bruto(p_id);
    v_aj := case when a.ajuste_ciclo = a.ciclo_inicio then coalesce(a.ajuste, '{}') else '{}' end;
    for k in select jsonb_object_keys(p_saldo) loop
      if v_atual ? k then
        v_aj := v_aj || jsonb_build_object(k, coalesce((v_aj->>k)::integer, 0) + greatest(0, (p_saldo->>k)::integer) - (v_atual->>k)::integer);
      end if;
    end loop;
    update public.assinantes set ajuste = v_aj, ajuste_ciclo = a.ciclo_inicio where id = p_id;
  end if;

  return v_novo;
end;
$$;

create or replace function public.excluir_assinante(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  if exists (select 1 from public.agendamentos where assinante_id = p_id) then
    raise exception 'TEM_HORARIOS' using hint = 'Esse assinante já marcou horário pelo plano. Use "Cancelar" em vez de excluir.'; end if;
  delete from public.assinantes where id = p_id;
end;
$$;

do $$ declare f text; begin
  foreach f in array array['saldo_bruto(uuid,date)', 'saldo_plano(uuid,date)', 'lista_assinantes()',
    'editar_assinante(uuid,text,text,text,uuid,uuid,date,text,boolean,text,jsonb)', 'excluir_assinante(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;
grant execute on function public.saldo_bruto(uuid,date) to service_role;
grant execute on function public.saldo_plano(uuid,date) to service_role;
grant execute on function public.lista_assinantes() to authenticated;
grant execute on function public.editar_assinante(uuid,text,text,text,uuid,uuid,date,text,boolean,text,jsonb) to authenticated;
grant execute on function public.excluir_assinante(uuid) to authenticated;
