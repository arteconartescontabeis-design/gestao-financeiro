// Agenda Pro — envio dos avisos de WhatsApp
// Projeto Supabase do Agenda (vuwgxndahrzinfdlapxz).
//
// A cada chamada (pg_cron a cada 30 s, o gatilho de mensagem recebida no Cobrança, ou o app logo após salvar):
//   1. gera os lembretes que venceram (agenda_whats_gerar_lembretes);
//   2. reserva os avisos pendentes (agenda_whats_reservar), monta o texto e
//      coloca na fila do WhatsApp do Cobrança Pro (cob_agenda_enfileirar);
//   3. confere na fila do Cobrança o que já foi enviado (cob_agenda_status);
//   4. lê as mensagens que a equipe mandou para o número da Artecon
//      (cob_agenda_recebidas2), cria/lista/cancela agendamentos e responde;
//   5. informa ao núcleo do portal os segundos de áudio que a Azure transcreveu
//      (public.ia_fala_registrar → Portal → Consumo de IA → Transcrição de áudio).
// Pode ser chamada várias vezes: a reserva e o id único de cada mensagem
// recebida impedem envio ou agendamento em dobro.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { AJUDA, interpretar, type Cliente, type Hoje, type Servico } from "./comandos.ts";

const TZ = "America/Sao_Paulo";
const COB_URL = "https://yeujqjtjqtegsnzwwazb.supabase.co";
// chave pública (anon) do projeto do Cobrança; a fila só aceita com o token do cofre
const COB_ANON =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlldWpxanRqcXRlZ3Nuend3YXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1NDE0OTksImV4cCI6MjEwMTExNzQ5OX0.5p1_wJ_aApJpRrN6tFu8qmAytK5FMXWt1soCubpzqao";
const MAX_TENTATIVAS = 3;
const MARCA_AUDIO = "🎤 "; // o serviço artecon-whats (v1.5.0+) põe esta marca no texto de áudio transcrito
// núcleo do Portal Artecon: minutos de áudio da Azure (chave pública; só grava com o token do cofre, ia_fala_token)
const NUCLEO_URL = "https://fbxelwhdiisfmnwrerbl.supabase.co";
const NUCLEO_CHAVE = "sb_publishable_iRqjOGU1ialauv_wHYarbw_cRzspHH6";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

type Aviso = {
  id: number;
  tenant_id: number;
  agendamento_id: number | null;
  tipo: string;
  telefone: string;
  tentativas: number;
};

const fmtDia = new Intl.DateTimeFormat("pt-BR", { timeZone: TZ, weekday: "long", day: "2-digit", month: "2-digit" });
const fmtHora = new Intl.DateTimeFormat("pt-BR", { timeZone: TZ, hour: "2-digit", minute: "2-digit" });
const fmtISO = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" });

const diaSP = (d: Date) => fmtISO.format(d); // AAAA-MM-DD no fuso de São Paulo
const capital = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

function quando(d: Date) {
  const hoje = new Date();
  const amanha = new Date(hoje.getTime() + 86400000);
  const rel = diaSP(d) === diaSP(hoje) ? "hoje" : diaSP(d) === diaSP(amanha) ? "amanhã" : "";
  return { dia: capital(fmtDia.format(d)), hora: fmtHora.format(d), rel };
}

function fone(whatsapp?: string | null, telefone?: string | null): string | null {
  const limpa = (v?: string | null) => {
    let d = String(v || "").replace(/\D/g, "");
    if ((d.length === 12 || d.length === 13) && d.startsWith("55")) d = d.slice(2);
    return d;
  };
  const w = limpa(whatsapp), t = limpa(telefone);
  if (w.length === 10 || w.length === 11) return w;
  if (t.length === 11 && t[2] === "9") return t;
  return null;
}

type Dados = { nome: string; escritorio: string; servico: string; responsavel: string; inicio: Date };

