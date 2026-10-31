using System.Text.Json;
using System.Text.RegularExpressions;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Guardas do instalador do Migrador Galileu (<c>installer/migracao-galileu/</c>, PRD-MGGINST-01) contra o código do
/// backend que ele empacota: o projeto WinForms <c>SisPedraCaida.Tools.MigracaoGalileu.App</c> e o publicador
/// <c>scripts/migracao-galileu-publish.ps1</c>.
/// </summary>
/// <remarks>
/// <para>
/// Leitura <b>textual</b> do <c>.csproj</c> e do publicador, sem <c>ProjectReference</c>: o App é casca WinForms
/// (#104a do backend) e, até o b3r3ch1t/SisPedraCaida-Backend#1396 chegar à <c>dev</c>/<c>prod</c> de lá, o projeto
/// nem existe no backend contra o qual o CI roda. Só <b>código</b> do backend, nunca documentação (armadilha u).
/// </para>
/// <para>
/// Sem o projeto no backend, as regras do lado de lá não têm contra o que comparar: passam <b>só</b> se a linha do
/// manifesto declara <c>aguardaBackend</c> — sem o campo, reprovam. As do lado de cá (AppId, upgrade, atalho)
/// rodam sempre.
/// </para>
/// </remarks>
public class MigracaoGalileuInnoGuardTests
{
    private const string Servico = "migracao-galileu";
    private const string Projeto = "SisPedraCaida.Tools.MigracaoGalileu.App";
    private const string AppIdDoMigrador = "84138E5C-EAA9-4D1E-947F-9E3BE09DCBE8";

    private static readonly string PastaDoInstalador = Path.Combine(Raizes.Instaladores, "installer", Servico);

    /// <summary>Lê um arquivo do instalador do migrador.</summary>
    /// <param name="arquivo">Nome do arquivo sob <c>installer/migracao-galileu</c>.</param>
    /// <returns>Conteúdo.</returns>
    private static string Ler(string arquivo) => File.ReadAllText(Path.Combine(PastaDoInstalador, arquivo));

    /// <summary>Valor de um <c>#define Nome "valor"</c> do <c>MigracaoGalileu.iss</c>.</summary>
    /// <param name="nome">Nome da constante do pré-processador.</param>
    /// <returns>O valor.</returns>
    private static string Define(string nome)
    {
        var achado = Regex.Match(Ler("MigracaoGalileu.iss"), $@"(?m)^#define\s+{Regex.Escape(nome)}\s+""(?<valor>[^""]*)""");
        Assert.True(achado.Success, $"#define {nome} não encontrado em MigracaoGalileu.iss.");
        return achado.Groups["valor"].Value;
    }

