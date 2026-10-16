-- =====================================================================
--  Trevus Barbearia — banco de agendamento (v2: sinal no Pix)
--  Rode este arquivo inteiro no SQL Editor do Supabase (uma vez só).
--  Fuso: America/Bahia (Salvador, UTC-3, sem horário de verão).
--
--  Regras combinadas no alinhamento de 24/09/2026:
--    grade de 30 em 30 min · agenda aberta 15 dias · antecedência 30 min
--    sinal de 50% (InfinitePay de cada barbeiro) · vaga segurada 15 min
--    cliente cancela até 1h antes -> sinal vira crédito com aquele barbeiro
--    faltou -> sinal fica com a barbearia · remarca até 2 vezes
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 1. BARBEIROS
-- ---------------------------------------------------------------------
create table if not exists public.barbeiros (
  id                 uuid primary key default gen_random_uuid(),
  slug               text unique not null,
  nome               text not null,
  foto               text,
  instagram          text,
  especialidade      text,
  frase              text,
  anos_profissao     integer,
  infinitepay_handle text,          -- InfiniteTag sem o "$": o sinal cai na conta dele
  ordem              integer not null default 0,
  ativo              boolean not null default true,
  user_id            uuid unique references auth.users(id) on delete set null
);

-- ---------------------------------------------------------------------
-- 2. SERVIÇOS
-- ---------------------------------------------------------------------
create table if not exists public.servicos (
  id             uuid primary key default gen_random_uuid(),
  slug           text unique not null,
  nome           text not null,
  descricao      text,
  categoria      text,
  preco_centavos integer not null check (preco_centavos >= 0),
  a_partir_de    boolean not null default false,
  duracao_min    integer not null check (duracao_min between 5 and 480),
  ordem          integer not null default 0,
  ativo          boolean not null default true,
  so_barbeiros   uuid[]                         -- nulo = todos fazem; senão só estes
);
alter table public.servicos add column if not exists so_barbeiros uuid[];

-- ---------------------------------------------------------------------
-- 3. EXPEDIENTE POR BARBEIRO   0 = domingo ... 6 = sábado
-- ---------------------------------------------------------------------
create table if not exists public.expediente (
  barbeiro_id   uuid not null references public.barbeiros(id) on delete cascade,
  dia_semana    smallint not null check (dia_semana between 0 and 6),
  aberto        boolean not null default true,
  abre          time,
  fecha         time,
  pausa_inicio  time,
  pausa_fim     time,
  primary key (barbeiro_id, dia_semana),
  constraint expediente_coerente check (
    not aberto or (abre is not null and fecha is not null and fecha > abre)
  )
);

-- ---------------------------------------------------------------------
-- 4. FERIADOS — o horário do dia vira a faixa abaixo (sem almoço).
--    abre nulo = barbearia fechada no dia.
-- ---------------------------------------------------------------------
create table if not exists public.feriados (
  data   date primary key,
  nome   text not null,
  abre   time,
  fecha  time,
  constraint feriado_coerente check (abre is null or (fecha is not null and fecha > abre))
);

-- ---------------------------------------------------------------------
-- 5. BLOQUEIOS (folga, compromisso). barbeiro_id nulo = casa toda.
-- ---------------------------------------------------------------------
create table if not exists public.bloqueios (
  id          uuid primary key default gen_random_uuid(),
  barbeiro_id uuid references public.barbeiros(id) on delete cascade,
  data        date not null,
  hora_inicio time not null default '00:00',
  hora_fim    time not null default '23:59',
  motivo      text,
  criado_em   timestamptz not null default now(),
  constraint bloqueio_coerente check (hora_fim > hora_inicio)
);
create index if not exists bloqueios_data_idx on public.bloqueios (data);

-- ---------------------------------------------------------------------
-- 6. AGENDAMENTOS
--   status:       aguardando_pagamento -> confirmado -> concluido | faltou
--                 (ou cancelado / expirado)
--   sinal_status: pendente | pago | credito (pago com crédito) | isento
--                 | virou_credito | retido | devolver | devolvido
-- ---------------------------------------------------------------------
create table if not exists public.agendamentos (
  id               uuid primary key default gen_random_uuid(),
  codigo           text unique not null,
  barbeiro_id      uuid not null references public.barbeiros(id),
  barbeiro_nome    text not null,
  servicos         jsonb not null,                -- [{id,nome,preco_centavos,duracao_min}]
  servico_nome     text not null,                 -- "Corte + Sobrancelha"
  preco_centavos   integer not null,
  duracao_min      integer not null,
  sinal_centavos   integer not null default 0,
  desconto_pct     integer not null default 0,
  credito_usado    integer not null default 0,
  sinal_status     text not null default 'pendente'
                   check (sinal_status in ('pendente','pago','credito','isento','virou_credito',
                                           'retido','devolver','devolvido')),
  cliente_nome     text not null,
  cliente_telefone text not null,
  cliente_email    text,
  data             date not null,
  inicio           time not null,
  fim              time not null,
  status           text not null default 'aguardando_pagamento'
                   check (status in ('aguardando_pagamento','confirmado','cancelado','expirado',
                                     'concluido','faltou')),
  expira_em        timestamptz,
  origem           text not null default 'site' check (origem in ('site','balcao')),
  remarcacoes      integer not null default 0,
  pagamento        jsonb,                         -- dados da InfinitePay (slug, nsu, comprovante)
  email_enviado_em    timestamptz,                -- confirmação mandada ao cliente
  lembrete_enviado_em timestamptz,                -- lembrete da véspera
  observacao       text,
  criado_em        timestamptz not null default now(),
  cancelado_em     timestamptz,
  constraint horario_coerente check (fim > inicio)
);

