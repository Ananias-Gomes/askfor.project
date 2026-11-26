/* Acompanhamento de Inglês v0.4 - SQL Server 2016 SP1 ou superior
   ATENÇÃO: recria alunos, conteúdos, avaliações, resultados e usuários (dados antigos são apagados).
   A tabela Contatos é preservada. As senhas NÃO são criadas aqui: use "dotnet run -- criar-usuario" (veja Program.cs). */
IF DB_ID(N'AcompanhamentoIngles') IS NULL CREATE DATABASE AcompanhamentoIngles;
GO
USE AcompanhamentoIngles;
GO
DROP VIEW IF EXISTS dbo.vw_EvolucaoMensal, dbo.vw_DesempenhoMensal, dbo.vw_ResultadosDetalhe;
DROP TABLE IF EXISTS dbo.Usuarios, dbo.Resultados, dbo.Avaliacoes, dbo.Conteudos, dbo.CriteriosNivel,
                     dbo.Alunos, dbo.Competencias, dbo.Niveis;
GO

/* ---------- TABELAS ---------- */
CREATE TABLE dbo.Niveis(
  NivelCodigo CHAR(2) PRIMARY KEY,
  Ordem       TINYINT NOT NULL UNIQUE,
  Nome        NVARCHAR(40) NOT NULL);

CREATE TABLE dbo.Competencias(                -- a ordem de inserção define os Ids 1..6 (o front usa essa ordem)
  CompetenciaId TINYINT IDENTITY PRIMARY KEY,
  Nome          NVARCHAR(40) NOT NULL UNIQUE);

CREATE TABLE dbo.CriteriosNivel(              -- o que se espera de cada habilidade em cada nível
  NivelCodigo   CHAR(2) NOT NULL REFERENCES dbo.Niveis,
  CompetenciaId TINYINT NOT NULL REFERENCES dbo.Competencias,
  Descricao     NVARCHAR(300) NOT NULL,
  MetaPct       DECIMAL(5,1) NOT NULL DEFAULT 60 CHECK (MetaPct BETWEEN 0 AND 100),  -- média mínima esperada
  PRIMARY KEY (NivelCodigo, CompetenciaId));

CREATE TABLE dbo.Alunos(
  AlunoId      INT IDENTITY PRIMARY KEY,
  Nome         NVARCHAR(120) NOT NULL,
  Email        NVARCHAR(160) NULL,
  NivelCodigo  CHAR(2) NOT NULL REFERENCES dbo.Niveis,
  DataIngresso DATE NOT NULL DEFAULT CAST(SYSDATETIME() AS DATE),
  Ativo        BIT NOT NULL DEFAULT 1);

CREATE TABLE dbo.Conteudos(                   -- assuntos ligados a um nível e a uma habilidade
  ConteudoId    INT IDENTITY PRIMARY KEY,
  Titulo        NVARCHAR(150) NOT NULL,
  NivelCodigo   CHAR(2) NOT NULL REFERENCES dbo.Niveis,
  CompetenciaId TINYINT NOT NULL REFERENCES dbo.Competencias);

CREATE TABLE dbo.Avaliacoes(                  -- atividades e provas (nível e habilidade vêm do conteúdo)
  AvaliacaoId   INT IDENTITY PRIMARY KEY,
  Tipo          NVARCHAR(10) NOT NULL CHECK (Tipo IN (N'Atividade', N'Prova')),
  Titulo        NVARCHAR(150) NOT NULL,
  ConteudoId    INT NOT NULL REFERENCES dbo.Conteudos,
  DataAplicacao DATE NOT NULL,
  NotaMaxima    DECIMAL(5,2) NOT NULL CHECK (NotaMaxima > 0),
  Peso          DECIMAL(4,2) NOT NULL DEFAULT 1 CHECK (Peso > 0));   -- prova costuma pesar mais que atividade

CREATE TABLE dbo.Resultados(
  ResultadoId  INT IDENTITY PRIMARY KEY,
  AlunoId      INT NOT NULL REFERENCES dbo.Alunos,
  AvaliacaoId  INT NOT NULL REFERENCES dbo.Avaliacoes,
  Nota         DECIMAL(5,2) NOT NULL CHECK (Nota >= 0),
  Observacao   NVARCHAR(300) NULL,            -- dificuldade observada pelo professor
  RegistradoEm DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT UQ_Resultado UNIQUE (AlunoId, AvaliacaoId));
CREATE INDEX IX_Resultados_Avaliacao ON dbo.Resultados(AvaliacaoId) INCLUDE (AlunoId, Nota);

IF OBJECT_ID(N'dbo.Contatos') IS NULL
CREATE TABLE dbo.Contatos(
  ContatoId INT IDENTITY PRIMARY KEY,
  Nome      NVARCHAR(120) NOT NULL,
  Email     NVARCHAR(160) NOT NULL,
  Mensagem  NVARCHAR(2000) NOT NULL,
  CriadoEm  DATETIME2 NOT NULL DEFAULT SYSDATETIME());

