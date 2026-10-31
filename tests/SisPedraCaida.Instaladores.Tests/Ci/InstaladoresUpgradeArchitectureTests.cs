using System.Text.RegularExpressions;
using Xunit;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Política de <b>upgrade por instalador</b> comum aos instaladores Inno dos agentes Windows do balcão — TEF,
/// PrintMonitor (PRD-PMTRAY-03, armadilha #101) e totem (PRD-TOTEMINST-01).
/// </summary>
/// <remarks>
/// <para>
/// Decisão de 21/10/2026: a versão nova chega por um instalador executado por cima do antigo, e os dois agentes
/// seguem a mesma política — AppId estável, binários sempre sobrescritos, nada apagado em <c>%PROGRAMDATA%</c>,
/// serviço tirado do caminho antes da cópia e downgrade recusado. Esta guarda roda no CI Linux (só lê texto); as
/// guardas finas do PrintMonitor, amarradas ao C#, estão em <c>InstaladorUpgradeGuardTests</c> (PrintMonitor.Tests,
/// só Windows).
/// </para>
/// <para>
/// A diferença deliberada entre os dois — o TEF roda o desinstalador anterior, o PrintMonitor não, porque o
/// <c>--uninstall</c> dele apaga as variáveis de máquina — também é travada aqui, para ninguém "alinhar" o
/// PrintMonitor ao TEF e apagar a chave das estações no próximo upgrade.
/// </para>
/// <para>
/// O totem segue o PrintMonitor (upgrade no lugar, sem o desinstalador anterior): o <c>--uninstall</c> dele
/// restaura as políticas da sessão e remove o serviço. As decisões próprias dele estão em
/// <c>TotemUpgradeGuardTests</c>.
/// </para>
/// </remarks>
[Trait("Category", "Architecture")]
public class InstaladoresUpgradeArchitectureTests
{
    /// <summary>Instaladores sob a política (pasta e arquivo principal).</summary>
    public static TheoryData<string, string> Instaladores => new()
    {
        { "tefagent", "TefAgent.iss" },
        { "printmonitor", "PrintMonitor.iss" },
        { "totem", "Totem.iss" },
    };

    /// <summary>
    /// Agentes mais os aplicativos de desktop (Migrador Galileu, PRD-MGGINST-01), que seguem a política de downgrade e
    /// de <c>%PROGRAMDATA%</c> mas não a de identidade: sem <c>Setup.exe</c> para parar processo, o aplicativo usa
    /// <c>CloseApplications=yes</c> (guarda própria em <c>MigracaoGalileuInnoGuardTests</c>).
    /// </summary>
    public static TheoryData<string, string> InstaladoresEAplicativos => new()
    {
        { "tefagent", "TefAgent.iss" },
        { "printmonitor", "PrintMonitor.iss" },
        { "totem", "Totem.iss" },
        { "migracao-galileu", "MigracaoGalileu.iss" },
    };

    /// <summary>AppId fixo, binários com ignoreversion, Inno sem fechar processos por conta própria.</summary>
    /// <param name="pasta">Pasta do instalador sob <c>installer/</c>.</param>
    /// <param name="principal">Arquivo <c>.iss</c> principal.</param>
    [Theory]
    [MemberData(nameof(Instaladores))]
    public void Instalador_TemIdentidadeEstavel_EBinariosSempreSobrescritos(string pasta, string principal)
    {
        var iss = Ler(pasta, principal);

        Assert.Matches(@"(?m)^AppId=\{\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}\s*$", iss);
        Assert.Matches(@"Flags: recursesubdirs createallsubdirs ignoreversion", iss);
        Assert.Matches(@"(?m)^CloseApplications=no\s*$", iss);
    }

    /// <summary>Nada apagado sob <c>{commonappdata}</c>: identidade, banco local e configuração sobrevivem.</summary>
    /// <param name="pasta">Pasta do instalador sob <c>installer/</c>.</param>
    /// <param name="principal">Arquivo <c>.iss</c> principal.</param>
    [Theory]
    [MemberData(nameof(InstaladoresEAplicativos))]
    public void Instalador_NaoApagaNadaEmProgramData(string pasta, string principal)
    {
        var ativas = Ler(pasta, principal).Split('\n')
            .Where(l => !l.TrimStart().StartsWith(';'))
            .ToArray();

        Assert.DoesNotContain(ativas, l => Regex.IsMatch(l, @"^\[(InstallDelete|UninstallDelete)\]"));
        Assert.DoesNotContain(ativas, l => l.Contains("{commonappdata}", StringComparison.OrdinalIgnoreCase)
                                          && l.Contains("Type:", StringComparison.Ordinal));
    }