    /// <summary>Linhas do <c>.iss</c> que não são comentário de linha.</summary>
    /// <param name="fonte">Texto do <c>.iss</c>.</param>
    /// <returns>As linhas ativas.</returns>
    private static string[] LinhasAtivas(string fonte) =>
        fonte.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => !l.TrimStart().StartsWith(';')).ToArray();

    /// <summary>
    /// Arquivo do backend, ou <c>null</c> quando o projeto do migrador ainda não chegou à branch do backend em uso —
    /// o que só é aceito se o manifesto declara <c>aguardaBackend</c>.
    /// </summary>
    /// <param name="partes">Caminho relativo à raiz do backend.</param>
    /// <returns>Conteúdo, ou <c>null</c>.</returns>
    private static string? LerDoBackendSeJaMesclado(params string[] partes)
    {
        var csproj = Path.Combine(Raizes.Backend, "src", Projeto, Projeto + ".csproj");
        if (!File.Exists(csproj))
        {
            Assert.False(
                string.IsNullOrWhiteSpace(AguardaBackend()),
                $"{csproj} não existe e a linha '{Servico}' do manifesto não declara 'aguardaBackend'.");
            return null;
        }

        var caminho = Path.Combine(new[] { Raizes.Backend }.Concat(partes).ToArray());
        Assert.True(File.Exists(caminho), $"{caminho} ausente com o projeto do migrador presente no backend.");
        return File.ReadAllText(caminho);
    }

    /// <summary>Campo <c>aguardaBackend</c> da linha do migrador no manifesto.</summary>
    /// <returns>O texto, ou <c>null</c>.</returns>
    private static string? AguardaBackend()
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", "instaladores-ci.json")));
        var linha = json.RootElement.GetProperty("instaladores").EnumerateArray()
            .Single(i => i.GetProperty("servico").GetString() == Servico);
        return linha.TryGetProperty("aguardaBackend", out var valor) ? valor.GetString() : null;
    }

    /// <summary>
    /// O manifesto, o <c>build-installer.ps1</c> e o <c>.iss</c> falam do mesmo projeto e do mesmo <c>.exe</c> —
    /// o publicador não troca o nome, então o <c>.exe</c> é <c>&lt;projeto&gt;.exe</c>.
    /// </summary>
    [Fact]
    public void Executavel_NoIss_NoScript_ENoManifesto_EhODoProjeto()
    {
        Assert.Equal(Projeto + ".exe", Define("AppExe"));
        Assert.Contains($"$projeto = '{Projeto}'", Ler("build-installer.ps1"), StringComparison.Ordinal);

        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", "instaladores-ci.json")));
        var linha = json.RootElement.GetProperty("instaladores").EnumerateArray()
            .Single(i => i.GetProperty("servico").GetString() == Servico);
        Assert.Equal("aplicativo", linha.GetProperty("tipo").GetString());
        Assert.Equal(new[] { Projeto }, linha.GetProperty("projetos").EnumerateArray().Select(p => p.GetString() ?? string.Empty).ToArray());
        Assert.Equal("MigracaoGalileuSetup", linha.GetProperty("nome").GetString());
        Assert.Contains("OutputBaseFilename=MigracaoGalileuSetup-{#AppVersion}", Ler("MigracaoGalileu.iss"), StringComparison.Ordinal);
    }

    /// <summary>
    /// Do lado do backend: o projeto é <c>WinExe</c> (sem console atrás do assistente), <c>net10.0-windows</c> (o
    /// layout é win-x64, o que o <c>.iss</c> declara em <c>ArchitecturesAllowed</c>), não renomeia o assembly e roda
    /// <c>asInvoker</c> — o que permite o <c>[Run]</c> com <c>runasoriginaluser</c> e nenhum <c>runas</c> no atalho.
    /// </summary>
    [Fact]
    public void ProjetoDoBackend_EhWinExe_Windows_SemRenomear_EAsInvoker()
    {
        var csproj = LerDoBackendSeJaMesclado("src", Projeto, Projeto + ".csproj");
        if (csproj is null)
            return;

        Assert.Matches(@"<OutputType>WinExe</OutputType>", csproj);
        Assert.Matches(@"<TargetFramework>net\d+\.\d+-windows</TargetFramework>", csproj);
        Assert.DoesNotMatch(@"<AssemblyName>", csproj);

        var manifesto = LerDoBackendSeJaMesclado("src", Projeto, "app.manifest");
        Assert.Matches(@"level=""asInvoker""", manifesto!);

        var iss = Ler("MigracaoGalileu.iss");
        Assert.Contains(@"Flags: runasoriginaluser nowait postinstall skipifsilent", iss, StringComparison.Ordinal);
        Assert.Contains("ArchitecturesAllowed=x64compatible", iss, StringComparison.Ordinal);
    }

    /// <summary>
    /// O publicador do backend aceita o contrato que o <c>build-installer.ps1</c> usa (<c>-OutputPath</c>,
    /// <c>-Version</c>, <c>-Configuration</c>, <c>-SkipZip</c>), publica este projeto e para win-x64.
    /// </summary>
    [Fact]
    public void Publicador_DoBackend_AceitaOContratoDoBuildInstaller()
    {
        var publicador = LerDoBackendSeJaMesclado("scripts", "migracao-galileu-publish.ps1");
        if (publicador is null)
            return;

        foreach (var parametro in new[] { "OutputPath", "Version", "Configuration" })
            Assert.Matches($@"\[string\]\s*\${parametro}\b", publicador);
        Assert.Matches(@"\[switch\]\s*\$SkipZip\b", publicador);
        Assert.Contains($"$projeto = '{Projeto}'", publicador, StringComparison.Ordinal);
        Assert.Contains("$runtime = 'win-x64'", publicador, StringComparison.Ordinal);

        Assert.Contains("-OutputPath $PublishDir -Version $versaoResolvida -Configuration $Configuration -SkipZip",
            Ler("build-installer.ps1"), StringComparison.Ordinal);
    }

    /// <summary>
    /// AppId estável, só do migrador e o mesmo da chave de desinstalação que o bloqueio de downgrade lê.
    /// </summary>
    [Fact]
    public void AppId_EhEstavel_EProprio_ELidoPelaChaveDeDesinstalacao()
    {
        var iss = Ler("MigracaoGalileu.iss");
        Assert.Contains("AppId={{" + AppIdDoMigrador + "}", iss, StringComparison.Ordinal);
        Assert.Contains(@"Uninstall\{" + AppIdDoMigrador + "}_is1", iss, StringComparison.Ordinal);

        foreach (var (pasta, principal) in new[]
                 {
                     ("tefagent", "TefAgent.iss"), ("printmonitor", "PrintMonitor.iss"), ("totem", "Totem.iss"),
                 })
        {
            var outro = File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", pasta, principal));
            Assert.DoesNotContain(AppIdDoMigrador, outro, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>
    /// Sem <c>Setup.exe</c> para parar processo, quem fecha o assistente aberto antes da cópia é o Restart Manager
    /// (<c>CloseApplications=yes</c>), sem reabrir; os binários são sempre sobrescritos (<c>ignoreversion</c>).
    /// </summary>
    [Fact]
    public void Upgrade_FechaOAssistenteAberto_ESobrescreveSempre()
    {
        var iss = Ler("MigracaoGalileu.iss");

        Assert.Matches(@"(?m)^CloseApplications=yes\s*$", iss);
        Assert.Matches(@"(?m)^RestartApplications=no\s*$", iss);
        Assert.Contains("Flags: recursesubdirs createallsubdirs ignoreversion", iss, StringComparison.Ordinal);
    }

    /// <summary>
    /// A desinstalação não apaga a sessão anterior nem o log do restore: elevada, <c>{userappdata}</c> seria o perfil
    /// do administrador, e o que está lá é a evidência da migração (PRD-MGGINST-01 D4).
    /// </summary>
    [Fact]
    public void Desinstalacao_NaoApagaDadosDoUsuario()
    {
        var ativas = LinhasAtivas(Ler("MigracaoGalileu.iss"));

        Assert.DoesNotContain(ativas, l => Regex.IsMatch(l, @"^\[(InstallDelete|UninstallDelete)\]"));
        Assert.DoesNotContain(ativas, l => Regex.IsMatch(l, @"\{(userappdata|localappdata|commonappdata)\}", RegexOptions.IgnoreCase));
    }
}
