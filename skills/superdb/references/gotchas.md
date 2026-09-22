# Armadilhas + troubleshooting SuperDB

Leia ISTO antes de debugar. A maioria dos erros é uma das coisas abaixo.

## 401 / "não autentica" ao ler dados
- **Esqueceu o `project`?** Era a causa #1 até 31/08/2026 — sem `project: '<slug>'` o
  `Accept-Profile` não ia e o portão rejeitava com `401 unauthorized`, mesmo com a chave
  correta. **Isso foi corrigido**: `api.superdb.com.br` agora preenche o profile a partir
  da própria chave. Se você viu esse 401 antes dessa data, tente de novo.
  (Ainda assim, passe o `project` — é o que faz o cliente pedir o schema certo desde a
  origem, e o único jeito de o erro aparecer cedo se você trocar de projeto.)
- **Usou a URL errada?** Dados são em `api.superdb.com.br/tabela` — **sem `/rest/v1/`** e
  **não** em `auth.superdb.com.br`. (O dashboard antigo mostrava o path errado.)
- **Key do formato velho?** Se a key não começa com `eyJhbGciOiJFUzI1NiI...` (header ES256),
  ela é antiga (HS256) e não funciona mais. Pegue a key atual no dashboard (aba Connect).
- **Regenerou a key?** A chave ANTIGA morre quando você regenera. Use a nova.

## 403 / "forbidden" mesmo logado
- A tabela tem **RLS ligada mas sem política** → nega tudo. Crie a política (veja
  `recipes.md` → RLS). Sem política = deny-by-default (é o seguro).
- O `Accept-Profile` não bate com o projeto do token (você misturou slugs).

## SQL deu certo, mas voltou com `avisos` (ou `WARNING`)
O SuperDB avisa na resposta do próprio comando quando ele deixou um risco (campo `avisos` do
`/db/exec`, faixa amarela no SQL Editor, topo da resposta no MCP, `WARNING` em conexão direta):
- **`rls_desligada`**: alguém rodou `disable row level security` numa tabela exposta. Toda tabela
  nova dá leitura ao `anon` e escrita ao `authenticated`, então sem RLS **qualquer pessoa com a
  chave pública lê e altera a tabela inteira**, e as policies dela deixam de valer. Religue
  (`enable row level security`) e crie a policy que faltava. O "conserto" clássico que abre a
  tabela é desligar a RLS porque um insert ou upload deu erro de policy.
- **`grant_public_convertido`**: `grant ... to public` vira `to anon, authenticated` na hora.
  `PUBLIC` num banco compartilhado inclui os papéis de todos os projetos. O acesso do app pela
  API não muda; escreva direto `to anon, authenticated`.

## `.channel` (realtime) joga erro
- `.storage` **funciona** (`db.storage.from('proj_<slug>_<bucket>').upload/...` — minta `/st/v1/token` sozinho).
  O nome do bucket é o COMPLETO: com o curto (`from('avatars')`) o Storage não acha o bucket.
- Só `.channel` (realtime) **ainda é stub**: minte `POST /rt/v1/token` e use
  `@supabase/realtime-js` em `wss://realtime.superdb.com.br/socket` (veja `recipes.md`).

## Realtime conecta mas não entrega nada
O realtime **segue o RLS da tabela** com o papel de quem pediu o token (claim `sdb_role`):
- Token pedido com a **anon key** recebe só o que um visitante sem login leria. Com usuário
  logado, minte com `await db.auth.getDataPlaneToken()` (a sessão; renove com `refreshSession()`
  quando o `/rt/v1/token` der 401).
- Regra que consulta **outra tabela** (`exists (select 1 from membros …)`) não vale no realtime —
  ele confere a regra com o papel `rt_<schema>`, que não lê as outras tabelas. Use uma função
  `security definer` na regra. O painel avisa ao ativar a tabela.
- A tabela precisa ter RLS ligada para entrar no realtime; desligar a RLS a tira de lá.
- **Não crie policy `TO rt_<schema>`**: a plataforma mantém o espelho (`sdb_rt_read` +
  `sdb_rt_limite`, restritiva) sozinha, e policy nenhuma alarga o que ele entrega.
- `DELETE` chega a quem está inscrito na tabela só com a chave primária.
- `/rt/v1/token` com **401 API key revogada ou inválida**: as chaves foram regeneradas no painel;
  **403 project is not active**: projeto suspenso; **403 forbidden: not a user of …**: usuário
  banido/apagado. São as mesmas travas da API (o mint consulta o banco antes de emitir).

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

## Login social: cliquei em "entrar com Google" e voltei sem nada (nem erro)
A causa quase sempre é a **allowlist**: o `redirectTo` não está cadastrado em
*Autenticação → URLs de redirecionamento* do projeto. O callback então descarta o destino
e manda pra `/` — silencioso de propósito (não vazar token pra URL não-registrada).
- Web: cadastre a URL **absoluta** (`https://meuapp.com.br/auth/callback`). Relativa (`/auth/callback`)
  resolve contra o host de **auth**, não o do seu app.