function montarTexto(tipo: string, x: Dados): string {
  const q = quando(x.inicio);
  const det = [
    `📅 ${q.dia}`,
    `🕐 ${q.hora}`,
    x.servico ? `📋 ${x.servico}` : "",
    x.responsavel ? `👤 ${x.responsavel}` : "",
  ].filter(Boolean).join("\n");
  const ola = x.nome ? `Olá, ${x.nome}!` : "Olá!";
  switch (tipo) {
    case "confirmacao":
      return `${ola} ✅\nSeu atendimento com a *${x.escritorio}* está confirmado.\n\n${det}\n\nSe precisar remarcar ou cancelar, fale com a nossa equipe.`;
    case "lembrete_24h":
      return `${ola} 🔔\nLembrete: ${q.rel ? q.rel + " você tem" : "você tem"} atendimento com a *${x.escritorio}*.\n\n${det}\n\nSe não puder comparecer, avise a nossa equipe.`;
    case "lembrete_dia":
      return `${ola} 🔔\nHoje é dia do seu atendimento com a *${x.escritorio}*.\n\n${det}\n\nAté logo!`;
    case "reagendamento":
      return `${ola} 📅\nSeu atendimento com a *${x.escritorio}* foi *remarcado*. Nova data:\n\n${det}\n\nSe o novo horário não servir, fale com a nossa equipe.`;
    case "cancelamento":
      return `${ola}\nSeu atendimento com a *${x.escritorio}* de ${q.dia.toLowerCase()} às ${q.hora} foi *cancelado*.\n\nPara marcar uma nova data, fale com a nossa equipe.`;
    default:
      return "";
  }
}

