// Agenda Pro — pessoas SÓ do Estudo da Reforma Tributária (estudo.html → Equipe).
// Projeto Supabase do Agenda (vuwgxndahrzinfdlapxz). Não passa pelo Portal Artecon.
//
// Quem chama precisa ser administrador ou gerente ativo do escritório (agenda_usuarios).
//   acao "cadastrar": cria o login com senha provisória (ou aproveita o login que o e-mail já tem,
//     o projeto também é usado pelo Financeiro Pro) e grava a pessoa em agenda_estudo_usuarios,
//     no mesmo escritório de quem cadastrou. Ela NÃO entra em agenda_usuarios: não vê nada da agenda.
//   acao "nova_senha": gera outra senha provisória, só para login criado por esta função
//     (app_metadata.criado_pelo_estudo) de pessoa que não está na equipe do Agenda.
// Ativar e desativar é feito pelo próprio Estudo (regra estudo_usuarios_update).
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// senha provisória fácil de ditar: letras sem ambiguidade + números (igual à agenda-equipe)
function senhaProvisoria() {
  const letras = "abcdefghjkmnpqrstuvwxyz", nums = "23456789";
  const b = crypto.getRandomValues(new Uint8Array(8));
  let s = "";
  for (let i = 0; i < 5; i++) s += letras[b[i] % letras.length];
  for (let i = 5; i < 8; i++) s += nums[b[i] % nums.length];
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function fone(v: unknown): string | null {
  let d = String(v || "").replace(/\D/g, "");
  if ((d.length === 12 || d.length === 13) && d.startsWith("55")) d = d.slice(2);
  return d.length === 10 || d.length === 11 ? d : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const resp = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    // quem está chamando?
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: quem, error: eQuem } = await db.auth.getUser(jwt);
    if (eQuem || !quem?.user) return resp({ ok: false, erro: "Sessão expirada. Entre de novo." }, 401);
    const { data: eu } = await db.from("agenda_usuarios").select("id, tenant_id, perfil, ativo")
      .eq("auth_id", quem.user.id).maybeSingle();
    if (!eu || !eu.ativo || !["admin", "gerente"].includes(eu.perfil)) {
      return resp({ ok: false, erro: "Só administrador ou gerente do Agenda pode cadastrar pessoas no Estudo." }, 403);
    }

    const b = await req.json().catch(() => ({}));

    // ── nova senha provisória ──────────────────────────────
    if (b.acao === "nova_senha") {
      const id = Number(b.id);
      const { data: pessoa } = await db.from("agenda_estudo_usuarios").select("*").eq("id", id).maybeSingle();
      if (!pessoa || pessoa.tenant_id !== eu.tenant_id) return resp({ ok: false, erro: "Pessoa não encontrada." }, 404);
      const { data: noAgenda } = await db.from("agenda_usuarios").select("id").eq("auth_id", pessoa.auth_id).eq("ativo", true).maybeSingle();
      if (noAgenda) return resp({ ok: false, erro: "Essa pessoa está na equipe do Agenda: a senha é a mesma do Agenda." }, 409);
      const { data: login } = await db.auth.admin.getUserById(pessoa.auth_id);
      if (!login?.user) return resp({ ok: false, erro: "Login não encontrado." }, 404);
      if (!login.user.app_metadata?.criado_pelo_estudo) {
        return resp({ ok: false, erro: "Esse e-mail já tinha login (Financeiro Pro ou outro app). A pessoa continua com a senha de lá." }, 409);
      }
      const nova = senhaProvisoria();
      const { error: eSenha } = await db.auth.admin.updateUserById(pessoa.auth_id, {
        password: nova, user_metadata: { ...(login.user.user_metadata || {}), trocar_senha: true },
      });
      if (eSenha) return resp({ ok: false, erro: "Não foi possível trocar a senha: " + eSenha.message }, 400);
      return resp({ ok: true, usuario: pessoa, senha: nova, ja_tinha_login: false });
    }

    // ── cadastrar ──────────────────────────────────────────
    const nome = String(b.nome || "").trim().slice(0, 120);
    const email = String(b.email || "").trim().toLowerCase().slice(0, 200);
    const whatsapp = b.whatsapp ? fone(b.whatsapp) : null;
    if (!nome || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return resp({ ok: false, erro: "Informe nome e um e-mail válido." }, 400);
    if (b.whatsapp && !whatsapp) return resp({ ok: false, erro: "WhatsApp inválido: informe DDD + número." }, 400);

    // o e-mail já tem login?
    let authId: string | null = null, senha: string | null = null, jaTinhaLogin = false;
    const { data: existente } = await db.rpc("agenda_auth_id_por_email", { p_email: email });
    if (existente) {
      authId = existente as string; jaTinhaLogin = true;
      const { data: noAgenda } = await db.from("agenda_usuarios").select("tenant_id, ativo").eq("auth_id", authId).maybeSingle();
      if (noAgenda && noAgenda.tenant_id !== eu.tenant_id) {
        return resp({ ok: false, erro: "Esse e-mail está cadastrado em outro escritório do Agenda Pro." }, 409);
      }
      if (noAgenda && noAgenda.ativo) {
        return resp({ ok: false, erro: "Essa pessoa já está na equipe do Agenda e já pode usar o Estudo com o login dela." }, 409);
      }
      const { data: jaNoEstudo } = await db.from("agenda_estudo_usuarios").select("*").eq("auth_id", authId).maybeSingle();
      if (jaNoEstudo) {
        if (jaNoEstudo.tenant_id !== eu.tenant_id) return resp({ ok: false, erro: "Esse e-mail está no Estudo de outro escritório." }, 409);
        if (jaNoEstudo.ativo) return resp({ ok: false, erro: "Essa pessoa já está cadastrada no Estudo." }, 409);
        // estava desativada: reativa com os dados novos (a senha continua a mesma)
        const { data: usuario, error: eUpd } = await db.from("agenda_estudo_usuarios")
          .update({ ativo: true, nome, whatsapp }).eq("id", jaNoEstudo.id).select("*").single();
        if (eUpd) return resp({ ok: false, erro: "Não foi possível reativar: " + eUpd.message }, 500);
        return resp({ ok: true, usuario, senha: null, ja_tinha_login: true, reativado: true });
      }
    } else {
      const nova = senhaProvisoria();
      const { data: criado, error: eCriar } = await db.auth.admin.createUser({
        email, password: nova, email_confirm: true,
        user_metadata: { nome, trocar_senha: true },          // o Estudo pede a senha da pessoa no 1º acesso
        app_metadata: { criado_pelo_estudo: true },            // permite "nova senha" depois; só a chave de serviço altera
      });
      if (!criado?.user) return resp({ ok: false, erro: "Não foi possível criar o login: " + (eCriar?.message || "erro desconhecido") }, 400);
      authId = criado.user.id; senha = nova;
    }

    const { data: usuario, error: eIns } = await db.from("agenda_estudo_usuarios").insert({
      tenant_id: eu.tenant_id, auth_id: authId, nome, email, whatsapp, ativo: true, criado_por: quem.user.id,
    }).select("*").single();
    if (eIns) return resp({ ok: false, erro: "Login pronto, mas não foi possível cadastrar no Estudo: " + eIns.message }, 500);

    return resp({ ok: true, usuario, senha, ja_tinha_login: jaTinhaLogin });
  } catch (e) {
    console.error(e);
    return resp({ ok: false, erro: String((e as Error).message || e) }, 500);
  }
});
