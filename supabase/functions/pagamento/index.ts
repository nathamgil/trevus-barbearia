// =====================================================================
//  Trevus Barbearia — função "pagamento" (Supabase Edge Function, Deno)
//
//  ?acao=cobrar     site pede o link de Pix/cartão do sinal (InfinitePay)
//  ?acao=verificar  site confere o pagamento quando o cliente volta
//  ?acao=webhook    a InfinitePay avisa que o pagamento caiu
//  ?acao=confirmado site avisa que um horário pago com crédito foi criado
//  ?acao=lembretes  rodado 1x por dia pelo agendador (pg_cron)
//
//  Planos mensais (db/planos.sql):
//  ?acao=cobrar_plano     link do mês inteiro (order_nsu "plano-<id do pagamento>")
//  ?acao=verificar_plano  site confere quando o cliente volta do pagamento
//  ?acao=acesso           e-mail com o link para o assinante criar a senha
//  ?acao=convidar         o painel manda o acesso a quem pagou no balcão (só sócio)
//  O webhook e os lembretes já cuidam dos planos também.
//
//  O sinal cai na conta InfinitePay DO BARBEIRO do horário: cada um tem a
//  sua InfiniteTag em barbeiros.infinitepay_handle.
//
//  Variáveis (Supabase > Edge Functions > Secrets):
//    SITE_URL         ex: https://trevusbarbearia.com.br
//    BREVO_API_KEY    chave da conta Brevo da barbearia (e-mails)
//    EMAIL_REMETENTE  e-mail verificado no Brevo
//    EMAIL_BARBEARIA  quem recebe o aviso de cada agendamento
//  SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já vêm do Supabase.
//
//  Publicar:  supabase functions deploy pagamento --no-verify-jwt
//  (sem JWT porque a InfinitePay não manda token no webhook; quem
//   protege é a conferência no payment_check, abaixo)
// =====================================================================

const SB_URL   = Deno.env.get("SUPABASE_URL")!;
const SB_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE_URL = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");
const BREVO    = Deno.env.get("BREVO_API_KEY") ?? "";
const REMETENTE = Deno.env.get("EMAIL_REMETENTE") ?? "";
const BARBEARIA = Deno.env.get("EMAIL_BARBEARIA") ?? "";

const IP_API = "https://api.checkout.infinitepay.io";
const ENDERECO = "Rua Sérgio de Carvalho, 28 - Federação, Salvador - BA";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// ---------------- banco (PostgREST com a chave de serviço) ----------------

async function banco(caminho: string, init: RequestInit = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${caminho}`, {
    ...init,
    headers: {
      apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`,
      "Content-Type": "application/json", Prefer: "return=representation",
      ...(init.headers ?? {}),
    },
  });
  const texto = await r.text();
  const corpo = texto ? JSON.parse(texto) : null;
  if (!r.ok) throw new Error(corpo?.message ?? `banco ${r.status}`);
  return corpo;
}
const rpc = (fn: string, args: Record<string, unknown>) =>
  banco(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

async function agendamento(id: string) {
  const l = await banco(`agendamentos?id=eq.${encodeURIComponent(id)}&select=*,barbeiros(infinitepay_handle)`);
  return l?.[0] ?? null;
}

// ---------------- InfinitePay ----------------

async function criarLink(a: any) {
  const handle = a.barbeiros?.infinitepay_handle;
  if (!handle) throw new Error("Esse barbeiro ainda não tem InfiniteTag cadastrada.");
  const valor = a.sinal_centavos - a.credito_usado;
  const tel = String(a.cliente_telefone).replace(/\D/g, "");
  const r = await fetch(`${IP_API}/links`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      handle,
      order_nsu: a.id,
      items: [{ quantity: 1, price: valor, description: `Sinal 50% - ${a.servico_nome} com ${a.barbeiro_nome}` }],
      redirect_url: `${SITE_URL}/?pagamento=${a.id}`,
      webhook_url: `${SB_URL}/functions/v1/pagamento?acao=webhook`,
      customer: { name: a.cliente_nome, email: a.cliente_email, phone_number: `+55${tel.replace(/^55/, "")}` },
      // Endereço da barbearia (serviço presencial): sem ele o checkout pede o
      // endereço do cliente antes de mostrar o Pix.
      address: { cep: "40230680", number: "28" },
    }),
  });
  const corpo = await r.json().catch(() => ({}));
  const url = corpo.url ?? corpo.link ?? corpo.checkout_url ?? corpo.data?.url;
  if (!r.ok || !url) throw new Error("A InfinitePay não gerou o link de pagamento. Tente de novo.");
  return url as string;
}

