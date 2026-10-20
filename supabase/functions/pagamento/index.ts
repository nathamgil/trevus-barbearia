// =====================================================================
//  Trevus Barbearia — função "pagamento" (Supabase Edge Function, Deno)
//
//  ?acao=cobrar     site pede o link de Pix/cartão do sinal (InfinitePay)
//  ?acao=verificar  site confere o pagamento quando o cliente volta
//  ?acao=webhook    a InfinitePay avisa que o pagamento caiu
//  ?acao=confirmado site avisa que um horário pago com crédito foi criado
//  ?acao=lembretes  rodado 1x por dia pelo agendador (pg_cron)
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
  const restante = a.preco_centavos - a.sinal_centavos;
  return `<div style="font-family:Arial,sans-serif;max-width:520px;margin:auto;color:#0F1F18">
    <div style="background:#0C1A13;color:#F3DB94;padding:18px 22px;border-radius:12px 12px 0 0;font-size:20px;letter-spacing:3px"><b>TREVUS</b> BARBEARIA</div>
    <div style="border:1px solid #CFD9D2;border-top:0;padding:22px;border-radius:0 0 12px 12px">
      <h2 style="margin:0 0 6px">${titulo}</h2><p style="margin:0 0 16px;color:#4A5C52">${texto}</p>
      <table style="width:100%;font-size:15px;border-collapse:collapse">
        <tr><td style="color:#4A5C52;padding:4px 0">Quando</td><td><b>${dataBR(a.data)} às ${hora(a.inicio)}</b></td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Com</td><td><b>${a.barbeiro_nome}</b></td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Serviço</td><td>${a.servico_nome}</td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Sinal pago</td><td>${reais(a.sinal_centavos)}</td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Na barbearia</td><td><b>${reais(restante)}</b></td></tr>
        <tr><td style="color:#4A5C52;padding:4px 0">Código</td><td><b style="letter-spacing:3px">${a.codigo}</b></td></tr>
      </table>
      <p style="font-size:14px;color:#4A5C52;margin-top:16px">${ENDERECO}, galeria ao lado da JP Tintas.<br>
      Cancele ou remarque pelo site até 1h antes: <a href="${SITE_URL}/#meu-horario">${SITE_URL.replace(/^https?:\/\//, "")}</a>.<br>
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
      const id = corpo.order_nsu;
      if (!id) return json({ ok: false }, 400);
      const res = await processarPagamento(id, corpo.transaction_nsu ?? "", corpo.invoice_slug ?? "", {
        receipt_url: corpo.receipt_url, capture_method: corpo.capture_method,
      });
      return json({ ok: true, resultado: res }, res === "NAO_PAGO" ? 400 : 200);
    }

    if (acao === "confirmado") {
      await emailConfirmacao(corpo.agendamento_id);
      return json({ ok: true });
    }

    // Sem senha: cada lembrete sai uma vez só (lembrete_enviado_em) e só para
    // os horários de amanhã, então chamar fora de hora não causa estrago.
    if (acao === "lembretes") return json({ enviados: await lembretes() });

    return json({ erro: "ação desconhecida" }, 400);
  } catch (e) {
    console.error(e);
    return json({ erro: (e as Error).message }, 500);
  }
});
