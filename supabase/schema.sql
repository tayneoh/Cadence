-- Cadence online: friends, groups and shared habits.
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run again; it only creates what is missing.
-- Every table has row-level security, so people only ever see what was shared with them.

-- ---------- profiles ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '' check (char_length(name) <= 30),
  visibility text not null default 'friends' check (visibility in ('private','friends','public')),
  friend_code text not null unique default upper(substr(md5(random()::text), 1, 6)),
  show_notes boolean not null default false,
  show_streaks boolean not null default true,
  created_at timestamptz not null default now()
);

-- a profile row is created automatically when someone signs up
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(left(new.raw_user_meta_data->>'name', 30), ''))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- friends ----------
create table if not exists public.friendships (
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);

create table if not exists public.blocks (
  blocker uuid not null references public.profiles(id) on delete cascade,
  blocked uuid not null references public.profiles(id) on delete cascade,
  primary key (blocker, blocked)
);

create or replace function public.is_friend(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from friendships f where f.status = 'accepted'
    and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a)));
$$;

create or replace function public.is_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks k where (k.blocker = a and k.blocked = b) or (k.blocker = b and k.blocked = a));
$$;

-- ---------- groups ----------
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 30),
  habit text not null check (char_length(habit) between 1 and 40),
  days int[] not null default '{0,1,2,3,4,5,6}',
  code text not null unique default upper(substr(md5(random()::text), 1, 6)),
  owner uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.group_checkins (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  primary key (group_id, user_id, day)
);

create or replace function public.is_member(g uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members m where m.group_id = g and m.user_id = u);
$$;

create or replace function public.shares_group(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members x join group_members y on x.group_id = y.group_id
    where x.user_id = a and y.user_id = b);
$$;

-- the creator joins their own group automatically
create or replace function public.handle_new_group() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into group_members (group_id, user_id) values (new.id, new.owner) on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_group_created on public.groups;
create trigger on_group_created after insert on public.groups
  for each row execute function public.handle_new_group();

-- ---------- shared habits ----------
-- only habits set to Friends or Public are ever uploaded; Private ones never leave the phone
create table if not exists public.shared_habits (
  user_id uuid not null references public.profiles(id) on delete cascade,
  habit_id text not null,
  title text not null check (char_length(title) <= 40),
  kind text not null default 'build' check (kind in ('build','quit')),
  visibility text not null check (visibility in ('friends','public')),
  note text check (char_length(note) <= 200),
  streak int not null default 0,
  recent date[] not null default '{}',     -- days done in the last 14 days
  updated_at timestamptz not null default now(),
  primary key (user_id, habit_id)
);

-- ---------- cheers and nudges ----------
create table if not exists public.cheers (
  sender uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  receiver uuid not null references public.profiles(id) on delete cascade,
  day date not null default current_date,
  primary key (sender, receiver, day)
);

create table if not exists public.nudges (
  sender uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  receiver uuid not null references public.profiles(id) on delete cascade,
  group_id uuid not null references public.groups(id) on delete cascade,
  day date not null default current_date,
  primary key (sender, receiver, group_id, day)
);

-- ---------- row-level security ----------
alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.blocks enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_checkins enable row level security;
alter table public.shared_habits enable row level security;
alter table public.cheers enable row level security;
alter table public.nudges enable row level security;

drop policy if exists "see profiles" on public.profiles;
create policy "see profiles" on public.profiles for select to authenticated using (
  id = auth.uid()
  or (not is_blocked(id, auth.uid()) and (
       visibility = 'public'
       or (visibility = 'friends' and is_friend(id, auth.uid()))
       or shares_group(id, auth.uid())
       or exists (select 1 from friendships f where f.requester = id and f.addressee = auth.uid()))));
drop policy if exists "edit own profile" on public.profiles;
create policy "edit own profile" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "see own friendships" on public.friendships;
create policy "see own friendships" on public.friendships for select to authenticated
  using (requester = auth.uid() or addressee = auth.uid());
drop policy if exists "accept requests" on public.friendships;
create policy "accept requests" on public.friendships for update to authenticated
  using (addressee = auth.uid()) with check (addressee = auth.uid() and status = 'accepted');
drop policy if exists "remove friendships" on public.friendships;
create policy "remove friendships" on public.friendships for delete to authenticated
  using (requester = auth.uid() or addressee = auth.uid());

