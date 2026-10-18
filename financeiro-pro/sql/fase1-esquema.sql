-- ============================================================
-- FINANCEIRO PRO — Fase 1
-- Projeto Supabase: vuwgxndahrzinfdlapxz (compartilhado com Agenda Pro)
-- Todas as tabelas usam prefixo "fin_" para não conflitar
-- ============================================================

-- ── 1. TENANTS ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_tenants (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome            TEXT NOT NULL,
  setor           TEXT,
  criado_em       TIMESTAMPTZ DEFAULT NOW(),
  ativo           BOOLEAN DEFAULT TRUE
);

-- ── 2. USUÁRIOS ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_usuarios (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  auth_id         UUID NOT NULL UNIQUE, -- auth.users.id do Supabase
  nome            TEXT NOT NULL,
  email           TEXT NOT NULL,
  perfil          TEXT NOT NULL DEFAULT 'admin' CHECK (perfil IN ('admin','financeiro','visualizador')),
  ativo           BOOLEAN DEFAULT TRUE,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 3. CONVITES ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_convites (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  email           TEXT NOT NULL,
  perfil          TEXT NOT NULL DEFAULT 'financeiro',
  codigo          TEXT NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(6), 'hex'),
  usado           BOOLEAN DEFAULT FALSE,
  criado_em       TIMESTAMPTZ DEFAULT NOW(),
  expira_em       TIMESTAMPTZ DEFAULT NOW() + INTERVAL '7 days'
);