// Nunca confiar só no webhook ou no redirect: pergunta à InfinitePay.
async function conferir(handle: string, orderNsu: string, transactionNsu: string, slug: string) {
  const r = await fetch(`${IP_API}/payment_check`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ handle, order_nsu: orderNsu, transaction_nsu: transactionNsu, slug }),
  });
  const c = await r.json().catch(() => ({}));
  return { pago: !!c.paid, valor: Number(c.paid_amount ?? c.amount ?? 0), dados: c };
}

async function processarPagamento(id: string, transactionNsu: string, slug: string, extra: Record<string, unknown> = {}) {
  const a = await agendamento(id);
  if (!a) return "NAO_ENCONTRADO";
  if (a.sinal_status === "pago") return "JA_PAGO";
  const handle = a.barbeiros?.infinitepay_handle;
  if (!handle) return "SEM_HANDLE";
  const c = await conferir(handle, id, transactionNsu, slug);
  if (!c.pago) return "NAO_PAGO";
  const res = await rpc("registrar_pagamento", {
    p_id: id, p_pago: c.valor,
    p_dados: { ...extra, ...c.dados, transaction_nsu: transactionNsu, slug },
  });
  if (res === "CONFIRMADO" || res === "CONFIRMADO_ATRASADO") await emailConfirmacao(id).catch(console.error);
  return res;
}

// ---------------- e-mails (Brevo) ----------------

const dataBR = (d: string) => d.split("-").reverse().join("/");
const hora = (t: string) => String(t).slice(0, 5);
const reais = (c: number) => "R$ " + (c / 100).toFixed(2).replace(".", ",");

function ics(a: any) {
  const carimbo = (d: string, h: string) => d.replace(/-/g, "") + "T" + hora(h).replace(":", "") + "00";
  return [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Trevus Barbearia//PT-BR", "METHOD:REQUEST",
    "BEGIN:VEVENT",
    `UID:${a.codigo}@trevusbarbearia`,
    `DTSTAMP:${new Date().toISOString().replace(/[-:]/g, "").slice(0, 15)}Z`,
    `DTSTART;TZID=America/Bahia:${carimbo(a.data, a.inicio)}`,
    `DTEND;TZID=America/Bahia:${carimbo(a.data, a.fim)}`,
    `SUMMARY:${a.servico_nome} com ${a.barbeiro_nome} - Trevus Barbearia`,
    `LOCATION:${ENDERECO}`,
    `DESCRIPTION:Código ${a.codigo}. Cancele ou remarque pelo site até 1h antes.`,
    `ORGANIZER;CN=Trevus Barbearia:mailto:${REMETENTE}`,
    `ATTENDEE;CN=${a.cliente_nome};RSVP=FALSE:mailto:${a.cliente_email}`,
    "BEGIN:VALARM", "TRIGGER:-PT2H", "ACTION:DISPLAY", "DESCRIPTION:Trevus Barbearia daqui a 2h", "END:VALARM",
    "END:VEVENT", "END:VCALENDAR",
  ].join("\r\n");
}

async function enviar(para: string, assunto: string, html: string, anexoIcs?: string) {
  if (!BREVO || !REMETENTE || !para) return false;
  const r = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": BREVO, "Content-Type": "application/json" },
    body: JSON.stringify({
      sender: { name: "Trevus Barbearia", email: REMETENTE },
      to: [{ email: para }],
      subject: assunto,
      htmlContent: html,
      ...(anexoIcs ? { attachment: [{ name: "horario-trevus.ics", content: btoa(unescape(encodeURIComponent(anexoIcs))) }] } : {}),
    }),
  });
  return r.ok;
}