alter table public.agendamentos add column if not exists email_enviado_em timestamptz;
alter table public.agendamentos add column if not exists desconto_pct integer not null default 0;
alter table public.agendamentos add column if not exists lembrete_enviado_em timestamptz;

create index if not exists agendamentos_data_idx on public.agendamentos (data, barbeiro_id, inicio);
create index if not exists agendamentos_tel_idx  on public.agendamentos (cliente_telefone);

-- O mesmo barbeiro não pega dois clientes no mesmo horário. Vale também
-- para o horário segurado enquanto o cliente paga.
alter table public.agendamentos drop constraint if exists agendamentos_sem_choque;
alter table public.agendamentos add constraint agendamentos_sem_choque
  exclude using gist (
    barbeiro_id with =,
    data with =,
    tsrange( (date '2000-01-01' + inicio)::timestamp,
             (date '2000-01-01' + fim)::timestamp ) with &&
  ) where (status in ('confirmado','aguardando_pagamento'));

-- Antes de gravar, libera os horários cujo prazo de pagamento já venceu.
-- Sem isto, uma reserva abandonada travaria a vaga para sempre.
create or replace function public.libera_vencidos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.agendamentos
     set status = 'expirado'
   where status = 'aguardando_pagamento'
     and expira_em < now()
     and barbeiro_id = new.barbeiro_id
     and data = new.data;
  return new;
end;
$$;
drop trigger if exists agendamentos_libera_vencidos on public.agendamentos;
create trigger agendamentos_libera_vencidos
  before insert or update of data, inicio, fim, barbeiro_id on public.agendamentos
  for each row execute function public.libera_vencidos();

-- ---------------------------------------------------------------------
-- 7. CRÉDITOS — sinal de quem cancelou com antecedência.
--    Fica preso ao barbeiro: o dinheiro caiu na conta dele.
-- ---------------------------------------------------------------------
create table if not exists public.creditos (
  id                 uuid primary key default gen_random_uuid(),
  telefone           text not null,
  barbeiro_id        uuid not null references public.barbeiros(id),
  valor_centavos     integer not null check (valor_centavos > 0),
  saldo_centavos     integer not null check (saldo_centavos >= 0),
  origem_agendamento uuid references public.agendamentos(id),
  criado_em          timestamptz not null default now()
);
create index if not exists creditos_tel_idx on public.creditos (telefone, barbeiro_id);

-- ---------------------------------------------------------------------
-- 8. DESCONTOS — a barbearia desmarcou em cima da hora (menos de 1h) ou
--    o barbeiro faltou: o cliente ganha 10% no próximo horário.
-- ---------------------------------------------------------------------
create table if not exists public.descontos (
  id                 uuid primary key default gen_random_uuid(),
  telefone           text not null,
  pct                integer not null check (pct between 1 and 100),
  origem_agendamento uuid references public.agendamentos(id),
  usado_em           uuid references public.agendamentos(id),
  criado_em          timestamptz not null default now()
);
create index if not exists descontos_tel_idx on public.descontos (telefone) where usado_em is null;

-- =====================================================================
--  SEGURANÇA (RLS)
-- =====================================================================
alter table public.barbeiros    enable row level security;
alter table public.servicos     enable row level security;
alter table public.expediente   enable row level security;
alter table public.feriados     enable row level security;
alter table public.bloqueios    enable row level security;
alter table public.agendamentos enable row level security;
alter table public.creditos     enable row level security;
alter table public.descontos    enable row level security;

