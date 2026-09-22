# Playbook: a primeira conexão de um projeto novo com o SuperDB

Do zero a um app que faz login, lê e grava dados — com a segurança certa desde a
primeira tabela. Cada passo abaixo foi rodado contra a plataforma; onde algo não
funciona, está escrito que não funciona.

**Antes de começar, saiba o que vem de fábrica:** tabela criada por SQL nasce
**sem RLS e legível pela anon key**. O passo 4 existe por causa disso e não é
opcional. Detalhe completo em `references/lgpd.md`.

---

## 1. Criar a conta e o projeto (uma vez, no navegador)

1. https://app.superdb.com.br → **Criar conta**. O cadastro pede CPF ou CNPJ
   (identidade obrigatória, exigência fiscal brasileira) e confirmação de
   e-mail — sem confirmar, o login não passa.
2. **Novo projeto** → dê um nome. O **slug** é o identificador técnico e
   **aceita só `a-z`, `0-9` e `_`** (3 a 31 caracteres). "Clínica Demo" vira
   `clinica_demo`; hífen é recusado.
3. Ligue o **2FA** em *Minha conta → Segurança*. Toda a isolação dos seus dados
   depende de ninguém entrar nesta conta.

> Não existe provisionamento por CLI. O `@superdb/cli` nunca funcionou e não
> está publicado. O caminho é o painel — ou, para SaaS multi-cliente, a Group
> API Key (`references/provisao-via-group-key.md`).

## 2. Pegar as credenciais

Projeto → **API Keys**. São três coisas diferentes e vale saber qual é qual:

| Credencial | Onde ela pode aparecer | Para quê |
|---|---|---|
| **anon key** (`eyJhbGciOiJFUzI1NiI…`) | No app, no navegador, no celular | Leitura/escrita do usuário final. **Respeita RLS** |
| **service_role key** | **Só no servidor** | Ignora as policies. Se vazar, vazou tudo |
| **Management key** (`sdb_pmk_`) | Só em CI/script/agente | Roda DDL e migrations via API |

O **Endpoint** dessa tela (`auth.superdb.com.br`) é o que vai no `createClient`.
Em *Configurações* aparece outro, o **Endpoint REST** (`api.superdb.com.br`):
esse é o PostgREST, usado quando você fala HTTP direto, sem SDK.

## 3. Conectar o app

```bash
npm install @superdb/client
```

```ts
// src/lib/superdb.ts
import { createClient } from '@superdb/client'

export const superdb = createClient(
  'https://auth.superdb.com.br',
  process.env.NEXT_PUBLIC_SUPERDB_ANON_KEY!,
  { project: 'meu_app' },   // obrigatório — é o schema do seu projeto
)
```

Três diferenças em relação ao Supabase, e só três: a URL, a key, e o
`{ project }`. `.auth`, `.from().select()`, `.rpc()` e `.storage` são a mesma
API que você já conhece.

*Alternativa zero-dependência:* copie `templates/superdb.ts` para o projeto em
vez de instalar o pacote.

**Mobile (Expo/React Native):** passe `AsyncStorage` — sem isso a sessão morre
ao fechar o app. Veja `references/recipes.md`.

**`.channel` (realtime) ainda é stub** no cliente: minte `/rt/v1/token` com a sessão
(`db.auth.getDataPlaneToken()`) e use `@supabase/realtime-js`. O realtime segue o RLS
da tabela — veja `references/recipes.md`.

## 4. Criar as tabelas — e ligar RLS na mesma migration

```sql
create table tarefas (
  id          bigint generated always as identity primary key,
  user_id     uuid not null,
  titulo      text not null,
  done        boolean not null default false,
  created_at  timestamptz not null default now()
);

-- NÃO É OPCIONAL. Sem esta linha a tabela é legível pela anon key, que é
-- pública e está no bundle do seu app.
alter table tarefas enable row level security;

create policy "cada um vê o seu" on tarefas
  for all to authenticated
  using      (user_id = auth.uid())
  with check (user_id = auth.uid());
```

`auth.uid()`, `auth.role()`, `auth.email()` e `auth.jwt()` existem no cluster e
funcionam dentro de policy — é a mesma escrita do Supabase.

Rode isso no **Editor SQL** do painel, ou por API com a management key
(`references/migrations-via-api.md`), ou pelo MCP com `superdb_run_sql`.

**Confira antes de seguir:** projeto → **Saúde**. Ele lista toda tabela sem RLS
que a anon key alcança, com o `ALTER TABLE` pronto para copiar. A lista precisa
estar vazia. Pelo MCP: `superdb_list_policies`.

## 5. Usar

```ts
await superdb.auth.signUp({ email, password })
// ou
await superdb.auth.signInWithPassword({ email, password })

const { data: { session } } = await superdb.auth.getSession()
const uid = session?.user.id

await superdb.from('tarefas').insert({ user_id: uid, titulo: 'primeira tarefa' })
const { data } = await superdb.from('tarefas').select()
```

## 6. Ligar a IA ao banco (opcional, mas é o atalho)

Projeto → **API Keys → Conectar sua IA (MCP)**. Cole a config no Claude Desktop,
Cursor ou Codex e gere a chave pelo botão. A partir daí o agente lê o schema,
roda migrations e revisa as policies sem você sair do editor:

> "Quais tabelas minhas ainda não têm política de RLS?"

Com mais de um projeto, cada um entra como um servidor com nome próprio
(`superdb-<slug>`) no mesmo `mcpServers` — o nome já vem preenchido justamente
para as configs não se sobrescreverem.

## 7. Antes de colocar no ar

- [ ] **Saúde/Advisors sem nenhum achado crítico** — é o passo que mais pega
- [ ] anon key é ES256 (começa com `eyJhbGciOiJFUzI1NiI`)
- [ ] `project` setado no `createClient`
- [ ] A `service_role` não aparece em nenhum arquivo do front
- [ ] `.env` no `.gitignore`; a anon key pode ir para o bundle, a outra não
- [ ] **URLs de redirecionamento** cadastradas, se usa login social — sem elas o
      callback recusa o redirect e o login volta para `/` sem erro nenhum
- [ ] Template de e-mail revisado (Emails) — sai com o seu nome, não com o nosso
- [ ] 2FA ligado na sua conta
- [ ] Se o app trata dado pessoal: leia `references/lgpd.md`. Ele diz o que a
      plataforma cobre (residência em SP, CPF/CNPJ cifrado, auditoria
      encadeada, apagamento definitivo) e o que continua sendo seu (base legal,
      retenção, ROPA) — e o que **não** existe, para você não prometer

## O que dá errado com mais frequência

| Sintoma | Causa quase sempre |
|---|---|
| `401` em tudo | Faltou `{ project: '<slug>' }` no `createClient` |
| `PGRST106` | Slug errado, ou projeto recém-criado ainda sincronizando |
| Login social volta para `/` sem erro | URL de redirecionamento não cadastrada |
| Query devolve 0 linhas com dado no banco | RLS ligada e nenhuma policy que caiba |
| Query devolve TUDO para qualquer visitante | RLS **não** ligada — veja o passo 4 |

Mais em `references/gotchas.md`.
