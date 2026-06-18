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

## O que cobre

- Conectar app web/mobile (`npm install @superdb/client`, `createClient(url, anonKey, { project })`)
- Login/cadastro (`db.auth`), dados via REST (`db.from(...)`) com RLS
- Aplicar schema/migrations via **management key** (sem colar SQL no dashboard)
- Migrar de Supabase → SuperDB
- Armadilhas comuns (auth_* não via REST → use `profiles`, etc.)

Detalhes: `skills/superdb/SKILL.md`. Site: https://www.superdb.com.br
