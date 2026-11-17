using System.Net.Mail;
using Dapper;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

// A connection string fica só no servidor (appsettings.json, user-secrets ou variável de ambiente).
var connStr = builder.Configuration.GetConnectionString("Default")
    ?? throw new InvalidOperationException("Defina ConnectionStrings:Default.");

// Limita o formulário público a 5 envios por minuto (por servidor) para reduzir spam.
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddFixedWindowLimiter("contato", c =>
    {
        c.PermitLimit = 5;
        c.Window = TimeSpan.FromMinutes(1);
    });
});

var app = builder.Build();

app.UseRateLimiter();
app.UseDefaultFiles();   // serve wwwroot/index.html na raiz
app.UseStaticFiles();

// GET /api/alunos: para cada aluno, a habilidade mais fraca do mês mais recente
// e a variação em relação ao mês anterior (lê a view vw_EvolucaoMensal).
app.MapGet("/api/alunos", async () =>
{
    const string sql = """
        WITH ult AS (SELECT MAX(Mes) AS Mes FROM dbo.vw_EvolucaoMensal),
        ranque AS (
            SELECT e.AlunoId, e.Nome, e.Nivel, e.Competencia, e.Mes, e.MediaPct, e.MediaMesAnterior,
                   ROW_NUMBER() OVER (PARTITION BY e.AlunoId ORDER BY e.MediaPct) AS rn
            FROM dbo.vw_EvolucaoMensal e
            JOIN ult ON e.Mes = ult.Mes
        )
        SELECT AlunoId AS Id, Nome, Nivel, Competencia AS Dificuldade, Mes,
               MediaPct AS MediaAtual, MediaMesAnterior AS MediaAnterior
        FROM ranque
        WHERE rn = 1
        ORDER BY Nome;
        """;

    await using var db = new SqlConnection(connStr);
    var alunos = await db.QueryAsync<AlunoDto>(sql);
    return Results.Ok(alunos);
});

// POST /api/contatos: valida no servidor (nunca confie só na validação do navegador) e grava.
app.MapPost("/api/contatos", async (ContatoDto c) =>
{
    var nome = c.Nome?.Trim();
    var email = c.Email?.Trim();
    var msg = c.Mensagem?.Trim();

    var erros = new Dictionary<string, string[]>();
    if (string.IsNullOrEmpty(nome) || nome.Length < 3 || nome.Length > 120)
        erros["nome"] = ["Informe de 3 a 120 caracteres."];
    if (string.IsNullOrEmpty(email) || email.Length > 160 || !MailAddress.TryCreate(email, out _))
        erros["email"] = ["Informe um e-mail válido."];
    if (string.IsNullOrEmpty(msg) || msg.Length < 10 || msg.Length > 2000)
        erros["mensagem"] = ["Informe de 10 a 2000 caracteres."];
    if (erros.Count > 0)
        return Results.ValidationProblem(erros);

    const string sql = """
        INSERT dbo.Contatos(Nome, Email, Mensagem) VALUES (@Nome, @Email, @Mensagem);
        SELECT CAST(SCOPE_IDENTITY() AS INT);
        """;

    await using var db = new SqlConnection(connStr);
    var id = await db.ExecuteScalarAsync<int>(sql, new { Nome = nome, Email = email, Mensagem = msg });
    return Results.Created($"/api/contatos/{id}", new { id });
}).RequireRateLimiting("contato");

app.Run();

// Os nomes das propriedades viram camelCase no JSON (id, nome, mediaAtual...).
record AlunoDto(int Id, string Nome, string Nivel, string Dificuldade, DateTime Mes, decimal MediaAtual, decimal? MediaAnterior);
record ContatoDto(string? Nome, string? Email, string? Mensagem);