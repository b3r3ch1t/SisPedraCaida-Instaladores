using System.Reflection;

namespace SisPedraCaida.Instaladores.Tests;

/// <summary>
/// As duas árvores que as guardas comparam: a deste repositório (`.iss`, scripts, manifesto) e o
/// checkout do backend (código C# dos agentes, `src/`, scripts de publicação).
/// </summary>
/// <remarks>
/// O backend vem do <c>BackendDir</c> gravado no assembly pelo <c>.csproj</c> — a mesma árvore contra
/// a qual os tipos referenciados compilaram. Ler <c>src/</c> de outro lugar compararia o <c>.iss</c> com
/// um C# diferente do que o teste está usando.
/// </remarks>
internal static class Raizes
{
    /// <summary>Raiz deste repositório: a pasta que contém <c>installer/instaladores-ci.json</c>.</summary>
    public static string Instaladores { get; } = LocalizarInstaladores();

    /// <summary>Raiz do checkout do SisPedraCaida-Backend usado na compilação.</summary>
    public static string Backend { get; } = LocalizarBackend();

    /// <summary>Sobe do diretório do teste até achar o manifesto de instaladores.</summary>
    /// <returns>Caminho da raiz.</returns>
    private static string LocalizarInstaladores()
    {
        var atual = new DirectoryInfo(AppContext.BaseDirectory);

        while (atual is not null && !File.Exists(Path.Combine(atual.FullName, "installer", "instaladores-ci.json")))
        {
            atual = atual.Parent;
        }

        Assert.True(atual is not null, "Raiz do SisPedraCaida-Instaladores não encontrada (installer/instaladores-ci.json).");

        return atual!.FullName;
    }

    /// <summary>Lê o <c>BackendDir</c> que o build gravou no assembly e confere que é o backend.</summary>
    /// <returns>Caminho da raiz do backend.</returns>
    private static string LocalizarBackend()
    {
        var gravado = typeof(Raizes).Assembly
            .GetCustomAttributes(typeof(AssemblyMetadataAttribute), inherit: false)
            .OfType<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "BackendDir")?.Value;

        Assert.False(string.IsNullOrWhiteSpace(gravado), "BackendDir ausente do assembly de testes.");
        Assert.True(File.Exists(Path.Combine(gravado!, "SisPedraCaida.slnx")),
            $"BackendDir '{gravado}' não é um checkout do SisPedraCaida-Backend.");

        return gravado!.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }
}
