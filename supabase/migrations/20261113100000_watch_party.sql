-- Watch party backend.
--
-- Client contract: composeApp/.../features/party/PartyApi.kt, PartyRepository.kt, PartyChat.kt and
-- PartyCompanion.kt (identical in NuvioDesktopButBetter and NuvioMobileButBetter).
--
-- Design
--   * Playback is synchronised peer to peer over a private Realtime channel "watch-party:<party id>"
--     (broadcast + presence). This schema stores the party, its members, the latest playback state (for
--     late joiners) and chat, and sends the server-originated events: member_joined, member_left, ended,
--     media, control and chat. Clients broadcast state / status / state_request / stream themselves.
--   * Every table is closed to clients (RLS on, no policies). All access goes through the security definer
--     RPCs below, plus one policy on realtime.messages that only lets current members use their channel.
--   * Lifetime: a party ends when its last member leaves, when every member has gone silent for
--     member_timeout, or after max_age. Ended parties (and their chat) are deleted after retention.
--     Tunables live in public.watch_party_config.
--   * Failures that the client understands are returned as {"error": "<code>"} instead of raised:
--     party_not_found, party_full, removed, not_member, party_ended, rate_limited, unavailable.

create table public.watch_party_config (
  id boolean primary key default true check (id),
  enabled boolean not null default true,
  max_members integer not null default 3 check (max_members between 2 and 12),
  member_timeout interval not null default interval '10 minutes',
  max_age interval not null default interval '12 hours',
  retention interval not null default interval '24 hours',
  create_limit_per_hour integer not null default 10
);
insert into public.watch_party_config (id) values (true);
alter table public.watch_party_config enable row level security;

create table public.watch_parties (
  id uuid primary key default gen_random_uuid(),
  code text not null check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  created_by uuid references auth.users(id) on delete set null,
  host_member_id uuid,
  host_only boolean not null default false,
  media jsonb not null,
  playback jsonb,
  max_members integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_reason text
);
-- A code identifies one live party; finished parties keep theirs until they are deleted.
create unique index watch_parties_live_code on public.watch_parties (code) where ended_at is null;
create index watch_parties_code on public.watch_parties (code);
create index watch_parties_created_by on public.watch_parties (created_by, created_at desc);
create index watch_parties_ended on public.watch_parties (ended_at) where ended_at is not null;
alter table public.watch_parties enable row level security;

