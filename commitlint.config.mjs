/**
 * Configuração do commitlint — valida as mensagens de commit e o título do PR contra o padrão
 * Conventional Commits, base do versionamento automático via release-please (ver docs/Versionamento.md).
 *
 * ⚠️ Extensão `.mjs` (ESM) obrigatória: o `wagoid/commitlint-github-action` roda em runtime ESM e
 * REJEITA `configFile` com extensão `.js` ("please use .mjs instead"). Localmente o husky/commitlint
 * também carrega `.mjs` sem problema (o repo não é `type: module`, então `.mjs` é o jeito ESM explícito).
 *
 * O quê: estende `@commitlint/config-conventional` e fixa a lista de tipos permitidos + o limite de
 * caracteres do cabeçalho, conforme o PRD de Versionamento Automático via SemVer (seção 5).
 * Por quê: garantir que todo commit/PR que chega à `dev` seja parseável pelo release-please —
 * `feat` gera MINOR, `fix`/`perf` geram PATCH, `feat!`/`BREAKING CHANGE` geram MAJOR (só na promoção → prod).
 *
 * Usado nas duas camadas de validação:
 *  - Local: hook `commit-msg` do husky (`.husky/commit-msg`) — feedback imediato ao desenvolvedor.
 *  - CI: `wagoid/commitlint-github-action` no workflow `commitlint.yml` — portão autoritativo do merge.
 */
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Cabeçalho (`<tipo>[escopo]: <descrição>`) limitado a 100 caracteres (PRD §5).
    'header-max-length': [2, 'always', 100],
    // Tipos permitidos — apenas estes chegam à `dev` (PRD §5). `revert` incluído para reverts limpos.
    'type-enum': [
      2,
      'always',
      ['feat', 'fix', 'perf', 'refactor', 'docs', 'style', 'test', 'chore', 'ci', 'build', 'revert'],
    ],
  },
};
