# Decisions

Why we chose X over Y. Use this to answer judges' cross-questions.

---

### D1 · Schema named `iam`, not `user`
- `USER` is a reserved word in PostgreSQL, so every query would need `"user"` in quotes, and someone forgets them sooner or later.
- IAM (Identity & Access Management) is the industry term.

### D2 · One schema per product, plus one DB login per product
- **Option rejected:** one shared schema with a `product` column. One missing `WHERE product = ...` would leak ERP data into AML.
- **What we did:** `erp_app` can't even *see* the `aml` schema, so separation is enforced by PostgreSQL itself, not by careful code.
- **Bonus:** per-product read-only logins (`*_ro`) for dashboards, as the brief recommends.

### D3 · Roles granted per app (`user_app_role`), not globally
- Real organizations work this way: the same person can be an Analyst in ERP and only a Viewer in Lending.
- With global roles, a "manager of ERP only" would need a new role for every combination of apps.

### D4 · Code checks permissions, never role names
- `fn_has_permission(user, 'ERP', 'batch.commit')`, never `if role == 'MANAGER'`.
- Roles can be added or changed with data, with no code deploy.
- Sidebar and dashboard are driven by the same permissions, so the UI can't show something the API would refuse.

### D5 · Logic in DB functions (`SECURITY DEFINER`), with the backend having no table access
- `iam_app` can only EXECUTE functions. A SQL-injection bug in the API can't `SELECT password_hash`.
- One source of truth for the rules, whatever client calls them.
- **Functions, not PROCEDUREs:** a function returns JSON from a plain `SELECT`, which is easy from Python. A procedure can't return a result set cleanly.

### D6 · Passwords: bcrypt (pgcrypto), cost 10
- bcrypt is salted and slow by design. Cost 10 is the OWASP minimum; each step up doubles the time.
- **Trade-off:** hashing uses DB CPU. At very high login volume, move hashing to the API (Argon2) and keep everything else.
- Unknown emails still burn one hash, so response time doesn't reveal which emails exist.

### D7 · Sessions: short JWT + refresh token stored as a hash, with rotation
- **Access JWT (about 15 min):** checked without a DB lookup.
- **Refresh token:** only its sha256 is stored, so a DB dump gives no usable tokens.
- **Rotation + reuse detection:** if an old token is replayed, it was probably stolen, so all of that user's sessions are killed. This follows OAuth 2.0 security guidance.
- `fn_session_is_active` per request makes logout, disable and password change take effect immediately.

### D8 · Lockout after 5 failures for 15 minutes
- Stops password guessing.
- `SELECT ... FOR UPDATE` keeps the counter correct when attempts arrive in parallel.

### D9 · Maker-checker
- The uploader can't commit their own batch, and a template creator can't approve it (a DB `CHECK`).
- This is standard four-eyes control in banking and finance (Lending/AML).

### D10 · Files on disk/object storage, metadata in the DB
- 10k concurrent uploads as `bytea` would bloat the WAL (transaction log), backups and replication.
- The DB keeps `storage_uri` and `sha256`, which is enough for audit and duplicate detection.

### D11 · Duplicate import protection with `sha256` + business-key upsert
- **Same file:** a partial unique index returns `DUPLICATE`. A `FAILED` file may be re-uploaded.
- **Same record in a new file:** upsert on the primary key, and the newer batch wins. Counts never double.

### D12 · One generic `raw_record` (JSONB) for all 4 formats
- This is the brief's "one adapter contract": CSV, Excel, JSON and PDF all produce the same shape.
- A new format means no schema change.
- Bulk loads use `COPY`, the fastest way into PostgreSQL.

### D13 · Commit = `jsonb_populate_record` + upsert in one transaction
- Typed conversion: a bad amount like `"abc"` aborts the whole commit, so a batch is never half-loaded.
- Only real domain tables (ones with a `source_record_no` column) are accepted as targets, so a record can't redirect writes into other tables.
- Domain foreign keys are `DEFERRABLE`, so parent and child rows in one batch can arrive in any order.

### D14 · State machine enforced in the DB
- Illegal jumps like `UPLOADED` → `READY_TO_COMMIT` are rejected.
- `erp_app` has no `UPDATE` on `ingestion_batch`, so the only way to change status is through the function.

