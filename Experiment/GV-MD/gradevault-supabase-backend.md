---
name: gradevault-supabase-backend
description: Use this skill for any GradeVault backend work touching Supabase/PostgreSQL — schema changes, RLS policies, RPC design (e.g. spend_credits, broadcast_announcement, catalog import), migrations (schemaN.sql), or admin_cli.py data operations. Trigger whenever the user discusses GradeVault's database, an RPC, a migration, RLS, or admin_cli.py, even if they call it something else ("the credit function broke", "add a column", "the CLI needs a new flag"). Do not use generic microservice/Node/Go backend advice for this project — GradeVault has no service layer, just Supabase Postgres + RPCs + a Python admin CLI.
---

# GradeVault Supabase Backend

## Stack reality (do not deviate)

- Database: Supabase Postgres. No separate API server. No ORM.
- Access patterns: RLS policies + Postgres RPCs (`spend_credits`, `broadcast_announcement`, etc.) called directly from the frontend JS client and from `admin_cli.py`.
- Migrations: sequential SQL files (`schema16.sql` style). No migration framework, no auto-rollback tooling — rollback is manual and must be written by hand if the change isn't trivially additive.
- Admin surface: `admin_cli.py`, a Python CLI. Every RPC signature change is a two-caller problem: frontend AND admin_cli.py. Grep both before declaring a migration done.
- Money-adjacent tables (credits/balance) are the highest-scrutiny surface in the schema. See the money-safety skill for the full ruleset; this skill covers the schema/RPC mechanics.

## Checklist for any schema or RPC change

1. **Signature drift.** If you change an RPC's parameters or return shape, list every caller (frontend fetch/rpc call sites, `admin_cli.py` functions) and update all of them in the same change. A signature change that isn't caller-complete is not done — this exact class of bug (broken `spend_credits` signature post-migration) has already happened once.
2. **RLS impact.** State explicitly which roles can read/write the changed table after the change, and confirm it matches intent. A migration that adds a column without an RLS policy update is a silent exposure risk, not a shortcut.
3. **Additive over destructive.** Prefer new columns/tables over altering or dropping existing ones. If a column must be dropped or renamed, name the reads that break and confirm none are missed.
4. **Race conditions.** Any RPC that reads-then-writes a balance, counter, or lock state must use a single atomic statement (`UPDATE ... RETURNING` or a `SELECT ... FOR UPDATE` inside the function) — never read-in-app-then-write-in-app for concurrent-safe fields.
5. **Idempotency.** If an RPC can plausibly be called twice for the same logical event (retry, double-tap, flaky network), state whether a second call is safe. If not, add a guard (unique constraint, event id check) before shipping.
6. **Audit trail.** Any RPC that changes a balance, lock state, or role must leave a row behind explaining what happened and why — not just the new state.
7. **Migration naming and order.** Follow the existing `schemaN.sql` sequence. Never insert a migration out of order or renumber past ones.

## Answer format

1. What's actually happening (root cause, not symptom)
2. Data model impact — tables, columns, constraints touched
3. RLS/policy impact — who can do what after this change
4. Migration impact — is this additive, does it need a rollback path
5. RPC/caller impact — every place that calls the changed function
6. What to change first, what to avoid
7. What to verify after — specific query or manual check, not "test it"

## Known project-specific traps

- `spend_credits` has already broken once from a signature mismatch after a migration — treat any future touch to this function as high-risk by default.
- `admin_cli.py` credit grant types (`Top-up`, `Bonus`) must stay distinguishable at the schema level, not just in CLI output — the label needs to be a stored value, not something reconstructed at display time.
- `broadcast_announcement` drives notification fan-out — changing its shape affects the notifications feature, not just announcements. Check both when touching it.
