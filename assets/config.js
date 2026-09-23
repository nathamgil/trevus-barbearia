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
    linha2: 'Federação, Salvador — BA',
    // link que a própria barbearia usa no "Como chegar"
    maps:   'https://maps.app.goo.gl/bP7qy1qc5hcHm5Vj6',
    busca:  'Trevus Barbearia, Rua Sérgio de Carvalho, 28, Salvador - BA'
  },

  /* ---- Supabase ---------------------------------------------------
     Enquanto estes dois campos estiverem vazios, o site roda em MODO
     DEMONSTRAÇÃO: a agenda funciona de verdade na tela, mas os horários
     ficam guardados só no navegador de quem está olhando.

     Para ligar de verdade:
       1. supabase.com  ->  New project (região: South America / São Paulo)
       2. SQL Editor    ->  cole e rode db/schema.sql inteiro
       3. Settings > API -> copie "Project URL" e a chave "anon public"
       4. cole abaixo e suba pro GitHub

     A chave anon é pública por natureza — ela aparece no código do site.
     Quem protege os dados é o RLS + as funções do schema.sql, não ela.
  ------------------------------------------------------------------ */
  supabaseUrl: '',
  supabaseKey: '',

  /* ---- Regras da agenda (espelham o db/schema.sql) ----------------
     Mudou aqui? Mude no banco também — o banco é quem manda de verdade.
  ------------------------------------------------------------------ */
  regras: {
    passoMin:        10,   // grade de horários de 10 em 10 minutos
    antecedenciaMin: 30,   // não dá para marcar para daqui a 20 min
    janelaDias:      30,   // até 30 dias à frente
    cancelamentoH:   2     // cancela sozinho até 2h antes
  },

  /* ---- Expediente (0 = domingo) — igual ao que está no MinhaAgenda -- */
  expediente: {
    0: { aberto: true, abre: '08:00', fecha: '12:00' },
    1: { aberto: true, abre: '14:00', fecha: '18:00' },
    2: { aberto: true, abre: '08:00', fecha: '20:00', pausa: ['12:00', '13:00'] },
    3: { aberto: true, abre: '08:00', fecha: '20:00', pausa: ['12:00', '13:00'] },
    4: { aberto: true, abre: '08:00', fecha: '20:00', pausa: ['12:00', '13:00'] },
    5: { aberto: true, abre: '08:00', fecha: '20:00', pausa: ['12:00', '13:00'] },
    6: { aberto: true, abre: '08:00', fecha: '20:00', pausa: ['12:00', '13:00'] }
  },

  /* ---- Dados usados no modo demonstração --------------------------
     No ar de verdade, barbeiros e serviços vêm do banco, não daqui.
  ------------------------------------------------------------------ */
  barbeirosDemo: [
    { id:'kelson', slug:'kelson', nome:'Kelson', foto:'fotos/kelson.jpg', instagram:'kelsonsbarbershop' },
    { id:'junior', slug:'junior', nome:'Júnior', foto:'fotos/junior.jpg', instagram:'' },
    { id:'hariel', slug:'hariel', nome:'Hariel', foto:'fotos/hariel.jpg', instagram:'harielbarber13' }
  ],

  // Preços e durações copiados do MinhaAgenda da Trevus (set/2026).
  servicosDemo: [
    { id:'corte',            nome:'Corte',                descricao:'Corte de cabelo e acabamento.',                 preco_centavos:3000,  a_partir_de:false, duracao_min:30, categoria:'Cabelo' },
    { id:'corte-tesoura',    nome:'Corte na tesoura',     descricao:'Todo na tesoura, pra quem quer volume e caimento.', preco_centavos:3500, a_partir_de:false, duracao_min:40, categoria:'Cabelo' },
    { id:'corte-todo-um',    nome:'Corte todo por um',    descricao:'Máquina num pente só, rápido e no ponto.',       preco_centavos:2500,  a_partir_de:false, duracao_min:15, categoria:'Cabelo' },
    { id:'corte-barba',      nome:'Corte e barba',        descricao:'O combo completo. Sai pronto pra semana.',       preco_centavos:4500,  a_partir_de:false, duracao_min:50, categoria:'Combos' },
    { id:'corte-pigmentacao',nome:'Corte e pigmentação',  descricao:'Corte com pigmentação para fechar as falhas.',   preco_centavos:4500,  a_partir_de:false, duracao_min:30, categoria:'Combos' },
    { id:'barba',            nome:'Barba',                descricao:'Toalha quente, navalha e finalização.',          preco_centavos:2000,  a_partir_de:false, duracao_min:20, categoria:'Barba' },
    { id:'bigode',           nome:'Bigode',               descricao:'Alinhamento e acabamento do bigode.',            preco_centavos:700,   a_partir_de:false, duracao_min:10, categoria:'Barba' },
    { id:'acabamento',       nome:'Acabamento (pé)',      descricao:'Aquele retoque entre um corte e outro.',         preco_centavos:1000,  a_partir_de:false, duracao_min:10, categoria:'Detalhes' },
    { id:'pigmentacao',      nome:'Pigmentação',          descricao:'Realça o desenho do corte e da barba.',          preco_centavos:1500,  a_partir_de:false, duracao_min:15, categoria:'Detalhes' },
    { id:'sobrancelha',      nome:'Sobrancelha',          descricao:'Desenho no ponto, sem exagero.',                 preco_centavos:1500,  a_partir_de:false, duracao_min:10, categoria:'Detalhes' },
    { id:'nevou',            nome:'Nevou',                descricao:'Platinado. Consulte as condições com o barbeiro.', preco_centavos:12000, a_partir_de:true,  duracao_min:30, categoria:'Procedimentos' }
  ]
};

window.TV.modoDemo = !(window.TV.supabaseUrl && window.TV.supabaseKey);
