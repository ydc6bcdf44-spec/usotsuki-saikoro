-- 放置ルームの自動整理（勝敗なし・履歴は保持）
begin;
create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.island_room_activity(
 room_id uuid primary key references public.game_rooms(id) on delete cascade,
 last_activity timestamptz not null default now(),
 has_room_ping boolean not null default false
);
alter table public.island_room_activity enable row level security;
revoke all on public.island_room_activity from public,anon,authenticated;

-- 初回は既存の部屋にも5分の猶予を与える。
insert into public.island_room_activity(room_id,last_activity)
select id,now() from public.game_rooms where status in ('waiting','playing')
on conflict(room_id) do nothing;

create or replace function public.island_track_room_change()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status in ('waiting','playing') then
  insert into public.island_room_activity(room_id,last_activity)
  values(new.id,clock_timestamp())
  on conflict(room_id) do update set last_activity=excluded.last_activity;
 end if;
 return new;
end $$;
revoke all on function public.island_track_room_change() from public,anon,authenticated;
drop trigger if exists island_room_change_activity on public.game_rooms;
create trigger island_room_change_activity
after insert or update on public.game_rooms
for each row execute function public.island_track_room_change();

-- 参加者だけが自分の部屋の通信時刻を記録できる。
create or replace function public.island_room_ping(p_room_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then return; end if;
 perform 1 from public.game_rooms r where r.id=p_room_id
 and r.status in ('waiting','playing')
 and (r.host_id=auth.uid() or r.guest_id=auth.uid())
 for update;
 if not found then return; end if;
 insert into public.island_room_activity(room_id,last_activity,has_room_ping)
 values(p_room_id,clock_timestamp(),true)
 on conflict(room_id) do update set last_activity=excluded.last_activity,has_room_ping=true;
end $$;
revoke all on function public.island_room_ping(uuid) from public,anon,authenticated;
grant execute on function public.island_room_ping(uuid) to authenticated;

create or replace function public.island_cleanup_rooms()
returns integer language plpgsql security definer set search_path='' as $$
declare r record; a record; n integer:=0;
begin
 for r in
  select g.id,g.status,g.host_id,g.guest_id,g.created_at
  from public.game_rooms g
  join public.island_room_activity x on x.room_id=g.id
  where g.status in ('waiting','playing')
  and (x.last_activity < now()-interval '5 minutes'
       or (g.status='waiting' and g.guest_id is null
           and g.created_at<now()-interval '5 minutes'
           and x.has_room_ping))
  for update of g skip locked
 loop
  select * into a from public.island_room_activity where room_id=r.id;
  if not found then continue; end if;
  if r.status='waiting' and r.guest_id is null then
   if r.created_at is null or r.created_at>=now()-interval '5 minutes' then continue; end if;
   if not a.has_room_ping and a.last_activity>=now()-interval '5 minutes' then continue; end if;
  elsif r.status='playing' then
   if a.last_activity>=now()-interval '5 minutes' then continue; end if;
   -- 旧版クライアントは部屋別pingを送らないので、利用者の
   -- 直近のアクセスがあれば安全のため終了させない。
   if not a.has_room_ping and exists(
     select 1 from public.island_visits v
     where v.user_id in (r.host_id,r.guest_id)
       and v.last_seen>=now()-interval '5 minutes'
   ) then continue; end if;
  else
   continue;
  end if;
  update public.game_rooms
  set status='finished',
      game_state=coalesce(game_state,'{}'::jsonb)||jsonb_build_object(
       'finished',false,'winner',null,'deadline',null,
       'closedReason','abandoned','closedAt',now(),
       'message',case when r.status='waiting' then '待機時間が終了しました。' else '通信が途絶えたため対戦を終了しました。' end
      )
  where id=r.id and status=r.status;
  if found then n:=n+1; end if;
 end loop;
 return n;
end $$;
revoke all on function public.island_cleanup_rooms() from public,anon,authenticated;
-- 毎分サーバー側で実行。ブラウザを閉じても動作する。
select cron.schedule('island-cleanup-abandoned-rooms','* * * * *','select public.island_cleanup_rooms();');
notify pgrst,'reload schema';
commit;