// ============================================================
// COBRANÇA PRO — Edge Function: mail-proxy  (v2 · app v2.17.0)
// Ponte segura entre o app (navegador) e o hub Artecon Mail.
// O MAIL_API_KEY vive só aqui, como secret (nunca no index.html).
//
// v2 (segurança, etapa A): o destinatário precisa ser conhecido —
//   • e-mail cadastrado de um cliente do escritório (ficha de contatos ativa ou e-mail do cadastro), ou
//   • o e-mail de teste das Configurações, ou
//   • o próprio e-mail de quem está logado, ou
//   • um endereço @artecon.cnt.br (relatórios internos).
// A conferência usa o token do próprio usuário, então o RLS do banco
// limita a busca aos clientes do escritório dele.
// Secrets: MAIL_API_KEY (SUPABASE_URL e SUPABASE_ANON_KEY já existem)
// ============================================================

const MAIL_SEND_URL = "https://tjnqloycikukvvnconqn.supabase.co/functions/v1/mail-send";
const MAIL_API_KEY  = Deno.env.get("MAIL_API_KEY")!;
const SB_URL        = Deno.env.get("SUPABASE_URL")!;
const SB_ANON       = Deno.env.get("SUPABASE_ANON_KEY")!;

const DOMINIO_INTERNO = "@artecon.cnt.br";
const MAX_DESTINOS = 5;
const MAX_HTML = 400_000;   // ~400 KB (o e-mail de cobrança tem ~30 KB)

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function resposta(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const EMAIL_OK = /^[^\s@<>(),;:"]+@[^\s@<>(),;:"]+\.[^\s@<>(),;:"]+$/;

// consulta a API do banco com o token do usuário (RLS do escritório)
async function existe(token: string, tabela: string, filtros: string): Promise<boolean> {
  const r = await fetch(`${SB_URL}/rest/v1/${tabela}?select=id&limit=1&${filtros}`, {
    headers: { apikey: SB_ANON, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) throw new Error(`consulta ${tabela} falhou (${r.status})`);
  const j = await r.json();
  return Array.isArray(j) && j.length > 0;
}

async function emailDeTeste(token: string, email: string): Promise<boolean> {
  const r = await fetch(`${SB_URL}/rest/v1/cob_politicas?select=teste_email`, {
    headers: { apikey: SB_ANON, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) return false;
  const j = await r.json();
  return Array.isArray(j) && j.some((p: { teste_email?: string }) => String(p.teste_email || "").trim().toLowerCase() === email);
}

async function destinoPermitido(token: string, email: string, emailUsuario: string): Promise<boolean> {
  if (email.endsWith(DOMINIO_INTERNO)) return true;
  if (emailUsuario && email === emailUsuario) return true;
  const v = encodeURIComponent(email);
  if (await existe(token, "cob_clientes_contatos", `tipo=eq.email&ativo=eq.true&valor=eq.${v}`)) return true;
  if (await existe(token, "cob_clientes", `email=eq.${v}`)) return true;
  return await emailDeTeste(token, email);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return resposta({ ok: false, erro: "método não permitido" }, 405);

  try {
    // 1) usuário logado (a anon key sozinha é recusada)
    const auth = req.headers.get("Authorization") ?? "";
    const token = auth.replace(/^Bearer\s+/i, "");
    if (!token) return resposta({ ok: false, erro: "sem token" }, 401);
    const u = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SB_ANON, Authorization: `Bearer ${token}` } });
    if (!u.ok) return resposta({ ok: false, erro: "usuario nao autenticado" }, 401);
    const usuario = await u.json();
    const emailUsuario = String(usuario?.email || "").trim().toLowerCase();

    // 2) pedido bem formado
    const p = await req.json();
    const destinos = (Array.isArray(p.to) ? p.to : [p.to]).map((x: unknown) => String(x ?? "").trim().toLowerCase());
    if (!destinos.length || destinos.length > MAX_DESTINOS || destinos.some((d: string) => !EMAIL_OK.test(d))) {
      return resposta({ ok: false, erro: "destinatário inválido" }, 400);
    }
    if (typeof p.assunto !== "string" || !p.assunto.trim() || p.assunto.length > 600) {
      return resposta({ ok: false, erro: "assunto inválido" }, 400);
    }
    if (typeof p.html !== "string" || !p.html || p.html.length > MAX_HTML) {
      return resposta({ ok: false, erro: "conteúdo inválido" }, 400);
    }
    const replyTo = typeof p.replyTo === "string" && p.replyTo.trim().toLowerCase().endsWith(DOMINIO_INTERNO) ? p.replyTo.trim() : undefined;

    // 3) só para destinatário conhecido (cliente do escritório, teste, o próprio usuário ou @artecon.cnt.br)
    for (const d of destinos) {
      if (!(await destinoPermitido(token, d, emailUsuario))) {
        console.warn(`mail-proxy: destino recusado ${d} (usuário ${emailUsuario})`);
        return resposta({ ok: false, erro: `destinatário ${d} não está cadastrado em nenhum cliente — envio bloqueado` }, 403);
      }
    }

    // 4) repassa ao hub Artecon Mail com a chave secreta
    const r = await fetch(MAIL_SEND_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-api-key": MAIL_API_KEY },
      body: JSON.stringify({ app: "cobranca-pro", to: Array.isArray(p.to) ? destinos : destinos[0], assunto: p.assunto, html: p.html, replyTo }),
    });
    const j = await r.json().catch(() => ({ ok: false, erro: "resposta invalida do mail-send" }));
    return resposta(j, r.status);
  } catch (e) {
    return resposta({ ok: false, erro: String(e) }, 500);
  }
});
