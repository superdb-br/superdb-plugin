# Auth Hooks — reagir a eventos de login, ou decidir quem entra

Webhook que o SuperDB dispara nos momentos de autenticação do seu projeto. Você
publica um endpoint HTTPS; nós ligamos para ele.

Não confunda com "Edge Functions": **não existe** execução de código do cliente
na infraestrutura do SuperDB. O endpoint é seu, hospedado onde você quiser.

## Quando recomendar hooks

| O usuário quer… | Evento |
|---|---|
| só quem já é cliente/paciente pode criar conta | `before-signup` **bloqueante** |
| bloquear e-mail descartável, exigir convite | `before-signup` **bloqueante** |
| barrar login de inadimplente, fora de horário, fora do país | `before-signin` **bloqueante** |
| criar o registro no ERP quando a conta nasce | `after-signup` |
| alimentar log de acesso próprio, avisar de dispositivo novo | `after-signin` |
| propagar exclusão LGPD para os sistemas dele | `user-deleted` |
| invalidar cache/sessão quando a senha muda | `password-changed` |
| encerrar a sessão espelhada no sistema dele | `after-signout` |
| exigir verificação extra antes do 2º fator | `before-mfa` **bloqueante** |

Só `before-signup`, `before-signin` e `before-mfa` aceitam `blocking: true`.

## Configurar

**Dashboard:** Autenticação → Hooks.

**API** (management key `sdb_pmk_` ou token de MCP):

```bash
curl -X POST https://auth.superdb.com.br/platform/v1/projects/$PROJECT_ID/auth/hooks \
  -H "Authorization: Bearer $SUPERDB_MANAGEMENT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"hook_event":"before-signup","url":"https://app.dele/webhooks/superdb","blocking":true,"timeout_ms":3000}'
```

A resposta traz `secret` **uma vez**. Sem ele, não há como validar a assinatura.

Outras rotas: `GET /` lista · `PATCH /:id` (url, active, timeout) · `DELETE /:id`
· `POST /:id/secret` rotaciona o segredo (mantém o id) · `POST /:id/test` dispara
um payload de teste e devolve status e latência reais.

## 🔴 As duas coisas que quebram toda primeira integração

### 1. O segredo é hex, mas o HMAC é sobre BYTES

Entregamos `secret` em hexadecimal. O HMAC usa os bytes que aquele hex
representa — **não o texto**. Usar a string hex como chave gera uma assinatura
que nunca bate, sem erro nenhum que explique o motivo.

```ts
const SEGREDO = Buffer.from(process.env.SUPERDB_HOOK_SECRET!, 'hex'); // ← obrigatório
```

### 2. Assine o corpo CRU

A assinatura é `HMAC-SHA256(segredo, `${timestamp}.${corpoCru}`)`. Reserializar
com `JSON.stringify(req.body)` muda espaços e ordem de chaves e o HMAC deixa de
bater. Use `express.raw()` ou `await req.text()` **antes** de qualquer parse.

```ts
import { createHmac, timingSafeEqual } from 'node:crypto';

const esperado = 'sha256=' + createHmac('sha256', SEGREDO)
  .update(`${req.headers['x-superdb-hook-timestamp']}.${corpoCru}`)
  .digest('hex');

const a = Buffer.from(esperado), b = Buffer.from(req.headers['x-superdb-hook-signature']);
const ok = a.length === b.length && timingSafeEqual(a, b);
```

Rejeite também se `|agora − timestamp| > 300s` (proteção contra replay).

## Bloquear

Responda `200` com `{"allow": false, "reason": "…"}`. O usuário recebe `403` com
código `hook_blocked` e a mensagem. Qualquer outro `200` libera.

## ⚠️ Hook bloqueante NÃO é trava de segurança

Se o endpoint do cliente cair, der timeout, retornar erro ou devolver algo que
não seja JSON válido, **o acesso é liberado** (fail-open).

É deliberado — não trancar todos os usuários para fora porque um webhook caiu.
Mas significa que `before-signup` é **regra de negócio com caminho de escape**.
Quando o usuário disser "quero que ninguém entre sem minha autorização", diga
isso explicitamente: a autorização precisa existir também nas rotas dele.

## Limites

- 20 hooks por projeto · 5 bloqueantes
- `timeout_ms` entre 500 e 5000
- 3 tentativas nos eventos assíncronos (espera crescente); bloqueante não repete
- URL **https** e pública. `localhost`, `10.x`, `192.168.x`, `169.254.x` são
  recusados **no cadastro** — a chamada sai dos nossos servidores.
- Bloqueantes rodam **em série**: 5 × 3 s somam 15 s ao login.

## Diagnóstico rápido

| Sintoma | Causa provável |
|---|---|
| assinatura nunca bate | segredo usado como string em vez de `Buffer.from(hex,'hex')`, ou corpo reserializado |
| hook não dispara | `active: false`, ou evento diferente do que você imagina (confira com `GET /`) |
| 400 `hook_url_resolves_private` | o domínio resolve para IP interno |
| 400 `hook_url_must_be_https` | http só é aceito em desenvolvimento |
| bloqueante não bloqueia | endpoint caiu (fail-open) ou a resposta não é JSON com `allow:false` |
| 409 `blocking_hook_limit_reached` | já há 5 bloqueantes no projeto |

Doc pública: https://superdb.com.br/docs/guides/hooks/
