-- Finals S3: storage for automatic progress sync.
-- One row per sync key. The page never reads the table directly: it only calls sync_progress(),
-- which merges item by item (the most recent change wins) and returns the merged result.

create table if not exists public.progress (
  sync_key   text primary key check (char_length(sync_key) between 20 and 64),
  items      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.progress enable row level security;   -- no policies: no direct access from the page
revoke all on public.progress from anon, authenticated;

create or replace function public.sync_progress(p_key text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cur    jsonb;
  merged jsonb;
begin
  if p_key is null or p_key !~ '^S3K-[A-Za-z0-9_-]{24}$' then
    raise exception 'invalid sync key';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'object' or octet_length(p_items::text) > 200000 then
    raise exception 'invalid items';
  end if;

  insert into progress (sync_key) values (p_key) on conflict (sync_key) do nothing;
  select items into cur from progress where sync_key = p_key for update;

  select cur || coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
    into merged
    from jsonb_each(p_items) as e
   where jsonb_typeof(e.value) = 'array'
     and jsonb_array_length(e.value) = 2
     and jsonb_typeof(e.value -> 1) = 'number'
     and (not (cur ? e.key) or (e.value ->> 1)::numeric > (cur -> e.key ->> 1)::numeric);

  update progress set items = merged, updated_at = now() where sync_key = p_key;
  return merged;
end;
$$;

revoke all on function public.sync_progress(text, jsonb) from public;
grant execute on function public.sync_progress(text, jsonb) to anon, authenticated;
