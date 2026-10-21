# Serviço artecon-whats: guardar as mensagens recebidas

Para a equipe agendar reuniões mandando mensagem ao WhatsApp da Artecon, o
serviço `artecon-whats` (servidor ARTEAPP01; antes ARTEDB01) precisa **gravar o que recebe** na
tabela `cob_whatsapp_recebidas` (projeto Supabase do Cobrança). O resto já
está pronto: a função `agenda-whats` lê essa tabela a cada 30 s, só considera
os números da equipe cadastrados no Agenda Pro e responde pela fila de sempre.

## Versão instalada: artecon-whats v1.5.1 (11/10/2026)

Instalada no ARTEDB01 em 11/10/2026 e testada: áudio "agenda de hoje" do Cleiver transcrito pela Azure,
respondido em ~12 s (`🎤 Ouvi: "Agenda de hoje."` + agenda do dia) e contado no portal (1 s).

No OneDrive: `Aplicativo Criado Artecon/Agenda Pro/Versão Atual/Atualização WhatsApp v1.5.1/`
(`artecon-whats.js` e `guardar-chave-azure.bat`). Instalar esta no lugar da v1.5.0 (que nunca foi instalada).

O que a v1.5.1 acrescenta à v1.5.0:
- grava em `cob_whatsapp_recebidas.audio_seg` quantos segundos de áudio foram para a Azure (também
  quando a Azure não entendeu, porque conta do mesmo jeito; áudio recusado antes, por ser longo ou
  por limite, não conta);
- a função `agenda-whats` lê por `cob_agenda_recebidas2` e informa ao núcleo do portal
  (`public.ia_fala_registrar`, token `ia_fala_token` no cofre do Agenda). Aparece em
  **Portal → Consumo de IA → Transcrição de áudio (Azure)**: minutos do mês e do dia contra as 5 h grátis.
- Banco: `sql/cobranca_recebidas_audio_seg.sql`, `sql/nucleo_ia_fala.sql`, `sql/agenda_ia_fala.sql` (aplicados).

### O que já vinha na v1.5.0

- **Áudio da equipe:** mensagem de voz (até 60 s) de quem está em
  `agenda_usuarios.whatsapp` é transcrita pela Azure (REST de áudio curto,
  `pt-BR`, OGG/Opus) e guardada com a marca `🎤 `. O Agenda responde
  `🎤 Ouvi: "..."` e o resultado do comando; se não entender, pede para mandar
  `ajuda`. Áudio de cliente não é transcrito.
- **Lista da equipe:** a função `agenda-whats` publica os números no Cobrança
  (`cob_agenda_equipe_set` → `cob_agenda_integracao.equipe_chaves`); o serviço
  lê com `cob_whatsapp_equipe` a cada 5 min.
- **Chave:** cofre do Windows `ArteconRobo` → `AZURE_FALA_CHAVE` (o
  `guardar-chave-azure.bat` grava). Usar o recurso de voz que já existe, do
  Projeto Criança: `artecon-voz` (Brazil South, plano Gratuito F0). Região em `config.json` → `azure_regiao`
  (padrão `brazilsouth`). Sem chave, o áudio da equipe recebe "mande por texto".
- **Custo:** a Azure cobra por segundo de áudio; o plano gratuito dá 5 h/mês.
  Limites no `config.json`: `audio_max_seg` (60), `audio_limite_dia_min` (30),
  `audio_limite_mes_min` (270). O uso fica em `audio.json` na pasta do serviço.
- **Resposta rápida:** depois de uma mensagem da equipe, o serviço olha
  `cob_whatsapp_proxima_resposta` a cada 2 s por `resposta_rapida_seg` (90 s) e
  envia sem a pausa de 20–45 s das cobranças (também fora do horário de envio).
- Banco: `sql/cobranca_whatsapp_equipe_audio.sql` (aplicado). Teste do lado do
  Agenda com áudio simulado: resposta `🎤 Ouvi: "Agenda amanhã."` em 12 s, ainda
  com a v1.4.1 no servidor.

## Versão instalada: artecon-whats v1.4.1 (10/10/2026)

Instalada no ARTEDB01 em 10/10/2026 e testada de ponta a ponta: a mensagem
"ajuda" mandada do celular da equipe foi guardada, entendida pelo Agenda e
respondida em 22 segundos.

O arquivo completo está no OneDrive, em
`Aplicativo Criado Artecon/Agenda Pro/Versão Atual/Atualização WhatsApp v1.4.1/artecon-whats.js`.

O que a v1.4.1 acrescenta à v1.4.0:
- toda mensagem de conversa individual que **não** for guardada aparece no log
  com o motivo (o WhatsApp não conseguiu ler, sem texto, enviada pelo próprio
  número da Artecon). A v1.4.0 descartava em silêncio e o primeiro teste real
  não foi guardado sem deixar pista;
