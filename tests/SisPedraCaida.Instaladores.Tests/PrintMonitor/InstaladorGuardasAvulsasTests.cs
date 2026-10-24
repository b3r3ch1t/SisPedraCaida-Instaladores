using System.Text.Json;
using System.Text.RegularExpressions;
using SisPedraCaida.PrintMonitor.Core.Provisioning;
using SisPedraCaida.PrintMonitor.Helper.Ambiente;
using SisPedraCaida.PrintMonitor.Setup;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// Guardas que, no backend, viviam no meio de classes de outro assunto e liam o <c>.iss</c> ou o
/// manifesto de instaladores. Vieram para cá com os instaladores (23/10/2026); a parte de cada classe
/// que só olha o C# continua no backend.
/// </summary>
public class InstaladorGuardasAvulsasTests
{
    private static string PastaDoPrintMonitor => Path.Combine(Raizes.Instaladores, "installer", "printmonitor");

    /// <summary>
    /// Códigos de saída do <c>Setup.exe</c> e o tratamento espelhado no <c>provisioning.iss</c>
    /// (PRD-PMCERT-01; era <c>CodigosDeSaidaTests</c>).
    /// </summary>
    /// <remarks>
    /// O <c>.iss</c> confere o <c>ResultCode</c> por <c>Exec()</c> e, em qualquer código que não conheça, desfaz a
    /// instalação inteira. Um código novo sem o par no <c>.iss</c> transforma "sucesso com aviso" em estação sem
    /// serviço — exatamente o sintoma de campo de 21/10/2026.
    /// </remarks>
    [Fact]
    public void SucessoComAviso_NoIss_EhOMesmoCodigo_ENaoDesprovisiona()
    {
        var provisionamento = File.ReadAllText(Path.Combine(PastaDoPrintMonitor, "provisioning.iss"));
        var principal = File.ReadAllText(Path.Combine(PastaDoPrintMonitor, "PrintMonitor.iss"));

        var constante = Regex.Match(provisionamento, @"CodigoSucessoComAviso\s*=\s*(?<codigo>\d+)\s*;");
        Assert.True(constante.Success, "const CodigoSucessoComAviso não encontrada no provisioning.iss.");
        Assert.Equal(CodigosDeSaida.SucessoComAviso, int.Parse(constante.Groups["codigo"].Value));

        // O ramo que desprovisiona e reprova tem de excluir o código de aviso.
        Assert.Contains("if (Codigo <> 0) and (Codigo <> CodigoSucessoComAviso) then", provisionamento, StringComparison.Ordinal);

        // E o aviso chega à tela final.
        Assert.Contains("ResumoAvisoProvisionamento()", principal, StringComparison.Ordinal);
    }

    /// <summary>O <c>.iss</c> inicia o Helper com o argumento que o Helper reconhece (era <c>AmbienteDaMaquinaTests</c>).</summary>
    [Fact]
    public void ArgumentoDoAmbienteDaMaquina_EhOMesmoQueOInstaladorPassa()
    {
        // Divergir faz o Helper subir com o ambiente antigo em silêncio.
        var upgrade = File.ReadAllText(Path.Combine(PastaDoPrintMonitor, "upgrade.iss"));

        Assert.Contains("ArgumentoAmbienteDaMaquina = '" + AmbienteDaMaquina.Argumento + "';", upgrade, StringComparison.Ordinal);
    }

    /// <summary>
    /// O instalador (Inno Setup) e o <c>DashboardUrlNormalizer</c> declaram as mesmas grafias do recurso
    /// (era <c>PrintAgentsControllerCatalogoTests</c>).
    /// </summary>
    /// <remarks>
    /// O <c>.iss</c> reimplementa a normalização em Pascal e o próprio arquivo avisa que "mudar um lado
    /// exige mudar o outro" — sem esta guarda, o aviso era a única coisa entre um instalador novo e a
    /// grafia que não tem rota. Que o normalizador aponta a rota REAL do servidor continua cobrado no
    /// backend, pelo harness das três camadas.
    /// </remarks>
    [Fact]
    public void InstaladorENormalizador_DeclaramAsMesmasGrafias()
    {
        var iss = File.ReadAllText(Path.Combine(PastaDoPrintMonitor, "PrintMonitor.iss"));

        Assert.Equal(DashboardUrlNormalizer.CaminhoCanonico, Definicao(iss, "CaminhoRecurso"));
        Assert.Equal(DashboardUrlNormalizer.CaminhoAlternativo, Definicao(iss, "CaminhoRecursoAlternativo"));
        Assert.EndsWith(DashboardUrlNormalizer.CaminhoCanonico, Definicao(iss, "DashboardUrlPadrao"), StringComparison.Ordinal);
    }

    /// <summary>
    /// A bandeja do PrintMonitor não é linha do manifesto: ela sai dentro do PrintMonitorSetup
    /// (era <c>PrintMonitorTrayArchitectureTests</c>; a parte "não é Windows Service" segue no backend).
    /// </summary>
    [Fact]
    public void Bandeja_NaoEhLinhaDoManifestoDeInstaladores()
    {
        using var manifesto = JsonDocument.Parse(File.ReadAllText(Path.Combine(Raizes.Instaladores, "installer", "instaladores-ci.json")));
        var projetos = manifesto.RootElement.GetProperty("instaladores").EnumerateArray()
            .SelectMany(i => i.GetProperty("projetos").EnumerateArray().Select(p => p.GetString()))
            .ToList();

        Assert.DoesNotContain("SisPedraCaida.PrintMonitor.Tray", projetos);

        // O instalador que a empacota é o do PrintMonitor (linha do PrintMonitor.Service).
        Assert.Contains("SisPedraCaida.PrintMonitor.Service", projetos);
    }

    /// <summary>Lê o valor de um <c>#define</c> do script do Inno Setup.</summary>
    /// <param name="iss">Conteúdo do script.</param>
    /// <param name="nome">Nome da definição.</param>
    /// <returns>O valor entre aspas.</returns>
    private static string Definicao(string iss, string nome)
    {
        var achado = Regex.Match(iss, $@"^#define\s+{nome}\s+""(?<valor>[^""]*)""", RegexOptions.Multiline);
        Assert.True(achado.Success, $"#define {nome} não encontrado no PrintMonitor.iss.");
        return achado.Groups["valor"].Value;
    }
}