do $$
declare t text;
begin
  -- leitura pública só do que não tem dado pessoal
  foreach t in array array['barbeiros','servicos','expediente','feriados'] loop
    execute format('drop policy if exists %1$s_leitura_publica on public.%1$s', t);
  end loop;
  -- os três sócios (logados) administram tudo
  foreach t in array array['barbeiros','servicos','expediente','feriados','bloqueios','agendamentos','creditos','descontos'] loop
    execute format('drop policy if exists %1$s_admin on public.%1$s', t);
    execute format('create policy %1$s_admin on public.%1$s for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

create policy barbeiros_leitura_publica  on public.barbeiros  for select to anon using (ativo);
create policy servicos_leitura_publica   on public.servicos   for select to anon using (ativo);
create policy expediente_leitura_publica on public.expediente for select to anon using (true);
create policy feriados_leitura_publica   on public.feriados   for select to anon using (true);

-- A InfiniteTag não é segredo (aparece em qualquer link de pagamento),
-- mas o site não precisa dela: fica fora da leitura pública.
revoke select on public.barbeiros from anon;
grant select (id, slug, nome, foto, instagram, especialidade, frase, anos_profissao, ordem, ativo)
  on public.barbeiros to anon;

-- =====================================================================
--  FUNÇÕES
-- =====================================================================

create or replace function public.agora_bahia()
returns timestamp language sql stable as $$
  select timezone('America/Bahia', now());
$$;

-- Faixa de trabalho de um barbeiro num dia (já considerando feriado).
create or replace function public.janela_barbeiro(p_data date, p_barbeiro_id uuid)
returns table (abre time, fecha time, pausa_inicio time, pausa_fim time)
language sql stable security definer set search_path = public as $$
  select case when f.data is not null then greatest(e.abre, f.abre) else e.abre end,
         case when f.data is not null then least(e.fecha, f.fecha) else e.fecha end,
         case when f.data is not null then null else e.pausa_inicio end,
         case when f.data is not null then null else e.pausa_fim end
    from public.expediente e
    left join public.feriados f on f.data = p_data
   where e.barbeiro_id = p_barbeiro_id
     and e.dia_semana = extract(dow from p_data)::smallint
     and e.aberto
     and (f.data is null or f.abre is not null);
$$;

-- ---------------------------------------------------------------------
-- slots_barbeiro(data, duração, barbeiro) -> inícios livres de UM barbeiro
-- ---------------------------------------------------------------------
create or replace function public.slots_barbeiro(p_data date, p_duracao integer, p_barbeiro_id uuid)
returns setof time
language plpgsql stable security definer set search_path = public as $$
declare
  j        record;
  v_agora  timestamp := public.agora_bahia();
  v_hoje   date := (public.agora_bahia())::date;
  v_passo  constant interval := interval '30 minutes';
  v_janela constant integer  := 15;
  v_antec  constant interval := interval '30 minutes';
begin
  if p_data is null or p_data < v_hoje or p_data > v_hoje + v_janela
     or p_duracao is null or p_duracao < 5 then
    return;
  end if;
  if not exists (select 1 from public.barbeiros where id = p_barbeiro_id and ativo) then
    return;
  end if;

  select * into j from public.janela_barbeiro(p_data, p_barbeiro_id);
  if not found or j.abre is null or j.fecha <= j.abre then return; end if;

  return query
  with grade as (
    select g::time as ini
      from generate_series(p_data + j.abre, p_data + j.fecha, v_passo) g
  ),
  candidatos as (
    select ini, (ini + make_interval(mins => p_duracao)) as fim from grade
  )
  select c.ini
    from candidatos c
   where c.fim <= j.fecha and c.fim > c.ini
     and ( j.pausa_inicio is null or not (c.ini < j.pausa_fim and c.fim > j.pausa_inicio) )
     and ( p_data > v_hoje or (p_data + c.ini) >= v_agora + v_antec )
     and not exists (
       select 1 from public.agendamentos a
        where a.barbeiro_id = p_barbeiro_id and a.data = p_data
          and ( a.status = 'confirmado'
                or (a.status = 'aguardando_pagamento' and a.expira_em > now()) )
          and c.ini < a.fim and c.fim > a.inicio )
     and not exists (
       select 1 from public.bloqueios b
        where b.data = p_data
          and (b.barbeiro_id is null or b.barbeiro_id = p_barbeiro_id)
          and c.ini < b.hora_fim and c.fim > b.hora_inicio )
   order by c.ini;
end;
$$;

-- Soma a duração de uma lista de serviços ativos (ids repetidos contam 1x).
create or replace function public.duracao_servicos(p_servicos uuid[])
returns integer language sql stable security definer set search_path = public as $$
  select sum(duracao_min)::integer from public.servicos
   where ativo and id = any(p_servicos);
$$;

-- O barbeiro faz todos os serviços da lista? (freestyle, por exemplo, só o Kelson)
create or replace function public.barbeiro_faz(p_servicos uuid[], p_barbeiro_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.servicos s
     where s.id = any(p_servicos) and s.so_barbeiros is not null
       and not (p_barbeiro_id = any(s.so_barbeiros)));
$$;

-- ---------------------------------------------------------------------
-- slots_disponiveis(data, serviços, barbeiro?) — nulo = sem preferência
-- ---------------------------------------------------------------------
create or replace function public.slots_disponiveis(p_data date, p_servicos uuid[], p_barbeiro_id uuid default null)
returns setof time
language sql stable security definer set search_path = public as $$
  select distinct s
    from public.barbeiros b,
         lateral public.slots_barbeiro(p_data, public.duracao_servicos(p_servicos), b.id) s
   where b.ativo and (p_barbeiro_id is null or b.id = p_barbeiro_id)
     and public.barbeiro_faz(p_servicos, b.id)
   order by s;
$$;

create or replace function public.dias_disponiveis(p_servicos uuid[], p_barbeiro_id uuid default null)
returns table (dia date, vagas integer)
language sql stable security definer set search_path = public as $$
  select d::date,
         (select count(*)::integer from public.slots_disponiveis(d::date, p_servicos, p_barbeiro_id))
    from generate_series(public.agora_bahia()::date, public.agora_bahia()::date + 15, interval '1 day') d;
$$;

-- Código curto e único que o cliente guarda.
-- No Supabase o pgcrypto (gen_random_bytes) mora no schema "extensions".
create or replace function public.novo_codigo()
returns text language plpgsql volatile set search_path = public, extensions as $$
declare v text;
begin
  loop
    v := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 6));
    exit when not exists (select 1 from public.agendamentos where codigo = v);
  end loop;
  return v;
