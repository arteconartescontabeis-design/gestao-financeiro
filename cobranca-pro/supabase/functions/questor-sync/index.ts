// ============================================================
// COBRANÇA PRO — Edge Function: questor-sync  (v1.0 · app v2.22.0)
// Integração com a API do Questor Negócio em MODO PARALELO:
// só lê a API, compara com o app e registra o resultado em
// cob_automacao_execucoes (origem 'questor_api'). NENHUM envio,
// baixa ou parcela depende dela nesta fase.
//
// Ações (POST { acao, tenant_id }):
//   • testar    — autentica na API e lista os estabelecimentos da conta
//   • capturar  — para cada empresa ativa com CNPJ do Questor vinculado:
//                 títulos (ConsultarContasReceber) e baixas dos últimos 7 dias
//                 (ConsultarBaixaContasReceber), compara com cob_parcelas /
//                 cob_pagamentos e grava a execução com o resumo por empresa.
//
// Segurança:
//   • usuário logado e com vínculo ativo no tenant (conferido com o token dele, sob RLS);
//   • a chave da API vem do cofre do banco: segredo_servico('questor_api_key')
//     — só a chave de serviço lê; o valor nunca aparece em código, log ou resposta;
//   • o endereço da conta pode vir do cofre ('questor_api_url'); sem ele, usa o padrão.
// Secrets: nenhum novo (SUPABASE_URL, SUPABASE_ANON_KEY e SUPABASE_SERVICE_ROLE_KEY já existem).
// ============================================================

