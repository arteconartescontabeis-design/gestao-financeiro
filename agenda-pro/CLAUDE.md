# Agenda Pro — memória do projeto

App de agendamento da **Artecon** (escritório contábil). Tudo em português.
Publicado pelo GitHub Pages: https://arteconartescontabeis-design.github.io/agenda-pro/app.html

## Estrutura
- `app.html` — o app inteiro (HTML + CSS + JS). Supabase via REST (`supa`/`supaWithAuth`), anon key no cliente, protegido por RLS.
- `service-worker.js` — cache: páginas vêm sempre da internet (cópia só sem conexão); `version.json` nunca é guardado.
- `version.json` — número da versão publicada; o app compara com `APP_VERSAO` e mostra o aviso "Nova versão disponível".
- `sql/` — migrations já aplicadas (registro). `supabase/functions/` — Edge Functions publicadas.
- `docs/` — instruções para o servidor (serviço de WhatsApp).
- `estudo.html` — Estudo da Reforma Tributária (v2.3.0; análises de vídeo na v2.4.0 e lote essencial de 11 aulas na v2.7.0, texto em
  `analises/lote-essencial.md` no armazenamento), **separado de propósito para ser apagado depois**:
  trilhas (Executivo, Intensivo, Avançado, Fiscal, Contábil, Pessoal), 40 áudios (voz Azure pt-BR-FranciscaNeural, gerados do
  programa salvo no OneDrive "Reforma Tributária - Programa de Estudo"), conteúdo, vídeos, tarefas e análises em `dados.json`.
  Mesmo login do Agenda.
  **Conteúdo só com login (v2.6.0, Estudo 1.3.0):** áudios (`audio/*.mp3`), `dados.json` e `analises/*` **não ficam no GitHub**
  (o repositório é público): estão no armazenamento privado `estudo` do Supabase (regra `estudo_arquivos_ler`,
  `sql/agenda_estudo_arquivos.sql`; só quem tem acesso ativo ao Estudo lê). O estudo.html baixa o `dados.json` com o login e toca
  os áudios por endereço assinado (12 h, renova sozinho). Para ler, trocar ou acrescentar arquivos: função `estudo-carga`
  (`GET` lista, `GET ?caminho=` baixa, `POST ?caminho=` grava; cabeçalho `x-carga` com o token). O token não fica guardado em lugar
  nenhum, só o hash na função: em outra sessão, gerar um token novo, trocar `HASH` e publicar a função de novo. Mudou o
  `dados.json`, basta subir o arquivo (não precisa trocar `ESTUDO_VERSAO`; o app sempre confere). As versões antigas desses arquivos
  ainda estão no histórico do GitHub (limpar o histórico só com confirmação do usuário).
  Tabelas `agenda_estudo_*` (`sql/agenda_estudo.sql`, com o comando de remoção comentado no fim).
  **Pessoas só do Estudo (v2.5.0, Estudo 1.2.0):** admin/gerente cadastram na aba Equipe do Estudo quem não usa o Agenda.
  Ficam em `agenda_estudo_usuarios` (não em `agenda_usuarios`: não veem nada da agenda), com login próprio e senha provisória
  criados pela função `estudo-usuario`; o Estudo pede a senha nova no 1º acesso. **Só local: não vai para o Portal** (pedido do
  usuário em 11/10/2026). As gravações do Estudo mandam `tenant_id` (para essas pessoas o banco usa `agenda_estudo_tenant_id()`;
  `sql/agenda_estudo_usuarios.sql`). Quem é só do Estudo e entra pelo `app.html` é levado ao `estudo.html`.
  Para remover: apagar `estudo.html`, os dois atalhos no `app.html` (menu lateral e "Mais"), o desvio para o
  estudo em `carregarDadosUsuario` (`app.html`), as funções `estudo-usuario` e `estudo-carga` e, com confirmação do usuário,
  os arquivos e o armazenamento `estudo` e as tabelas (`sql/agenda_estudo.sql`, `sql/agenda_estudo_usuarios.sql` e
  `sql/agenda_estudo_arquivos.sql`). Logins criados pelo Estudo têm `app_metadata.criado_pelo_estudo`.

