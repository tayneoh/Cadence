-- Cadence: reset a password in the app with just an email (no reset email).
-- Run once in the SQL Editor (safe to run again).
-- Anyone who knows an account's email can set a new password for it, so
-- this suits a small family app. To go back to reset emails, run:
--   drop function if exists public.reset_password(text, text);

create extension if not exists pgcrypto with schema extensions;
create schema if not exists cadence_private;
revoke all on schema cadence_private from public, anon, authenticated;
create table if not exists cadence_private.reset_log (at timestamptz not null default now());

create or replace function public.reset_password(email text, new_password text) returns text
language plpgsql security definer set search_path = public, auth, extensions, cadence_private as $$
declare uid uuid;
begin
  if char_length(coalesce(new_password, '')) < 6 then return 'short'; end if;
  -- at most 30 resets an hour across everyone, to slow down misuse
  if (select count(*) from cadence_private.reset_log where at > now() - interval '1 hour') >= 30 then
    return 'too_many';
  end if;
  insert into cadence_private.reset_log default values;
  select id into uid from auth.users where lower(auth.users.email) = lower(trim(reset_password.email)) limit 1;
  if uid is null then return 'no_account'; end if;
  update auth.users set encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf')),
    updated_at = now() where id = uid;
  return 'ok';
end $$;

revoke all on function public.reset_password(text, text) from public;
grant execute on function public.reset_password(text, text) to anon, authenticated;
