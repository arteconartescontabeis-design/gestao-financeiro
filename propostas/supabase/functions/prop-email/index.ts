// =====================================================================
// Artecon Propostas — Edge Function  prop-email   (v1.6.4 — chave da central no cofre do banco)
// Projeto Supabase: cobranca-pro (yeujqjtjqtegsnzwwazb)
//
// O que faz: esvazia a fila public.prop_fila_email e envia cada mensagem pelo hub Artecon Mail (mail-send), no padrão visual Artecon.
//   via_assinada       -> signatário: link só de leitura da via assinada por todos (o link é gerado AQUI, no servidor)
//   recibo_assinatura  -> signatário: confirmação de que a assinatura dele foi recebida, com o código de verificação
//   aviso_abertura     -> escritório: o cliente abriu o link (notificação de recebimento)
//   aviso_assinatura   -> escritório: alguém assinou
//   aviso_conclusao    -> escritório: todos assinaram; vias enviadas
// Quem chama: o banco (pg_net, a cada mensagem nova na fila) e o pg_cron (a cada 5 min, para novas tentativas).
//
// SECRETS (Edge Functions > prop-email > Secrets):
//   (v1.6.4: a chave da central não é mais secret: fica no cofre do banco, mail_hub_key_propostas)
//   PROP_EMAIL_SECRET   segredo longo, o MESMO gravado em prop_priv.config pelo 10_config_fila.sql
//   (SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem em toda Edge Function; não precisa criar)
// Opcionais: MAIL_HUB_URL, PROP_APP_URL, PROP_LOGO_URL
// v1.6.3 (18/10/2026): app e logo no endereço novo (repositório gestao-financeiro). Os links já enviados com o
//   endereço antigo continuam valendo: /propostas/ virou aviso que leva ao novo com o mesmo #/c/<token>.
// v1.6.4 (20/10/2026): chave própria da central de e-mail no cofre do banco (a antiga, MAIL_API_KEY, ficou no histórico
//   público e só vale na transição). {"verificar_hub": true} (com x-prop-secret) confere a chave sem enviar nada.
//
// Teste manual (Invoke/Test da função):  {"teste": true, "para": "cleiver@artecon.cnt.br"}  com o cabeçalho x-prop-secret.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const HUB  = Deno.env.get("MAIL_HUB_URL")  ?? "https://tjnqloycikukvvnconqn.supabase.co/functions/v1/mail-send";
const APP  = Deno.env.get("PROP_APP_URL")  ?? "https://arteconartescontabeis-design.github.io/gestao-financeiro/propostas/";
const LOGO = Deno.env.get("PROP_LOGO_URL") ?? "https://arteconartescontabeis-design.github.io/gestao-financeiro/propostas/logo_artecon.png";

const esc = (v: unknown) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
const numero = (f: any) => String(f.numero).padStart(3, "0") + "/" + f.ano;
const dataHora = (iso: string) => {
  const p = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: false })
    .formatToParts(new Date(iso)).reduce((a: any, x) => (a[x.type] = x.value, a), {});
  return `${p.day}/${p.month}/${p.year} às ${p.hour}:${p.minute}`;
};
const primeiro = (n: string) => String(n || "").trim().split(/\s+/)[0] || "";

