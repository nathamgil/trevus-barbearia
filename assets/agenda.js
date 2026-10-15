/* =====================================================================
   Trevus Barbearia — motor de agendamento (v2: sinal no Pix)
   Fala com o Supabase por RPC e com a função "pagamento" (InfinitePay).
   Sem as chaves em config.js, roda em modo demonstração com as mesmas
   regras, guardando no navegador e simulando o Pix.
   ===================================================================== */
(function () {
  'use strict';

  var CFG  = window.TV;
  var R    = CFG.regras;
  var DEMO = CFG.modoDemo;
  var K_AG = 'tv2_agendamentos_demo', K_CR = 'tv2_creditos_demo', K_BL = 'tv_bloqueios_demo';

  var SEMANA      = ['Domingo','Segunda','Terça','Quarta','Quinta','Sexta','Sábado'];
  var SEMANA_CURT = ['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'];
  var MESES_CURT  = ['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'];
  var MESES       = ['janeiro','fevereiro','março','abril','maio','junho','julho',
                     'agosto','setembro','outubro','novembro','dezembro'];

  /* ---------------- utilidades ---------------- */

  function $(s, raiz) { return (raiz || document).querySelector(s); }
  function el(tag, cls, txt) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (txt != null) n.textContent = txt;
    return n;
  }
  function dinheiro(c) { return 'R$ ' + (c / 100).toFixed(2).replace('.', ','); }
  function duracao(min) {
    if (min < 60) return min + ' min';
    var h = Math.floor(min / 60), m = min % 60;
    return h + 'h' + (m ? String(m).padStart(2, '0') : '');
  }
  function iso(d) {
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }
  function deIso(s) { var p = String(s).split('-'); return new Date(+p[0], +p[1] - 1, +p[2]); }
  function hhmm(t) { return String(t).slice(0, 5); }
  function minutos(t) { var p = String(t).split(':'); return (+p[0]) * 60 + (+p[1]); }
  function deMinutos(m) { return String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0'); }
  function soDigitos(s) { return String(s || '').replace(/\D/g, ''); }
  function dataPorExtenso(s) { var d = deIso(s); return SEMANA[d.getDay()] + ', ' + d.getDate() + ' de ' + MESES[d.getMonth()]; }
  function diaRelativo(s) {
    if (s === iso(new Date())) return 'Hoje';
    if (s === iso(new Date(Date.now() + 86400000))) return 'Amanhã';
    return dataPorExtenso(s);
  }
  function somaDur(lista) { return lista.reduce(function (t, s) { return t + s.duracao_min; }, 0); }
  function somaPreco(lista) { return lista.reduce(function (t, s) { return t + s.preco_centavos; }, 0); }
  function nomes(lista) { return lista.map(function (s) { return s.nome; }).join(' + '); }
  function sinalDe(total) { return Math.ceil(total * R.sinalPct / 100); }
  // freestyle, por exemplo, só o Kelson faz (so_barbeiros = lista de ids; vazio = todos)
  function faz(servico, barbeiroId) { return !servico.so_barbeiros || servico.so_barbeiros.indexOf(barbeiroId) >= 0; }
  function fazTodos(lista, barbeiroId) { return lista.every(function (s) { return faz(s, barbeiroId); }); }
  function ler(k, padrao) { try { return JSON.parse(localStorage.getItem(k) || 'null') || padrao; } catch (e) { return padrao; } }
  function gravar(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }

  /* ---------------- camada de dados (servidor) ---------------- */

  function cabecalhos() {
    return { 'apikey': CFG.supabaseKey, 'Authorization': 'Bearer ' + CFG.supabaseKey, 'Content-Type': 'application/json' };
  }
  function lerResposta(r) {
    return r.text().then(function (t) {
      var corpo = t ? JSON.parse(t) : null;
      if (!r.ok) {
        var e = new Error((corpo && (corpo.hint || corpo.erro || corpo.message)) || 'Falha de conexão. Tente de novo.');
        e.codigo = corpo && corpo.message;
        throw e;
      }
      return corpo;
    });
  }
  function rpc(fn, args) {
    return fetch(CFG.supabaseUrl + '/rest/v1/rpc/' + fn, { method: 'POST', headers: cabecalhos(), body: JSON.stringify(args || {}) })
      .then(lerResposta);
  }
  function tabela(caminho) {
    return fetch(CFG.supabaseUrl + '/rest/v1/' + caminho, { headers: cabecalhos() }).then(lerResposta);
  }
  function funcao(acao, corpo) {
    return fetch(CFG.supabaseUrl + '/functions/v1/pagamento?acao=' + acao, { method: 'POST', headers: cabecalhos(), body: JSON.stringify(corpo) })
      .then(lerResposta);
  }

  /* ---------------- modo demonstração: mesmas regras ---------------- */

  function demoAg() { return ler(K_AG, []); }
  function demoCr() { return ler(K_CR, []); }

  function janela(dataIso, barbeiroId) {
    var exp = (CFG.expediente[barbeiroId] || {})[deIso(dataIso).getDay()];
    if (!exp || !exp.aberto) return null;
    var j = { abre: minutos(exp.abre), fecha: minutos(exp.fecha), pausa: exp.pausa ? [minutos(exp.pausa[0]), minutos(exp.pausa[1])] : null };
    var f = CFG.feriados && CFG.feriados[dataIso];
    if (f) {
      if (!f[1]) return null;
      j = { abre: Math.max(j.abre, minutos(f[1])), fecha: Math.min(j.fecha, minutos(f[2])), pausa: null, feriado: f[0] };
    }
    return j.fecha > j.abre ? j : null;
  }

  function ocupa(a) {
    return a.status === 'confirmado' || (a.status === 'aguardando_pagamento' && a.expira_em > Date.now());
  }

  function demoSlotsBarbeiro(dataIso, dur, barbeiroId, ignorarCodigo) {
    var hoje = iso(new Date());
    var lim = deIso(hoje); lim.setDate(lim.getDate() + R.janelaDias);
    if (dataIso < hoje || dataIso > iso(lim)) return [];
    var j = janela(dataIso, barbeiroId);
    if (!j) return [];
    var limite = Date.now() + R.antecedenciaMin * 60000;
    var ocupados = demoAg().filter(function (a) {
      return a.dia === dataIso && a.barbeiro_id === barbeiroId && ocupa(a) && a.codigo !== ignorarCodigo;
    });
    var bloqueios = ler(K_BL, []).filter(function (b) {
      return b.data === dataIso && (!b.barbeiro_id || b.barbeiro_id === barbeiroId);
    });
    var livres = [];
    for (var m = j.abre; m + dur <= j.fecha; m += R.passoMin) {
      var fim = m + dur;
      if (j.pausa && m < j.pausa[1] && fim > j.pausa[0]) continue;
      if (deIso(dataIso).getTime() + m * 60000 < limite) continue;
      if (ocupados.some(function (a) { return m < minutos(a.fim) && fim > minutos(a.inicio); })) continue;
      if (bloqueios.some(function (b) { return m < minutos(b.hora_fim) && fim > minutos(b.hora_inicio); })) continue;
      livres.push(deMinutos(m));
    }
    return livres;
  }
  function demoSlots(dataIso, dur, barbeiroId, servicos) {
    var ids = (barbeiroId ? [barbeiroId] : CFG.barbeirosDemo.map(function (b) { return b.id; }))
      .filter(function (id) { return !servicos || fazTodos(servicos, id); });
    var todos = {};
    ids.forEach(function (id) { demoSlotsBarbeiro(dataIso, dur, id).forEach(function (h) { todos[h] = true; }); });
    return Object.keys(todos).sort();
  }
  function demoCreditos(tel) {
    var t = soDigitos(tel), out = {};
    demoCr().forEach(function (c) { if (c.telefone === t && c.saldo > 0) out[c.barbeiro_id] = (out[c.barbeiro_id] || 0) + c.saldo; });
    return out;
  }

  // A agenda da demonstração já nasce com movimento, com clientes de exemplo.
  function demoSemeia() {
    if (ler('tv2_demo_semeado', false)) return;
    var nomesEx = ['Rafael S.','Lucas M.','Diego A.','Bruno C.','Matheus R.','Thiago O.','Gabriel L.','Caio F.','Pedro H.','Vinícius B.'];
    var lista = [], semente = 11;
    function sorte(n) { semente = (semente * 9301 + 49297) % 233280; return Math.floor(semente / 233280 * n); }
    for (var d = 0; d < 7; d++) {
      var dia = new Date(); dia.setDate(dia.getDate() + d);
      CFG.barbeirosDemo.forEach(function (b) {
        var j = janela(iso(dia), b.id);
        if (!j) return;
        for (var i = 0, qtd = 2 + sorte(4); i < qtd; i++) {
          var s = CFG.servicosDemo[sorte(7)];
          var ini = j.abre + sorte(Math.max(1, (j.fecha - j.abre - s.duracao_min) / R.passoMin)) * R.passoMin;
          var fim = ini + s.duracao_min;
          if (j.pausa && ini < j.pausa[1] && fim > j.pausa[0]) continue;
          if (lista.some(function (a) { return a.barbeiro_id === b.id && a.dia === iso(dia) && ini < minutos(a.fim) && fim > minutos(a.inicio); })) continue;
          lista.push({
            codigo: 'EX' + (1000 + lista.length), barbeiro_id: b.id, barbeiro: b.nome,
            servicos: [s.id], servico: s.nome, preco_centavos: s.preco_centavos, duracao_min: s.duracao_min,
            sinal_centavos: sinalDe(s.preco_centavos), credito_usado: 0, sinal_status: 'pago',
            nome: nomesEx[sorte(nomesEx.length)] + ' (exemplo)', telefone: '71900000000', email: '',
            dia: iso(dia), inicio: deMinutos(ini), fim: deMinutos(fim), obs: '', status: 'confirmado',
            origem: sorte(4) === 0 ? 'balcao' : 'site', remarcacoes: 0
          });
        }
      });
    }
    gravar(K_AG, lista);
    gravar('tv2_demo_semeado', true);
  }

  /* ---------------- API (demonstração ou servidor) ---------------- */

  var API = {
    barbeiros: function () {
      if (DEMO) return Promise.resolve(CFG.barbeirosDemo.slice());
      return tabela('barbeiros?select=id,slug,nome,foto,instagram,especialidade,frase,anos_profissao&ativo=eq.true&order=ordem.asc');
    },
    servicos: function () {
      if (DEMO) return Promise.resolve(CFG.servicosDemo.slice());
      return tabela('servicos?select=*&ativo=eq.true&order=ordem.asc');
    },
    dias: function (servicos, barbeiro) {
      if (DEMO) {
        var out = [], hoje = new Date(), dur = somaDur(servicos);
        for (var i = 0; i <= R.janelaDias; i++) {
          var d = iso(new Date(hoje.getFullYear(), hoje.getMonth(), hoje.getDate() + i));
          out.push({ dia: d, vagas: demoSlots(d, dur, barbeiro && barbeiro.id, servicos).length });
        }
        return Promise.resolve(out);
      }
      return rpc('dias_disponiveis', { p_servicos: servicos.map(function (s) { return s.id; }), p_barbeiro_id: barbeiro ? barbeiro.id : null });
    },
    slots: function (dataIso, servicos, barbeiro) {
      if (DEMO) return Promise.resolve(demoSlots(dataIso, somaDur(servicos), barbeiro && barbeiro.id, servicos));
      return rpc('slots_disponiveis', { p_data: dataIso, p_servicos: servicos.map(function (s) { return s.id; }), p_barbeiro_id: barbeiro ? barbeiro.id : null })
        .then(function (l) { return l.map(hhmm); });
    },
    desconto: function (tel) {
      if (soDigitos(tel).length < 10) return Promise.resolve(0);
      if (DEMO) {
        var d = ler('tv2_descontos_demo', []).filter(function (x) { return x.telefone === soDigitos(tel) && !x.usado; })[0];
        return Promise.resolve(d ? d.pct : 0);
      }
      return rpc('meu_desconto', { p_telefone: soDigitos(tel) }).then(function (p) { return p || 0; });
    },
    creditos: function (tel) {
      if (soDigitos(tel).length < 10) return Promise.resolve({});
      if (DEMO) return Promise.resolve(demoCreditos(tel));
      return rpc('meus_creditos', { p_telefone: soDigitos(tel) }).then(function (l) {
        var out = {}; (l || []).forEach(function (c) { out[c.barbeiro_id] = c.saldo_centavos; }); return out;
      });
    },

    criar: function (d) {
      if (DEMO) {
        var dur = somaDur(d.servicos), tel = soDigitos(d.telefone), cred = demoCreditos(tel), ag0 = demoAg();
        var candidatos = (d.barbeiro ? [d.barbeiro] : CFG.barbeirosDemo.slice())
          .filter(function (b) { return fazTodos(d.servicos, b.id) && demoSlotsBarbeiro(d.dia, dur, b.id).indexOf(d.hora) >= 0; })
          .sort(function (a, b) {
            function carga(x) { return ag0.filter(function (y) { return y.barbeiro_id === x.id && y.dia === d.dia && y.status === 'confirmado'; }).length; }
            return ((cred[b.id] || 0) - (cred[a.id] || 0)) || (carga(a) - carga(b));
          });
        var b = candidatos[0];
        if (!b) return Promise.reject(new Error('Esse horário acabou de ser ocupado. Escolha outro.'));

        var descontos = ler('tv2_descontos_demo', []), desc = descontos.filter(function (x) { return x.telefone === tel && !x.usado; })[0];
        var total = somaPreco(d.servicos);
        if (desc) { total = Math.round(total * (100 - desc.pct) / 100); desc.usado = true; gravar('tv2_descontos_demo', descontos); }
        var sinal = sinalDe(total), resta = sinal, usado = 0;
        var creditos = demoCr();
        creditos.forEach(function (c) {
          if (resta && c.telefone === tel && c.barbeiro_id === b.id && c.saldo > 0) {
            var x = Math.min(c.saldo, resta); c.saldo -= x; resta -= x; usado += x;
          }
        });
        gravar(K_CR, creditos);
        var a = {
          id: 'demo-' + Math.random().toString(16).slice(2, 10),
          codigo: Math.random().toString(16).slice(2, 8).toUpperCase(),
          barbeiro_id: b.id, barbeiro: b.nome, servicos: d.servicos.map(function (s) { return s.id; }),
          servico: nomes(d.servicos), preco_centavos: total, duracao_min: dur,
          sinal_centavos: sinal, credito_usado: usado, desconto_pct: desc ? desc.pct : 0, sinal_status: resta ? 'pendente' : 'credito',
          nome: d.nome, telefone: tel, email: d.email, dia: d.dia, inicio: d.hora,
          fim: deMinutos(minutos(d.hora) + dur), obs: d.obs || '',
          status: resta ? 'aguardando_pagamento' : 'confirmado',
          expira_em: resta ? Date.now() + R.pagarEmMin * 60000 : null, origem: 'site', remarcacoes: 0
        };
        var lista = demoAg(); lista.push(a); gravar(K_AG, lista);
        return Promise.resolve({
          id: a.id, codigo: a.codigo, barbeiro: a.barbeiro, servico: a.servico, dia: a.dia, inicio: a.inicio, fim: a.fim,
          preco_centavos: total, sinal_centavos: resta, credito_usado: usado, status: a.status, expira_em: a.expira_em
        });
      }
      return rpc('criar_agendamento', {
        p_servicos: d.servicos.map(function (s) { return s.id; }), p_barbeiro_id: d.barbeiro ? d.barbeiro.id : null,
        p_nome: d.nome, p_telefone: soDigitos(d.telefone), p_email: d.email,
        p_data: d.dia, p_inicio: d.hora, p_obs: d.obs || null
      }).then(function (l) {
        if (!l || !l.length) throw new Error('Não consegui reservar. Tente de novo.');
        var a = l[0];
        if (a.status === 'confirmado') funcao('confirmado', { agendamento_id: a.id }).catch(function () {});
        return {
          id: a.id, codigo: a.codigo, barbeiro: a.barbeiro, servico: a.servico, dia: a.dia,
          inicio: hhmm(a.inicio), fim: hhmm(a.fim), preco_centavos: a.preco_centavos,
          sinal_centavos: a.sinal_centavos, credito_usado: a.credito_usado, status: a.status,
          expira_em: Date.now() + R.pagarEmMin * 60000
        };
      });
    },

    // Link de pagamento da InfinitePay do barbeiro (no modo demo, nada: o Pix é simulado).
    cobrar: function (id) {
      if (DEMO) return Promise.resolve({ demo: true });
      return funcao('cobrar', { agendamento_id: id });
    },
    demoPagar: function (id) {
      var lista = demoAg(), achou = null;
      lista.forEach(function (a) {
        if (a.id === id && a.status === 'aguardando_pagamento' && a.expira_em > Date.now()) {
          a.status = 'confirmado'; a.sinal_status = 'pago'; a.expira_em = null; achou = a;
        }
      });
      gravar(K_AG, lista);
      return achou ? Promise.resolve(achou) : Promise.reject(new Error('O prazo de pagamento acabou. Marque de novo.'));
    },
    verificar: function (id, nsu, slug) {
      if (DEMO) return Promise.resolve({});
      return funcao('verificar', { agendamento_id: id, transaction_nsu: nsu || '', slug: slug || '' }).catch(function () { return {}; });
    },
    status: function (id) {
      if (DEMO) {
        var a = demoAg().filter(function (x) { return x.id === id; })[0];
        if (!a) return Promise.resolve(null);
        return Promise.resolve({ codigo: a.codigo, status: a.status === 'aguardando_pagamento' && a.expira_em < Date.now() ? 'expirado' : a.status,
          sinal_status: a.sinal_status, barbeiro: a.barbeiro, servico: a.servico, dia: a.dia, inicio: a.inicio, fim: a.fim });
      }
      return rpc('status_agendamento', { p_id: id }).then(function (l) {
        var a = l && l[0]; if (!a) return null;
        a.inicio = hhmm(a.inicio); a.fim = hhmm(a.fim); return a;
      });
    },

    consultar: function (codigo, telefone) {
      if (DEMO) {
        var a = demoAg().filter(function (x) { return x.codigo === codigo.trim().toUpperCase() && x.telefone === soDigitos(telefone); })[0];
        if (!a) return Promise.resolve(null);
        var quando = deIso(a.dia).getTime() + minutos(a.inicio) * 60000, folga = quando >= Date.now() + R.cancelamentoH * 3600000;
        return Promise.resolve({
          codigo: a.codigo, barbeiro_id: a.barbeiro_id, barbeiro: a.barbeiro, servico: a.servico, servicos: a.servicos,
          dia: a.dia, inicio: a.inicio, fim: a.fim, preco_centavos: a.preco_centavos, sinal_centavos: a.sinal_centavos,
          duracao_min: a.duracao_min, status: a.status, sinal_status: a.sinal_status, remarcacoes: a.remarcacoes,
          pode_cancelar: a.status === 'confirmado' && folga,
          pode_remarcar: a.status === 'confirmado' && folga && a.remarcacoes < R.remarcacoesMax
        });
      }
      return rpc('consultar_agendamento', { p_codigo: codigo, p_telefone: soDigitos(telefone) }).then(function (l) {
        var a = l && l[0]; if (!a) return null;
        a.inicio = hhmm(a.inicio); a.fim = hhmm(a.fim); a.duracao_min = minutos(a.fim) - minutos(a.inicio);
        return a;
      });
    },
    cancelar: function (codigo, telefone) {
      if (DEMO) {
        var lista = demoAg(), res = null, erro = null;
        lista.forEach(function (a) {
          if (a.codigo !== codigo.trim().toUpperCase() || a.telefone !== soDigitos(telefone)) return;
          var quando = deIso(a.dia).getTime() + minutos(a.inicio) * 60000;
          if (a.status === 'aguardando_pagamento') { a.status = 'cancelado'; res = 'CANCELADO'; return; }
          if (quando < Date.now() + R.cancelamentoH * 3600000) { erro = 'O cancelamento pelo site vai até 1h antes. Fale no WhatsApp.'; return; }
          a.status = 'cancelado';
          if (a.sinal_status === 'pago' || a.sinal_status === 'credito') {
            a.sinal_status = 'virou_credito';
            var cr = demoCr(); cr.push({ telefone: a.telefone, barbeiro_id: a.barbeiro_id, saldo: a.sinal_centavos }); gravar(K_CR, cr);
            res = 'CANCELADO_CREDITO';
          } else res = 'CANCELADO';
        });
        if (erro) return Promise.reject(new Error(erro));
        if (!res) return Promise.reject(new Error('Código ou telefone não confere.'));
        gravar(K_AG, lista);
        return Promise.resolve(res);
      }
      return rpc('cancelar_agendamento', { p_codigo: codigo, p_telefone: soDigitos(telefone) });
    },
    remarcar: function (codigo, telefone, dataIso, hora) {
      if (DEMO) {
        var lista = demoAg(), a = lista.filter(function (x) { return x.codigo === codigo.trim().toUpperCase() && x.telefone === soDigitos(telefone); })[0];
        if (!a) return Promise.reject(new Error('Código ou telefone não confere.'));
        if (a.remarcacoes >= R.remarcacoesMax) return Promise.reject(new Error('Esse horário já foi remarcado 2 vezes. Fale no WhatsApp.'));
        if (demoSlotsBarbeiro(dataIso, a.duracao_min, a.barbeiro_id, a.codigo).indexOf(hora) < 0)
          return Promise.reject(new Error('Esse horário não está livre. Escolha outro.'));
        a.dia = dataIso; a.inicio = hora; a.fim = deMinutos(minutos(hora) + a.duracao_min); a.remarcacoes++;
        gravar(K_AG, lista);
        return Promise.resolve({ dia: a.dia, inicio: a.inicio, fim: a.fim, remarcacoes: a.remarcacoes });
      }
      return rpc('remarcar_agendamento', { p_codigo: codigo, p_telefone: soDigitos(telefone), p_data: dataIso, p_inicio: hora })
        .then(function (l) { var a = l[0]; return { dia: a.dia, inicio: hhmm(a.inicio), fim: hhmm(a.fim), remarcacoes: a.remarcacoes }; });
    },
    // horários para remarcar: mesmo barbeiro, mesma duração, sem contar o próprio horário
    slotsRemarcar: function (dataIso, a) {
      if (DEMO) return Promise.resolve(demoSlotsBarbeiro(dataIso, a.duracao_min, a.barbeiro_id, a.codigo));
      return rpc('slots_disponiveis', { p_data: dataIso, p_servicos: a.servicos, p_barbeiro_id: a.barbeiro_id })
        .then(function (l) { return l.map(hhmm); });
    }
  };

  window.TV.API = API;
  window.TV.util = { janela: janela, dinheiro: dinheiro, dataPorExtenso: dataPorExtenso, minutos: minutos, deMinutos: deMinutos, iso: iso, deIso: deIso };
  // feriados lançados no painel valem para a agenda do site
  if (DEMO) {
    var extra = ler('tv2_feriados_demo', {});
    CFG.feriados = Object.assign({}, CFG.feriados);
    Object.keys(extra).forEach(function (d) { if (extra[d]) CFG.feriados[d] = extra[d]; else delete CFG.feriados[d]; });
    demoSemeia();
  }

  /* ================= interface do agendamento ================= */

  var raiz = $('#agendar-app');
  if (!raiz) return;

  var estado = { barbeiros: [], servicos: [], barbeiro: null, escolhidos: [], dia: null, hora: null, etapa: 1, reserva: null, creditos: {} };
  function barbeiroEscolhido() { return estado.barbeiro === 'qualquer' ? null : estado.barbeiro; }
  function nomeBarbeiro() { return estado.barbeiro === 'qualquer' ? 'Sem preferência' : (estado.barbeiro ? estado.barbeiro.nome : ''); }

  var passos = $('#passos', raiz);
  var etapas = {};
  [1, 2, 3, 4, 5, 6].forEach(function (n) { etapas[n] = $('[data-etapa="' + n + '"]', raiz); });

  function irPara(n, semRolar) {
    estado.etapa = n;
    Object.keys(etapas).forEach(function (k) {
      if (+k === n) etapas[k].setAttribute('data-ativa', ''); else etapas[k].removeAttribute('data-ativa');
    });
    Array.prototype.forEach.call(passos.children, function (p, i) {
      p.setAttribute('data-estado', i + 1 === n ? 'atual' : (i + 1 < n ? 'feito' : 'aberto'));
    });
    passos.hidden = n === 6;
    pintaEscolhas();
    if (semRolar) return;
    var topo = raiz.getBoundingClientRect().top + window.scrollY - 90;
    if (Math.abs(window.scrollY - topo) > 140) window.scrollTo({ top: topo, behavior: 'smooth' });
  }

  var escolhas = $('#escolhas', raiz);
  function pintaEscolhas() {
    escolhas.innerHTML = '';
    if (estado.etapa >= 5) { escolhas.hidden = true; return; }
    var itens = [];
    if (estado.barbeiro) itens.push(['Barbeiro', nomeBarbeiro(), 1]);
    if (estado.escolhidos.length && estado.etapa > 2) itens.push(['Serviço', nomes(estado.escolhidos), 2]);
    if (estado.dia && estado.hora && estado.etapa >= 4) itens.push(['Quando', diaRelativo(estado.dia) + ' · ' + estado.hora, 3]);
    escolhas.hidden = !itens.length;
    itens.forEach(function (it) {
      var b = el('button', 'escolha'); b.type = 'button';
      b.appendChild(el('small', null, it[0])); b.appendChild(el('span', null, it[1]));
      b.addEventListener('click', function () { irPara(it[2]); });
      escolhas.appendChild(b);
    });
  }

  function erro(caixa, msg) { caixa.innerHTML = ''; caixa.appendChild(el('div', 'aviso aviso-erro', msg)); }

  /* ---- 1: barbeiro ---- */

  var listaBarbeiros = $('#lista-barbeiros', raiz);
  function pintaBarbeiros() {
    listaBarbeiros.innerHTML = '';
    estado.barbeiros.concat(['qualquer']).forEach(function (b) {
      var qualquer = b === 'qualquer';
      var btn = el('button', 'barbeiro-opcao' + (qualquer ? ' qualquer' : '')); btn.type = 'button';
      btn.setAttribute('aria-pressed', estado.barbeiro === b || (!qualquer && estado.barbeiro && estado.barbeiro.id === b.id) ? 'true' : 'false');
      var foto = el('span', 'barbeiro-foto');
      if (qualquer) foto.innerHTML = '<svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="9" cy="8" r="3.2"/><circle cx="17" cy="9" r="2.6"/><path d="M3 20c.6-3.4 3-5.4 6-5.4s5.4 2 6 5.4M15 14.8c2.8-.4 5.2 1.3 6 4.6"/></svg>';
      else { var img = el('img'); img.src = b.foto; img.alt = ''; img.loading = 'lazy'; foto.appendChild(img); }
      btn.appendChild(foto);
      var txt = el('span', 'barbeiro-txt');
      txt.appendChild(el('strong', null, qualquer ? 'Sem preferência' : b.nome));
      txt.appendChild(el('span', null, qualquer ? 'Primeiro barbeiro livre' : (b.especialidade || 'Sócio · Barbeiro')));
      btn.appendChild(txt);
      if (!qualquer && estado.escolhidos.length && !fazTodos(estado.escolhidos, b.id)) {
        btn.disabled = true; btn.title = 'Não faz um dos serviços escolhidos';
      }
      btn.addEventListener('click', function () {
        estado.barbeiro = b; estado.dia = null; estado.hora = null;
        if (!qualquer) estado.escolhidos = estado.escolhidos.filter(function (s) { return faz(s, b.id); });
        pintaBarbeiros(); pintaServicos();
        if (estado.escolhidos.length) { carregaDias(); irPara(3); } else irPara(2);
      });
      listaBarbeiros.appendChild(btn);
    });
  }

  /* ---- 2: serviços (vários) ---- */

  var listaServicos = $('#lista-servicos', raiz);
  var barraServ = $('#barra-servicos', raiz);
  function pintaServicos() {
    listaServicos.innerHTML = '';
    var grupos = {};
    var bid = barbeiroEscolhido() && barbeiroEscolhido().id;
    estado.servicos.filter(function (s) { return !bid || faz(s, bid); })
      .forEach(function (s) { (grupos[s.categoria || 'Serviços'] = grupos[s.categoria || 'Serviços'] || []).push(s); });
    Object.keys(grupos).forEach(function (g) {
      listaServicos.appendChild(el('div', 'grupo-servico', g));
      var grade = el('div', 'lista-escolha');
      grupos[g].forEach(function (s) {
        var marcado = estado.escolhidos.some(function (x) { return x.id === s.id; });
        var b = el('button', 'opcao opcao-multi'); b.type = 'button';
        b.setAttribute('aria-pressed', marcado ? 'true' : 'false');
        var esq = el('span');
        esq.appendChild(el('strong', null, s.nome));
        var so = s.so_barbeiros && estado.barbeiros.filter(function (x) { return s.so_barbeiros.indexOf(x.id) >= 0; })
          .map(function (x) { return x.nome; }).join(' e ');
        esq.appendChild(el('span', null, duracao(s.duracao_min) + (so && !bid ? ' · só com ' + so : '')));
        b.appendChild(el('span', 'caixinha'));
        b.appendChild(esq);
        b.appendChild(el('span', 'val', (s.a_partir_de ? 'a partir de ' : '') + dinheiro(s.preco_centavos)));
        b.addEventListener('click', function () {
          estado.escolhidos = marcado ? estado.escolhidos.filter(function (x) { return x.id !== s.id; }) : estado.escolhidos.concat([s]);
          // mantém a ordem do cardápio ("Corte + Freestyle", não a ordem dos cliques)
          estado.escolhidos.sort(function (x, y) { return estado.servicos.indexOf(x) - estado.servicos.indexOf(y); });
          estado.dia = null; estado.hora = null;
          pintaServicos();
        });
        grade.appendChild(b);
      });
      listaServicos.appendChild(grade);
    });
    var n = estado.escolhidos.length;
    barraServ.hidden = !n;
    if (n) {
      $('#bs-txt', raiz).textContent = n + (n > 1 ? ' serviços · ' : ' serviço · ') + duracao(somaDur(estado.escolhidos));
      $('#bs-total', raiz).textContent = dinheiro(somaPreco(estado.escolhidos));
    }
  }
  $('#btn-servicos', raiz).addEventListener('click', function () {
    if (!estado.escolhidos.length) return;
    carregaDias(); irPara(3);
  });

  /* ---- 3: dia e hora ---- */

  var fita = $('#fita-dias', raiz), caixaHoras = $('#caixa-horas', raiz), tituloDia = $('#titulo-dia', raiz);

  function fitaDias(alvo, carregar, aoEscolher) {
    alvo.innerHTML = '';
    alvo.appendChild(el('div', 'carregando', 'Consultando a agenda…'));
    return carregar().then(function (dias) {
      alvo.innerHTML = '';
      var primeiro = null;
      dias.forEach(function (d) {
        var data = deIso(d.dia);
        var b = el('button', 'dia'); b.type = 'button';
        b.disabled = !d.vagas;
        b.setAttribute('aria-pressed', 'false');
        var fer = CFG.feriados && CFG.feriados[d.dia];
        b.appendChild(el('span', 'sem', d.dia === iso(new Date()) ? 'Hoje' : SEMANA_CURT[data.getDay()]));
        b.appendChild(el('span', 'num', String(data.getDate())));
        b.appendChild(el('span', 'mes', fer ? 'Feriado' : MESES_CURT[data.getMonth()]));
        b.title = d.vagas ? d.vagas + ' horário(s) livre(s)' : 'Sem horário livre';
        b.addEventListener('click', function () {
          Array.prototype.forEach.call(alvo.children, function (x) { x.setAttribute('aria-pressed', 'false'); });
          b.setAttribute('aria-pressed', 'true');
          b.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'nearest' });
          aoEscolher(d.dia);
        });
        if (d.vagas && !primeiro) primeiro = b;
        alvo.appendChild(b);
      });
      if (primeiro) primeiro.click();
      return !!primeiro;
    });
  }

  function grade(alvo, horas, aoEscolher) {
    alvo.innerHTML = '';
    if (!horas.length) {
      var v = el('div', 'vazio'); v.appendChild(el('b', null, 'Nenhum horário nesse dia')); v.appendChild(el('p', null, 'Escolha outro dia na fita acima.'));
      alvo.appendChild(v); return;
    }
    [['Manhã', 0, 720], ['Tarde', 720, 1080], ['Noite', 1080, 1440]].forEach(function (t) {
      var doTurno = horas.filter(function (h) { var m = minutos(h); return m >= t[1] && m < t[2]; });
      if (!doTurno.length) return;
      var bloco = el('div', 'blocos-hora');
      bloco.appendChild(el('div', 'turno', t[0] + ' · ' + doTurno.length + (doTurno.length > 1 ? ' livres' : ' livre')));
      var g = el('div', 'grade-horas');
      doTurno.forEach(function (h) {
        var b = el('button', 'hora', h); b.type = 'button';
        b.addEventListener('click', function () { aoEscolher(h); });
        g.appendChild(b);
      });
      bloco.appendChild(g); alvo.appendChild(bloco);
    });
  }

  function carregaDias() {
    caixaHoras.innerHTML = ''; tituloDia.textContent = '';
    fitaDias(fita, function () { return API.dias(estado.escolhidos, barbeiroEscolhido()); }, function (dia) {
      estado.dia = dia; estado.hora = null;
      var f = CFG.feriados && CFG.feriados[dia];
      tituloDia.textContent = dataPorExtenso(dia) + (f ? ' · feriado (' + f[0] + ')' : '') +
        (estado.barbeiro === 'qualquer' ? ' · com o primeiro barbeiro livre' : ' · com ' + estado.barbeiro.nome);
      caixaHoras.innerHTML = '<div class="carregando">Buscando horários livres…</div>';
      API.slots(dia, estado.escolhidos, barbeiroEscolhido()).then(function (horas) {
        grade(caixaHoras, horas, function (h) { estado.hora = h; montaResumo(); irPara(4); atualizaCredito(); });
      }).catch(function (e) { erro(caixaHoras, e.message); });
    }).then(function (algum) {
      if (algum) return;
      fita.innerHTML = '';
      var v = el('div', 'vazio'); v.appendChild(el('b', null, 'Agenda cheia'));
      v.appendChild(el('p', null, 'Não há horário livre nos próximos ' + R.janelaDias + ' dias. Tente outro barbeiro ou chame no WhatsApp.'));
      fita.appendChild(v);
    }).catch(function (e) { erro(fita, e.message); });
  }

  /* ---- 4: dados ---- */

  var resumo = $('#resumo', raiz);
  var campoTel = $('#cli-tel', raiz);

  function montaResumo() {
    var cheio = somaPreco(estado.escolhidos);
    var total = estado.desconto ? Math.round(cheio * (100 - estado.desconto) / 100) : cheio, sinal = sinalDe(total);
    var bid = barbeiroEscolhido() && barbeiroEscolhido().id;
    var cred = bid ? (estado.creditos[bid] || 0) : 0;
    var aPagar = Math.max(0, sinal - cred);
    var aPartir = estado.escolhidos.some(function (s) { return s.a_partir_de; });
    resumo.innerHTML = '';
    var dl = el('dl');
    [
      ['Barbeiro', estado.barbeiro === 'qualquer' ? 'O primeiro livre nesse horário' : estado.barbeiro.nome],
      ['Serviço', nomes(estado.escolhidos)],
      ['Quando', dataPorExtenso(estado.dia) + ', ' + estado.hora + ' às ' + deMinutos(minutos(estado.hora) + somaDur(estado.escolhidos))],
      estado.desconto ? ['Desconto', estado.desconto + '% (a barbearia desmarcou seu último horário em cima da hora)'] : null,
      ['Total', (aPartir ? 'a partir de ' : '') + dinheiro(total) + (estado.desconto ? ' (era ' + dinheiro(cheio) + ')' : '')],
      cred ? ['Seu crédito', '− ' + dinheiro(Math.min(cred, sinal))] : null,
      ['Sinal agora', aPagar ? dinheiro(aPagar) + ' no Pix' : 'coberto pelo seu crédito'],
      ['Na barbearia', dinheiro(total - sinal) + (aPartir ? ' (pode variar)' : '')]
    ].forEach(function (p) {
      if (!p) return;
      dl.appendChild(el('dt', null, p[0]));
      dl.appendChild(el('dd', p[0] === 'Sinal agora' ? 'total' : null, p[1]));
    });
    resumo.appendChild(dl);
    $('#btn-confirmar', raiz).textContent = aPagar || estado.barbeiro === 'qualquer' ? 'Reservar e pagar o sinal' : 'Confirmar horário';
  }

  function mascaraTel() {
    var d = soDigitos(this.value).slice(0, 11), out = d;
    if (d.length > 2) out = '(' + d.slice(0, 2) + ') ' + d.slice(2);
    if (d.length > 7) out = '(' + d.slice(0, 2) + ') ' + d.slice(2, 3) + ' ' + d.slice(3, 7) + '-' + d.slice(7);
    this.value = out;
  }
  campoTel.addEventListener('input', mascaraTel);
  // o crédito depende do WhatsApp: reconsulta ao abrir o resumo e ao terminar de digitar
  function atualizaCredito() {
    Promise.all([API.creditos(campoTel.value), API.desconto(campoTel.value)]).then(function (r) {
      estado.creditos = r[0]; estado.desconto = r[1]; if (estado.etapa === 4) montaResumo();
    });
  }
  campoTel.addEventListener('input', function () { if (soDigitos(campoTel.value).length === 11) atualizaCredito(); });

  try {
    var salvo = JSON.parse(localStorage.getItem('tv_cliente') || 'null');
    if (salvo) {
      $('#cli-nome', raiz).value = salvo.nome || ''; campoTel.value = salvo.tel || ''; $('#cli-email', raiz).value = salvo.email || '';
    }
  } catch (e) {}

  var form = $('#form-cliente', raiz), caixaMsg = $('#msg-form', raiz), btnEnvia = $('#btn-confirmar', raiz);
  form.addEventListener('submit', function (ev) {
    ev.preventDefault();
    caixaMsg.innerHTML = '';
    var nome = $('#cli-nome', raiz).value.trim(), tel = soDigitos(campoTel.value);
    var email = $('#cli-email', raiz).value.trim(), obs = $('#cli-obs', raiz).value.trim();
    if (nome.length < 2) return erro(caixaMsg, 'Escreva seu nome para o barbeiro te reconhecer.');
    if (tel.length !== 11) return erro(caixaMsg, 'O WhatsApp precisa ter DDD + 9 dígitos. Ex: (71) 9 9391-1293');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return erro(caixaMsg, 'Escreva um e-mail válido: a confirmação e o lembrete chegam por ele.');

    btnEnvia.disabled = true; btnEnvia.textContent = 'Reservando…';
    API.criar({ barbeiro: barbeiroEscolhido(), servicos: estado.escolhidos, nome: nome, telefone: tel, email: email, dia: estado.dia, hora: estado.hora, obs: obs })
      .then(function (a) {
        try { localStorage.setItem('tv_cliente', JSON.stringify({ nome: nome, tel: campoTel.value, email: email })); } catch (e) {}
        a.nome = nome; estado.reserva = a;
        if (a.status === 'confirmado') mostraSucesso(a);
        else mostraPagamento(a);
      })
      .catch(function (e) {
        erro(caixaMsg, e.message);
        if (/ocupad|indispon/i.test(e.message)) setTimeout(function () { irPara(3); carregaDias(); }, 1400);
      })
      .finally(function () { btnEnvia.disabled = false; montaResumo(); });
  });

  /* ---- 5: sinal ---- */

  var relogio = null;
  function mostraPagamento(a) {
    $('#pg-valor', raiz).textContent = dinheiro(a.sinal_centavos);
    $('#pg-linha', raiz).textContent = a.servico + ' com ' + a.barbeiro + ' · ' + diaRelativo(a.dia) + ', ' + a.inicio;
    $('#pg-resto', raiz).textContent = dinheiro(a.preco_centavos - a.sinal_centavos - a.credito_usado) + ' na barbearia';
    $('#pg-demo', raiz).hidden = !DEMO;
    $('#pg-msg', raiz).innerHTML = '';
    clearInterval(relogio);
    var fim = a.expira_em || Date.now() + R.pagarEmMin * 60000;
    function tic() {
      var s = Math.max(0, Math.round((fim - Date.now()) / 1000));
      $('#pg-relogio', raiz).textContent = Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
      if (!s) {
        clearInterval(relogio);
        $('#btn-pagar', raiz).disabled = true;
        erro($('#pg-msg', raiz), 'O tempo para pagar acabou e a vaga foi liberada. Marque de novo.');
      }
    }
    $('#btn-pagar', raiz).disabled = false;
    tic(); relogio = setInterval(tic, 1000);
    irPara(5);
  }

  $('#btn-pagar', raiz).addEventListener('click', function () {
    var a = estado.reserva, b = this, msg = $('#pg-msg', raiz);
    b.disabled = true;
    if (DEMO) {
      b.textContent = 'Confirmando o Pix…';
      setTimeout(function () {
        API.demoPagar(a.id).then(function () { clearInterval(relogio); a.sinal_pago = true; mostraSucesso(a); })
          .catch(function (e) { erro(msg, e.message); })
          .finally(function () { b.disabled = false; b.textContent = 'Pagar o sinal'; });
      }, 900);
      return;
    }
    b.textContent = 'Abrindo o pagamento…';
    try { sessionStorage.setItem('tv_reserva', JSON.stringify(a)); } catch (e) {}
    API.cobrar(a.id).then(function (r) { window.location.href = r.checkout_url; })
      .catch(function (e) { erro(msg, e.message); b.disabled = false; b.textContent = 'Pagar o sinal'; });
  });

  $('#btn-desistir', raiz).addEventListener('click', function () {
    clearInterval(relogio);
    var a = estado.reserva;
    if (a) API.cancelar(a.codigo, campoTel.value).catch(function () {});
    estado.reserva = null; estado.hora = null;
    irPara(3); carregaDias();
  });

  // volta da InfinitePay: ?pagamento=<id>&transaction_nsu=...&slug=...
  function voltaDoPagamento() {
    var p = new URLSearchParams(location.search), id = p.get('pagamento');
    if (!id) return;
    var guardada = null;
    try { guardada = JSON.parse(sessionStorage.getItem('tv_reserva') || 'null'); } catch (e) {}
    history.replaceState(null, '', location.pathname + '#agendar');
    $('#pg-msg', raiz).innerHTML = '<div class="aviso aviso-neutro">Conferindo o seu pagamento…</div>';
    irPara(5);
    API.verificar(id, p.get('transaction_nsu'), p.get('slug')).then(function () {
      var tentativas = 0;
      (function confere() {
        API.status(id).then(function (s) {
          if (s && s.status === 'confirmado') {
            mostraSucesso(Object.assign({}, guardada || {}, s, { sinal_pago: true }));
          } else if (s && s.status === 'expirado') {
            erro($('#pg-msg', raiz), 'O tempo para pagar acabou antes do Pix chegar. Se você pagou, a barbearia devolve o valor: chame no WhatsApp.');
          } else if (++tentativas < 40) setTimeout(confere, 3000);
          else erro($('#pg-msg', raiz), 'Ainda não recebemos a confirmação do Pix. Se você já pagou, aguarde um minuto e confira em "Meu horário".');
        });
      })();
    });
  }

  /* ---- 6: confirmado ---- */

  function mostraSucesso(a) {
    $('#ok-codigo', raiz).textContent = a.codigo;
    $('#ok-barbeiro', raiz).textContent = a.barbeiro;
    $('#ok-linha', raiz).textContent = a.servico + ' · ' + dataPorExtenso(a.dia) + ' · ' + a.inicio + ' às ' + a.fim;
    $('#ok-sinal', raiz).textContent = a.sinal_pago ? 'Sinal recebido. O resto você paga na barbearia.'
      : 'Sinal coberto pelo seu crédito. O resto você paga na barbearia.';
    var texto = 'Olá, Trevus! Marquei pelo site.\n\n*' + a.servico + '* com ' + a.barbeiro + '\n' +
      dataPorExtenso(a.dia) + '\n' + a.inicio + ' às ' + a.fim + '\nCódigo: ' + a.codigo + (a.nome ? '\nNome: ' + a.nome : '');
    $('#ok-zap', raiz).href = 'https://wa.me/' + CFG.whatsapp + '?text=' + encodeURIComponent(texto);
    $('#ok-ics', raiz).href = fazIcs(a);
    $('#ok-ics', raiz).download = 'trevus-' + a.codigo + '.ics';
    try { sessionStorage.removeItem('tv_reserva'); } catch (e) {}
    irPara(6);
  }

  function fazIcs(a) {
    function carimbo(d, h) { return d.replace(/-/g, '') + 'T' + h.replace(':', '') + '00'; }
    return 'data:text/calendar;charset=utf-8,' + encodeURIComponent([
      'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Trevus Barbearia//PT-BR', 'BEGIN:VEVENT',
      'UID:' + a.codigo + '@trevusbarbearia',
      'DTSTART;TZID=America/Bahia:' + carimbo(a.dia, a.inicio), 'DTEND;TZID=America/Bahia:' + carimbo(a.dia, a.fim),
      'SUMMARY:' + a.servico + ' com ' + a.barbeiro + ' — Trevus Barbearia',
      'LOCATION:' + CFG.endereco.linha1 + ', ' + CFG.endereco.linha2,
      'DESCRIPTION:Código ' + a.codigo + '. Cancele ou remarque pelo site até 1h antes.',
      'END:VEVENT', 'END:VCALENDAR'].join('\r\n'));
  }

  Array.prototype.forEach.call(raiz.querySelectorAll('[data-voltar]'), function (b) {
    b.addEventListener('click', function () { irPara(+b.getAttribute('data-voltar')); });
  });
  $('#btn-novo', raiz).addEventListener('click', function () {
    estado.barbeiro = null; estado.escolhidos = []; estado.dia = null; estado.hora = null; estado.reserva = null;
    $('#cli-obs', raiz).value = ''; caixaMsg.innerHTML = '';
    pintaBarbeiros(); pintaServicos(); irPara(1);
  });

  /* ---- meu horário: consultar, cancelar, remarcar ---- */

  var formConsulta = $('#form-consulta');
  if (formConsulta) {
    var saida = $('#saida-consulta');
    $('#con-tel').addEventListener('input', mascaraTel);

    function mostraHorario(a, cod, tel) {
      saida.innerHTML = '';
      var cx = el('div', 'resumo'), dl = el('dl');
      [
        ['Barbeiro', a.barbeiro], ['Serviço', a.servico], ['Quando', dataPorExtenso(a.dia) + ', ' + a.inicio],
        ['Situação', { confirmado: 'Confirmado', aguardando_pagamento: 'Aguardando o Pix do sinal', cancelado: 'Cancelado',
          expirado: 'Expirou sem pagamento', faltou: 'Não compareceu', concluido: 'Atendido' }[a.status] || a.status],
        a.sinal_status === 'virou_credito' ? ['Sinal', dinheiro(a.sinal_centavos) + ' virou crédito com ' + a.barbeiro] : null,
        a.status === 'confirmado' ? ['Remarcações', a.remarcacoes + ' de ' + R.remarcacoesMax] : null
      ].forEach(function (p) { if (p) { dl.appendChild(el('dt', null, p[0])); dl.appendChild(el('dd', null, p[1])); } });
      cx.appendChild(dl); saida.appendChild(cx);

      var acoes = el('div', 'acoes'); acoes.style.marginTop = '0';
      if (a.pode_remarcar) {
        var br = el('button', 'btn btn-ouro', 'Remarcar'); br.type = 'button';
        br.addEventListener('click', function () { abreRemarcar(a, cod, tel); });
        acoes.appendChild(br);
      }
      if (a.pode_cancelar) {
        var bc = el('button', 'btn btn-linha', 'Cancelar'); bc.type = 'button';
        bc.addEventListener('click', function () { confirmaCancelar(a, cod, tel); });
        acoes.appendChild(bc);
      }
      if (acoes.children.length) saida.appendChild(acoes);
      else if (a.status === 'confirmado') saida.appendChild(el('div', 'aviso aviso-neutro',
        'Falta menos de ' + R.cancelamentoH + 'h ou o limite de remarcações acabou. Para mudar agora, chame no WhatsApp.'));
    }

    // a página não pode usar confirm(): a confirmação é um passo na própria tela
    function confirmaCancelar(a, cod, tel) {
      var cx = el('div', 'aviso aviso-neutro');
      var pago = a.sinal_status === 'pago' || a.sinal_status === 'credito';
      cx.appendChild(el('p', null, pago
        ? 'Cancelando agora, o sinal de ' + dinheiro(a.sinal_centavos) + ' vira crédito para o seu próximo horário com ' + a.barbeiro + '.'
        : 'Tem certeza que quer cancelar este horário?'));
      var ac = el('div', 'acoes'); ac.style.marginTop = '.6rem';
      var sim = el('button', 'btn btn-ouro', 'Sim, cancelar'); sim.type = 'button';
      var nao = el('button', 'voltar', 'Manter o horário'); nao.type = 'button';
      sim.addEventListener('click', function () {
        sim.disabled = true;
        API.cancelar(cod, tel).then(function (r) {
          saida.innerHTML = '';
          saida.appendChild(el('div', 'aviso aviso-ok', r === 'CANCELADO_CREDITO'
            ? 'Horário cancelado. O sinal virou crédito: ele é descontado sozinho quando você marcar de novo com ' + a.barbeiro + ' usando este WhatsApp.'
            : 'Horário cancelado. A vaga já voltou para a agenda.'));
        }).catch(function (e) { erro(saida, e.message); });
      });
      nao.addEventListener('click', function () { cx.remove(); });
      ac.appendChild(sim); ac.appendChild(nao); cx.appendChild(ac);
      saida.appendChild(cx);
    }

    function abreRemarcar(a, cod, tel) {
      saida.innerHTML = '';
      var cx = el('div', 'remarcar');
      cx.appendChild(el('h3', null, 'Novo horário com ' + a.barbeiro));
      cx.appendChild(el('p', 'dica', 'O sinal fica com o mesmo barbeiro, por isso a remarcação é com ele. Restam ' +
        (R.remarcacoesMax - a.remarcacoes) + ' remarcação(ões).'));
      var f = el('div', 'fita'), t = el('p', 'titulo-dia'), h = el('div'), m = el('div');
      cx.appendChild(f); cx.appendChild(t); cx.appendChild(h); cx.appendChild(m);
      var volta = el('button', 'voltar', '← Voltar'); volta.type = 'button';
      volta.addEventListener('click', function () { mostraHorario(a, cod, tel); });
      cx.appendChild(volta);
      saida.appendChild(cx);
      fitaDias(f, function () {
        var out = [], hoje = new Date(), ps = [];
        for (var i = 0; i <= R.janelaDias; i++) {
          (function (d) { ps.push(API.slotsRemarcar(d, a).then(function (l) { out.push({ dia: d, vagas: l.length }); })); })
            (iso(new Date(hoje.getFullYear(), hoje.getMonth(), hoje.getDate() + i)));
        }
        return Promise.all(ps).then(function () { return out.sort(function (x, y) { return x.dia < y.dia ? -1 : 1; }); });
      }, function (dia) {
        t.textContent = dataPorExtenso(dia);
        h.innerHTML = '<div class="carregando">Buscando horários livres…</div>';
        API.slotsRemarcar(dia, a).then(function (horas) {
          grade(h, horas, function (hora) {
            m.innerHTML = '';
            API.remarcar(cod, tel, dia, hora).then(function (r) {
              saida.innerHTML = '';
              saida.appendChild(el('div', 'aviso aviso-ok', 'Remarcado para ' + dataPorExtenso(r.dia) + ', às ' + r.inicio + ', com ' + a.barbeiro + '. O sinal continua valendo.'));
            }).catch(function (e) { erro(m, e.message); });
          });
        });
      });
    }

    formConsulta.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var cod = $('#con-codigo').value.trim(), tel = $('#con-tel').value.trim();
      saida.innerHTML = '<div class="carregando">Procurando…</div>';
      API.consultar(cod, tel).then(function (a) {
        if (!a) return erro(saida, 'Não achei esse horário. Confira o código e o WhatsApp usados na hora de marcar.');
        mostraHorario(a, cod, tel);
      }).catch(function (e) { erro(saida, e.message); });
    });
  }

  /* ---- atalhos vindos da página ---- */

  window.TV.agendarCom = function (id) {
    var b = estado.barbeiros.filter(function (x) { return x.id === id || x.slug === id; })[0];
    if (!b) return;
    estado.barbeiro = b; estado.dia = null; estado.hora = null;
    pintaBarbeiros();
    if (estado.escolhidos.length) { carregaDias(); irPara(3); } else irPara(2);
  };
  window.TV.agendarServico = function (id) {
    var s = estado.servicos.filter(function (x) { return x.id === id || x.slug === id; })[0];
    if (!s) return;
    estado.escolhidos = [s]; estado.dia = null; estado.hora = null;
    pintaServicos();
    if (estado.barbeiro) { carregaDias(); irPara(3); } else irPara(1);
  };

  /* ---- partida ---- */

  listaBarbeiros.appendChild(el('div', 'carregando', 'Carregando a equipe…'));
  var feriados = DEMO ? Promise.resolve() : tabela('feriados?select=*').then(function (l) {
    CFG.feriados = {};
    (l || []).forEach(function (f) { CFG.feriados[f.data] = [f.nome, f.abre && hhmm(f.abre), f.fecha && hhmm(f.fecha)]; });
  }).catch(function () {});
  Promise.all([API.barbeiros(), API.servicos(), feriados]).then(function (r) {
    estado.barbeiros = r[0]; estado.servicos = r[1];
    window.TV.barbeirosCarregados = r[0]; window.TV.servicosCarregados = r[1];
    pintaBarbeiros(); pintaServicos(); irPara(1, true);
    document.dispatchEvent(new CustomEvent('tv:dados', { detail: { barbeiros: r[0], servicos: r[1] } }));
    voltaDoPagamento();
  }).catch(function (e) {
    erro(listaBarbeiros, 'Não consegui carregar a agenda agora. Chame no WhatsApp que a gente marca na hora. (' + e.message + ')');
  });

})();