end;
$$;

-- ---------------------------------------------------------------------
-- criar_agendamento(...) — grava o horário e calcula o sinal.
--   Sinal = 50% do total, abatendo o crédito que o cliente tiver com
--   aquele barbeiro. Sinal zerado pelo crédito já sai confirmado; o
--   resto fica "aguardando pagamento" por 15 minutos.
-- ---------------------------------------------------------------------
create or replace function public.criar_agendamento(
  p_servicos    uuid[],
  p_barbeiro_id uuid,
  p_nome        text,
  p_telefone    text,
  p_email       text,
  p_data        date,
  p_inicio      time,
  p_obs         text default null
)
returns table (id uuid, codigo text, barbeiro text, servico text, dia date, inicio time, fim time,
               preco_centavos integer, sinal_centavos integer, credito_usado integer, status text,
               desconto_pct integer)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_dur    integer;
  v_lista  jsonb;
  v_nomes  text;
  v_total  integer;
  v_b      public.barbeiros%rowtype;
  v_tel    text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_nome   text := btrim(coalesce(p_nome, ''));
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_sinal  integer;
  v_cred   integer := 0;
  v_resta  integer;
  v_id     uuid;
  v_cod    text;
  v_desc   public.descontos%rowtype;
  c        record;
begin
  if length(v_nome) < 2 or length(v_nome) > 80 then
    raise exception 'NOME_INVALIDO' using hint = 'Informe seu nome.';
  end if;
  if length(v_tel) < 10 or length(v_tel) > 13 then
    raise exception 'TELEFONE_INVALIDO' using hint = 'Informe um WhatsApp com DDD.';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'EMAIL_INVALIDO' using hint = 'Informe um e-mail válido para receber a confirmação.';
  end if;

  select jsonb_agg(jsonb_build_object('id', s.id, 'nome', s.nome,
                     'preco_centavos', s.preco_centavos, 'duracao_min', s.duracao_min) order by s.ordem),
         string_agg(s.nome, ' + ' order by s.ordem),
         sum(s.preco_centavos)::integer, sum(s.duracao_min)::integer
    into v_lista, v_nomes, v_total, v_dur
    from public.servicos s
   where s.ativo and s.id = any(p_servicos);
  if v_lista is null then
    raise exception 'SERVICO_INVALIDO' using hint = 'Escolha pelo menos um serviço.';
  end if;

  -- Sem preferência: prefere quem já tem crédito do cliente, depois quem
  -- está com menos clientes no dia.
  select * into v_b from public.barbeiros b
   where b.ativo
     and (p_barbeiro_id is null or b.id = p_barbeiro_id)
     and public.barbeiro_faz(p_servicos, b.id)
     and exists (select 1 from public.slots_barbeiro(p_data, v_dur, b.id) s where s = p_inicio)
   order by (select coalesce(sum(saldo_centavos),0) from public.creditos cr
              where cr.telefone = v_tel and cr.barbeiro_id = b.id) desc,
            (select count(*) from public.agendamentos a
              where a.barbeiro_id = b.id and a.data = p_data and a.status = 'confirmado'),
            b.ordem
   limit 1;

  if v_b.id is null then
    raise exception 'HORARIO_INDISPONIVEL' using hint = 'Esse horário acabou de ser ocupado. Escolha outro.';
  end if;

  -- desconto de 10% pendente (barbearia desmarcou em cima da hora)
  select * into v_desc from public.descontos d
   where d.telefone = v_tel and d.usado_em is null order by d.criado_em limit 1 for update;
  if v_desc.id is not null then
    v_total := round(v_total * (100 - v_desc.pct) / 100.0)::integer;
  end if;

  v_sinal := ceil(v_total / 2.0)::integer;
  v_resta := v_sinal;

  -- abate o crédito com este barbeiro, do mais antigo para o mais novo
  for c in select * from public.creditos cr
            where cr.telefone = v_tel and cr.barbeiro_id = v_b.id and cr.saldo_centavos > 0
            order by cr.criado_em for update loop
    exit when v_resta = 0;
    update public.creditos set saldo_centavos = saldo_centavos - least(saldo_centavos, v_resta)
     where creditos.id = c.id;
    v_cred  := v_cred + least(c.saldo_centavos, v_resta);
    v_resta := v_resta - least(c.saldo_centavos, v_resta);
  end loop;

  v_cod := public.novo_codigo();

  insert into public.agendamentos (
    codigo, barbeiro_id, barbeiro_nome, servicos, servico_nome, preco_centavos, duracao_min,
    sinal_centavos, desconto_pct, credito_usado, sinal_status, cliente_nome, cliente_telefone, cliente_email,
    data, inicio, fim, status, expira_em, observacao)
  values (
    v_cod, v_b.id, v_b.nome, v_lista, v_nomes, v_total, v_dur,
    v_sinal, coalesce(v_desc.pct, 0), v_cred, case when v_resta = 0 then 'credito' else 'pendente' end,
    v_nome, v_tel, v_email,
    p_data, p_inicio, p_inicio + make_interval(mins => v_dur),
    case when v_resta = 0 then 'confirmado' else 'aguardando_pagamento' end,
    case when v_resta = 0 then null else now() + interval '15 minutes' end,
    nullif(btrim(p_obs), ''))
  returning agendamentos.id into v_id;

  if v_desc.id is not null then
    update public.descontos set usado_em = v_id where descontos.id = v_desc.id;
  end if;

  return query
    select a.id, a.codigo, a.barbeiro_nome, a.servico_nome, a.data, a.inicio, a.fim,
           a.preco_centavos, a.sinal_centavos - a.credito_usado, a.credito_usado, a.status, a.desconto_pct
      from public.agendamentos a where a.id = v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Pagamento: só as Edge Functions (service_role) chamam estas duas.
