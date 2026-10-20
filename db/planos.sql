-- =====================================================================
--  Trevus Barbearia — PLANOS MENSAIS (assinatura)
--  Rode DEPOIS do schema.sql, no SQL Editor do Supabase. Pode rodar de novo.
--
--  Como funciona (combinado em 20/10/2026):
--    · O cliente compra o plano no site e paga o mês INTEIRO (Pix ou cartão)
--      na InfinitePay do barbeiro que ele escolheu. O plano vale com esse
--      barbeiro.
--    · A data da compra vira o dia do vencimento, todo mês.
--    · A InfinitePay não debita sozinha: 3 dias e 1 dia antes do vencimento
--      o cliente recebe o link do mês por e-mail. Não pagou até o
--      vencimento, o plano trava (saldo zerado) até pagar.
--    · Pagou de novo depois de travar: o vencimento passa a ser o dia do
--      novo pagamento.
--    · O saldo renova a cada ciclo. Horário cancelado devolve o saldo;
--      falta ("Não veio") conta como usado.
--    · A barbearia também cadastra assinante que pagou no balcão.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. SEGURANÇA: cliente agora também tem login. "Estar logado" deixa de
--    significar "ser sócio".
-- ---------------------------------------------------------------------
create or replace function public.e_socio()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.barbeiros where user_id = auth.uid());
$$;

do $$
declare t text;
begin
  foreach t in array array['barbeiros','servicos','expediente','feriados','bloqueios','agendamentos','creditos','descontos'] loop
    execute format('drop policy if exists %1$s_admin on public.%1$s', t);
    execute format('create policy %1$s_admin on public.%1$s for all to authenticated using (public.e_socio()) with check (public.e_socio())', t);
  end loop;
  -- cliente logado enxerga o mesmo que o visitante
  foreach t in array array['barbeiros','servicos','expediente','feriados'] loop
    execute format('drop policy if exists %1$s_leitura_logado on public.%1$s', t);
  end loop;
end $$;
create policy barbeiros_leitura_logado  on public.barbeiros  for select to authenticated using (ativo);
create policy servicos_leitura_logado   on public.servicos   for select to authenticated using (ativo);
create policy expediente_leitura_logado on public.expediente for select to authenticated using (true);
create policy feriados_leitura_logado   on public.feriados   for select to authenticated using (true);

-- desmarcar pelo painel: só sócio
create or replace function public.desmarcar_pela_barbearia(p_id uuid)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare a public.agendamentos%rowtype; v_tarde boolean;
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS' using hint = 'Só a equipe desmarca pelo painel.'; end if;
  select * into a from public.agendamentos where id = p_id for update;
  if not found or a.status <> 'confirmado' then return 'NAO_DESMARCAVEL'; end if;
  v_tarde := (a.data + a.inicio) < public.agora_bahia() + interval '1 hour';
  update public.agendamentos
     set status = 'cancelado', cancelado_em = now(),
         sinal_status = case when a.sinal_status = 'pago' then 'devolver'
                             when a.sinal_status = 'credito' then 'virou_credito' else a.sinal_status end
   where id = a.id;
  if a.sinal_status in ('pago','credito') and a.credito_usado > 0 then
    insert into public.creditos (telefone, barbeiro_id, valor_centavos, saldo_centavos, origem_agendamento)
    values (a.cliente_telefone, a.barbeiro_id, a.credito_usado, a.credito_usado, a.id);
  end if;
  if v_tarde and a.origem = 'site' then
    insert into public.descontos (telefone, pct, origem_agendamento) values (a.cliente_telefone, 10, a.id);
    return 'DESMARCADO_COM_DESCONTO';
  end if;
  return 'DESMARCADO';
end;
$$;

-- ---------------------------------------------------------------------
-- 1. PLANOS e o que cada serviço consome do saldo
-- ---------------------------------------------------------------------
create table if not exists public.planos (
  id             uuid primary key default gen_random_uuid(),
  slug           text unique not null,
  nome           text not null,
  preco_centavos integer not null check (preco_centavos > 0),
  itens          text[] not null default '{}',      -- o que aparece no cartão do site
  cotas          jsonb not null default '{}',       -- {"corte":4,"barba":4}
  destaque       boolean not null default false,
  ordem          integer not null default 0,
  ativo          boolean not null default true
);

