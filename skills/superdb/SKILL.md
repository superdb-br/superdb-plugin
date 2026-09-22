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
4. **"Login com Google/GitHub/Apple"** (web ou mobile) → `references/social-login.md`.
5. **"Quero saber quando alguém se cadastra/entra"** ou **"só quem eu autorizo pode
   criar conta"** → `references/auth-hooks.md`. ⚠️ Hook bloqueante **falha em ABERTO**:
   se o endpoint do cliente cair, o acesso é liberado. Diga isso antes de ele desenhar
   um controle de acesso em cima disso.
6. **"Login por WhatsApp / código por SMS / OTP"** → `references/recipes.md`
   (seção *Login por código*). ⚠️ O `verifyOtp` tem que receber o **mesmo alvo** do envio
   (phone com phone), e o **fallback de canal é do app** — a plataforma não troca sozinha.
7. **"Notificação no celular"** ("é sua vez", lembrete, aviso de pedido) → `references/push.md`.
   ⚠️ O token é o NATIVO (`getDevicePushTokenAsync`), nunca o `ExponentPushToken`; mandar é só com a
   `service_role` ou de função `security definer` do projeto (`push.enviar`).
8. **"Deu erro / não autentica / 401"** → veja `references/gotchas.md` PRIMEIRO.

## Conectar um agente ao projeto (MCP)

**Recomende sempre o servidor REMOTO**: `https://mcp.superdb.com.br/mcp`, colado
como conector no cliente MCP. Login em vez de API key; **uma conexão alcança N
projetos**, escolhidos no consentimento e alteráveis depois em Conta →
Aplicativos conectados. Sem Node, e funciona no Claude web e no celular.

O pacote `@superdb/mcp` (npx) continua válido **só** quando não há navegador para
completar o login: automação, CI, script que roda sozinho.

No Claude, o link
`https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=SuperDB&connectorUrl=https%3A%2F%2Fmcp.superdb.com.br%2Fmcp`
abre o diálogo com nome e URL preenchidos. No consentimento dá para marcar
**todos os projetos, inclusive os novos** (a conexão passa a alcançar sozinha
todo projeto em que a pessoa é owner/admin).

⚠️ Com mais de um projeto na conexão, o agente PRECISA dizer em qual opera — se
não disser, a chamada é recusada com a lista. Não existe "usar o primeiro".

Para **ler**, use `superdb_query_sql` (transação somente leitura — o Postgres
recusa escrita; o cliente roda sem pedir confirmação). `superdb_run_sql` é para
o que ALTERA (DDL, INSERT/UPDATE/DELETE) e pede confirmação.

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
- **⚠️ O padrão da plataforma é ABERTO, não fechado.** Tabela criada por SQL, migration,
  Drizzle ou MCP nasce com `GRANT SELECT` para a **anon** e CRUD para **authenticated**, e
  **sem RLS**. Só o criador de tabelas do painel liga RLS sozinho. Ou seja: `create table`
  e pronto = tabela pública. Ligue RLS e escreva a policy **na mesma migration**; os
  Advisors do projeto listam as que ficaram sem. (Com RLS ligada e sem policy, aí sim
  nega tudo.)
- **`auth.uid()`, `auth.jwt()`, `auth.role()` e `auth.email()` existem** desde 30/07/2026 —
  policy copiada de projeto Supabase roda aqui sem edição. Antes disso o schema `auth` não
  existia e todo exemplo de RLS falhava com `schema "auth" does not exist`.
- **O clone de um group NÃO leva as policies** — leva só a estrutura. Tenant recém-provisionado
  tem as tabelas e nenhuma proteção. Aplicar a RLS logo depois de provisionar é passo
  obrigatório, não opcional.
- **Login social precisa de 2 cliques no dashboard**: ligar o provedor **e** cadastrar a
  URL de retorno em *Autenticação → URLs de redirecionamento*. Sem a segunda, o login
  volta pra `/` sem erro nenhum. Veja `references/social-login.md`.
- **`.storage` funciona** (`db.storage.from('proj_<slug>_<bucket>').upload/download/list/remove/createSignedUrl`,
  com o nome COMPLETO do bucket) — o cliente minta o token de storage (`/st/v1/token`) sozinho.
  Não há pasta por usuário: todo usuário logado do projeto acessa todos os buckets do projeto. Só **`.channel` (realtime)** ainda é
  stub: minte `/rt/v1/token` **com a sessão** (`db.auth.getDataPlaneToken()`) e use
  `@supabase/realtime-js`. O realtime segue o RLS da tabela. Veja `references/recipes.md`.

## Arquivos desta skill
- `references/connection-contract.md` — URLs, keys, headers, o token de dados (a verdade técnica).
- `references/migrations-via-api.md` — aplicar schema/DDL/migrations via API (Management Key `sdb_pmk_`), sem colar SQL no dashboard.
- `references/provisao-via-group-key.md` — **SaaS factory / vertical**: provisionar N tenants isolados 100% via API (Group Key `sdb_gk_`) — provisiona + minta mgmt key + aplica RLS, sem dashboard. Inclui **publicar versão do template** (`/template/publish`, passo de deploy) e a **cobrança por tenant** (inclusos por plano; grátis bloqueia, pago paga R$ 5,00/mês por excedente).
- `references/recipes.md` — receitas: auth, CRUD, RLS, **mobile (Expo/RN)**.
- `references/social-login.md` — **login social** (Google/GitHub/Apple) por projeto: ligar no dashboard, allowlist de redirect, PKCE mobile.
- `references/lgpd.md` — **dado pessoal**: o que a plataforma entrega (residência em SP, CPF/CNPJ cifrado, auditoria encadeada, apagamento definitivo), o que **não** existe (ISO 27001, SAML/SCIM, portabilidade da conta) e o checklist de um app novo. **Começa pela pegadinha da RLS**, que é o que mais custa caro.
- `references/auth-hooks.md` — **webhooks de autenticação**: reagir a signup/signin/exclusão, ou
  BLOQUEAR quem entra. Traz as duas armadilhas que quebram toda primeira integração (segredo é
  hex mas o HMAC é sobre bytes; assinar o corpo CRU) e o aviso de que bloqueante é fail-open.
- `references/push.md` — **push no iPhone e no Android**: credenciais (.p8 e conta de serviço), registrar o aparelho no app, mandar pelo servidor ou de gatilho no banco, recibo e motivos de recusa.
- `references/gotchas.md` — armadilhas + troubleshooting (leia antes de debugar 401).
- `playbooks/new-project.md` — **a primeira conexão**, passo a passo: conta → projeto → credenciais → cliente → tabela com RLS → MCP → checklist de ir ao ar.
- `playbooks/migrate-from-supabase.md` — passo a passo de migração.
- `templates/superdb.ts` + `.env.example` — cliente self-contained (alternativa zero-dep ao `@superdb/client`) + env.
