using System.Net.Mail;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Threading.RateLimiting;
using Dapper;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

// A connection string fica só no servidor (appsettings.json, user-secrets ou variável de ambiente).
var connStr = builder.Configuration.GetConnectionString("Default")
    ?? throw new InvalidOperationException("Defina ConnectionStrings:Default.");

// Sessão no servidor: cookie HttpOnly + SameSite=Strict (protege também contra CSRF nas rotas POST).
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme).AddCookie(o =>
{
    o.Cookie.Name = "askfor.auth";
    o.Cookie.HttpOnly = true;
    o.Cookie.SameSite = SameSiteMode.Strict;
    o.Cookie.SecurePolicy = builder.Environment.IsDevelopment() ? CookieSecurePolicy.SameAsRequest : CookieSecurePolicy.Always;
    o.ExpireTimeSpan = TimeSpan.FromHours(8);
    o.Events.OnRedirectToLogin = c => { c.Response.StatusCode = 401; return Task.CompletedTask; };      // API não redireciona
    o.Events.OnRedirectToAccessDenied = c => { c.Response.StatusCode = 403; return Task.CompletedTask; };
});
builder.Services.AddAuthorization();

// Limite por IP: 10 logins e 5 contatos por minuto.
static RateLimitPartition<string> PorIp(HttpContext c, int n) =>
    RateLimitPartition.GetFixedWindowLimiter(c.Connection.RemoteIpAddress?.ToString() ?? "?",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = n, Window = TimeSpan.FromMinutes(1) });
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddPolicy("login", c => PorIp(c, 10));
    o.AddPolicy("contato", c => PorIp(c, 5));
});

var app = builder.Build();

// Cria usuários com senha em hash: dotnet run -- criar-usuario <email> <nome> <Professor|Aluno> <senha(8+)> [alunoId]
if (args is ["criar-usuario", var uEmail, var uNome, var uPapel, var uSenha, ..var uExtra])
{
    if (uPapel is not ("Professor" or "Aluno") || uSenha.Length < 8 || (uPapel == "Aluno") != (uExtra.Length == 1))
    {
        Console.WriteLine("Uso: criar-usuario <email> <nome> <Professor|Aluno> <senha com 8+ caracteres> [alunoId, só para Aluno]");
        return;
    }
    await using var dbU = new SqlConnection(connStr);
    await dbU.ExecuteAsync("INSERT dbo.Usuarios(Email, Nome, Papel, AlunoId, SenhaHash) VALUES (@e, @n, @p, @a, @h)",
        new { e = uEmail.ToLowerInvariant(), n = uNome, p = uPapel, a = uExtra.Length == 1 ? int.Parse(uExtra[0]) : (int?)null, h = Senha.Criar(uSenha) });
    Console.WriteLine("Usuário criado.");
    return;
}

app.Use(async (c, next) =>
{
    c.Response.Headers["X-Content-Type-Options"] = "nosniff";
    c.Response.Headers["Referrer-Policy"] = "same-origin";
    await next();
});
app.UseRateLimiter();
app.UseDefaultFiles();   // serve wwwroot/index.html na raiz
app.UseStaticFiles();
app.UseAuthentication();
app.UseAuthorization();

// Professor enxerga todos; Aluno só o próprio registro (o servidor decide, nunca o navegador).
static int? Escopo(ClaimsPrincipal u, int? pedido) =>
    u.IsInRole("Professor") ? pedido : int.TryParse(u.FindFirst("alunoId")?.Value, out var id) ? id : -1;

var api = app.MapGroup("/api");
var priv = api.MapGroup("").RequireAuthorization();

// ---------- Autenticação ----------
api.MapPost("/login", async (LoginDto l, HttpContext ctx) =>
{
    var email = l.Email?.Trim().ToLowerInvariant();
    if (string.IsNullOrEmpty(email) || string.IsNullOrEmpty(l.Senha) || l.Senha.Length > 128 || l.Papel is not ("Professor" or "Aluno"))
        return Results.Json(new { erro = "Informe e-mail, senha e perfil." }, statusCode: 400);

    await using var db = new SqlConnection(connStr);
    var u = await db.QuerySingleOrDefaultAsync<UsuarioRow>(
        "SELECT UsuarioId, Nome, Papel, AlunoId, SenhaHash, BloqueadoAte FROM dbo.Usuarios WHERE Email = @email AND Ativo = 1", new { email });

    if (u?.BloqueadoAte > DateTime.UtcNow)
        return Results.Json(new { erro = "Acesso bloqueado por 15 minutos após várias tentativas. Tente mais tarde." }, statusCode: 429);

    // Verificar() roda mesmo sem usuário, para não revelar por tempo de resposta se o e-mail existe.
    if (!(Senha.Verificar(l.Senha, u?.SenhaHash) && u!.Papel == l.Papel))
    {
        if (u != null)
            await db.ExecuteAsync("""
                UPDATE dbo.Usuarios
                SET FalhasConsecutivas = CASE WHEN FalhasConsecutivas + 1 >= 5 THEN 0 ELSE FalhasConsecutivas + 1 END,
                    BloqueadoAte = CASE WHEN FalhasConsecutivas + 1 >= 5 THEN DATEADD(MINUTE, 15, SYSUTCDATETIME()) ELSE BloqueadoAte END
                WHERE UsuarioId = @UsuarioId
                """, new { u.UsuarioId });
        return Results.Json(new { erro = "E-mail, senha ou perfil incorretos." }, statusCode: 401);
    }

    await db.ExecuteAsync("UPDATE dbo.Usuarios SET FalhasConsecutivas = 0, BloqueadoAte = NULL, UltimoLogin = SYSUTCDATETIME() WHERE UsuarioId = @UsuarioId", new { u.UsuarioId });
    var claims = new List<Claim> { new(ClaimTypes.NameIdentifier, u.UsuarioId.ToString()), new(ClaimTypes.Name, u.Nome), new(ClaimTypes.Role, u.Papel) };
    if (u.AlunoId is int aid) claims.Add(new Claim("alunoId", aid.ToString()));
    await ctx.SignInAsync(new ClaimsPrincipal(new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme)));
    return Results.Ok(new { nome = u.Nome, papel = u.Papel });
}).RequireRateLimiting("login");