-- nulo = o plano não cobre esse serviço
alter table public.servicos add column if not exists consome jsonb;

-- ---------------------------------------------------------------------
-- 2. ASSINANTES e PAGAMENTOS DO PLANO
--    status: aguardando_pagamento (comprou, ainda não pagou) | ativo |
--            vencido (travado) | cancelado
-- ---------------------------------------------------------------------
create table if not exists public.assinantes (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid unique references auth.users(id) on delete set null,
  nome           text not null,
  telefone       text not null,
  email          text not null,
  foto           text,
  plano_id       uuid not null references public.planos(id),
  barbeiro_id    uuid not null references public.barbeiros(id),
  status         text not null default 'aguardando_pagamento'
                 check (status in ('aguardando_pagamento','ativo','vencido','cancelado')),
  ciclo_inicio   date,
  vence_em       date,
  proximo_pago   boolean not null default false,  -- já pagou o ciclo seguinte
  origem         text not null default 'site' check (origem in ('site','balcao')),
  ultimo_aviso   text,                              -- "2026-11-20:d3": evita e-mail repetido
  acesso_enviado_em timestamptz,                    -- último e-mail de criar senha
  criado_em      timestamptz not null default now()
);
create unique index if not exists assinantes_email_idx on public.assinantes (lower(email));

create table if not exists public.pagamentos_plano (
  id             uuid primary key default gen_random_uuid(),
  assinante_id   uuid not null references public.assinantes(id) on delete cascade,
  valor_centavos integer not null check (valor_centavos > 0),
  status         text not null default 'pendente' check (status in ('pendente','pago','cancelado')),
  forma          text not null default 'site' check (forma in ('site','balcao')),
  pagamento      jsonb,
  pago_em        timestamptz,
  criado_em      timestamptz not null default now()
);
create index if not exists pagamentos_plano_ass_idx on public.pagamentos_plano (assinante_id, status);

-- horário marcado pelo plano
alter table public.agendamentos add column if not exists assinante_id uuid references public.assinantes(id);
alter table public.agendamentos add column if not exists consumo jsonb;
alter table public.agendamentos drop constraint if exists agendamentos_sinal_status_check;
alter table public.agendamentos add constraint agendamentos_sinal_status_check
  check (sinal_status in ('pendente','pago','credito','isento','virou_credito','retido','devolver','devolvido','plano'));
create index if not exists agendamentos_assinante_idx on public.agendamentos (assinante_id, data);

alter table public.planos           enable row level security;
alter table public.assinantes       enable row level security;
alter table public.pagamentos_plano enable row level security;

drop policy if exists planos_leitura        on public.planos;
drop policy if exists planos_admin          on public.planos;
drop policy if exists assinantes_admin      on public.assinantes;
drop policy if exists assinantes_eu         on public.assinantes;
drop policy if exists pagamentos_plano_admin on public.pagamentos_plano;
create policy planos_leitura   on public.planos for select to anon, authenticated using (ativo);
create policy planos_admin     on public.planos for all to authenticated using (public.e_socio()) with check (public.e_socio());
create policy assinantes_admin on public.assinantes for all to authenticated using (public.e_socio()) with check (public.e_socio());
create policy assinantes_eu    on public.assinantes for select to authenticated using (user_id = auth.uid());
create policy pagamentos_plano_admin on public.pagamentos_plano for all to authenticated using (public.e_socio()) with check (public.e_socio());