## Versão e histórico (obrigatório a cada mudança no app)
1. Subir `APP_VERSAO` no `app.html` (padrão `X.Y.Z`: Z = correção, Y = novidade, X = mudança grande).
2. Acrescentar a versão **no topo** de `VERSOES` (data `dd/mm/aaaa` e itens em linguagem simples, para o usuário).
3. Trocar `versao` em `version.json`.
4. Trocar `CACHE_NAME` no `service-worker.js` para `agenda-pro-vX.Y.Z`.
O número aparece no topo de todas as telas e no login; tocar nele abre o histórico.

## Publicação
- Desenvolver no ramo da sessão e abrir pull request para `main`.
- **Autorização permanente (10/10/2026):** o usuário autorizou publicar sempre. Depois de testar, juntar o pull request
  sem perguntar e avisar o que foi publicado (com o número da versão).
- O GitHub Pages publica sozinho em ~1 min depois do merge.

## Supabase
- Projeto do Agenda: `vuwgxndahrzinfdlapxz` (compartilhado com o Financeiro Pro, tabelas `fin_*`). Tabelas `agenda_*`, multi-escritório por `tenant_id` (Artecon = 2).
- Mudanças de banco: só **acrescentar** (comandos que apagam pedem confirmação do usuário). Registrar em `sql/`.
- Edge Functions:
  - `agenda-whats` (index.ts + comandos.ts): avisos ao cliente e comandos da equipe por WhatsApp. Roda pelo pg_cron a cada 30 s.
  - `agenda-equipe`: cadastra pessoa da equipe (cria o login com senha provisória ou reaproveita o existente).
  - `estudo-usuario`: cadastra pessoa só do Estudo (`acao` `cadastrar` ou `nova_senha`); só admin/gerente ativo do Agenda chama.
    Nova senha só para login criado por ela (`app_metadata.criado_pelo_estudo`), nunca para quem já tinha login (Financeiro Pro).
  - `estudo-carga`: manutenção dos arquivos do armazenamento `estudo` (token no cabeçalho `x-carga`, hash na função). Não é usada pelo app.
  - `portal-provisionar` (index.ts + provisionar.ts; Verify JWT **desligado**): chamada pelo Portal Artecon (Acessos). Confere a
    sessão e o papel de administrador no núcleo do portal (projeto `fbxelwhdiisfmnwrerbl`), acha o escritório em `agenda_portal_orgs`
    (Artecon = org `a47ec000-…0001` → tenant 2) e cria/reativa/desativa a pessoa em `agenda_usuarios`. Níveis do portal:
    leitura → visualizador, operador → colaborador (gerente continua gerente), admin → admin. Nunca bloqueia o login (é o mesmo do
    Financeiro Pro) e só troca a senha de quem já tem login com `redefinir: true`. Protege o último administrador.
- Senha provisória: login criado pelo portal ou pelo convite leva `user_metadata.trocar_senha = true`; o app (v2.2.0+) pede a senha nova.
- Pessoa com `agenda_usuarios.ativo = false` não vê dados: `agenda_meu_tenant_id/perfil/usuario_id` só olham cadastros ativos
  (`sql/agenda_portal_controle.sql`).

