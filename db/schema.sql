-- =====================================================================
--  Trevus Barbearia — banco de agendamento (3 barbeiros)
--  Rode este arquivo inteiro no SQL Editor do Supabase (uma vez só).
--  Fuso: America/Bahia (Salvador, UTC-3, sem horário de verão).
-- =====================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid / gen_random_bytes
create extension if not exists btree_gist; -- constraint anti-choque de horário

-- ---------------------------------------------------------------------
-- 1. BARBEIROS
--    user_id liga o barbeiro ao login dele no painel (/admin).
-- ---------------------------------------------------------------------
create table if not exists public.barbeiros (
  id        uuid primary key default gen_random_uuid(),
  slug      text unique not null,
  nome      text not null,
  foto      text,
  instagram text,
  ordem     integer not null default 0,
  ativo     boolean not null default true,
  user_id   uuid unique references auth.users(id) on delete set null
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
  a_partir_de    boolean not null default false,  -- mostra "a partir de R$ X"
  duracao_min    integer not null check (duracao_min between 5 and 480),
  ordem          integer not null default 0,
  ativo          boolean not null default true
);

-- ---------------------------------------------------------------------
-- 3. EXPEDIENTE da casa   0 = domingo ... 6 = sábado
-- ---------------------------------------------------------------------
create table if not exists public.expediente (
  dia_semana    smallint primary key check (dia_semana between 0 and 6),
  aberto        boolean not null default true,
  abre          time,
  fecha         time,
  pausa_inicio  time,
  pausa_fim     time,
  constraint expediente_coerente check (
    not aberto or (abre is not null and fecha is not null and fecha > abre)
  )
);

-- ---------------------------------------------------------------------
-- 4. BLOQUEIOS (folga, feriado, compromisso)
--    barbeiro_id nulo = a barbearia inteira fecha.
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
-- 5. AGENDAMENTOS
-- ---------------------------------------------------------------------
create table if not exists public.agendamentos (
  id               uuid primary key default gen_random_uuid(),
  codigo           text unique not null,
  barbeiro_id      uuid not null references public.barbeiros(id),
  barbeiro_nome    text not null,                 -- snapshot
  servico_id       uuid not null references public.servicos(id),
  servico_nome     text not null,                 -- snapshot: preço/nome mudam
  preco_centavos   integer not null,
  duracao_min      integer not null,
  cliente_nome     text not null,
  cliente_telefone text not null,                 -- só dígitos
  data             date not null,
  inicio           time not null,
  fim              time not null,
  status           text not null default 'confirmado'
                   check (status in ('confirmado','cancelado','concluido','faltou')),
  origem           text not null default 'site' check (origem in ('site','balcao')),
  observacao       text,
  criado_em        timestamptz not null default now(),
  cancelado_em     timestamptz,
  constraint horario_coerente check (fim > inicio)
);

create index if not exists agendamentos_data_idx on public.agendamentos (data, barbeiro_id, inicio);
create index if not exists agendamentos_tel_idx  on public.agendamentos (cliente_telefone);

-- Rede de segurança: o MESMO barbeiro não pega dois clientes no mesmo
-- horário, nem se duas pessoas clicarem no mesmo segundo.
alter table public.agendamentos drop constraint if exists agendamentos_sem_choque;
alter table public.agendamentos add constraint agendamentos_sem_choque
  exclude using gist (
    barbeiro_id with =,
    data with =,
    tsrange( (date '2000-01-01' + inicio)::timestamp,
             (date '2000-01-01' + fim)::timestamp ) with &&
  ) where (status = 'confirmado');

-- =====================================================================
--  SEGURANÇA (RLS)
--  A chave anon fica visível no HTML. Por isso nenhuma tabela com dado
--  de cliente é exposta direto: o site só enxerga o banco pelas funções.
-- =====================================================================
alter table public.barbeiros    enable row level security;
alter table public.servicos     enable row level security;
alter table public.expediente   enable row level security;
alter table public.bloqueios    enable row level security;
alter table public.agendamentos enable row level security;

