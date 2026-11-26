-- =====================================================================
--  v9 (26/11/2026) — Aba "Planos" (pedido do Kelson): quem pagou o mês,
--  quem está em aberto e quanto falta de saldo, para todos os barbeiros.
--  lista_assinantes ganha preço, sem_trava, último pagamento e pago_ciclo.
--  pago_ciclo:
--    cortesia            -> null (parceria, não paga)
--    vencido             -> false
--    plano normal ativo  -> true  (ativo = mês pago; senão travaria)
--    plano sem trava     -> pagou dentro do ciclo atual (desde ciclo_inicio)
-- =====================================================================
drop function if exists public.lista_assinantes();
create function public.lista_assinantes()
returns table (id uuid, nome text, telefone text, email text, foto text, status text, vence_em date, proximo_pago boolean,
               plano text, barbeiro_id uuid, barbeiro text, saldo jsonb, cotas jsonb, tem_acesso boolean, origem text, cortesia boolean,
               plano_id uuid, ciclo_inicio date, obs text, criado_em timestamptz,
               preco_centavos integer, multa_centavos integer, sem_trava boolean, ultimo_pago date, pago_ciclo boolean)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.e_socio() then raise exception 'SO_SOCIOS'; end if;
  perform public.atualiza_ciclos();
  return query
    select a.id, a.nome, a.telefone, a.email, a.foto, a.status, a.vence_em, a.proximo_pago, p.nome, a.barbeiro_id,
           coalesce(b.nome, 'Qualquer barbeiro'),
           case when a.status = 'ativo' then public.saldo_plano(a.id) else '{}'::jsonb end, p.cotas,
           a.user_id is not null, a.origem, a.cortesia, a.plano_id, a.ciclo_inicio, a.obs, a.criado_em,
           p.preco_centavos, coalesce(p.multa_centavos, 0), coalesce(p.sem_trava, false), u.dia,
           case when a.cortesia then null
                when a.status <> 'ativo' then false
                when not coalesce(p.sem_trava, false) then true
                else coalesce(u.dia >= a.ciclo_inicio, false) end
      from public.assinantes a
      join public.planos p on p.id = a.plano_id
      left join public.barbeiros b on b.id = a.barbeiro_id
      left join lateral (select max((pg.pago_em at time zone 'America/Bahia')::date) dia
                           from public.pagamentos_plano pg where pg.assinante_id = a.id and pg.status = 'pago') u on true
     order by case a.status when 'vencido' then 0 when 'ativo' then 1 when 'aguardando_pagamento' then 2 else 3 end,
              a.vence_em nulls last, a.nome;
end;
$$;
revoke all on function public.lista_assinantes() from public, anon;
grant execute on function public.lista_assinantes() to authenticated;