api.MapPost("/logout", async (HttpContext ctx) => { await ctx.SignOutAsync(); return Results.NoContent(); });

api.MapGet("/me", (ClaimsPrincipal u) =>
    Results.Ok(new { nome = u.Identity!.Name, papel = u.IsInRole("Professor") ? "Professor" : "Aluno" })).RequireAuthorization();

// ---------- Cartões: habilidade mais distante da meta no último mês de cada aluno ----------
priv.MapGet("/alunos", async (ClaimsPrincipal u) =>
{
    const string sql = """
        WITH r AS (
            SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.AlunoId ORDER BY e.Mes DESC, e.MediaPct - e.MetaPct) AS rn
            FROM dbo.vw_EvolucaoMensal e)
        SELECT a.AlunoId AS Id, a.Nome, a.NivelCodigo AS Nivel, r.Competencia AS Dificuldade,
               CONVERT(CHAR(7), r.Mes, 126) AS Mes, r.MediaPct AS MediaAtual,
               r.MediaMesAnterior AS MediaAnterior, r.MetaPct AS Meta
        FROM dbo.Alunos a
        LEFT JOIN r ON r.AlunoId = a.AlunoId AND r.rn = 1
        WHERE a.Ativo = 1 AND (@alunoId IS NULL OR a.AlunoId = @alunoId)
        ORDER BY a.Nome;
        """;
    await using var db = new SqlConnection(connStr);
    return Results.Ok(await db.QueryAsync<AlunoDto>(sql, new { alunoId = Escopo(u, null) }));
});

// ---------- Dashboard: média ponderada por mês e habilidade, com filtros ----------
priv.MapGet("/evolucao", async (ClaimsPrincipal u, int? alunoId, string? nivel, int? competenciaId, string? tipo, string? de, string? ate) =>
{
    const string sql = """
        SELECT CONVERT(CHAR(7), Mes, 126) AS Mes, Competencia,
               CAST(SUM(Pct * Peso) / SUM(Peso) AS DECIMAL(5,1)) AS MediaPct,
               CAST(AVG(MetaPct) AS DECIMAL(5,1)) AS MetaPct, COUNT(*) AS Qtd
        FROM dbo.vw_ResultadosDetalhe
        WHERE (@alunoId IS NULL OR AlunoId = @alunoId) AND (@nivel IS NULL OR NivelAluno = @nivel)
          AND (@competenciaId IS NULL OR CompetenciaId = @competenciaId) AND (@tipo IS NULL OR Tipo = @tipo)
          AND (@de  IS NULL OR Mes >= TRY_CONVERT(date, @de  + '-01'))
          AND (@ate IS NULL OR Mes <= TRY_CONVERT(date, @ate + '-01'))
        GROUP BY CompetenciaId, Competencia, Mes
        ORDER BY Mes, CompetenciaId;
        """;
    await using var db = new SqlConnection(connStr);
    return Results.Ok(await db.QueryAsync<EvolDto>(sql, new { alunoId = Escopo(u, alunoId), nivel, competenciaId, tipo, de, ate }));
});

priv.MapGet("/avaliacoes", async () =>
{
    const string sql = """
        SELECT v.AvaliacaoId AS Id, v.Tipo, v.Titulo, c.NivelCodigo AS Nivel, cp.Nome AS Competencia, v.NotaMaxima
        FROM dbo.Avaliacoes v
        JOIN dbo.Conteudos c ON c.ConteudoId = v.ConteudoId
        JOIN dbo.Competencias cp ON cp.CompetenciaId = c.CompetenciaId
        ORDER BY v.DataAplicacao DESC, v.AvaliacaoId DESC;
        """;
    await using var db = new SqlConnection(connStr);
    return Results.Ok(await db.QueryAsync<AvalDto>(sql));
});

