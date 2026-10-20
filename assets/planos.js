/* =====================================================================
   Trevus Barbearia — vitrine e compra dos planos mensais (index.html)
   Com o banco ligado, os planos vêm da tabela "planos" e a compra gera o
   link da InfinitePay do barbeiro escolhido (mês inteiro, Pix ou cartão).
   ===================================================================== */
(function () {
  'use strict';
  var CFG = window.TV, alvo = document.getElementById('planos-lista'), caixa = document.getElementById('plano-compra');
  if (!alvo) return;

  function el(t, c, x) { var n = document.createElement(t); if (c) n.className = c; if (x != null) n.textContent = x; return n; }
  function reais(c) { return 'R$ ' + (c / 100).toFixed(0); }
  function cab() { return { apikey: CFG.supabaseKey, Authorization: 'Bearer ' + CFG.supabaseKey, 'Content-Type': 'application/json' }; }
  function ler(r) {
    return r.text().then(function (t) {
      var j = t ? JSON.parse(t) : null;
      if (!r.ok) throw new Error((j && (j.hint || j.erro || j.message)) || 'Falha de conexão. Tente de novo.');
      return j;
    });
  }
  function get(caminho) { return fetch(CFG.supabaseUrl + '/rest/v1/' + caminho, { headers: cab() }).then(ler); }
  function post(caminho, corpo) { return fetch(CFG.supabaseUrl + caminho, { method: 'POST', headers: cab(), body: JSON.stringify(corpo) }).then(ler); }

  var barbeiros = [];

  function pinta(planos) {
    alvo.innerHTML = '';
    planos.forEach(function (pl) {
      var c = el('article', 'plano' + (pl.destaque ? ' destaque' : ''));
      c.appendChild(el('h3', null, pl.nome));
      var v = el('p', 'plano-preco'); v.innerHTML = reais(pl.preco_centavos) + '<small>/mês</small>'; c.appendChild(v);
      var ul = el('ul');
      (pl.itens || []).concat(['Sem sinal para agendar', 'Área do assinante com seu saldo']).forEach(function (i) { ul.appendChild(el('li', null, i)); });
      c.appendChild(ul);
      var b = el('button', 'btn ' + (pl.destaque ? 'btn-ouro' : 'btn-linha'), 'Assinar o ' + pl.nome); b.type = 'button';
      b.addEventListener('click', function () { abreCompra(pl); });
      c.appendChild(b);
      alvo.appendChild(c);
    });
  }

  function abreCompra(pl) {
    if (CFG.modoDemo || !pl.id) {
      location.href = 'https://wa.me/' + CFG.whatsapp + '?text=' + encodeURIComponent('Olá, Trevus! Quero assinar o ' + pl.nome + '.');
      return;
    }
    caixa.hidden = false; caixa.innerHTML = '';
    var box = el('div', 'painel'); box.style.marginTop = '1.4rem';
    box.appendChild(el('p', 'olho', 'Assinar'));
    var h = el('h3', null, pl.nome + ' · ' + reais(pl.preco_centavos) + ' por mês'); h.style.fontSize = '1.35rem'; box.appendChild(h);
    box.appendChild(el('p', 'sub', 'Você paga o mês inteiro agora, no Pix ou no cartão. O dia de hoje vira o dia do vencimento, e todo mês o link chega no seu e-mail 3 dias antes.'));

    box.appendChild(el('p', 'passo-tit', '1. Seu barbeiro'));
    var lista = el('div', 'lista-barbeiros'), escolhido = null;
    barbeiros.forEach(function (b) {
      var bt = el('button', 'barbeiro-opcao'); bt.type = 'button'; bt.setAttribute('aria-pressed', 'false');
      var f = el('span', 'barbeiro-foto'); if (b.foto) { var im = el('img'); im.src = b.foto; im.alt = ''; f.appendChild(im); } bt.appendChild(f);
      var tx = el('span', 'barbeiro-txt'); tx.appendChild(el('strong', null, b.nome)); tx.appendChild(el('span', null, 'O plano vale com ele')); bt.appendChild(tx);
      bt.addEventListener('click', function () {
        escolhido = b;
        Array.prototype.forEach.call(lista.children, function (x) { x.setAttribute('aria-pressed', x === bt ? 'true' : 'false'); });
      });
      lista.appendChild(bt);
    });
    box.appendChild(lista);

    box.appendChild(el('p', 'passo-tit', '2. Seus dados'));
    var form = el('form'); form.noValidate = true;
    form.innerHTML =
      '<div class="campos">' +
      '<div class="campo"><label for="pc-nome">Nome</label><input id="pc-nome" type="text" autocomplete="name" required></div>' +
      '<div class="campo"><label for="pc-tel">WhatsApp</label><input id="pc-tel" type="tel" inputmode="numeric" autocomplete="tel" placeholder="(71) 9 0000-0000" required></div>' +
      '<div class="campo"><label for="pc-email">E-mail</label><input id="pc-email" type="email" autocomplete="email" required>' +
      '<small style="color:var(--cinza);font-size:.82rem">É nele que chega o link para você criar sua senha.</small></div>' +
      '<button class="btn btn-ouro btn-bloco" type="submit">Pagar ' + reais(pl.preco_centavos) + ' (Pix ou cartão)</button>' +
      '<p class="pg-regras">Na página de pagamento a InfinitePay pode mandar um código no seu WhatsApp para confirmar que é você.</p>' +
      '</div>';
    var msg = el('div');
    form.querySelector('#pc-tel').addEventListener('input', function () {
      var d = this.value.replace(/\D/g, '').slice(0, 11), o = d;
      if (d.length > 2) o = '(' + d.slice(0, 2) + ') ' + d.slice(2);
      if (d.length > 7) o = '(' + d.slice(0, 2) + ') ' + d.slice(2, 3) + ' ' + d.slice(3, 7) + '-' + d.slice(7);
      this.value = o;
    });
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var botao = form.querySelector('button[type=submit]');
      function erro(t) { msg.innerHTML = ''; msg.appendChild(el('div', 'aviso aviso-erro', t)); }
      if (!escolhido) return erro('Escolha o seu barbeiro.');
      botao.disabled = true; botao.textContent = 'Abrindo o pagamento…';
      post('/rest/v1/rpc/comprar_plano', {
        p_plano: pl.id, p_barbeiro: escolhido.id, p_nome: form.querySelector('#pc-nome').value,
        p_telefone: form.querySelector('#pc-tel').value, p_email: form.querySelector('#pc-email').value
      }).then(function (pgId) {
        return post('/functions/v1/pagamento?acao=cobrar_plano', { pagamento_id: pgId });
      }).then(function (j) { location.href = j.checkout_url; })
        .catch(function (e) {
          botao.disabled = false; botao.textContent = 'Pagar ' + reais(pl.preco_centavos) + ' (Pix ou cartão)';
          erro(e.message);
          if (/já tem plano/i.test(e.message)) {
            var a = el('a', 'btn btn-linha mini', 'Ir para a Área do assinante'); a.href = 'conta.html'; msg.appendChild(a);
          }
        });
    });
    box.appendChild(form); box.appendChild(msg);
    var fechar = el('button', 'voltar', '← Ver os outros planos'); fechar.type = 'button';
    fechar.addEventListener('click', function () { caixa.hidden = true; caixa.innerHTML = ''; alvo.scrollIntoView({ behavior: 'smooth' }); });
    box.appendChild(fechar);
    caixa.appendChild(box);
    box.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  if (CFG.modoDemo) return pinta(CFG.planos || []);
  pinta(CFG.planos || []);   // aparece na hora; os dados do banco chegam em seguida
  Promise.all([
    get('planos?select=id,nome,preco_centavos,itens,destaque,ordem&ativo=eq.true&order=ordem'),
    get('barbeiros?select=id,nome,foto,ordem&ativo=eq.true&order=ordem')
  ]).then(function (r) { barbeiros = r[1]; if (r[0] && r[0].length) pinta(r[0]); })
    .catch(function () { /* fica a vitrine do config, que leva ao WhatsApp */ });
})();