-- Público lê equipe, cardápio e horário (nada de dado pessoal).
drop policy if exists barbeiros_leitura_publica on public.barbeiros;
create policy barbeiros_leitura_publica on public.barbeiros
  for select to anon, authenticated using (ativo);

drop policy if exists servicos_leitura_publica on public.servicos;
create policy servicos_leitura_publica on public.servicos
  for select to anon, authenticated using (ativo);

drop policy if exists expediente_leitura_publica on public.expediente;
create policy expediente_leitura_publica on public.expediente
  for select to anon, authenticated using (true);

-- Os três sócios (usuários logados) administram tudo.
-- Cadastro público fica DESLIGADO no Supabase, então "logado" = sócio.
drop policy if exists barbeiros_admin on public.barbeiros;
create policy barbeiros_admin on public.barbeiros
  for all to authenticated using (true) with check (true);

drop policy if exists servicos_admin on public.servicos;
create policy servicos_admin on public.servicos
  for all to authenticated using (true) with check (true);

drop policy if exists expediente_admin on public.expediente;
create policy expediente_admin on public.expediente
  for all to authenticated using (true) with check (true);

drop policy if exists bloqueios_admin on public.bloqueios;
create policy bloqueios_admin on public.bloqueios
  for all to authenticated using (true) with check (true);

drop policy if exists agendamentos_admin on public.agendamentos;
create policy agendamentos_admin on public.agendamentos
  for all to authenticated using (true) with check (true);

-- =====================================================================
--  FUNÇÕES — a porta de entrada do site público
-- =====================================================================

create or replace function public.agora_bahia()
returns timestamp language sql stable as $$
  select timezone('America/Bahia', now());
$$;

-- ---------------------------------------------------------------------
-- slots_barbeiro(data, servico, barbeiro) -> horários livres de UM barbeiro
-- ---------------------------------------------------------------------
create or replace function public.slots_barbeiro(p_data date, p_servico_id uuid, p_barbeiro_id uuid)
returns setof time
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_dur    integer;
  v_exp    public.expediente%rowtype;
  v_agora  timestamp := public.agora_bahia();
  v_hoje   date;
  v_passo  constant interval := interval '10 minutes';
  v_janela constant integer  := 30;
  v_antec  constant interval := interval '30 minutes';
begin
  v_hoje := v_agora::date;

  if p_data is null or p_data < v_hoje or p_data > v_hoje + v_janela then
    return;
  end if;

  if not exists (select 1 from public.barbeiros where id = p_barbeiro_id and ativo) then
    return;
  end if;

  select duracao_min into v_dur from public.servicos where id = p_servico_id and ativo;
  if v_dur is null then return; end if;

  select * into v_exp from public.expediente where dia_semana = extract(dow from p_data)::smallint;
  if not found or not v_exp.aberto then return; end if;

  return query
  with grade as (
    select g::time as ini
      from generate_series(p_data + v_exp.abre, p_data + v_exp.fecha, v_passo) g
  ),
  candidatos as (
    select ini, (ini + make_interval(mins => v_dur)) as fim from grade
  )
  select c.ini
    from candidatos c
   where c.fim <= v_exp.fecha
     and c.fim > c.ini                                    -- não vira a meia-noite
     and ( v_exp.pausa_inicio is null
           or not (c.ini < v_exp.pausa_fim and c.fim > v_exp.pausa_inicio) )
     and ( p_data > v_hoje or (p_data + c.ini) >= v_agora + v_antec )
     and not exists (
       select 1 from public.agendamentos a
        where a.barbeiro_id = p_barbeiro_id and a.data = p_data
          and a.status = 'confirmado'
          and c.ini < a.fim and c.fim > a.inicio )
     and not exists (
       select 1 from public.bloqueios b
        where b.data = p_data
          and (b.barbeiro_id is null or b.barbeiro_id = p_barbeiro_id)
          and c.ini < b.hora_fim and c.fim > b.hora_inicio )
   order by c.ini;
end;
$$;