-- ---------------------------------------------------------------------
create or replace function public.dados_cobranca(p_id uuid)
returns table (id uuid, codigo text, handle text, valor integer, descricao text,
               cliente_nome text, cliente_email text, cliente_telefone text, status text)
language sql stable security definer set search_path = public as $$
  select a.id, a.codigo, b.infinitepay_handle, a.sinal_centavos - a.credito_usado,
         'Sinal 50% - ' || a.servico_nome || ' com ' || a.barbeiro_nome,
         a.cliente_nome, a.cliente_email, a.cliente_telefone, a.status
    from public.agendamentos a join public.barbeiros b on b.id = a.barbeiro_id
   where a.id = p_id;
$$;

create or replace function public.registrar_pagamento(p_id uuid, p_pago integer, p_dados jsonb)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare a public.agendamentos%rowtype;
begin
  select * into a from public.agendamentos where id = p_id for update;
  if not found then return 'NAO_ENCONTRADO'; end if;
  if a.sinal_status = 'pago' then return 'JA_PAGO'; end if;
  if p_pago < a.sinal_centavos - a.credito_usado then return 'VALOR_MENOR'; end if;

  if a.status = 'aguardando_pagamento' then
    update public.agendamentos
       set status = 'confirmado', sinal_status = 'pago', expira_em = null, pagamento = p_dados
     where id = p_id;
    return 'CONFIRMADO';
  end if;

  -- Pagou depois de a vaga expirar: tenta segurar de novo; se outro
  -- cliente já pegou, o painel avisa para devolver o sinal.
  begin
    update public.agendamentos
       set status = 'confirmado', sinal_status = 'pago', expira_em = null, pagamento = p_dados
     where id = p_id;
    return 'CONFIRMADO_ATRASADO';
  exception when exclusion_violation then
    update public.agendamentos set sinal_status = 'devolver', pagamento = p_dados where id = p_id;
    return 'DEVOLVER';
  end;
end;
$$;

-- Status do pagamento para a tela de "aguardando Pix". Pelo id (uuid
-- impossível de adivinhar), sem nome nem telefone.
create or replace function public.status_agendamento(p_id uuid)
returns table (codigo text, status text, sinal_status text, barbeiro text, servico text,
               dia date, inicio time, fim time, expira_em timestamptz)
language sql stable security definer set search_path = public as $$
  select codigo, case when status = 'aguardando_pagamento' and expira_em < now() then 'expirado' else status end,
         sinal_status, barbeiro_nome, servico_nome, data, inicio, fim, expira_em
    from public.agendamentos where id = p_id;
$$;

-- ---------------------------------------------------------------------
-- Consulta, cancelamento e remarcação pelo cliente (código + telefone)
-- ---------------------------------------------------------------------
create or replace function public.consultar_agendamento(p_codigo text, p_telefone text)
returns table (codigo text, barbeiro_id uuid, barbeiro text, servico text, servicos uuid[], dia date,
               inicio time, fim time, preco_centavos integer, sinal_centavos integer, status text,
               sinal_status text, pode_cancelar boolean, pode_remarcar boolean, remarcacoes integer)
language sql stable security definer set search_path = public as $$
  select a.codigo, a.barbeiro_id, a.barbeiro_nome, a.servico_nome,
         array(select (x->>'id')::uuid from jsonb_array_elements(a.servicos) x),
         a.data, a.inicio, a.fim, a.preco_centavos, a.sinal_centavos, a.status, a.sinal_status,
         (a.status = 'confirmado' and (a.data + a.inicio) >= public.agora_bahia() + interval '1 hour'),
         (a.status = 'confirmado' and a.remarcacoes < 2
          and (a.data + a.inicio) >= public.agora_bahia() + interval '1 hour'),
         a.remarcacoes
    from public.agendamentos a
   where upper(btrim(p_codigo)) = a.codigo
     and a.cliente_telefone = regexp_replace(coalesce(p_telefone,''), '\D', '', 'g');
$$;