-- ── 4. CONTAS BANCÁRIAS ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_contas (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  nome            TEXT NOT NULL,
  tipo            TEXT NOT NULL DEFAULT 'corrente' CHECK (tipo IN ('corrente','poupanca','caixa','cartao','investimento','outro')),
  banco           TEXT,
  saldo_inicial   NUMERIC(15,2) NOT NULL DEFAULT 0,
  saldo_atual     NUMERIC(15,2) NOT NULL DEFAULT 0,
  cor             TEXT DEFAULT '#6366F1',
  ativo           BOOLEAN DEFAULT TRUE,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 5. CATEGORIAS ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_categorias (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  nome            TEXT NOT NULL,
  tipo            TEXT NOT NULL CHECK (tipo IN ('receita','despesa','ambos')),
  cor             TEXT DEFAULT '#6366F1',
  icone           TEXT DEFAULT '📁',
  padrao          BOOLEAN DEFAULT FALSE, -- categorias padrão do sistema
  ativo           BOOLEAN DEFAULT TRUE,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 6. CLIENTES ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_clientes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  nome            TEXT NOT NULL,
  cpf_cnpj        TEXT,
  email           TEXT,
  telefone        TEXT,
  ativo           BOOLEAN DEFAULT TRUE,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 7. FORNECEDORES ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_fornecedores (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  nome            TEXT NOT NULL,
  cpf_cnpj        TEXT,
  email           TEXT,
  telefone        TEXT,
  ativo           BOOLEAN DEFAULT TRUE,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 8. CONTAS A RECEBER ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_receitas (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  descricao       TEXT NOT NULL,
  valor           NUMERIC(15,2) NOT NULL,
  vencimento      DATE NOT NULL,
  recebido_em     DATE,
  status          TEXT NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente','recebido','vencido','cancelado')),
  cliente_id      UUID REFERENCES fin_clientes(id),
  categoria_id    UUID REFERENCES fin_categorias(id),
  conta_id        UUID REFERENCES fin_contas(id), -- conta que recebeu
  parcela_atual   INT DEFAULT 1,
  total_parcelas  INT DEFAULT 1,
  grupo_parcela   UUID, -- agrupa parcelas do mesmo lançamento
  origem          TEXT DEFAULT 'manual' CHECK (origem IN ('manual','agenda_pro','documento_ia')),
  origem_ref      TEXT, -- ID externo (ex: id do agendamento no Agenda Pro)
  observacao      TEXT,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 9. CONTAS A PAGAR ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_despesas (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  descricao       TEXT NOT NULL,
  valor           NUMERIC(15,2) NOT NULL,
  vencimento      DATE NOT NULL,
  pago_em         DATE,
  status          TEXT NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente','pago','vencido','cancelado')),
  fornecedor_id   UUID REFERENCES fin_fornecedores(id),
  categoria_id    UUID REFERENCES fin_categorias(id),
  conta_id        UUID REFERENCES fin_contas(id), -- conta que pagou
  parcela_atual   INT DEFAULT 1,
  total_parcelas  INT DEFAULT 1,
  grupo_parcela   UUID,
  origem          TEXT DEFAULT 'manual' CHECK (origem IN ('manual','documento_ia')),
  observacao      TEXT,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 10. MOVIMENTAÇÕES (BAIXAS) ───────────────────────────────
CREATE TABLE IF NOT EXISTS fin_movimentacoes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  conta_id        UUID NOT NULL REFERENCES fin_contas(id),
  tipo            TEXT NOT NULL CHECK (tipo IN ('entrada','saida','transferencia')),
  valor           NUMERIC(15,2) NOT NULL,
  data            DATE NOT NULL,
  descricao       TEXT,
  receita_id      UUID REFERENCES fin_receitas(id),
  despesa_id      UUID REFERENCES fin_despesas(id),
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 11. TRANSFERÊNCIAS ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_transferencias (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  conta_origem_id UUID NOT NULL REFERENCES fin_contas(id),
  conta_destino_id UUID NOT NULL REFERENCES fin_contas(id),
  valor           NUMERIC(15,2) NOT NULL,
  data            DATE NOT NULL,
  descricao       TEXT,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 12. DOCUMENTOS PROCESSADOS PELA IA ──────────────────────
CREATE TABLE IF NOT EXISTS fin_documentos (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  nome_arquivo    TEXT NOT NULL,
  tipo            TEXT NOT NULL CHECK (tipo IN ('extrato_ofx','extrato_pdf','nota_fiscal_xml','nota_fiscal_pdf','boleto','comprovante')),
  status          TEXT NOT NULL DEFAULT 'processando' CHECK (status IN ('processando','processado','parcial','falhou','timeout')),
  lancamentos_json JSONB, -- prévia dos lançamentos extraídos pela IA
  confirmado      BOOLEAN DEFAULT FALSE,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 13. MÓDULO PESSOAL ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_pessoal (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id      UUID NOT NULL, -- auth.users.id
  descricao       TEXT NOT NULL,
  valor           NUMERIC(15,2) NOT NULL,
  tipo            TEXT NOT NULL CHECK (tipo IN ('receita','despesa')),
  categoria       TEXT,
  data            DATE NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente','concluido','cancelado')),
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);

-- ── 14. CONFIGURAÇÕES ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fin_config (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID NOT NULL REFERENCES fin_tenants(id) ON DELETE CASCADE,
  chave           TEXT NOT NULL,
  valor           TEXT,
  categoria       TEXT DEFAULT 'geral',
  UNIQUE(tenant_id, chave)
);

-- ============================================================
-- RLS — ROW LEVEL SECURITY
-- Isolamento total por tenant + pessoal por usuário
-- ============================================================

-- Habilitar RLS em todas as tabelas
ALTER TABLE fin_tenants        ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_usuarios       ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_convites       ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_contas         ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_categorias     ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_clientes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_fornecedores   ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_receitas       ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_despesas       ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_movimentacoes  ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_transferencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_documentos     ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_pessoal        ENABLE ROW LEVEL SECURITY;
ALTER TABLE fin_config         ENABLE ROW LEVEL SECURITY;

-- Função auxiliar: retorna tenant_id do usuário autenticado
CREATE OR REPLACE FUNCTION fin_tenant_id()
RETURNS UUID AS $$
  SELECT tenant_id FROM fin_usuarios WHERE auth_id = auth.uid() LIMIT 1;
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- Políticas: tabelas com tenant_id
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'fin_contas','fin_categorias','fin_clientes','fin_fornecedores',
    'fin_receitas','fin_despesas','fin_movimentacoes','fin_transferencias',
    'fin_documentos','fin_config','fin_convites'
  ] LOOP
    EXECUTE format('CREATE POLICY "tenant_iso" ON %I USING (tenant_id = fin_tenant_id())', t);
    EXECUTE format('CREATE POLICY "tenant_iso_insert" ON %I FOR INSERT WITH CHECK (tenant_id = fin_tenant_id())', t);
  END LOOP;
END $$;

-- Política: fin_tenants (usuário vê só o seu tenant)
CREATE POLICY "tenant_self" ON fin_tenants
  USING (id = fin_tenant_id());

-- Política: fin_usuarios (vê usuários do mesmo tenant)
CREATE POLICY "usuarios_tenant" ON fin_usuarios
  USING (tenant_id = fin_tenant_id());
CREATE POLICY "usuarios_tenant_insert" ON fin_usuarios
  FOR INSERT WITH CHECK (tenant_id = fin_tenant_id());

-- Política: fin_pessoal (só o próprio usuário vê)
CREATE POLICY "pessoal_proprio" ON fin_pessoal
  USING (usuario_id = auth.uid());
CREATE POLICY "pessoal_proprio_insert" ON fin_pessoal
  FOR INSERT WITH CHECK (usuario_id = auth.uid());

-- ============================================================
-- ÍNDICES — performance nas queries mais comuns
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_fin_usuarios_auth_id    ON fin_usuarios(auth_id);
CREATE INDEX IF NOT EXISTS idx_fin_usuarios_tenant     ON fin_usuarios(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fin_receitas_tenant     ON fin_receitas(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fin_receitas_status     ON fin_receitas(status);
CREATE INDEX IF NOT EXISTS idx_fin_receitas_vencimento ON fin_receitas(vencimento);
CREATE INDEX IF NOT EXISTS idx_fin_despesas_tenant     ON fin_despesas(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fin_despesas_status     ON fin_despesas(status);
CREATE INDEX IF NOT EXISTS idx_fin_despesas_vencimento ON fin_despesas(vencimento);
CREATE INDEX IF NOT EXISTS idx_fin_movimentacoes_conta ON fin_movimentacoes(conta_id);
CREATE INDEX IF NOT EXISTS idx_fin_pessoal_usuario     ON fin_pessoal(usuario_id);

-- ============================================================
-- TRIGGER — atualiza saldo da conta automaticamente
-- ============================================================
CREATE OR REPLACE FUNCTION fin_atualizar_saldo()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.tipo = 'entrada' THEN
      UPDATE fin_contas SET saldo_atual = saldo_atual + NEW.valor WHERE id = NEW.conta_id;
    ELSIF NEW.tipo = 'saida' THEN
      UPDATE fin_contas SET saldo_atual = saldo_atual - NEW.valor WHERE id = NEW.conta_id;
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.tipo = 'entrada' THEN
      UPDATE fin_contas SET saldo_atual = saldo_atual - OLD.valor WHERE id = OLD.conta_id;
    ELSIF OLD.tipo = 'saida' THEN
      UPDATE fin_contas SET saldo_atual = saldo_atual + OLD.valor WHERE id = OLD.conta_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER fin_saldo_trigger
  AFTER INSERT OR DELETE ON fin_movimentacoes
  FOR EACH ROW EXECUTE FUNCTION fin_atualizar_saldo();

-- ============================================================
-- TRIGGER — atualiza status para "vencido" automaticamente
-- ============================================================
CREATE OR REPLACE FUNCTION fin_atualizar_vencidos()
RETURNS void AS $$
BEGIN
  UPDATE fin_receitas SET status = 'vencido'
    WHERE status = 'pendente' AND vencimento < CURRENT_DATE;
  UPDATE fin_despesas SET status = 'vencido'
    WHERE status = 'pendente' AND vencimento < CURRENT_DATE;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- CATEGORIAS PADRÃO (inserir após criar o primeiro tenant)
-- Execute este bloco separadamente passando o tenant_id real
-- ============================================================
-- INSERT INTO fin_categorias (tenant_id, nome, tipo, cor, icone, padrao) VALUES
--   ('SEU_TENANT_ID', 'Honorários',      'receita',  '#16A34A', '💼', true),
--   ('SEU_TENANT_ID', 'Consultoria',     'receita',  '#2563EB', '🧠', true),
--   ('SEU_TENANT_ID', 'Vendas',          'receita',  '#7C3AED', '🛒', true),
--   ('SEU_TENANT_ID', 'Outros (receita)','receita',  '#6B7280', '💰', true),
--   ('SEU_TENANT_ID', 'Aluguel',         'despesa',  '#DC2626', '🏢', true),
--   ('SEU_TENANT_ID', 'Salários',        'despesa',  '#D97706', '👤', true),
--   ('SEU_TENANT_ID', 'Impostos',        'despesa',  '#9D174D', '📋', true),
--   ('SEU_TENANT_ID', 'Fornecedores',    'despesa',  '#B45309', '📦', true),
--   ('SEU_TENANT_ID', 'Marketing',       'despesa',  '#0891B2', '📣', true),
--   ('SEU_TENANT_ID', 'Tecnologia',      'despesa',  '#4F46E5', '💻', true),
--   ('SEU_TENANT_ID', 'Outros (despesa)','despesa',  '#6B7280', '💸', true);
