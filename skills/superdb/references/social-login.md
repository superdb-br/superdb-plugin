# Login social (Google / GitHub / Apple) — web e mobile

Cada **projeto** liga seus próprios provedores. É configurado no dashboard
(`app.superdb.com.br` → seu projeto → **Autenticação**), não em variável de ambiente.

## 1. Ligar o provedor (dashboard)

Aba **Autenticação** → cartão do provedor → **Configurar**. Dois modos:

| Modo | Quando usar | O que aparece pro usuário |
|---|---|---|
| **Gerenciado** (padrão) | Protótipo, MVP, app interno | A tela de consentimento diz **SuperDB** |
| **Credenciais próprias (BYO)** | Produção com marca própria | A tela diz **o nome do SEU app** |

No BYO você cola `client_id` + `client_secret` do provedor (o secret é cifrado
at-rest). Registre no provedor o redirect **da plataforma**, sempre este:

```
https://auth.superdb.com.br/auth/v1/callback/google     (idem /github, /apple)
```

> Suporte por provedor: **Google** e **GitHub** = gerenciado ou BYO. **Apple** = só
> gerenciado. Microsoft ainda não.

### "Coloquei minhas credenciais e ainda aparece a marca do SuperDB"
Não é bug: no Google a tela de consentimento pertence ao **projeto do Google Cloud**, não
ao Client ID. Criar um client novo **dentro do projeto do SuperDB** dá um client seu com a
marca alheia. O Client ID começa com o número do projeto — se o seu começa igual ao de
outro, nasceram no mesmo lugar. Para ter a sua marca: crie um **projeto Google Cloud
próprio**, configure a *Tela de permissão OAuth* nele e só então gere o Client ID.
Mesma ideia no GitHub (a marca é do dono do OAuth App — crie na **organização**).

## 2. URLs de redirecionamento (allowlist) — **o passo que todo mundo esquece**

Mesma aba **Autenticação** → seção **URLs de redirecionamento**. Cadastre pra onde
o login pode voltar — **match exato**, um por linha:

```
https://meuapp.com.br/auth/callback     ← web (URL ABSOLUTA)
meuapp://auth                           ← deep link mobile
```

**Se o `redirectTo` não estiver nessa lista, o que acontece depende do fluxo — e os
dois sintomas não se parecem em nada:**

| Fluxo | Sintoma quando a URI não está registrada |
|---|---|
| **Web** (sem `code_challenge`) | o callback descarta o destino e manda o usuário pra `/` — o login "some" sem erro |
| **Mobile / PKCE** (com `code_challenge`) | **`400 oauth_state_unbound`** no callback |

É a causa #1 de "cliquei em entrar com Google e não aconteceu nada" — e, no mobile,
a causa #1 de um erro que fala de **cookie** e faz o dev caçar bug no próprio código.

🔑 **Por que o mobile falha com cara de problema de cookie.** O cookie `sdb_oauth_state`
amarra o callback a quem começou o login. Em app nativo isso é impossível (RFC 8252: o
init sai do `fetch` do app, o callback abre no navegador do sistema — jars diferentes).
A plataforma aceita o **PKCE** como binding equivalente, mas só quando o `redirect_to`
é **URI registrada** — é o registro que declara "este projeto roda um cliente PKCE".
Sem ele o cookie volta a ser exigido, e aí o app nativo não tem como passar.

⚠️ **Não tente contornar mandando `return=json` no callback.** Nesse modo o callback
devolve access/refresh token no corpo, e ali o cookie é o único binding — por isso ele
nunca é dispensado. `return=json` no **init** é normal e é o que o SDK faz (serve só
para receber a URL do provider); no **callback**, não.

⚠️ **Web: use URL absoluta.** Um `redirectTo: '/auth/callback'` (relativo) é aceito
pela validação, mas resolve contra o host de **auth** — o usuário cai em
`https://auth.superdb.com.br/auth/callback`, não no seu app.

## 3. Mobile (Expo / React Native) — PKCE, o jeito certo

Precisa de `@superdb/client` **≥ 0.2.0** (ou `@superdb/auth-js` ≥ 0.2.0).

