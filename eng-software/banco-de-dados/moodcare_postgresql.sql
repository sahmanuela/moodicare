-- ============================================================================
-- MOODCARE - SCHEMA DO BANCO DE DADOS PostgreSQL
-- ============================================================================
-- Aplicativo de acompanhamento de humor e medicamentos
-- Versão: 3.0 (PostgreSQL) - Corrigida após 10 revisões
-- Data: Novembro 2025
-- ============================================================================

-- Extensões necessárias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- TIPOS ENUMERADOS (ENUMs)
-- ============================================================================

CREATE TYPE genero_tipo AS ENUM (
    'masculino', 
    'feminino', 
    'nao_binario', 
    'prefiro_nao_opinar', 
    'outro'
);

CREATE TYPE categoria_genero_tipo AS ENUM ('masculino', 'feminino', 'neutro');

CREATE TYPE verificacao_tipo AS ENUM (
    'verificacao_email', 
    'alteracao_email', 
    'reset_senha'
);

CREATE TYPE forma_farmaceutica_tipo AS ENUM (
    'comprimido', 
    'capsula', 
    'gotas', 
    'liquido', 
    'injetavel', 
    'outro'
);

CREATE TYPE modo_uso_tipo AS ENUM (
    'todos_dias',
    'intervalos_regulares',
    'dias_semana',
    'ciclos',
    'quando_necessario'
);

CREATE TYPE intervalo_tipo AS ENUM ('horas', 'dias');

CREATE TYPE medicamento_status AS ENUM ('ativo', 'suspenso', 'excluido');

CREATE TYPE dose_status AS ENUM (
    'pendente', 
    'nao_registrada', 
    'tomada', 
    'ignorada', 
    'adiada'
);

CREATE TYPE sentimento_tipo AS ENUM ('pre_definido', 'customizado');

CREATE TYPE sentimento_categoria AS ENUM ('ativo', 'oculto');

CREATE TYPE sentimento_acao AS ENUM (
    'criado', 
    'editado', 
    'ocultado', 
    'ativado', 
    'removido'
);

CREATE TYPE dose_esquecida_delay_tipo AS ENUM (
    '30min', '1h', '2h', '3h', '6h', '12h', '24h'
);

CREATE TYPE notificacao_tipo AS ENUM (
    'lembrete_dose',
    'dose_esquecida',
    'estoque_baixo',
    'lembrete_sair',
    'lembrete_humor',
    'dose_adiada'
);

CREATE TYPE notificacao_acao AS ENUM (
    'tomado', 
    'ignorado', 
    'adiado', 
    'visualizado'
);

CREATE TYPE contato_status AS ENUM (
    'pendente', 
    'em_analise', 
    'respondida', 
    'arquivada'
);

CREATE TYPE plataforma_tipo AS ENUM ('ios', 'android', 'web');

-- ============================================================================
-- FUNÇÕES DE VALIDAÇÃO (criadas antes das tabelas)
-- ============================================================================

-- Valida que array JSONB contém apenas valores 0-6 (dias da semana)
CREATE OR REPLACE FUNCTION fn_validar_dias_semana(p_dias JSONB)
RETURNS BOOLEAN AS $$
DECLARE
    v_elem JSONB;
BEGIN
    IF p_dias IS NULL THEN
        RETURN TRUE;
    END IF;
    
    IF jsonb_typeof(p_dias) != 'array' THEN
        RETURN FALSE;
    END IF;
    
    FOR v_elem IN SELECT jsonb_array_elements(p_dias)
    LOOP
        IF jsonb_typeof(v_elem) != 'number' OR 
           (v_elem::INTEGER < 0 OR v_elem::INTEGER > 6) THEN
            RETURN FALSE;
        END IF;
    END LOOP;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- TABELAS DE USUÁRIO E AUTENTICAÇÃO
-- ============================================================================