-- ---------------------------------------------------------------------
-- slots_disponiveis(data, servico, barbeiro?)
--   barbeiro nulo = "sem preferência": vale o horário em que QUALQUER um
--   dos três está livre.
-- ---------------------------------------------------------------------
create or replace function public.slots_disponiveis(p_data date, p_servico_id uuid, p_barbeiro_id uuid default null)
returns setof time
language sql
stable
security definer
set search_path = public
as $$
  select distinct s
    from public.barbeiros b,
         lateral public.slots_barbeiro(p_data, p_servico_id, b.id) s
   where b.ativo and (p_barbeiro_id is null or b.id = p_barbeiro_id)
   order by s;
$$;

-- ---------------------------------------------------------------------
-- dias_disponiveis(servico, barbeiro?) -> vagas por dia nos próximos 30
-- ---------------------------------------------------------------------
create or replace function public.dias_disponiveis(p_servico_id uuid, p_barbeiro_id uuid default null)
returns table (dia date, vagas integer)
language sql
stable
security definer
set search_path = public
as $$
  select d::date,
         (select count(*)::integer
            from public.slots_disponiveis(d::date, p_servico_id, p_barbeiro_id))
    from generate_series(public.agora_bahia()::date,
                         public.agora_bahia()::date + 30,
                         interval '1 day') d;
$$;

-- ---------------------------------------------------------------------
-- criar_agendamento(...) -> grava e devolve o código do cliente
--   Revalida TUDO no servidor. Sem barbeiro escolhido, entrega para quem
--   está livre e com menos clientes no dia (divide o movimento).
-- ---------------------------------------------------------------------
create or replace function public.criar_agendamento(
  p_servico_id  uuid,
  p_barbeiro_id uuid,
  p_nome        text,
  p_telefone    text,
  p_data        date,
  p_inicio      time,
  p_obs         text default null
)
returns table (codigo text, barbeiro text, servico text, dia date, inicio time, fim time, preco_centavos integer)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_s    public.servicos%rowtype;
  v_b    public.barbeiros%rowtype;
  v_fim  time;
  v_cod  text;
  v_tel  text;
  v_nome text;
begin
  v_nome := btrim(coalesce(p_nome, ''));
  v_tel  := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');

  if length(v_nome) < 2 or length(v_nome) > 80 then
    raise exception 'NOME_INVALIDO' using hint = 'Informe seu nome.';
  end if;
  if length(v_tel) < 10 or length(v_tel) > 13 then
    raise exception 'TELEFONE_INVALIDO' using hint = 'Informe um WhatsApp com DDD.';
  end if;

  select * into v_s from public.servicos where id = p_servico_id and ativo;
  if not found then
    raise exception 'SERVICO_INVALIDO' using hint = 'Serviço indisponível.';
  end if;

  if p_barbeiro_id is not null then
    select * into v_b from public.barbeiros b
     where b.id = p_barbeiro_id and b.ativo
       and exists (select 1 from public.slots_barbeiro(p_data, p_servico_id, b.id) s where s = p_inicio);
  else
    select * into v_b from public.barbeiros b
     where b.ativo
       and exists (select 1 from public.slots_barbeiro(p_data, p_servico_id, b.id) s where s = p_inicio)
     order by (select count(*) from public.agendamentos a
                where a.barbeiro_id = b.id and a.data = p_data and a.status = 'confirmado'),
              b.ordem
     limit 1;
  end if;

  if v_b.id is null then
    raise exception 'HORARIO_INDISPONIVEL'
      using hint = 'Esse horário acabou de ser ocupado. Escolha outro.';
  end if;

  -- Freio de spam: no máximo 3 horários futuros por telefone.
  if (select count(*) from public.agendamentos a
       where a.cliente_telefone = v_tel
         and a.status = 'confirmado'
         and (a.data + a.inicio) >= public.agora_bahia()) >= 3 then
    raise exception 'LIMITE_AGENDAMENTOS'
      using hint = 'Você já tem 3 horários marcados. Cancele um para marcar outro.';
  end if;

  v_fim := p_inicio + make_interval(mins => v_s.duracao_min);

  loop
    v_cod := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 6));
    exit when not exists (select 1 from public.agendamentos a where a.codigo = v_cod);
  end loop;

  insert into public.agendamentos (
    codigo, barbeiro_id, barbeiro_nome, servico_id, servico_nome, preco_centavos, duracao_min,
    cliente_nome, cliente_telefone, data, inicio, fim, observacao)
  values (
    v_cod, v_b.id, v_b.nome, v_s.id, v_s.nome, v_s.preco_centavos, v_s.duracao_min,
    v_nome, v_tel, p_data, p_inicio, v_fim, nullif(btrim(p_obs), ''));

  return query select v_cod, v_b.nome, v_s.nome, p_data, p_inicio, v_fim, v_s.preco_centavos;
