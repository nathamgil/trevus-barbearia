# Trevus Barbearia — site com agendamento

Site + agendamento próprio da Trevus Barbearia (Kelson, Júnior e Hariel),
Rua Sérgio de Carvalho, 28, Federação, Salvador — BA.

O cliente escolhe o **barbeiro** (ou "sem preferência"), o serviço, o dia e a
hora, e confirma na hora. Cada sócio tem a própria agenda e as próprias folgas,
e acompanha tudo em `/admin`. Sem app de terceiro e sem mensalidade de plataforma.

---

## Arquivos

```
index.html          site público + agendamento em 4 passos
admin.html          painel dos barbeiros (agenda por sócio, folgas, status)
assets/config.js    ÚNICO arquivo a editar (chaves, WhatsApp, horários, dados da demo)
assets/estilo.css   visual (verde + dourado, tirado do escudo da marca)
assets/agenda.js    motor do agendamento
db/schema.sql       banco: tabelas, segurança e regras (rodar 1x no Supabase)
fotos/              imagens do site (tiradas do Instagram da Trevus)
```

## Estado atual: MODO DEMONSTRAÇÃO

Com `supabaseUrl` e `supabaseKey` vazios em `assets/config.js`, o site funciona
inteiro, mas os horários ficam guardados **só no navegador de quem está olhando**.
A agenda da demo já vem com clientes de exemplo, marcados como "(exemplo)",
para os sócios verem como fica um dia cheio. O `/admin` abre sem login.

## Ligando de verdade (uns 20 minutos)

1. **Criar o banco:** em [supabase.com](https://supabase.com), clique em *New project* e escolha a região
   **South America (São Paulo)**. Crie **no e-mail da barbearia**, para que a
   conta e a base de clientes fiquem com eles. O plano grátis dá e sobra.
2. **Rodar o schema:** abra *SQL Editor*, clique em *New query*, cole o `db/schema.sql` inteiro e clique em *Run*.
   Já cadastra os 3 barbeiros, os 11 serviços e o expediente.
3. **Pegar as chaves:** em *Settings*, vá em *API* e copie a **Project URL** e a chave **anon public** para o
   `assets/config.js`.
4. **Criar o login de cada sócio:** em *Authentication*, vá em *Users* e clique em *Add user* (3 vezes).
   Em *Providers*, **desligue "Enable signup"**. Depois ligue cada login ao
   barbeiro com o `update barbeiros set user_id = ...` que está no fim do schema.
   Assim cada um abre o painel já na própria agenda.
5. **Publicar:** faça commit e push, e ative o GitHub Pages na branch `main`.

## Custos para a barbearia

| Item | Custo |
|---|---|
| Hospedagem (GitHub Pages) | R$ 0 |
| Banco da agenda (Supabase Free) | R$ 0 |
| Domínio próprio (.com.br, Registro.br) | opcional, R$ 40/ano |

O plano grátis do Supabase pausa o projeto depois de **7 dias sem nenhum
acesso**. Com agendamento todo dia isso não acontece. Se a casa fechar por férias
longas, basta entrar no painel do Supabase e clicar em *Restore*.

## Regras da agenda

| regra | valor | onde muda |
|---|---|---|
| Grade de horários | 10 em 10 min | `slots_barbeiro` |
| Antecedência mínima | 30 min | `slots_barbeiro` |
| Janela de agendamento | 30 dias | `slots_barbeiro` |
| Cancelamento pelo cliente | até 2h antes | `cancelar_agendamento` |
| Máx. horários futuros por telefone | 3 | `criar_agendamento` |
| "Sem preferência" | vai para o barbeiro livre com menos clientes no dia | `criar_agendamento` |

Expediente: Dom 8–12 · Seg 14–18 · Ter a Sáb 8–20, com almoço das 12 às 13.

> Mudou uma regra? Mude nos **dois** lugares (`config.js` e `db/schema.sql`).
> Quem manda de verdade é o banco. O site é só a vitrine.

## Segurança e privacidade

- A chave `anon` aparece no código do site. Isso é normal: quem protege os dados
  é o **RLS** + as funções do `schema.sql`.
- O visitante **não lê a tabela de agendamentos**. Ele só chama funções: ver
  horários, marcar, e consultar ou cancelar o próprio horário (exige código **e** telefone).
- Dois clientes no mesmo horário com o mesmo barbeiro: o banco recusa o segundo
  (constraint de exclusão por barbeiro). Não depende do JavaScript.
- LGPD: guarda-se só nome + WhatsApp, com finalidade declarada no rodapé.

## Rodando local

```bash
python -m http.server 5520
```

Depois abra `http://localhost:5520`.

## Ficou de fora de propósito

- Lembrete automático no WhatsApp na véspera (exige API paga da Meta)
- Pagamento ou sinal antecipado
- Lançar no painel o cliente que chegou por ordem de chegada
- Galeria de cortes (esperando fotos dos trabalhos)
