# Aplicar schema/migrations via API (Management Key)

Pra um agente/CI aplicar `CREATE TABLE`, RLS, etc. **sem depender de alguém colar
SQL no dashboard**. É o equivalente ao "rodar SQL via token" do Supabase (Management
API), feito por-projeto.

## O que é
Uma **Management Key** (`sdb_pmk_...`) é uma credencial de **plano de controle**,
escopada a UM projeto, que autentica no endpoint de execução de SQL. Diferente da
`anon`/`service_role` (plano de dados, RLS, vão no app), a management key:
- roda SQL/DDL no schema do projeto (como o role dono do tenant, **confinado** ao schema);
- é **server-side only** — NUNCA vai no frontend/app/bundle;
- é **revogável** e pode ter expiração;
- **não alcança** outro projeto nem schemas de sistema (auth_global, etc.).

## Como obter
- Dashboard → projeto → **API Keys** → seção *Management Keys* → gerar (mostra o
  valor uma vez). *(Se o botão ainda não estiver no dashboard, peça ao platform admin
  pra gerar — a chave + o `projectId` ficam guardados pra você.)*
- **Vertical / SaaS factory:** minta a chave programaticamente com a Group Key —
  `POST /groups/v1/<GROUP_ID>/tenants/<slug>/keys` (Bearer `sdb_gk_...`). Fecha a
  provisão 100% via API (provisiona → minta → aplica RLS). Ver `provisao-via-group-key.md`.

## Como aplicar uma migration
`POST https://auth.superdb.com.br/platform/v1/projects/<projectId>/db/exec`
- Header: `Authorization: Bearer sdb_pmk_...`
- Body: `{ "sql": "<seu SQL>" }`
- `<projectId>` é o **UUID** do projeto (no dashboard, ou junto da chave). NÃO é o slug.

```bash
curl -X POST https://auth.superdb.com.br/platform/v1/projects/<projectId>/db/exec \
  -H "Authorization: Bearer $SUPERDB_MGMT_KEY" \
  -H "Content-Type: application/json" \
  -d '{"sql":"create table tarefas(id bigint generated always as identity primary key, user_id text not null, titulo text not null, done boolean not null default false); alter table tarefas enable row level security; create policy p on tarefas for all to authenticated using (user_id = (current_setting(''request.jwt.claims'',true)::json->>''sub'')) with check (user_id = (current_setting(''request.jwt.claims'',true)::json->>''sub''));"}'
```
Resposta de sucesso: `{ "columns":[...], "rows":[...], "rows_affected":N, "duration_ms":N }`,
mais `"avisos":[...]` quando o comando deixou um risco de segurança (ver abaixo).

## ⚠️ `avisos` na resposta: o comando deu certo, mas abriu uma porta

O campo só aparece quando há algo a corrigir. Cada item tem `tipo`, `objeto`,
`mensagem` e `como_corrigir` (o SQL pronto). **Um agente que recebe `avisos` deve
parar e resolver antes de seguir**, não tratar como sucesso comum.

| `tipo` | O que aconteceu | O que fazer |
|---|---|---|
| `rls_desligada` | `disable row level security` numa tabela que a API alcança. Qualquer pessoa com a chave pública lê (e às vezes escreve) a tabela inteira, e as policies dela deixam de valer. | Religar a RLS e criar a policy que faltava. Erro de insert se resolve com policy de `INSERT`, nunca desligando a RLS. |
| `grant_public_convertido` | Um `grant ... to public`. O banco é compartilhado entre projetos, então o SuperDB troca na hora por `anon, authenticated`. O app continua com o mesmo acesso pela API. | Nada urgente. Nas próximas migrations, escreva direto `to anon, authenticated`. |

```json
{ "columns": [], "rows": [], "rows_affected": 0, "duration_ms": 4,
  "avisos": [{ "tipo": "rls_desligada", "objeto": "proj_loja.fotos",
    "mensagem": "SuperDB: a RLS de proj_loja.fotos está desligada, e a tabela ficou exposta pela API. ...",
    "como_corrigir": "ALTER TABLE proj_loja.fotos ENABLE ROW LEVEL SECURITY; ..." }] }
```

## ⚠️ Erro de SQL vem com HTTP **200**

Esta é a armadilha número um deste endpoint. Um SQL que falha responde:

```
HTTP/1.1 200 OK
{ "error": { "code": "42501", "message": "must be owner of table clinics", "line": 12 } }
```

**Checar só o status esconde a falha.** Um integrador aplicou uma bootstrap de
~200 comandos, o cliente dele conferia apenas `res.ok`, e o relatório saiu como
"provisionamento bem-sucedido" com **dois terços do schema não aplicado**. O
problema só apareceu depois, como comportamento errado do app.

O motivo do 200 é que a requisição HTTP de fato deu certo — quem falhou foi o
SQL dentro dela. Não é o desenho que escolheríamos hoje, mas mudar agora
quebraria todo cliente que já lê o corpo.

**Sempre cheque o corpo:**

```js
const res = await fetch(url, { method: 'POST', headers, body });
const data = await res.json();

// As DUAS verificações. Nenhuma sozinha basta.
if (!res.ok) throw new Error(`HTTP ${res.status}`);        // auth, rate-limit, 5xx
if (data.error) {                                           // o SQL falhou
  throw new Error(`SQL ${data.error.code}: ${data.error.message} (linha ${data.error.line})`);
}
```

```bash
# Em shell, com jq:
resposta=$(curl -s -X POST "$URL" -H "$AUTH" -d "$BODY")
if echo "$resposta" | jq -e '.error' >/dev/null; then
  echo "SQL falhou: $(echo "$resposta" | jq -r '.error.message')" >&2
  exit 1
fi
```

**Aplicando vários comandos?** Mande o lote inteiro numa requisição só: cada
chamada já roda dentro de uma transação, então se um comando falha, **nenhum**
fica aplicado. **Não escreva `BEGIN;`/`COMMIT;`**: o endpoint recusa com
`transaction_control_blocked`, porque um `BEGIN` do cliente quebraria a
transação que ele mesmo abre. (Bloco `DO $$ BEGIN ... END $$` de plpgsql não é
controle de transação e passa normalmente.) O pior cenário é o meio-termo: um
script que manda um comando por requisição, segue em frente depois do primeiro
erro e deixa o schema pela metade.

## Não precisa de NOTIFY/reload manual
Tabelas criadas via a chave já ficam **visíveis no PostgREST** e com **grant** pro
anon/authenticated automaticamente (event triggers no banco). Depois de aplicar o
schema, o app já lê com `db.from('sua_tabela')`.

## Limites (de propósito)
- Bloqueia schemas de sistema (`auth_global`, `proj_management`, `pg_*`, `storage`...).
- Bloqueia `SET ROLE`/`RESET ROLE` e `BEGIN`/`COMMIT`/`ROLLBACK` (`transaction_control_blocked`).
  Timeout 30s. SELECT ganha LIMIT implícito (1000).
- `grant ... to public` vira `to anon, authenticated` na hora (vem em `avisos`).
- Rate-limit ~120 req/min por chave.
- Uma chave de um projeto em outro projeto → **403**. Revogada/expirada → **401**.

## Segurança
- Trate como senha de banco: só no servidor/CI, nunca commitada, nunca no frontend.
- Vazou? **Revogue** (dashboard ou `DELETE .../db/keys/<id>`) — a revogação é imediata
  e real (a chave para de funcionar na hora).