function cartao(a: any, titulo: string, texto: string) {
  const plano = a.sinal_status === "plano";
  const restante = plano ? 0 : a.preco_centavos - a.sinal_centavos;
  return `<div style="font-family:Arial,sans-serif;max-width:520px;margin:auto;color:#0F1F18">
    <div style="background:#0C1A13;color:#F3DB94;padding:18px 22px;border-radius:12px 12px 0 0;font-size:20px;letter-spacing:3px"><b>TREVUS</b> BARBEARIA</div>
    <div style="border:1px solid #CFD9D2;border-top:0;padding:22px;border-radius:0 0 12px 12px">
      <h2 style="margin:0 0 6px">${titulo}</h2><p style="margin:0 0 16px;color:#4A5C52">${texto}</p>
      <table style="width:100%;font-size:15px;border-collapse:collapse">
        <tr><td style="color:#4A5C52;padding:4px 0">Quando</td><td><b>${dataBR(a.data)} às ${hora(a.inicio)}</b></td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Com</td><td><b>${a.barbeiro_nome}</b></td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Serviço</td><td>${a.servico_nome}</td></tr>
        ${plano ? `<tr><td style="color:#4A5C52;padding:4px 0">Pagamento</td><td><b>Pelo seu plano</b></td></tr>`
          : `<tr><td style="color:#4A5C52;padding:4px 0">Sinal pago</td><td>${reais(a.sinal_centavos)}</td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Na barbearia</td><td><b>${reais(restante)}</b></td></tr>`}
        <tr><td style="color:#4A5C52;padding:4px 0">Código</td><td><b style="letter-spacing:3px">${a.codigo}</b></td></tr>
      </table>
      <p style="font-size:14px;color:#4A5C52;margin-top:16px">${ENDERECO}, galeria ao lado da JP Tintas.<br>
      Cancele ${plano ? "" : "ou remarque "}pelo site até 1h antes: <a href="${SITE_URL}/${plano ? "conta.html" : "#meu-horario"}">${SITE_URL.replace(/^https?:\/\//, "")}</a>.<br>
      Tolerância de atraso: 5 minutos.</p>
    </div></div>`;
}

