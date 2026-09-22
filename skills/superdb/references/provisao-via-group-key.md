# Provisão de tenants via Group Key (SaaS factory / vertical multi-cliente)

Pra quem constrói uma **vertical** ou **SaaS factory** — um app que cria N tenants
isolados (ex: uma clínica por cliente, uma loja por cliente). Provisiona 1 tenant
ponta-a-ponta **100% via API**, sem dashboard, sem intervenção humana.

## Onde nasce o group (mudou em 04/08/2026)

Você mesmo cria em **`/groups`** no painel, escolhendo um dos **seus** projetos
como template. Antes era operação de staff, pedida por e-mail a cada cliente
novo. A Group API Key é gerada na página do group e o texto claro aparece **uma
vez só**.

## A credencial: Group Key (`sdb_gk_...`)
Uma **Group Key** autentica a "fábrica" (a org-mãe/ISV) e provisiona até 100 tenants
no seu group. É **server-side only** (nunca no frontend). Peça ao platform admin pra
criar seu group + group key.

## Fluxo completo (3 chamadas)

### 1. Provisionar o tenant
`POST https://auth.superdb.com.br/groups/v1/<GROUP_ID>/tenants`
- Header: `Authorization: Bearer sdb_gk_...`
- Body: `{ "slug": "cliente_acme", "external_id": "seu-id-interno" }` (slug opcional — gerado se ausente)
- Resposta **201**: `{ tenant: {id, slug, ...}, anon_key, service_role_key, already_existed }`

Cria, numa transação: o schema `proj_<slug>`, o role de login `proj_<slug>_owner`
(confinado ao schema, sem superuser/bypassrls), a senha do owner (cifrada), as keys
ES256 (anon + service_role) e o role de realtime isolado `rt_<schema>`.
Erros: slug em uso → **409**; limite de 100 tenants → **402**; **slug reservado → 400
`slug_reservado`**.

> **Slugs reservados (17/08/2026).** O schema do tenant é `proj_<slug>`, e alguns
> nomes colidem com schemas internos — `management` é o control-plane da
> plataforma. Estes slugs são recusados na criação: `management`, `public`,
> `storage`, `realtime`, `auth`, `auth_global`, `pgrst_helpers`, `extensions`,
> `graphql`, `vault`, `cron`, `information_schema`, `pg_catalog`, `pg_toast`,
> `postgres`, `admin`, `internal`, `system`, `platform`, `superdb`. Se você deriva
> o slug do nome do cliente, trate o 400 caindo para um sufixo (`acme_admin` em vez
> de `admin`) — a reserva vale para criação nova, tenant existente não é afetado.

### 2. Mintar uma Management Key do tenant novo
`POST https://auth.superdb.com.br/groups/v1/<GROUP_ID>/tenants/<slug>/keys`
- Header: `Authorization: Bearer sdb_gk_...`
- Body: `{ "label": "provisioning", "expires_in_days": 30 }` (ambos opcionais)
- Resposta **201**: `{ id, key: "sdb_pmk_...", prefix, label, expires_at }` (a key aparece UMA vez)

A group key só minta pra tenants **do seu group** (tenant de outro group → 404).

### 3. Aplicar o schema-de-RLS do app
O clone do template leva só a **estrutura** das tabelas — **não** leva RLS policies,
triggers nem dados. O app é dono do seu schema-de-RLS: aplique-o com a pmk via
`/db/exec` (ver `migrations-via-api.md`). Idempotente — versione sua migração.

```bash
curl -X POST https://auth.superdb.com.br/platform/v1/projects/<projectId>/db/exec \
  -H "Authorization: Bearer sdb_pmk_..." -H "Content-Type: application/json" \
  -d '{"sql":"alter table pacientes enable row level security; create policy p on pacientes for all to authenticated using (true);"}'
```

> ⚠️ **Erro de SQL volta com HTTP 200**, com `{"error":{...}}` no corpo. Checar
> só o status faz o script reportar sucesso com o schema pela metade — já
> aconteceu, com dois terços de uma bootstrap não aplicados. Veja o exemplo de
> cliente correto em `migrations-via-api.md`.

## Gerenciar
- `GET /groups/v1/<GROUP_ID>/tenants` — lista (paginado).
- `GET /groups/v1/<GROUP_ID>/tenants/<slug>` — detalhe.
- `DELETE /groups/v1/<GROUP_ID>/tenants/<slug>` — **soft-delete** (marca status, cancela subscription; reversível).

