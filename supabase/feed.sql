-- Cadence feed: friends' check-ins, streaks and short updates, with
-- reactions and comments. Run once after schema.sql (safe to run again).
-- Only you and your friends see your posts; a private profile hides them.

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  kind text not null check (kind in ('checkin','streak','text')),
  habit_id text,
  habit_title text check (char_length(habit_title) <= 40),
  streak int,
  body text check (char_length(body) <= 280),
  day date not null,
  created_at timestamptz not null default now()
);
-- one automatic post per habit per day (check-in, and streak milestone)
create unique index if not exists posts_auto_once on public.posts (user_id, habit_id, day, kind) where kind <> 'text';
create index if not exists posts_recent on public.posts (created_at desc);

create table if not exists public.reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  emoji text not null check (emoji in ('heart','fire','clap','muscle','party')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, emoji)
);

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  author_name text not null default '',
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);

-- the commenter's name is copied in, so everyone on the post can read it
create or replace function public.fill_comment_author() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  select coalesce(name, '') into new.author_name from profiles where id = auth.uid();
  return new;
end $$;
drop trigger if exists on_comment_insert on public.comments;
create trigger on_comment_insert before insert on public.comments
  for each row execute function public.fill_comment_author();

create or replace function public.can_see_post(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from posts x join profiles o on o.id = x.user_id
    where x.id = p and (
      x.user_id = auth.uid()
      or (o.visibility <> 'private' and is_friend(x.user_id, auth.uid()) and not is_blocked(x.user_id, auth.uid()))));
$$;

alter table public.posts enable row level security;
alter table public.reactions enable row level security;
alter table public.comments enable row level security;

drop policy if exists "see posts" on public.posts;
create policy "see posts" on public.posts for select to authenticated using (can_see_post(id));
drop policy if exists "write own posts" on public.posts;
create policy "write own posts" on public.posts for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "delete own posts" on public.posts;
create policy "delete own posts" on public.posts for delete to authenticated using (user_id = auth.uid());

drop policy if exists "see reactions" on public.reactions;
create policy "see reactions" on public.reactions for select to authenticated using (can_see_post(post_id));
drop policy if exists "add reaction" on public.reactions;
create policy "add reaction" on public.reactions for insert to authenticated
  with check (user_id = auth.uid() and can_see_post(post_id));
drop policy if exists "remove reaction" on public.reactions;
create policy "remove reaction" on public.reactions for delete to authenticated using (user_id = auth.uid());

drop policy if exists "see comments" on public.comments;
create policy "see comments" on public.comments for select to authenticated using (can_see_post(post_id));
drop policy if exists "add comment" on public.comments;
create policy "add comment" on public.comments for insert to authenticated with check (can_see_post(post_id));
drop policy if exists "remove comment" on public.comments;
create policy "remove comment" on public.comments for delete to authenticated using (
  user_id = auth.uid() or exists (select 1 from posts x where x.id = post_id and x.user_id = auth.uid()));