create or replace function public.cancelar_agendamento(p_codigo text, p_telefone text)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare a public.agendamentos%rowtype; v_pago integer;
begin
  select * into a from public.agendamentos ag
   where ag.codigo = upper(btrim(p_codigo))
     and ag.cliente_telefone = regexp_replace(coalesce(p_telefone,''), '\D', '', 'g')
   for update;
  if not found then raise exception 'NAO_ENCONTRADO' using hint = 'Código ou telefone não confere.'; end if;
  if a.status in ('cancelado','expirado') then return 'JA_CANCELADO'; end if;

  if a.status = 'aguardando_pagamento' then
    update public.agendamentos set status = 'cancelado', cancelado_em = now() where id = a.id;
    return 'CANCELADO';
  end if;
  if a.status <> 'confirmado' then
    raise exception 'NAO_CANCELAVEL' using hint = 'Esse horário já foi atendido.';
  end if;
  if (a.data + a.inicio) < public.agora_bahia() + interval '1 hour' then
    raise exception 'PRAZO_ESGOTADO'
      using hint = 'O cancelamento pelo site vai até 1h antes. Fale no WhatsApp.';
  end if;

  -- tudo o que o cliente pagou de sinal (Pix + crédito usado) volta como crédito
  v_pago := case when a.sinal_status in ('pago','credito') then a.sinal_centavos else 0 end;
  update public.agendamentos
     set status = 'cancelado', cancelado_em = now(),
         sinal_status = case when v_pago > 0 then 'virou_credito' else sinal_status end
   where id = a.id;
  if v_pago > 0 then
    insert into public.creditos (telefone, barbeiro_id, valor_centavos, saldo_centavos, origem_agendamento)
    values (a.cliente_telefone, a.barbeiro_id, v_pago, v_pago, a.id);
    return 'CANCELADO_CREDITO';
  end if;
  return 'CANCELADO';
end;
$$;

-- Remarca com o MESMO barbeiro (o sinal está na conta dele), até 2 vezes.
create or replace function public.remarcar_agendamento(p_codigo text, p_telefone text, p_data date, p_inicio time)
returns table (codigo text, dia date, inicio time, fim time, remarcacoes integer)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare a public.agendamentos%rowtype;
begin
  select * into a from public.agendamentos ag
   where ag.codigo = upper(btrim(p_codigo))
     and ag.cliente_telefone = regexp_replace(coalesce(p_telefone,''), '\D', '', 'g')
   for update;
  if not found then raise exception 'NAO_ENCONTRADO' using hint = 'Código ou telefone não confere.'; end if;
  if a.status <> 'confirmado' then raise exception 'NAO_REMARCAVEL' using hint = 'Só dá para remarcar um horário confirmado.'; end if;
  if a.remarcacoes >= 2 then
    raise exception 'LIMITE_REMARCACAO' using hint = 'Esse horário já foi remarcado 2 vezes. Fale no WhatsApp.';
  end if;
  if (a.data + a.inicio) < public.agora_bahia() + interval '1 hour' then
    raise exception 'PRAZO_ESGOTADO' using hint = 'A remarcação pelo site vai até 1h antes. Fale no WhatsApp.';
  end if;

  -- tira o horário atual da conta antes de procurar a vaga nova
  update public.agendamentos set status = 'cancelado' where id = a.id;
  if not exists (select 1 from public.slots_barbeiro(p_data, a.duracao_min, a.barbeiro_id) s where s = p_inicio) then
    raise exception 'HORARIO_INDISPONIVEL' using hint = 'Esse horário não está livre. Escolha outro.';
  end if;
  update public.agendamentos
     set status = 'confirmado', data = p_data, inicio = p_inicio,
         fim = p_inicio + make_interval(mins => a.duracao_min),
         remarcacoes = a.remarcacoes + 1
   where id = a.id;
  return query select a.codigo, p_data, p_inicio, p_inicio + make_interval(mins => a.duracao_min), a.remarcacoes + 1;
end;
$$;

-- A barbearia desmarca (painel). Sinal pago entra na lista "devolver";
-- com menos de 1h para o horário, o cliente ganha 10% no próximo.
create or replace function public.desmarcar_pela_barbearia(p_id uuid)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare a public.agendamentos%rowtype; v_tarde boolean;
begin
  select * into a from public.agendamentos where id = p_id for update;
  if not found or a.status <> 'confirmado' then return 'NAO_DESMARCAVEL'; end if;
  v_tarde := (a.data + a.inicio) < public.agora_bahia() + interval '1 hour';
  update public.agendamentos
     set status = 'cancelado', cancelado_em = now(),
         sinal_status = case when a.sinal_status = 'pago' then 'devolver'
                             when a.sinal_status = 'credito' then 'virou_credito' else a.sinal_status end
   where id = a.id;
  -- a parte do sinal paga com crédito volta como crédito; só o Pix é devolvido
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

-- Desconto pendente de um telefone (mostrado na hora de marcar).
create or replace function public.meu_desconto(p_telefone text)
returns integer language sql stable security definer set search_path = public as $$
  select pct from public.descontos
   where telefone = regexp_replace(coalesce(p_telefone,''), '\D', '', 'g') and usado_em is null
   order by criado_em limit 1;
