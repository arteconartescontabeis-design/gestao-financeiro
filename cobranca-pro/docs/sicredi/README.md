# Integração Sicredi — API Cobrança (boletos)

Material recebido da Sicredi em 06/10/2026 e guardado aqui como referência do projeto.

| Arquivo | O que é |
|---|---|
| `Cartilha_Portal_Desenvolvedor.pdf` | Cartilha de 6 páginas: criar a conta no Portal do Desenvolvedor, criar a App e pedir o Access Token |
| `API_Cobranca_Collection_Geral.postman_collection.json` | Coleção Postman oficial (Sandbox e Produção). **Tokens, x-api-key, usuário e senha foram trocados por variáveis** (`{{access_token}}`, `{{x_api_key}}`, `{{usuario}}`, `{{senha}}`). Os originais eram só exemplos/expirados, mas credencial não fica no repositório. |
| Vídeo "Emissão de Access token" (2 min 52 s, não versionado, 16 MB) | Mostra na tela os mesmos passos da cartilha (abaixo) |

## 1. Como obter o acesso (cartilha + vídeo)

1. **Criar conta** em <https://developer.sicredi.com.br/api-portal/pt-br> → "Criar Conta" → **Conta Profissional** → nome, e-mail, senha, aceitar termos → confirmar pelo e-mail.
2. **Criar a App**: Minha Conta → Minhas Apps → **Cadastrar Nova App** → nome e descrição → marcar
   **Open API - OAuth - Parceiros 1.0.0** e **Open API - Cobranca - Parceiros 1.0.0** → Registrar.
   A App já nasce com **Client ID / Client Secret** (status "Aprovada").
3. **Pedir o Access Token** (o Client ID sozinho não basta): Suporte → Abra um chamado →
   tipo **API Cobrança Boletos**, motivo **Solicitar Access Token**, ambiente **Produção** (recomendado pela Sicredi;
   se pedir Sandbox, terá de repetir para Produção), colar o **Client ID** → Enviar.
4. Quando o chamado for resolvido (SLA 24 h; costuma levar 30 min a 1 h): Minhas Apps → **Detalhes** →
   "Tokens de Acesso" mostra o código do token (é este código que vai no header **`x-api-key`**).
5. Dúvidas: 0800-724-4770 (CPF → Pagamentos e Recebíveis). Chamado na PJ Tech: (51) 3358-8000 (tel/WhatsApp),
   pjtech@sicredi.com.br, seg–sex 9h–18h.

## 2. Como a API funciona (coleção Postman)

Base: `https://api-parceiro.sicredi.com.br` — Sandbox usa o prefixo `/sb` (ex.: `/sb/auth/openapi/token`).

### Autenticação (OAuth2 *password*)
`POST /auth/openapi/token` — `Content-Type: application/x-www-form-urlencoded`

| Header | Valor |
|---|---|
| `x-api-key` | token de acesso do portal (passo 4) |
| `context` | `COBRANCA` |

Corpo: `username` = código do beneficiário + cooperativa, `password` = **código de acesso da cobrança gerado no Internet Banking** (não é a senha do portal — confirmar no portal/chamado), `scope=cobranca`, `grant_type=password`.
Resposta: `access_token` (vale ~1 h, JWT) e `refresh_token`.

### Headers de todas as chamadas da cobrança
`Authorization: Bearer <access_token>`, `x-api-key`, `cooperativa` (4 dígitos), `posto` (2 dígitos), `Content-Type: application/json` e, nas instruções, `codigoBeneficiario`.

### Endpoints (Produção; Sandbox = mesmo caminho com `/sb`)

| Uso no Cobrança Pro | Método e caminho |
|---|---|
| **Liquidados do dia** (substitui/compara o .CRT — já previsto no robô, `sicredi.py`) | `GET /cobranca/boleto/v1/boletos/liquidados/dia?codigoBeneficiario=…&dia=DD/MM/AAAA` |
| **Francesinha** (movimentação financeira: créditos/débitos/tarifas) | `GET /cobranca/v1/cobranca-financeiro/movimentacoes?codigoBeneficiario=…&cooperativa=…&posto=…&dataLancamento=DD/MM/AAAA&pagina=0&tipoMovimento=CREDITO\|DEBITO\|AMBOS` |
| Consultar boleto pelo nosso número | `GET /cobranca/boleto/v1/boletos?codigoBeneficiario=…&nossoNumero=…` (há `v2`) |
| Consultar pelo seu número / id da empresa | `GET /cobranca/boleto/v1/boletos/cadastrados?idTituloEmpresa=…&codigoBeneficiario=…` |
| Segunda via em PDF | `GET /cobranca/boleto/v1/boletos/pdf?linhaDigitavel=…` |
| Emitir boleto (futuro: substituir a remessa .CRM) | `POST /cobranca/boleto/v1/boletos` — `pagador`, `beneficiarioFinal`, `codigoBeneficiario`, `dataVencimento` (AAAA-MM-DD), `especieDocumento`, `tipoCobranca` (`NORMAL`/`HIBRIDO` = com Pix), `seuNumero`, `valor`, `mensagens`, `informativos` |
| Instruções (PATCH `/cobranca/boleto/v1/boletos/{nossoNumero}/…`) | `baixa`, `data-vencimento` `{dataVencimento}`, `juros` `{valorOuPercentual}`, `desconto` `{valorDesconto1..3}`, `seu-numero`, `conceder-abatimento`/`cancelar-abatimento` `{valorAbatimento}`, `protesto`, `sustar-protesto-baixar-titulo`, `sustar-protesto-manter-titulo`, `cancelar-protesto-automatico`, `negativacao`, `sustar-negativacao-baixar-titulo`, `sustar-negativacao-manter-titulo` |

Atenções na coleção da Sicredi (conferir na documentação do portal antes de usar):
- Sandbox "Instrução Altera Juros" manda `valorAbatimento`; em Produção o corpo é `valorOuPercentual`.
- Produção "Instrução Altera Juros" aponta para `/desconto` — o caminho certo é `/juros`.
- Formatos de data variam: `dia=DD/MM/AAAA` nos liquidados, `dataVencimento` em ISO no cadastro.

## 3. Onde isso entra no projeto

- **Já existe** (v2.1.2): Configurações → Automação → "Integração Sicredi" (`sicredi_ativo`, `sicredi_modo` = `paralelo` ou fonte única,
  `sicredi_hora`). Hoje está **desligada** (`sicredi_ativo = false`, modo `paralelo`, 07:30).
  O robô (`sicredi.py`) consulta os liquidados do dia útil anterior e gera um .CRT no layout do banco; no modo paralelo compara com o .CRT baixado.
- **Próximos passos** sugeridos:
  1. Obter o token de **Produção** (seção 1) e guardar as credenciais **só no servidor do robô / Vault do Supabase** — nunca no `index.html`.
  2. Rodar em **modo paralelo** por algumas semanas e conferir as diferenças.
  3. Usar a **Francesinha** para conferir tarifas e créditos do dia.
  4. Depois: emissão de boleto e 2ª via pela API (fim da remessa .CRM manual) e instruções (baixa, prorrogação) a partir do app.
- **Segurança**: `access_token` expira em ~1 h (renovar com `refresh_token`); `x-api-key`, usuário e código de acesso ficam no
  cofre do Windows do servidor ou no Vault (mesmo padrão da senha do Questor, v2.8.0). Nada de credencial em log, print ou commit.
