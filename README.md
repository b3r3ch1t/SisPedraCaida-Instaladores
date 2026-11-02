# SisPedraCaida-Instaladores

Instaladores Windows (Inno Setup 6) dos agentes de estação do SisPedraCaida — agente TEF,
PrintMonitor e totem de autoatendimento —, do Migrador Galileu (ferramenta do time técnico) e o pipeline que os gera a partir de um commit do
[SisPedraCaida-Backend](https://github.com/b3r3ch1t/SisPedraCaida-Backend) e os publica nas releases
deste repositório.

- Guia completo (estrutura, comandos, CI/CD, armadilhas): [`CLAUDE.md`](CLAUDE.md)
- Gerar localmente: [`docs/InstaladoresBuildLocalWindows.md`](docs/InstaladoresBuildLocalWindows.md)
- Runner, variáveis e segredos do CI: [`docs/RunnerWindowsInstaladores.md`](docs/RunnerWindowsInstaladores.md)

O instalador **de campo** é o asset da release `prod-vX.Y.Z`; `dev-latest` é homologação.