async function cobRpc(fn: string, body: unknown) {
  const r = await fetch(`${COB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: COB_ANON, Authorization: `Bearer ${COB_ANON}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const txt = await r.text();
  let json: unknown = null;
  try { json = txt ? JSON.parse(txt) : null; } catch { /* texto puro */ }
  if (!r.ok) {
    const msg = (json && typeof json === "object" && "message" in json) ? String((json as { message: string }).message) : txt;
    throw new Error(msg || `HTTP ${r.status}`);
  }
  return json;
}

/** Informa ao portal quantos segundos de áudio a Azure transcreveu (o serviço manda em audio_seg). Nunca lança erro. */
let falaToken: string | null | undefined;
async function informarAudio(segundos: number, recebidaId: number, usuario: string) {
  try {
    if (falaToken === undefined) {
      const { data, error } = await db.rpc("agenda_ia_fala_token");
      falaToken = error ? null : (data as string | null);
    }
    if (!falaToken) return;
    const r = await fetch(`${NUCLEO_URL}/rest/v1/rpc/ia_fala_registrar`, {
      method: "POST", signal: AbortSignal.timeout(5000),
      headers: { apikey: NUCLEO_CHAVE, "Content-Type": "application/json" },
      body: JSON.stringify({ p_token: falaToken, p_segundos: segundos, p_ref: `whats:${recebidaId}`, p_usuario: usuario }),
    });
    if (!r.ok) console.error("ia_fala_registrar:", r.status, (await r.text()).slice(0, 200));
  } catch (e) { console.error("ia_fala_registrar:", (e as Error).message); }
}

const cfgCache = new Map<number, Record<string, string>>();
async function config(tenant: number) {
  if (!cfgCache.has(tenant)) {
    const [{ data: cfg }, { data: ten }] = await Promise.all([
      db.from("agenda_config").select("chave, valor").eq("tenant_id", tenant),
      db.from("agenda_tenants").select("nome").eq("id", tenant).maybeSingle(),
    ]);
    const m: Record<string, string> = {};
    (cfg || []).forEach((c: { chave: string; valor: string }) => (m[c.chave] = c.valor));
    m.__escritorio = m.nome_escritorio || ten?.nome || "nosso escritório";
    cfgCache.set(tenant, m);
  }
  return cfgCache.get(tenant)!;
}

async function marcar(id: number, patch: Record<string, unknown>) {
  await db.from("agenda_whats_avisos").update({ ...patch, atualizado_em: new Date().toISOString() }).eq("id", id);
}

// Prepara um aviso: devolve texto, telefone e validade, ou o motivo para não enviar.
async function preparar(a: Aviso): Promise<{ texto: string; tel: string; valido?: string } | { motivo: string }> {
  const cfg = await config(a.tenant_id);
  if (a.tipo === "teste") {
    return {
      tel: a.telefone,
      texto: `✅ Teste do Agenda Pro — *${cfg.__escritorio}*.\nSe você recebeu esta mensagem, os avisos por WhatsApp da agenda estão funcionando.`,
    };
  }
  if ((cfg["whats_" + a.tipo] || "false") !== "true") return { motivo: "aviso desligado nas Configurações" };
  const { data: ag } = await db.from("agenda_agendamentos")
    .select("id, status, data_inicio, cliente_id, servico_id, usuario_responsavel_id")
    .eq("id", a.agendamento_id!).maybeSingle();
  if (!ag) return { motivo: "agendamento não existe mais" };
  const inicio = new Date(ag.data_inicio);
  if (inicio.getTime() <= Date.now()) return { motivo: "o horário do agendamento já passou" };
  const cancelado = ["cancelado_cliente", "cancelado_escritorio"].includes(ag.status);
  if (a.tipo === "cancelamento" ? !cancelado : ag.status !== "confirmado") {
    return { motivo: "a situação do agendamento mudou" };
  }
  const [{ data: cli }, { data: sv }, { data: us }] = await Promise.all([
    db.from("agenda_clientes").select("nome, whatsapp, telefone, whatsapp_avisos").eq("id", ag.cliente_id).maybeSingle(),
    ag.servico_id ? db.from("agenda_servicos").select("nome").eq("id", ag.servico_id).maybeSingle() : Promise.resolve({ data: null }),
    ag.usuario_responsavel_id ? db.from("agenda_usuarios").select("nome").eq("id", ag.usuario_responsavel_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  if (!cli) return { motivo: "cliente não encontrado" };
  if (cli.whatsapp_avisos === false) return { motivo: "cliente não quer avisos por WhatsApp" };
  const tel = fone(cli.whatsapp, cli.telefone);
  if (!tel) return { motivo: "cliente sem WhatsApp cadastrado" };
  const servico = sv?.nome && !/sem servi/i.test(sv.nome) ? sv.nome : "";
  const texto = montarTexto(a.tipo, {
    nome: String(cli.nome || "").trim(),
    escritorio: cfg.__escritorio,
    servico,
    responsavel: String(us?.nome || "").trim(),
    inicio,
  });
  // aviso que não saiu até o horário do atendimento perde o sentido
  return { texto, tel, valido: a.tipo === "cancelamento" ? undefined : inicio.toISOString() };
}

async function enviarPendentes(token: string) {
  const { data: lote, error } = await db.rpc("agenda_whats_reservar", { p_limite: 20 });
  if (error) throw new Error("reservar: " + error.message);
  let naFila = 0, falhas = 0, descartados = 0;
  for (const a of (lote || []) as Aviso[]) {
    try {
      const p = await preparar(a);
      if ("motivo" in p) { await marcar(a.id, { status: "cancelado", erro: p.motivo }); descartados++; continue; }
      const filaId = await cobRpc("cob_agenda_enfileirar", {
        p_token: token,
        p_telefone: p.tel,
        p_mensagem: p.texto,
        p_valido_ate: p.valido ?? null,
        p_contexto: { tipo: a.tipo, agendamento_id: a.agendamento_id, aviso_id: a.id },
      });
      await marcar(a.id, { status: "na_fila", fila_id: filaId, mensagem: p.texto, telefone: p.tel, erro: null });
      naFila++;
    } catch (e) {
      const msg = String((e as Error).message || e).slice(0, 300);
      const fim = a.tentativas >= MAX_TENTATIVAS || /token|telefone inválido|limite/i.test(msg);
      await marcar(a.id, { status: fim ? "falha" : "pendente", erro: msg });
      falhas++;
    }
  }
  return { reservados: (lote || []).length, naFila, falhas, descartados };
}

async function conferirFila(token: string) {
  const { data: abertos } = await db.from("agenda_whats_avisos")
    .select("id, fila_id").eq("status", "na_fila").not("fila_id", "is", null).order("id").limit(200);
  if (!abertos || !abertos.length) return 0;
  const linhas = await cobRpc("cob_agenda_status", { p_token: token, p_ids: abertos.map((x) => x.fila_id) }) as
    { id: number; status: string; erro: string | null; enviado_em: string | null }[];
  const porFila = new Map((linhas || []).map((l) => [Number(l.id), l]));
  let n = 0;
  for (const a of abertos) {
    const f = porFila.get(Number(a.fila_id));
    if (!f || f.status === "pendente" || f.status === "enviando") continue;
    if (f.status === "enviado") await marcar(a.id, { status: "enviado", enviado_em: f.enviado_em || new Date().toISOString(), erro: null });
    else if (f.status === "expirado") await marcar(a.id, { status: "falha", erro: "não foi enviado a tempo (serviço de WhatsApp parado?)" });
    else if (f.status === "cancelado") await marcar(a.id, { status: "falha", erro: f.erro || "cancelada na fila do Cobrança" });
    else await marcar(a.id, { status: "falha", erro: f.erro || f.status });
    n++;
  }
  return n;
}


// ── Comandos da equipe recebidos por WhatsApp ──────────────────────────
type Membro = { id: number; tenant_id: number; nome: string; perfil: string; fone: string };
const chaveFone = (f: string) => f.slice(0, 2) + f.slice(-8); // DDD + 8 últimos (WhatsApp às vezes omite o 9)
const ATIVOS = ["solicitado", "pendente_confirmacao", "confirmado"];

function agoraSP(): Hoje {
  const partes = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric",
    weekday: "short", hour12: false,
  }).formatToParts(new Date()).map((x) => [x.type, x.value]));
  const dows: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return { ano: +partes.year, mes: +partes.month, dia: +partes.day, hora: +partes.hour % 24, minuto: +partes.minute, dow: dows[partes.weekday] };
}
const diaLongo = (dataISO: string) => capital(fmtDia.format(new Date(`${dataISO}T12:00:00-03:00`)));

async function servicoGenerico(tenant: number): Promise<number> {
  const { data } = await db.from("agenda_servicos").select("id").eq("tenant_id", tenant).eq("nome", "— Sem serviço —").limit(1);
  if (data && data[0]) return data[0].id;
  const { data: novo, error } = await db.from("agenda_servicos").insert({
    tenant_id: tenant, nome: "— Sem serviço —", duracao_min: 60, cor: "#C8C5BC", antecedencia_min: 0, max_reagendamentos: 99, ativo: false,
  }).select("id").single();
  if (error) throw new Error("serviço genérico: " + error.message);
  return novo.id;
}

type Resultado = { status: "feito" | "pergunta" | "erro" | "ignorado"; acao: string; resposta: string | null; agendamento_id?: number | null };

async function executar(u: Membro, texto: string, comandoId: number): Promise<Resultado> {
  const [{ data: cli }, { data: svs }] = await Promise.all([
    db.from("agenda_clientes").select("id, nome").eq("tenant_id", u.tenant_id).eq("ativo", true),
    db.from("agenda_servicos").select("id, nome, duracao_min").eq("tenant_id", u.tenant_id).eq("ativo", true),
  ]);
  const clientes = ((cli || []) as Cliente[]).filter((c) => c.nome !== "— Sem cliente —");
  const cmd = interpretar(texto, agoraSP(), clientes, (svs || []) as Servico[]);

  if (cmd.acao === "desconhecido") return { status: "ignorado", acao: "desconhecido", resposta: null };
  if (cmd.acao === "ajuda") return { status: "feito", acao: "ajuda", resposta: AJUDA };

  if (cmd.acao === "listar") {
    const ini = new Date(`${cmd.data}T00:00:00-03:00`), fim = new Date(ini.getTime() + 86400000);
    let q = db.from("agenda_agendamentos")
      .select("data_inicio, usuario_responsavel_id, agenda_clientes(nome), agenda_servicos(nome)")
      .eq("tenant_id", u.tenant_id).in("status", ATIVOS)
      .gte("data_inicio", ini.toISOString()).lt("data_inicio", fim.toISOString()).order("data_inicio");
    const gestor = ["admin", "gerente"].includes(u.perfil);
    if (!gestor) q = q.eq("usuario_responsavel_id", u.id);
    const [{ data: ags }, { data: equipe }] = await Promise.all([
      q, db.from("agenda_usuarios").select("id, nome").eq("tenant_id", u.tenant_id),
    ]);
    const nomeEq = new Map((equipe || []).map((x: { id: number; nome: string }) => [x.id, String(x.nome).split(" ")[0]]));
    const linhas = (ags || []).map((a: any) => {
      const sv = a.agenda_servicos?.nome && !/sem servi/i.test(a.agenda_servicos.nome) ? ` — ${a.agenda_servicos.nome}` : "";
      const resp = gestor && a.usuario_responsavel_id !== u.id ? ` (${nomeEq.get(a.usuario_responsavel_id) || "—"})` : "";
      return `${fmtHora.format(new Date(a.data_inicio))} · ${a.agenda_clientes?.nome || "—"}${sv}${resp}`;
    });
    const titulo = `📅 *${gestor ? "Agenda do escritório" : "Sua agenda"} — ${diaLongo(cmd.data)}*`;
    return { status: "feito", acao: "listar", resposta: linhas.length ? `${titulo}\n\n${linhas.join("\n")}` : `${titulo}\n\nNenhum agendamento.` };
  }

  if (cmd.acao === "cancelar") {
    const desde = new Date(Date.now() - 2 * 3600000).toISOString();
    const { data: ult } = await db.from("agenda_whats_comandos").select("agendamento_id")
      .eq("usuario_id", u.id).eq("acao", "agendar").eq("status", "feito").not("agendamento_id", "is", null)
      .gte("criado_em", desde).neq("id", comandoId).order("id", { ascending: false }).limit(1);
    const agId = ult && ult[0] ? ult[0].agendamento_id : null;
    if (!agId) return { status: "pergunta", acao: "cancelar", resposta: "Não achei nenhum agendamento seu feito pelo WhatsApp nas últimas 2 horas para desfazer. Para cancelar outro, use o app." };
    const { data: ag } = await db.from("agenda_agendamentos").select("id, status, data_inicio, agenda_clientes(nome)").eq("id", agId).maybeSingle();
    if (!ag || !ATIVOS.includes(ag.status)) return { status: "pergunta", acao: "cancelar", resposta: "Esse agendamento já tinha sido cancelado ou concluído." };
    const { error } = await db.from("agenda_agendamentos").update({
      status: "cancelado_escritorio", cancelado_em: new Date().toISOString(), motivo_cancelamento: "Desfeito pelo WhatsApp", atualizado_por: u.id,
    }).eq("id", agId);
    if (error) throw new Error("cancelar: " + error.message);
    const d = new Date(ag.data_inicio);
    return { status: "feito", acao: "cancelar", agendamento_id: agId,
      resposta: `❌ Cancelado: ${(ag as any).agenda_clientes?.nome || "—"} — ${capital(fmtDia.format(d))} às ${fmtHora.format(d)}.` };
  }

  // agendar
  if (cmd.ambiguos.length) {
    return { status: "pergunta", acao: "agendar",
      resposta: `Encontrei mais de um cliente com esse nome:\n${cmd.ambiguos.map((c) => "• " + c.nome).join("\n")}\n\nMande de novo com o nome completo.` };
  }
  if (!cmd.cliente && !cmd.clienteNovo) return { status: "pergunta", acao: "agendar", resposta: "Faltou o nome do cliente.\nExemplo: agendar Maria Souza amanhã 10h" };
  if (!cmd.data || !cmd.hora) {
    const falta = !cmd.data && !cmd.hora ? "a data e a hora" : !cmd.data ? "a data" : "a hora";
    return { status: "pergunta", acao: "agendar", resposta: `Faltou ${falta}.\nExemplo: agendar ${cmd.cliente?.nome || cmd.clienteNovo} amanhã 10h` };
  }
  const inicio = new Date(`${cmd.data}T${cmd.hora}:00-03:00`);
  if (isNaN(inicio.getTime())) return { status: "pergunta", acao: "agendar", resposta: "Não entendi a data. Use, por exemplo, 20/10 ou amanhã." };
  if (inicio.getTime() <= Date.now()) return { status: "pergunta", acao: "agendar", resposta: `Esse horário (${diaLongo(cmd.data)} às ${cmd.hora}) já passou. Mande outro.` };
  const dur = cmd.duracao ?? cmd.servico?.duracao_min ?? 60;
  const fim = new Date(inicio.getTime() + dur * 60000);

  const { data: conflito } = await db.rpc("agenda_verificar_conflito", {
    p_tenant_id: u.tenant_id, p_responsavel_id: u.id, p_inicio: inicio.toISOString(), p_fim: fim.toISOString(),
  });
  if (conflito) {
    const { data: choque } = await db.from("agenda_agendamentos").select("data_inicio, agenda_clientes(nome)")
      .eq("tenant_id", u.tenant_id).eq("usuario_responsavel_id", u.id).not("status", "in", "(cancelado_cliente,cancelado_escritorio,reagendado)")
      .lt("data_inicio", fim.toISOString()).gt("data_fim", inicio.toISOString()).limit(1);
    const c = choque && choque[0];
    const qual = c ? `${(c as any).agenda_clientes?.nome || "outro atendimento"} às ${fmtHora.format(new Date(c.data_inicio))}` : "outro atendimento";
    return { status: "pergunta", acao: "agendar", resposta: `⚠️ Você já tem ${qual} nesse horário. Mande outro horário.` };
  }

  let clienteId = cmd.cliente?.id ?? null, novo = false;
  if (!clienteId) {
    const { data: c, error } = await db.from("agenda_clientes").insert({
      tenant_id: u.tenant_id, nome: cmd.clienteNovo, ativo: true, noshow_count: 0, score: 100,
      obs_interna: `⚡ Cadastrado pelo WhatsApp por ${u.nome}`,
    }).select("id").single();
    if (error) throw new Error("cliente: " + error.message);
    clienteId = c.id; novo = true;
  }
  const servicoId = cmd.servico?.id ?? await servicoGenerico(u.tenant_id);
  const { data: ag, error } = await db.from("agenda_agendamentos").insert({
    tenant_id: u.tenant_id, cliente_id: clienteId, servico_id: servicoId, usuario_responsavel_id: u.id,
    data_inicio: inicio.toISOString(), data_fim: fim.toISOString(), status: "confirmado", origem_agendamento: "whatsapp",
    confirmado_em: new Date().toISOString(), criado_por: u.id, observacao_interna: cmd.obs,
  }).select("id").single();
  if (error) throw new Error("agendamento: " + error.message);

  const nome = cmd.cliente?.nome || cmd.clienteNovo;
  const resposta = [
    "✅ *Agendado!*",
    `👤 ${nome}${novo ? " _(cliente novo, cadastrado agora)_" : ""}`,
    `📅 ${diaLongo(cmd.data)}`,
    `🕐 ${cmd.hora} (${dur} min)`,
    cmd.servico ? `📋 ${cmd.servico.nome}` : "",
    cmd.obs ? `📝 ${cmd.obs}` : "",
    "",
    "Para desfazer, responda *cancelar*.",
  ].filter((l, i, arr) => l !== "" || (i > 0 && arr[i - 1] !== "")).join("\n");
  return { status: "feito", acao: "agendar", agendamento_id: ag.id, resposta };
}

async function processarComandos(token: string) {
  const { data: libs } = await db.from("agenda_whats_tenants").select("tenant_id").eq("ativo", true);
  const tenants = (libs || []).map((l: { tenant_id: number }) => l.tenant_id);
  if (!tenants.length) return 0;
  const { data: eq } = await db.from("agenda_usuarios").select("id, tenant_id, nome, perfil, whatsapp")
    .in("tenant_id", tenants).eq("ativo", true).not("whatsapp", "is", null);
  const equipe: Membro[] = (eq || []).map((x: any) => ({ ...x, fone: fone(x.whatsapp, null) })).filter((x: Membro) => x.fone);
  // o serviço do WhatsApp só transcreve áudio de quem está nesta lista (só grava se mudou)
  try { await cobRpc("cob_agenda_equipe_set", { p_token: token, p_telefones: equipe.map((m) => m.fone) }); }
  catch (e) { console.error("equipe_set:", (e as Error).message); }
  if (!equipe.length) return 0;
  const porChave = new Map(equipe.map((m) => [chaveFone(m.fone), m]));

  const { data: ult } = await db.from("agenda_whats_comandos").select("recebida_id").order("recebida_id", { ascending: false }).limit(1);
  const cursor = ult && ult[0] ? ult[0].recebida_id : 0;
  // cob_agenda_recebidas2 traz também audio_seg (segundos de áudio que o serviço mandou para a Azure)
  const pedido = { p_token: token, p_apos_id: cursor, p_telefones: equipe.map((m) => m.fone) };
  let msgs: { id: number; telefone: string; texto: string; recebido_em: string; audio_seg?: number | null }[];
  try { msgs = await cobRpc("cob_agenda_recebidas2", pedido) as typeof msgs; }
  catch (e) { console.error("recebidas2:", (e as Error).message); msgs = await cobRpc("cob_agenda_recebidas", pedido) as typeof msgs; }
  let n = 0;
  for (const m of msgs || []) {
    const tel = fone(m.telefone, null);
    const u = tel ? porChave.get(chaveFone(tel)) : undefined;
    if (!u) continue;
    // registra antes de agir: se outra execução já pegou esta mensagem, o id único barra
    const { data: reg } = await db.from("agenda_whats_comandos").upsert({
      tenant_id: u.tenant_id, usuario_id: u.id, recebida_id: m.id, telefone: u.fone, texto: String(m.texto || "").slice(0, 1000),
    }, { onConflict: "recebida_id", ignoreDuplicates: true }).select("id");
    if (!reg || !reg.length) continue;
    const comandoId = reg[0].id;
    // a Azure cobra o áudio processado, mesmo o antigo ou o que não deu para entender
    if (Number(m.audio_seg) > 0) await informarAudio(Number(m.audio_seg), m.id, u.nome);
    if (Date.now() - new Date(m.recebido_em).getTime() > 30 * 60000) {
      await db.from("agenda_whats_comandos").update({ status: "ignorado", acao: "antiga", atualizado_em: new Date().toISOString() }).eq("id", comandoId);
      continue;
    }
    // áudio já transcrito pelo serviço do WhatsApp chega com a marca 🎤 na frente
    const bruto = String(m.texto || "");
    const audio = bruto.startsWith(MARCA_AUDIO);
    const texto = audio ? bruto.slice(MARCA_AUDIO.length).trim() : bruto;
    let r: Resultado;
    try { r = await executar(u, texto, comandoId); }
    catch (e) { r = { status: "erro", acao: "erro", resposta: "Não consegui fazer isso agora. Tente pelo app ou mande de novo em instantes." }; console.error("comando", m.id, e); }
    if (audio) {
      // no áudio, sempre diz o que ouviu (texto digitado que não é comando continua sem resposta)
      const ouvi = `🎤 _Ouvi:_ "${texto.slice(0, 300)}"`;
      r = { ...r, resposta: r.resposta ? `${ouvi}\n\n${r.resposta}` : `${ouvi}\n\nNão entendi o pedido. Mande *ajuda* para ver os comandos.` };
    }
    let filaId: unknown = null;
    if (r.resposta) {
      try {
        filaId = await cobRpc("cob_agenda_enfileirar", {
          p_token: token, p_telefone: u.fone, p_mensagem: r.resposta, p_valido_ate: null,
          p_contexto: { tipo: "resposta_comando", comando_id: comandoId },
        });
      } catch (e) { console.error("resposta", m.id, (e as Error).message); }
    }
    await db.from("agenda_whats_comandos").update({
      status: r.status, acao: r.acao, resposta: r.resposta, agendamento_id: r.agendamento_id ?? null,
      fila_id: filaId, atualizado_em: new Date().toISOString(),
    }).eq("id", comandoId);
    n++;
  }
  return n;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const resp = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const { data: token, error: eTok } = await db.rpc("agenda_whats_token");
    if (eTok || !token) return resp({ ok: false, erro: "token da fila não configurado" }, 500);
    const { data: gerados, error: eGer } = await db.rpc("agenda_whats_gerar_lembretes");
    if (eGer) console.error("gerar_lembretes:", eGer.message);
    const envio = await enviarPendentes(token as string);
    let conferidos = 0, comandos = 0;
    try { comandos = await processarComandos(token as string); } catch (e) { console.error("comandos:", (e as Error).message); }
    try { conferidos = await conferirFila(token as string); } catch (e) { console.error("conferir:", (e as Error).message); }
    return resp({ ok: true, lembretes: gerados ?? 0, ...envio, comandos, conferidos });
  } catch (e) {
    console.error(e);
    return resp({ ok: false, erro: String((e as Error).message || e) }, 500);
  }
});