const SB_URL  = Deno.env.get("SUPABASE_URL")!;
const SB_ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SB_SRK  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const QN_URL_PADRAO = "https://arteconartes.questornegocio.com.br";
const PAGINA_MAX = 500;      // máximo da API
const PAGINAS_TETO = 10;     // trava de segurança por consulta
const JANELA_VENC_DIAS = 400;    // títulos: vencimento de hoje-400 até hoje+60
const JANELA_VENC_FUTURO = 60;
const JANELA_BAIXAS_DIAS = 7;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function resposta(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

// ── cofre do banco (lista fechada em segredo_servico; v2.22.0 inclui as chaves do Questor) ──
async function segredo(nome: string): Promise<string> {
  try {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/segredo_servico`, {
      method: "POST", signal: AbortSignal.timeout(10000),
      headers: { "Content-Type": "application/json", apikey: SB_SRK, Authorization: `Bearer ${SB_SRK}` },
      body: JSON.stringify({ p_nome: nome }),
    });
    const v = r.ok ? await r.json() : null;
    return typeof v === "string" ? v : "";
  } catch { return ""; }
}

// ── consultas ao banco ──
async function restUsuario(token: string, caminho: string): Promise<unknown[]> {
  const r = await fetch(`${SB_URL}/rest/v1/${caminho}`, { headers: { apikey: SB_ANON, Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new Error(`consulta (usuário) falhou: ${caminho.split("?")[0]} ${r.status}`);
  return await r.json();
}
async function restServico(caminho: string): Promise<unknown[]> {
  const r = await fetch(`${SB_URL}/rest/v1/${caminho}`, { headers: { apikey: SB_SRK, Authorization: `Bearer ${SB_SRK}` } });
  if (!r.ok) throw new Error(`consulta falhou: ${caminho.split("?")[0]} ${r.status}`);
  return await r.json();
}
async function registrarExecucao(tenantId: string, status: string, resumo: unknown, erro: string | null, email: string, iniciadoEm: string) {
  const r = await fetch(`${SB_URL}/rest/v1/cob_automacao_execucoes`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SB_SRK, Authorization: `Bearer ${SB_SRK}`, Prefer: "return=minimal" },
    body: JSON.stringify({ tenant_id: tenantId, etapa: "questor_api", status, origem: "questor_api",
      resumo, erro, usuario_email: email, iniciado_em: iniciadoEm, concluido_em: new Date().toISOString() }),
  });
  if (!r.ok) console.warn("execução não registrada:", r.status, await r.text().catch(() => ""));
}

// ── API do Questor Negócio ──
type QN = { base: string; token: string };
async function qnEntrar(): Promise<QN> {
  const chave = await segredo("questor_api_key");
  if (!chave) throw new Error("a chave 'questor_api_key' não está no cofre do Supabase (Dashboard → Integrations → Vault) — cadastre-a e tente de novo");
  const base = (await segredo("questor_api_url")) || QN_URL_PADRAO;
  const r = await fetch(`${base}/api/v1/Autenticacao/Autenticar`, {
    signal: AbortSignal.timeout(20000), headers: { "x-api-key": chave },
  });
  const j = await r.json().catch(() => null) as { Sucesso?: boolean; Dados?: string } | null;
  if (!r.ok || !j || j.Sucesso !== true || typeof j.Dados !== "string") {
    throw new Error(`autenticação na API do Questor falhou (HTTP ${r.status}) — confira a chave no cofre`);
  }
  return { base, token: j.Dados };
}
async function qnGet(qn: QN, caminho: string): Promise<Record<string, unknown>> {
  const r = await fetch(`${qn.base}${caminho}`, {
    signal: AbortSignal.timeout(30000),
    headers: { Authorization: `Bearer ${qn.token}` },
  });
  const j = await r.json().catch(() => null) as Record<string, unknown> | null;
  if (!r.ok || !j) throw new Error(`API do Questor: ${caminho.split("?")[0]} respondeu HTTP ${r.status}`);
  return j;
}
// percorre as páginas de uma consulta GET (PaginaAtual/TotalPaginas) e junta a lista indicada
async function qnPaginas(qn: QN, caminho: string, extrair: (d: Record<string, unknown>) => unknown[]): Promise<unknown[]> {
  const tudo: unknown[] = [];
  for (let pag = 1; pag <= PAGINAS_TETO; pag++) {
    const j = await qnGet(qn, `${caminho}&Pagina=${pag}&QuantidadePagina=${PAGINA_MAX}`);
    const dados = (j.Dados ?? {}) as Record<string, unknown>;
    const itens = extrair((dados && typeof dados === "object") ? dados : {}) || [];
    tudo.push(...itens);
    const total = Number(j.TotalPaginas) || 1;
    if (pag >= total || itens.length === 0) break;
  }
  return tudo;
}

const soData = (d: Date) => d.toISOString().slice(0, 10);
const chaveNum = (v: unknown) => String(v ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "").replace(/^0+(?=.)/, "");

// ── comparação de uma empresa (modo paralelo) ──
async function compararEmpresa(qn: QN, tenantId: string, emp: { id: string; apelido: string; questor_cnpj: string }) {
  const hoje = new Date();
  const vIni = soData(new Date(hoje.getTime() - JANELA_VENC_DIAS * 86400000));
  const vFim = soData(new Date(hoje.getTime() + JANELA_VENC_FUTURO * 86400000));
  const bIni = soData(new Date(hoje.getTime() - JANELA_BAIXAS_DIAS * 86400000));
  const cnpjQ = encodeURIComponent(String(emp.questor_cnpj).replace(/\D/g, "") || emp.questor_cnpj);

  // 1) títulos da API na janela de vencimento
  const titulos = await qnPaginas(qn,
    `/api/v1/ContaReceber/ConsultarContasReceber?EstabelecimentosInscricaoFederal=${cnpjQ}&DataVencimentoInicial=${vIni}&DataVencimentoFinal=${vFim}`,
    (d) => (d.ContaReceber as unknown[]) || []) as Record<string, unknown>[];

  // 2) baixas da API nos últimos dias
  const baixas = await qnPaginas(qn,
    `/api/v1/ContaReceber/ConsultarBaixaContasReceber?EstabelecimentosInscricaoFederal=${cnpjQ}&DataLancamentoInicial=${bIni}&DataLancamentoFinal=${soData(hoje)}`,
    (d) => (d.BaixaContasReceber as unknown[]) || []) as Record<string, unknown>[];

  // 3) parcelas do app desta empresa (sem as canceladas)
  const parcelas = await restServico(
    `cob_parcelas?select=nosso_numero,documento,status,valor_original,data_vencimento` +
    `&tenant_id=eq.${tenantId}&empresa_id=eq.${emp.id}&status=neq.cancelada&limit=20000`) as Record<string, unknown>[];
  const porChave = new Map<string, Record<string, unknown>>();
  for (const p of parcelas) {
    for (const k of [chaveNum(p.nosso_numero), chaveNum(p.documento)]) if (k && !porChave.has(k)) porChave.set(k, p);
  }
  const appAbertas = parcelas.filter((p) => p.status === "aberta").length;

  // 4) pagamentos do app no mesmo período das baixas
  const pags = await restServico(
    `cob_pagamentos?select=id&tenant_id=eq.${tenantId}&empresa_id=eq.${emp.id}` +
    `&data_recebimento=gte.${bIni}&estornado_em=is.null&limit=10000`) as unknown[];

  // 5) cruzamento
  let apiAbertos = 0, soApi = 0, liquidadaAppAberta = 0, divergenciaValor = 0, casados = 0;
  const exSoApi: string[] = [], exLiquidada: string[] = [];
  for (const t of titulos) {
    const restante = Number(t.ValorRestante) || 0;
    const situacao = Number(t.SituacaoBoleto);
    const rotulo = String(t.NossoNumeroRetorno || t.NossoNumeroGeracao || t.DocumentoFiscal || t.Id || "?");
    const chaves = [chaveNum(t.NossoNumeroRetorno), chaveNum(t.NossoNumeroGeracao),
      chaveNum(t.DocumentoFiscal), "U" + chaveNum(t.DocumentoFiscal)].filter(Boolean);
    const par = chaves.map((k) => porChave.get(k)).find(Boolean);
    if (restante > 0.004) apiAbertos++;
    if (par) {
      casados++;
      const aberta = par.status === "aberta";
      if (aberta && (restante <= 0.004 || situacao === 5 || situacao === 6)) {
        liquidadaAppAberta++; if (exLiquidada.length < 5) exLiquidada.push(rotulo);
      } else if (aberta && restante > 0.004 && Math.abs(restante - (Number(par.valor_original) || 0)) > 0.01) {
        divergenciaValor++;
      }
    } else if (restante > 0.004) {
      soApi++; if (exSoApi.length < 5) exSoApi.push(rotulo);
    }
  }

  return {
    empresa: emp.apelido, questor_cnpj: emp.questor_cnpj,
    janela: { vencimento: [vIni, vFim], baixas: [bIni, soData(hoje)] },
    api_titulos: titulos.length, api_abertos: apiAbertos, app_abertas: appAbertas, casados,
    so_api: soApi, api_liquidada_app_aberta: liquidadaAppAberta, divergencia_valor: divergenciaValor,
    baixas_api: baixas.length, pagamentos_app: (pags || []).length,
    exemplos: { so_api: exSoApi, liquidada_app_aberta: exLiquidada },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return resposta({ ok: false, erro: "método não permitido" }, 405);
  const iniciadoEm = new Date().toISOString();
  let tenantId = "", emailUsuario = "";
  try {
    // 1) usuário logado e com vínculo ativo no tenant (conferido sob o RLS do próprio usuário)
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!token) return resposta({ ok: false, erro: "sem token" }, 401);
    const u = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SB_ANON, Authorization: `Bearer ${token}` } });
    if (!u.ok) return resposta({ ok: false, erro: "usuário não autenticado" }, 401);
    const usuario = await u.json();
    emailUsuario = String(usuario?.email || "").trim().toLowerCase();

    const p = await req.json().catch(() => ({}));
    const acao = String(p.acao || "");
    tenantId = String(p.tenant_id || "");
    if (!/^[0-9a-f-]{36}$/.test(tenantId)) return resposta({ ok: false, erro: "tenant inválido" }, 400);
    const vinc = await restUsuario(token,
      `cob_usuarios_tenants?select=perfil&tenant_id=eq.${tenantId}&usuario_id=eq.${usuario.id}&ativo=eq.true&limit=1`);
    if (!Array.isArray(vinc) || !vinc.length) return resposta({ ok: false, erro: "sem acesso a este tenant" }, 403);

    // 2) entra na API (a chave sai do cofre; nunca é devolvida)
    const qn = await qnEntrar();

    if (acao === "testar") {
      const j = await qnGet(qn, `/api/v1/Estabelecimento?Pagina=1&QuantidadePagina=${PAGINA_MAX}`);
      const dados = j.Dados;
      const lista = (Array.isArray(dados) ? dados
        : Array.isArray((dados as Record<string, unknown>)?.Estabelecimentos) ? (dados as Record<string, unknown>).Estabelecimentos
        : []) as Record<string, unknown>[];
      const estabelecimentos = lista.map((e) => ({
        inscricao: String(e.InscricaoFederal ?? e.EstabelecimentoInscricaoFederal ?? e.Cnpj ?? ""),
        nome: String(e.RazaoSocial ?? e.NomeFantasia ?? e.Nome ?? ""),
      })).filter((e) => e.inscricao || e.nome);
      return resposta({ ok: true, url: qn.base, estabelecimentos });
    }

    if (acao === "capturar") {
      const empresas = await restServico(
        `cob_empresas?select=id,apelido,nome,questor_cnpj&tenant_id=eq.${tenantId}&ativo=is.true&questor_cnpj=not.is.null&order=nome`) as Record<string, unknown>[];
      if (!empresas.length) {
        const resumo = { aviso: "nenhuma empresa ativa com o CNPJ do estabelecimento do Questor vinculado — preencha em Sistema → Empresas" };
        await registrarExecucao(tenantId, "atencao", resumo, null, emailUsuario, iniciadoEm);
        return resposta({ ok: true, resumo });
      }
      const porEmpresa = [];
      for (const e of empresas) {
        porEmpresa.push(await compararEmpresa(qn, tenantId, {
          id: String(e.id), apelido: String(e.apelido || e.nome || "—"), questor_cnpj: String(e.questor_cnpj) }));
      }
      const atencao = porEmpresa.some((r) => r.so_api > 0 || r.api_liquidada_app_aberta > 0 || r.divergencia_valor > 0);
      const resumo = { modo: "paralelo (só leitura — nada foi gravado em parcelas)", por_empresa: porEmpresa };
      await registrarExecucao(tenantId, atencao ? "atencao" : "ok", resumo, null, emailUsuario, iniciadoEm);
      return resposta({ ok: true, resumo });
    }

    return resposta({ ok: false, erro: "ação desconhecida" }, 400);
  } catch (e) {
    const msg = String((e as Error)?.message || e);
    if (tenantId) await registrarExecucao(tenantId, "erro", null, msg, emailUsuario, iniciadoEm).catch(() => {});
    return resposta({ ok: false, erro: msg }, 500);
  }
});
