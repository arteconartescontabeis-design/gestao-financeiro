// ============================================================
// cobranca-pro · Edge Function  validar-anexos  (código "claude-proxy") — v3.2.0 (20/10/2026)
// v3.2.0 — o token do Financeiro na IA Central fica no COFRE do banco (ia_gateway_token_financeiro), gerado lá dentro
//   em 20/10/2026 (ninguém vê o valor; o Portal guarda só o sha256). O secret IA_GATEWAY_TOKEN continua aceito como
//   alternativa. Nada mais mudou.
// v3.1.0 — mesma função que estava no agenda-pro, agora no projeto do Financeiro (cobranca-pro, banco da Gestão
//   Empresarial e Financeiro), onde fica o login dele. Código igual ao da v3.0.0. Precisa do secret IA_GATEWAY_TOKEN
//   NESTE projeto (token do Financeiro no Portal → Consumo de IA) — no agenda-pro ele nunca chegou a ser cadastrado.
// v3.0.0 — IA CENTRAL (Fase 3 do controle de consumo):
//   • Não fala mais direto com a Anthropic nem guarda chave da Anthropic. Chama o
//     ia-gateway do projeto Departamento Pessoal com o token do Financeiro
//     (secret IA_GATEWAY_TOKEN). O consumo aparece no Portal → Consumo de IA e respeita
//     os limites do Financeiro (mensal, diário, modelo Haiku e total da Artecon).
//   • Cada chamada vai identificada com o e-mail de quem estava logado (quando houver).
//   • Se o gateway recusar (limite, token trocado, sem crédito), o motivo em português
//     vem no campo "error" da resposta.
//   Prompt, modelo, travas da v2.1.0 e resposta NÃO mudaram — o Financeiro segue igual.
// v2.1.0 — TRAVAS DE SEGURANÇA E CUSTO (achado 11 do inventário, 26/09/2026):
//   • Modo proxy (legado): passa a EXIGIR usuário logado (o Financeiro já envia o token),
//     com modelo FIXO (Haiku 4.5) e no máximo 1.024 tokens de resposta — antes aceitava
//     qualquer modelo e qualquer tamanho, de qualquer pessoa, pagos pela chave da Artecon.
//   • Modo validação de documento: continua sem login (o app chama sem token), mas com
//     limite de tamanho do arquivo e limite de chamadas por endereço (30 por minuto).
//   • A chave enviada no corpo (apiKey) deixa de ser aceita: só vale o secret do servidor.
//   Prompt, modelo e resposta da validação de documento NÃO mudaram — o app segue igual.
// ============================================================
// claude-proxy — versão enriquecida
// ------------------------------------------------------------
// Modo 1 (legado): proxy genérico para Claude API
//   → body: { messages, model, max_tokens, apiKey? }
//   → retrocompatível com o app atual
//
// Modo 2 (novo): validação de documento
//   → body: { validar_documento: true, file_base64, media_type,
//             file_name, lancamento }
//   → retorna diagnóstico estruturado
//
// v3.0.0: a chamada vai para o ia-gateway com o secret IA_GATEWAY_TOKEN (iagw_financeiro_...).
// Opcional: IA_GATEWAY_URL. O secret ANTHROPIC_API_KEY deixa de ser usado e pode ser excluído.
// ============================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-api-key',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ------------------------------------------------------------
// Travas (v2.1.0)
// ------------------------------------------------------------
const MODELO_FIXO = 'claude-haiku-4-5-20251001';
const MAX_TOKENS = 1024;
const MAX_CORPO = 7_500_000;          // ~5 MB de arquivo em base64 + dados do lançamento
const JANELA_MS = 60_000, MAX_POR_JANELA = 30;
const chamadas = new Map<string, number[]>();
const GATEWAY_URL = Deno.env.get('IA_GATEWAY_URL') ||
  'https://fbxelwhdiisfmnwrerbl.supabase.co/functions/v1/ia-gateway';