## WhatsApp (mesmo número do Cobrança Pro)
- O serviço `artecon-whats` (servidor ARTEDB01, código fora do GitHub) envia o que está em `cob_whatsapp_fila` no projeto do Cobrança (`yeujqjtjqtegsnzwwazb`).
- O Agenda entra nessa fila só por `cob_agenda_enfileirar` / `cob_agenda_status` / `cob_agenda_recebidas` (token no cofre do projeto do Agenda: `vault` → `cob_agenda_token`; no Cobrança fica só o hash em `cob_agenda_integracao`).
- Avisos: `agenda_whats_avisos` (gatilho em `agenda_agendamentos` + `agenda_whats_gerar_lembretes`). Liberação por escritório em `agenda_whats_tenants`. Tipos ligados em `agenda_config` (`whats_*`). Nada sai entre 21h e 7h (só teste).
- Comandos da equipe: o serviço `artecon-whats.js` **v1.5.1** (instalado no ARTEDB01 em 11/10/2026, testado de ponta a ponta com áudio) grava o que recebe em `cob_whatsapp_recebidas`; o arquivo está no OneDrive (`Agenda Pro/Versão Atual/Atualização WhatsApp v1.5.1/`; a v1.4.1 ficou no servidor como `artecon-whats-v1.4.1.js`). Detalhes em `docs/servico-whats-mensagens-recebidas.md`. Versão em uso: `cob_whatsapp_sessao.versao_servico` no Cobrança. Registro em `agenda_whats_comandos`. Só números em `agenda_usuarios.whatsapp` são atendidos.
- Áudio e resposta rápida (serviço **v1.5.1**, instalado em 11/10/2026; a v1.5.0 nunca foi instalada; chave da Azure `artecon-voz` CHAVE 1 no cofre do servidor): áudio da equipe transcrito pela Azure (cofre `AZURE_FALA_CHAVE`, limites em config.json) e guardado com a marca `🎤 ` — a função `agenda-whats` tira a marca e responde `Ouvi: "..."`. A função publica os números da equipe no Cobrança (`cob_agenda_equipe_set`); o serviço usa `cob_whatsapp_equipe` e `cob_whatsapp_proxima_resposta` (`sql/cobranca_whatsapp_equipe_audio.sql`).
- Minutos de áudio no portal: o serviço (v1.5.1) grava os segundos em `cob_whatsapp_recebidas.audio_seg`; a `agenda-whats`
  lê por `cob_agenda_recebidas2` e informa ao núcleo do portal (`public.ia_fala_registrar`, token do cofre `ia_fala_token`).
  Portal (v1.7.0) → Consumo de IA: um cartão por uso da Azure em "Por aplicativo" e o quadro "Azure — voz e transcrição" com as
  duas cotas grátis do recurso `artecon-voz` (transcrição 5 h/mês; voz 500 mil caracteres/mês) (`core.ia_fala_painel`, tabelas
  `core.ia_fala_apps`/`ia_fala_uso`; `sql/nucleo_ia_fala.sql` e `sql/nucleo_ia_fala_v2.sql`). Apps: `agenda` (transcrição, automático),
  `estudo` e `crianca` (voz, lançados à mão). **Ao gerar voz com a Azure** (falas do Projeto Criança, faixas do Estudo etc.), lançar os
  caracteres em Portal → Consumo de IA → Lançar uso (ou `core.ia_fala_lancar`). Já lançado em 11/10/2026: Projeto Criança ~7 mil e
  Estudo ~112 mil caracteres (estimado pelo texto das 40 faixas). A IA Central (Claude/OpenAI, `ia-gateway`) não foi mexida: o Agenda não usa IA paga — a voz no app é
  o reconhecimento do navegador e os comandos são interpretados pelo `AGCMD`/`comandos.ts`.
- Resposta rápida: o gatilho `trg_recebida_avisar_agenda` (em `cob_whatsapp_recebidas`, no Cobrança) chama a função `agenda-whats` assim que uma mensagem chega (`sql/cobranca_recebidas_aviso_agenda.sql`); o pg_cron de 30 s fica de reserva. O resto da espera é do serviço: ele olha a fila a cada `consulta_fila_seg` (config.json, padrão 20 s) e espera 20–45 s entre um envio e outro.
- Diagnóstico: as chamadas do serviço aparecem nos logs do projeto do Cobrança (agente `node`); o log do servidor (`logs\whats_AAAAMMDD.log`) diz por que uma mensagem recebida não foi guardada (v1.4.1+). Para reiniciar o serviço, o usuário já sabe o caminho no servidor.

## Lista (próximos passos)
1. ~~**Instalar o serviço WhatsApp v1.5.1 no ARTEDB01**~~ **Feito em 11/10/2026** (áudio "agenda de hoje" de 1 s transcrito,
   respondido em ~12 s e contado no portal). Usa a **Azure do Projeto Criança**: recurso `artecon-voz` (grupo `artecon-voz`, Brazil South,
   plano Gratuito F0, assinatura "Azure subscription 1"), CHAVE 1 (a CHAVE 2 é do Corretor de Vídeos do Radar). As 5 h/mês grátis são do
   recurso inteiro. **Pendente:** a avaliação grátis da Azure vence por volta de **08/11/2026** — antes disso, passar a assinatura para
   pagamento conforme o uso (o F0 continua grátis), senão o recurso para (também no Projeto Criança).
