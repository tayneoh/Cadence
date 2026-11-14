-- Cadence: turn OFF the old instant password reset.
-- The old version of this file let anyone who knew an account's email set a
-- new password for it. The app now sends a reset link by email instead.
-- Run once in the Supabase SQL Editor (safe to run again).
drop function if exists public.reset_password(text, text);
drop table if exists cadence_private.reset_log;
