# Contrato de conexão SuperDB (a verdade técnica)

## Hosts
| Host | Pra quê |
|---|---|
| `https://auth.superdb.com.br` | Login/cadastro (`/auth/v1/*`), gestão (`/platform/v1/*`) |
| `https://api.superdb.com.br` | **Dados (PostgREST).** Tabela na raiz: `/minha_tabela` (forma canônica). Desde 31/08/2026 `/rest/v1/minha_tabela` também é aceito, pro supabase-js funcionar sem ajuste. |
| `https://storage.superdb.com.br` | Arquivos (S3-compat) |
| `https://realtime.superdb.com.br` | Tempo real |
| `https://app.superdb.com.br` | Dashboard (provisionar projeto, ver keys) |

## Como a autenticação de DADOS funciona (importante)
O PostgREST (api.*) verifica tokens **ES256** (chave pública da plataforma, via JWKS).
Existem 2 tipos de token que ele aceita:

1. **anon key** — JWT estático ES256 (do dashboard). role=`anon`. Pra acesso público
   (RLS-anon). Pode ir no frontend. Carrega `project_id` + `project_schema` + uma versão (`kv`).
2. **data_plane_token** — JWT ES256 de **sessão**, emitido no `/auth/v1/signin` (e otp/
   magic-link/refresh), junto do `access_token`. role=`authenticated`, sub=usuário. É o que
   dá acesso **por-usuário** (RLS avalia quem é). Curto (1h); renova no refresh.

   > O `templates/superdb.ts` cuida disso: guarda o `data_plane_token` da sessão e o usa no
   > `.from()` automaticamente. Sem login, cai pra anon key.

## Headers de uma request de dados
```
GET https://api.superdb.com.br/minha_tabela?select=*
Authorization: Bearer <data_plane_token ou anon key>
apikey: <anon key>
Accept-Profile: proj_<slug>      # leitura (GET)   — opcional desde 31/08/2026
Content-Profile: proj_<slug>     # escrita (POST/PATCH/DELETE) — idem
```

O `Accept-Profile`/`Content-Profile` é o que **roteia** para o seu schema, e é
**amarrado ao token**: a plataforma rejeita se o profile não bater com o projeto do
token. É isso que isola um projeto do outro, e continua valendo.

### O header ficou opcional (31/08/2026)
`api.superdb.com.br` passou a ser servido por um gateway que **preenche o profile a
partir da própria chave**. Na prática:

- **Não mandar o header** funciona — antes dava `401 unauthorized`. Era o que acontecia
  com `supabase-js` cru e com `fetch` na mão.
- **Mandar o header certo** funciona igual a antes (é o que o `@superdb/client` faz).
- **Mandar o header errado** (ex.: `public`, que o supabase-js envia por padrão) passou
  a ser corrigido para o schema da chave, em vez de virar erro.

Sua chave só alcança o próprio schema, então não há como o gateway "escolher errado":
ele só sabe escrever um valor, o que está no token. O cadeado continua sendo o
`pre_request` do PostgREST, que valida a assinatura e o profile — o gateway é
conveniência, não fronteira de confiança.

> `/rest/v1/<tabela>` (o caminho do supabase-js) também é aceito e mapeado para a raiz.
> `/auth/v1` e `/storage/v1` **não** são servidos por este host. Eles respondem `404` com
> um corpo que nomeia o host certo (`{"error":"endpoint_em_outro_host", ...}`) — em vez do
> 404 mudo de antes.

## Provisão (criar projeto) e keys
- **Dashboard** (`app.superdb.com.br`): conta → criar projeto → aba Connect/API mostra a
  `anon` (visível) e a `service_role` (oculta até "revelar"). Slug é gerado do nome.
- As keys são **ES256** (geradas e guardadas no projeto). **Regenerar** invalida as antigas
  de verdade (incrementa a versão `kv`; o portão rejeita `kv` velho).
- **service_role**: acesso administrativo COMPLETO às suas tabelas de negócio via PostgREST — a
  plataforma cria a policy `sdb_service_role_all` (`using(true)`) em cada tabela nova, então ela
  ignora sua RLS de negócio (igual ao Supabase). Confinada ao PRÓPRIO projeto pelo gate (SEM
  BYPASSRLS global; não toca outro tenant nem `auth_*`). Backend-only, secreta. DDL/migrations e
  SQL multi-tabela → Management Key (`sdb_pmk_`).

## SDK
- **`@superdb/client`** — publicado no npm: `npm install @superdb/client` (drop-in supabase-js).
  `.auth` + `.from()`/`.rpc()` + `.storage` funcionam (o `.storage` minta `/st/v1/token` sozinho).
  Só `.channel` (realtime) é stub — minte `/rt/v1/token` com a sessão (`getDataPlaneToken()`;
  anon key só em tela sem login) + use `@supabase/realtime-js`. O realtime segue o RLS da tabela.
  Dual ESM/CJS. Depende de `@superdb/auth-js` (instalado junto). Escopo `@superdb`.
- **≥ 0.2.0** traz o login social com PKCE: `signInWithOAuth()` + `exchangeCodeForSession(code)`
  (troca em `POST /auth/v1/token/exchange`, code de uso único, S256 obrigatório) + `setSession()`.
  Veja `social-login.md`.
- `createClient(authUrl, anonKey, { project: '<slug>' })` — o `project` é obrigatório.
  Assinatura idêntica ao supabase-js + o 3º arg `{ project }` (e `storage` pra mobile).
- *Alternativa zero-dependência:* `templates/superdb.ts` (mesmo contrato inline, `createSuperDB({...})`).