### D15 · SSE over WebSocket for progress
- Progress only flows server → browser, so SSE is enough.
- It runs over plain HTTP and reconnects automatically.
- `batch_event.event_id` doubles as the SSE `Last-Event-ID`, so a reconnecting browser replays what it missed.

### D16 · One pipeline template for all 3 products
- `_product_pipeline.sql` is included once per schema, so the three pipelines can't drift apart, and a fourth product takes two lines.
- This replaced the planned `sp_provision_product_schema` procedure: plain SQL in a file is easier to read and test than DDL built inside strings.

### D18 · FastAPI with sync psycopg pools
- **FastAPI:** async where it matters (upload streaming, SSE, RabbitMQ), and it generates OpenAPI docs automatically.
- **Sync DB driver:** our DB calls are short function calls. Plain `def` routes run in FastAPI's threadpool. psycopg's async mode doesn't work with Windows' default event loop, so sync avoids that whole class of bugs.

### D19 · Refresh token in an httpOnly cookie, access token in memory
- JavaScript can never read the refresh token, so an XSS bug can't steal a long-lived token.
- `SameSite=Strict` and `Path=/api/auth` block CSRF and keep the cookie off every other request.

### D20 · Upload stored by content hash (`storage/<app>/<sha256>`)
- The same file is stored once.
- The name comes from the hash, never from user input, so path traversal (`../../`) is impossible.
- Write to a temp file, then an atomic rename: no half-written files.

### D21 · Two-stage RabbitMQ: shared progress queue, then fanout
- With several API instances, each progress message must be written to the DB **once**, so the instances compete for one shared queue.
- But every instance needs the event for its own SSE clients, so the stored event is re-published to a fanout exchange.
- Messages are acknowledged only after the DB write; failures go to a dead-letter queue instead of retrying forever.

### D21b · Progress applied in order
- aio-pika runs message handlers concurrently, so "80%" could be saved before "40%".
- The `ingestion.progress` queue uses `x-single-active-consumer`: only one API instance consumes at a time, with automatic failover.
- Its own channel has `prefetch=1`, so messages are handled one at a time, in the order the worker sent them.

### D22 · Local in-process broker fallback
- Dev and tests run without installing RabbitMQ. The same `handle_progress` code path is used, so the tests still cover the logic.
- Single instance only; production sets `RABBITMQ_URL`.

### D23 · Validate a file's real content, not just its extension
- PDF must start with `%PDF-`, Excel must be a ZIP or OLE file, JSON must start with `{` or `[`, CSV must have no binary bytes.
- Blocks renamed executables and oversized uploads (413) before any parsing happens.

### D24 · UI stack: React + TypeScript, Tailwind v4, Motion, lucide
- **TypeScript:** API shapes are typed, so field-name mismatches show up at build time.
- **Tailwind with CSS-variable tokens:** one place to change colours; dark mode is the same tokens with different values.
- **Motion:** spring animations for the sidebar width, shared "active pill", dialogs and drawer. It honours the OS "reduce motion" setting.
- **lucide icons:** they match the icon keys stored in `iam.menu_item`, so the DB drives the sidebar icons too.

### D25 · Black and white, colour only for meaning
- A neutral palette keeps it enterprise-calm.
- Red, green and amber appear only for failed, committed and needs-review, and status is also shown by text and shape, so colour-blind users lose nothing.
- One solid button per screen marks the main action; everything else is outline or ghost.

### D26 · Sidebar comes from the server
- The UI renders exactly what `sp_select_app` returns, so changing who sees what means changing DB rows, with no UI deploy.
- Typed URLs are checked against the same list (a "no access" page), and the API enforces it again (403).

### D27 · Tokens in the browser
- **Access token:** kept in memory only.
- **Refresh:** done through the httpOnly cookie, and single-flight. The server treats a replayed refresh token as theft, so two parallel refreshes (React StrictMode or two tabs) must never happen; all callers share one promise.
- **Vite proxy:** puts the UI and `/api` on the same origin, so the SameSite=Strict cookie works without CORS credentials.

### D28 · SSE through fetch, upload through XHR
- `fetch-event-source` can send the Authorization header, which native `EventSource` can't. It resumes from `Last-Event-ID` and reconnects with a refreshed token.
- XHR is used for upload because `fetch` can't report upload progress.

### D17 · No table partitioning yet
- `raw_record`'s primary key `(batch_id, record_no)` already makes per-batch reads fast.
- Partitioning adds operational cost; add it (by upload month) when data volume calls for it.
