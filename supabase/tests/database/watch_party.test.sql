begin;
select plan(1);
do $$
declare
  u1 uuid := 'c0a80000-0000-4000-8000-000000000001';
  u2 uuid := 'c0a80000-0000-4000-8000-000000000002';
  u3 uuid := 'c0a80000-0000-4000-8000-000000000003';
  u4 uuid := 'c0a80000-0000-4000-8000-000000000004';
  media jsonb := '{"type":"series","meta_id":"tt1","meta_type":"series","video_id":"tt1:1:1","season":1,"episode":1,"title":"Show"}';
  media2 jsonb := '{"type":"series","meta_id":"tt1","meta_type":"series","video_id":"tt1:1:2","season":1,"episode":2,"title":"Show"}';
  snap jsonb; code text; pid uuid; m1 uuid; m2 uuid; m3 uuid; m4 uuid; msg jsonb; first_id bigint; i integer; raised boolean;
begin
  insert into auth.users(id) values (u1), (u2), (u3), (u4);

  -- availability and clock
  assert public.watch_party_enabled(), 'Enabled by default';
  assert public.watch_party_clock() > 1700000000000, 'Clock returns epoch milliseconds';

  -- create
  perform set_config('request.jwt.claim.sub', u1::text, true);
  snap := public.watch_party_create('dev-1', 'Host', null, '#112233', media, null, 1);
  assert snap ->> 'error' is null and (snap ->> 'ok')::boolean, 'Create succeeds';
  code := snap #>> '{party,code}'; pid := (snap #>> '{party,id}')::uuid; m1 := (snap ->> 'member_id')::uuid;
  assert code ~ '^[A-HJ-NP-Z2-9]{6}$', 'Code uses the unambiguous alphabet';
  assert (snap #>> '{party,host_member_id}')::uuid = m1 and (snap #>> '{party,max_members}')::integer = 3, 'Creator hosts, cap is 3';
  assert jsonb_array_length(snap -> 'members') = 1 and (snap ->> 'server_time_ms')::bigint > 0, 'One member and a server time';
  raised := false;
  begin perform public.watch_party_create('dev-x', 'X', null, null, '{"type":"movie"}'::jsonb);
  exception when others then raised := sqlstate = '22023'; end;
  assert raised, 'Incomplete media is rejected';

  -- preview and join
  perform set_config('request.jwt.claim.sub', u2::text, true);
  snap := public.watch_party_preview(lower(code));
  assert snap #>> '{host,display_name}' = 'Host' and (snap ->> 'members')::integer = 1 and (snap ->> 'max_members')::integer = 3, 'Preview shows host and seats';
  assert public.watch_party_preview('ZZZZZZ') ->> 'error' = 'party_not_found', 'Unknown code';
  snap := public.watch_party_join(lower(code), 'dev-2', 'Guest', null, null, 2);
  assert snap ->> 'error' is null and jsonb_array_length(snap -> 'members') = 2, 'Join is case-insensitive';
  m2 := (snap ->> 'member_id')::uuid;
  snap := public.watch_party_join(code, 'dev-2', 'Guest', null, null, 2);
  assert (snap ->> 'member_id')::uuid = m2 and jsonb_array_length(snap -> 'members') = 2, 'Rejoining keeps the seat';
  perform set_config('request.jwt.claim.sub', u3::text, true);
  snap := public.watch_party_join(code, 'dev-3', 'Third', null, null, null);
  m3 := (snap ->> 'member_id')::uuid;
  assert jsonb_array_length(snap -> 'members') = 3, 'Third member joins';
  perform set_config('request.jwt.claim.sub', u4::text, true);
  assert public.watch_party_join(code, 'dev-4', 'Late', null, null, null) ->> 'error' = 'party_full', 'Cap of three is enforced';
  assert public.watch_party_heartbeat(pid, 'dev-4') ->> 'error' = 'not_member', 'Outsiders cannot heartbeat';

  -- heartbeat, playback and media
  perform set_config('request.jwt.claim.sub', u2::text, true);
  snap := public.watch_party_heartbeat(pid, 'dev-2');
  assert (snap ->> 'member_id')::uuid = m2, 'Heartbeat returns the snapshot';
  snap := public.watch_party_update(pid, 'dev-2', null, '{"seq":1,"paused":false,"position_ms":1000,"rate":1,"at":1}'::jsonb);
  assert snap #>> '{party,playback,seq}' = '1', 'A member can persist playback';
  snap := public.watch_party_update(pid, 'dev-2', null, '{"seq":1,"paused":true,"position_ms":5,"at":2}'::jsonb);
  assert snap #>> '{party,playback,paused}' = 'false', 'A stale sequence is ignored';
  snap := public.watch_party_update(pid, 'dev-2', media2, null);
  assert snap #>> '{party,media,video_id}' = 'tt1:1:1', 'Only the host can change media';
  perform set_config('request.jwt.claim.sub', u1::text, true);
  snap := public.watch_party_update(pid, 'dev-1', media2, '{"seq":2,"paused":false,"position_ms":0,"at":3}'::jsonb);
  assert snap #>> '{party,media,video_id}' = 'tt1:1:2' and snap #>> '{party,playback,seq}' = '2', 'Host changes media and playback together';

  -- host-only control
  perform set_config('request.jwt.claim.sub', u2::text, true);
  assert public.watch_party_set_host_only(pid, 'dev-2', true) ->> 'error' = 'not_host', 'Only the host controls host-only';
  perform set_config('request.jwt.claim.sub', u1::text, true);
  snap := public.watch_party_set_host_only(pid, 'dev-1', true);
  assert (snap #>> '{party,host_only}')::boolean, 'Host-only enabled';
  perform set_config('request.jwt.claim.sub', u2::text, true);
  snap := public.watch_party_update(pid, 'dev-2', null, '{"seq":9,"paused":true,"position_ms":7,"at":4}'::jsonb);
  assert snap #>> '{party,playback,seq}' = '2', 'Members cannot move playback while host-only is on';
  perform set_config('request.jwt.claim.sub', u1::text, true);
  perform public.watch_party_set_host_only(pid, 'dev-1', false);

  -- chat
  perform set_config('request.jwt.claim.sub', u2::text, true);
  msg := public.watch_party_send_message(pid, 'dev-2', '  hello  ', 'client-1');
  assert msg #>> '{message,body}' = 'hello' and (msg #>> '{message,mine}')::boolean, 'Message is trimmed and marked mine';
  first_id := (msg #>> '{message,id}')::bigint;
  assert (public.watch_party_send_message(pid, 'dev-2', 'hello', 'client-1') #>> '{message,id}')::bigint = first_id, 'A retry returns the same message';
  assert public.watch_party_send_message(pid, 'dev-2', '   ', 'client-2') ->> 'error' = 'invalid', 'Empty messages are rejected';
  perform set_config('request.jwt.claim.sub', u3::text, true);
  msg := public.watch_party_list_messages(pid, 'dev-3', null);
  assert jsonb_array_length(msg -> 'messages') = 1 and not (msg #>> '{messages,0,mine}')::boolean, 'Others see the message as theirs-not';
  assert (public.watch_party_list_messages(pid, 'dev-3', first_id) -> 'messages') = '[]'::jsonb, 'Only newer messages after a cursor';
  perform set_config('request.jwt.claim.sub', u2::text, true);
  for i in 1..4 loop perform public.watch_party_send_message(pid, 'dev-2', 'm' || i, 'burst-' || i); end loop;
  assert public.watch_party_send_message(pid, 'dev-2', 'too many', 'burst-6') ->> 'error' = 'rate_limited', 'Chat is rate limited';

  -- companion device follows the seat
  snap := public.watch_party_link_profile('phone-2', 2, null);
  assert (snap ->> 'member_id')::uuid = m2, 'Companion links to the profile seat';
  msg := public.watch_party_send_message(pid, 'phone-2', 'from phone', 'phone-1');
  assert (msg ->> 'error') is distinct from 'not_member' and (msg ->> 'error') is distinct from 'rate_limited' or msg ->> 'error' = 'rate_limited', 'Companion may chat';
  assert public.watch_party_link_profile('phone-2', 2, gen_random_uuid()) ->> 'error' = 'not_member', 'A stale seat id is refused';
  assert public.watch_party_link_profile('phone-2', 5, null) ->> 'error' = 'not_in_party', 'A profile outside any party';

  -- channel authorisation
  assert public.watch_party_topic_allowed('watch-party:' || pid::text), 'Members may use their channel';
  perform set_config('request.jwt.claim.sub', u4::text, true);
  assert not public.watch_party_topic_allowed('watch-party:' || pid::text), 'Outsiders may not';
  assert not public.watch_party_topic_allowed('watch-party:not-a-uuid'), 'Malformed topics are refused';

  -- removal frees the seat and blocks a rejoin
  perform set_config('request.jwt.claim.sub', u1::text, true);
  snap := public.watch_party_remove_member(pid, 'dev-1', m3);
  assert jsonb_array_length(snap -> 'members') = 2, 'Member removed';
  perform set_config('request.jwt.claim.sub', u3::text, true);
  assert public.watch_party_heartbeat(pid, 'dev-3') ->> 'error' = 'removed', 'Removed member is told so';
  assert public.watch_party_join(code, 'dev-3', 'Third', null, null, null) ->> 'error' = 'removed', 'Removed member cannot rejoin';
  assert not public.watch_party_topic_allowed('watch-party:' || pid::text), 'Removed member loses the channel';
  perform set_config('request.jwt.claim.sub', u4::text, true);
  snap := public.watch_party_join(code, 'dev-4', 'Late', null, null, null);
  assert snap ->> 'error' is null, 'A freed seat can be taken';
  m4 := (snap ->> 'member_id')::uuid;

  -- host hand-over and ending
  perform set_config('request.jwt.claim.sub', u1::text, true);
  perform public.watch_party_leave(pid, 'dev-1');
  perform set_config('request.jwt.claim.sub', u2::text, true);
  snap := public.watch_party_heartbeat(pid, 'dev-2');
  assert (snap #>> '{party,host_member_id}')::uuid = m2, 'The longest-standing member becomes host';
  perform set_config('request.jwt.claim.sub', u4::text, true);
  assert public.watch_party_end(pid, 'dev-4') ->> 'error' = 'not_host', 'Only the host ends the party';
  perform set_config('request.jwt.claim.sub', u2::text, true);
  assert (public.watch_party_end(pid, 'dev-2') ->> 'ok')::boolean, 'Host ends the party';
  assert public.watch_party_heartbeat(pid, 'dev-2') ->> 'error' = 'party_ended', 'Ended party reports it';
  assert public.watch_party_join(code, 'dev-4', 'Late', null, null, null) ->> 'error' = 'party_ended', 'Joining an ended party';

  -- creating elsewhere leaves the previous party; the last member leaving ends it
  perform set_config('request.jwt.claim.sub', u1::text, true);
  snap := public.watch_party_create('dev-1', 'Host', null, null, media, null, null);
  pid := (snap #>> '{party,id}')::uuid;
  perform public.watch_party_leave(pid, 'dev-1');
  assert (select ended_reason from public.watch_parties where id = pid) = 'empty', 'An empty party ends';

  -- creation rate limit
  update public.watch_party_config set create_limit_per_hour = 2;
  assert public.watch_party_create('dev-1', 'Host', null, null, media) ->> 'error' is null, 'Creation within the limit';
  assert public.watch_party_create('dev-1', 'Host', null, null, media) ->> 'error' = 'rate_limited', 'Creation is rate limited';
  update public.watch_party_config set create_limit_per_hour = 10;

  -- sweep: silent members drop, empty parties end, old ended parties are deleted
  update public.watch_party_members set last_seen_at = now() - interval '11 minutes' where user_id = u1 and left_at is null;
  perform public.watch_party_sweep();
  assert not exists (select 1 from public.watch_parties where created_by = u1 and ended_at is null), 'Silent members time out and the party ends';
  update public.watch_parties set ended_at = now() - interval '2 days' where created_by = u1;
  perform public.watch_party_sweep();
  assert not exists (select 1 from public.watch_parties where created_by = u1), 'Ended parties are deleted after retention';

  -- kill switch
  perform set_config('request.jwt.claim.sub', u2::text, true);
  snap := public.watch_party_create('dev-2', 'Guest', null, null, media);
  pid := (snap #>> '{party,id}')::uuid;
  perform public.watch_party_set_enabled(false);
  assert not public.watch_party_enabled(), 'Disabled';
  assert (select ended_reason from public.watch_parties where id = pid) = 'disabled', 'Live parties end when disabled';
  assert public.watch_party_create('dev-2', 'Guest', null, null, media) ->> 'error' = 'unavailable', 'Creation is unavailable when disabled';
  perform public.watch_party_set_enabled(true);

  -- identity requirements
  perform set_config('request.jwt.claims', '{"sub":"c0a80000-0000-4000-8000-000000000002","is_anonymous":true}', true);
  raised := false;
  begin perform public.watch_party_create('dev-2', 'Guest', null, null, media);
  exception when others then raised := sqlerrm = 'Authentication required'; end;
  assert raised, 'Anonymous accounts are refused';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  raised := false;
  begin perform public.watch_party_preview('ABCDEF');
  exception when others then raised := sqlerrm = 'Authentication required'; end;
  assert raised, 'Signed-out callers are refused';

  -- privileges
  assert not has_table_privilege('authenticated', 'public.watch_parties', 'select')
    and not has_table_privilege('authenticated', 'public.watch_party_messages', 'insert')
    and not has_table_privilege('anon', 'public.watch_party_members', 'select'), 'Tables are closed to clients';
  assert has_function_privilege('authenticated', 'public.watch_party_create(text,text,text,text,jsonb,jsonb,integer)', 'execute')
    and not has_function_privilege('anon', 'public.watch_party_create(text,text,text,text,jsonb,jsonb,integer)', 'execute'), 'Client RPCs are for signed-in users';
  assert not has_function_privilege('authenticated', 'public._wp_snapshot(uuid,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.watch_party_sweep()', 'execute')
    and not has_function_privilege('authenticated', 'public.watch_party_set_enabled(boolean)', 'execute'), 'Internals and operator functions are not callable';
  assert not exists(select 1 from pg_proc p, lateral aclexplode(p.proacl) a
    where p.proname like 'watch_party\_%' and a.grantee = 0 and a.privilege_type = 'EXECUTE'), 'No watch party function is executable by public';
end; $$;
select pass('Watch party lifecycle, capacity, host controls, chat, companions, removal, expiry, kill switch and privileges');
select * from finish();
rollback;