```ts
import * as WebBrowser from 'expo-web-browser'
import { createClient } from '@superdb/client'
import AsyncStorage from '@react-native-async-storage/async-storage'

const db = createClient('https://auth.superdb.com.br', process.env.EXPO_PUBLIC_SUPERDB_ANON_KEY!, {
  project: 'meu_app',
  storage: AsyncStorage,
})

// 1) inicia — o SDK gera o par PKCE e guarda o verifier no storage sozinho
const { data, error } = await db.auth.signInWithOAuth({
  provider: 'google',
  redirectTo: 'meuapp://auth',        // <- tem que estar na allowlist do passo 2
})
await WebBrowser.openAuthSessionAsync(data!.url, 'meuapp://auth')

// 2) volta no deep link: meuapp://auth?code=XXXX
const code = new URL(deepLinkUrl).searchParams.get('code')!
const { data: s } = await db.auth.exchangeCodeForSession(code)
// pronto — sessão persistida; db.from() já respeita a RLS do usuário
```

**Por que code e não token no link:** um deep link pode ser interceptado por outro
app instalado no device. O `code` é de **uso único**, expira em 5 min e só vira
sessão junto com o `code_verifier` que nunca saiu do app (PKCE, RFC 8252).

**Requisito de WebCrypto:** o PKCE usa `crypto.subtle` (SHA-256). Expo tem via
`expo-crypto`; RN bare precisa de polyfill (`react-native-quick-crypto`). Sem ele o
SDK **lança erro claro** em vez de degradar — o método `plain` foi removido de
propósito (vazaria o verifier em log).

## 4. Web (SPA / Next.js)

Com o SDK ≥ 0.2.0 o fluxo web é **o mesmo** do mobile (também usa PKCE):

```ts
await db.auth.signInWithOAuth({ provider: 'google', redirectTo: 'https://meuapp.com.br/auth/callback' })
// → redirecione o browser pra data.url

// na página /auth/callback:
const code = new URLSearchParams(location.search).get('code')
if (code) await db.auth.exchangeCodeForSession(code)
```

> **Fluxo antigo (tokens no `#hash`)** só acontece se você montar a URL de init na
> mão, **sem** `code_challenge` — mantido por retrocompatibilidade. Nesse caso leia o
> fragmento e chame `db.auth.setSession({ access_token, data_plane_token, refresh_token })`.

## 5. Isolamento entre projetos (por que um projeto não rouba o login do outro)

- O `state` do OAuth carrega o **slug do projeto** que iniciou o fluxo (uso único, TTL 10 min).
- A allowlist de redirect é lida do **próprio projeto** do state — projeto A não
  consegue registrar uma URL que capture a sessão de B.
- O exchange code é gravado com o **schema** do tenant; a sessão que sai do
  `/token/exchange` é sempre daquele tenant.
- Identidades sociais vivem em `proj_<slug>.auth_identities` — **por projeto**. A mesma
  conta Google em dois projetos = dois usuários distintos, sem link entre eles.
  (O login social da própria plataforma SuperDB é outra tabela, em `auth_global`.)

## 6. Erros

| Erro | Significa |
|---|---|
| `oauth_not_enabled` (400) | Provedor desligado nesse projeto, ou BYO sem credencial. Ligue no dashboard. |
| **Voltou pra `/`, sem erro** | `redirectTo` fora da allowlist (passo 2). Causa #1. |
| `invalid_pkce` (400) | `code_challenge` não é base64url(SHA256) de 43–128 chars, ou method ≠ S256. |
| `pkce_mismatch` (400) | O verifier não bate com o challenge. O code **já foi queimado** — refaça o login inteiro. |
| `invalid_code` (400) | Code inexistente, expirado (5 min) ou **já usado**. Uso único é real. |
| `no_pkce_verifier` (SDK) | Chamou `exchangeCodeForSession` sem ter chamado `signInWithOAuth` (ou o storage foi limpo entre os dois). |
| `oauth_state_invalid` (400) | State expirou (10 min) ou já foi consumido. Refaça. |
| `redirect_uri_mismatch` (no Google) | Faltou registrar `https://auth.superdb.com.br/auth/v1/callback/google` no provedor. |

## 7. O template zero-dep não tem login social

`templates/superdb.ts` cobre senha/OTP e dados. Pra social, use o pacote npm
(`@superdb/client` ≥ 0.2.0) — o PKCE exige gerenciar verifier + storage + troca.
