# Estudo da Reforma — atualização semanal das aulas novas (Agenda 2.10.0 / Estudo 1.6.0)

Pedido do usuário (24/10/2026): toda semana verificar se os cursos publicaram aulas novas e atualizar o Estudo.
Quem **já começou** a trilha vê a aula como **"Atualização para revisar"** (quadro no topo da trilha, botão
"Marcar como vista", fora do % de conclusão). Quem **não começou** recebe a aula direto na lista da trilha.
Fonte escolhida pelo usuário: só as **aulas novas dos cursos** (Caio Melo/Hotmart e Fellipe Guerra/Nutror).
Publicação **automática**. Quando: **segunda-feira, por volta das 7h** (horário de Brasília).

## Como funciona
- A rotina roda na sessão do Claude que montou o Estudo (agendamento semanal). **Desde 02/11/2026 a leitura dos cursos é
  feita no servidor ARTEAPP01** (veja "No ARTEAPP01" abaixo): a rotina manda a ordem para a sessão do Claude ligada ao
  servidor e lê a resposta. Lá fica o login do escritório, **fora do GitHub** (nunca versionar cookies nem senhas). O
  roteiro compara a lista de aulas com a da semana anterior (`base_hotmart.json`, `base_nutror.json`).
- Aula nova vira, no `dados.json` do armazenamento privado:
  - `videos["video:cm:<hash>"]` (ou `video:fg:<id>`) com `novo: "AAAA-MM-DD"`;
  - o id entra em `videos` ou `opcionais` das trilhas certas;
  - `atualizacoes[]`: `{ id, iso, data, titulo, html, video, trilhas }` (o `html` segue as regras de `docs/estudo-modulos.md`).
- O app: `trilhaVisivel()` tira da lista (e do %) as aulas publicadas depois do início da pessoa na trilha, e
  `htmlAtualizacoes()` mostra essas aulas no quadro. "Marcar como vista" grava o item `atualizacao:<id>` em
  `agenda_estudo_progresso`. Selo "novo" por 30 dias.
- Vídeos não são baixados nem gravados. O resumo usa título, descrição e material anexo da aula (quando houver).
  A análise dos trechos continua pela tela, no Chrome do usuário (como nos lotes).
- Se o login de uma plataforma expirar, a rotina avisa o usuário e segue com a outra.

## No ARTEAPP01 (desde 02/11/2026)
Por que saiu da nuvem: a entrada automática na Eduzz (Nutror) passou a pedir captcha, e a Hotmart guarda o login num
cookie de sessão, que some quando o navegador fecha. Nada disso é contornado: **uma pessoa** faz o login, e o roteiro só
usa o Chrome que ficou logado.

- **Pasta:** `C:\Artecon\EstudoCursos`, com Node e `playwright-core` (sem baixar navegador: usa o Chrome instalado).
  Não mexer em `C:\Artecon\WhatsServico`. Cópia dos roteiros em `ferramentas/arteapp01/` no armazenamento `estudo`.
- **Ligação com o Claude:** nessa pasta roda `claude remote-control` (janela aberta, logada na conta do escritório).
  A rotina de segunda manda a ordem para a sessão do Claude ligada ao servidor e lê a resposta no histórico dela
  (a sessão do servidor não consegue responder de volta).
- **`entrar_cursos.js`** abre um **Chrome comum** (sem "controlado por software de teste") com o perfil `perfil`,
  as abas da Nutror e da Hotmart e a porta de controle `9334`, que só atende o próprio servidor (127.0.0.1).
  A pessoa entra nas duas plataformas, **minimiza e deixa o Chrome aberto**. A cada 5 s o login é guardado em `sessao.json`.
  - Nutror: `cleiver@artecon.cnt.br`, código "sem senha" da Eduzz.
  - Hotmart: `artecon@artecon.cnt.br`, e-mail + código. Pedir o código **uma vez** e usar o mais recente.
    Não usar "Entrar com Google".
- **`verificar_semana.js [--salvar]`** usa primeiro o Chrome aberto (porta 9334) numa aba nova, que fecha no fim, e
  mantém o Chrome aberto. Sem esse Chrome, abre o perfil escondido e repõe os cookies de `sessao.json`. A saída começa
  com `via: chrome aberto (porta 9334)` ou `via: perfil escondido`, e grava `semana_<data>.json`.
  `--salvar` troca a base pela lista lida: rodar **só depois** de publicar o `dados.json`, conferido o md5.
- **Servidor reiniciado ou Chrome fechado:** status `login`. Alguém roda `node entrar_cursos.js` na pasta e faz os
  dois logins de novo. A rotina avisa o usuário e não tenta entrar sozinha.
- **Sessão do Windows:** sair do RDP pelo X (desconectar), **nunca "Sair"**. Sair fecha o Chrome dos cursos e o
  `claude remote-control`.
- **Segurança:** `sessao.json` (cookies em texto) e a porta 9334 dão acesso às duas contas a quem usa o servidor.
  A pasta fica restrita aos administradores do ARTEAPP01.
- **Primeira verificação pelo servidor (02/11/2026):** Hotmart ok (401 aulas, nenhuma nova). Nutror ok (98 aulas,
  2 novas): "Exercício Prático - Formação de Preço" (opcionais: Contábil, Intensivo, Avançado) e "Exercício Prático -
  O Simples Nacional na NF-e de 2027" (opcionais: Fiscal, Intensivo, Avançado), no bloco "Simuladores da Reforma
  Tributária". Só o título estava disponível; o resumo entra quando a aula for analisada.
