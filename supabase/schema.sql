create extension if not exists pgcrypto;

create table public.game_rooms (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  host_id uuid not null,
  guest_id uuid,
  status text not null default 'waiting'
    check (status in ('waiting', 'playing', 'finished')),
  created_at timestamptz default now()
);

alter table public.game_rooms enable row level security;

create policy "room members can read"
on public.game_rooms
for select to authenticated
using (
  auth.uid() = host_id or auth.uid() = guest_id
);

create or replace function public.create_game_room()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.game_rooms;
  c text;
begin
  if auth.uid() is null then
    raise exception 'ログインが必要です';
  end if;

  loop
    c := upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 6));
    exit when not exists (
      select 1 from public.game_rooms where code = c
    );
  end loop;

  insert into public.game_rooms(code, host_id)
  values(c, auth.uid())
  returning * into r;

  return to_jsonb(r);
end;
$$;

create or replace function public.join_game_room(room_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.game_rooms;
begin
  select * into r
  from public.game_rooms
  where code = upper(trim(room_code))
  for update;

  if not found then
    raise exception 'ルームが見つかりません';
  end if;

  if r.host_id = auth.uid() then
    return to_jsonb(r);
  end if;

  if r.status <> 'waiting' or r.guest_id is not null then
    raise exception '満員のルームです';
  end if;

  update public.game_rooms
  set guest_id = auth.uid(), status = 'playing'
  where id = r.id
  returning * into r;

  return to_jsonb(r);
end;
$$;

create or replace function public.find_random_match()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.game_rooms;
  c text;
  is_waiting boolean;
begin
  select * into r
  from public.game_rooms
  where status = 'waiting'
    and guest_id is null
    and host_id <> auth.uid()
  order by created_at
  for update skip locked
  limit 1;

  if found then
    update public.game_rooms
    set guest_id = auth.uid(), status = 'playing'
    where id = r.id
    returning * into r;
    is_waiting := false;
  else
    loop
      c := upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 6));
      exit when not exists (
        select 1 from public.game_rooms where code = c
      );
    end loop;

    insert into public.game_rooms(code, host_id)
    values(c, auth.uid())
    returning * into r;
    is_waiting := true;
  end if;

  return jsonb_build_object(
    'room', to_jsonb(r),
    'waiting', is_waiting
  );
end;
$$;

grant execute on function public.create_game_room() to authenticated;
grant execute on function public.join_game_room(text) to authenticated;
grant execute on function public.find_random_match() to authenticated;

alter table public.game_rooms replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.game_rooms;
exception when duplicate_object then null;
end $$;