// v3.2.0: token do Financeiro lido do cofre do banco (só a chave de serviço lê); cache enquanto a instância viver
let tokenCofre = '';
async function tokenIA(): Promise<string> {
  const env = (Deno.env.get('IA_GATEWAY_TOKEN') || '').trim();
  if (env) return env;
  if (tokenCofre) return tokenCofre;
  const url = Deno.env.get('SUPABASE_URL') || '';
  const srk = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  try {
    const r = await fetch(url + '/rest/v1/rpc/segredo_servico', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: srk, authorization: 'Bearer ' + srk },
      body: JSON.stringify({ p_nome: 'ia_gateway_token_financeiro' }),
      signal: AbortSignal.timeout(10_000),
    });
    const v = r.ok ? await r.json() : null;
    if (typeof v === 'string' && v.startsWith('iagw_')) tokenCofre = v.trim();
  } catch (_e) { /* sem cofre: segue sem token e o erro explica */ }
  return tokenCofre;
}

function limiteOk(chave: string): boolean {
  const agora = Date.now();
  const lista = (chamadas.get(chave) || []).filter((t) => agora - t < JANELA_MS);
  if (lista.length >= MAX_POR_JANELA) { chamadas.set(chave, lista); return false; }
  lista.push(agora); chamadas.set(chave, lista);
  if (chamadas.size > 500) for (const [k, v] of chamadas) if (!v.some((t) => agora - t < JANELA_MS)) chamadas.delete(k);
  return true;
}

async function usuarioLogado(req: Request): Promise<string | null> {
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  const url = Deno.env.get('SUPABASE_URL') || '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') || '';
  if (!token || !url || token === anon) return null;
  try {
    const r = await fetch(url + '/auth/v1/user', { headers: { apikey: anon, authorization: 'Bearer ' + token } });
    if (!r.ok) return null;
    const u = await r.json();
    return (u && u.id) ? String(u.email || u.id) : null;
  } catch { return null; }
}

// ------------------------------------------------------------
// Utilidades
// ------------------------------------------------------------
function somenteDigitos(s: string | null | undefined): string {
  return (s || '').replace(/\D/g, '');
}