async function emailConfirmacao(id: string) {
  const a = await agendamento(id);
  if (!a || a.status !== "confirmado" || a.email_enviado_em) return;
  await enviar(a.cliente_email, `Horário confirmado: ${dataBR(a.data)} às ${hora(a.inicio)} com ${a.barbeiro_nome}`,
    cartao(a, "Horário confirmado", "Seu horário está garantido. Toque no convite anexo para salvar na sua agenda."), ics(a));
  await enviar(BARBEARIA, `Novo agendamento: ${a.cliente_nome} · ${dataBR(a.data)} ${hora(a.inicio)} · ${a.barbeiro_nome}`,
    cartao(a, "Novo agendamento pelo site", `${a.cliente_nome} · WhatsApp ${a.cliente_telefone}`));
  await banco(`agendamentos?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ email_enviado_em: new Date().toISOString() }) });
}

async function lembretes() {
  const amanha = new Date(Date.now() - 3 * 3600e3 + 86400e3).toISOString().slice(0, 10); // dia seguinte em Salvador
  const lista = await banco(`agendamentos?data=eq.${amanha}&status=eq.confirmado&lembrete_enviado_em=is.null&cliente_email=not.is.null&select=*`);
  let n = 0;
  for (const a of lista ?? []) {
    if (await enviar(a.cliente_email, `Amanhã às ${hora(a.inicio)} com ${a.barbeiro_nome} na Trevus`,
      cartao(a, "Te esperamos amanhã", "Passando para lembrar do seu horário. Se não puder vir, cancele ou remarque pelo site com pelo menos 1h de antecedência."))) {
      await banco(`agendamentos?id=eq.${a.id}`, { method: "PATCH", body: JSON.stringify({ lembrete_enviado_em: new Date().toISOString() }) });
      n++;
    }
  }
  return n;
}

// ---------------- planos mensais ----------------

async function pagamentoPlano(id: string) {
  if (!/^[0-9a-f-]{36}$/i.test(String(id))) return null;
  const l = await banco(`pagamentos_plano?id=eq.${id}&select=*,assinantes(*,planos(nome,preco_centavos,itens),barbeiros(nome,infinitepay_handle))`);
  return l?.[0] ?? null;
}

async function linkPlano(pg: any) {
  const a = pg.assinantes, handle = a?.barbeiros?.infinitepay_handle;
  if (!handle) throw new Error("O barbeiro do plano ainda não tem InfiniteTag cadastrada.");
  const tel = String(a.telefone).replace(/\D/g, "");
  const r = await fetch(`${IP_API}/links`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      handle,
      order_nsu: `plano-${pg.id}`,
      items: [{ quantity: 1, price: pg.valor_centavos, description: `${a.planos.nome} - mensalidade com ${a.barbeiros.nome}` }],
      redirect_url: `${SITE_URL}/conta.html?plano=${pg.id}`,
      webhook_url: `${SB_URL}/functions/v1/pagamento?acao=webhook`,
      customer: { name: a.nome, email: a.email, phone_number: `+55${tel.replace(/^55/, "")}` },
      address: { cep: "40230680", number: "28" },
    }),
  });
  const corpo = await r.json().catch(() => ({}));
  const url = corpo.url ?? corpo.link ?? corpo.checkout_url ?? corpo.data?.url;
  if (!r.ok || !url) throw new Error("A InfinitePay não gerou o link de pagamento. Tente de novo.");
  return url as string;
}

// Link para o assinante criar (ou trocar) a senha, mandado pelo Brevo em
// português. Convite para quem ainda não tem login; recuperação para quem tem.
async function enviarAcesso(a: any, motivo: "novo" | "pedido") {
  const destino = `${SITE_URL}/conta.html`;
  const gerar = (type: string) => fetch(`${SB_URL}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ type, email: a.email, redirect_to: destino }),
  }).then(async (r) => ({ ok: r.ok, corpo: await r.json().catch(() => ({})) }));
  let g = await gerar("invite");
  if (!g.ok) g = await gerar("recovery");          // já tem login
  if (!g.ok) throw new Error("Não consegui gerar o link de acesso.");
  const link = g.corpo.action_link ?? g.corpo.properties?.action_link;
  const userId = g.corpo.id ?? g.corpo.user?.id;
  await banco(`assinantes?id=eq.${a.id}`, { method: "PATCH", body: JSON.stringify({
    acesso_enviado_em: new Date().toISOString(), ...(userId && !a.user_id ? { user_id: userId } : {}) }) });
  const titulo = motivo === "novo" ? "Bem-vindo ao plano! Crie seu acesso" : "Seu link para entrar";
  const texto = motivo === "novo"
    ? "Seu plano está ativo. Toque no botão para criar sua senha: na sua área você vê o saldo do mês, coloca sua foto e marca horário sem pagar sinal."
    : "Toque no botão para criar uma senha nova e entrar na sua área de assinante.";
  return enviar(a.email, motivo === "novo" ? "Seu plano Trevus está ativo: crie seu acesso" : "Acesse sua área de assinante Trevus",
    moldura(titulo, texto, `<p style="text-align:center;margin:22px 0"><a href="${link}" style="background:#D7AE4F;color:#1B1405;padding:14px 26px;border-radius:10px;font-weight:bold;text-decoration:none;display:inline-block">Criar minha senha</a></p>
     <p style="font-size:13px;color:#4A5C52">O link vale por 24 horas. Se vencer, peça outro em ${SITE_URL.replace(/^https?:\/\//, "")}/conta.html.</p>`));
}

function moldura(titulo: string, texto: string, miolo = "") {
  return `<div style="font-family:Arial,sans-serif;max-width:520px;margin:auto;color:#0F1F18">
    <div style="background:#0C1A13;color:#F3DB94;padding:18px 22px;border-radius:12px 12px 0 0;font-size:20px;letter-spacing:3px"><b>TREVUS</b> BARBEARIA</div>
    <div style="border:1px solid #CFD9D2;border-top:0;padding:22px;border-radius:0 0 12px 12px">
      <h2 style="margin:0 0 6px">${titulo}</h2><p style="margin:0 0 12px;color:#4A5C52">${texto}</p>${miolo}
      <p style="font-size:13px;color:#4A5C52;margin-top:16px">${ENDERECO}, galeria ao lado da JP Tintas.</p>
    </div></div>`;
}

const botaoPagar = (url: string, rotulo: string) =>
  `<p style="text-align:center;margin:22px 0"><a href="${url}" style="background:#D7AE4F;color:#1B1405;padding:14px 26px;border-radius:10px;font-weight:bold;text-decoration:none;display:inline-block">${rotulo}</a></p>
   <p style="font-size:13px;color:#4A5C52">Pix ou cartão. Se o botão não abrir, entre em ${SITE_URL.replace(/^https?:\/\//, "")}/conta.html e toque em "Pagar mensalidade".</p>`;

