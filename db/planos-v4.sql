-- =====================================================================
--  Trevus Barbearia — PLANOS v4 (29/10/2026)
--  Rode DEPOIS de planos-v3.sql. Pode rodar de novo.
--
--    · Multa fixa por atraso: depois do vencimento a mensalidade em aberto
--      passa a ser preço + planos.multa_centavos (padrão R$ 10).
--    · Preço no cartão: planos.cartao_pct (padrão 5%) a mais que o Pix.
--      Só vale para o barbeiro que tiver a chave de API da InfinitePay em
--      infinitepay_chaves (sem a chave, o link sai com um preço só).
-- =====================================================================

alter table public.planos add column if not exists multa_centavos integer not null default 1000 check (multa_centavos >= 0);
alter table public.planos add column if not exists cartao_pct integer not null default 5 check (cartao_pct between 0 and 30);
alter table public.pagamentos_plano add column if not exists multa_centavos integer not null default 0;

-- Chave de API da InfinitePay de cada barbeiro. Sem policy: ninguém lê pelo
-- site, só a função "pagamento" (service_role).
create table if not exists public.infinitepay_chaves (
  barbeiro_id uuid primary key references public.barbeiros(id) on delete cascade,
  api_key     text not null check (api_key like 'inchk\_%'),
  criado_em   timestamptz not null default now()
);
alter table public.infinitepay_chaves enable row level security;
revoke all on public.infinitepay_chaves from anon, authenticated;

-- Cobrança do mês. Vencido (mensalidade atrasada) = preço + multa.
-- Se já existia uma cobrança sem multa, ela é trocada por uma nova.
create or replace function public.cobranca_aberta(p_assinante uuid)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare a public.assinantes%rowtype; p public.planos%rowtype; v uuid; v_valor integer; v_multa integer := 0; v_atual integer;
begin
  perform public.atualiza_ciclo(p_assinante);
  select * into a from public.assinantes where id = p_assinante;
  if not found or a.status = 'cancelado' or a.cortesia then return null; end if;
  if a.status = 'ativo' and a.proximo_pago then return null; end if;
  select * into p from public.planos where id = a.plano_id;
  if a.status = 'vencido' then v_multa := p.multa_centavos; end if;
  v_valor := p.preco_centavos + v_multa;
  select id, valor_centavos into v, v_atual from public.pagamentos_plano
   where assinante_id = a.id and status = 'pendente' order by criado_em desc limit 1;
  if v is not null and v_atual <> v_valor then
    update public.pagamentos_plano set status = 'cancelado' where id = v;
    v := null;
  end if;
  if v is null then
    insert into public.pagamentos_plano (assinante_id, valor_centavos, multa_centavos)
    values (a.id, v_valor, v_multa) returning id into v;
  end if;
  return v;
end;
$$;

-- Pagamento do mês. Aceita até 50 centavos a menos (arredondamento do
-- desconto do Pix na InfinitePay). Um link antigo pago depois de cancelado
-- (trocado pela cobrança com multa) ainda vale: o cliente pagou.
create or replace function public.registrar_pagamento_plano(p_id uuid, p_pago integer, p_dados jsonb, p_forma text default 'site')
returns text
language plpgsql volatile security definer set search_path = public as $$
declare pg public.pagamentos_plano%rowtype; a public.assinantes%rowtype; v_hoje date := public.agora_bahia()::date; v_res text;
begin
  select * into pg from public.pagamentos_plano where id = p_id for update;
  if not found then return 'NAO_ENCONTRADO'; end if;
  if pg.status = 'pago' then return 'JA_PAGO'; end if;
  if p_pago < pg.valor_centavos - 50 then return 'VALOR_MENOR'; end if;
  perform public.atualiza_ciclo(pg.assinante_id);
  select * into a from public.assinantes where id = pg.assinante_id for update;

  if a.status = 'ativo' and v_hoje < a.vence_em and not a.proximo_pago then
    update public.assinantes set proximo_pago = true where id = a.id;
    v_res := 'RENOVADO';
  elsif a.status = 'ativo' and a.proximo_pago then
    v_res := 'JA_ADIANTADO';
  else
    update public.assinantes set status = 'ativo', ciclo_inicio = v_hoje,
           vence_em = (v_hoje + interval '1 month')::date, proximo_pago = false
     where id = a.id;
    v_res := case when a.status = 'aguardando_pagamento' then 'ATIVADO' else 'REATIVADO' end;
  end if;

  update public.pagamentos_plano set status = 'pago', pago_em = now(), pagamento = p_dados, forma = coalesce(p_forma, 'site')
   where id = pg.id;
  -- outra cobrança aberta do mesmo assinante deixa de valer
  update public.pagamentos_plano set status = 'cancelado'
   where assinante_id = pg.assinante_id and status = 'pendente' and id <> pg.id;
  return v_res;
end;
$$;

-- a área do assinante e o site mostram multa e preço no cartão
drop function if exists public.meu_plano();
create or replace function public.meu_plano()
returns table (id uuid, nome text, email text, telefone text, foto text, status text, ciclo_inicio date, vence_em date,
               proximo_pago boolean, plano text, plano_preco integer, cotas jsonb, saldo jsonb,
               barbeiro_id uuid, barbeiro text, barbeiro_foto text, socio boolean, pacote uuid[], cortesia boolean,
               multa integer, cartao_pct integer)
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
           b.id, b.nome, b.foto, public.e_socio(), p.pacote, a.cortesia,
           p.multa_centavos,
           case when exists (select 1 from public.infinitepay_chaves k where k.barbeiro_id = a.barbeiro_id) then p.cartao_pct else 0 end
      from public.assinantes a
      join public.planos p on p.id = a.plano_id
      left join public.barbeiros b on b.id = a.barbeiro_id
     where a.id = v_id;
end;
$$;

do $$ declare f text; begin
  foreach f in array array['cobranca_aberta(uuid)', 'registrar_pagamento_plano(uuid,integer,jsonb,text)', 'meu_plano()'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
end $$;
grant execute on function public.cobranca_aberta(uuid) to service_role;
grant execute on function public.registrar_pagamento_plano(uuid,integer,jsonb,text) to service_role;
grant execute on function public.meu_plano() to authenticated;
