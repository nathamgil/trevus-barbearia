-- =====================================================================
--  planos-v5 (17/11/2026): "Marcar pelo plano" no painel aceita escolher
--  o serviço quando o plano não tem pacote fixo (ex.: plano do Jean, com
--  corte e barba + cortes avulsos). Sem p_servicos continua igual:
--  usa o pacote do plano.
-- =====================================================================
drop function if exists public.agendar_plano_painel(uuid, uuid, date, time, integer);
create or replace function public.agendar_plano_painel(p_assinante uuid, p_barbeiro uuid, p_data date, p_inicio time,
                                                       p_dur integer default null, p_servicos uuid[] default null)
returns uuid language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  if p_dur is not null and (p_dur < 5 or p_dur > 480) then raise exception 'DURACAO_INVALIDA' using hint = 'A duração vai de 5 a 480 minutos.'; end if;
  return public.marca_plano(p_assinante, p_servicos, p_barbeiro, p_data, p_inicio, p_dur, null, 'balcao', false);
end;
$$;
revoke all on function public.agendar_plano_painel(uuid,uuid,date,time,integer,uuid[]) from public, anon;
grant execute on function public.agendar_plano_painel(uuid,uuid,date,time,integer,uuid[]) to authenticated;

-- =====================================================================
--  Planos "sem trava" (17/11/2026, regra do Kelson): o saldo volta cheio
--  todo mês no dia do vencimento, mesmo sem pagamento. Não trava, não
--  tem multa e não manda o aviso de "vai travar". Só nos planos marcados.
-- =====================================================================
alter table public.planos add column if not exists sem_trava boolean not null default false;

create or replace function public.atualiza_ciclo(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a public.assinantes%rowtype; v_hoje date := public.agora_bahia()::date; v_livre boolean;
begin
  select * into a from public.assinantes where id = p_id for update;
  if not found or a.status <> 'ativo' then return; end if;
  select coalesce(p.sem_trava, false) into v_livre from public.planos p where p.id = a.plano_id;
  while a.vence_em is not null and v_hoje >= a.vence_em loop
    if a.proximo_pago or a.cortesia or v_livre then
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

-- sem trava: só o lembrete de 3 dias (com o link de pagar); nada de "vai travar"
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
     where t.tipo is not null and not a.cortesia and a.email is not null
       and coalesce(a.ultimo_aviso, '') <> a.vence_em::text || ':' || t.tipo;
end;
$$;

drop function if exists public.meu_plano();
create or replace function public.meu_plano()
returns table (id uuid, nome text, email text, telefone text, foto text, status text, ciclo_inicio date, vence_em date,
               proximo_pago boolean, plano text, plano_preco integer, cotas jsonb, saldo jsonb,
               barbeiro_id uuid, barbeiro text, barbeiro_foto text, socio boolean, pacote uuid[], cortesia boolean,
               multa integer, cartao_pct integer, sem_trava boolean)
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
           p.sem_trava
      from public.assinantes a
      join public.planos p on p.id = a.plano_id
      left join public.barbeiros b on b.id = a.barbeiro_id
     where a.id = v_id;
end;
$$;
revoke all on function public.meu_plano() from public, anon, authenticated;
grant execute on function public.meu_plano() to authenticated;
grant execute on function public.avisos_planos() to service_role;