async function processarPlano(id: string, transactionNsu: string, slug: string, extra: Record<string, unknown> = {}) {
  const pg = await pagamentoPlano(id);
  if (!pg) return "NAO_ENCONTRADO";
  if (pg.status === "pago") return "JA_PAGO";
  const handle = pg.assinantes?.barbeiros?.infinitepay_handle;
  if (!handle) return "SEM_HANDLE";
  const c = await conferir(handle, `plano-${id}`, transactionNsu, slug);
  if (!c.pago) return "NAO_PAGO";
  const res = await rpc("registrar_pagamento_plano", {
    p_id: id, p_pago: c.valor, p_dados: { ...extra, ...c.dados, transaction_nsu: transactionNsu, slug }, p_forma: "site",
  });
  await avisarPagamentoPlano(id, res).catch(console.error);
  return res;
}

async function avisarPagamentoPlano(id: string, res: string) {
  if (!["ATIVADO", "REATIVADO", "RENOVADO"].includes(res)) return;
  const pg = await pagamentoPlano(id);
  const a = (await banco(`assinantes?id=eq.${pg.assinante_id}&select=*,planos(nome),barbeiros(nome)`))[0];
  const vence = a.proximo_pago ? new Date(new Date(a.vence_em + "T12:00:00").setMonth(new Date(a.vence_em + "T12:00:00").getMonth() + 1)).toISOString().slice(0, 10) : a.vence_em;
  if (!a.user_id) await enviarAcesso(a, "novo");
  else await enviar(a.email, `Mensalidade confirmada: ${a.planos.nome}`,
    moldura("Mensalidade confirmada", `Recebemos ${reais(pg.valor_centavos)}. Seu plano com ${a.barbeiros.nome} está garantido até ${dataBR(vence)}.`,
      `<p><a href="${SITE_URL}/conta.html">Abrir minha área e marcar horário</a></p>`));
  await enviar(BARBEARIA, `${res === "ATIVADO" ? "Novo assinante" : "Mensalidade paga"}: ${a.nome} · ${a.planos.nome} · ${a.barbeiros.nome}`,
    moldura(res === "ATIVADO" ? "Novo assinante pelo site" : "Mensalidade paga pelo site",
      `${a.nome} · WhatsApp ${a.telefone} · ${a.email}<br>${a.planos.nome} com ${a.barbeiros.nome} · ${reais(pg.valor_centavos)} · vale até ${dataBR(vence)}`));
}

// Quem chama é um sócio logado? (o token vem do painel)
async function eSocio(req: Request) {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token === SB_KEY) return false;
  const r = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SB_KEY, Authorization: `Bearer ${token}` } });
  if (!r.ok) return false;
  const u = await r.json();
  const l = await banco(`barbeiros?user_id=eq.${u.id}&select=id`);
  return l.length > 0;
}

async function lembretesPlanos() {
  const lista = await rpc("avisos_planos", {});
  let n = 0;
  for (const av of lista ?? []) {
    const a = (await banco(`assinantes?id=eq.${av.assinante_id}&select=*,planos(nome,preco_centavos)`))[0];
    if (!a) continue;
    const pgId = await rpc("cobranca_aberta", { p_assinante: a.id });
    const pg = pgId ? await pagamentoPlano(pgId) : null;
    const url = pg ? await linkPlano(pg).catch(() => `${SITE_URL}/conta.html`) : `${SITE_URL}/conta.html`;
    const [assunto, titulo, texto] = av.tipo === "d3"
      ? [`Seu plano vence em 3 dias (${dataBR(a.vence_em)})`, "Seu plano vence em 3 dias", `A mensalidade do ${a.planos.nome} (${reais(a.planos.preco_centavos)}) vence dia ${dataBR(a.vence_em)}. Pague agora e seu saldo renova sem interrupção.`]
      : av.tipo === "d1"
      ? [`Seu plano vence amanhã`, "Seu plano vence amanhã", `A mensalidade do ${a.planos.nome} (${reais(a.planos.preco_centavos)}) vence amanhã, ${dataBR(a.vence_em)}. Sem o pagamento, o plano trava e os horários voltam a pedir sinal.`]
      : [`Seu plano Trevus está pausado`, "Seu plano está pausado", `A mensalidade do ${a.planos.nome} venceu em ${dataBR(a.vence_em)}. Pague para voltar a marcar sem sinal: o novo mês começa no dia do pagamento.`];
    if (await enviar(a.email, assunto, moldura(titulo, texto, botaoPagar(url, `Pagar ${reais(a.planos.preco_centavos)}`)))) {
      await banco(`assinantes?id=eq.${a.id}`, { method: "PATCH", body: JSON.stringify({ ultimo_aviso: av.chave }) });
      n++;
    }
  }
  return n;
}