CREATE TABLE dbo.Usuarios(
  UsuarioId          INT IDENTITY PRIMARY KEY,
  Email              NVARCHAR(160) NOT NULL,
  Nome               NVARCHAR(120) NOT NULL,
  Papel              NVARCHAR(10) NOT NULL CHECK (Papel IN (N'Professor', N'Aluno')),
  AlunoId            INT NULL REFERENCES dbo.Alunos,
  SenhaHash          NVARCHAR(400) NOT NULL,   -- PBKDF2, nunca a senha
  Ativo              BIT NOT NULL DEFAULT 1,
  FalhasConsecutivas INT NOT NULL DEFAULT 0,
  BloqueadoAte       DATETIME2 NULL,           -- UTC
  UltimoLogin        DATETIME2 NULL,
  CriadoEm           DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT CK_Usuarios_AlunoPapel CHECK ((Papel = N'Aluno' AND AlunoId IS NOT NULL) OR (Papel = N'Professor' AND AlunoId IS NULL)));
CREATE UNIQUE INDEX UX_Usuarios_Email ON dbo.Usuarios(Email);
CREATE UNIQUE INDEX UX_Usuarios_Aluno ON dbo.Usuarios(AlunoId) WHERE AlunoId IS NOT NULL;   -- um login por aluno
GO

/* ---------- VIEWS ---------- */
-- Uma linha por nota, já em %, com a meta do nível atual do aluno para aquela habilidade
CREATE VIEW dbo.vw_ResultadosDetalhe AS
SELECT r.ResultadoId, a.AlunoId, a.Nome, a.NivelCodigo AS NivelAluno,
       v.AvaliacaoId, v.Tipo, v.Titulo, v.DataAplicacao,
       DATEFROMPARTS(YEAR(v.DataAplicacao), MONTH(v.DataAplicacao), 1) AS Mes,
       cp.CompetenciaId, cp.Nome AS Competencia, c.NivelCodigo AS NivelConteudo,
       CAST(r.Nota * 100.0 / v.NotaMaxima AS DECIMAL(6,2)) AS Pct, v.Peso, k.MetaPct
FROM dbo.Resultados r
JOIN dbo.Alunos a        ON a.AlunoId = r.AlunoId
JOIN dbo.Avaliacoes v    ON v.AvaliacaoId = r.AvaliacaoId
JOIN dbo.Conteudos c     ON c.ConteudoId = v.ConteudoId
JOIN dbo.Competencias cp ON cp.CompetenciaId = c.CompetenciaId
JOIN dbo.CriteriosNivel k ON k.NivelCodigo = a.NivelCodigo AND k.CompetenciaId = cp.CompetenciaId;
GO

-- Média ponderada (pelo peso) por aluno, habilidade e mês
CREATE VIEW dbo.vw_DesempenhoMensal AS
SELECT AlunoId, Nome, NivelAluno AS Nivel, CompetenciaId, Competencia, Mes,
       COUNT(*) AS QtdAvaliacoes,
       CAST(SUM(Pct * Peso) / SUM(Peso) AS DECIMAL(5,1)) AS MediaPct,
       MAX(MetaPct) AS MetaPct
FROM dbo.vw_ResultadosDetalhe
GROUP BY AlunoId, Nome, NivelAluno, CompetenciaId, Competencia, Mes;
GO

-- Compara com o mês anterior e marca quem está abaixo da meta do nível
CREATE VIEW dbo.vw_EvolucaoMensal AS
SELECT d.*,
       LAG(MediaPct) OVER (PARTITION BY AlunoId, CompetenciaId ORDER BY Mes) AS MediaMesAnterior,
       MediaPct - LAG(MediaPct) OVER (PARTITION BY AlunoId, CompetenciaId ORDER BY Mes) AS Variacao,
       CASE WHEN MediaPct < MetaPct THEN 1 ELSE 0 END AS EmDificuldade
FROM dbo.vw_DesempenhoMensal d;
GO

/* ---------- DADOS DE EXEMPLO ---------- */
INSERT dbo.Niveis(NivelCodigo, Ordem, Nome) VALUES
  ('A1',1,N'Iniciante'),('A2',2,N'Básico'),('B1',3,N'Intermediário'),
  ('B2',4,N'Intermediário superior'),('C1',5,N'Avançado'),('C2',6,N'Proficiência');

INSERT dbo.Competencias(Nome) VALUES (N'Grammar'),(N'Vocabulary'),(N'Writing'),(N'Speaking'),(N'Reading'),(N'Listening');

