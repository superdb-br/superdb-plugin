---
name: superdb
description: Use ao criar um app novo (web ou mobile) que precisa de banco de dados + login, ou ao migrar um projeto Supabase para o SuperDB. Cobre provisionar projeto, conectar o app (auth + dados via REST), e os padrões do dia-a-dia. Ancorado em Supabase — se você conhece supabase-js, conhece isto.
---

# SuperDB

SuperDB é uma plataforma de backend (Postgres + Auth + Storage + APIs) **compatível
com o modelo do Supabase**. Cada app vira um **projeto** (um schema isolado) num
SuperDB compartilhado — você não roda um stack inteiro por app.

**Se você conhece Supabase, isto é quase igual:** mesmo `.auth`, mesmo `.from().select()`.
O que muda são 3 coisas (URL, key, e passar o slug do projeto). O resto é o que você já sabe.

## Modelo mental (vindo do Supabase)

| No Supabase | No SuperDB |
|---|---|
| Um projeto = um Postgres dedicado | Um projeto = um **schema** (`proj_<slug>`) num Postgres compartilhado |
| `createClient(url, anonKey)` | `createClient(url, anonKey, { project: '<slug>' })` — **a MESMA função + o slug** |
| Dados em `url/rest/v1/tabela` | Dados em `api.superdb.com.br/tabela` (host separado, **sem** `/rest/v1`) |
| anon/service_role keys | iguais (anon pública, service_role secreta) |
| RLS isola por usuário | RLS isola por usuário **+** a plataforma isola por projeto (binding) |

**Hosts:** `auth.superdb.com.br` (login/cadastro) · `api.superdb.com.br` (dados) ·
`storage.superdb.com.br` (arquivos) · `realtime.superdb.com.br` (tempo real) ·
`app.superdb.com.br` (dashboard).

## Árvore de decisão — o que o usuário quer?

1. **"Criar um app/projeto novo"** → siga `playbooks/new-project.md`
   (provisiona no dashboard → pega as keys → cola o cliente → pronto).
2. **"Migrar meu projeto Supabase pro SuperDB"** → siga `playbooks/migrate-from-supabase.md`.
3. **"Como faço X (login, ler/gravar dados, mobile)"** → veja `references/recipes.md`.
4. **"Deu erro / não autentica / 401"** → veja `references/gotchas.md` PRIMEIRO.

## Setup mínimo (qualquer projeto novo)

1. **Provisione** em https://app.superdb.com.br → criar conta → criar projeto.
   Anote o **slug** e copie a **anon key** (aba Connect/API).
2. **Cliente:** `npm install @superdb/client` (drop-in do supabase-js — `.auth` + `.from()`/`.rpc()`,
   ESM e CJS). Para mobile (Expo/RN), passe `AsyncStorage` como `storage`.
   *Alternativa zero-dependência:* copie `templates/superdb.ts` (mesmo contrato inline, usa `createSuperDB({...})`).
3. **Use:**
   ```ts
   import { createClient } from '@superdb/client'
   const db = createClient('https://auth.superdb.com.br', process.env.SUPERDB_ANON_KEY!, {
     project: 'meu_projeto',          // <- a ÚNICA diferença pro supabase-js
   })
   await db.auth.signInWithPassword({ email, password })
   const { data, error } = await db.from('tarefas').select().eq('done', false)
   ```

## Regras de ouro (não erre)

- **SEMPRE passe `project: '<slug>'`** — sem ele os dados não roteiam (toma erro).
- **`api.superdb.com.br` SEM `/rest/v1/`** — esse path é do Supabase, aqui não existe.
- **anon key** vai no frontend/app (é pública, RLS protege). **service_role** SÓ no
  backend, nunca no client/mobile.
- **Dados de usuário precisam de login** — o `db.from()` usa o token da sessão
  automaticamente após `signIn`. Sem login, usa a anon key (só vê o que a RLS-anon permite).
- **Ative RLS + políticas** nas suas tabelas (igual Supabase) — é o que isola os dados
  por usuário. Sem política, a tabela com RLS nega tudo (deny-by-default).
- **Ainda NÃO tem** no cliente: `.storage` e `.channel` (arquivos/tempo-real). Para
  esses, veja `references/gotchas.md`.

## Arquivos desta skill
- `references/connection-contract.md` — URLs, keys, headers, o token de dados (a verdade técnica).
- `references/migrations-via-api.md` — aplicar schema/DDL/migrations via API (Management Key `sdb_pmk_`), sem colar SQL no dashboard.
- `references/recipes.md` — receitas: auth, CRUD, RLS, **mobile (Expo/RN)**.
- `references/gotchas.md` — armadilhas + troubleshooting (leia antes de debugar 401).
- `playbooks/new-project.md` — passo a passo de projeto novo.
- `playbooks/migrate-from-supabase.md` — passo a passo de migração.
- `templates/superdb.ts` + `.env.example` — cliente self-contained (alternativa zero-dep ao `@superdb/client`) + env.