// ---------- PADRÃO ARTECON DE E-MAIL (o mesmo desenho está no index.html, função emailArtecon) ----------
type Msg = { titulo: string; saudacao?: string; paragrafos: string[]; chaves?: [string, string, boolean?][]; botao?: { txt: string; url: string }; aviso?: string; escritorio: any };
function emailArtecon(m: Msg): string {
  const e = m.escritorio || {};
  const chaves = (m.chaves || []).filter((k) => k[1]).map((k) =>
    `<tr><td style="padding:5px 12px 5px 0;color:#6f6b6c;font-size:13px;white-space:nowrap;vertical-align:top">${esc(k[0])}</td><td style="padding:5px 0;font-size:14px;${k[2] ? "font-weight:bold;color:#BC151B" : "font-weight:bold;color:#2f2d2e"}">${esc(k[1])}</td></tr>`).join("");
  return `<div style="background:#f3f5f6;padding:24px 12px;font-family:Arial,Helvetica,sans-serif;color:#2f2d2e">
<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="max-width:600px;margin:0 auto;background:#ffffff;border:1px solid #dfe7eb;border-collapse:collapse">
<tr><td style="padding:22px 30px 14px;text-align:center"><img src="${esc(LOGO)}" alt="${esc(e.nome || "Artecon Artes Contábeis")}" width="170" style="display:inline-block;border:0;max-width:170px;height:auto"></td></tr>
<tr><td style="background:#BC151B;color:#ffffff;text-align:center;padding:14px 24px;font-size:18px;font-weight:bold">${esc(m.titulo)}</td></tr>
<tr><td style="height:4px;background:#FFF200;font-size:0;line-height:0">&nbsp;</td></tr>
<tr><td style="padding:26px 30px 10px;font-size:14px;line-height:1.6">
${m.saudacao ? `<p style="margin:0 0 12px">${esc(m.saudacao)}</p>` : ""}${m.paragrafos.map((p) => `<p style="margin:0 0 12px">${p}</p>`).join("")}
${chaves ? `<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="margin:16px 0;background:#f0fafe;border-left:4px solid #00AEEF"><tr><td style="padding:10px 16px"><table role="presentation" cellpadding="0" cellspacing="0">${chaves}</table></td></tr></table>` : ""}
${m.botao ? `<table role="presentation" cellpadding="0" cellspacing="0" align="center" style="margin:24px auto 18px"><tr><td align="center" bgcolor="#BC151B" style="background:#BC151B;padding:13px 30px"><a href="${esc(m.botao.url)}" style="color:#ffffff;text-decoration:none;font-weight:bold;font-size:15px;font-family:Arial,Helvetica,sans-serif;display:block">${esc(m.botao.txt)}</a></td></tr></table>
<p style="font-size:12px;color:#6f6b6c;margin:0 0 12px">Se o botão não abrir, copie este endereço no navegador:<br><span style="word-break:break-all">${esc(m.botao.url)}</span></p>` : ""}
${m.aviso ? `<p style="font-size:12px;color:#6f6b6c;margin:0 0 12px">${esc(m.aviso)}</p>` : ""}
</td></tr>
<tr><td style="padding:16px 30px 20px;border-top:1px solid #dfe7eb;font-size:12px;line-height:1.5;color:#6f6b6c;text-align:center"><b style="color:#4F4C4D">${esc(e.nome || "Artecon Artes Contábeis")}</b><br>${esc([e.telefone, e.site].filter(Boolean).join(" · "))}${e.endereco ? "<br>" + esc(e.endereco) : ""}</td></tr>
</table>
<p style="max-width:600px;margin:12px auto 0;font-size:11px;color:#999999;text-align:center">Mensagem automática do sistema de propostas da ${esc(e.nome || "Artecon")}.</p></div>`;
}

