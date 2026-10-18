-- Presents: shared groups and sealed moments.
-- Paste all of this into Supabase › SQL Editor › New query, and press Run.
-- Safe to run more than once.

create table if not exists public.rolls (
  id uuid primary key,
  name text not null,
  reveal_date timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists public.members (
  roll_id uuid not null references public.rolls(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  name text not null,
  joined_at timestamptz not null default now(),
  primary key (roll_id, user_id)
);

create table if not exists public.moments (
  id uuid primary key,
  roll_id uuid not null references public.rolls(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  author text not null,
  kind text not null,
  caption text not null default '',
  body text not null default '',
  media_path text,
  thumb_path text,
  created_at timestamptz not null,
  hidden_at timestamptz
);

create index if not exists moments_roll_idx on public.moments (roll_id);

-- Is the signed-in phone in this group? (security definer so policies don't loop)
create or replace function public.is_member(r uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where roll_id = r and user_id = auth.uid());
$$;

alter table public.rolls enable row level security;
alter table public.members enable row level security;
alter table public.moments enable row level security;

-- Groups: anyone signed in can create one; you only see groups you're in.
drop policy if exists "create rolls" on public.rolls;
create policy "create rolls" on public.rolls for insert to authenticated with check (true);
drop policy if exists "see my rolls" on public.rolls;
create policy "see my rolls" on public.rolls for select to authenticated using (public.is_member(id));

-- Members: you add yourself (the group id is the invite); you see your groups' members.
drop policy if exists "join as myself" on public.members;
create policy "join as myself" on public.members for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "see my groups' members" on public.members;
create policy "see my groups' members" on public.members for select to authenticated using (public.is_member(roll_id));
drop policy if exists "leave" on public.members;
create policy "leave" on public.members for delete to authenticated using (user_id = auth.uid());

-- Moments: group members add and read; you take back only your own; anyone in the group can hide.
drop policy if exists "add my moments" on public.moments;
create policy "add my moments" on public.moments for insert to authenticated
  with check (user_id = auth.uid() and public.is_member(roll_id));
drop policy if exists "read group moments" on public.moments;
create policy "read group moments" on public.moments for select to authenticated using (public.is_member(roll_id));
drop policy if exists "hide group moments" on public.moments;
create policy "hide group moments" on public.moments for update to authenticated
  using (public.is_member(roll_id)) with check (public.is_member(roll_id));
drop policy if exists "take back mine" on public.moments;
create policy "take back mine" on public.moments for delete to authenticated using (user_id = auth.uid());

-- Media: private bucket, files live at <roll id>/<file>.
insert into storage.buckets (id, name, public) values ('moments', 'moments', false)
on conflict (id) do nothing;

drop policy if exists "group uploads" on storage.objects;
create policy "group uploads" on storage.objects for insert to authenticated
  with check (bucket_id = 'moments' and public.is_member(((storage.foldername(name))[1])::uuid));
drop policy if exists "group downloads" on storage.objects;
create policy "group downloads" on storage.objects for select to authenticated
  using (bucket_id = 'moments' and public.is_member(((storage.foldername(name))[1])::uuid));
drop policy if exists "delete my uploads" on storage.objects;
create policy "delete my uploads" on storage.objects for delete to authenticated
  using (bucket_id = 'moments' and owner_id = auth.uid()::text);