2. ~~**Agenda Pro no Portal Artecon, com o controle de acesso**~~ **Feito em 10/10/2026** (portal v1.5.0 + Agenda v2.2.0 +
   função `portal-provisionar`). Ficou como o Cobrança: login próprio com senha provisória. Em aberto, se o usuário quiser:
   entrar no Agenda direto pelo portal (sem digitar a senha de novo) e cadastrar o WhatsApp da pessoa pelo portal. Anotações originais:
   - Hoje: o Agenda já está no catálogo do portal (núcleo, projeto Supabase `fbxelwhdiisfmnwrerbl`: `core.apps` id `agenda`,
     destino `https://arteconartescontabeis-design.github.io/agenda-pro/`, papéis `leitura`/`operador`/`admin` em `core.app_roles`,
     liberações em `core.app_access`). Mas liberar ou revogar no portal **não** mexe no login do Agenda.
   - Fazer como o Cobrança Pro (portal v1.1.0): função `portal-provisionar` no projeto do Agenda, chamada pelo portal
     (`CFG.provisionar.agenda` no `index.html` do repositório `portal`). Ela confere a sessão e o papel de administrador no núcleo,
     cria ou reativa o login com senha provisória (reaproveitar a lógica da `agenda-equipe`) e cadastra a pessoa em `agenda_usuarios`;
     revogar desativa a pessoa e o login. Papéis: leitura → visualizador, operador → colaborador, admin → admin.
   - A decidir com o usuário: entrar no Agenda direto pelo portal (sem pedir a senha de novo) ou manter o login próprio;
     escritório (tenant) de quem é liberado; se o WhatsApp da pessoa também vem do portal.

## Segurança (revisão de 12/10/2026, `sql/seguranca_2026-10-12.sql`)
- Sessão: o app (v2.8.0+) e o `estudo.html` guardam só o acesso (`agenda_token`) e, com "Manter conectado", o código de renovação
  (`agenda_refresh`, o mesmo nos dois; o servidor troca a cada uso). **Nunca guardar senha no navegador.** `sessaoRenovar()` renova
  a cada 45 min e no 401 (`supaWithAuth(token, true)`).
- Visões novas: sempre `security_invoker = true` e sem `anon`. As regras para quem não está logado (agendamento por link público,
  bloqueios, disponibilidade) estão desligadas com `false` — não existe página pública.
- Gerente não cadastra administrador (regra `usuarios_insert_admin`).
- Núcleo do portal: `enviar_email`/`cct_email_db` só para a chave de serviço; funções do robô do CCT fechadas sem login.
- Azure: chaves, troca e orçamento em `docs/azure-chaves-e-custo.md`; avisos de 80%/100% das cotas em `sql/nucleo_ia_fala_avisos.sql`.
- Feito pelo usuário (12/10/2026): a chave da Anthropic do histórico (final `6QAA`) já não existe no console; "Prevent use of
  leaked passwords" ligado nos três projetos (agenda-pro, Departamento Pessoal e Cobrança; conferido nos alertas do Supabase). Pendente: orçamento na Azure antes de 08/11/2026.
- Fora do Agenda (avisar, não mexer sem pedido): no mesmo projeto, as funções `fin_*` do Financeiro aceitam chamada sem login
  (conferir dentro de cada uma); `validar-anexos` lê documento sem login (limitado pela IA Central a US$ 1/dia).
  O armazenamento `fin-documentos` (privado) deixa **qualquer pessoa logada** no projeto ler, trocar e apagar todos os arquivos
  (inclusive quem é só do Agenda ou só do Estudo): a regra olha só o nome do armazenamento.

## Regras
- Dado do banco que vai para `innerHTML` passa por `whatsEsc` (texto e atributos) e cor do banco por `corSegura` — em todo o app
  desde a v2.8.0. Id em `onclick` vai como `Number(...)`.
- Interface de celular: barra inferior (`UI`, `uiIniciar`), modo simples (`renderHoje`) para colaborador e modo controlador (`renderPainel`) para admin/gerente.
- O interpretador `AGCMD` dentro do `app.html` é a cópia em JS de `supabase/functions/agenda-whats/comandos.ts`: mudou um, mudar o outro.
