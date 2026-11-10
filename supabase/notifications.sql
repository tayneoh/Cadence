-- Cadence notifications, friend suggestions and account sync.
-- Run once after schema.sql and feed.sql (safe to run again).
-- Before running, replace the two placeholders below:
--   PUSH_FUNCTION_URL  your function's address, e.g. https://<project>.supabase.co/functions/v1/push
--   PUSH_SECRET_VALUE  the same secret you saved as PUSH_SECRET on the function

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------- where to send each phone's notifications ----------
create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  p256dh text not null,
  auth text not null,
  tz text not null default 'UTC',
  prefs jsonb not null default '{}',     -- e.g. {"likes": false} turns likes off
  created_at timestamptz not null default now()
);

-- ---------- habit reminders (only habits with a reminder time) ----------
create table if not exists public.reminders (
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  habit_id text not null,
  title text not null check (char_length(title) <= 40),
  remind_at text not null check (remind_at ~ '^[0-2][0-9]:[0-5][0-9]$'),
  days int[] not null default '{0,1,2,3,4,5,6}',
  tz text not null default 'UTC',
  done_on date,                          -- skip today's reminder once it's done
  last_sent date,
  primary key (user_id, habit_id)
);

alter table public.push_subscriptions enable row level security;
alter table public.reminders enable row level security;
drop policy if exists "own subscriptions" on public.push_subscriptions;
create policy "own subscriptions" on public.push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "own reminders" on public.reminders;
create policy "own reminders" on public.reminders for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- private settings the app can't read ----------
create schema if not exists cadence_private;
revoke all on schema cadence_private from public, anon, authenticated;
create table if not exists cadence_private.config (key text primary key, value text not null);
insert into cadence_private.config (key, value) values
  ('push_url', 'PUSH_FUNCTION_URL'),
  ('push_secret', 'PUSH_SECRET_VALUE')
on conflict (key) do update set value = excluded.value;

-- hand an event to the push function
create or replace function public.push_send(payload jsonb) returns void
language plpgsql security definer set search_path = public, cadence_private as $$
declare u text; s text;
begin
  select value into u from cadence_private.config where key = 'push_url';
  select value into s from cadence_private.config where key = 'push_secret';
  if u is null or u like 'PUSH_%' then return; end if;
  perform net.http_post(url := u, body := payload,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', s));
end $$;
revoke all on function public.push_send(jsonb) from public, anon, authenticated;

-- nudges, cheers, reactions, comments and posts each send a notification
create or replace function public.push_on_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform push_send(jsonb_build_object('table', tg_table_name, 'record', to_jsonb(new)));
  return new;
exception when others then
  return new;   -- a notification problem never blocks the action itself
end $$;

drop trigger if exists push_nudges on public.nudges;
create trigger push_nudges after insert on public.nudges for each row execute function public.push_on_insert();
drop trigger if exists push_cheers on public.cheers;
create trigger push_cheers after insert on public.cheers for each row execute function public.push_on_insert();
drop trigger if exists push_reactions on public.reactions;
create trigger push_reactions after insert on public.reactions for each row execute function public.push_on_insert();
drop trigger if exists push_comments on public.comments;
create trigger push_comments after insert on public.comments for each row execute function public.push_on_insert();
drop trigger if exists push_posts on public.posts;
create trigger push_posts after insert on public.posts for each row execute function public.push_on_insert();

-- every minute, ask the function to send any reminders that are due
select cron.schedule('cadence-reminders', '* * * * *', $$ select public.push_send('{"table":"tick"}'::jsonb) $$);

-- ---------- friend suggestions ----------
-- friends of your friends and people in your groups, who you aren't
-- connected to yet. Private profiles and blocked people are left out.
create or replace function public.friend_suggestions()
returns table (id uuid, name text, mutuals int, groups int)
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as u),
  my_friends as (
    select case when f.requester = me.u then f.addressee else f.requester end as f
    from friendships f, me where f.status = 'accepted' and me.u in (f.requester, f.addressee)),
  connected as (
    select case when f.requester = me.u then f.addressee else f.requester end as c
    from friendships f, me where me.u in (f.requester, f.addressee)),
  fof as (
    select case when fr.requester = mf.f then fr.addressee else fr.requester end as s, count(*)::int as n
    from friendships fr join my_friends mf on mf.f in (fr.requester, fr.addressee)
    where fr.status = 'accepted' group by 1),
  gm as (
    select b.user_id as s, count(distinct b.group_id)::int as n
    from group_members a join group_members b on b.group_id = a.group_id, me
    where a.user_id = me.u and b.user_id <> me.u group by 1)
  select p.id, p.name, coalesce(fof.n, 0), coalesce(gm.n, 0)
  from profiles p
  left join fof on fof.s = p.id
  left join gm on gm.s = p.id, me
  where (fof.s is not null or gm.s is not null)
    and p.id <> me.u
    and p.id not in (select c from connected)
    and p.visibility <> 'private'
    and not is_blocked(p.id, me.u)
  order by coalesce(fof.n, 0) + coalesce(gm.n, 0) desc, p.name
  limit 10;
$$;

-- send a friend request to a suggested person
create or replace function public.request_friend(target uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if target is null or target = auth.uid() then return 'self'; end if;
  if is_blocked(target, auth.uid()) then return 'not_found'; end if;
  if exists (select 1 from friendships where (requester = auth.uid() and addressee = target)
             or (requester = target and addressee = auth.uid())) then
    update friendships set status = 'accepted' where requester = target and addressee = auth.uid();
    return 'exists';
  end if;
  insert into friendships (requester, addressee) values (auth.uid(), target);
  return 'sent';
end $$;

revoke all on function public.friend_suggestions(), public.request_friend(uuid) from public, anon;
grant execute on function public.friend_suggestions(), public.request_friend(uuid) to authenticated;

-- ---------- account sync ----------
-- one row per account holding your habits, check-ins, to-dos and settings,
-- so they follow you to any device. Only you can read or change it.
create table if not exists public.user_data (
  user_id uuid primary key references public.profiles(id) on delete cascade default auth.uid(),
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.user_data enable row level security;
drop policy if exists "own data" on public.user_data;
create policy "own data" on public.user_data for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