// ---------- Lançamento de nota (só Professor; reenviar atualiza a nota existente) ----------
api.MapPost("/resultados", async (ResultadoDto r) =>
{
    await using var db = new SqlConnection(connStr);
    var k = await db.QuerySingleAsync<ChkRow>("""
        SELECT (SELECT NotaMaxima FROM dbo.Avaliacoes WHERE AvaliacaoId = @AvaliacaoId) AS Max,
               (SELECT COUNT(*) FROM dbo.Alunos WHERE AlunoId = @AlunoId AND Ativo = 1) AS Existe
        """, r);

    var erros = new Dictionary<string, string[]>();
    if (k.Existe == 0) erros["alunoId"] = ["Escolha um aluno válido."];
    if (k.Max is null) erros["avaliacaoId"] = ["Escolha uma avaliação válida."];
    else if (r.Nota < 0 || r.Nota > k.Max) erros["nota"] = [$"A nota deve ficar entre 0 e {k.Max:0.##}."];
    if (r.Observacao?.Length > 300) erros["observacao"] = ["A observação aceita até 300 caracteres."];
    if (erros.Count > 0) return Results.ValidationProblem(erros);

    await db.ExecuteAsync("""
        UPDATE dbo.Resultados SET Nota = @Nota, Observacao = @Observacao, RegistradoEm = SYSUTCDATETIME()
        WHERE AlunoId = @AlunoId AND AvaliacaoId = @AvaliacaoId;
        IF @@ROWCOUNT = 0
            INSERT dbo.Resultados(AlunoId, AvaliacaoId, Nota, Observacao) VALUES (@AlunoId, @AvaliacaoId, @Nota, @Observacao);
        """, r with { Observacao = r.Observacao?.Trim() });
    return Results.Ok(new { ok = true });
}).RequireAuthorization(p => p.RequireRole("Professor"));

// ---------- Contato (público): valida no servidor e grava ----------
api.MapPost("/contatos", async (ContatoDto c) =>
{
    var nome = c.Nome?.Trim();
    var email = c.Email?.Trim();
    var msg = c.Mensagem?.Trim();

    var erros = new Dictionary<string, string[]>();
    if (string.IsNullOrEmpty(nome) || nome.Length < 3 || nome.Length > 120)
        erros["nome"] = ["Informe de 3 a 120 caracteres no nome."];
    if (string.IsNullOrEmpty(email) || email.Length > 160 || !MailAddress.TryCreate(email, out _))
        erros["email"] = ["Informe um e-mail válido."];
    if (string.IsNullOrEmpty(msg) || msg.Length < 10 || msg.Length > 2000)
        erros["mensagem"] = ["Escreva de 10 a 2000 caracteres na mensagem."];
    if (erros.Count > 0) return Results.ValidationProblem(erros);

    await using var db = new SqlConnection(connStr);
    var id = await db.ExecuteScalarAsync<int>("""
        INSERT dbo.Contatos(Nome, Email, Mensagem) VALUES (@Nome, @Email, @Mensagem);
        SELECT CAST(SCOPE_IDENTITY() AS INT);
        """, new { Nome = nome, Email = email, Mensagem = msg });
    return Results.Created($"/api/contatos/{id}", new { id });
}).RequireRateLimiting("contato");

app.Run();

// Propriedades viram camelCase no JSON. Dapper liga colunas e parâmetros do construtor pelo nome.
record AlunoDto(int Id, string Nome, string Nivel, string? Dificuldade, string? Mes, decimal? MediaAtual, decimal? MediaAnterior, decimal? Meta);
record EvolDto(string Mes, string Competencia, decimal MediaPct, decimal MetaPct, int Qtd);
record AvalDto(int Id, string Tipo, string Titulo, string Nivel, string Competencia, decimal NotaMaxima);
record ResultadoDto(int AlunoId, int AvaliacaoId, decimal Nota, string? Observacao);
record ChkRow(decimal? Max, int Existe);
record LoginDto(string? Email, string? Senha, string? Papel);
record ContatoDto(string? Nome, string? Email, string? Mensagem);
record UsuarioRow(int UsuarioId, string Nome, string Papel, int? AlunoId, string SenhaHash, DateTime? BloqueadoAte);

static class Senha
{
    const int Iter = 600_000;   // PBKDF2-HMAC-SHA256; o número vai dentro do hash, então dá para aumentar depois
    static readonly string Falso = Criar("senha-falsa");

    public static string Criar(string s)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var h = Rfc2898DeriveBytes.Pbkdf2(s, salt, Iter, HashAlgorithmName.SHA256, 32);
        return $"PBKDF2${Iter}${Convert.ToBase64String(salt)}${Convert.ToBase64String(h)}";
    }

    public static bool Verificar(string s, string? guardado)
    {
        var p = (guardado ?? Falso).Split('$');
        var h = Rfc2898DeriveBytes.Pbkdf2(s, Convert.FromBase64String(p[2]), int.Parse(p[1]), HashAlgorithmName.SHA256, 32);
        return CryptographicOperations.FixedTimeEquals(h, Convert.FromBase64String(p[3])) && guardado != null;
    }
}