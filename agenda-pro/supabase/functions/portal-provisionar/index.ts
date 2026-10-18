// Agenda Pro — conta da pessoa a pedido do PORTAL ARTECON (Acessos → liberar, revogar, "Senha do Agenda").
// Projeto Supabase do Agenda (vuwgxndahrzinfdlapxz), que é COMPARTILHADO com o Financeiro Pro: o login é o
// mesmo nos dois aplicativos. Por isso esta função nunca bloqueia o login e só troca a senha de quem já tem
// login quando o portal pede isso de forma explícita (redefinir = true, botão "Senha do Agenda").
//
// Quem chama é o portal, com o token da sessão do núcleo (projeto fbxelwhdiisfmnwrerbl). A função:
//   1) confirma o token no núcleo (/auth/v1/user);
//   2) confere no núcleo (core.is_admin) que quem pede é administrador da organização;
//   3) acha o escritório do Agenda ligado à organização (agenda_portal_orgs);
//   4) só então usa a chave de serviço deste projeto.
// Publicar com "Verify JWT" DESLIGADO: o token vem de outro projeto e é conferido aqui (passos 1 e 2).
//
// Ações (corpo JSON, sempre com "org"):
//   lista                                         → { contas: [{ email, perfil, ativo, trocar_senha }] }
//   criar { email, nome, perfil, senha?, redefinir? } → cria o login (se não existir) e cadastra ou reativa a
//                                                     pessoa no Agenda; perfil do portal: leitura | operador | admin
//   desativar { email }                           → desativa a pessoa no Agenda (o login continua existindo)
import { createClient } from "jsr:@supabase/supabase-js@2";
import { tratar } from "./provisionar.ts";

const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
Deno.serve((req) => tratar(req, { dpFetch: fetch, adm }));