    /// <summary>Só versão instalada MAIOR bloqueia (a mesma reinstala), com a mesma frase nos dois.</summary>
    /// <param name="pasta">Pasta do instalador sob <c>installer/</c>.</param>
    /// <param name="principal">Arquivo <c>.iss</c> principal.</param>
    [Theory]
    [MemberData(nameof(InstaladoresEAplicativos))]
    public void Instalador_BloqueiaDowngrade_EAceitaAMesmaVersao(string pasta, string principal)
    {
        var iss = Ler(pasta, principal);

        Assert.Contains("(CompareVersaoInstalada(VersaoInstalada, '{#AppVersion}') > 0)", iss, StringComparison.Ordinal);
        Assert.Contains("Uma versão mais recente do ", iss, StringComparison.Ordinal);
        Assert.Contains("'Desinstale a versão atual antes, se a regressão for intencional.'", iss, StringComparison.Ordinal);
    }

    /// <summary>
    /// O serviço sai do caminho no <c>PrepareToInstall</c>, antes da cópia — e o PrintMonitor faz isso SEM o
    /// desinstalador anterior.
    /// </summary>
    [Fact]
    public void PrepareToInstall_TiraOServicoDoCaminho_PrintMonitorSemDesinstalar()
    {
        var tef = Ler("tefagent", "TefAgent.iss");
        var printMonitor = Ler("printmonitor", "PrintMonitor.iss");
        var upgrade = Ler("printmonitor", "upgrade.iss");

        Assert.Contains("Result := RemoverInstalacaoAnterior();", tef, StringComparison.Ordinal);
        Assert.Contains("Result := PrepararUpgrade();", printMonitor, StringComparison.Ordinal);

        Assert.Contains("function PararServicoEConfirmar(): Boolean;", upgrade, StringComparison.Ordinal);
        Assert.DoesNotContain("UninstallString", upgrade, StringComparison.Ordinal);
        Assert.DoesNotContain("'--uninstall'", upgrade, StringComparison.Ordinal);
    }

    /// <summary>
    /// PrintMonitor (PRD-PMTRAY-04, campo 21/10/2026): antes da cópia, fecha por CAMINHO todo processo rodando de
    /// <c>{app}</c> — sem depender de instalação anterior registrada — e não recusa por arquivo em uso: o que sobrar
    /// travado é trocado no reinício (<c>restartreplace</c>). Reversão e desinstalação fazem a mesma limpeza.
    /// </summary>
    [Fact]
    public void PrintMonitor_FechaTudoDaPasta_Sempre_ESobrescreveComRestartreplace()
    {
        var printMonitor = Ler("printmonitor", "PrintMonitor.iss");
        var upgrade = Ler("printmonitor", "upgrade.iss");
        var processos = Ler("printmonitor", "processos.iss");
        var provisionamento = Ler("printmonitor", "provisioning.iss");

        Assert.Contains("#include \"processos.iss\"", printMonitor, StringComparison.Ordinal);
        Assert.Contains("FROM Win32_Process WHERE ExecutablePath LIKE", processos, StringComparison.Ordinal);
        Assert.Contains("/FO CSV /NH", processos, StringComparison.Ordinal);

        var preparar = Regex.Match(upgrade, @"function PrepararUpgrade\(\): String;[\s\S]*?\nend;").Value;
        Assert.Contains("EncerrarProcessosDaPasta(Pasta, ExpandConstant('{srcexe}'), Restantes)", preparar, StringComparison.Ordinal);
        Assert.DoesNotMatch(@"if\s+(not\s+)?InstalacaoAnterior", preparar);

        Assert.Matches(@"Flags: recursesubdirs createallsubdirs ignoreversion restartreplace uninsrestartdelete", printMonitor);
        Assert.Contains("EncerrarProcessosDaPasta(ExpandConstant('{app}')", provisionamento, StringComparison.Ordinal);
        Assert.Contains("LimparProcessosParaDesinstalar();", printMonitor, StringComparison.Ordinal);
    }

    /// <summary>Lê um arquivo do instalador.</summary>
    /// <param name="pasta">Pasta sob <c>installer/</c>.</param>
    /// <param name="arquivo">Nome do arquivo.</param>
    /// <returns>Conteúdo.</returns>
    private static string Ler(string pasta, string arquivo) =>
        File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", pasta, arquivo));

}