end;
$$;

-- ---------------------------------------------------------------------
-- consultar_agendamento(codigo, telefone) — exige os dois
-- ---------------------------------------------------------------------
create or replace function public.consultar_agendamento(p_codigo text, p_telefone text)
returns table (codigo text, barbeiro text, servico text, dia date, inicio time, fim time,
               preco_centavos integer, status text, pode_cancelar boolean)
language sql
stable
security definer
set search_path = public
as $$
  select a.codigo, a.barbeiro_nome, a.servico_nome, a.data, a.inicio, a.fim, a.preco_centavos, a.status,
         (a.status = 'confirmado'
          and (a.data + a.inicio) >= public.agora_bahia() + interval '2 hours')
    from public.agendamentos a
   where upper(btrim(p_codigo)) = a.codigo
     and a.cliente_telefone = regexp_replace(coalesce(p_telefone,''), '\D', '', 'g');
$$;

-- ---------------------------------------------------------------------
-- cancelar_agendamento(codigo, telefone) — até 2h antes
-- ---------------------------------------------------------------------
create or replace function public.cancelar_agendamento(p_codigo text, p_telefone text)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare a public.agendamentos%rowtype;
begin
  select * into a from public.agendamentos ag
   where ag.codigo = upper(btrim(p_codigo))
     and ag.cliente_telefone = regexp_replace(coalesce(p_telefone,''), '\D', '', 'g');

  if not found then
    raise exception 'NAO_ENCONTRADO' using hint = 'Código ou telefone não confere.';
  end if;
  if a.status = 'cancelado' then
    return 'JA_CANCELADO';
  end if;
  if a.status <> 'confirmado' then
    raise exception 'NAO_CANCELAVEL' using hint = 'Esse horário já foi atendido.';
  end if;
  if (a.data + a.inicio) < public.agora_bahia() + interval '2 hours' then
    raise exception 'PRAZO_ESGOTADO'
      using hint = 'O cancelamento pelo site vai até 2h antes. Fale no WhatsApp.';
  end if;

  update public.agendamentos set status = 'cancelado', cancelado_em = now() where id = a.id;
  return 'CANCELADO';
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões: o visitante só chama estas funções.
-- slots_barbeiro fica fechado: é peça interna das outras.
-- ---------------------------------------------------------------------
revoke all on function public.slots_barbeiro(date, uuid, uuid)                     from public;
revoke all on function public.slots_disponiveis(date, uuid, uuid)                  from public;
revoke all on function public.dias_disponiveis(uuid, uuid)                         from public;
revoke all on function public.criar_agendamento(uuid,uuid,text,text,date,time,text) from public;
revoke all on function public.consultar_agendamento(text,text)                     from public;
revoke all on function public.cancelar_agendamento(text,text)                      from public;

grant execute on function public.slots_disponiveis(date, uuid, uuid)                  to anon, authenticated;
grant execute on function public.dias_disponiveis(uuid, uuid)                         to anon, authenticated;
grant execute on function public.criar_agendamento(uuid,uuid,text,text,date,time,text) to anon, authenticated;
grant execute on function public.consultar_agendamento(text,text)                     to anon, authenticated;
grant execute on function public.cancelar_agendamento(text,text)                      to anon, authenticated;

-- =====================================================================
--  DADOS INICIAIS — Trevus Barbearia
-- =====================================================================

