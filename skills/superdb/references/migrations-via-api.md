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
Resposta de sucesso: `{ "columns":[...], "rows":[...], "rows_affected":N, "duration_ms":N }`.
Erro: `{ "error": { "code":"...", "message":"..." } }`.

## Não precisa de NOTIFY/reload manual
Tabelas criadas via a chave já ficam **visíveis no PostgREST** e com **grant** pro
anon/authenticated automaticamente (event triggers no banco). Depois de aplicar o
schema, o app já lê com `db.from('sua_tabela')`.

## Limites (de propósito)
- Bloqueia schemas de sistema (`auth_global`, `proj_management`, `pg_*`, `storage`...).
- Bloqueia `SET ROLE`/`RESET ROLE`. Timeout 30s. SELECT ganha LIMIT implícito (1000).
- Rate-limit ~120 req/min por chave.
- Uma chave de um projeto em outro projeto → **403**. Revogada/expirada → **401**.

## Segurança
- Trate como senha de banco: só no servidor/CI, nunca commitada, nunca no frontend.
- Vazou? **Revogue** (dashboard ou `DELETE .../db/keys/<id>`) — a revogação é imediata
  e real (a chave para de funcionar na hora).
