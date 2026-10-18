# Gestão Empresarial e Financeiro — Artecon

Repositório do departamento, um aplicativo por pasta (estrutura definida em 18/10/2026). Entre sempre pelo
[Portal Artecon](https://arteconartescontabeis-design.github.io/portal/).

| Pasta | Aplicativo | Banco (Supabase) |
|---|---|---|
| `cobranca-pro/` | Cobrança Pro | `cobranca-pro` (`yeujqjtjqtegsnzwwazb`) |
| `propostas/` | Propostas de Honorários | `cobranca-pro` (tabelas `prop_*`, schema `prop_priv`) |
| `financeiro-pro/` | Financeiro Pro | hoje `agenda-pro`; **vai para `cobranca-pro`** na virada dele |
| `agenda-pro/` | Agenda Pro (+ Estudo da Reforma) | `agenda-pro` (`vuwgxndahrzinfdlapxz`) |
| `patrimonial-pro/` | Patrimonial Pro | hoje `patrimonial-pro`; **vai para `agenda-pro`** na virada dele |
| `carreira-pro/` | Carreira Pro | hoje `Carreira PRO` (vazio); **vai para `agenda-pro`** na virada dele |
| `radar/` | Radar (curadoria) | `radar-artecon` — entra numa etapa própria |

Cada pasta guarda o próprio `CLAUDE.md` quando o app tinha um (Cobrança e Agenda): as regras de versão e de testes de
cada app continuam valendo.

## Migração (outubro/2026)
Origem (commit): `cobranca-pro` `7b0005c` · `propostas` `85fbc00` · `financeiro-pro` `4eb8661` · `agenda-pro` `ef61af6` ·
`patrimonial-pro` `fdb4a73` · Carreira Pro: `index.html` enviado pelo usuário em 18/10/2026 (o endereço antigo dava 404).

O que mudou além da pasta (só endereços — nenhuma regra de negócio):
- Cobrança **v2.17.1**: logo dos e-mails no endereço novo.
- Propostas **v2.1.2**: logo dos e-mails no endereço novo. Os links de assinatura são montados a partir do endereço da
  página, então já saem com o endereço novo; os antigos continuam valendo pelo aviso com redirecionamento.
- Financeiro: `cadastro_usuario.html` aponta para o endereço novo (convites de 7 dias já enviados seguem pelo aviso).
- Agenda **v2.8.1**: `manifest.json` e `service-worker.js` no caminho novo (quem instalou o app no celular instala de novo).
- Patrimonial e Carreira: nenhuma mudança no código nesta etapa (o banco muda na virada de cada um).

## Virada (um app por vez — código e banco juntos)
1. Carreira Pro · 2. Patrimonial · 3. Financeiro · 4. Agenda, Propostas e Cobrança (só código) · 5. Radar.
Scripts do Portal em `banco/portal/` (`virada_destinos.sql`, `volta_destinos.sql`, `areas.sql`, `areas_volta.sql`).
Os endereços antigos viram aviso com redirecionamento que preserva `?…` e `#…`; logos antigos ficam no ar.
