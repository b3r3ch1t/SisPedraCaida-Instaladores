using System.Text.RegularExpressions;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Guardas do <b>upgrade e da desinstalação</b> do instalador do totem (PRD-TOTEMINST-01).
/// </summary>
/// <remarks>
/// O totem segue a política do PrintMonitor, não a do TEF: upgrade no lugar, SEM rodar o desinstalador anterior,
/// porque a identidade (<c>identidade.json</c>), a configuração e o estado das políticas da sessão vivem em
/// <c>%PROGRAMDATA%</c> e precisam sobreviver. A política comum (AppId fixo, <c>ignoreversion</c>,
/// <c>CloseApplications=no</c>, nada apagado em <c>{commonappdata}</c>, downgrade recusado) está em
/// <see cref="InstaladoresUpgradeArchitectureTests"/>; aqui ficam as decisões próprias do totem, que revertidas só
/// apareceriam numa estação real.
/// </remarks>
public class TotemUpgradeGuardTests
{
    private const string AppIdDoTotem = "C9D9108B-9DB0-450D-986B-7470728B6123";

    private static readonly string PastaDoInstalador = Path.Combine(Raizes.Instaladores, "installer", "totem");

    /// <summary>Lê um arquivo do instalador do totem.</summary>
    /// <param name="arquivo">Nome do arquivo sob <c>installer/totem</c>.</param>
    /// <returns>Conteúdo.</returns>
    private static string Ler(string arquivo) => File.ReadAllText(Path.Combine(PastaDoInstalador, arquivo));

    /// <summary>Lê um arquivo de outro instalador deste repositório.</summary>
    /// <param name="pasta">Pasta sob <c>installer/</c>.</param>
    /// <param name="arquivo">Nome do arquivo.</param>
    /// <returns>Conteúdo.</returns>
    private static string LerDe(string pasta, string arquivo) =>
        File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", pasta, arquivo));

    /// <summary>Corpo de uma função ou procedimento Pascal (até o <c>end;</c> na coluna 0).</summary>
    /// <param name="fonte">Texto do <c>.iss</c>.</param>
    /// <param name="assinatura">Assinatura exata.</param>
    /// <returns>O corpo, assinatura incluída.</returns>
    private static string Corpo(string fonte, string assinatura)
    {
        var achado = Regex.Match(fonte, Regex.Escape(assinatura) + @"[\s\S]*?\nend;");
        Assert.True(achado.Success, $"'{assinatura}' não encontrado.");
        return achado.Value;
    }