-- ---------------------------------------------------------------------
-- 3. CICLO: vira o mês (se já pagou) ou trava (se não pagou)
-- ---------------------------------------------------------------------
create or replace function public.atualiza_ciclo(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a public.assinantes%rowtype; v_hoje date := public.agora_bahia()::date;
begin
  select * into a from public.assinantes where id = p_id for update;
  if not found or a.status <> 'ativo' then return; end if;
  while a.vence_em is not null and v_hoje >= a.vence_em loop
    if a.proximo_pago then
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

create or replace function public.atualiza_ciclos()
returns integer language plpgsql volatile security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id from public.assinantes where status = 'ativo' and vence_em <= public.agora_bahia()::date loop
    perform public.atualiza_ciclo(r.id); n := n + 1;
  end loop;
  return n;
end;
$$;

-- Saldo do ciclo que contém o dia p_data: cota do plano menos o que já foi
-- marcado nesse ciclo (cancelado não conta; falta conta).
create or replace function public.saldo_plano(p_assinante uuid, p_data date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.assinantes%rowtype; p public.planos%rowtype; v_ini date; v_fim date; v_uso jsonb; k text; v_out jsonb := '{}';
begin
  select * into a from public.assinantes where id = p_assinante;
  if not found or a.ciclo_inicio is null then return '{}'; end if;
  select * into p from public.planos where id = a.plano_id;
  p_data := coalesce(p_data, public.agora_bahia()::date);
  if p_data >= a.vence_em then           -- ciclo seguinte (só se já pago)
    v_ini := a.vence_em; v_fim := (a.vence_em + interval '1 month')::date;
  else
    v_ini := a.ciclo_inicio; v_fim := a.vence_em;
  end if;
  select coalesce(jsonb_object_agg(chave, total), '{}') into v_uso from (
    select c.key as chave, sum(c.value::integer) as total
      from public.agendamentos ag, jsonb_each_text(coalesce(ag.consumo, '{}')) c
     where ag.assinante_id = a.id and ag.data >= v_ini and ag.data < v_fim
       and ag.status in ('confirmado','concluido','faltou')
     group by c.key) x;
  for k in select jsonb_object_keys(p.cotas) loop
    v_out := v_out || jsonb_build_object(k, greatest(0, (p.cotas->>k)::integer - coalesce((v_uso->>k)::integer, 0)));
  end loop;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. COMPRA PELO SITE (visitante)
-- ---------------------------------------------------------------------
create or replace function public.comprar_plano(p_plano uuid, p_barbeiro uuid, p_nome text, p_telefone text, p_email text)
returns uuid    -- id do pagamento (a função "pagamento" gera o link)
language plpgsql volatile security definer set search_path = public as $$
declare
  v_tel   text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_nome  text := btrim(coalesce(p_nome, ''));
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_pl    public.planos%rowtype;
  a       public.assinantes%rowtype;
  v_pg    uuid;
begin
  if length(v_nome) < 2 or length(v_nome) > 80 then raise exception 'NOME_INVALIDO' using hint = 'Informe seu nome.'; end if;
  if length(v_tel) < 10 or length(v_tel) > 13 then raise exception 'TELEFONE_INVALIDO' using hint = 'Informe um WhatsApp com DDD.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'EMAIL_INVALIDO' using hint = 'Informe um e-mail válido: é nele que chega o seu acesso.'; end if;
  select * into v_pl from public.planos where id = p_plano and ativo;
  if not found then raise exception 'PLANO_INVALIDO' using hint = 'Escolha um plano.'; end if;
  if not exists (select 1 from public.barbeiros where id = p_barbeiro and ativo and infinitepay_handle is not null) then
    raise exception 'BARBEIRO_INVALIDO' using hint = 'Escolha o seu barbeiro.';
  end if;

  select * into a from public.assinantes where lower(email) = v_email for update;
  if found and a.status in ('ativo','vencido') then
    raise exception 'JA_ASSINANTE' using hint = 'Esse e-mail já tem plano. Entre na Área do assinante para ver ou renovar.';
  end if;

  if found then   -- tentativa anterior abandonada ou plano cancelado: reaproveita
    update public.assinantes set nome = v_nome, telefone = v_tel, plano_id = v_pl.id, barbeiro_id = p_barbeiro,
           status = 'aguardando_pagamento', ciclo_inicio = null, vence_em = null, proximo_pago = false, origem = 'site'
     where id = a.id;
    update public.pagamentos_plano set status = 'cancelado' where assinante_id = a.id and status = 'pendente';
  else
    insert into public.assinantes (nome, telefone, email, plano_id, barbeiro_id)
    values (v_nome, v_tel, v_email, v_pl.id, p_barbeiro) returning * into a;
  end if;

  insert into public.pagamentos_plano (assinante_id, valor_centavos) values (a.id, v_pl.preco_centavos) returning id into v_pg;
  return v_pg;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. PAGAMENTO CONFIRMADO (só a função "pagamento", depois do payment_check)
-- ---------------------------------------------------------------------
create or replace function public.registrar_pagamento_plano(p_id uuid, p_pago integer, p_dados jsonb, p_forma text default 'site')
returns text
language plpgsql volatile security definer set search_path = public as $$
declare pg public.pagamentos_plano%rowtype; a public.assinantes%rowtype; v_hoje date := public.agora_bahia()::date; v_res text;
begin
  select * into pg from public.pagamentos_plano where id = p_id for update;
  if not found then return 'NAO_ENCONTRADO'; end if;
  if pg.status = 'pago' then return 'JA_PAGO'; end if;
  if p_pago < pg.valor_centavos then return 'VALOR_MENOR'; end if;
  perform public.atualiza_ciclo(pg.assinante_id);
  select * into a from public.assinantes where id = pg.assinante_id for update;

  if a.status = 'ativo' and v_hoje < a.vence_em and not a.proximo_pago then
    update public.assinantes set proximo_pago = true where id = a.id;           -- pagou adiantado
    v_res := 'RENOVADO';
  elsif a.status = 'ativo' and a.proximo_pago then
    v_res := 'JA_ADIANTADO';                                                  -- dois pagamentos no mesmo ciclo
  else
    update public.assinantes set status = 'ativo', ciclo_inicio = v_hoje,
           vence_em = (v_hoje + interval '1 month')::date, proximo_pago = false
     where id = a.id;                                                          -- 1º pagamento ou reativação
    v_res := case when a.status = 'aguardando_pagamento' then 'ATIVADO' else 'REATIVADO' end;
  end if;

  update public.pagamentos_plano set status = 'pago', pago_em = now(), pagamento = p_dados, forma = coalesce(p_forma, 'site')
   where id = pg.id;
  return v_res;
end;
$$;

-- Cobrança do mês: devolve o pagamento pendente (cria se não houver).
create or replace function public.cobranca_aberta(p_assinante uuid)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare a public.assinantes%rowtype; v uuid;
begin
  perform public.atualiza_ciclo(p_assinante);
  select * into a from public.assinantes where id = p_assinante;
  if not found or a.status = 'cancelado' then return null; end if;
  if a.status = 'ativo' and a.proximo_pago then return null; end if;           -- já está pago
  select id into v from public.pagamentos_plano where assinante_id = a.id and status = 'pendente' order by criado_em desc limit 1;
  if v is null then
    insert into public.pagamentos_plano (assinante_id, valor_centavos)
    select a.id, p.preco_centavos from public.planos p where p.id = a.plano_id returning id into v;
  end if;
  return v;
end;
$$;

-- Lista do lembrete diário: d3 e d1 = vence em 3 / 1 dia; venceu = travou.
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
     where t.tipo is not null
       and coalesce(a.ultimo_aviso, '') <> a.vence_em::text || ':' || t.tipo;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. ÁREA DO ASSINANTE (cliente logado)
-- ---------------------------------------------------------------------
create or replace function public.meu_plano()
returns table (id uuid, nome text, email text, telefone text, foto text, status text, ciclo_inicio date, vence_em date,
               proximo_pago boolean, plano text, plano_preco integer, cotas jsonb, saldo jsonb,
               barbeiro_id uuid, barbeiro text, barbeiro_foto text, socio boolean)
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
           b.id, b.nome, b.foto, public.e_socio()
      from public.assinantes a
      join public.planos p on p.id = a.plano_id
      join public.barbeiros b on b.id = a.barbeiro_id
     where a.id = v_id;
end;
$$;

create or replace function public.salvar_minha_foto(p_url text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if p_url is not null and p_url !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/clientes/' then
    raise exception 'FOTO_INVALIDA';
  end if;
  update public.assinantes set foto = p_url where user_id = auth.uid();
end;
$$;

-- Marca pelo plano: só serviços que o plano cobre, com o barbeiro do plano,
-- dentro do ciclo pago e com saldo. Sai confirmado, sem sinal.
create or replace function public.agendar_pelo_plano(p_servicos uuid[], p_data date, p_inicio time, p_obs text default null)
returns table (id uuid, codigo text, barbeiro text, servico text, dia date, inicio time, fim time)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  a public.assinantes%rowtype; p public.planos%rowtype;
  v_lista jsonb; v_nomes text; v_total integer; v_dur integer; v_consumo jsonb := '{}'; v_saldo jsonb;
  s record; k text; v_id uuid; v_limite date;
begin
  select * into a from public.assinantes where user_id = auth.uid();
  if not found then raise exception 'SEM_PLANO' using hint = 'Essa conta não tem plano.'; end if;
  perform public.atualiza_ciclo(a.id);
  select * into a from public.assinantes where id = a.id;
  if a.status <> 'ativo' then
    raise exception 'PLANO_TRAVADO' using hint = 'Seu plano está com a mensalidade em aberto. Pague para voltar a marcar.';
  end if;
  v_limite := case when a.proximo_pago then (a.vence_em + interval '1 month')::date else a.vence_em end;
  if p_data >= v_limite then
    raise exception 'FORA_DO_CICLO' using hint = 'Esse dia já cai no próximo mês do plano. Pague a mensalidade para liberar.';
  end if;
  select * into p from public.planos where id = a.plano_id;

  for s in select * from public.servicos sv where sv.ativo and sv.id = any(p_servicos) loop
    if s.consome is null then
      raise exception 'NAO_COBERTO' using hint = s.nome || ' não está no plano. Marque esse serviço pelo agendamento normal.';
    end if;
    for k in select jsonb_object_keys(s.consome) loop
      if coalesce((p.cotas->>k)::integer, 0) = 0 then
        raise exception 'NAO_COBERTO' using hint = s.nome || ' não está no seu plano.';
      end if;
      v_consumo := v_consumo || jsonb_build_object(k, coalesce((v_consumo->>k)::integer, 0) + (s.consome->>k)::integer);
    end loop;
  end loop;
  if v_consumo = '{}'::jsonb then raise exception 'SERVICO_INVALIDO' using hint = 'Escolha pelo menos um serviço.'; end if;

  v_saldo := public.saldo_plano(a.id, p_data);
  for k in select jsonb_object_keys(v_consumo) loop
    if (v_consumo->>k)::integer > coalesce((v_saldo->>k)::integer, 0) then
      raise exception 'SEM_SALDO' using hint = 'Seu saldo de ' || k || ' deste mês acabou.';
    end if;
  end loop;

  if not public.barbeiro_faz(p_servicos, a.barbeiro_id) then
    raise exception 'SERVICO_INVALIDO' using hint = 'Seu barbeiro não faz um desses serviços.';
  end if;

  select jsonb_agg(jsonb_build_object('id', sv.id, 'nome', sv.nome, 'preco_centavos', sv.preco_centavos, 'duracao_min', sv.duracao_min) order by sv.ordem),
         string_agg(sv.nome, ' + ' order by sv.ordem), sum(sv.preco_centavos)::integer, sum(sv.duracao_min)::integer
    into v_lista, v_nomes, v_total, v_dur
    from public.servicos sv where sv.ativo and sv.id = any(p_servicos);

  if not exists (select 1 from public.slots_barbeiro(p_data, v_dur, a.barbeiro_id) x where x = p_inicio) then
    raise exception 'HORARIO_INDISPONIVEL' using hint = 'Esse horário acabou de ser ocupado. Escolha outro.';
  end if;

  insert into public.agendamentos (codigo, barbeiro_id, barbeiro_nome, servicos, servico_nome, preco_centavos, duracao_min,
    sinal_centavos, sinal_status, cliente_nome, cliente_telefone, cliente_email, data, inicio, fim, status,
    observacao, assinante_id, consumo)
  select public.novo_codigo(), b.id, b.nome, v_lista, v_nomes, v_total, v_dur,
         0, 'plano', a.nome, a.telefone, a.email, p_data, p_inicio, p_inicio + make_interval(mins => v_dur), 'confirmado',
         nullif(btrim(p_obs), ''), a.id, v_consumo
    from public.barbeiros b where b.id = a.barbeiro_id
  returning agendamentos.id into v_id;

  return query select ag.id, ag.codigo, ag.barbeiro_nome, ag.servico_nome, ag.data, ag.inicio, ag.fim
                 from public.agendamentos ag where ag.id = v_id;
end;
$$;

create or replace function public.meus_horarios()
returns table (id uuid, codigo text, barbeiro text, servico text, dia date, inicio time, fim time, status text, pode_cancelar boolean)
language sql stable security definer set search_path = public as $$
  select ag.id, ag.codigo, ag.barbeiro_nome, ag.servico_nome, ag.data, ag.inicio, ag.fim, ag.status,
         ag.status = 'confirmado' and (ag.data + ag.inicio) >= public.agora_bahia() + interval '1 hour'
    from public.agendamentos ag join public.assinantes a on a.id = ag.assinante_id
   where a.user_id = auth.uid() and ag.status = 'confirmado' and ag.data >= public.agora_bahia()::date
   order by ag.data, ag.inicio;
$$;

create or replace function public.cancelar_pelo_plano(p_id uuid)
returns text language plpgsql volatile security definer set search_path = public as $$
declare ag public.agendamentos%rowtype;
begin
  select ag2.* into ag from public.agendamentos ag2 join public.assinantes a on a.id = ag2.assinante_id
   where ag2.id = p_id and a.user_id = auth.uid() for update of ag2;
  if not found then raise exception 'NAO_ENCONTRADO' using hint = 'Horário não encontrado.'; end if;
  if ag.status <> 'confirmado' then return 'JA_CANCELADO'; end if;
  if (ag.data + ag.inicio) < public.agora_bahia() + interval '1 hour' then
    raise exception 'PRAZO_ESGOTADO' using hint = 'O cancelamento pelo site vai até 1h antes. Fale no WhatsApp.';
  end if;
  update public.agendamentos set status = 'cancelado', cancelado_em = now() where id = ag.id;
  return 'CANCELADO';   -- o saldo volta sozinho: cancelado não conta
end;
$$;

-- Cobrança do mês pelo próprio assinante (botão "Pagar mensalidade").
create or replace function public.minha_cobranca()
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from public.assinantes where user_id = auth.uid();
  if v is null then raise exception 'SEM_PLANO' using hint = 'Essa conta não tem plano.'; end if;
  return public.cobranca_aberta(v);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. PAINEL (sócios)
-- ---------------------------------------------------------------------
create or replace function public.cadastrar_assinante_balcao(p_plano uuid, p_barbeiro uuid, p_nome text, p_telefone text, p_email text)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare v_pg uuid; v_ass uuid;
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  -- aceita o barbeiro mesmo sem InfiniteTag: o pagamento foi no balcão
  v_pg := public.comprar_plano(p_plano, p_barbeiro, p_nome, p_telefone, p_email);
  select assinante_id into v_ass from public.pagamentos_plano where id = v_pg;
  update public.assinantes set origem = 'balcao' where id = v_ass;
  perform public.registrar_pagamento_plano(v_pg, 2147483647, jsonb_build_object('registrado_por', auth.uid()), 'balcao');
  return v_ass;
end;
$$;

create or replace function public.pagamento_balcao(p_assinante uuid)
returns text language plpgsql volatile security definer set search_path = public as $$
declare v_pg uuid;
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  v_pg := public.cobranca_aberta(p_assinante);
  if v_pg is null then return 'NADA_A_PAGAR'; end if;
  return public.registrar_pagamento_plano(v_pg, 2147483647, jsonb_build_object('registrado_por', auth.uid()), 'balcao');
end;
$$;

create or replace function public.lista_assinantes()
returns table (id uuid, nome text, telefone text, email text, foto text, status text, vence_em date, proximo_pago boolean,
               plano text, barbeiro_id uuid, barbeiro text, saldo jsonb, cotas jsonb, tem_acesso boolean, origem text)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  perform public.atualiza_ciclos();
  return query
    select a.id, a.nome, a.telefone, a.email, a.foto, a.status, a.vence_em, a.proximo_pago, p.nome, b.id, b.nome,
           case when a.status = 'ativo' then public.saldo_plano(a.id) else '{}'::jsonb end, p.cotas,
           a.user_id is not null, a.origem
      from public.assinantes a join public.planos p on p.id = a.plano_id join public.barbeiros b on b.id = a.barbeiro_id
     where a.status <> 'aguardando_pagamento'
     order by case a.status when 'vencido' then 0 when 'ativo' then 1 else 2 end, a.vence_em nulls last, a.nome;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. PERMISSÕES
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'e_socio()', 'atualiza_ciclo(uuid)', 'atualiza_ciclos()', 'saldo_plano(uuid,date)',
    'comprar_plano(uuid,uuid,text,text,text)', 'registrar_pagamento_plano(uuid,integer,jsonb,text)',
    'cobranca_aberta(uuid)', 'avisos_planos()', 'meu_plano()', 'salvar_minha_foto(text)',
    'agendar_pelo_plano(uuid[],date,time,text)', 'meus_horarios()', 'cancelar_pelo_plano(uuid)', 'minha_cobranca()',
    'cadastrar_assinante_balcao(uuid,uuid,text,text,text)', 'pagamento_balcao(uuid)', 'lista_assinantes()',
    'desmarcar_pela_barbearia(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

grant execute on function public.comprar_plano(uuid,uuid,text,text,text)       to anon, authenticated;
grant execute on function public.e_socio()                                     to authenticated;
grant execute on function public.meu_plano()                                   to authenticated;
grant execute on function public.salvar_minha_foto(text)                       to authenticated;
grant execute on function public.agendar_pelo_plano(uuid[],date,time,text)      to authenticated;
grant execute on function public.meus_horarios()                               to authenticated;
grant execute on function public.cancelar_pelo_plano(uuid)                     to authenticated;
grant execute on function public.minha_cobranca()                              to authenticated;
grant execute on function public.cadastrar_assinante_balcao(uuid,uuid,text,text,text) to authenticated;
grant execute on function public.pagamento_balcao(uuid)                        to authenticated;
grant execute on function public.lista_assinantes()                            to authenticated;
grant execute on function public.desmarcar_pela_barbearia(uuid)                to authenticated;
grant execute on function public.registrar_pagamento_plano(uuid,integer,jsonb,text) to service_role;
grant execute on function public.cobranca_aberta(uuid)                         to service_role;
grant execute on function public.avisos_planos()                               to service_role;
grant execute on function public.atualiza_ciclos()                             to service_role;
grant execute on function public.saldo_plano(uuid,date)                        to service_role;

-- ---------------------------------------------------------------------
-- 9. FOTO DO ASSINANTE (Supabase Storage, bucket público "clientes")
--    Cada um só grava na própria pasta: clientes/<id do login>/...
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('clientes', 'clientes', true, 2097152, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do update set public = true, file_size_limit = 2097152,
      allowed_mime_types = array['image/jpeg','image/png','image/webp'];
    execute 'drop policy if exists clientes_grava_propria on storage.objects';
    execute 'drop policy if exists clientes_troca_propria on storage.objects';
    execute 'drop policy if exists clientes_apaga_propria on storage.objects';
    execute $p$create policy clientes_grava_propria on storage.objects for insert to authenticated
             with check (bucket_id = 'clientes' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
    execute $p$create policy clientes_troca_propria on storage.objects for update to authenticated
             using (bucket_id = 'clientes' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
    execute $p$create policy clientes_apaga_propria on storage.objects for delete to authenticated
             using (bucket_id = 'clientes' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10. DADOS: planos e o que cada serviço consome
-- ---------------------------------------------------------------------
insert into public.planos (slug, nome, preco_centavos, itens, cotas, destaque, ordem) values
  ('basic', 'Trevus Basic', 11500, array['4 cortes por mês'],                                  '{"corte":4}',                          false, 1),
  ('hyper', 'Hyper Trevus', 17000, array['4 cortes por mês','4 barbas por mês'],               '{"corte":4,"barba":4}',                false, 2),
  ('mega',  'Mega Trevus',  23000, array['4 cortes por mês','4 barbas por mês','4 sobrancelhas por mês'], '{"corte":4,"barba":4,"sobrancelha":4}', true, 3)
on conflict (slug) do update set nome = excluded.nome, preco_centavos = excluded.preco_centavos, itens = excluded.itens,
  cotas = excluded.cotas, destaque = excluded.destaque, ordem = excluded.ordem;

update public.servicos set consome = case slug
    when 'corte'         then '{"corte":1}'::jsonb
    when 'corte-tesoura' then '{"corte":1}'::jsonb
    when 'corte-todo-um' then '{"corte":1}'::jsonb
    when 'corte-barba'   then '{"corte":1,"barba":1}'::jsonb
    when 'barba'         then '{"barba":1}'::jsonb
    when 'sobrancelha'   then '{"sobrancelha":1}'::jsonb
  end;
