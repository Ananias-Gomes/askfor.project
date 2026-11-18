/* v0.3.0 - Login de professor e aluno (SQL Server 2016 SP1 ou superior)
   Rode DEPOIS do banco_de_dados.sql. Pode ser executado mais de uma vez.
   As senhas NÃO são criadas aqui: use o comando "criar-usuario" da API (veja o README),
   que grava só o hash da senha. */
USE AcompanhamentoIngles;
GO

IF OBJECT_ID(N'dbo.Usuarios') IS NULL
CREATE TABLE dbo.Usuarios(
  UsuarioId          INT IDENTITY PRIMARY KEY,
  Email              NVARCHAR(160) NOT NULL,
  Nome               NVARCHAR(120) NOT NULL,
  Papel              NVARCHAR(10)  NOT NULL CONSTRAINT CK_Usuarios_Papel CHECK (Papel IN (N'Professor', N'Aluno')),
  AlunoId            INT NULL CONSTRAINT FK_Usuarios_Alunos REFERENCES dbo.Alunos(AlunoId),
  SenhaHash          NVARCHAR(400) NOT NULL,          -- hash (PBKDF2), nunca a senha
  Ativo              BIT NOT NULL CONSTRAINT DF_Usuarios_Ativo DEFAULT 1,
  FalhasConsecutivas INT NOT NULL CONSTRAINT DF_Usuarios_Falhas DEFAULT 0,
  BloqueadoAte       DATETIME2 NULL,                  -- bloqueio temporário (UTC)
  UltimoLogin        DATETIME2 NULL,
  CriadoEm           DATETIME2 NOT NULL CONSTRAINT DF_Usuarios_Criado DEFAULT SYSUTCDATETIME(),
  -- aluno precisa estar ligado a um aluno; professor não
  CONSTRAINT CK_Usuarios_AlunoPapel CHECK ((Papel = N'Aluno' AND AlunoId IS NOT NULL) OR (Papel = N'Professor' AND AlunoId IS NULL)));
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Usuarios_Email' AND object_id = OBJECT_ID(N'dbo.Usuarios'))
  CREATE UNIQUE INDEX UX_Usuarios_Email ON dbo.Usuarios(Email);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Usuarios_Aluno' AND object_id = OBJECT_ID(N'dbo.Usuarios'))
  CREATE UNIQUE INDEX UX_Usuarios_Aluno ON dbo.Usuarios(AlunoId) WHERE AlunoId IS NOT NULL;   -- um login por aluno
GO