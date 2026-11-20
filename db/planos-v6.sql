-- =====================================================================
--  v6 (20/11/2026)
--  1. Materiais: lista de compras da casa (barbeiro_id nulo) e de cada
--     sócio. Só a equipe vê e mexe.
--  2. Assinante ilimitado (assinantes.ilimitado): marca quantas vezes
--     quiser. Combinado com os sócios só para o Natham (Parceria Zync).
-- =====================================================================

-- 1. Materiais ---------------------------------------------------------
create table if not exists public.materiais (
  id uuid primary key default gen_random_uuid(),
  barbeiro_id uuid references public.barbeiros(id) on delete cascade,   -- nulo = da barbearia
  nome text not null check (length(btrim(nome)) between 1 and 80),
  comprar boolean not null default false,
  obs text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.materiais enable row level security;
drop policy if exists materiais_equipe on public.materiais;
create policy materiais_equipe on public.materiais for all to authenticated
  using (public.e_socio()) with check (public.e_socio());
grant select, insert, update, delete on public.materiais to authenticated;

insert into public.materiais (barbeiro_id, nome)
select null, x from unnest(array['Galão de água','Copo descartável','Saco de lixo']) x
 where not exists (select 1 from public.materiais m where m.barbeiro_id is null and m.nome = x);

-- 2. Ilimitado ---------------------------------------------------------
alter table public.assinantes add column if not exists ilimitado boolean not null default false;

-- saldo: quem é ilimitado sempre tem 99 de cada item do plano
create or replace function public.saldo_bruto(p_assinante uuid, p_data date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare a public.assinantes%rowtype; p public.planos%rowtype; v_ini date; v_fim date; v_uso jsonb; k text; v_out jsonb := '{}';
        v_aj jsonb;
begin
  select * into a from public.assinantes where id = p_assinante;
  if not found or a.ciclo_inicio is null then return '{}'; end if;
  select * into p from public.planos where id = a.plano_id;
  if a.ilimitado then
    for k in select jsonb_object_keys(p.cotas) loop v_out := v_out || jsonb_build_object(k, 99); end loop;
    return v_out;
  end if;
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

drop function if exists public.meu_plano();
create or replace function public.meu_plano()
returns table (id uuid, nome text, email text, telefone text, foto text, status text, ciclo_inicio date, vence_em date,
               proximo_pago boolean, plano text, plano_preco integer, cotas jsonb, saldo jsonb,
               barbeiro_id uuid, barbeiro text, barbeiro_foto text, socio boolean, pacote uuid[], cortesia boolean,
               multa integer, cartao_pct integer, sem_trava boolean, ilimitado boolean)
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
           case when exists (select 1 from public.infinitepay_chaves k where k.barbeiro_id = a.barbeiro_id) then p.cartao_pct else 0 end,
           p.sem_trava, a.ilimitado
      from public.assinantes a
      join public.planos p on p.id = a.plano_id
      left join public.barbeiros b on b.id = a.barbeiro_id
     where a.id = v_id;
end;
$$;
revoke all on function public.meu_plano() from public, anon, authenticated;
grant execute on function public.meu_plano() to authenticated;

-- o Natham (Parceria Zync): ilimitado e escolhe o serviço a cada marcação
-- (corte, barba, corte e barba, sobrancelha), já que marca também pra família.
update public.assinantes set ilimitado = true where lower(email) = 'nathamgil10@gmail.com';
update public.planos set pacote = null where slug = 'parceria';

-- conferência
select a.nome, a.email, p.nome plano, a.ilimitado, public.saldo_plano(a.id) saldo
  from public.assinantes a join public.planos p on p.id = a.plano_id where a.ilimitado;
select nome, comprar from public.materiais order by criado_em;
