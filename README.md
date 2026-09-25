# SuperDB — plugin do Claude Code

Skill de integração com o **SuperDB** (BaaS multi-tenant: Postgres + Auth + REST + Storage + Realtime, drop-in do `supabase-js`). Instala como plugin do Claude Code pro seu Claude saber conectar apps no SuperDB.

## Instalar

```
/plugin marketplace add superdb-br/superdb-plugin
/plugin install superdb@superdb
```

Abra um Claude novo e pronto — quando você pedir pra construir/conectar um app no SuperDB, ele segue a skill.

## Atualizar

```
/plugin marketplace update superdb
```

## Servidor MCP incluso

O plugin já traz o `.mcp.json` do **MCP remoto** do SuperDB
(`https://mcp.superdb.com.br/mcp`). Depois de instalar, o agente pergunta se você
quer conectar; o acesso é por **login**, não por chave colada em arquivo, e você
escolhe na tela de consentimento quais projetos ele enxerga.

Sem conectar, a skill continua funcionando: ela ensina a usar a API. Conectado, o
agente lê e escreve no seu projeto de verdade (listar tabelas, rodar SQL de
leitura, aplicar migrations).

## O que cobre

- Conectar app web ou celular (`npm install @superdb/client`, `createClient(url, anonKey, { project })`)
- Login e cadastro (`db.auth`): senha, link mágico, código por e-mail, login social e código pelo WhatsApp
- Dados pela API REST (`db.from(...)`) com RLS, e o que mudou no SDK 0.3 (a sessão se renova sozinha, `upsert`, `or`, `count`, `onAuthStateChange`)
- Aplicar schema e migrations por **management key**, sem colar SQL no painel
- Provisionar clientes por API (group key), para quem vende o mesmo app para vários
- LGPD: exportar e apagar os dados de uma pessoa
- Notificação push no iPhone e no Android
- Conectar um agente ao projeto pelo **MCP remoto** (`https://mcp.superdb.com.br/mcp`), com login em vez de chave
- Migrar do Supabase, com as senhas dos usuários vindo junto
- Armadilhas comuns (as tabelas `auth_*` não saem pela REST: use `profiles`, e outras)

Detalhes: `skills/superdb/SKILL.md`. Site: https://www.superdb.com.br

## Licença

MIT (ver `LICENSE`). O plugin é instrução e configuração: os trechos de
`skills/superdb/templates/` existem para você copiar para dentro do seu projeto
sem pensar em licença. O servidor do SuperDB tem licença própria.
