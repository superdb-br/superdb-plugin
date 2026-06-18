# Contrato de conexão SuperDB (a verdade técnica)

## Hosts
| Host | Pra quê |
|---|---|
| `https://auth.superdb.com.br` | Login/cadastro (`/auth/v1/*`), gestão (`/platform/v1/*`) |
| `https://api.superdb.com.br` | **Dados (PostgREST).** Tabela na raiz: `/minha_tabela`. SEM `/rest/v1/`. |
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
Accept-Profile: proj_<slug>      # leitura (GET)
Content-Profile: proj_<slug>     # escrita (POST/PATCH/DELETE)
```
O `Accept-Profile`/`Content-Profile` **tem que ser `proj_<slug>`** — é o que roteia pro
seu schema E é amarrado ao token (a plataforma rejeita se o profile não bater com o
projeto do token → isso é o isolamento entre projetos).

## Provisão (criar projeto) e keys
- **Dashboard** (`app.superdb.com.br`): conta → criar projeto → aba Connect/API mostra a
  `anon` (visível) e a `service_role` (oculta até "revelar"). Slug é gerado do nome.
- As keys são **ES256** (geradas e guardadas no projeto). **Regenerar** invalida as antigas
  de verdade (incrementa a versão `kv`; o portão rejeita `kv` velho).
- **service_role**: hoje é RLS-gated (NÃO "acesso total" — é uma escolha de segurança). Use
  pra backend; respeita RLS como o authenticated. (Bypass total é decisão futura.)

## SDK
- **`@superdb/client`** — publicado no npm: `npm install @superdb/client` (drop-in supabase-js).
  `.auth` + `.from()`/`.rpc()` funcionam; `.storage`/`.channel` são stub (jogam erro).
  Dual ESM/CJS. Depende de `@superdb/auth-js` (instalado junto). Escopo `@superdb`.
- `createClient(authUrl, anonKey, { project: '<slug>' })` — o `project` é obrigatório.
  Assinatura idêntica ao supabase-js + o 3º arg `{ project }` (e `storage` pra mobile).
- *Alternativa zero-dependência:* `templates/superdb.ts` (mesmo contrato inline, `createSuperDB({...})`).
