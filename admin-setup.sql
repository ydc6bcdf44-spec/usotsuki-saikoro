-- Island Adventure 管理者ページ設定
-- 先に Authentication > Users > Add user > Create new user で
-- 自分専用のメールアドレス・パスワードのユーザーを作成し、UUIDをコピーする。
-- 下の REPLACE_WITH_ADMIN_UUID をそのUUIDに置き換えてから全体を実行。
begin;
create table if not exists public.island_admins (
 user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.island_admins enable row level security;
revoke all on public.island_admins from public, anon, authenticated;
do $$
declare uid uuid := 'REPLACE_WITH_ADMIN_UUID'::uuid;
begin
 if not exists(select 1 from auth.users where id=uid and coalesce(is_anonymous,false)=false and email is not null) then
  raise exception '管理者はメールアドレスで登録したユーザーのUUIDを指定してください';
 end if;
 insert into public.island_admins(user_id) values(uid) on conflict do nothing;
end $$;
create table if not exists public.island_visits (
 visit_id uuid primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 player_name text,
 device text not null check(device in ('mobile','desktop')),
 started_at timestamptz not null default now(),
 last_seen timestamptz not null default now()
);
alter table public.island_visits enable row level security;
revoke all on public.island_visits from public, anon, authenticated;
create index if not exists island_visits_seen_idx on public.island_visits(last_seen);
create index if not exists island_visits_user_idx on public.island_visits(user_id,last_seen desc);
create index if not exists island_visits_started_idx on public.island_visits(started_at);

create or replace function public.island_visit_ping(p_visit uuid,p_name text,p_device text)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
 if uid is null or p_visit is null then raise exception '認証が必要です'; end if;
 if exists(select 1 from public.island_admins where user_id=uid) then return; end if;
 insert into public.island_visits(visit_id,user_id,player_name,device)
 values(p_visit,uid,nullif(left(btrim(coalesce(p_name,'')),12),''),case when p_device='mobile' then 'mobile' else 'desktop' end)
 on conflict(visit_id) do update set last_seen=now(),player_name=coalesce(excluded.player_name,public.island_visits.player_name)
 where public.island_visits.user_id=uid;
end $$;
revoke all on function public.island_visit_ping(uuid,text,text) from public,anon,authenticated;
grant execute on function public.island_visit_ping(uuid,text,text) to authenticated;

create or replace function public.island_admin_overview()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare today_start timestamptz := date_trunc('day',now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
begin
 if auth.uid() is null or not exists(select 1 from public.island_admins where user_id=auth.uid()) then
   raise exception '管理者権限が必要です' using errcode='42501';
 end if;
 return jsonb_build_object(
 'accounts',(select count(*) from auth.users u where not exists(select 1 from public.island_admins a where a.user_id=u.id)),
 'online',(select count(distinct user_id) from public.island_visits where last_seen>=now()-interval '90 seconds'),
 'today_users',(select count(distinct user_id) from public.island_visits where last_seen>=today_start),
 'today_visits',(select count(*) from public.island_visits where started_at>=today_start),
 'total_visits',(select count(*) from public.island_visits),
 'mobile',(select count(*) from public.island_visits where device='mobile'),
 'desktop',(select count(*) from public.island_visits where device='desktop'),
 'waiting',(select count(*) from public.game_rooms where status='waiting'),
 'playing',(select count(*) from public.game_rooms where status='playing'),
 'players',coalesce((select jsonb_agg(to_jsonb(t) order by t.last_seen desc nulls last,t.created_at desc) from (
   select u.id,u.created_at,u.last_sign_in_at,v.last_seen,
    coalesce(v.player_name,h.player_name) as player_name,v.device,
    coalesce(st.games_played,0) as games_played,coalesce(st.wins,0) as wins,coalesce(st.losses,0) as losses
   from auth.users u
   left join lateral (select z.last_seen,z.player_name,z.device from public.island_visits z where z.user_id=u.id order by z.last_seen desc limit 1) v on true
   left join lateral (select case when r.host_id=u.id then r.game_state->'players'->>0 else r.game_state->'players'->>1 end as player_name from public.game_rooms r where r.host_id=u.id or r.guest_id=u.id order by r.created_at desc limit 1) h on true
   left join public.game_player_stats st on st.user_id=u.id
   where not exists(select 1 from public.island_admins a where a.user_id=u.id)
   order by v.last_seen desc nulls last,u.created_at desc limit 500
 ) t),'[]'::jsonb)
 );
end $$;
revoke all on function public.island_admin_overview() from public,anon,authenticated;
grant execute on function public.island_admin_overview() to authenticated;
commit;