function jsonResponse(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// ------------------------------------------------------------
// Prompt para extração de documento
// ------------------------------------------------------------
const SYSTEM_PROMPT_VALIDACAO = `Você é um especialista em leitura de documentos fiscais e financeiros brasileiros (NFe, NFSe, boletos, recibos, comprovantes).

Extraia informações do documento e retorne APENAS um JSON válido, sem texto antes ou depois, sem markdown, sem comentários.

Formato exato:
{
  "tipo_documento": "NFe" | "NFSe" | "boleto" | "recibo" | "comprovante" | "outro",
  "cnpj_cpf_emitente": "apenas_digitos_ou_null",
  "nome_emitente": "texto_ou_null",
  "cnpj_cpf_destinatario": "apenas_digitos_ou_null",
  "nome_destinatario": "texto_ou_null",
  "valor_total": numero_decimal_ou_null,
  "data_emissao": "YYYY-MM-DD_ou_null",
  "data_vencimento": "YYYY-MM-DD_ou_null",
  "numero_documento": "texto_ou_null",
  "descricao": "texto_resumido_ou_null",
  "confianca": numero_de_0_a_100,
  "observacoes": "texto_curto_ate_150_chars"
}

Regras:
- CNPJ/CPF: APENAS dígitos (sem pontos, traços, barras)
- Valores: decimal em Real sem R$
- Datas: ISO YYYY-MM-DD
- Campo não identificável: null
- confianca: 100 (texto perfeito) a 0 (ilegível)`;

// ------------------------------------------------------------
// Chamar Claude API
// ------------------------------------------------------------
async function callClaude(
  apiKey: string,
  payload: Record<string, unknown>,
  usuario: string | null = null,
) {
  const cab: Record<string, string> = {
    'content-type': 'application/json',
    'x-api-key': apiKey,               // v3.0.0: token do Financeiro na IA Central
    'anthropic-version': '2023-06-01',
  };
  if (usuario) cab['x-ia-usuario'] = usuario.slice(0, 120);
  const resp = await fetch(GATEWAY_URL, {
    method: 'POST',
    headers: cab,
    body: JSON.stringify(payload),
  });
  const txt = await resp.text();
  let data: any;
  try {
    data = JSON.parse(txt);
  } catch {
    data = { raw: txt };
  }
  return { status: resp.status, ok: resp.ok, data };
}

// ------------------------------------------------------------
// Validação de documento
// ------------------------------------------------------------
async function handleValidacao(apiKey: string, body: any, usuario: string | null = null) {
  const { file_base64, media_type, file_name, lancamento } = body;

  if (!file_base64 || !media_type || !lancamento) {
    return jsonResponse({
      status: 'erro',
      etapa: 'params',
      error: 'Faltam: file_base64, media_type, lancamento',
    });
  }

  const isImage = media_type.startsWith('image/');
  const isPdf = media_type === 'application/pdf';

  let userContent: any;
  if (isImage || isPdf) {
    userContent = [
      {
        type: isPdf ? 'document' : 'image',
        source: { type: 'base64', media_type, data: file_base64 },
      },
      {
        type: 'text',
        text: `Extraia as informações deste documento (${file_name || 'documento'}) no formato JSON especificado. Retorne APENAS o JSON.`,
      },
    ];
  } else {
    let textoArquivo = '';
    try {
      textoArquivo = atob(file_base64);
    } catch {
      textoArquivo = file_base64;
    }
    userContent = [
      {
        type: 'text',
        text: `Analise este conteúdo e extraia no formato JSON especificado. Retorne APENAS o JSON.\n\n---\n${textoArquivo.slice(0, 50000)}\n---`,
      },
    ];
  }

  const claudeResp = await callClaude(apiKey, {
    model: 'claude-haiku-4-5-20251001',
    max_tokens: 1024,
    system: SYSTEM_PROMPT_VALIDACAO,
    messages: [{ role: 'user', content: userContent }],
  }, usuario);

  if (!claudeResp.ok) {
    return jsonResponse({
      status: 'erro',
      etapa: 'claude_api',
      error: claudeResp.data?.error?.message || ('IA Central ' + claudeResp.status),
      claude_status: claudeResp.status,
      claude_response: claudeResp.data,
    });
  }

  // Extrair texto da resposta
  const textBlock = claudeResp.data.content?.find(
    (b: any) => b.type === 'text',
  );
  if (!textBlock) {
    return jsonResponse({
      status: 'erro',
      etapa: 'claude_sem_texto',
      claude_response: claudeResp.data,
    });
  }

  // Parsear JSON (removendo markdown se vier)
  let raw = textBlock.text.trim();
  raw = raw.replace(/^```json\s*/i, '').replace(/^```\s*/i, '');
  raw = raw.replace(/```$/, '').trim();

  let extraido: any;
  try {
    extraido = JSON.parse(raw);
  } catch {
    return jsonResponse({
      status: 'erro',
      etapa: 'parse_json',
      error: 'Claude não retornou JSON válido',
      raw: raw.slice(0, 500),
    });
  }

  // ============================================================
  // Comparação com lançamento
  // ============================================================
  const divergencias: any[] = [];
  const coincidencias: any[] = [];

  const cnpjDoc = somenteDigitos(
    extraido.cnpj_cpf_emitente || extraido.cnpj_cpf_destinatario,
  );
  const cnpjLanc = somenteDigitos(lancamento.entidade_cnpj_cpf);

  let cnpjConfere: boolean | null = null;
  if (cnpjLanc && cnpjDoc) {
    cnpjConfere = cnpjDoc === cnpjLanc;
    if (cnpjConfere) {
      coincidencias.push({ campo: 'CNPJ/CPF', valor: cnpjDoc });
    } else {
      divergencias.push({
        campo: 'CNPJ/CPF',
        digitado: cnpjLanc,
        documento: cnpjDoc,
        critico: true,
      });
    }
  }

  // Valor
  if (
    extraido.valor_total !== null &&
    extraido.valor_total !== undefined &&
    lancamento.valor
  ) {
    const valorDoc = Number(extraido.valor_total);
    const valorLanc = Number(lancamento.valor);
    if (Math.abs(valorDoc - valorLanc) < 0.01) {
      coincidencias.push({ campo: 'Valor', valor: valorDoc });
    } else {
      divergencias.push({
        campo: 'Valor',
        digitado: valorLanc,
        documento: valorDoc,
        critico: false,
      });
    }
  }

  // Data
  const dataDoc = extraido.data_vencimento || extraido.data_emissao;
  if (dataDoc && lancamento.vencimento) {
    if (dataDoc === lancamento.vencimento) {
      coincidencias.push({ campo: 'Data', valor: dataDoc });
    } else {
      divergencias.push({
        campo: 'Data',
        digitado: lancamento.vencimento,
        documento: dataDoc,
        critico: false,
      });
    }
  }

  // Número documento
  if (extraido.numero_documento && lancamento.numero_documento) {
    const a = String(extraido.numero_documento).trim();
    const b = String(lancamento.numero_documento).trim();
    if (a === b) {
      coincidencias.push({ campo: 'Número documento', valor: a });
    } else {
      divergencias.push({
        campo: 'Número documento',
        digitado: b,
        documento: a,
        critico: false,
      });
    }
  }

  // Decisão final
  let status: 'ok' | 'divergente' | 'bloqueado' | 'sem_validacao';
  let mensagem: string;

  if (!cnpjLanc) {
    status = 'bloqueado';
    mensagem =
      'A entidade (cliente/fornecedor) deste lançamento não tem CNPJ/CPF cadastrado. Cadastre antes de anexar.';
  } else if (!cnpjDoc) {
    status = 'sem_validacao';
    mensagem =
      'Não foi possível identificar CNPJ/CPF no documento. Verifique manualmente.';
  } else if (cnpjConfere === false) {
    status = 'bloqueado';
    mensagem = `O CNPJ/CPF do documento (${cnpjDoc}) não corresponde ao da entidade cadastrada (${cnpjLanc}).`;
  } else if (divergencias.length === 0) {
    status = 'ok';
    mensagem = 'Documento confere com o lançamento.';
  } else {
    status = 'divergente';
    mensagem = `Encontradas ${divergencias.length} divergência(s). Revise antes de confirmar.`;
  }

  return jsonResponse({
    status,
    mensagem,
    cnpj_confere: cnpjConfere,
    divergencias,
    coincidencias,
    dados_extraidos: extraido,
  });
}

// ------------------------------------------------------------
// Proxy genérico (modo legado)
// ------------------------------------------------------------
async function handleProxy(apiKey: string, body: any, usuario: string | null = null) {
  const { messages, model, max_tokens, system, temperature } = body;

  if (!messages) {
    return jsonResponse(
      { error: "Missing 'messages' in body" },
      400,
    );
  }

  // v2.1.0: modelo fixo e teto de resposta (o app usa exatamente estes valores)
  void model;
  const payload: Record<string, unknown> = {
    model: MODELO_FIXO,
    max_tokens: Math.min(Number(max_tokens) || MAX_TOKENS, MAX_TOKENS),
    messages,
  };
  if (system) payload.system = system;
  if (temperature !== undefined) payload.temperature = temperature;

  const claudeResp = await callClaude(apiKey, payload, usuario);
  return jsonResponse(claudeResp.data, claudeResp.status);
}

// ------------------------------------------------------------
// Handler principal
// ------------------------------------------------------------
serve(async (req) => {
  // Preflight CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const bruto = await req.text();
    if (bruto.length > MAX_CORPO) {
      return jsonResponse({ status: 'erro', etapa: 'tamanho', error: 'Arquivo grande demais para leitura por IA (máximo 5 MB).' }, 413);
    }
    const body = JSON.parse(bruto);

    // v3.0.0: token do Financeiro na IA Central (a chave vinda do corpo continua não aceita)
    const apiKey = await tokenIA();

    if (!apiKey.startsWith('iagw_')) {
      return jsonResponse({
        status: 'erro',
        etapa: 'apikey',
        error:
          'Falta o token do Financeiro na IA Central (cofre ia_gateway_token_financeiro ou secret IA_GATEWAY_TOKEN).',
      });
    }

    // Roteia por modo
    if (body.validar_documento === true) {
      const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || 'sem-ip';
      if (!limiteOk(ip)) {
        return jsonResponse({ status: 'erro', etapa: 'limite', error: 'Muitas leituras em sequência — aguarde um minuto.' }, 429);
      }
      return await handleValidacao(apiKey, body, await usuarioLogado(req));
    }

    // v2.1.0: modo proxy só para usuário logado
    const usuario = await usuarioLogado(req);
    if (!usuario) {
      return jsonResponse({ error: 'Faça login no Financeiro para usar a leitura por IA.' }, 401);
    }
    return await handleProxy(apiKey, body, usuario);
  } catch (err) {
    return jsonResponse({
      status: 'erro',
      etapa: 'catch',
      error: err instanceof Error ? err.message : String(err),
    });
  }
});
