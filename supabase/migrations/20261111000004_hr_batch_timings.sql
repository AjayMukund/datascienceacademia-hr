-- Per batch / department timings (late-after time, class days), pushed from the attendance PC.
-- Reports now judge each person against their own batch's class days and late time.

create table if not exists public.hr_groups (
  grp          text primary key,
  late_after   text,            -- 'HH:MM' or null = role default
  working_days text             -- '0,2,4' (Mon=0) or null = institute default
);
alter table public.hr_groups enable row level security;
drop policy if exists hr_groups_read on public.hr_groups;
create policy hr_groups_read on public.hr_groups for select to authenticated using (true);
revoke all on public.hr_groups from anon;

-- sync: accept the full list of group timings
create or replace function public.hr_sync_push(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n_people int := 0; n_att int := 0; n_del int := 0; changed text[];
begin
  with up as (
    insert into hr_people (code, name, role, grp, email, guardian_email, active, joined_on, updated_at)
    select x.code, x.name, x.role, coalesce(x.grp,''), coalesce(x.email,''), coalesce(x.guardian_email,''),
           coalesce(x.active, true), coalesce(x.joined_on, (now() at time zone 'Asia/Kolkata')::date), now()
      from jsonb_to_recordset(coalesce(p->'people','[]')) as x(code text, name text, role text, grp text, email text,
                                                                 guardian_email text, active boolean, joined_on date)
    on conflict (code) do update set name = excluded.name, role = excluded.role, grp = excluded.grp,
      email = excluded.email, guardian_email = excluded.guardian_email, active = excluded.active,
      joined_on = excluded.joined_on, updated_at = now()
    returning code)
  select count(*), array_agg(code) into n_people, changed from up;

  if changed is not null then
    update hr_people hp set user_id = null from auth.users u
     where hp.code = any(changed) and hp.user_id = u.id and lower(u.email) <> lower(hp.email);
    delete from hr_guardians g using hr_people hp, auth.users u
     where g.person_id = hp.id and hp.code = any(changed) and g.user_id = u.id
       and lower(u.email) <> lower(hp.guardian_email);
  end if;

  delete from hr_people where code in (select jsonb_array_elements_text(coalesce(p->'people_deleted','[]')));

  with up as (
    insert into hr_attendance (person_id, day, in_time, out_time, late, method, synced_at)
    select hp.id, x.day, x.in_time, x.out_time, coalesce(x.late,false), coalesce(x.method,'fingerprint'), now()
      from jsonb_to_recordset(coalesce(p->'attendance','[]')) as x(code text, day date, in_time time, out_time time,
                                                                     late boolean, method text)
      join hr_people hp on hp.code = x.code
    on conflict (person_id, day) do update set in_time = excluded.in_time, out_time = excluded.out_time,
      late = excluded.late, method = excluded.method, synced_at = now()
    returning 1)
  select count(*) into n_att from up;

  with d as (
    delete from hr_attendance a using hr_people hp,
           jsonb_to_recordset(coalesce(p->'attendance_deleted','[]')) as x(code text, day date)
     where a.person_id = hp.id and hp.code = x.code and a.day = x.day returning 1)
  select count(*) into n_del from d;

  insert into hr_holidays (day, name)
    select x.day, coalesce(x.name,'') from jsonb_to_recordset(coalesce(p->'holidays','[]')) as x(day date, name text)
  on conflict (day) do update set name = excluded.name;
  delete from hr_holidays where day::text in (select jsonb_array_elements_text(coalesce(p->'holidays_deleted','[]')));

  if p ? 'groups' then
    delete from hr_groups where true;
    insert into hr_groups (grp, late_after, working_days)
      select x.grp, nullif(x.late_after, ''), nullif(x.working_days, '')
        from jsonb_to_recordset(p->'groups') as x(grp text, late_after text, working_days text)
       where coalesce(x.grp, '') <> '';
  end if;

  update hr_settings set
    data = case when p ? 'settings' then data || (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(p->'settings') e(k, v)
                where k in ('org_name','late_after_student','late_after_staff','working_days',
                            'alert_consecutive','alert_min_pct','alert_window_days')) else data end,
    last_sync = now()
  where id = 1;

  return jsonb_build_object('people', n_people, 'attendance', n_att, 'attendance_deleted', n_del);
end $$;
revoke execute on function public.hr_sync_push(jsonb) from public, anon, authenticated;
grant execute on function public.hr_sync_push(jsonb) to service_role;

-- ───────────────────────── reports with per-person schedules ─────────────────────────
create or replace function public.hr_summary(p_days int default 30, p_role text default null, p_grp text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  nowt text := to_char(now() at time zone 'Asia/Kolkata', 'HH24:MI');
  gwd int[]; win int; streak_n int; min_pct numeric; lb int;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  p_days := least(greatest(coalesce(p_days, 30), 7), 180);
  p_role := nullif(p_role, ''); p_grp := nullif(p_grp, '');
  select data into s from hr_settings where id = 1;
  gwd      := string_to_array(coalesce(nullif(s->>'working_days', ''), '0,1,2,3,4,5'), ',')::int[];
  win      := coalesce((s->>'alert_window_days')::int, 30);
  streak_n := coalesce((s->>'alert_consecutive')::int, 3);
  min_pct  := coalesce((s->>'alert_min_pct')::numeric, 75);
  lb       := greatest(p_days, win, 120);

  with
  vis as (select p.*,
                 coalesce(g.late_after, case when p.role = 'student' then coalesce(s->>'late_after_student', '09:30')
                                             else coalesce(s->>'late_after_staff', '09:15') end) as la,
                 coalesce(string_to_array(nullif(g.working_days, ''), ',')::int[], gwd) as pwd
            from hr_people p left join hr_groups g on g.grp = p.grp
           where p.active and public.hr_can_see(p.id)
             and (p_role is null or p.role = p_role) and (p_grp is null or p.grp = p_grp)),
  cal as (select d::date as day, extract(isodow from d)::int - 1 as dow
            from generate_series(today - lb, today, interval '1 day') d
           where not exists (select 1 from hr_holidays h where h.day = d::date)),
  att as (select a.* from hr_attendance a join vis on vis.id = a.person_id where a.day between today - lb and today),
  pd as (select v.id, c.day, (c.day < today or nowt > v.la) as complete,
                (a.person_id is not null) as present, coalesce(a.late, false) as late
           from vis v join cal c on c.day >= v.joined_on and c.dow = any(v.pwd)
           left join att a on a.person_id = v.id and a.day = c.day),
  lastp as (select person_id, max(day) as last_day from att group by person_id),
  trend as (select day, count(*) as expected, count(*) filter (where present) as present,
                   count(*) filter (where late) as late
              from pd where day > today - p_days
             group by day having day < today or bool_and(complete)),
  pp as (select v.id, v.code, v.name, v.role, v.grp, v.la as late_after,
                count(*) filter (where pd.complete and pd.day > today - win) as possible,
                count(*) filter (where pd.complete and pd.day > today - win and pd.present) as attended,
                count(*) filter (where pd.complete and not pd.present
                                   and pd.day > coalesce(lp.last_day, v.joined_on - 1)) as streak
           from vis v
           left join pd on pd.id = v.id
           left join lastp lp on lp.person_id = v.id
          group by v.id, v.code, v.name, v.role, v.grp, v.la, v.joined_on, lp.last_day),
  ppx as (select pp.*, case when possible > 0 then round(100.0 * attended / possible, 1) end as pct from pp),
  alerts as (select ppx.*,
                    array_remove(array[
                      case when streak >= streak_n then format('Absent %s class days in a row', streak) end,
                      case when possible >= 5 and pct < min_pct
                           then format('Attendance %s%% (below %s%%) over last %s days', pct, min_pct, win) end
                    ], null) as reasons,
                    case when streak >= streak_n * 2 or (pct is not null and pct < min_pct - 15)
                         then 'critical' else 'serious' end as level
               from ppx where streak >= streak_n or (possible >= 5 and pct < min_pct)),
  today_att as (select a.person_id, a.in_time, a.out_time, a.late, v.code, v.name, v.role, v.grp
                  from att a join vis v on v.id = a.person_id where a.day = today),
  missing as (select ppx.*, pd.complete as past_cut
                from ppx join pd on pd.id = ppx.id and pd.day = today
               where not pd.present),
  grps as (select role, coalesce(nullif(grp, ''), '—') as grp, count(*) as people,
                  round(100.0 * sum(attended) / sum(possible), 1) as pct
             from ppx where possible > 0 group by 1, 2)
  select jsonb_build_object(
    'today', today,
    'is_working_today', exists (select 1 from pd where day = today),
    'people', (select count(*) from vis),
    'present_today', (select count(*) from today_att),
    'late_today', (select count(*) from today_att where late),
    'absent_today',  coalesce((select jsonb_agg(to_jsonb(m) order by m.grp, m.name) from missing m where past_cut), '[]'::jsonb),
    'not_yet_today', coalesce((select jsonb_agg(to_jsonb(m) order by m.grp, m.name) from missing m where not past_cut), '[]'::jsonb),
    'avg_pct', (select round(avg(100.0 * present / expected), 1) from trend where day < today and expected > 0),
    'trend', coalesce((select jsonb_agg(jsonb_build_object(
                 'day', day, 'expected', expected, 'present', present, 'late', late,
                 'pct', case when expected > 0 then round(100.0 * present / expected, 1) end) order by day) from trend), '[]'::jsonb),
    'by_group', coalesce((select jsonb_agg(to_jsonb(g) order by g.pct) from grps g), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(to_jsonb(a) order by a.level <> 'critical', a.streak desc, a.pct nulls last)
                          from alerts a), '[]'::jsonb),
    'people_rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.pct nulls last, x.name) from ppx x), '[]'::jsonb),
    'today_rows', coalesce((select jsonb_agg(jsonb_build_object('id', person_id, 'code', code, 'name', name, 'role', role,
                 'grp', grp, 'in_time', in_time, 'out_time', out_time, 'late', late) order by in_time desc) from today_att), '[]'::jsonb),
    'settings', s,
    'last_sync', (select last_sync from hr_settings where id = 1)
  ) into result;
  return result;
end $$;

create or replace function public.hr_person_report(p_person uuid, p_days int default 90)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb; p hr_people; g hr_groups;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  nowt text := to_char(now() at time zone 'Asia/Kolkata', 'HH24:MI');
  la text; cut boolean; wd int[]; result jsonb;
begin
  if auth.uid() is null or not public.hr_can_see(p_person) then raise exception 'not allowed'; end if;
  p_days := least(greatest(coalesce(p_days, 90), 7), 370);
  select * into p from hr_people where id = p_person;
  select * into g from hr_groups where grp = p.grp;
  select data into s from hr_settings where id = 1;
  la  := coalesce(g.late_after, case when p.role = 'student' then coalesce(s->>'late_after_student', '09:30')
                                     else coalesce(s->>'late_after_staff', '09:15') end);
  cut := nowt > la;
  wd  := coalesce(string_to_array(nullif(g.working_days, ''), ',')::int[],
                  string_to_array(coalesce(nullif(s->>'working_days', ''), '0,1,2,3,4,5'), ',')::int[]);

  with cal as (
    select d::date as day, (extract(isodow from d)::int - 1) = any(wd) as workday, h.name as holiday
      from generate_series(today - (p_days - 1), today, interval '1 day') d
      left join hr_holidays h on h.day = d::date),
  x as (
    select c.day, c.holiday, a.in_time, a.out_time, a.method,
           case when a.person_id is not null then case when a.late then 'late' else 'present' end
                when c.day < p.joined_on then 'none'
                when c.holiday is not null then 'holiday'
                when not c.workday then 'off'
                when c.day = today and not cut then 'pending'
                else 'absent' end as status,
           case when a.out_time is not null
                then round((extract(epoch from (a.out_time - a.in_time)) / 3600.0)::numeric, 2) end as hours
      from cal c left join hr_attendance a on a.person_id = p.id and a.day = c.day)
  select jsonb_build_object(
    'person', jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'role', p.role, 'grp', p.grp,
                                 'joined_on', p.joined_on, 'late_after', la),
    'days', jsonb_agg(jsonb_build_object('day', day, 'status', status, 'in', in_time, 'out', out_time,
                                         'hours', hours, 'holiday', holiday, 'method', method) order by day),
    'present',  count(*) filter (where status in ('present', 'late')),
    'late',     count(*) filter (where status = 'late'),
    'absent',   count(*) filter (where status = 'absent'),
    'possible', count(*) filter (where status in ('present', 'late', 'absent')),
    'hours',    round(coalesce(sum(hours), 0), 1),
    'settings', s,
    'today', today,
    'last_sync', (select last_sync from hr_settings where id = 1))
  into result from x;
  return result;
end $$;

revoke execute on function public.hr_summary(int, text, text), public.hr_person_report(uuid, int) from public, anon;
grant execute on function public.hr_summary(int, text, text), public.hr_person_report(uuid, int) to authenticated;
