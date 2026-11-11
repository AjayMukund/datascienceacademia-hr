-- HR / attendance projection for hr.datascienceacademia.in
-- Biometric data (fingerprint templates/images) is NEVER stored here; it stays on the local attendance PC.
-- Source of truth for people & attendance is the local PC, pushed via the hr-sync Edge Function.
-- Adds new hr_* objects only; existing LMS tables are untouched (reuses public.is_admin()).

create table public.hr_people (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique,
  name           text not null,
  role           text not null check (role in ('student','staff')),
  grp            text not null default '',
  email          text not null default '',
  guardian_email text not null default '',
  active         boolean not null default true,
  joined_on      date not null default ((now() at time zone 'Asia/Kolkata')::date),
  user_id        uuid unique references auth.users(id) on delete set null,
  updated_at     timestamptz not null default now()
);
create index hr_people_email_idx on public.hr_people (lower(email));
create index hr_people_gemail_idx on public.hr_people (lower(guardian_email));
create index hr_people_grp_idx on public.hr_people (grp);

create table public.hr_attendance (
  person_id uuid not null references public.hr_people(id) on delete cascade,
  day       date not null,
  in_time   time not null,
  out_time  time,
  late      boolean not null default false,
  method    text not null default 'fingerprint',
  synced_at timestamptz not null default now(),
  primary key (person_id, day)
);
create index hr_attendance_day_idx on public.hr_attendance (day);

create table public.hr_guardians (
  user_id   uuid not null references auth.users(id) on delete cascade,
  person_id uuid not null references public.hr_people(id) on delete cascade,
  primary key (user_id, person_id)
);
create index hr_guardians_person_idx on public.hr_guardians (person_id);

create table public.hr_trainer_groups (
  person_id uuid not null references public.hr_people(id) on delete cascade,
  grp       text not null,
  primary key (person_id, grp)
);

create table public.hr_holidays (
  day  date primary key,
  name text not null default ''
);

create table public.hr_settings (
  id        int primary key default 1 check (id = 1),
  data      jsonb not null default '{}'::jsonb,
  last_sync timestamptz
);
insert into public.hr_settings (id, data) values (1, '{
  "org_name":"Data Science Academia","late_after_student":"09:30","late_after_staff":"09:15",
  "working_days":"0,1,2,3,4,5","alert_consecutive":"3","alert_min_pct":"75","alert_window_days":"30"}');

-- ───────────────────────────── access helpers ─────────────────────────────
create or replace function public.hr_can_see(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or exists (select 1 from hr_people where id = pid and user_id = auth.uid())
      or exists (select 1 from hr_guardians where person_id = pid and user_id = auth.uid())
      or exists (select 1 from hr_people me
                   join hr_trainer_groups tg on tg.person_id = me.id
                   join hr_people p on p.grp = tg.grp and p.role = 'student'
                  where me.user_id = auth.uid() and me.active and me.role = 'staff' and p.id = pid)
$$;

create or replace function public.hr_whoami() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'is_admin', public.is_admin(),
    'email', (select email from auth.users where id = auth.uid()),
    'self', (select to_jsonb(x) from (select id, code, name, role, grp from hr_people
                                       where user_id = auth.uid() and active) x),
    'children', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'grp', p.grp) order by p.name)
                            from hr_guardians g join hr_people p on p.id = g.person_id
                           where g.user_id = auth.uid() and p.active), '[]'::jsonb),
    'trainer_groups', coalesce((select jsonb_agg(tg.grp order by tg.grp)
                                  from hr_people me join hr_trainer_groups tg on tg.person_id = me.id
                                 where me.user_id = auth.uid() and me.active and me.role = 'staff'), '[]'::jsonb),
    'org_name', (select data->>'org_name' from hr_settings where id = 1),
    'last_sync', (select last_sync from hr_settings where id = 1)
  )
$$;

-- Link the signed-in (email-verified) user to their attendance record and/or as guardian.
create or replace function public.hr_link_me() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid := auth.uid(); em text;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select lower(email) into em from auth.users where id = uid and email_confirmed_at is not null;
  if em is not null and em <> '' then
    if not exists (select 1 from hr_people where user_id = uid) then
      update hr_people set user_id = uid
       where id = (select id from hr_people where user_id is null and lower(email) = em
                   order by active desc, role desc limit 1);
    end if;
    insert into hr_guardians (user_id, person_id)
      select uid, id from hr_people where guardian_email <> '' and lower(guardian_email) = em
      on conflict do nothing;
  end if;
  return public.hr_whoami();
end $$;

-- ───────────────────────────── RLS ─────────────────────────────
alter table public.hr_people         enable row level security;
alter table public.hr_attendance     enable row level security;
alter table public.hr_guardians      enable row level security;
alter table public.hr_trainer_groups enable row level security;
alter table public.hr_holidays       enable row level security;
alter table public.hr_settings       enable row level security;

create policy hr_people_read on public.hr_people for select to authenticated using (public.hr_can_see(id));
create policy hr_att_read    on public.hr_attendance for select to authenticated using (public.hr_can_see(person_id));
create policy hr_guard_read  on public.hr_guardians for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy hr_guard_admin on public.hr_guardians for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy hr_tg_read     on public.hr_trainer_groups for select to authenticated
  using (public.is_admin() or exists (select 1 from public.hr_people me where me.id = person_id and me.user_id = auth.uid()));
create policy hr_tg_admin    on public.hr_trainer_groups for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy hr_hol_read    on public.hr_holidays for select to authenticated using (true);
create policy hr_set_read    on public.hr_settings for select to authenticated using (true);
-- people / attendance / holidays / settings are written only by hr_sync_push (service role).

revoke all on public.hr_people, public.hr_attendance, public.hr_guardians, public.hr_trainer_groups,
              public.hr_holidays, public.hr_settings from anon;

-- ───────────────────────────── sync (service role only) ─────────────────────────────
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

  -- an email changed: drop account / guardian links that no longer match
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
revoke execute on function public.hr_can_see(uuid), public.hr_whoami(), public.hr_link_me() from public, anon;
grant execute on function public.hr_can_see(uuid), public.hr_whoami(), public.hr_link_me() to authenticated;