- Mobile: cadastre o deep link exato (`meuapp://auth`).
- Provedor desligado no projeto → aí sim vem `oauth_not_enabled` (400).
- Detalhes e tabela de erros (`pkce_mismatch`, `invalid_code`, …): `social-login.md`.

## Login social no mobile: "PKCE requer Web Crypto (crypto.subtle)"
React Native não traz WebCrypto. Instale `expo-crypto` (Expo) ou `react-native-quick-crypto`
(bare). O SDK **falha explícito** de propósito — não existe fallback `plain` (vazaria o
verifier em log). Precisa de `@superdb/client` ≥ 0.2.0.

## Mobile: "localStorage is not defined"
- React Native não tem localStorage. Passe `storage: AsyncStorage` no createSuperDB
  (veja `recipes.md` → Mobile).

## service_role: acesso total ao PRÓPRIO projeto (não é global)
- A service_role tem acesso ADMINISTRATIVO completo (SELECT/INSERT/UPDATE/DELETE) às suas tabelas
  de **negócio** via PostgREST — a plataforma cria a policy `sdb_service_role_all` (PERMISSIVE, FOR
  ALL, `using(true)`) automaticamente em cada tabela que você cria (event trigger no CREATE TABLE).
  Ou seja, igual ao Supabase: a service_role **ignora sua RLS de negócio**. Use pra escrita
  administrativa no backend (upserts, jobs, seed) sem escrever política pra ela.
- **Mas não é bypass GLOBAL**: ela é confinada ao SEU projeto (`proj_<slug>`) pelo gate do data-plane
  (pre_request) — NÃO toca outro tenant, nem as tabelas internas `auth_*` (essas são revogadas). Por
  isso "não bypassa RLS" no sentido de superusuário — é uma policy explícita, escopada ao projeto.
- **DDL/migrations e SQL multi-tabela cru** → use a Management Key (`sdb_pmk_`) no `/db/exec`.
- Secreta: nunca no client/frontend/mobile, só backend.

## O que NÃO fazer
- ❌ Não coloque a `service_role` no frontend/app/mobile. Só backend.
- ❌ Não invente `/rest/v1/` na URL de dados.
- ❌ Não esqueça de ligar RLS + criar política — senão ou vaza (sem RLS) ou nega tudo (RLS sem política).
- ❌ Não desligue a RLS para destravar um insert: o que falta é a policy de `INSERT`.
- ❌ Não use `grant ... to public`: use `to anon, authenticated`.
- ❌ Não trate `.storage`/`.channel` como prontos.

## Quando travar de verdade
Cheque, nesta ordem: (1) o `project` está certo? (2) a URL é `api.*` sem `/rest/v1`? (3) a
key é a atual (ES256) do dashboard? (4) a tabela tem RLS + política? Isso resolve ~95% dos casos.

## Link mágico / "esqueci a senha" não volta pro app
O `redirect_to` do link mágico (`/auth/v1/signin/magic-link`) e da redefinição de senha
(`/auth/v1/password/forgot`) tem de estar cadastrado, **exatamente como o app o pede**, em
*Autenticação → URLs de redirecionamento* (a mesma lista do login social). Fora da lista, o
link cai no destino padrão da plataforma. A redefinição chega em `redirect_to#token=…`: a
página lê o token do fragmento e chama `POST /auth/v1/password/reset {token, new_password}`
(token de 1h, uso único).

## Broadcast/presence: canal privado com o nome do projeto
Canal PÚBLICO do realtime é compartilhado entre TODOS os projetos da plataforma (um tenant só):
o "sala-1" de outro projeto é o mesmo canal. Para broadcast e presence use
`rt.channel('proj_<slug>:sala-1', { config: { private: true } })` — o servidor só deixa entrar e
mandar quem tem token do mesmo projeto (policy em `realtime.messages`). Canal privado
sem o prefixo `proj_<slug>:` é recusado.

Use o canal privado **também para postgres_changes**. Ele sozinho não vaza (cada evento é
roteado pela inscrição, com o RLS da tabela nos claims dela), mas o canal que hoje só escuta a
tabela é o mesmo que amanhã ganha um "fulano está digitando" — e aí o nome público passa a ser
namespace compartilhado. Uma regra só, sem pegadinha.

## Senha: conta sem senha CRIA com a sessão; conta com senha troca com a atual
`PUT /auth/v1/user/password` (Bearer = `access_token` da sessão). Quem entrou por código, link
mágico ou login social não tem senha: manda só `{ new_password }` e a resposta traz
`criada: true`. Conta que já tem senha manda também `current_password` (sem ela: 400
`current_password_required`) e as outras sessões caem. Durante o "entrar como" do painel,
criar é recusado (403). Não existe `updateUser({ password })` no SDK: use a rota.

## Link mágico: a sessão chega no fragmento, sem o data_plane_token
O link volta para `redirect_to#access_token=…&refresh_token=…`. Passe os dois para
`db.auth.setSession(...)` e chame `db.auth.refreshSession()` — é a renovação que traz o
`data_plane_token`; sem ela o `db.from()` sai como anon e a RLS devolve vazio. Link vencido ou
usado volta com `?error=…`.