insert into public.barbeiros (slug, nome, foto, instagram, ordem) values
  ('kelson', 'Kelson', 'fotos/kelson.jpg', 'kelsonsbarbershop', 1),
  ('junior', 'Júnior', 'fotos/junior.jpg', null,                2),
  ('hariel', 'Hariel', 'fotos/hariel.jpg', 'harielbarber13',    3)
on conflict (slug) do update set
  nome = excluded.nome, foto = excluded.foto, instagram = excluded.instagram, ordem = excluded.ordem;

-- Expediente (igual ao MinhaAgenda):
--   Dom 08-12 · Seg 14-18 · Ter a Sáb 08-20 com almoço 12-13
insert into public.expediente (dia_semana, aberto, abre, fecha, pausa_inicio, pausa_fim) values
  (0, true, '08:00', '12:00', null,    null),
  (1, true, '14:00', '18:00', null,    null),
  (2, true, '08:00', '20:00', '12:00', '13:00'),
  (3, true, '08:00', '20:00', '12:00', '13:00'),
  (4, true, '08:00', '20:00', '12:00', '13:00'),
  (5, true, '08:00', '20:00', '12:00', '13:00'),
  (6, true, '08:00', '20:00', '12:00', '13:00')
on conflict (dia_semana) do update set
  aberto = excluded.aberto, abre = excluded.abre, fecha = excluded.fecha,
  pausa_inicio = excluded.pausa_inicio, pausa_fim = excluded.pausa_fim;

insert into public.servicos (slug, nome, descricao, categoria, preco_centavos, a_partir_de, duracao_min, ordem) values
  ('corte',             'Corte',               'Corte de cabelo e acabamento.',                     'Cabelo',        3000,  false, 30,  1),
  ('corte-tesoura',     'Corte na tesoura',    'Todo na tesoura, pra quem quer volume e caimento.', 'Cabelo',        3500,  false, 40,  2),
  ('corte-todo-um',     'Corte todo por um',   'Máquina num pente só, rápido e no ponto.',          'Cabelo',        2500,  false, 15,  3),
  ('corte-barba',       'Corte e barba',       'O combo completo. Sai pronto pra semana.',          'Combos',        4500,  false, 50,  4),
  ('corte-pigmentacao', 'Corte e pigmentação', 'Corte com pigmentação para fechar as falhas.',      'Combos',        4500,  false, 30,  5),
  ('barba',             'Barba',               'Toalha quente, navalha e finalização.',             'Barba',         2000,  false, 20,  6),
  ('bigode',            'Bigode',              'Alinhamento e acabamento do bigode.',               'Barba',          700,  false, 10,  7),
  ('acabamento',        'Acabamento (pé)',     'Aquele retoque entre um corte e outro.',            'Detalhes',      1000,  false, 10,  8),
  ('pigmentacao',       'Pigmentação',         'Realça o desenho do corte e da barba.',             'Detalhes',      1500,  false, 15,  9),
  ('sobrancelha',       'Sobrancelha',         'Desenho no ponto, sem exagero.',                    'Detalhes',      1500,  false, 10, 10),
  ('nevou',             'Nevou',               'Platinado. Consulte as condições com o barbeiro.',  'Procedimentos', 12000, true,  30, 11)
on conflict (slug) do update set
  nome = excluded.nome, descricao = excluded.descricao, categoria = excluded.categoria,
  preco_centavos = excluded.preco_centavos, a_partir_de = excluded.a_partir_de,
  duracao_min = excluded.duracao_min, ordem = excluded.ordem;

-- ---------------------------------------------------------------------
-- Depois de criar o login de cada sócio (Authentication > Users),
-- ligue o login ao barbeiro para o painel abrir já na agenda dele:
--   update barbeiros set user_id = (select id from auth.users where email = 'kelson@...') where slug = 'kelson';
--   update barbeiros set user_id = (select id from auth.users where email = 'junior@...') where slug = 'junior';
--   update barbeiros set user_id = (select id from auth.users where email = 'hariel@...') where slug = 'hariel';
-- ---------------------------------------------------------------------