- lê o texto que vem "embrulhado" (temporária, visualização única etc.);
- o início do log mostra a versão da biblioteca `baileys` instalada.

As mensagens da equipe chegam como `@lid`; o número vem em `remoteJidAlt`.

### Histórico: v1.4.0
Foi feito a partir da v1.3.1 (a da pasta `Versão Atual`), então também leva o
Pix copia e cola e a conferência da chave Pix (v1.3.0 e v1.3.1).

O que muda na v1.4.0:
- guarda as mensagens de **texto** recebidas em conversas individuais (grupos,
  status, canais, fotos, áudios e figurinhas ficam de fora);
- contatos que chegam como `@lid` têm o número buscado em `remoteJidAlt` /
  `senderPn` ou no mapa da biblioteca (`signalRepository.lidMapping`);
- mensagens que chegam com o serviço reconectando (`append`) só entram se
  forem dos últimos 30 minutos;
- grava com o mesmo usuário do robô (política `cob_whatsapp_recebidas_ins`;
  conferido em 10/10/2026 que esse usuário tem permissão);
- respostas aos comandos da equipe (`contexto.tipo = "resposta_comando"`)
  saem só em texto, sem o logotipo;
- erro ao guardar uma mensagem recebida nunca atrapalha o envio (só um aviso no log).

### Como instalar no servidor (hoje ARTEAPP01)
1. Parar o serviço (fechar a janela do `node artecon-whats.js` ou parar o que o liga).
2. Na pasta do serviço, renomear o `artecon-whats.js` atual para `artecon-whats-antigo.js` (cópia de segurança).
3. Copiar o novo `artecon-whats.js` da pasta do OneDrive para a pasta do serviço.
4. **Não apagar** a pasta `sessao` (é o pareamento), nem `config.json` e `logo.jpg`.
5. (Opcional) `node artecon-whats.js --checar` para conferir o acesso ao banco.
6. Ligar o serviço como sempre. Não é preciso ler o QR Code de novo.
7. Conferir no Cobrança Pro → Robô → WhatsApp: "Conectado" e versão **1.4.0**.

O serviço só envia entre `hora_inicio` e `hora_fim` do `config.json` (padrão 8h–20h).
Uma mensagem de comando mandada fora desse horário é registrada no Agenda, mas a
resposta só sairia no horário de envio, e a fila expira à meia-noite.

## Trecho genérico (para outro serviço Baileys)

Logo depois de criar a conexão (`sock`), junto dos outros `sock.ev.on(...)`.
Os nomes `supabase`, `TENANT_ID` e `log` devem ser trocados pelos que o
serviço já usa.

```js
// v1.4.0: guarda as mensagens de texto recebidas (conversas individuais)
sock.ev.on('messages.upsert', async ({ messages, type }) => {
  if (type !== 'notify') return;
  for (const m of messages) {
    try {
      if (!m.message || m.key.fromMe) continue;
      const jid = m.key.remoteJid || '';
      if (jid.endsWith('@g.us') || jid === 'status@broadcast' || jid.endsWith('@newsletter')) continue;
      // contatos novos podem vir como "@lid": o número fica em senderPn / remoteJidAlt
      const jidNumero = jid.endsWith('@lid') ? (m.key.senderPn || m.key.remoteJidAlt || '') : jid;
      let tel = String(jidNumero.split('@')[0] || '').replace(/\D/g, '');
      if ((tel.length === 12 || tel.length === 13) && tel.startsWith('55')) tel = tel.slice(2);
      if (tel.length < 10) continue;
      const msg = m.message.ephemeralMessage?.message || m.message;
      const texto = msg.conversation || msg.extendedTextMessage?.text || '';
      if (!texto.trim()) continue;
      const { error } = await supabase.from('cob_whatsapp_recebidas').insert({
        tenant_id: TENANT_ID,
        telefone: tel,
        jid,
        nome: m.pushName || null,
        texto: texto.slice(0, 2000),
        id_mensagem: m.key.id,
        recebido_em: new Date(Number(m.messageTimestamp || Date.now() / 1000) * 1000).toISOString(),
      });
      if (error && !/duplicate key/i.test(error.message)) log('mensagem recebida não gravada: ' + error.message);
    } catch (e) {
      log('erro ao gravar mensagem recebida: ' + e.message);
    }
  }
});
```

Observações:
- Se o serviço usa a chave `service_role`, a gravação passa direto. Se entra
  com usuário e senha, a política `cob_whatsapp_recebidas_ins` já permite
  gravar para quem é do escritório.
- Um erro aqui nunca interrompe o envio das cobranças (fica dentro do `try`).
- Depois de trocar o arquivo, reiniciar o serviço. Não é preciso ler o QR Code
  de novo.