    /// <summary>Linhas do <c>.iss</c> que não são comentário de linha.</summary>
    /// <param name="fonte">Texto do <c>.iss</c>.</param>
    /// <returns>As linhas ativas.</returns>
    private static string[] LinhasAtivas(string fonte) =>
        fonte.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => !l.TrimStart().StartsWith(';')).ToArray();

    /// <summary>
    /// O AppId é estável e só do totem, e é o mesmo que o <c>checks.iss</c> procura para achar a instalação anterior.
    /// Trocar o AppId faz o pacote novo não reconhecer o antigo: duas entradas e dois layouts brigando pelo serviço.
    /// </summary>
    [Fact]
    public void AppId_EhEstavel_EProprio_ELidoPelaChaveDeDesinstalacao()
    {
        Assert.Contains("AppId={{" + AppIdDoTotem + "}", Ler("Totem.iss"), StringComparison.Ordinal);
        Assert.Contains(@"Uninstall\{" + AppIdDoTotem + "}_is1", Ler("checks.iss"), StringComparison.Ordinal);

        foreach (var (pasta, principal) in new[]
                 {
                     ("tefagent", "TefAgent.iss"), ("printmonitor", "PrintMonitor.iss"),
                 })
        {
            Assert.DoesNotContain(AppIdDoTotem, LerDe(pasta, principal), StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>
    /// Antes da cópia o serviço para (confirmado no SCM), a casca fecha e o que sobrou da pasta é encerrado por
    /// caminho, SEM o desinstalador anterior: o <c>--uninstall</c> restauraria as políticas e removeria o serviço
    /// no meio de um simples upgrade.
    /// </summary>
    [Fact]
    public void PrepareToInstall_TiraOServicoDoCaminho_SemDesinstaladorAnterior()
    {
        Assert.Contains("Result := PrepararUpgrade();", Ler("Totem.iss"), StringComparison.Ordinal);

        var preparar = Corpo(Ler("provisioning.iss"), "function PrepararUpgrade(): String;");
        Assert.Contains("PararServicoEConfirmar()", preparar, StringComparison.Ordinal);
        Assert.Contains("EncerrarProcesso('{#CascaExe}')", preparar, StringComparison.Ordinal);
        Assert.Contains("EncerrarProcessosDaPasta(Pasta, ExpandConstant('{srcexe}'), Restantes)", preparar, StringComparison.Ordinal);

        Assert.DoesNotContain("'--uninstall'", preparar, StringComparison.Ordinal);
        Assert.DoesNotContain("UninstallString", preparar, StringComparison.Ordinal);
        // O fechamento vale SEMPRE, não só com instalação anterior registrada (lição do PrintMonitor, #112h).
        Assert.DoesNotMatch(@"if\s+(not\s+)?InstalacaoAnterior", preparar);
    }

    /// <summary>
    /// Na desinstalação: parar o serviço, fechar a casca e só então chamar o <c>Setup.exe --uninstall</c> por
    /// <c>Exec()</c>, com o código conferido. Sem <c>[UninstallRun]</c> (ignora o código) e sem <c>[Registry]</c>: a
    /// chave Run da casca é do <c>Setup.exe</c>, e o <c>uninsdeletevalue</c> a apagaria antes de o
    /// <c>--uninstall</c> conferir o estado.
    /// </summary>
    [Fact]
    public void Desinstalacao_ParaServico_FechaCasca_EChamaUninstallPorExec()
    {
        var iss = Ler("Totem.iss");
        var gancho = Corpo(iss, "procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);");
        Assert.Contains("DesprovisionarParaDesinstalar();", gancho, StringComparison.Ordinal);

        var desinstalar = Corpo(Ler("provisioning.iss"), "procedure DesprovisionarParaDesinstalar();");
        var parar = desinstalar.IndexOf("PararServicoEConfirmar()", StringComparison.Ordinal);
        var fecharCasca = desinstalar.IndexOf("EncerrarProcesso('{#CascaExe}')", StringComparison.Ordinal);
        var uninstall = desinstalar.IndexOf("ExecutarSetup('--uninstall'", StringComparison.Ordinal);

        Assert.True(parar >= 0 && fecharCasca > parar && uninstall > fecharCasca,
            "A desinstalação precisa parar o serviço, depois fechar a casca, depois chamar o --uninstall.");

        var ativas = LinhasAtivas(iss);
        Assert.DoesNotContain(ativas, l => l.Trim() == "[UninstallRun]");
        Assert.DoesNotContain(ativas, l => l.Trim() == "[Registry]");
    }

    /// <summary>
    /// O fechamento é por CAMINHO (WMI) e com <c>tasklist</c> em CSV: em tabela o nome da imagem é truncado em 25
    /// caracteres e <c>SisPedraCaida.Totem.*.exe</c> nunca seria achado (#112h). O que escapar é trocado no próximo
    /// reinício (<c>restartreplace</c>), em vez de parar a instalação em "DeleteFile falhou; código 5".
    /// </summary>
    [Fact]
    public void FechamentoPorCaminho_CsvEWmi_ERestartreplace()
    {
        var provisionamento = Ler("provisioning.iss");
        Assert.Contains("FROM Win32_Process WHERE ExecutablePath LIKE", provisionamento, StringComparison.Ordinal);
        Assert.Contains("/FO CSV /NH", provisionamento, StringComparison.Ordinal);
        Assert.Contains("PrefixoDosExecutaveis = 'SISPEDRACAIDA.'", provisionamento, StringComparison.Ordinal);

        Assert.Matches(@"Flags: recursesubdirs createallsubdirs ignoreversion restartreplace uninsrestartdelete", Ler("Totem.iss"));
    }
}
