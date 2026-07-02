-- Stores one row per device that has registered for push notifications.
-- A user can have multiple rows (multiple devices).
create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  platform text not null default 'android',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, token)
);

create index if not exists push_tokens_user_id_idx on public.push_tokens(user_id);

alter table public.push_tokens enable row level security;

-- Each user can only see/insert/update/delete their own device tokens.
-- The send-push Edge Function reads this table with the service role key,
-- which bypasses RLS, so it can still look up tokens for any user.
drop policy if exists "Users manage their own push tokens" on public.push_tokens;
create policy "Users manage their own push tokens"
  on public.push_tokens
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
