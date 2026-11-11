-- Report functions for hr.datascienceacademia.in.
-- SECURITY DEFINER + an explicit hr_can_see() filter: every caller only ever aggregates people they may see
-- (admin: everyone; trainer: their batches; student/staff: self; guardian: their children).
-- Rules mirror the local app (attendance/reports.py). Times are Asia/Kolkata.

create or replace function public.hr_summary(p_days int default 30, p_role text default null, p_grp text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  nowt text := to_char(now() at time zone 'Asia/Kolkata', 'HH24:MI');
  cut_s boolean; cut_t boolean; wd int[]; win int; streak_n int; min_pct numeric; is_wd boolean;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  p_days := least(greatest(coalesce(p_days, 30), 7), 180);
  p_role := nullif(p_role, ''); p_grp := nullif(p_grp, '');
  select data into s from hr_settings where id = 1;
  cut_s    := nowt > coalesce(s->>'late_after_student', '09:30');
  cut_t    := nowt > coalesce(s->>'late_after_staff', '09:15');
  wd       := string_to_array(coalesce(nullif(s->>'working_days', ''), '0,1,2,3,4,5'), ',')::int[];
  win      := coalesce((s->>'alert_window_days')::int, 30);
  streak_n := coalesce((s->>'alert_consecutive')::int, 3);
  min_pct  := coalesce((s->>'alert_min_pct')::numeric, 75);
  is_wd    := (extract(isodow from today)::int - 1) = any(wd)
              and not exists (select 1 from hr_holidays where day = today);

  with
  vis as (select p.* from hr_people p
           where p.active and public.hr_can_see(p.id)
             and (p_role is null or p.role = p_role) and (p_grp is null or p.grp = p_grp)),
  cal as (select d::date as day from generate_series(today - 180, today, interval '1 day') d
           where (extract(isodow from d)::int - 1) = any(wd)
             and not exists (select 1 from hr_holidays h where h.day = d::date)),
  att as (select a.* from hr_attendance a join vis on vis.id = a.person_id
           where a.day between today - 180 and today),
  pd as (select v.id, c.day,
                (c.day < today or case when v.role = 'student' then cut_s else cut_t end) as complete,
                (a.person_id is not null) as present, coalesce(a.late, false) as late
           from vis v join cal c on c.day >= v.joined_on
           left join att a on a.person_id = v.id and a.day = c.day),
  lastp as (select person_id, max(day) as last_day from att group by person_id),
  trend as (select c.day, count(pd.id) as expected,
                   count(*) filter (where pd.present) as present,
                   count(*) filter (where pd.late) as late
              from cal c left join pd on pd.day = c.day
             where c.day > today - p_days and (c.day < today or (cut_s and cut_t))
             group by c.day),
  pp as (select v.id, v.code, v.name, v.role, v.grp,
                count(*) filter (where pd.complete and pd.day > today - win) as possible,
                count(*) filter (where pd.complete and pd.day > today - win and pd.present) as attended,
                count(*) filter (where pd.complete and not pd.present
                                   and pd.day > coalesce(lp.last_day, v.joined_on - 1)) as streak
           from vis v
           left join pd on pd.id = v.id
           left join lastp lp on lp.person_id = v.id
          group by v.id, v.code, v.name, v.role, v.grp, v.joined_on, lp.last_day),
  ppx as (select pp.*, case when possible > 0 then round(100.0 * attended / possible, 1) end as pct from pp),
  alerts as (select ppx.*,
                    array_remove(array[
                      case when streak >= streak_n then format('Absent %s working days in a row', streak) end,
                      case when possible >= 5 and pct < min_pct
                           then format('Attendance %s%% (below %s%%) over last %s days', pct, min_pct, win) end
                    ], null) as reasons,
                    case when streak >= streak_n * 2 or (pct is not null and pct < min_pct - 15)
                         then 'critical' else 'serious' end as level
               from ppx where streak >= streak_n or (possible >= 5 and pct < min_pct)),
  today_att as (select a.person_id, a.in_time, a.out_time, a.late, v.code, v.name, v.role, v.grp
                  from att a join vis v on v.id = a.person_id where a.day = today),
  missing as (select ppx.*, case when ppx.role = 'student' then cut_s else cut_t end as past_cut
                from ppx join vis v on v.id = ppx.id
               where is_wd and v.joined_on <= today
                 and not exists (select 1 from today_att t where t.person_id = ppx.id)),
  grps as (select role, coalesce(nullif(grp, ''), '—') as grp, count(*) as people,
                  round(100.0 * sum(attended) / sum(possible), 1) as pct
             from ppx where possible > 0 group by 1, 2)
  select jsonb_build_object(
    'today', today,
    'is_working_today', is_wd,
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

-- One person's day-by-day record (self, guardian's child, trainer's student, or any for admin).
create or replace function public.hr_person_report(p_person uuid, p_days int default 90)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb; p hr_people;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  nowt text := to_char(now() at time zone 'Asia/Kolkata', 'HH24:MI');
  cut boolean; wd int[]; result jsonb;
begin
  if auth.uid() is null or not public.hr_can_see(p_person) then raise exception 'not allowed'; end if;
  p_days := least(greatest(coalesce(p_days, 90), 7), 370);
  select * into p from hr_people where id = p_person;
  select data into s from hr_settings where id = 1;
  cut := nowt > coalesce(case when p.role = 'student' then s->>'late_after_student' else s->>'late_after_staff' end, '09:30');
  wd  := string_to_array(coalesce(nullif(s->>'working_days', ''), '0,1,2,3,4,5'), ',')::int[];

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
    'person', jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'role', p.role, 'grp', p.grp, 'joined_on', p.joined_on),
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

-- Admin view of people + account status (for invites and trainer/batch assignment).
create or replace function public.hr_admin_people()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.is_admin() then null else coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'code', p.code, 'name', p.name, 'role', p.role, 'grp', p.grp, 'email', p.email,
    'guardian_email', p.guardian_email, 'active', p.active, 'joined_on', p.joined_on,
    'has_account', p.user_id is not null,
    'email_has_account', exists (select 1 from auth.users u where p.email <> '' and lower(u.email) = lower(p.email)),
    'guardian_linked', exists (select 1 from hr_guardians g where g.person_id = p.id),
    'guardian_has_account', exists (select 1 from auth.users u where p.guardian_email <> '' and lower(u.email) = lower(p.guardian_email)),
    'groups', coalesce((select jsonb_agg(grp order by grp) from hr_trainer_groups tg where tg.person_id = p.id), '[]'::jsonb)
  ) order by p.active desc, p.role, p.grp, p.name), '[]'::jsonb) end
  from hr_people p
$$;
revoke execute on function public.hr_admin_people() from public, anon;
grant execute on function public.hr_admin_people() to authenticated;
