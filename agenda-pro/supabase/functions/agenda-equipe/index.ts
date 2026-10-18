// Agenda Pro — cadastro de pessoas da equipe (Colaboradores → Convidar).
// Projeto Supabase do Agenda (vuwgxndahrzinfdlapxz).
//
// O app não pode criar logins sozinho (precisa da chave de serviço), por isso
// esta função: confere que quem chama é administrador ou gerente do escritório,
// cria o login com uma senha provisória (ou aproveita o login que o e-mail já
// tem — o projeto também é usado pelo Financeiro Pro) e cadastra a pessoa em
// agenda_usuarios no mesmo escritório de quem convidou.
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const PERFIS = ["admin", "gerente", "colaborador", "visualizador"];

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// senha provisória fácil de ditar: letras sem ambiguidade + números
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
    if (eQuem || !quem?.user) return resp({ ok: false, erro: "Sessão expirada. Entre de novo no app." }, 401);
    const { data: eu } = await db.from("agenda_usuarios").select("id, tenant_id, perfil, ativo")
      .eq("auth_id", quem.user.id).maybeSingle();
    if (!eu || !eu.ativo || !["admin", "gerente"].includes(eu.perfil)) {
      return resp({ ok: false, erro: "Só administrador ou gerente pode cadastrar pessoas da equipe." }, 403);
    }

    const b = await req.json().catch(() => ({}));
    const nome = String(b.nome || "").trim().slice(0, 120);
    const email = String(b.email || "").trim().toLowerCase().slice(0, 200);
    const perfil = PERFIS.includes(b.perfil) ? b.perfil : "colaborador";
    const whatsapp = b.whatsapp ? fone(b.whatsapp) : null;
    if (!nome || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return resp({ ok: false, erro: "Informe nome e um e-mail válido." }, 400);
    if (b.whatsapp && !whatsapp) return resp({ ok: false, erro: "WhatsApp inválido: informe DDD + número." }, 400);
    if (perfil === "admin" && eu.perfil !== "admin") return resp({ ok: false, erro: "Só o administrador pode cadastrar outro administrador." }, 403);

    // login: cria com senha provisória ou aproveita o que já existe
    let authId: string | null = null, senha: string | null = null, jaTinhaLogin = false;
    const nova = senhaProvisoria();
    const { data: criado, error: eCriar } = await db.auth.admin.createUser({
      email, password: nova, email_confirm: true, user_metadata: { nome, trocar_senha: true },   // o app pede a senha da pessoa no 1º acesso (v2.2.0)
    });
    if (criado?.user) { authId = criado.user.id; senha = nova; }
    else {
      const { data: existente } = await db.rpc("agenda_auth_id_por_email", { p_email: email });
      if (!existente) return resp({ ok: false, erro: "Não foi possível criar o login: " + (eCriar?.message || "erro desconhecido") }, 400);
      authId = existente as string; jaTinhaLogin = true;
    }

    const { data: jaNoAgenda } = await db.from("agenda_usuarios").select("id, tenant_id").eq("auth_id", authId).maybeSingle();
    if (jaNoAgenda) {
      return resp({ ok: false, erro: jaNoAgenda.tenant_id === eu.tenant_id
        ? "Essa pessoa já está na equipe."
        : "Esse e-mail já está cadastrado em outro escritório do Agenda Pro." }, 409);
    }

    const { data: usuario, error: eIns } = await db.from("agenda_usuarios").insert({
      tenant_id: eu.tenant_id, auth_id: authId, nome, email, perfil, ativo: true, whatsapp,
    }).select("*").single();
    if (eIns) return resp({ ok: false, erro: "Login criado, mas não foi possível cadastrar na equipe: " + eIns.message }, 500);

    return resp({ ok: true, usuario, senha, ja_tinha_login: jaTinhaLogin });
  } catch (e) {
    console.error(e);
    return resp({ ok: false, erro: String((e as Error).message || e) }, 500);
  }
});