function montar(f: any, urlVia?: string): { assunto: string; html: string } {
  const n = numero(f), d = f.dados || {}, esc_ = f.escritorio, app = (esc_.app_url || APP), interno = app.split("#")[0] + "#/proposta/" + f.proposta_id;
  const base: [string, string, boolean?][] = [["Proposta", "nº " + n], ["Cliente", f.cliente_nome]];
  switch (f.tipo) {
    case "via_assinada": return { assunto: `Proposta de Honorários nº ${n} — via assinada`, html: emailArtecon({ escritorio: esc_, titulo: "Proposta assinada por todos", saudacao: `Olá, ${primeiro(d.nome || f.signatario)}!`,
      paragrafos: [`A <b>Proposta de Honorários nº ${esc(n)}</b> foi assinada por todas as partes. No endereço abaixo você abre a via completa, com o comprovante das assinaturas, e pode salvar em PDF ou imprimir.`],
      chaves: base, botao: { txt: "Abrir a via assinada", url: urlVia! }, aviso: "Este endereço é pessoal, só permite leitura e fica disponível por 30 dias. Não o encaminhe a terceiros." }) };
    case "recibo_assinatura": return { assunto: `Proposta de Honorários nº ${n} — recebemos a sua assinatura`, html: emailArtecon({ escritorio: esc_, titulo: "Recebemos a sua assinatura", saudacao: `Olá, ${primeiro(d.nome)}!`,
      paragrafos: ["Confirmamos o recebimento da sua assinatura eletrônica. Guarde o código de verificação abaixo.", "Assim que as demais partes assinarem, você receberá outro e-mail com o endereço da via completa para impressão."],
      chaves: [...base, ["Assinado em", dataHora(d.assinado_em)], ["Código de verificação", d.codigo, true]], aviso: "Se você não reconhece esta assinatura, avise o escritório imediatamente." }) };
    case "aviso_abertura": return { assunto: `Proposta ${n} — ${f.cliente_nome}: o cliente abriu o link`, html: emailArtecon({ escritorio: esc_, titulo: "O cliente abriu a proposta",
      paragrafos: [`<b>${esc(d.nome || "O cliente")}</b> abriu o link de assinatura pela primeira vez. Isso confirma que a mensagem chegou.`],
      chaves: [...base, ["Aberto em", dataHora(d.aberto_em), true], ["Link enviado por", d.canal === "whatsapp" ? "WhatsApp" : d.canal === "email" ? "e-mail" : ""], ["Para", d.para || ""]], botao: { txt: "Abrir no sistema", url: interno } }) };
    case "aviso_assinatura": return { assunto: `Proposta ${n} — ${f.cliente_nome}: ${d.nome} assinou`, html: emailArtecon({ escritorio: esc_, titulo: "Nova assinatura na proposta",
      paragrafos: [`<b>${esc(d.nome)}</b> assinou a proposta${d.foto ? ", com foto do documento" : ""}.`, "Se ainda faltar a assinatura do escritório, ela aparece como pendência no painel."],
      chaves: [...base, ["Assinado em", dataHora(d.assinado_em), true], ["Código de verificação", d.codigo]], botao: { txt: "Abrir no sistema", url: interno } }) };
    default: { const sem: string[] = d.sem_email || [];
      return { assunto: `Proposta ${n} — ${f.cliente_nome}: assinada por todos`, html: emailArtecon({ escritorio: esc_, titulo: "Proposta assinada por todos",
      paragrafos: ["Todas as assinaturas foram concluídas e a proposta está <b>Aprovada</b> e travada. A via assinada foi enviada automaticamente por e-mail aos signatários.",
        ...(sem.length ? [`<b>Atenção:</b> ${esc(sem.join(", "))} não ${sem.length > 1 ? "têm" : "tem"} e-mail cadastrado. Envie a via pelo WhatsApp, na tela da proposta.`] : [])],
      chaves: [...base, ["Concluída em", dataHora(d.assinada_em), true]], botao: { txt: "Abrir no sistema", url: interno } }) }; }
  }
}

// v1.6.4: chave própria da central de e-mail, guardada no cofre do banco (mail_hub_key_propostas; só a chave de serviço lê).
//   O secret MAIL_API_KEY (a chave antiga, vazada) fica só de reserva até a central parar de aceitá-la.
let _chaveHub = "";
async function chaveHub(): Promise<string> {
  if (_chaveHub) return _chaveHub;
  const url = Deno.env.get("SUPABASE_URL") ?? "", srk = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  try {
    const r = await fetch(`${url}/rest/v1/rpc/segredo_servico`, {
      method: "POST", signal: AbortSignal.timeout(10000),
      headers: { "Content-Type": "application/json", apikey: srk, Authorization: `Bearer ${srk}` },
      body: JSON.stringify({ p_nome: "mail_hub_key_propostas" }),
    });
    const v = r.ok ? await r.json() : null;
    if (typeof v === "string" && v) return (_chaveHub = v);
    console.warn(`chave da central: cofre respondeu ${r.status}`);
  } catch (e) { console.warn("chave da central: cofre indisponível", String(e)); }
  return Deno.env.get("MAIL_API_KEY") ?? "";
}

