# Trevus Barbearia — site com agendamento e sinal no Pix

Site + agendamento próprio da Trevus Barbearia (Kelson, Júnior e Hariel),
Rua Sérgio de Carvalho, 28, Federação, Salvador — BA.

O cliente escolhe o **barbeiro** (ou "sem preferência"), **um ou mais serviços**,
o dia e a hora, e paga **50% de sinal** no Pix. O sinal cai na conta
**InfinitePay do barbeiro** do horário. O horário confirma sozinho quando o Pix
cai. Os sócios acompanham tudo em `/admin`.

---

## Arquivos

```
index.html                         site público + agendamento em 5 passos
admin.html                         painel dos barbeiros
assets/config.js                   chaves, WhatsApp, regras, expediente, dados da demo
assets/estilo.css                  visual (verde + dourado, do escudo da marca)
assets/agenda.js                   motor do agendamento (site)
db/schema.sql                      banco: tabelas, segurança e regras (rodar no Supabase)
supabase/functions/pagamento/      servidor do pagamento: InfinitePay + e-mails
fotos/                             imagens do site
```

## Regras (alinhamento de 24/09/2026)

| regra | valor |
|---|---|
| Grade de horários | 30 em 30 min |
| Agenda aberta | 15 dias |
| Antecedência mínima | 30 min |
| Sinal | 50% do total, no Pix, para o barbeiro do horário |
| Vaga segurada esperando o Pix | 15 min |
| Cliente cancela | até 1h antes; o sinal vira **crédito com o mesmo barbeiro** |
| Cliente remarca | até 1h antes, até 2 vezes, com o mesmo barbeiro |
| Cliente falta | sinal fica com a barbearia (painel: "Não veio") |
| Barbearia desmarca | painel lista "devolver R$ X"; devolução pelo app da InfinitePay |
| Sem preferência | vai para quem já tem crédito do cliente, depois para quem está com menos clientes |
| Feriado | 8h–17h (local) ou 8h–12h (nacional), sem almoço |

Expediente: Ter a Sáb 8h–20h com almoço 12h–13h · Dom 8h–12h ·
**segunda só o Kelson, 14h–20h** · **terça sem o Hariel**.

> As regras vivem no `db/schema.sql` (quem manda) e se repetem no
> `assets/config.js` (para a tela e a demo). Mudou uma, mude as duas.

## Estado atual: MODO DEMONSTRAÇÃO

Com `supabaseUrl` vazio no `config.js`, tudo funciona na tela e fica guardado
no navegador de quem está olhando. O Pix é **simulado** (botão "Pagar o sinal"
confirma na hora). A agenda já vem com clientes "(exemplo)".

## Colocando no ar

### 1. Contas que a Trevus cria (no e-mail trevusbarbearia77@gmail.com)
- **Supabase** (supabase.com), região South America (São Paulo), plano grátis.
- **Brevo** (brevo.com), plano grátis com 300 e-mails/dia. Verificar o e-mail remetente.
- **InfinitePay, uma por sócio**, no CPF de cada um. Em cada app: *Vendas >
  Checkout > Configurações* > ativar o Checkout Integrado. Anotar a
  **InfiniteTag** de cada um (o `$nome`, sem o `$`).

### 2. Banco
1. Supabase > *SQL Editor* > cole o `db/schema.sql` inteiro > *Run*.
2. *Authentication > Users > Add user* para os 3 sócios. Em *Providers*,
   **desligue "Enable signup"**.
3. No SQL Editor, rode os `update barbeiros ...` do fim do schema (liga o login
   de cada um e cadastra a InfiniteTag de cada um).

### 3. Servidor do pagamento
```bash
npx supabase login
npx supabase link --project-ref <ref-do-projeto>
npx supabase functions deploy pagamento --no-verify-jwt
npx supabase secrets set SITE_URL=https://trevusbarbearia.com.br BREVO_API_KEY=... EMAIL_REMETENTE=... EMAIL_BARBEARIA=trevusbarbearia77@gmail.com CRON_SECRET=<senha-longa>
```

Lembrete da véspera (todo dia às 18h de Salvador = 21h UTC). No SQL Editor:
```sql
create extension if not exists pg_cron; create extension if not exists pg_net;
select cron.schedule('lembretes-trevus', '0 21 * * *', $$
  select net.http_post(
    url := 'https://<ref>.supabase.co/functions/v1/pagamento?acao=lembretes',
    headers := '{"Content-Type":"application/json","x-cron-secret":"<senha-longa>"}'::jsonb,
    body := '{}'::jsonb)
$$);
```

### 4. Site
Cole a *Project URL* e a chave *anon public* em `assets/config.js`, faça o commit
e o push. Com o domínio próprio, aponte o DNS para o GitHub Pages e crie o
arquivo `CNAME`.

### 5. Teste antes de anunciar
Um agendamento de verdade com cada barbeiro, com um serviço barato, para confirmar
que o Pix cai na conta certa, que o horário confirma sozinho e que os dois
e-mails chegam. Depois, desmarque pelo painel e devolva pelo app.

## Custos para a barbearia

| item | custo |
|---|---|
| Hospedagem (GitHub Pages) | R$ 0 |
| Banco + servidor (Supabase Free) | R$ 0 |
| E-mails (Brevo Free, 300/dia) | R$ 0 |
| Sinal no Pix (InfinitePay) | taxa da InfinitePay por venda (conferir no app de cada um) |
| Domínio .com.br | R$ 40/ano |

O Supabase grátis pausa depois de 7 dias **sem nenhum acesso**. Com agendamento
diário isso não acontece.

## Segurança

- A chave `anon` é pública. Quem protege é o RLS + as funções do schema.
- O visitante não lê agendamentos, créditos nem a InfiniteTag. Ele só chama funções:
  ver horários, marcar, acompanhar o pagamento, consultar, cancelar e remarcar
  o próprio horário (código **e** telefone).
- **Só o servidor confirma pagamento** (`registrar_pagamento` é exclusivo da
  chave de serviço), e só depois de perguntar à InfinitePay (`payment_check`).
  Um webhook falso não confirma nada.
- Dois clientes no mesmo horário com o mesmo barbeiro: o banco recusa
  (constraint de exclusão), inclusive enquanto um deles está pagando.

## Testes

O schema foi testado num Postgres real (PGlite) com 36 cenários: agenda por
barbeiro, almoço, feriado, sinal, crédito, remarcação, Pix vencido e
permissões. A função de pagamento foi testada com a InfinitePay, o banco e o
Brevo simulados (14 cenários, incluindo webhook falso).

## Pendências da Trevus

- Preço das **luzes** e da **remoção de pelos nasais** (já cadastrados, desligados)
- O que o **Hyper Trevus** inclui (`config.js > planos`)
- Bairro: Federação ou Vasco da Gama
- Corte infantil a R$ 35 (mais caro que o adulto): confirmar
- Regra dos **10% de desconto** quando o barbeiro desmarca em cima da hora ou falta
- Fotos dos cortes, fotos individuais e logo em PNG

## Fase 2

Login do cliente, planos de assinatura (sem sinal para assinante), importar
clientes do MinhaAgenda.