$$;

-- Crédito disponível de um telefone, por barbeiro (mostrado na hora de marcar).
create or replace function public.meus_creditos(p_telefone text)
returns table (barbeiro_id uuid, saldo_centavos integer)
language sql stable security definer set search_path = public as $$
  select barbeiro_id, sum(saldo_centavos)::integer
    from public.creditos
   where telefone = regexp_replace(coalesce(p_telefone,''), '\D', '', 'g') and saldo_centavos > 0
   group by barbeiro_id;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'janela_barbeiro(date,uuid)', 'slots_barbeiro(date,integer,uuid)', 'duracao_servicos(uuid[])',
    'slots_disponiveis(date,uuid[],uuid)', 'dias_disponiveis(uuid[],uuid)', 'novo_codigo()',
    'criar_agendamento(uuid[],uuid,text,text,text,date,time,text)', 'dados_cobranca(uuid)',
    'registrar_pagamento(uuid,integer,jsonb)', 'status_agendamento(uuid)',
    'consultar_agendamento(text,text)', 'cancelar_agendamento(text,text)',
    'remarcar_agendamento(text,text,date,time)', 'meus_creditos(text)', 'barbeiro_faz(uuid[],uuid)',
    'desmarcar_pela_barbearia(uuid)', 'meu_desconto(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;

-- o que o site público pode chamar
grant execute on function public.slots_disponiveis(date,uuid[],uuid)                         to anon, authenticated;
grant execute on function public.dias_disponiveis(uuid[],uuid)                               to anon, authenticated;
grant execute on function public.criar_agendamento(uuid[],uuid,text,text,text,date,time,text) to anon, authenticated;
grant execute on function public.status_agendamento(uuid)                                    to anon, authenticated;
grant execute on function public.consultar_agendamento(text,text)                            to anon, authenticated;
grant execute on function public.cancelar_agendamento(text,text)                             to anon, authenticated;
grant execute on function public.remarcar_agendamento(text,text,date,time)                   to anon, authenticated;
grant execute on function public.meus_creditos(text)                                         to anon, authenticated;
grant execute on function public.meu_desconto(text)                                          to anon, authenticated;
grant execute on function public.desmarcar_pela_barbearia(uuid)                              to authenticated;
-- só as Edge Functions (chave service_role)
grant execute on function public.dados_cobranca(uuid)                 to service_role;
grant execute on function public.registrar_pagamento(uuid,integer,jsonb) to service_role;

-- =====================================================================
--  DADOS INICIAIS — Trevus Barbearia
-- =====================================================================

insert into public.barbeiros (slug, nome, foto, instagram, especialidade, frase, anos_profissao, ordem) values
  ('kelson', 'Kelson', 'fotos/perfil-kelson.jpg', 'kelsonstrevus', 'Cortes na tesoura',      'Cortes que comunicam poder.',                    4,  1),
  ('junior', 'Júnior', 'fotos/perfil-junior.jpg', 'juniortrevus',  'Química e platinado',    'Autoestima renovada em cada atendimento.',       10, 2),
  ('hariel', 'Hariel', 'fotos/perfil-hariel.jpg', 'haridade1996',  'Degradê',                'Experiência que transforma técnica em excelência.', 13, 3)
on conflict (slug) do update set
  nome = excluded.nome, foto = excluded.foto, instagram = excluded.instagram,
  especialidade = excluded.especialidade, frase = excluded.frase,
  anos_profissao = excluded.anos_profissao, ordem = excluded.ordem;

-- Expediente: Ter a Sáb 8-20 com almoço 12-13 · Dom 8-12
-- Segunda: só o Kelson, 14-20 · Terça: o Hariel não trabalha
insert into public.expediente (barbeiro_id, dia_semana, aberto, abre, fecha, pausa_inicio, pausa_fim)
select b.id, d.dia,
       case when d.dia = 1 then b.slug = 'kelson'
            when d.dia = 2 then b.slug <> 'hariel'
            else true end,
       case when d.dia = 0 then '08:00'::time when d.dia = 1 then '14:00'::time else '08:00'::time end,
       case when d.dia = 0 then '12:00'::time else '20:00'::time end,
       case when d.dia in (0,1) then null else '12:00'::time end,
       case when d.dia in (0,1) then null else '13:00'::time end
  from public.barbeiros b, (select generate_series(0,6)::smallint as dia) d
on conflict (barbeiro_id, dia_semana) do update set
  aberto = excluded.aberto, abre = excluded.abre, fecha = excluded.fecha,
  pausa_inicio = excluded.pausa_inicio, pausa_fim = excluded.pausa_fim;

