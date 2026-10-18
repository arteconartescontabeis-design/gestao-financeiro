// Lógica da função portal-provisionar (sem ligar o servidor: testável com dependências falsas).
// Ver o cabeçalho do index.ts.
const DP_URL = Deno.env.get("DP_URL") ?? "https://fbxelwhdiisfmnwrerbl.supabase.co";
const DP_CHAVE = Deno.env.get("DP_PUBLISHABLE_KEY") ?? "sb_publishable_iRqjOGU1ialauv_wHYarbw_cRzspHH6";
const ORIGENS = (Deno.env.get("ORIGENS_PERMITIDAS") ?? "https://arteconartescontabeis-design.github.io")
  .split(",").map((s) => s.trim());
// nível no portal → perfil no Agenda (o portal não tem "gerente": quem já é gerente continua gerente como Operador)
export const PERFIS: Record<string, string> = { leitura: "visualizador", operador: "colaborador", admin: "admin" };

type Json = Record<string, unknown>;
// deno-lint-ignore no-explicit-any
type Adm = any;
export type Dep = { dpFetch: typeof fetch; adm: Adm };

function cors(origem: string | null) {
  const ok = origem && ORIGENS.includes(origem) ? origem : ORIGENS[0];
  return {
    "Access-Control-Allow-Origin": ok,
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
function resp(corpo: unknown, status: number, h: Record<string, string>) {
  return new Response(JSON.stringify(corpo), { status, headers: { ...h, "Content-Type": "application/json" } });
}
const emailValido = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

/** Quem chama é administrador da organização no núcleo? Devolve o e-mail de quem chama, ou um erro. */
async function conferirAdmin(dep: Dep, token: string, org: string): Promise<{ email: string } | { erro: string; status: number }> {
  const rU = await dep.dpFetch(`${DP_URL}/auth/v1/user`, { headers: { apikey: DP_CHAVE, Authorization: `Bearer ${token}` } });
  if (!rU.ok) return { erro: "sessão do portal inválida ou expirada", status: 401 };
  const executor = await rU.json();
  const rA = await dep.dpFetch(`${DP_URL}/rest/v1/rpc/is_admin`, {
    method: "POST",
    headers: { apikey: DP_CHAVE, Authorization: `Bearer ${token}`, "Content-Type": "application/json", "Content-Profile": "core", "Accept-Profile": "core" },
    body: JSON.stringify({ p_org: org }),
  });
  let ehAdmin = rA.ok ? await rA.json() : null;
  if (ehAdmin === null) {   // sem permissão de executar a função: confere o vínculo (a RLS do núcleo deixa ler o próprio)
    const rM = await dep.dpFetch(`${DP_URL}/rest/v1/memberships?select=papel,situacao&org_id=eq.${encodeURIComponent(org)}&user_id=eq.${encodeURIComponent(executor.id)}`,
      { headers: { apikey: DP_CHAVE, Authorization: `Bearer ${token}`, "Accept-Profile": "core" } });
    const m = rM.ok ? await rM.json() : [];
    ehAdmin = Array.isArray(m) && m.some((x: Json) => x.situacao === "ativo" && ["admin", "superadmin"].includes(String(x.papel)));
  }
  if (ehAdmin !== true) return { erro: "apenas administradores do portal podem gerir contas", status: 403 };
  return { email: String(executor.email || "") };
}

/** É o único administrador ativo do Agenda neste escritório? */
async function unicoAdmin(adm: Adm, tenant: number, usuarioId: number) {
  const { data, error } = await adm.from("agenda_usuarios").select("id").eq("tenant_id", tenant).eq("perfil", "admin").eq("ativo", true);
  if (error) throw error;
  return (data || []).length === 1 && data[0].id === usuarioId;
}
const MSG_UNICO_ADMIN = "é o único administrador do Agenda Pro neste escritório — libere outra pessoa como Administrador antes";

export async function tratar(req: Request, dep: Dep): Promise<Response> {
  const h = cors(req.headers.get("Origin"));
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  if (req.method !== "POST") return resp({ ok: false, erro: "use POST" }, 405, h);
  try {
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!token) return resp({ ok: false, erro: "sem sessão do portal" }, 401, h);
    const corpo = await req.json().catch(() => ({})) as Json;
    const acao = String(corpo.acao ?? "");
    const org = String(corpo.org ?? "");
    if (!org) return resp({ ok: false, erro: "organização não informada" }, 400, h);

    const quem = await conferirAdmin(dep, token, org);
    if ("erro" in quem) return resp({ ok: false, erro: quem.erro }, quem.status, h);

    const adm = dep.adm;
    const { data: liga, error: eLiga } = await adm.from("agenda_portal_orgs").select("tenant_id").eq("org_id", org).maybeSingle();
    if (eLiga) throw eLiga;
    if (!liga) return resp({ ok: false, erro: "esta organização ainda não está ligada a um escritório do Agenda Pro" }, 403, h);
    const tenant = Number(liga.tenant_id);
    const log = (m: string) => console.log(`[portal-provisionar] ${quem.email} → ${m}`);

    // ----- lista: situação das contas (para a tela Acessos do portal)
    if (acao === "lista") {
      const { data: us, error } = await adm.from("agenda_usuarios").select("email, perfil, ativo, auth_id").eq("tenant_id", tenant);
      if (error) throw error;
      const contas = [];
      for (const u of us || []) {
        let trocar = false;
        if (u.auth_id) { const { data: a } = await adm.auth.admin.getUserById(u.auth_id); trocar = !!a?.user?.user_metadata?.trocar_senha; }
        contas.push({ email: String(u.email || "").toLowerCase(), perfil: u.perfil, ativo: !!u.ativo, trocar_senha: trocar });
      }
      return resp({ ok: true, contas }, 200, h);
    }

    const email = String(corpo.email ?? "").trim().toLowerCase();
    if (!emailValido(email)) return resp({ ok: false, erro: "e-mail inválido" }, 400, h);
    const { data: authIdAchado, error: eAuth } = await adm.rpc("agenda_auth_id_por_email", { p_email: email });
    if (eAuth) throw eAuth;
    let authId = (authIdAchado as string | null) || null;

    // ----- criar / reativar
    if (acao === "criar") {
      const perfil = PERFIS[String(corpo.perfil ?? "operador")];
      if (!perfil) return resp({ ok: false, erro: "nível desconhecido (use Leitura, Operador ou Administrador)" }, 400, h);
      const senha = corpo.senha ? String(corpo.senha) : "";
      if (senha && senha.length < 8) return resp({ ok: false, erro: "a senha provisória precisa de pelo menos 8 caracteres" }, 400, h);
      const redefinir = corpo.redefinir === true;
      const nome = String(corpo.nome ?? "").trim().slice(0, 120);

      let criado = false, senhaDefinida = false;
      if (!authId) {
        if (!senha) return resp({ ok: false, erro: "informe a senha provisória para criar o login" }, 400, h);
        const { data, error } = await adm.auth.admin.createUser({ email, password: senha, email_confirm: true,
          user_metadata: { nome, trocar_senha: true, criado_pelo_portal: quem.email } });
        if (error) throw error;
        authId = data.user.id; criado = true; senhaDefinida = true;
      } else if (redefinir && senha) {
        const { data: a } = await adm.auth.admin.getUserById(authId);
        const { error } = await adm.auth.admin.updateUserById(authId, { password: senha,
          user_metadata: { ...(a?.user?.user_metadata ?? {}), trocar_senha: true } });
        if (error) throw error;
        senhaDefinida = true;
      }

      const { data: atual, error: eAt } = await adm.from("agenda_usuarios").select("id, tenant_id, perfil, ativo, nome").eq("auth_id", authId).maybeSingle();
      if (eAt) throw eAt;
      if (atual && Number(atual.tenant_id) !== tenant) {
        return resp({ ok: false, erro: "este e-mail já está cadastrado em outro escritório do Agenda Pro" }, 409, h);
      }
      const perfilFinal = atual && perfil === "colaborador" && atual.perfil === "gerente" ? "gerente" : perfil;
      if (atual && atual.ativo && atual.perfil === "admin" && perfilFinal !== "admin" && await unicoAdmin(adm, tenant, atual.id)) {
        return resp({ ok: false, erro: MSG_UNICO_ADMIN }, 409, h);
      }
      if (atual) {
        const { error } = await adm.from("agenda_usuarios").update({ perfil: perfilFinal, ativo: true, ...(atual.nome ? {} : { nome: nome || email }) }).eq("id", atual.id);
        if (error) throw error;
      } else {
        const { error } = await adm.from("agenda_usuarios").insert({ tenant_id: tenant, auth_id: authId, nome: nome || email.split("@")[0], email, perfil: perfilFinal, ativo: true });
        if (error) throw error;
      }
      log(`${atual ? (atual.ativo ? "atualizou" : "reativou") : "cadastrou"} ${email} (${perfilFinal})${criado ? ", login novo" : senhaDefinida ? ", nova senha provisória" : ""}`);
      return resp({ ok: true, criado, ja_tinha_login: !criado, senha_definida: senhaDefinida, perfil: perfilFinal }, 200, h);
    }

    // ----- desativar (não apaga nada e não bloqueia o login, que é o mesmo do Financeiro Pro)
    if (acao === "desativar") {
      if (!authId) return resp({ ok: true, aviso: "não havia login no Agenda Pro" }, 200, h);
      const { data: atual, error: eAt } = await adm.from("agenda_usuarios").select("id, perfil, ativo").eq("auth_id", authId).eq("tenant_id", tenant).maybeSingle();
      if (eAt) throw eAt;
      if (!atual) return resp({ ok: true, aviso: "a pessoa não estava cadastrada no Agenda Pro" }, 200, h);
      if (atual.ativo && atual.perfil === "admin" && await unicoAdmin(adm, tenant, atual.id)) return resp({ ok: false, erro: MSG_UNICO_ADMIN }, 409, h);
      const { error } = await adm.from("agenda_usuarios").update({ ativo: false }).eq("id", atual.id);
      if (error) throw error;
      log(`desativou ${email}`);
      return resp({ ok: true }, 200, h);
    }

    return resp({ ok: false, erro: "ação desconhecida" }, 400, h);
  } catch (e) {
    console.error("[portal-provisionar]", e);
    return resp({ ok: false, erro: String((e as Error)?.message ?? e) }, 500, h);
  }
}
