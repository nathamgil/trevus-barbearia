/* =====================================================================
   Trevus Barbearia — configuração
   Único arquivo que precisa ser editado para o site sair do modo de
   demonstração e entrar no ar de verdade.
   ===================================================================== */

window.TV = {

  /* ---- Negócio ---------------------------------------------------- */
  nome:       'Trevus Barbearia',
  slogan:     'Seu estilo, nossa assinatura',
  inauguracao:'2026-09-08',
  instagram:  'trevusbarbearia',

  // WhatsApp da barbearia em formato internacional, só dígitos.
  whatsapp:        '5571993911293',
  whatsappVisivel: '(71) 9 9391-1293',

  endereco: {
    linha1: 'Rua Sérgio de Carvalho, 28',
    linha2: 'Federação, Salvador — BA',          // PENDENTE: confirmar Federação x Vasco da Gama
    referencia: 'Na galeria ao lado da JP Tintas.',
    maps:   'https://maps.app.goo.gl/bP7qy1qc5hcHm5Vj6',
    busca:  'Trevus Barbearia, Rua Sérgio de Carvalho, 28, Salvador - BA'
  },

  /* ---- Supabase ---------------------------------------------------
     Com estes dois campos vazios, o site roda em MODO DEMONSTRAÇÃO: a
     agenda e o sinal funcionam na tela (o Pix é simulado), mas tudo fica
     guardado só no navegador de quem está olhando.

     Para ligar de verdade, siga o README (Supabase + InfinitePay + Brevo).
     A chave anon é pública por natureza; quem protege os dados é o RLS e
     as funções do schema.sql.
  ------------------------------------------------------------------ */
  supabaseUrl: '',
  supabaseKey: '',

  /* ---- Regras da agenda (espelham o db/schema.sql) ----------------
     Mudou aqui? Mude no banco também: o banco é quem manda de verdade.
  ------------------------------------------------------------------ */
  regras: {
    passoMin:        30,   // horários de 30 em 30 minutos
    antecedenciaMin: 30,   // não dá para marcar para daqui a 20 min
    janelaDias:      15,   // agenda aberta para os próximos 15 dias
    cancelamentoH:   1,    // cancela ou remarca sozinho até 1h antes
    sinalPct:        50,   // sinal pago no Pix ao marcar
    pagarEmMin:      15,   // vaga segurada enquanto o cliente paga
    remarcacoesMax:  2,
    toleranciaMin:   5     // atraso tolerado (só aviso, não é automático)
  },

  /* ---- Expediente de cada barbeiro (0 = domingo) ------------------ */
  expediente: (function () {
    var normal  = { aberto: true, abre: '08:00', fecha: '20:00', pausa: ['12:00', '13:00'] };
    var domingo = { aberto: true, abre: '08:00', fecha: '12:00' };
    var folga   = { aberto: false };
    return {
      kelson: { 0: domingo, 1: { aberto: true, abre: '14:00', fecha: '20:00' }, 2: normal, 3: normal, 4: normal, 5: normal, 6: normal },
      junior: { 0: domingo, 1: folga, 2: normal, 3: normal, 4: normal, 5: normal, 6: normal },
      hariel: { 0: domingo, 1: folga, 2: folga,  3: normal, 4: normal, 5: normal, 6: normal }
    };
  })(),

  // Feriados: o dia vira esta faixa, sem almoço. Nacionais 8h-12h, locais 8h-17h.
  feriados: {
    '2026-11-02': ['Finados', '08:00', '12:00'],
    '2026-11-15': ['Proclamação da República', '08:00', '12:00'],
    '2026-11-20': ['Consciência Negra', '08:00', '12:00'],
    '2026-12-08': ['N. Sra. da Conceição da Praia', '08:00', '17:00'],
    '2026-12-25': ['Natal', '08:00', '12:00'],
    '2027-01-01': ['Confraternização Universal', '08:00', '12:00']
  },

  /* ---- Dados usados no modo demonstração --------------------------
     No ar de verdade, barbeiros, serviços e planos vêm do banco.
  ------------------------------------------------------------------ */
  barbeirosDemo: [
    { id:'kelson', slug:'kelson', nome:'Kelson', foto:'fotos/kelson.jpg', instagram:'kelsonstrevus',
      especialidade:'Cortes na tesoura', anos_profissao:4,  frase:'Cortes que comunicam poder.' },
    { id:'junior', slug:'junior', nome:'Júnior', foto:'fotos/junior.jpg', instagram:'juniortrevus',
      especialidade:'Química e platinado', anos_profissao:10, frase:'Autoestima renovada em cada atendimento.' },
    { id:'hariel', slug:'hariel', nome:'Hariel', foto:'fotos/hariel.jpg', instagram:'haridade1996',
      especialidade:'Degradê', anos_profissao:13, frase:'Experiência que transforma técnica em excelência.' }
  ],

  // Alinhamento de 24/09/2026. "ativo:false" = esperando preço da Trevus.
  servicosDemo: [
    { id:'corte',             nome:'Corte',                 descricao:'Corte de cabelo e acabamento.',                       preco_centavos:3000,  a_partir_de:false, duracao_min:30, categoria:'Cabelo' },
    { id:'corte-tesoura',     nome:'Corte na tesoura',      descricao:'Todo na tesoura, pra quem quer volume e caimento.',   preco_centavos:3500,  a_partir_de:false, duracao_min:40, categoria:'Cabelo' },
    { id:'corte-todo-um',     nome:'Corte todo por um',     descricao:'Máquina num pente só, rápido e no ponto.',            preco_centavos:2500,  a_partir_de:false, duracao_min:15, categoria:'Cabelo' },
    { id:'corte-infantil',    nome:'Corte infantil',        descricao:'Para crianças de até 6 anos.',                        preco_centavos:3500,  a_partir_de:false, duracao_min:30, categoria:'Cabelo' },
    { id:'corte-barba',       nome:'Corte e barba',         descricao:'O combo completo. Sai pronto pra semana.',            preco_centavos:4500,  a_partir_de:false, duracao_min:50, categoria:'Combos' },
    { id:'corte-pigmentacao', nome:'Corte e pigmentação',   descricao:'Corte com pigmentação para fechar as falhas.',        preco_centavos:4500,  a_partir_de:false, duracao_min:45, categoria:'Combos' },
    { id:'barba',             nome:'Barba',                 descricao:'Toalha quente, navalha e finalização.',               preco_centavos:2000,  a_partir_de:false, duracao_min:20, categoria:'Barba' },
    { id:'bigode',            nome:'Bigode',                descricao:'Alinhamento e acabamento do bigode.',                 preco_centavos:700,   a_partir_de:false, duracao_min:10, categoria:'Barba' },
    { id:'barboterapia',      nome:'Barboterapia',          descricao:'Ritual completo de barba com toalha quente e hidratação.', preco_centavos:3000, a_partir_de:false, duracao_min:30, categoria:'Barba' },
    { id:'acabamento',        nome:'Acabamento (pé)',       descricao:'Aquele retoque entre um corte e outro.',              preco_centavos:1000,  a_partir_de:false, duracao_min:10, categoria:'Detalhes' },
    { id:'pigmentacao',       nome:'Pigmentação',           descricao:'Realça o desenho do corte e da barba.',               preco_centavos:1500,  a_partir_de:false, duracao_min:15, categoria:'Detalhes' },
    { id:'sobrancelha',       nome:'Sobrancelha',           descricao:'Desenho no ponto, sem exagero.',                      preco_centavos:1500,  a_partir_de:false, duracao_min:10, categoria:'Detalhes' },
    { id:'limpeza-pele',      nome:'Limpeza de pele',       descricao:'Limpeza facial para tirar oleosidade e cravos.',      preco_centavos:2000,  a_partir_de:false, duracao_min:25, categoria:'Cuidados' },
    { id:'nevou',             nome:'Nevou',                 descricao:'Platinado. O valor final pode mudar conforme o tamanho do cabelo.', preco_centavos:12000, a_partir_de:true, duracao_min:30, categoria:'Química' }
    // PENDENTE: Luzes (40 min) e Remoção de pelos nasais (5 min) entram quando a Trevus passar o preço.
  ],

  // Planos (Fase 2: login do assinante). Por enquanto a vitrine leva ao WhatsApp.
  planos: [
    { nome:'Trevus Basic', preco_centavos:11500, itens:['4 cortes por mês'] },
    { nome:'Hyper Trevus', preco_centavos:17000, itens:['4 cortes por mês', 'Barba ou sobrancelha'], pendente:true }, // PENDENTE: confirmar o que inclui
    { nome:'Mega Trevus',  preco_centavos:23000, itens:['4 cortes por mês', 'Barba', 'Sobrancelha'], destaque:true }
  ]
};

window.TV.modoDemo = !(window.TV.supabaseUrl && window.TV.supabaseKey);
