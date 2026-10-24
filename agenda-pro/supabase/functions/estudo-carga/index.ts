// Agenda Pro — carga dos arquivos do Estudo da Reforma no armazenamento privado "estudo" (v2.6.0).
// Projeto Supabase do Agenda (vuwgxndahrzinfdlapxz). Uso de manutenção, não é chamada pelo app.
//
// Quem chama manda o token de carga no cabeçalho x-carga (e a chave anon em Authorization).
// Aqui fica só o hash SHA-256 do token. Para trocar: gerar outro token, pôr o hash novo em HASH e publicar de novo.
//   GET                          → lista os arquivos
//   GET  ?caminho=dados.json     → devolve o arquivo
//   POST ?caminho=audio/m1a.mp3  → grava (substitui) com o corpo da requisição
// O app lê os arquivos com o login da pessoa (regra estudo_arquivos_ler, sql/agenda_estudo_arquivos.sql).
import { createClient } from "jsr:@supabase/supabase-js@2";

const HASH = "90300f4d93eac8ca7767b6fd7089fc3a7fafcdbf17e3b00665c41ed509f61aa1";
const BALDE = "estudo";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function sha256(s: string) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  const resp = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  try {
    if (await sha256(req.headers.get("x-carga") || "") !== HASH) return resp({ ok: false, erro: "Não autorizado." }, 401);
    const caminho = new URL(req.url).searchParams.get("caminho") || "";
    if (caminho && (!/^[a-z0-9][a-z0-9_.\/-]*$/i.test(caminho) || caminho.includes(".."))) {
      return resp({ ok: false, erro: "Caminho inválido." }, 400);
    }

    if (req.method === "GET" && !caminho) {
      const arquivos: unknown[] = [];
      for (const pasta of ["", "audio", "analises", "modulos"]) {
        const { data, error } = await db.storage.from(BALDE).list(pasta, { limit: 1000 });
        if (error) return resp({ ok: false, erro: error.message }, 500);
        (data || []).filter((a) => a.id).forEach((a) =>
          arquivos.push({ caminho: (pasta ? pasta + "/" : "") + a.name, bytes: a.metadata?.size, em: a.updated_at }));
      }
      return resp({ ok: true, arquivos });
    }

    if (req.method === "GET") {
      const { data, error } = await db.storage.from(BALDE).download(caminho);
      if (error || !data) return resp({ ok: false, erro: error?.message || "Não encontrado." }, 404);
      return new Response(data, { headers: { "Content-Type": data.type || "application/octet-stream" } });
    }

    if (req.method === "POST") {
      if (!caminho) return resp({ ok: false, erro: "Informe ?caminho=" }, 400);
      const corpo = new Uint8Array(await req.arrayBuffer());
      const { error } = await db.storage.from(BALDE).upload(caminho, corpo, {
        upsert: true,
        contentType: req.headers.get("content-type") || "application/octet-stream",
        cacheControl: caminho.endsWith(".mp3") ? "86400" : "0",   // dados.json: sempre confere se mudou
      });
      if (error) return resp({ ok: false, erro: error.message }, 500);
      return resp({ ok: true, caminho, bytes: corpo.length });
    }

    return resp({ ok: false, erro: "Método não aceito." }, 405);
  } catch (e) {
    console.error(e);
    return resp({ ok: false, erro: String((e as Error).message || e) }, 500);
  }
});
