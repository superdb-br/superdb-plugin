# Armadilhas + troubleshooting SuperDB

Leia ISTO antes de debugar. A maioria dos erros é uma das coisas abaixo.

## 401 / "não autentica" ao ler dados
- **Esqueceu o `project`?** Sem `project: '<slug>'` no createSuperDB, o `Accept-Profile`
  não vai → o portão rejeita. É a causa #1.
- **Usou a URL errada?** Dados são em `api.superdb.com.br/tabela` — **sem `/rest/v1/`** e
  **não** em `auth.superdb.com.br`. (O dashboard antigo mostrava o path errado.)
- **Key do formato velho?** Se a key não começa com `eyJhbGciOiJFUzI1NiI...` (header ES256),
  ela é antiga (HS256) e não funciona mais. Pegue a key atual no dashboard (aba Connect).
- **Regenerou a key?** A chave ANTIGA morre quando você regenera. Use a nova.

## 403 / "forbidden" mesmo logado
- A tabela tem **RLS ligada mas sem política** → nega tudo. Crie a política (veja
  `recipes.md` → RLS). Sem política = deny-by-default (é o seguro).
- O `Accept-Profile` não bate com o projeto do token (você misturou slugs).

## "from is not a function" / `.storage`/`.channel` jogam erro
- `.storage` e `.channel` **ainda não estão implementados** no cliente. NÃO tente usá-los
  pelo `db.` — use os SDKs do Supabase apontados pros hosts (veja `recipes.md`).

## `db.from('auth_users')` (ou qualquer `auth_*`) dá 401 / permission denied
As tabelas internas de auth do tenant (`auth_users`, `auth_sessions`, `auth_signing_keys`,
`auth_mfa_factors`, etc.) são **bloqueadas no data-plane REST de propósito** — têm hash de
senha, chaves privadas e PII. anon/authenticated nunca leem/escrevem nelas (401/permission denied).
- **Dados do usuário logado** → use `db.auth.getUser()` / `db.auth.getSession()`. NUNCA `db.from('auth_users')`.
- **Perfil do usuário no app** → crie uma tabela de NEGÓCIO sua (ex: `profiles`) com `user_id`
  referenciando o id do usuário (o `sub`), RLS por `user_id`. É o mesmo padrão do Supabase
  (auth privado + `public.profiles`). Veja `recipes.md` → Perfil do usuário.

## `npm install @superdb/client` falha (404)
- O pacote **está publicado** (`@superdb/client` + `@superdb/auth-js`, escopo `@superdb`, públicos).
  Um 404 quase sempre é cache de mirror/offline ou propagação de CDN logo após um publish —
  tente de novo, ou force o registro: `npm install @superdb/client --registry=https://registry.npmjs.org`.
- Não precisa de login/token pra instalar (é público). Se persistir, use o `templates/superdb.ts`
  (zero-dep) como alternativa — é o mesmo contrato.

## Mobile: "localStorage is not defined"
- React Native não tem localStorage. Passe `storage: AsyncStorage` no createSuperDB
  (veja `recipes.md` → Mobile).

## service_role não "faz tudo"
- Hoje a service_role é **RLS-gated** (respeita as políticas, igual authenticated). Ela NÃO
  bypassa RLS. Para operações administrativas que ignoram RLS, use o SQL Editor do dashboard
  (roda como dono do projeto). Não exponha a service_role no client de qualquer forma.

## O que NÃO fazer
- ❌ Não coloque a `service_role` no frontend/app/mobile. Só backend.
- ❌ Não invente `/rest/v1/` na URL de dados.
- ❌ Não esqueça de ligar RLS + criar política — senão ou vaza (sem RLS) ou nega tudo (RLS sem política).
- ❌ Não trate `.storage`/`.channel` como prontos.

## Quando travar de verdade
Cheque, nesta ordem: (1) o `project` está certo? (2) a URL é `api.*` sem `/rest/v1`? (3) a
key é a atual (ES256) do dashboard? (4) a tabela tem RLS + política? Isso resolve ~95% dos casos.