drop policy if exists "own blocks" on public.blocks;
create policy "own blocks" on public.blocks for all to authenticated
  using (blocker = auth.uid()) with check (blocker = auth.uid());

drop policy if exists "see my groups" on public.groups;
create policy "see my groups" on public.groups for select to authenticated using (owner = auth.uid() or is_member(id, auth.uid()));
drop policy if exists "create groups" on public.groups;
create policy "create groups" on public.groups for insert to authenticated with check (owner = auth.uid());
drop policy if exists "owner edits group" on public.groups;
create policy "owner edits group" on public.groups for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists "owner deletes group" on public.groups;
create policy "owner deletes group" on public.groups for delete to authenticated using (owner = auth.uid());

drop policy if exists "see group members" on public.group_members;
create policy "see group members" on public.group_members for select to authenticated using (is_member(group_id, auth.uid()));
drop policy if exists "leave group" on public.group_members;
create policy "leave group" on public.group_members for delete to authenticated using (user_id = auth.uid());

drop policy if exists "see group checkins" on public.group_checkins;
create policy "see group checkins" on public.group_checkins for select to authenticated using (is_member(group_id, auth.uid()));
drop policy if exists "add own checkin" on public.group_checkins;
create policy "add own checkin" on public.group_checkins for insert to authenticated
  with check (user_id = auth.uid() and is_member(group_id, auth.uid()));
drop policy if exists "remove own checkin" on public.group_checkins;
create policy "remove own checkin" on public.group_checkins for delete to authenticated using (user_id = auth.uid());

drop policy if exists "see shared habits" on public.shared_habits;
create policy "see shared habits" on public.shared_habits for select to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from profiles p where p.id = user_id and p.visibility <> 'private'
     and not is_blocked(p.id, auth.uid())
     and ((shared_habits.visibility = 'public' and p.visibility = 'public') or is_friend(p.id, auth.uid()))));
drop policy if exists "write own habits" on public.shared_habits;
create policy "write own habits" on public.shared_habits for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "see cheers" on public.cheers;
create policy "see cheers" on public.cheers for select to authenticated using (sender = auth.uid() or receiver = auth.uid());
drop policy if exists "send cheers" on public.cheers;
create policy "send cheers" on public.cheers for insert to authenticated
  with check (sender = auth.uid() and is_friend(sender, receiver));

drop policy if exists "see nudges" on public.nudges;
create policy "see nudges" on public.nudges for select to authenticated using (sender = auth.uid() or receiver = auth.uid());
drop policy if exists "send nudges" on public.nudges;
create policy "send nudges" on public.nudges for insert to authenticated
  with check (sender = auth.uid() and is_member(group_id, sender) and is_member(group_id, receiver));

-- ---------- actions that need a code ----------
-- send a friend request using someone's friend code
create or replace function public.add_friend(code text) returns text
language plpgsql security definer set search_path = public as $$
declare target uuid;
begin
  select id into target from profiles where friend_code = upper(trim(code));
  if target is null then return 'not_found'; end if;
  if target = auth.uid() then return 'self'; end if;
  if is_blocked(target, auth.uid()) then return 'not_found'; end if;
  if exists (select 1 from friendships where (requester = auth.uid() and addressee = target)
             or (requester = target and addressee = auth.uid())) then
    -- they already asked you: accept it
    update friendships set status = 'accepted' where requester = target and addressee = auth.uid();
    return 'exists';
  end if;
  insert into friendships (requester, addressee) values (auth.uid(), target);
  return 'sent';
end $$;

-- join a group using its code
create or replace function public.join_group(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select id into g from groups where groups.code = upper(trim(join_group.code));
  if g is null then return null; end if;
  insert into group_members (group_id, user_id) values (g, auth.uid()) on conflict do nothing;
  return g;
end $$;

-- block someone: also ends the friendship
create or replace function public.block_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into blocks (blocker, blocked) values (auth.uid(), target) on conflict do nothing;
  delete from friendships where (requester = auth.uid() and addressee = target) or (requester = target and addressee = auth.uid());
end $$;

revoke all on function public.add_friend(text), public.join_group(text), public.block_user(uuid) from public, anon;
grant execute on function public.add_friend(text), public.join_group(text), public.block_user(uuid) to authenticated;