// ---------------- rotas ----------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const acao = new URL(req.url).searchParams.get("acao");
  const corpo = await req.json().catch(() => ({}));

  try {
    if (acao === "cobrar") {
      const a = await agendamento(corpo.agendamento_id);
      if (!a) return json({ erro: "Agendamento não encontrado." }, 404);
      if (a.status !== "aguardando_pagamento" || new Date(a.expira_em) < new Date())
        return json({ erro: "Esse horário não está mais aguardando pagamento. Marque de novo." }, 409);
      return json({ checkout_url: await criarLink(a) });
    }

    if (acao === "verificar") {
      const res = await processarPagamento(corpo.agendamento_id, corpo.transaction_nsu ?? "", corpo.slug ?? "");
      return json({ resultado: res });
    }

    if (acao === "webhook") {
      // A InfinitePay reenvia quando recebe 400; respondemos 200 depressa.
      const id = String(corpo.order_nsu ?? "");
      if (!id) return json({ ok: false }, 400);
      const extra = { receipt_url: corpo.receipt_url, capture_method: corpo.capture_method };
      const res = id.startsWith("plano-")
        ? await processarPlano(id.slice(6), corpo.transaction_nsu ?? "", corpo.invoice_slug ?? "", extra)
        : await processarPagamento(id, corpo.transaction_nsu ?? "", corpo.invoice_slug ?? "", extra);
      return json({ ok: true, resultado: res }, res === "NAO_PAGO" ? 400 : 200);
    }

    if (acao === "confirmado") {
      await emailConfirmacao(corpo.agendamento_id);
      return json({ ok: true });
    }

    // Sem senha: cada lembrete sai uma vez só (lembrete_enviado_em) e só para
    // os horários de amanhã, então chamar fora de hora não causa estrago.
    if (acao === "lembretes") return json({ enviados: await lembretes(), planos: await lembretesPlanos() });

    if (acao === "cobrar_plano") {
      const pg = await pagamentoPlano(corpo.pagamento_id);
      if (!pg || pg.status !== "pendente") return json({ erro: "Essa cobrança não está mais em aberto. Atualize a página." }, 409);
      return json({ checkout_url: await linkPlano(pg) });
    }

    if (acao === "verificar_plano") {
      const res = await processarPlano(corpo.pagamento_id, corpo.transaction_nsu ?? "", corpo.slug ?? "");
      const pg = await pagamentoPlano(corpo.pagamento_id);
      return json({ resultado: res, pago: pg?.status === "pago", tem_acesso: !!pg?.assinantes?.user_id, email: pg?.assinantes?.email });
    }

    // Sempre responde "ok" (não revela quem é assinante). Um e-mail a cada 2 min.
    if (acao === "acesso") {
      const email = String(corpo.email ?? "").trim().toLowerCase();
      if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
        const a = (await banco(`assinantes?email=eq.${encodeURIComponent(email)}&status=in.(ativo,vencido)&select=*`))?.[0];
        if (a && (!a.acesso_enviado_em || Date.now() - new Date(a.acesso_enviado_em).getTime() > 120000))
          await enviarAcesso(a, a.user_id ? "pedido" : "novo").catch(console.error);
      }
      return json({ ok: true });
    }

    if (acao === "convidar") {
      if (!(await eSocio(req))) return json({ erro: "Só a equipe pode mandar o acesso." }, 403);
      const a = (await banco(`assinantes?id=eq.${encodeURIComponent(corpo.assinante_id)}&select=*`))?.[0];
      if (!a) return json({ erro: "Assinante não encontrado." }, 404);
      await enviarAcesso(a, a.user_id ? "pedido" : "novo");
      return json({ ok: true });
    }

    return json({ erro: "ação desconhecida" }, 400);
  } catch (e) {
    console.error(e);
    return json({ erro: (e as Error).message }, 500);
  }
});