## Deletar de verdade (LGPD / direito ao esquecimento)
`DELETE /groups/v1/<GROUP_ID>/tenants/<slug>/purge` (Bearer `sdb_gk_...`) — **hard-delete
IRREVERSÍVEL**. Numa transação atômica remove TUDO do tenant: schema `proj_<slug>`
(tabelas + dados), roles (`_owner` + `rt_`), keys (anon/service/management), buckets +
objetos de storage, subscriptions, usage e a linha do projeto — com audit (`project.purged`).
Blast radius = 1 tenant.
- **Confirmação obrigatória:** body `{ "confirm_slug": "<slug>" }` igual ao slug (ou
  `?confirm=<slug>`); senão **400**. Evita apagão acidental.
- Escopado ao group (tenant de outro group → 404; groupId alheio → 403); recusa purgar o
  template do group (409). Resposta **200**: `{ ok, purged: { buckets_deleted, objects_deleted } }`.
- Storage: os **arquivos são apagados de verdade** (o purge chama o storage-api `/empty` do
  bucket → remove objetos + blobs do disco), não só a metadata. Sobra no máximo um diretório
  VAZIO (sem dado) — cruft cosmético, não é gap de LGPD.

## Isolamento (verificado adversarialmente)
Cada tenant é 1 schema + 1 owner role confinado. Provado: a pmk de um tenant não toca
outro (403); a anon key de um tenant não lê o schema de outro nem spoofando
`Accept-Profile` (401 no gate); a group key não minta fora do group (404); o owner role
não lê schema vizinho (`permission denied`, sem `bypassrls`). Isolamento redundante —
bloqueia na aplicação **e** no Postgres por construção. Adequado a dado sensível
(saúde/LGPD) no perímetro control-plane + REST + role Postgres. (Storage/Realtime têm
seus próprios contratos — ver as referências específicas.)


## Publicar versão nova do template (04/08/2026)

```bash
curl -X POST "$SUPERDB_URL/groups/v1/$GROUP_ID/template/publish" \
  -H "Authorization: Bearer $GROUP_KEY"
```

Congela o schema do projeto de ORIGEM numa versão nova (`<fonte>_v2`, `_v3`…) e
aponta o group para ela. **Faça disso um passo do deploy do app**, depois das
migrations: é assim que se controla quando a estrutura que o próximo cliente
recebe muda.

Sem isso, um group que aponta para o projeto de produção entrega ao próximo
cliente qualquer `ALTER TABLE` feito em produção, no mesmo instante.

**NÃO retroage.** A resposta traz `tenants_na_versao_anterior`: tenant que já
existe fica com a estrutura antiga. Migrar os existentes é migration do app, uma
por tenant, via `/db/exec` com a management key de cada um.

`foreign_keys: null` na resposta = o fechamento do clone falhou e o template
ficou **sem integridade referencial**. Não trate como sucesso.

Pelo MCP: ferramenta `superdb_publish_template`, que só aparece quando
`SUPERDB_GROUP_ID` e `SUPERDB_GROUP_KEY` estão configuradas.

### Antes de publicar: ler o estado do group

```bash
curl "$SUPERDB_URL/groups/v1/$GROUP_ID" -H "Authorization: Bearer $GROUP_KEY"
```

```json
{
  "group":  { "id": "…", "slug": "meu_saas", "name": "Meu SaaS" },
  "template": { "slug": "modelo_v3", "congelado_em": "…",
                "tabelas": 49, "foreign_keys": 155 },
  "source":   { "slug": "modelo" },
  "tenants":  { "total": 2, "na_versao_atual": 1,
                "em_versao_anterior": 1, "teto": 100 }
}
```

- `template.foreign_keys` — confira **antes e depois** de publicar. Zero num
  schema que tem FK é o mesmo sintoma do `foreign_keys: null` na resposta do
  publish: o fechamento do clone falhou.
- `source` — de onde a PRÓXIMA versão sai. `null` significa que o group nunca
  publicou e aponta direto para a fonte: aí `ALTER TABLE` em produção vale para
  o próximo cliente no mesmo instante.
- `tenants.em_versao_anterior` — provisionados ANTES do template atual ser
  congelado. Esses têm estrutura antiga, garantido. O tenant não guarda de qual
  versão nasceu; a data é o que dá para afirmar sem inventar.

## Cobrança por tenant (04/08/2026)

O group herda o plano do projeto **template**, e os tenants inclusos são os
projetos daquele plano: Grátis 2, Site 3, Pro 10, Escala 40.

- **Grátis bloqueia** acima do incluso: `402 tenant_quota_exceeded`.
- **Pago segue provisionando** e cada tenant acima custa **R$ 5,00/mês**.
- `402 tenant_limit_reached` é outra coisa: teto de **infraestrutura**, 100 por
  group. Subir de plano **não** destrava.

Trate os dois 402 como erros de negócio distintos — um pede upgrade, o outro não
tem upgrade que resolva.