-- Critérios: gramática, vocabulário, escrita, fala, leitura, escuta (meta padrão 60%; ajuste com UPDATE)
INSERT dbo.CriteriosNivel(NivelCodigo, CompetenciaId, Descricao)
SELECT n.c, k.id, k.t FROM (VALUES
 ('A1',N'To be, presente simples, artigos',N'Cerca de 500 palavras do dia a dia',N'Frases simples e formulários',N'Apresentar-se e fazer perguntas básicas',N'Placas, avisos e textos de 2 a 3 linhas',N'Instruções e números ditos devagar'),
 ('A2',N'Passado simples, going to, comparativos',N'Viagens, compras, rotina e família',N'Mensagens e parágrafos curtos',N'Conversas simples sobre rotina e gostos',N'Textos curtos e e-mails familiares',N'Diálogos curtos sobre temas conhecidos'),
 ('B1',N'Present perfect, condicionais 0 e 1, voz passiva simples',N'Trabalho, estudos e opiniões, com colocações comuns',N'Textos conectados sobre experiências e planos',N'Narrar experiências e justificar opiniões',N'Artigos simples e histórias',N'Podcasts e notícias em fala clara'),
 ('B2',N'Condicionais 2 e 3, discurso indireto, voz passiva',N'Phrasal verbs, expressões e termos abstratos',N'Redações argumentativas e relatórios',N'Debater com fluência e espontaneidade',N'Artigos e textos contemporâneos',N'Palestras e filmes em ritmo normal'),
 ('C1',N'Inversão, estruturas complexas e nuances de tempo verbal',N'Expressões idiomáticas e registro formal e informal',N'Textos longos, bem estruturados e detalhados',N'Fluência e precisão sem esforço aparente',N'Textos longos e exigentes, inclusive implícitos',N'Falas longas, mesmo mal estruturadas'),
 ('C2',N'Domínio e precisão de todas as estruturas',N'Ironia, humor e sentidos sutis',N'Estilo adequado a cada contexto',N'Distinguir nuances de significado',N'Qualquer texto, inclusive literário e técnico',N'Qualquer fala, em qualquer velocidade')
) n(c,g,v,w,s,r,l)
CROSS APPLY (VALUES (1,n.g),(2,n.v),(3,n.w),(4,n.s),(5,n.r),(6,n.l)) k(id,t);

INSERT dbo.Alunos(Nome, NivelCodigo) VALUES
  (N'Ana Beatriz Lima','B1'),(N'Carlos Eduardo Souza','A2'),(N'Marina Costa','B2'),
  (N'Rafael Oliveira','A2'),(N'Júlia Fernandes','B1'),(N'Pedro Henrique Alves','B2');

INSERT dbo.Conteudos(Titulo, NivelCodigo, CompetenciaId) VALUES
  (N'Present Perfect','B1',1),(N'Travel vocabulary','A2',2),(N'Podcasts for beginners','A2',6),
  (N'Opinion essay','B2',3),(N'Job interview role-play','B1',4),(N'Short stories','B2',5);

INSERT dbo.Avaliacoes(Tipo, Titulo, ConteudoId, DataAplicacao, NotaMaxima, Peso) VALUES
  (N'Atividade',N'Present Perfect - exercícios',1,'2026-10-15',10,1),
  (N'Prova',    N'Prova de outubro - Listening',3,'2026-10-28',10,2),
  (N'Atividade',N'Travel vocabulary - quiz',    2,'2026-10-20',10,1),
  (N'Prova',    N'Prova de outubro - Writing',  4,'2026-10-30',10,2),
  (N'Atividade',N'Present Perfect - revisão',   1,'2026-11-05',10,1),
  (N'Prova',    N'Prova de novembro - Listening',3,'2026-11-09',10,2),
  (N'Atividade',N'Travel vocabulary - revisão', 2,'2026-11-10',10,1),
  (N'Prova',    N'Prova de novembro - Writing', 4,'2026-11-12',10,2),
  (N'Atividade',N'Job interview - role-play',   5,'2026-10-22',10,1),
  (N'Atividade',N'Job interview - revisão',     5,'2026-11-18',10,1),
  (N'Atividade',N'Short stories - leitura',     6,'2026-10-25',10,1),
  (N'Atividade',N'Short stories - leitura 2',   6,'2026-11-20',10,1);

INSERT dbo.Resultados(AlunoId, AvaliacaoId, Nota) VALUES
  (1,1,5.8),(1,5,6.7),(1,9,6.9),(1,10,7.4),
  (2,2,6.1),(2,6,5.9),(2,3,7.0),(2,7,7.4),
  (3,4,7.2),(3,8,7.8),(3,11,8.0),(3,12,8.3),
  (4,2,4.9),(4,6,5.7),(4,3,5.2),(4,7,6.0),
  (5,1,6.5),(5,5,6.4),(5,9,5.8),(5,10,6.2),
  (6,4,8.0),(6,8,8.4),(6,11,8.2),(6,12,8.6);
GO

/* Usuário somente leitura para Power BI (troque a senha):
-- CREATE LOGIN painel_leitura WITH PASSWORD = N'TroqueEstaSenha#2026';
-- CREATE USER painel_leitura FOR LOGIN painel_leitura;
-- GRANT SELECT ON dbo.vw_EvolucaoMensal TO painel_leitura; */