/* =====================================================================
   Trevus — "manter conectado" e "adicionar à tela inicial"
   Carregar ANTES de criar o cliente do Supabase.
   ===================================================================== */
(function () {
  'use strict';
  var CHAVE = 'tv_manter_conectado';

  function manter() { try { return localStorage.getItem(CHAVE) !== '0'; } catch (e) { return true; } }

  // Com "manter conectado" a sessão fica no aparelho (localStorage) e o
  // Supabase renova sozinho. Sem, some quando fecha o navegador (sessionStorage).
  function guarda() { try { return manter() ? window.localStorage : window.sessionStorage; } catch (e) { return null; } }
  window.TV_ARMAZEM = {
    getItem: function (k) { try { return (guarda() || {}).getItem ? guarda().getItem(k) : null; } catch (e) { return null; } },
    setItem: function (k, v) { try { guarda().setItem(k, v); } catch (e) {} },
    removeItem: function (k) { try { localStorage.removeItem(k); } catch (e) {} try { sessionStorage.removeItem(k); } catch (e) {} }
  };
  window.TV_DEFINE_MANTER = function (sim) {
    try { localStorage.setItem(CHAVE, sim ? '1' : '0'); } catch (e) {}
  };
  window.TV_MANTER = manter;

  // ---------- app na tela inicial ----------
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () { navigator.serviceWorker.register('sw.js').catch(function () {}); });
  }
  var pedido = null;
  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault(); pedido = e;
    document.dispatchEvent(new Event('tv:instalavel'));
  });
  function jaInstalado() {
    return (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) || window.navigator.standalone === true;
  }
  function ehIOS() { return /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1); }

  // Desenha o convite de instalar dentro de "alvo" (some se já for app).
  window.TV_CONVITE_APP = function (alvo) {
    if (!alvo || jaInstalado()) return;
    try { if (localStorage.getItem('tv_app_fechado') === '1') return; } catch (e) {}
    function pinta() {
      alvo.innerHTML = '';
      if (!pedido && !ehIOS()) return;
      var box = document.createElement('div'); box.className = 'convite-app';
      var tx = document.createElement('div');
      var b = document.createElement('b'); b.textContent = 'Coloque a Trevus na tela do seu celular';
      var p = document.createElement('p');
      p.textContent = ehIOS() && !pedido
        ? 'No Safari, toque em Compartilhar (o quadrado com a seta pra cima) e depois em "Adicionar à Tela de Início". Abre como app e você não precisa entrar de novo.'
        : 'Abre como app, direto na sua área, e você não precisa entrar de novo.';
      tx.appendChild(b); tx.appendChild(p); box.appendChild(tx);
      var ac = document.createElement('div'); ac.className = 'convite-acoes';
      if (pedido) {
        var bt = document.createElement('button'); bt.type = 'button'; bt.className = 'btn btn-ouro mini'; bt.textContent = 'Adicionar à tela inicial';
        bt.addEventListener('click', function () { pedido.prompt(); pedido.userChoice.then(function () { pedido = null; alvo.innerHTML = ''; }); });
        ac.appendChild(bt);
      }
      var x = document.createElement('button'); x.type = 'button'; x.className = 'voltar'; x.textContent = 'Agora não';
      x.addEventListener('click', function () { try { localStorage.setItem('tv_app_fechado', '1'); } catch (e) {} alvo.innerHTML = ''; });
      ac.appendChild(x); box.appendChild(ac);
      alvo.appendChild(box);
    }
    pinta();
    document.addEventListener('tv:instalavel', pinta);
  };
})();