CREATE TABLE avatares (
    id SERIAL PRIMARY KEY,
    nome VARCHAR(100) NOT NULL,
    url_imagem VARCHAR(500) NOT NULL,
    categoria_genero categoria_genero_tipo NOT NULL DEFAULT 'neutro',
    ordem_exibicao INTEGER NOT NULL DEFAULT 0,
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_avatares_categoria_ordem ON avatares(categoria_genero, ordem_exibicao) 
    WHERE ativo = TRUE;

COMMENT ON TABLE avatares IS 'Galeria de avatares pré-definidos para perfil do usuário';

-- ----------------------------------------------------------------------------
-- Tabela: usuarios
-- CORREÇÃO: Índices únicos parciais para permitir reutilização após soft delete
-- ----------------------------------------------------------------------------
CREATE TABLE usuarios (
    id SERIAL PRIMARY KEY,
    
    -- Dados de autenticação
    username VARCHAR(50) NOT NULL,
    email VARCHAR(255) NOT NULL,
    email_verificado BOOLEAN NOT NULL DEFAULT FALSE,
    senha_hash VARCHAR(255), -- NULL se login apenas por Google (usar bcrypt!)
    google_id VARCHAR(255),
    
    -- Dados de perfil
    avatar_id INTEGER REFERENCES avatares(id) ON DELETE SET NULL,
    nome_completo VARCHAR(255) NOT NULL,
    apelido VARCHAR(100) NOT NULL,
    data_nascimento DATE,
    genero genero_tipo,
    genero_outro VARCHAR(100),
    
    -- Controle
    ultimo_login TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    
    -- CORREÇÃO: Validações
    CONSTRAINT chk_data_nascimento CHECK (data_nascimento <= CURRENT_DATE),
    CONSTRAINT chk_genero_outro CHECK (
        (genero != 'outro' AND genero_outro IS NULL) OR
        (genero = 'outro') OR
        (genero IS NULL)
    )
);

-- CORREÇÃO: Índices únicos parciais (permitem reutilização após soft delete)
CREATE UNIQUE INDEX uk_usuarios_username ON usuarios(username) 
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uk_usuarios_email ON usuarios(email) 
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uk_usuarios_google_id ON usuarios(google_id) 
    WHERE google_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX idx_usuarios_ativos ON usuarios(id) 
    WHERE deleted_at IS NULL;

COMMENT ON TABLE usuarios IS 'Usuários do aplicativo';

-- ----------------------------------------------------------------------------
CREATE TABLE codigos_verificacao (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo verificacao_tipo NOT NULL,
    codigo CHAR(4) NOT NULL,
    email_destino VARCHAR(255) NOT NULL,
    expira_em TIMESTAMPTZ NOT NULL,
    usado BOOLEAN NOT NULL DEFAULT FALSE,
    tentativas SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_tentativas CHECK (tentativas >= 0 AND tentativas <= 5),
    CONSTRAINT chk_codigo_numerico CHECK (codigo ~ '^[0-9]{4}$')
);

CREATE INDEX idx_codigos_user_tipo ON codigos_verificacao(user_id, tipo);
CREATE INDEX idx_codigos_codigo_email ON codigos_verificacao(codigo, email_destino);
CREATE INDEX idx_codigos_expira ON codigos_verificacao(expira_em) WHERE usado = FALSE;
CREATE INDEX idx_codigos_limpeza ON codigos_verificacao(expira_em, usado);

COMMENT ON TABLE codigos_verificacao IS 'Códigos de verificação temporários (15 min)';

-- ============================================================================
-- TABELAS DE MEDICAMENTOS
-- ============================================================================

CREATE TABLE medicamentos (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    
    -- Etapa 1: Informações básicas
    -- CORREÇÃO: DECIMAL(10,4) para suportar concentrações pequenas como mcg
    nome VARCHAR(255) NOT NULL,
    concentracao DECIMAL(10,4) NOT NULL,
    unidade_concentracao VARCHAR(20) NOT NULL,
    forma_farmaceutica forma_farmaceutica_tipo NOT NULL,
    observacoes TEXT,
    
    -- Etapa 2: Modo de uso
    modo_uso modo_uso_tipo NOT NULL,
    
    -- Para modo "intervalos_regulares"
    intervalo_tipo intervalo_tipo,
    intervalo_valor INTEGER,
    
    -- Para modo "dias_semana" (0=Dom, 1=Seg, ..., 6=Sab)
    dias_semana JSONB,
    
    -- Para modo "ciclos"
    ciclo_dias_uso INTEGER,
    ciclo_dias_pausa INTEGER,
    ciclo_inicio DATE,
    
    -- Etapa 4: Duração do tratamento
    data_inicio DATE NOT NULL,
    data_termino DATE,
    uso_continuo BOOLEAN NOT NULL DEFAULT FALSE,
    
    -- Etapa 5: Controle de estoque
    -- CORREÇÃO: CHECKs para valores não negativos
    controle_estoque_ativo BOOLEAN NOT NULL DEFAULT FALSE,
    estoque_quantidade INTEGER,
    estoque_alerta_em INTEGER,
    
    -- Status e controle
    status medicamento_status NOT NULL DEFAULT 'ativo',
    data_suspensao TIMESTAMPTZ,
    motivo_suspensao VARCHAR(255),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    
    -- Validações
    CONSTRAINT chk_concentracao_positiva CHECK (concentracao > 0),
    CONSTRAINT chk_intervalo CHECK (
        (modo_uso != 'intervalos_regulares') OR 
        (intervalo_tipo IS NOT NULL AND intervalo_valor > 0)
    ),
    -- CORREÇÃO: Validação de dias_semana com função
    CONSTRAINT chk_dias_semana CHECK (
        (modo_uso != 'dias_semana') OR 
        (dias_semana IS NOT NULL AND jsonb_array_length(dias_semana) > 0 AND fn_validar_dias_semana(dias_semana))
    ),
    CONSTRAINT chk_ciclos CHECK (
        (modo_uso != 'ciclos') OR 
        (ciclo_dias_uso > 0 AND ciclo_dias_pausa >= 0 AND ciclo_inicio IS NOT NULL)
    ),
    -- CORREÇÃO: CHECK para valores não negativos de estoque
    CONSTRAINT chk_estoque CHECK (
        (controle_estoque_ativo = FALSE) OR 
        (estoque_quantidade IS NOT NULL AND estoque_quantidade >= 0 AND 
         estoque_alerta_em IS NOT NULL AND estoque_alerta_em >= 0)
    ),
    CONSTRAINT chk_duracao CHECK (
        uso_continuo = TRUE OR data_termino IS NULL OR data_termino >= data_inicio
    )
);

CREATE INDEX idx_medicamentos_user_status ON medicamentos(user_id, status) 
    WHERE deleted_at IS NULL;
CREATE INDEX idx_medicamentos_modo_uso ON medicamentos(modo_uso) 
    WHERE status = 'ativo' AND deleted_at IS NULL;

-- CORREÇÃO: Índice funcional para estoque baixo (sem comparar colunas)
CREATE INDEX idx_medicamentos_com_estoque ON medicamentos(user_id, estoque_quantidade, estoque_alerta_em)
    WHERE controle_estoque_ativo = TRUE AND status = 'ativo' AND deleted_at IS NULL;

COMMENT ON TABLE medicamentos IS 'Medicamentos cadastrados pelo usuário';

-- ----------------------------------------------------------------------------
CREATE TABLE horarios_medicamento (
    id SERIAL PRIMARY KEY,
    medicamento_id INTEGER NOT NULL REFERENCES medicamentos(id) ON DELETE CASCADE,
    horario TIME NOT NULL,
    quantidade DECIMAL(5,2) NOT NULL,
    unidade VARCHAR(50) NOT NULL,
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    ordem SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_quantidade_positiva CHECK (quantidade > 0)
);

CREATE INDEX idx_horarios_medicamento_ativo ON horarios_medicamento(medicamento_id) 
    WHERE ativo = TRUE;
CREATE INDEX idx_horarios_horario ON horarios_medicamento(horario);

-- Índice único para evitar horários duplicados no mesmo medicamento
CREATE UNIQUE INDEX uk_horarios_medicamento ON horarios_medicamento(medicamento_id, horario)
    WHERE ativo = TRUE;

COMMENT ON TABLE horarios_medicamento IS 'Horários programados para cada medicamento';

-- ----------------------------------------------------------------------------
CREATE TABLE registros_dose (
    id SERIAL PRIMARY KEY,
    medicamento_id INTEGER NOT NULL REFERENCES medicamentos(id) ON DELETE CASCADE,
    horario_medicamento_id INTEGER REFERENCES horarios_medicamento(id) ON DELETE SET NULL,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    
    -- Agendamento
    data_programada DATE NOT NULL,
    hora_programada TIME NOT NULL,
    quantidade_programada DECIMAL(5,2) NOT NULL,
    unidade VARCHAR(50) NOT NULL,
    
    -- Registro real
    status dose_status NOT NULL DEFAULT 'pendente',
    data_hora_real TIMESTAMPTZ,
    quantidade_real DECIMAL(5,2),
    
    -- Para doses adiadas
    adiada_para_data DATE,
    adiada_para_hora TIME,
    
    -- Controle
    dose_extra BOOLEAN NOT NULL DEFAULT FALSE,
    estoque_decrementado BOOLEAN NOT NULL DEFAULT FALSE,
    observacao TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_quantidade_programada CHECK (quantidade_programada > 0),
    CONSTRAINT chk_quantidade_real CHECK (quantidade_real IS NULL OR quantidade_real > 0),
    CONSTRAINT chk_adiamento CHECK (
        (status != 'adiada') OR 
        (adiada_para_data IS NOT NULL AND adiada_para_hora IS NOT NULL)
    ),
    -- Nova validação: se tomada, deve ter data_hora_real
    CONSTRAINT chk_tomada CHECK (
        (status != 'tomada') OR (data_hora_real IS NOT NULL)
    )
);

CREATE INDEX idx_doses_medicamento_data ON registros_dose(medicamento_id, data_programada);
CREATE INDEX idx_doses_user_data ON registros_dose(user_id, data_programada);
CREATE INDEX idx_doses_status ON registros_dose(status);

-- CORREÇÃO: Índice para doses pendentes (sem CURRENT_DATE volátil)
CREATE INDEX idx_doses_pendentes ON registros_dose(user_id, data_programada, hora_programada) 
    WHERE status = 'pendente';

-- CORREÇÃO: Índice para doses adiadas no dia de destino
CREATE INDEX idx_doses_adiadas_destino ON registros_dose(user_id, adiada_para_data, adiada_para_hora) 
    WHERE status = 'adiada';

CREATE UNIQUE INDEX uk_doses_programadas ON registros_dose(
    medicamento_id, horario_medicamento_id, data_programada
) WHERE dose_extra = FALSE AND horario_medicamento_id IS NOT NULL;

COMMENT ON TABLE registros_dose IS 'Histórico de doses de medicamentos';

-- ============================================================================
-- TABELAS DE HUMOR E SENTIMENTOS
-- ============================================================================

CREATE TABLE sentimentos (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    nome VARCHAR(50) NOT NULL,
    tipo sentimento_tipo NOT NULL DEFAULT 'customizado',
    categoria sentimento_categoria NOT NULL DEFAULT 'ativo',
    ordem_exibicao INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX uk_sentimentos_user_nome ON sentimentos(user_id, LOWER(nome)) 
    WHERE deleted_at IS NULL;

CREATE INDEX idx_sentimentos_user_categoria ON sentimentos(user_id, categoria) 
    WHERE deleted_at IS NULL;
CREATE INDEX idx_sentimentos_user_ordem ON sentimentos(user_id, ordem_exibicao)
    WHERE deleted_at IS NULL;

COMMENT ON TABLE sentimentos IS 'Sentimentos disponíveis para registro de humor';

-- ----------------------------------------------------------------------------
CREATE TABLE historico_sentimentos (
    id SERIAL PRIMARY KEY,
    sentimento_id INTEGER NOT NULL REFERENCES sentimentos(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    acao sentimento_acao NOT NULL,
    nome_anterior VARCHAR(50),
    nome_novo VARCHAR(50),
    historico_mantido BOOLEAN,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_hist_sent_sentimento ON historico_sentimentos(sentimento_id);
CREATE INDEX idx_hist_sent_user_acao ON historico_sentimentos(user_id, acao);

COMMENT ON TABLE historico_sentimentos IS 'Histórico de alterações em sentimentos';

-- ----------------------------------------------------------------------------
CREATE TABLE registros_humor (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    intensidade SMALLINT NOT NULL,
    data_hora TIMESTAMPTZ NOT NULL,
    anotacao VARCHAR(500),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_intensidade CHECK (intensidade BETWEEN 1 AND 10)
);

CREATE INDEX idx_humor_user_data ON registros_humor(user_id, data_hora DESC);
CREATE INDEX idx_humor_intensidade ON registros_humor(intensidade);
CREATE INDEX idx_humor_data ON registros_humor(data_hora::DATE);

COMMENT ON TABLE registros_humor IS 'Registros de humor do usuário';

-- ----------------------------------------------------------------------------
-- CORREÇÃO: ON DELETE RESTRICT para manter integridade do histórico
CREATE TABLE registros_humor_sentimentos (
    id SERIAL PRIMARY KEY,
    registro_humor_id INTEGER NOT NULL REFERENCES registros_humor(id) ON DELETE CASCADE,
    sentimento_id INTEGER NOT NULL REFERENCES sentimentos(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT uk_registro_sentimento UNIQUE (registro_humor_id, sentimento_id)
);

CREATE INDEX idx_rhs_sentimento ON registros_humor_sentimentos(sentimento_id);

COMMENT ON TABLE registros_humor_sentimentos IS 'Relacionamento N:N entre registros de humor e sentimentos';

-- ============================================================================
-- TABELAS DE NOTIFICAÇÕES E PREFERÊNCIAS
-- ============================================================================

CREATE TABLE preferencias_notificacao (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    
    lembretes_medicamentos BOOLEAN NOT NULL DEFAULT TRUE,
    
    dose_esquecida BOOLEAN NOT NULL DEFAULT TRUE,
    dose_esquecida_delay dose_esquecida_delay_tipo NOT NULL DEFAULT '2h',
    
    mostrar_nome_medicamento BOOLEAN NOT NULL DEFAULT TRUE,
    
    lembrete_sair BOOLEAN NOT NULL DEFAULT FALSE,
    lembrete_sair_horario TIME NOT NULL DEFAULT '08:00:00',
    
    lembrete_humor BOOLEAN NOT NULL DEFAULT FALSE,
    lembrete_humor_horario TIME,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT uk_prefs_user UNIQUE (user_id)
);

COMMENT ON TABLE preferencias_notificacao IS 'Preferências de notificação do usuário';

-- ----------------------------------------------------------------------------
-- Considerar particionamento por data para esta tabela em produção
CREATE TABLE notificacoes (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo notificacao_tipo NOT NULL,
    
    medicamento_id INTEGER REFERENCES medicamentos(id) ON DELETE SET NULL,
    registro_dose_id INTEGER REFERENCES registros_dose(id) ON DELETE SET NULL,
    
    titulo VARCHAR(255) NOT NULL,
    mensagem TEXT NOT NULL,
    
    agendada_para TIMESTAMPTZ NOT NULL,
    enviada BOOLEAN NOT NULL DEFAULT FALSE,
    enviada_em TIMESTAMPTZ,
    lida BOOLEAN NOT NULL DEFAULT FALSE,
    lida_em TIMESTAMPTZ,
    
    acao_tomada notificacao_acao,
    acao_em TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notif_user_enviada ON notificacoes(user_id, enviada);
CREATE INDEX idx_notif_user_lida ON notificacoes(user_id, lida);
CREATE INDEX idx_notif_agendada ON notificacoes(agendada_para) WHERE enviada = FALSE;
CREATE INDEX idx_notif_tipo ON notificacoes(tipo);
CREATE INDEX idx_notif_created ON notificacoes(created_at);

COMMENT ON TABLE notificacoes IS 'Notificações enviadas e agendadas';

-- ============================================================================
-- TABELAS DE SUPORTE
-- ============================================================================

CREATE TABLE mensagens_contato (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    assunto VARCHAR(255) NOT NULL,
    mensagem TEXT NOT NULL,
    status contato_status NOT NULL DEFAULT 'pendente',
    respondida_em TIMESTAMPTZ,
    resposta TEXT,
    respondido_por VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT chk_assunto_nao_vazio CHECK (LENGTH(TRIM(assunto)) > 0),
    CONSTRAINT chk_mensagem_nao_vazia CHECK (LENGTH(TRIM(mensagem)) > 0)
);

CREATE INDEX idx_contato_user ON mensagens_contato(user_id);
CREATE INDEX idx_contato_status ON mensagens_contato(status);
CREATE INDEX idx_contato_created ON mensagens_contato(created_at DESC);

COMMENT ON TABLE mensagens_contato IS 'Mensagens do formulário de contato';

-- ============================================================================
-- TABELAS DE SESSÃO E TOKENS
-- ============================================================================

CREATE TABLE sessoes_usuario (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    token_hash VARCHAR(64) NOT NULL, -- Armazenar hash do token, não o token
    dispositivo VARCHAR(255),
    plataforma plataforma_tipo,
    ip_address INET,
    user_agent TEXT,
    ultimo_acesso TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expira_em TIMESTAMPTZ NOT NULL,
    ativa BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sessoes_user_ativa ON sessoes_usuario(user_id, ativa);
CREATE UNIQUE INDEX uk_sessoes_token ON sessoes_usuario(token_hash);
CREATE INDEX idx_sessoes_expira ON sessoes_usuario(expira_em) WHERE ativa = TRUE;

COMMENT ON TABLE sessoes_usuario IS 'Sessões ativas dos usuários';

-- ----------------------------------------------------------------------------
CREATE TABLE tokens_push (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    token VARCHAR(500) NOT NULL,
    plataforma plataforma_tipo NOT NULL,
    dispositivo_id VARCHAR(255),
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT uk_token_push UNIQUE (token)
);

CREATE INDEX idx_tokens_user_ativo ON tokens_push(user_id, ativo);
CREATE UNIQUE INDEX uk_tokens_user_dispositivo ON tokens_push(user_id, dispositivo_id) 
    WHERE dispositivo_id IS NOT NULL AND ativo = TRUE;

COMMENT ON TABLE tokens_push IS 'Tokens de push notification';

-- ============================================================================
-- DADOS INICIAIS (SEEDS)
-- ============================================================================

INSERT INTO avatares (nome, url_imagem, categoria_genero, ordem_exibicao) VALUES
('avatar_m_1', '/assets/avatars/male_1.png', 'masculino', 1),
('avatar_m_2', '/assets/avatars/male_2.png', 'masculino', 2),
('avatar_m_3', '/assets/avatars/male_3.png', 'masculino', 3),
('avatar_m_4', '/assets/avatars/male_4.png', 'masculino', 4),
('avatar_m_5', '/assets/avatars/male_5.png', 'masculino', 5),
('avatar_f_1', '/assets/avatars/female_1.png', 'feminino', 1),
('avatar_f_2', '/assets/avatars/female_2.png', 'feminino', 2),
('avatar_f_3', '/assets/avatars/female_3.png', 'feminino', 3),
('avatar_f_4', '/assets/avatars/female_4.png', 'feminino', 4),
('avatar_f_5', '/assets/avatars/female_5.png', 'feminino', 5),
('avatar_n_1', '/assets/avatars/neutral_1.png', 'neutro', 1),
('avatar_n_2', '/assets/avatars/neutral_2.png', 'neutro', 2),
('avatar_n_3', '/assets/avatars/neutral_3.png', 'neutro', 3),
('avatar_n_4', '/assets/avatars/neutral_4.png', 'neutro', 4),
('avatar_n_5', '/assets/avatars/neutral_5.png', 'neutro', 5);

-- ============================================================================
-- FUNÇÕES AUXILIARES
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_contar_sentimentos_ativos(p_user_id INTEGER)
RETURNS INTEGER AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)
        FROM sentimentos
        WHERE user_id = p_user_id 
          AND categoria = 'ativo'
          AND deleted_at IS NULL
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_obter_label_intensidade(p_intensidade SMALLINT)
RETURNS VARCHAR(10) AS $$
BEGIN
    RETURN CASE 
        WHEN p_intensidade BETWEEN 1 AND 2 THEN 'Péssimo'
        WHEN p_intensidade BETWEEN 3 AND 4 THEN 'Mau'
        WHEN p_intensidade BETWEEN 5 AND 6 THEN 'Neutro'
        WHEN p_intensidade BETWEEN 7 AND 8 THEN 'Bom'
        WHEN p_intensidade BETWEEN 9 AND 10 THEN 'Ótimo'
        ELSE 'Desconhecido'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_calcular_dia_ciclo(
    p_ciclo_inicio DATE,
    p_dias_uso INTEGER,
    p_dias_pausa INTEGER,
    p_data DATE
)
RETURNS INTEGER AS $$
DECLARE
    v_total_ciclo INTEGER;
    v_dias_desde_inicio INTEGER;
    v_posicao_no_ciclo INTEGER;
BEGIN
    IF p_ciclo_inicio IS NULL OR p_dias_uso IS NULL OR p_dias_pausa IS NULL THEN
        RETURN NULL;
    END IF;
    
    IF p_data < p_ciclo_inicio THEN
        RETURN NULL;
    END IF;
    
    v_total_ciclo := p_dias_uso + p_dias_pausa;
    
    IF v_total_ciclo = 0 THEN
        RETURN NULL;
    END IF;
    
    v_dias_desde_inicio := p_data - p_ciclo_inicio;
    v_posicao_no_ciclo := v_dias_desde_inicio % v_total_ciclo;
    
    IF v_posicao_no_ciclo < p_dias_uso THEN
        RETURN v_posicao_no_ciclo + 1;
    ELSE
        RETURN -(v_posicao_no_ciclo - p_dias_uso + 1);
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ----------------------------------------------------------------------------
-- CORREÇÃO: Função para verificar dia da semana em array JSONB
CREATE OR REPLACE FUNCTION fn_verificar_dia_semana(
    p_dias_semana JSONB,
    p_data DATE
)
RETURNS BOOLEAN AS $$
DECLARE
    v_dow INTEGER;
BEGIN
    IF p_dias_semana IS NULL THEN
        RETURN FALSE;
    END IF;
    
    -- EXTRACT(DOW FROM date) retorna 0=Dom, 1=Seg, ..., 6=Sab
    v_dow := EXTRACT(DOW FROM p_data)::INTEGER;
    
    -- CORREÇÃO: Usar @> para verificar se array contém o valor
    RETURN p_dias_semana @> to_jsonb(v_dow);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_converter_delay_minutos(p_delay dose_esquecida_delay_tipo)
RETURNS INTEGER AS $$
BEGIN
    RETURN CASE p_delay
        WHEN '30min' THEN 30
        WHEN '1h' THEN 60
        WHEN '2h' THEN 120
        WHEN '3h' THEN 180
        WHEN '6h' THEN 360
        WHEN '12h' THEN 720
        WHEN '24h' THEN 1440
        ELSE 120
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- STORED PROCEDURES
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_criar_sentimentos_padrao(p_user_id INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    -- Verifica se já existem sentimentos para este usuário
    IF EXISTS (SELECT 1 FROM sentimentos WHERE user_id = p_user_id LIMIT 1) THEN
        RETURN;
    END IF;

    -- Sentimentos ativos por padrão
    INSERT INTO sentimentos (user_id, nome, tipo, categoria, ordem_exibicao) VALUES
    (p_user_id, 'Feliz', 'pre_definido', 'ativo', 1),
    (p_user_id, 'Motivado', 'pre_definido', 'ativo', 2),
    (p_user_id, 'Calmo', 'pre_definido', 'ativo', 3),
    (p_user_id, 'Confiante', 'pre_definido', 'ativo', 4),
    (p_user_id, 'Orgulhoso', 'pre_definido', 'ativo', 5),
    (p_user_id, 'Inspirado', 'pre_definido', 'ativo', 6),
    (p_user_id, 'Neutro', 'pre_definido', 'ativo', 7),
    (p_user_id, 'Cansado', 'pre_definido', 'ativo', 8),
    (p_user_id, 'Ansioso', 'pre_definido', 'ativo', 9),
    (p_user_id, 'Triste', 'pre_definido', 'ativo', 10),
    (p_user_id, 'Irritado', 'pre_definido', 'ativo', 11),
    (p_user_id, 'Estressado', 'pre_definido', 'ativo', 12),
    (p_user_id, 'Exausto', 'pre_definido', 'ativo', 13),
    (p_user_id, 'Indiferente', 'pre_definido', 'ativo', 14);
    
    -- Sentimentos ocultos por padrão
    INSERT INTO sentimentos (user_id, nome, tipo, categoria, ordem_exibicao) VALUES
    (p_user_id, 'Animado', 'pre_definido', 'oculto', 15),
    (p_user_id, 'Grato', 'pre_definido', 'oculto', 16),
    (p_user_id, 'Esperançoso', 'pre_definido', 'oculto', 17),
    (p_user_id, 'Relaxado', 'pre_definido', 'oculto', 18),
    (p_user_id, 'Satisfeito', 'pre_definido', 'oculto', 19),
    (p_user_id, 'Pensativo', 'pre_definido', 'oculto', 20),
    (p_user_id, 'Desmotivado', 'pre_definido', 'oculto', 21),
    (p_user_id, 'Solitário', 'pre_definido', 'oculto', 22),
    (p_user_id, 'Perdido', 'pre_definido', 'oculto', 23),
    (p_user_id, 'Frustrado', 'pre_definido', 'oculto', 24),
    (p_user_id, 'Decepcionado', 'pre_definido', 'oculto', 25),
    (p_user_id, 'Inseguro', 'pre_definido', 'oculto', 26),
    (p_user_id, 'Sobrecarregado', 'pre_definido', 'oculto', 27),
    (p_user_id, 'Confuso', 'pre_definido', 'oculto', 28);
END;
$$;

-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_criar_preferencias_padrao(p_user_id INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO preferencias_notificacao (
        user_id, 
        lembretes_medicamentos,
        dose_esquecida,
        dose_esquecida_delay,
        mostrar_nome_medicamento,
        lembrete_sair,
        lembrete_sair_horario,
        lembrete_humor
    ) VALUES (
        p_user_id,
        TRUE,
        TRUE,
        '2h',
        TRUE,
        FALSE,
        '08:00:00',
        FALSE
    )
    ON CONFLICT (user_id) DO NOTHING;
END;
$$;

-- ----------------------------------------------------------------------------
-- CORREÇÃO: Verifica deleted_at IS NULL nos medicamentos
CREATE OR REPLACE PROCEDURE sp_gerar_doses_dia(
    p_user_id INTEGER,
    p_data DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    -- 1. Medicamentos com modo "todos_dias"
    INSERT INTO registros_dose (
        medicamento_id, horario_medicamento_id, user_id,
        data_programada, hora_programada, quantidade_programada, unidade
    )
    SELECT 
        m.id,
        hm.id,
        m.user_id,
        p_data,
        hm.horario,
        hm.quantidade,
        hm.unidade
    FROM medicamentos m
    INNER JOIN horarios_medicamento hm ON hm.medicamento_id = m.id AND hm.ativo = TRUE
    WHERE m.user_id = p_user_id
      AND m.status = 'ativo'
      AND m.deleted_at IS NULL  -- CORREÇÃO
      AND m.modo_uso = 'todos_dias'
      AND m.data_inicio <= p_data
      AND (m.data_termino IS NULL OR m.data_termino >= p_data)
      AND NOT EXISTS (
          SELECT 1 FROM registros_dose rd 
          WHERE rd.medicamento_id = m.id 
            AND rd.horario_medicamento_id = hm.id
            AND rd.data_programada = p_data
            AND rd.dose_extra = FALSE
      );
    
    -- 2. Medicamentos com "dias_semana" específicos
    INSERT INTO registros_dose (
        medicamento_id, horario_medicamento_id, user_id,
        data_programada, hora_programada, quantidade_programada, unidade
    )
    SELECT 
        m.id,
        hm.id,
        m.user_id,
        p_data,
        hm.horario,
        hm.quantidade,
        hm.unidade
    FROM medicamentos m
    INNER JOIN horarios_medicamento hm ON hm.medicamento_id = m.id AND hm.ativo = TRUE
    WHERE m.user_id = p_user_id
      AND m.status = 'ativo'
      AND m.deleted_at IS NULL  -- CORREÇÃO
      AND m.modo_uso = 'dias_semana'
      AND m.data_inicio <= p_data
      AND (m.data_termino IS NULL OR m.data_termino >= p_data)
      AND fn_verificar_dia_semana(m.dias_semana, p_data)
      AND NOT EXISTS (
          SELECT 1 FROM registros_dose rd 
          WHERE rd.medicamento_id = m.id 
            AND rd.horario_medicamento_id = hm.id
            AND rd.data_programada = p_data
            AND rd.dose_extra = FALSE
      );
    
    -- 3. Medicamentos com modo "ciclos" (apenas se em período de uso)
    INSERT INTO registros_dose (
        medicamento_id, horario_medicamento_id, user_id,
        data_programada, hora_programada, quantidade_programada, unidade
    )
    SELECT 
        m.id,
        hm.id,
        m.user_id,
        p_data,
        hm.horario,
        hm.quantidade,
        hm.unidade
    FROM medicamentos m
    INNER JOIN horarios_medicamento hm ON hm.medicamento_id = m.id AND hm.ativo = TRUE
    WHERE m.user_id = p_user_id
      AND m.status = 'ativo'
      AND m.deleted_at IS NULL  -- CORREÇÃO
      AND m.modo_uso = 'ciclos'
      AND m.data_inicio <= p_data
      AND (m.data_termino IS NULL OR m.data_termino >= p_data)
      AND fn_calcular_dia_ciclo(m.ciclo_inicio, m.ciclo_dias_uso, m.ciclo_dias_pausa, p_data) > 0
      AND NOT EXISTS (
          SELECT 1 FROM registros_dose rd 
          WHERE rd.medicamento_id = m.id 
            AND rd.horario_medicamento_id = hm.id
            AND rd.data_programada = p_data
            AND rd.dose_extra = FALSE
      );
    
    -- 4. Medicamentos com modo "intervalos_regulares" em dias
    INSERT INTO registros_dose (
        medicamento_id, horario_medicamento_id, user_id,
        data_programada, hora_programada, quantidade_programada, unidade
    )
    SELECT 
        m.id,
        hm.id,
        m.user_id,
        p_data,
        hm.horario,
        hm.quantidade,
        hm.unidade
    FROM medicamentos m
    INNER JOIN horarios_medicamento hm ON hm.medicamento_id = m.id AND hm.ativo = TRUE
    WHERE m.user_id = p_user_id
      AND m.status = 'ativo'
      AND m.deleted_at IS NULL  -- CORREÇÃO
      AND m.modo_uso = 'intervalos_regulares'
      AND m.intervalo_tipo = 'dias'
      AND m.data_inicio <= p_data
      AND (m.data_termino IS NULL OR m.data_termino >= p_data)
      AND MOD((p_data - m.data_inicio), m.intervalo_valor) = 0
      AND NOT EXISTS (
          SELECT 1 FROM registros_dose rd 
          WHERE rd.medicamento_id = m.id 
            AND rd.horario_medicamento_id = hm.id
            AND rd.data_programada = p_data
            AND rd.dose_extra = FALSE
      );
END;
$$;

-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_atualizar_doses_nao_registradas(
    p_tolerancia_minutos INTEGER DEFAULT 120
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE registros_dose
    SET status = 'nao_registrada',
        updated_at = NOW()
    WHERE status = 'pendente'
      AND (data_programada + hora_programada) < (NOW() - (p_tolerancia_minutos || ' minutes')::INTERVAL);
END;
$$;

-- ----------------------------------------------------------------------------
-- NOVA: Procedure para gerar doses em intervalos de horas
CREATE OR REPLACE PROCEDURE sp_gerar_doses_intervalo_horas(
    p_user_id INTEGER,
    p_data DATE,
    p_hora_atual TIME DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_med RECORD;
    v_hora_atual TIME;
    v_ultima_dose TIMESTAMPTZ;
    v_proxima_dose TIMESTAMPTZ;
    v_hora_inicial TIME;
BEGIN
    v_hora_atual := COALESCE(p_hora_atual, CURRENT_TIME);
    
    FOR v_med IN 
        SELECT m.*, hm.id as hm_id, hm.horario as hora_base, hm.quantidade, hm.unidade
        FROM medicamentos m
        INNER JOIN horarios_medicamento hm ON hm.medicamento_id = m.id AND hm.ativo = TRUE
        WHERE m.user_id = p_user_id
          AND m.status = 'ativo'
          AND m.deleted_at IS NULL
          AND m.modo_uso = 'intervalos_regulares'
          AND m.intervalo_tipo = 'horas'
          AND m.data_inicio <= p_data
          AND (m.data_termino IS NULL OR m.data_termino >= p_data)
    LOOP
        -- Encontra última dose registrada
        SELECT MAX(data_programada + hora_programada)
        INTO v_ultima_dose
        FROM registros_dose
        WHERE medicamento_id = v_med.id
          AND dose_extra = FALSE;
        
        -- Se nunca teve dose, usa data_inicio + horario base
        IF v_ultima_dose IS NULL THEN
            v_ultima_dose := v_med.data_inicio + v_med.hora_base;
        END IF;
        
        -- Gera próximas doses até hora atual
        v_proxima_dose := v_ultima_dose + (v_med.intervalo_valor || ' hours')::INTERVAL;
        
        WHILE v_proxima_dose <= (p_data + v_hora_atual) LOOP
            -- Insere dose se ainda não existe
            INSERT INTO registros_dose (
                medicamento_id, horario_medicamento_id, user_id,
                data_programada, hora_programada, quantidade_programada, unidade
            )
            SELECT 
                v_med.id,
                v_med.hm_id,
                v_med.user_id,
                v_proxima_dose::DATE,
                v_proxima_dose::TIME,
                v_med.quantidade,
                v_med.unidade
            WHERE NOT EXISTS (
                SELECT 1 FROM registros_dose 
                WHERE medicamento_id = v_med.id
                  AND data_programada = v_proxima_dose::DATE
                  AND hora_programada = v_proxima_dose::TIME
                  AND dose_extra = FALSE
            );
            
            v_proxima_dose := v_proxima_dose + (v_med.intervalo_valor || ' hours')::INTERVAL;
        END LOOP;
    END LOOP;
END;
$$;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE OR REPLACE FUNCTION trg_fn_after_usuario_insert()
RETURNS TRIGGER AS $$
BEGIN
    -- Executa em bloco protegido
    BEGIN
        CALL sp_criar_sentimentos_padrao(NEW.id);
        CALL sp_criar_preferencias_padrao(NEW.id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Erro ao criar dados padrão para usuário %: %', NEW.id, SQLERRM;
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_usuario_insert
AFTER INSERT ON usuarios
FOR EACH ROW
EXECUTE FUNCTION trg_fn_after_usuario_insert();

-- ----------------------------------------------------------------------------
-- CORREÇÃO: Valida também soft delete de sentimentos
CREATE OR REPLACE FUNCTION trg_fn_validar_sentimentos_minimos()
RETURNS TRIGGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Se está ocultando ou soft-deletando um sentimento ativo
    IF (OLD.categoria = 'ativo' AND NEW.categoria = 'oculto') OR
       (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.categoria = 'ativo') THEN
        
        v_count := fn_contar_sentimentos_ativos(NEW.user_id);
        
        IF v_count <= 3 THEN
            RAISE EXCEPTION 'Mantenha pelo menos três sentimentos ativos';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validar_sentimentos_minimos
BEFORE UPDATE ON sentimentos
FOR EACH ROW
EXECUTE FUNCTION trg_fn_validar_sentimentos_minimos();

-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decrementar_estoque()
RETURNS TRIGGER AS $$
DECLARE
    v_controle_ativo BOOLEAN;
    v_estoque_atual INTEGER;
    v_quantidade DECIMAL(5,2);
BEGIN
    IF NEW.status = 'tomada' AND OLD.status != 'tomada' AND NEW.estoque_decrementado = FALSE THEN
        
        SELECT controle_estoque_ativo, estoque_quantidade 
        INTO v_controle_ativo, v_estoque_atual
        FROM medicamentos 
        WHERE id = NEW.medicamento_id;
        
        IF v_controle_ativo = TRUE AND v_estoque_atual IS NOT NULL THEN
            v_quantidade := COALESCE(NEW.quantidade_real, NEW.quantidade_programada);
            
            UPDATE medicamentos 
            SET estoque_quantidade = GREATEST(0, estoque_quantidade - CEIL(v_quantidade)::INTEGER),
                updated_at = NOW()
            WHERE id = NEW.medicamento_id;
            
            NEW.estoque_decrementado := TRUE;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decrementar_estoque
BEFORE UPDATE ON registros_dose
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decrementar_estoque();

-- ----------------------------------------------------------------------------
-- NOVO: Valida mínimo 1 sentimento por registro de humor
CREATE OR REPLACE FUNCTION trg_fn_validar_humor_sentimentos()
RETURNS TRIGGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Verifica após pequeno delay para permitir inserts em batch
    PERFORM pg_sleep(0.01);
    
    SELECT COUNT(*) INTO v_count
    FROM registros_humor_sentimentos
    WHERE registro_humor_id = NEW.id;
    
    IF v_count = 0 THEN
        RAISE WARNING 'Registro de humor % sem sentimentos associados', NEW.id;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger executado após insert para permitir inserts em lote
CREATE TRIGGER trg_validar_humor_sentimentos
AFTER INSERT ON registros_humor
FOR EACH ROW
EXECUTE FUNCTION trg_fn_validar_humor_sentimentos();

-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_updated_at_usuarios BEFORE UPDATE ON usuarios 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_avatares BEFORE UPDATE ON avatares 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_medicamentos BEFORE UPDATE ON medicamentos 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_horarios BEFORE UPDATE ON horarios_medicamento 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_registros_dose BEFORE UPDATE ON registros_dose 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_sentimentos BEFORE UPDATE ON sentimentos 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_registros_humor BEFORE UPDATE ON registros_humor 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_prefs_notif BEFORE UPDATE ON preferencias_notificacao 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_mensagens BEFORE UPDATE ON mensagens_contato 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();
CREATE TRIGGER trg_updated_at_tokens_push BEFORE UPDATE ON tokens_push 
    FOR EACH ROW EXECUTE FUNCTION trg_fn_updated_at();

-- ============================================================================
-- VIEWS
-- ============================================================================

-- CORREÇÃO: View que mostra doses no dia correto (incluindo adiadas)
CREATE OR REPLACE VIEW vw_agenda_dia AS
-- Doses normais (não adiadas) no dia programado
SELECT 
    rd.id AS registro_dose_id,
    rd.user_id,
    CASE 
        WHEN rd.status = 'adiada' THEN rd.adiada_para_data
        ELSE rd.data_programada
    END AS data_exibicao,
    CASE 
        WHEN rd.status = 'adiada' THEN rd.adiada_para_hora
        ELSE rd.hora_programada
    END AS hora_exibicao,
    rd.data_programada AS data_original,
    rd.hora_programada AS hora_original,
    rd.quantidade_programada,
    rd.unidade,
    rd.status,
    rd.data_hora_real,
    rd.quantidade_real,
    rd.adiada_para_data,
    rd.adiada_para_hora,
    rd.dose_extra,
    rd.observacao,
    m.id AS medicamento_id,
    m.nome AS medicamento_nome,
    m.concentracao,
    m.unidade_concentracao,
    m.forma_farmaceutica,
    m.observacoes AS medicamento_observacoes,
    m.controle_estoque_ativo,
    m.estoque_quantidade,
    m.estoque_alerta_em,
    CASE 
        WHEN m.controle_estoque_ativo = TRUE 
             AND m.estoque_quantidade IS NOT NULL
             AND m.estoque_alerta_em IS NOT NULL
             AND m.estoque_quantidade <= m.estoque_alerta_em 
        THEN TRUE 
        ELSE FALSE 
    END AS estoque_baixo
FROM registros_dose rd
INNER JOIN medicamentos m ON m.id = rd.medicamento_id
WHERE m.status = 'ativo' 
  AND m.deleted_at IS NULL;

COMMENT ON VIEW vw_agenda_dia IS 'Agenda de medicamentos com status e alertas - use data_exibicao para filtrar';

-- ----------------------------------------------------------------------------
-- CORREÇÃO: Remove NULLs do array de sentimentos
CREATE OR REPLACE VIEW vw_historico_humor AS
SELECT 
    rh.id,
    rh.user_id,
    rh.intensidade,
    fn_obter_label_intensidade(rh.intensidade) AS intensidade_label,
    rh.data_hora,
    rh.data_hora::DATE AS data,
    rh.data_hora::TIME AS hora,
    rh.anotacao,
    COALESCE(STRING_AGG(s.nome, ', ' ORDER BY s.ordem_exibicao), '') AS sentimentos,
    COALESCE(
        ARRAY_AGG(s.id ORDER BY s.ordem_exibicao) FILTER (WHERE s.id IS NOT NULL),
        ARRAY[]::INTEGER[]
    ) AS sentimentos_ids,
    COUNT(rhs.sentimento_id) AS total_sentimentos,
    rh.created_at,
    rh.updated_at
FROM registros_humor rh
LEFT JOIN registros_humor_sentimentos rhs ON rhs.registro_humor_id = rh.id
LEFT JOIN sentimentos s ON s.id = rhs.sentimento_id
GROUP BY rh.id;

COMMENT ON VIEW vw_historico_humor IS 'Humor com sentimentos agregados e labels';

-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_medicamentos_usuario AS
SELECT 
    m.id,
    m.user_id,
    m.nome,
    m.concentracao,
    m.unidade_concentracao,
    CONCAT(m.nome, ' ', m.concentracao, m.unidade_concentracao) AS nome_completo,
    m.forma_farmaceutica,
    m.modo_uso,
    m.status,
    m.data_inicio,
    m.data_termino,
    m.uso_continuo,
    m.data_suspensao,
    m.controle_estoque_ativo,
    m.estoque_quantidade,
    m.estoque_alerta_em,
    CASE 
        WHEN m.controle_estoque_ativo = TRUE 
             AND m.estoque_quantidade IS NOT NULL
             AND m.estoque_alerta_em IS NOT NULL
             AND m.estoque_quantidade <= m.estoque_alerta_em 
        THEN TRUE 
        ELSE FALSE 
    END AS estoque_baixo,
    (
        SELECT STRING_AGG(
            CONCAT(hm.quantidade, ' ', hm.unidade, ' às ', TO_CHAR(hm.horario, 'HH24:MI')),
            ' | ' ORDER BY hm.horario
        )
        FROM horarios_medicamento hm 
        WHERE hm.medicamento_id = m.id AND hm.ativo = TRUE
    ) AS programacao_resumo,
    (
        SELECT MIN(hm.horario)
        FROM horarios_medicamento hm 
        WHERE hm.medicamento_id = m.id AND hm.ativo = TRUE
    ) AS primeiro_horario,
    CASE 
        WHEN m.modo_uso = 'ciclos' THEN 
            fn_calcular_dia_ciclo(m.ciclo_inicio, m.ciclo_dias_uso, m.ciclo_dias_pausa, CURRENT_DATE)
        ELSE NULL
    END AS dia_ciclo_atual
FROM medicamentos m
WHERE m.deleted_at IS NULL;

COMMENT ON VIEW vw_medicamentos_usuario IS 'Lista de medicamentos com resumo de programação';

-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_sentimentos_usuario AS
SELECT 
    s.id,
    s.user_id,
    s.nome,
    s.tipo,
    s.categoria,
    s.ordem_exibicao,
    (
        SELECT COUNT(*) 
        FROM registros_humor_sentimentos rhs 
        WHERE rhs.sentimento_id = s.id
    ) AS vezes_usado,
    s.created_at,
    s.updated_at
FROM sentimentos s
WHERE s.deleted_at IS NULL
ORDER BY s.user_id, s.categoria, s.ordem_exibicao;

COMMENT ON VIEW vw_sentimentos_usuario IS 'Sentimentos com contagem de uso';

-- ============================================================================
-- QUERIES DE EXEMPLO E MANUTENÇÃO
-- ============================================================================

-- Buscar agenda do dia para um usuário
-- SELECT * FROM vw_agenda_dia 
-- WHERE user_id = 1 AND data_exibicao = CURRENT_DATE
-- ORDER BY hora_exibicao;

-- Buscar medicamentos com estoque baixo
-- SELECT * FROM vw_medicamentos_usuario 
-- WHERE user_id = 1 AND estoque_baixo = TRUE;

-- Limpar códigos expirados (executar via cron diariamente)
-- DELETE FROM codigos_verificacao 
-- WHERE expira_em < NOW() OR usado = TRUE;

-- Limpar sessões expiradas
-- DELETE FROM sessoes_usuario 
-- WHERE expira_em < NOW();

-- Atualizar doses não registradas (executar via cron a cada hora)
-- CALL sp_atualizar_doses_nao_registradas(120);

-- ============================================================================
-- FIM DO SCHEMA
-- ============================================================================
