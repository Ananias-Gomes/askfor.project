/* Acompanhamento de Inglês - SQL Server 2016 SP1 ou superior */
IF DB_ID(N'AcompanhamentoIngles') IS NULL CREATE DATABASE AcompanhamentoIngles;
GO
USE AcompanhamentoIngles;
GO

/* ---------- TABELAS ---------- */
CREATE TABLE dbo.Alunos(
  AlunoId      INT IDENTITY PRIMARY KEY,
  Nome         NVARCHAR(120) NOT NULL,
  Email        NVARCHAR(160) NULL,
  Nivel        CHAR(2) NOT NULL CONSTRAINT CK_Alunos_Nivel CHECK (Nivel IN ('A1','A2','B1','B2','C1','C2')),
  DataIngresso DATE NOT NULL DEFAULT CAST(SYSDATETIME() AS DATE),
  Ativo        BIT NOT NULL DEFAULT 1);

CREATE TABLE dbo.Competencias(            -- Grammar, Listening, etc.
  CompetenciaId TINYINT IDENTITY PRIMARY KEY,
  Nome          NVARCHAR(40) NOT NULL UNIQUE);

CREATE TABLE dbo.Conteudos(               -- tópicos ensinados
  ConteudoId    INT IDENTITY PRIMARY KEY,
  Titulo        NVARCHAR(150) NOT NULL,
  CompetenciaId TINYINT NOT NULL REFERENCES dbo.Competencias,
  NivelAlvo     CHAR(2) NOT NULL);

CREATE TABLE dbo.Avaliacoes(              -- atividades e provas
  AvaliacaoId   INT IDENTITY PRIMARY KEY,
  Tipo          NVARCHAR(10) NOT NULL CHECK (Tipo IN (N'Atividade', N'Prova')),
  Titulo        NVARCHAR(150) NOT NULL,
  ConteudoId    INT NOT NULL REFERENCES dbo.Conteudos,
  DataAplicacao DATE NOT NULL,
  NotaMaxima    DECIMAL(5,2) NOT NULL CHECK (NotaMaxima > 0));

CREATE TABLE dbo.Resultados(              -- nota de cada aluno em cada avaliação
  ResultadoId INT IDENTITY PRIMARY KEY,
  AlunoId     INT NOT NULL REFERENCES dbo.Alunos,
  AvaliacaoId INT NOT NULL REFERENCES dbo.Avaliacoes,
  Nota        DECIMAL(5,2) NOT NULL CHECK (Nota >= 0),
  Observacao  NVARCHAR(300) NULL,
  CONSTRAINT UQ_Resultado UNIQUE (AlunoId, AvaliacaoId));

CREATE TABLE dbo.Contatos(                -- formulário do site
  ContatoId INT IDENTITY PRIMARY KEY,
  Nome      NVARCHAR(120) NOT NULL,
  Email     NVARCHAR(160) NOT NULL,
  Mensagem  NVARCHAR(2000) NOT NULL,
  CriadoEm  DATETIME2 NOT NULL DEFAULT SYSDATETIME());

CREATE INDEX IX_Resultados_Avaliacao ON dbo.Resultados(AvaliacaoId) INCLUDE (AlunoId, Nota);
GO

/* ---------- VIEWS PARA O DASHBOARD ---------- */
-- Média percentual por aluno, habilidade e mês
CREATE OR ALTER VIEW dbo.vw_DesempenhoMensal AS
SELECT a.AlunoId, a.Nome, a.Nivel, cp.CompetenciaId, cp.Nome AS Competencia,
       DATEFROMPARTS(YEAR(v.DataAplicacao), MONTH(v.DataAplicacao), 1) AS Mes,
       COUNT(*) AS QtdAvaliacoes,
       CAST(AVG(r.Nota * 100.0 / v.NotaMaxima) AS DECIMAL(5,1)) AS MediaPct
FROM dbo.Resultados r
JOIN dbo.Alunos a        ON a.AlunoId = r.AlunoId
JOIN dbo.Avaliacoes v    ON v.AvaliacaoId = r.AvaliacaoId
JOIN dbo.Conteudos c     ON c.ConteudoId = v.ConteudoId
JOIN dbo.Competencias cp ON cp.CompetenciaId = c.CompetenciaId
GROUP BY a.AlunoId, a.Nome, a.Nivel, cp.CompetenciaId, cp.Nome,
         DATEFROMPARTS(YEAR(v.DataAplicacao), MONTH(v.DataAplicacao), 1);
GO

-- Compara cada mês com o mês anterior e marca quem está abaixo de 60%
CREATE OR ALTER VIEW dbo.vw_EvolucaoMensal AS
SELECT d.*,
       LAG(MediaPct) OVER (PARTITION BY AlunoId, CompetenciaId ORDER BY Mes) AS MediaMesAnterior,
       MediaPct - LAG(MediaPct) OVER (PARTITION BY AlunoId, CompetenciaId ORDER BY Mes) AS Variacao,
       CASE WHEN MediaPct < 60 THEN 1 ELSE 0 END AS EmDificuldade
FROM dbo.vw_DesempenhoMensal d;
GO

/* ---------- DADOS DE EXEMPLO ---------- */
INSERT dbo.Competencias(Nome) VALUES (N'Grammar'),(N'Vocabulary'),(N'Listening'),(N'Speaking'),(N'Reading'),(N'Writing');
INSERT dbo.Alunos(Nome, Nivel) VALUES (N'Ana Beatriz Lima','B1'),(N'Carlos Eduardo Souza','A2'),(N'Rafael Oliveira','A2');
INSERT dbo.Conteudos(Titulo, CompetenciaId, NivelAlvo) VALUES (N'Present Perfect',1,'B1'),(N'Travel vocabulary',2,'A2'),(N'Podcasts for beginners',3,'A2');
INSERT dbo.Avaliacoes(Tipo, Titulo, ConteudoId, DataAplicacao, NotaMaxima) VALUES
  (N'Atividade', N'Present Perfect - exercícios', 1, '2026-10-15', 10),
  (N'Prova',     N'Prova de outubro - Listening', 3, '2026-10-28', 10),
  (N'Atividade', N'Present Perfect - revisão',    1, '2026-11-05', 10),
  (N'Prova',     N'Prova de novembro - Listening',3, '2026-11-09', 10);
INSERT dbo.Resultados(AlunoId, AvaliacaoId, Nota) VALUES
  (1,1,5.8),(1,3,6.7),(2,2,6.1),(2,4,5.9),(3,2,4.9),(3,4,5.7);
GO

/* Consulta que alimenta o dashboard: quem piorou ou está em dificuldade */
-- SELECT Nome, Competencia, Mes, MediaPct, MediaMesAnterior, Variacao
-- FROM dbo.vw_EvolucaoMensal WHERE EmDificuldade = 1 OR Variacao < 0 ORDER BY Mes DESC, Variacao;

/* Usuário somente leitura para o Power BI / API (troque a senha) */
-- CREATE LOGIN painel_leitura WITH PASSWORD = N'TroqueEstaSenha#2026';
-- CREATE USER painel_leitura FOR LOGIN painel_leitura;
-- GRANT SELECT ON dbo.vw_EvolucaoMensal TO painel_leitura;