async function enviar(to: string, assunto: string, html: string) {
  const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), 25000);
  try {
    const r = await fetch(HUB, { method: "POST", signal: ctl.signal, headers: { "Content-Type": "application/json", "x-api-key": await chaveHub() }, body: JSON.stringify({ to, assunto, html, app: "propostas" }) });
    if (!r.ok) throw new Error(`hub ${r.status}: ${(await r.text()).slice(0, 160)}`);
  } finally { clearTimeout(t); }
}

Deno.serve(async (req) => {
  const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json" } });
  const segredo = Deno.env.get("PROP_EMAIL_SECRET") ?? "";
  if (!segredo || req.headers.get("x-prop-secret") !== segredo) return J({ ok: false, erro: "nao autorizado" }, 401);
  if (!(await chaveHub())) return J({ ok: false, erro: "chave da central de e-mail ausente (cofre mail_hub_key_propostas)" }, 500);
  let corpo: any = {}; try { corpo = await req.json(); } catch (_) { /* sem corpo */ }

  if (corpo.verificar_hub === true) {   // v1.6.4: confere a chave na central, sem enviar nada
    try {
      const r = await fetch(HUB, { method: "POST", signal: AbortSignal.timeout(15000), headers: { "Content-Type": "application/json", "x-api-key": await chaveHub() }, body: JSON.stringify({ verificar: true }) });
      const j = await r.json().catch(() => ({}));
      return J({ ok: r.ok && j.ok === true, chave: j.chave ?? null }, r.ok ? 200 : 502);
    } catch (e) { return J({ ok: false, erro: String(e) }, 502); }
  }

  if (corpo.teste) {   // confere secrets, hub e o visual, sem tocar na fila
    const para = String(corpo.para || ""); if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(para)) return J({ ok: false, erro: 'informe "para"' }, 400);
    try { await enviar(para, "Artecon · Propostas — e-mail de teste", emailArtecon({ escritorio: { nome: "Artecon Artes Contábeis", telefone: "(48) 3242-0530", site: "www.artecon.cnt.br" }, titulo: "E-mail de teste",
      saudacao: "Olá!", paragrafos: ["Se você está lendo isto, a função <b>prop-email</b> está publicada, os secrets estão corretos e o hub Artecon Mail aceitou o envio."],
      chaves: [["Proposta", "nº 000/2026"], ["Cliente", "Cliente de Teste Ltda"], ["Código de verificação", "ABCDE-12345", true]], botao: { txt: "Abrir o sistema", url: APP } })); return J({ ok: true, teste: "enviado para " + para }); }
    catch (e) { return J({ ok: false, erro: String((e as Error).message || e) }, 502); }
  }

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: fila, error } = await sb.rpc("prop_sistema_fila_pegar", { p_limite: 20 });
  if (error) { console.error("[prop-email] fila:", error.message); return J({ ok: false, erro: error.message }, 500); }
  const res = { ok: true, pegos: (fila || []).length, enviados: 0, erros: 0 };
  for (const f of (fila || []) as any[]) {
    try {
      let urlVia: string | undefined;
      if (f.tipo === "via_assinada") {
        const { data: lk, error: e1 } = await sb.rpc("prop_sistema_link_leitura", { p_fila: f.id }); if (e1) throw new Error(e1.message);
        urlVia = (f.escritorio.app_url || APP).split("#")[0] + "#/c/" + lk.token;
      }
      const m = montar(f, urlVia);
      await enviar(f.destinatario, m.assunto, m.html);
      const { error: e2 } = await sb.rpc("prop_sistema_fila_ok", { p_fila: f.id }); if (e2) throw new Error("enviado, mas não marcou: " + e2.message);
      res.enviados++; console.log(`[prop-email] ok ${f.tipo} -> ${f.destinatario} (proposta ${numero(f)})`);
    } catch (e) {
      res.erros++; const msg = String((e as Error).message || e); console.error(`[prop-email] ERRO ${f.tipo} -> ${f.destinatario}: ${msg}`);
      await sb.rpc("prop_sistema_fila_erro", { p_fila: f.id, p_erro: msg });
    }
  }
  return J(res);
});