create table public.watch_party_members (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.watch_parties(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null check (length(device_id) between 1 and 128),
  profile_index integer,
  display_name text not null,
  avatar_url text,
  avatar_color text,
  joined_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default now(),
  left_at timestamptz,
  removed boolean not null default false,
  unique (party_id, device_id)
);
create index watch_party_members_active on public.watch_party_members (party_id) where left_at is null;
create index watch_party_members_user on public.watch_party_members (user_id) where left_at is null;
create index watch_party_members_seen on public.watch_party_members (last_seen_at) where left_at is null;
alter table public.watch_party_members enable row level security;

-- A second device of the same account that follows a member's seat (chat only).
create table public.watch_party_companions (
  party_id uuid not null references public.watch_parties(id) on delete cascade,
  member_id uuid not null references public.watch_party_members(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  linked_at timestamptz not null default now(),
  primary key (party_id, device_id)
);
alter table public.watch_party_companions enable row level security;

create table public.watch_party_messages (
  id bigint generated always as identity primary key,
  party_id uuid not null references public.watch_parties(id) on delete cascade,
  member_id uuid not null references public.watch_party_members(id) on delete cascade,
  client_id text,
  body text not null check (length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create unique index watch_party_messages_client on public.watch_party_messages (party_id, member_id, client_id) where client_id is not null;
create index watch_party_messages_party on public.watch_party_messages (party_id, id);
alter table public.watch_party_messages enable row level security;

revoke all on public.watch_party_config, public.watch_parties, public.watch_party_members,
  public.watch_party_companions, public.watch_party_messages from anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Internal helpers (not callable by clients)
-- ---------------------------------------------------------------------------------------------

create function public._wp_now_ms() returns bigint language sql stable as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint
$$;

create function public._wp_uid() returns uuid language plpgsql stable set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  return uid;
end; $$;

-- Broadcast failures must never fail the RPC that caused them.
create function public._wp_broadcast(p_party uuid, p_event text, p_payload jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform realtime.send(p_payload, p_event, 'watch-party:' || p_party::text, true);
exception when others then
  null;
end; $$;

create function public._wp_valid_media(p_media jsonb) returns boolean language sql immutable as $$
  select coalesce(
    p_media is not null
      and jsonb_typeof(p_media) = 'object'
      and length(p_media::text) <= 16384
      and jsonb_typeof(p_media -> 'type') = 'string'
      and jsonb_typeof(p_media -> 'meta_id') = 'string'
      and jsonb_typeof(p_media -> 'meta_type') = 'string',
    false)
$$;

-- Returns the playback object when it has the fields every client needs, otherwise null.
create function public._wp_clean_playback(p_playback jsonb) returns jsonb language sql immutable as $$
  select case
    when p_playback is not null
      and jsonb_typeof(p_playback) = 'object'
      and length(p_playback::text) <= 2048
      and jsonb_typeof(p_playback -> 'seq') = 'number'
      and jsonb_typeof(p_playback -> 'paused') = 'boolean'
      and jsonb_typeof(p_playback -> 'position_ms') = 'number'
      and jsonb_typeof(p_playback -> 'at') = 'number'
    then p_playback
  end
$$;

create function public._wp_snapshot(p_party uuid, p_member uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'party', jsonb_build_object(
      'id', p.id, 'code', p.code, 'host_member_id', p.host_member_id, 'host_only', p.host_only,
      'media', p.media, 'playback', p.playback, 'max_members', p.max_members),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'display_name', m.display_name, 'avatar_url', m.avatar_url, 'avatar_color', m.avatar_color)
        order by m.joined_at)
      from public.watch_party_members m where m.party_id = p.id and m.left_at is null), '[]'::jsonb),
    'member_id', p_member,
    'server_time_ms', public._wp_now_ms(),
    'ok', true)
  from public.watch_parties p where p.id = p_party
$$;

-- Resolves the caller's seat in a party. A companion device resolves to the seat it follows.
create function public._wp_context(p_party uuid, p_device text, p_user uuid, lock_party boolean default false,
  out o_party public.watch_parties, out o_member public.watch_party_members, out o_error text)
language plpgsql security definer set search_path = public as $$
begin
  if lock_party then
    select * into o_party from public.watch_parties where id = p_party for update;
  else
    select * into o_party from public.watch_parties where id = p_party;
  end if;
  if o_party.id is null then o_error := 'party_not_found'; return; end if;
  if o_party.ended_at is not null then o_error := 'party_ended'; return; end if;
  select * into o_member from public.watch_party_members
    where party_id = p_party and user_id = p_user and device_id = p_device and left_at is null;
  if o_member.id is null then
    select m.* into o_member from public.watch_party_companions c
      join public.watch_party_members m on m.id = c.member_id
      where c.party_id = p_party and c.device_id = p_device and c.user_id = p_user and m.left_at is null;
  end if;
  if o_member.id is null then
    o_error := case when exists (
      select 1 from public.watch_party_members
      where party_id = p_party and user_id = p_user and device_id = p_device and removed) then 'removed' else 'not_member' end;
  end if;
end; $$;

create function public._wp_end_party(p_party uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.watch_parties set ended_at = now(), ended_reason = p_reason, updated_at = now()
    where id = p_party and ended_at is null;
  if found then
    update public.watch_party_members set left_at = coalesce(left_at, now()) where party_id = p_party;
    perform public._wp_broadcast(p_party, 'ended', jsonb_build_object('reason', p_reason));
  end if;
end; $$;

-- Takes a member out of a party, hands the host role over and ends an empty party.
create function public._wp_remove_member(p_member uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare m public.watch_party_members; p public.watch_parties; next_host uuid;
begin
  select * into m from public.watch_party_members where id = p_member and left_at is null for update;
  if m.id is null then return; end if;
  select * into p from public.watch_parties where id = m.party_id for update;
  update public.watch_party_members set left_at = now(), removed = (p_reason = 'removed') where id = m.id;
  delete from public.watch_party_companions where member_id = m.id;
  next_host := p.host_member_id;
  if p.host_member_id = m.id then
    select id into next_host from public.watch_party_members
      where party_id = p.id and left_at is null order by joined_at limit 1;
    update public.watch_parties set host_member_id = next_host, updated_at = now() where id = p.id;
  end if;
  if p.ended_at is not null then return; end if;
  perform public._wp_broadcast(p.id, 'member_left', jsonb_build_object(
    'member_id', m.id, 'reason', p_reason, 'host_member_id', next_host));
  if next_host is null then perform public._wp_end_party(p.id, 'empty'); end if;
end; $$;

-- A device sits in one party at a time.
create function public._wp_leave_others(p_user uuid, p_device text, p_keep uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from public.watch_party_members
    where user_id = p_user and device_id = p_device and left_at is null and party_id is distinct from p_keep loop
    perform public._wp_remove_member(r.id, 'left');
  end loop;
end; $$;

create function public._wp_new_code() returns text language plpgsql as $$
declare alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; candidate text; attempts integer := 0;
begin
  loop
    candidate := '';
    for i in 1..6 loop
      candidate := candidate || substr(alphabet, 1 + floor(random() * length(alphabet))::integer, 1);
    end loop;
    if not exists (select 1 from public.watch_parties where code = candidate) then return candidate; end if;
    attempts := attempts + 1;
    if attempts > 20 then raise exception 'Could not allocate a party code'; end if;
  end loop;
end; $$;

create function public._wp_clean_text(p_value text, p_max integer) returns text language sql immutable as $$
  select nullif(left(btrim(p_value), p_max), '')
$$;

-- ---------------------------------------------------------------------------------------------
-- Client RPCs
-- ---------------------------------------------------------------------------------------------

create function public.watch_party_enabled() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select enabled from public.watch_party_config where id), false)
$$;

create function public.watch_party_clock() returns bigint language sql stable as $$
  select public._wp_now_ms()
$$;

create function public.watch_party_create(
  p_device_id text, p_display_name text, p_avatar_url text, p_avatar_color text,
  p_media jsonb, p_playback jsonb default null, p_profile_index integer default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public._wp_uid(); cfg public.watch_party_config; pid uuid; mid uuid;
begin
  select * into cfg from public.watch_party_config where id;
  if not cfg.enabled then return jsonb_build_object('error', 'unavailable'); end if;
  if p_device_id is null or length(p_device_id) not between 1 and 128 or not public._wp_valid_media(p_media) then
    raise exception 'Invalid watch party request' using errcode = '22023';
  end if;
  if (select count(*) from public.watch_parties where created_by = uid and created_at > now() - interval '1 hour')
     >= cfg.create_limit_per_hour then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  perform public._wp_leave_others(uid, p_device_id, null);
  pid := gen_random_uuid(); mid := gen_random_uuid();
  insert into public.watch_parties (id, code, created_by, host_member_id, media, playback, max_members)
    values (pid, public._wp_new_code(), uid, null, p_media, public._wp_clean_playback(p_playback), cfg.max_members);
  insert into public.watch_party_members (id, party_id, user_id, device_id, profile_index, display_name, avatar_url, avatar_color)
    values (mid, pid, uid, p_device_id, p_profile_index,
      coalesce(public._wp_clean_text(p_display_name, 40), 'Nuvio'),
      public._wp_clean_text(p_avatar_url, 512), public._wp_clean_text(p_avatar_color, 7));
  update public.watch_parties set host_member_id = mid where id = pid;
  return public._wp_snapshot(pid, mid);
end; $$;

create function public.watch_party_join(
  p_code text, p_device_id text, p_display_name text, p_avatar_url text, p_avatar_color text,
  p_profile_index integer default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public._wp_uid(); cfg public.watch_party_config; v_code text := upper(btrim(coalesce(p_code, '')));
  p public.watch_parties; m public.watch_party_members; rejoin boolean := false;
begin
  select * into cfg from public.watch_party_config where id;
  if not cfg.enabled then return jsonb_build_object('error', 'unavailable'); end if;
  if p_device_id is null or length(p_device_id) not between 1 and 128 then
    raise exception 'Invalid watch party request' using errcode = '22023';
  end if;
  select * into p from public.watch_parties where code = v_code and ended_at is null for update;
  if p.id is null then
    return jsonb_build_object('error', case when exists (select 1 from public.watch_parties where code = v_code)
      then 'party_ended' else 'party_not_found' end);
  end if;
  select * into m from public.watch_party_members where party_id = p.id and device_id = p_device_id;
  if m.id is not null and m.user_id <> uid then return jsonb_build_object('error', 'not_member'); end if;
  if m.id is not null and m.removed then return jsonb_build_object('error', 'removed'); end if;
  if m.id is not null and m.left_at is null then
    rejoin := true;
  elsif (select count(*) from public.watch_party_members where party_id = p.id and left_at is null) >= p.max_members then
    return jsonb_build_object('error', 'party_full');
  end if;
  perform public._wp_leave_others(uid, p_device_id, p.id);
  if m.id is null then
    insert into public.watch_party_members (party_id, user_id, device_id, profile_index, display_name, avatar_url, avatar_color)
      values (p.id, uid, p_device_id, p_profile_index,
        coalesce(public._wp_clean_text(p_display_name, 40), 'Nuvio'),
        public._wp_clean_text(p_avatar_url, 512), public._wp_clean_text(p_avatar_color, 7))
      returning * into m;
  else
    update public.watch_party_members set left_at = null, last_seen_at = now(), profile_index = p_profile_index,
      display_name = coalesce(public._wp_clean_text(p_display_name, 40), display_name),
      avatar_url = public._wp_clean_text(p_avatar_url, 512), avatar_color = public._wp_clean_text(p_avatar_color, 7)
      where id = m.id returning * into m;
  end if;
  if p.host_member_id is null then
    update public.watch_parties set host_member_id = m.id, updated_at = now() where id = p.id;
  end if;
  if not rejoin then
    perform public._wp_broadcast(p.id, 'member_joined', jsonb_build_object('member_id', m.id));
  end if;
  return public._wp_snapshot(p.id, m.id);
end; $$;

create function public.watch_party_preview(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_code text := upper(btrim(coalesce(p_code, ''))); p public.watch_parties; host public.watch_party_members;
begin
  perform public._wp_uid();
  select * into p from public.watch_parties where code = v_code and ended_at is null;
  if p.id is null then return jsonb_build_object('error', 'party_not_found'); end if;
  select * into host from public.watch_party_members where id = p.host_member_id;
  return jsonb_build_object(
    'media', p.media,
    'host', case when host.id is null then null else jsonb_build_object(
      'id', host.id, 'display_name', host.display_name, 'avatar_url', host.avatar_url, 'avatar_color', host.avatar_color) end,
    'members', (select count(*) from public.watch_party_members where party_id = p.id and left_at is null),
    'max_members', p.max_members);
end; $$;

create function public.watch_party_heartbeat(p_party_id uuid, p_device_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._wp_uid(); ctx record;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  update public.watch_party_members set last_seen_at = now() where id = (ctx.o_member).id;
  return public._wp_snapshot(p_party_id, (ctx.o_member).id);
end; $$;

create function public.watch_party_update(
  p_party_id uuid, p_device_id text, p_media jsonb default null, p_playback jsonb default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public._wp_uid(); ctx record; p public.watch_parties; v_playback jsonb := public._wp_clean_playback(p_playback);
  is_host boolean; stored_seq bigint;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid, true);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  p := ctx.o_party;
  is_host := p.host_member_id = (ctx.o_member).id;
  update public.watch_party_members set last_seen_at = now() where id = (ctx.o_member).id;
  if p_media is not null and is_host and public._wp_valid_media(p_media) and p_media is distinct from p.media then
    update public.watch_parties set media = p_media, playback = v_playback, updated_at = now() where id = p.id;
    perform public._wp_broadcast(p.id, 'media', jsonb_build_object('media', p_media, 'playback', v_playback));
  elsif v_playback is not null and (is_host or not p.host_only) then
    stored_seq := coalesce((p.playback ->> 'seq')::bigint, -1);
    if (v_playback ->> 'seq')::bigint > stored_seq then
      update public.watch_parties set playback = v_playback, updated_at = now() where id = p.id;
    end if;
  end if;
  return public._wp_snapshot(p.id, (ctx.o_member).id);
end; $$;

create function public.watch_party_leave(p_party_id uuid, p_device_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._wp_uid(); ctx record;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  perform public._wp_remove_member((ctx.o_member).id, 'left');
  return jsonb_build_object('ok', true);
end; $$;

create function public.watch_party_end(p_party_id uuid, p_device_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._wp_uid(); ctx record;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  if (ctx.o_party).host_member_id <> (ctx.o_member).id then return jsonb_build_object('error', 'not_host'); end if;
  perform public._wp_end_party(p_party_id, 'ended');
  return jsonb_build_object('ok', true);
end; $$;

create function public.watch_party_set_host_only(p_party_id uuid, p_device_id text, p_host_only boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._wp_uid(); ctx record;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid, true);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  if (ctx.o_party).host_member_id <> (ctx.o_member).id then return jsonb_build_object('error', 'not_host'); end if;
  update public.watch_parties set host_only = coalesce(p_host_only, false), updated_at = now() where id = p_party_id;
  perform public._wp_broadcast(p_party_id, 'control', jsonb_build_object('host_only', coalesce(p_host_only, false)));
  return public._wp_snapshot(p_party_id, (ctx.o_member).id);
end; $$;

create function public.watch_party_remove_member(p_party_id uuid, p_device_id text, p_member_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := public._wp_uid(); ctx record;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid, true);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  if (ctx.o_party).host_member_id <> (ctx.o_member).id then return jsonb_build_object('error', 'not_host'); end if;
  if p_member_id is not null and p_member_id <> (ctx.o_member).id
     and exists (select 1 from public.watch_party_members where id = p_member_id and party_id = p_party_id and left_at is null) then
    perform public._wp_remove_member(p_member_id, 'removed');
  end if;
  return public._wp_snapshot(p_party_id, (ctx.o_member).id);
end; $$;

-- Lets a second device of the account follow the profile's current party for chat.
create function public.watch_party_link_profile(p_device_id text, p_profile_index integer, p_member_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public._wp_uid(); m public.watch_party_members; p public.watch_parties;
begin
  if p_device_id is null or length(p_device_id) not between 1 and 128 then
    raise exception 'Invalid watch party request' using errcode = '22023';
  end if;
  if p_member_id is not null then
    select * into m from public.watch_party_members where id = p_member_id and user_id = uid;
    if m.id is null then return jsonb_build_object('error', 'not_member'); end if;
    select * into p from public.watch_parties where id = m.party_id;
    if p.ended_at is not null then return jsonb_build_object('error', 'party_ended'); end if;
    if m.left_at is not null then return jsonb_build_object('error', 'not_member'); end if;
  else
    select m2.* into m from public.watch_party_members m2
      join public.watch_parties p2 on p2.id = m2.party_id
      where m2.user_id = uid and m2.profile_index is not distinct from p_profile_index
        and m2.left_at is null and p2.ended_at is null
      order by m2.joined_at desc limit 1;
    if m.id is null then return jsonb_build_object('error', 'not_in_party'); end if;
  end if;
  if m.device_id <> p_device_id then
    insert into public.watch_party_companions (party_id, member_id, user_id, device_id)
      values (m.party_id, m.id, uid, p_device_id)
      on conflict (party_id, device_id) do update set member_id = excluded.member_id, linked_at = now();
  end if;
  return public._wp_snapshot(m.party_id, m.id);
end; $$;

create function public._wp_chat_payload(m public.watch_party_messages, author public.watch_party_members, p_mine boolean)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'id', m.id, 'member_id', m.member_id, 'name', author.display_name,
    'avatar_url', author.avatar_url, 'avatar_color', author.avatar_color, 'body', m.body,
    'client_id', m.client_id, 'sent_at', (extract(epoch from m.created_at) * 1000)::bigint, 'mine', p_mine)
$$;

create function public.watch_party_send_message(p_party_id uuid, p_device_id text, p_body text, p_client_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := public._wp_uid(); ctx record; v_body text := btrim(coalesce(p_body, '')); v_client text := left(p_client_id, 64);
  msg public.watch_party_messages;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  if length(v_body) = 0 then return jsonb_build_object('error', 'invalid'); end if;
  v_body := left(v_body, 500);
  -- A retry of a message that already went through returns the stored message.
  if v_client is not null then
    select * into msg from public.watch_party_messages
      where party_id = p_party_id and member_id = (ctx.o_member).id and client_id = v_client;
    if msg.id is not null then
      return jsonb_build_object('message', public._wp_chat_payload(msg, ctx.o_member, true));
    end if;
  end if;
  if (select count(*) from public.watch_party_messages
        where member_id = (ctx.o_member).id and created_at > now() - interval '10 seconds') >= 5
     or (select count(*) from public.watch_party_messages where party_id = p_party_id) >= 2000 then
    return jsonb_build_object('error', 'rate_limited');
  end if;
  insert into public.watch_party_messages (party_id, member_id, client_id, body)
    values (p_party_id, (ctx.o_member).id, v_client, v_body) returning * into msg;
  update public.watch_party_members set last_seen_at = now() where id = (ctx.o_member).id;
  perform public._wp_broadcast(p_party_id, 'chat', public._wp_chat_payload(msg, ctx.o_member, false));
  return jsonb_build_object('message', public._wp_chat_payload(msg, ctx.o_member, true));
end; $$;

create function public.watch_party_list_messages(p_party_id uuid, p_device_id text, p_after bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := public._wp_uid(); ctx record;
begin
  select * into ctx from public._wp_context(p_party_id, p_device_id, uid);
  if ctx.o_error is not null then return jsonb_build_object('error', ctx.o_error); end if;
  return jsonb_build_object('messages', coalesce((
    select jsonb_agg(public._wp_chat_payload(t, a, t.member_id = (ctx.o_member).id) order by t.id)
    from (
      select * from public.watch_party_messages
      where party_id = p_party_id and (p_after is null or id > p_after)
      order by id desc limit 100
    ) t join public.watch_party_members a on a.id = t.member_id), '[]'::jsonb));
end; $$;

-- ---------------------------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------------------------

create function public.watch_party_sweep() returns void
language plpgsql security definer set search_path = public as $$
declare cfg public.watch_party_config; r record;
begin
  select * into cfg from public.watch_party_config where id;
  for r in select id from public.watch_party_members
    where left_at is null and last_seen_at < now() - cfg.member_timeout loop
    perform public._wp_remove_member(r.id, 'timeout');
  end loop;
  for r in select id from public.watch_parties where ended_at is null and created_at < now() - cfg.max_age loop
    perform public._wp_end_party(r.id, 'expired');
  end loop;
  delete from public.watch_parties where ended_at is not null and ended_at < now() - cfg.retention;
end; $$;

-- Operator switch (run from the SQL editor, not callable by clients). Turning it off ends live parties.
create function public.watch_party_set_enabled(p_enabled boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  update public.watch_party_config set enabled = p_enabled where id;
  if not p_enabled then
    for r in select id from public.watch_parties where ended_at is null loop
      perform public._wp_end_party(r.id, 'disabled');
    end loop;
  end if;
end; $$;

-- ---------------------------------------------------------------------------------------------
-- Realtime authorization: only current members may read or write their party's channel.
-- ---------------------------------------------------------------------------------------------

create function public.watch_party_topic_allowed(p_topic text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_topic ~ '^watch-party:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then exists (
      select 1 from public.watch_party_members m
      join public.watch_parties p on p.id = m.party_id
      where m.party_id = split_part(p_topic, ':', 2)::uuid
        and m.user_id = auth.uid() and m.left_at is null and p.ended_at is null)
    else false
  end
$$;

do $$
begin
  if to_regclass('realtime.messages') is not null then
    drop policy if exists "watch_party_members_receive" on realtime.messages;
    create policy "watch_party_members_receive" on realtime.messages for select to authenticated
      using (realtime.messages.extension in ('broadcast', 'presence')
        and (select public.watch_party_topic_allowed((select realtime.topic()))));
    drop policy if exists "watch_party_members_send" on realtime.messages;
    create policy "watch_party_members_send" on realtime.messages for insert to authenticated
      with check (realtime.messages.extension in ('broadcast', 'presence')
        and (select public.watch_party_topic_allowed((select realtime.topic()))));
  end if;
end $$;

-- Sweep every two minutes where pg_cron exists (hosted Supabase and the local stack both ship it).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('watch-party-sweep', '*/2 * * * *', 'select public.watch_party_sweep()');
  end if;
exception when others then
  raise notice 'pg_cron unavailable, run public.watch_party_sweep() on a schedule instead: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------------------------

revoke all on function
  public._wp_now_ms(), public._wp_uid(), public._wp_broadcast(uuid, text, jsonb), public._wp_valid_media(jsonb),
  public._wp_clean_playback(jsonb), public._wp_snapshot(uuid, uuid), public._wp_end_party(uuid, text),
  public._wp_remove_member(uuid, text), public._wp_leave_others(uuid, text, uuid), public._wp_new_code(),
  public._wp_clean_text(text, integer), public._wp_chat_payload(public.watch_party_messages, public.watch_party_members, boolean),
  public._wp_context(uuid, text, uuid, boolean),
  public.watch_party_sweep(), public.watch_party_set_enabled(boolean)
from public, anon, authenticated;

revoke all on function
  public.watch_party_enabled(), public.watch_party_clock(),
  public.watch_party_create(text, text, text, text, jsonb, jsonb, integer),
  public.watch_party_join(text, text, text, text, text, integer),
  public.watch_party_preview(text),
  public.watch_party_heartbeat(uuid, text),
  public.watch_party_update(uuid, text, jsonb, jsonb),
  public.watch_party_leave(uuid, text),
  public.watch_party_end(uuid, text),
  public.watch_party_set_host_only(uuid, text, boolean),
  public.watch_party_remove_member(uuid, text, uuid),
  public.watch_party_link_profile(text, integer, uuid),
  public.watch_party_send_message(uuid, text, text, text),
  public.watch_party_list_messages(uuid, text, bigint),
  public.watch_party_topic_allowed(text)
from public, anon;

grant execute on function public.watch_party_enabled(), public.watch_party_clock() to anon, authenticated;
grant execute on function
  public.watch_party_create(text, text, text, text, jsonb, jsonb, integer),
  public.watch_party_join(text, text, text, text, text, integer),
  public.watch_party_preview(text),
  public.watch_party_heartbeat(uuid, text),
  public.watch_party_update(uuid, text, jsonb, jsonb),
  public.watch_party_leave(uuid, text),
  public.watch_party_end(uuid, text),
  public.watch_party_set_host_only(uuid, text, boolean),
  public.watch_party_remove_member(uuid, text, uuid),
  public.watch_party_link_profile(text, integer, uuid),
  public.watch_party_send_message(uuid, text, text, text),
  public.watch_party_list_messages(uuid, text, bigint),
  public.watch_party_topic_allowed(text)
to authenticated;