-- Feriados: nacionais 8h-12h · estaduais e municipais 8h-17h
insert into public.feriados (data, nome, abre, fecha) values
  ('2026-11-02', 'Finados',                         '08:00', '12:00'),
  ('2026-11-15', 'Proclamação da República',        '08:00', '12:00'),
  ('2026-11-20', 'Consciência Negra',               '08:00', '12:00'),
  ('2026-12-08', 'N. Sra. da Conceição da Praia',   '08:00', '17:00'),
  ('2026-12-25', 'Natal',                           '08:00', '12:00'),
  ('2027-01-01', 'Confraternização Universal',      '08:00', '12:00'),
  ('2027-03-26', 'Sexta-feira Santa',               '08:00', '12:00'),
  ('2027-04-21', 'Tiradentes',                      '08:00', '12:00'),
  ('2027-05-01', 'Dia do Trabalho',                 '08:00', '12:00'),
  ('2027-06-24', 'São João',                        '08:00', '17:00'),
  ('2027-07-02', 'Independência da Bahia',          '08:00', '17:00'),
  ('2027-09-07', 'Independência do Brasil',         '08:00', '12:00'),
  ('2027-10-12', 'N. Sra. Aparecida',               '08:00', '12:00')
on conflict (data) do update set nome = excluded.nome, abre = excluded.abre, fecha = excluded.fecha;

-- Serviços (alinhamento de 24/09). Os marcados PENDENTE ainda sem preço
-- confirmado: ficam desligados (ativo = false) até a Trevus responder.
insert into public.servicos (slug, nome, descricao, categoria, preco_centavos, a_partir_de, duracao_min, ordem, ativo) values
  ('corte',             'Corte',                'Corte de cabelo e acabamento.',                        'Cabelo',        3000,  false, 30,  1, true),
  ('corte-tesoura',     'Corte na tesoura',     'Todo na tesoura, pra quem quer volume e caimento.',    'Cabelo',        3500,  false, 40,  2, true),
  ('corte-todo-um',     'Corte todo por um',    'Máquina num pente só, rápido e no ponto.',             'Cabelo',        2500,  false, 15,  3, true),
  ('corte-infantil',    'Corte infantil',       'Para crianças de até 6 anos.',                         'Cabelo',        3500,  false, 30,  4, true),
  ('corte-barba',       'Corte e barba',        'O combo completo. Sai pronto pra semana.',             'Combos',        4500,  false, 50,  5, true),
  ('corte-pigmentacao', 'Corte e pigmentação',  'Corte com pigmentação para fechar as falhas.',         'Combos',        4500,  false, 45,  6, true),
  ('barba',             'Barba',                'Toalha quente, navalha e finalização.',                'Barba',         2000,  false, 20,  7, true),
  ('bigode',            'Bigode',               'Alinhamento e acabamento do bigode.',                  'Barba',          700,  false, 10,  8, true),
  ('barboterapia',      'Barboterapia',         'Ritual completo de barba com toalha quente e hidratação.', 'Barba',     3000,  false, 30,  9, true),
  ('acabamento',        'Acabamento (pé)',      'Aquele retoque entre um corte e outro.',               'Detalhes',      1000,  false, 10, 10, true),
  ('pigmentacao',       'Pigmentação',          'Realça o desenho do corte e da barba.',                'Detalhes',      1500,  false, 15, 11, true),
  ('sobrancelha',       'Sobrancelha',          'Desenho no ponto, sem exagero.',                       'Detalhes',      1500,  false, 10, 12, true),
  ('pelos-nasais',      'Remoção de pelos nasais', 'Rápido e sem dor.',                                 'Detalhes',      1000,  false,  5, 13, false), -- PENDENTE: preço
  ('limpeza-pele',      'Limpeza de pele',      'Limpeza facial para tirar oleosidade e cravos.',       'Cuidados',      2000,  false, 25, 14, true),
  ('freestyle',         'Freestyle',            'Desenho na lateral, feito à mão. Valor conforme o desenho.', 'Detalhes', 700, true, 10, 13, true), -- PENDENTE: duração
  ('nevou',             'Nevou',                'Platinado. O valor final pode mudar conforme o tamanho do cabelo.', 'Química', 12000, true, 30, 15, true),
  ('luzes',             'Luzes',                'Mechas no tom certo.',                                 'Química',       8000,  true,  40, 16, false)  -- PENDENTE: preço
on conflict (slug) do update set
  nome = excluded.nome, descricao = excluded.descricao, categoria = excluded.categoria,
  preco_centavos = excluded.preco_centavos, a_partir_de = excluded.a_partir_de,
  duracao_min = excluded.duracao_min, ordem = excluded.ordem, ativo = excluded.ativo;

-- Freestyle: só o Kelson faz.
update public.servicos set so_barbeiros = array(select id from public.barbeiros where slug = 'kelson')
 where slug = 'freestyle';

-- ---------------------------------------------------------------------
-- Depois de criar o login de cada sócio (Authentication > Users):
--   update barbeiros set user_id = (select id from auth.users where email = 'kelsondossantos2003@icloud.com') where slug = 'kelson';
--   update barbeiros set user_id = (select id from auth.users where email = 'paulocj2217@gmail.com')          where slug = 'junior';
--   update barbeiros set user_id = (select id from auth.users where email = 'hariel13anderson08@gmail.com')   where slug = 'hariel';
-- E a InfiniteTag de cada um (sem o $):
--   update barbeiros set infinitepay_handle = 'tag-do-kelson' where slug = 'kelson';  -- etc.
-- ---------------------------------------------------------------------
