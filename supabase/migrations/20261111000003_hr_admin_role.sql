-- Allow role 'admin' on attendance records (admins give fingerprints and are tracked like staff:
-- staff late cutoff, hours worked). Admins/staff can both be assigned as trainers for batches.
-- Website admin rights still come from profiles.role = 'admin' (portal), not from this column.

alter table public.hr_people drop constraint hr_people_role_check;
alter table public.hr_people add constraint hr_people_role_check check (role in ('student', 'staff', 'admin'));

create or replace function public.hr_can_see(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
      or exists (select 1 from hr_people where id = pid and user_id = auth.uid())
      or exists (select 1 from hr_guardians where person_id = pid and user_id = auth.uid())
      or exists (select 1 from hr_people me
                   join hr_trainer_groups tg on tg.person_id = me.id
                   join hr_people p on p.grp = tg.grp and p.role = 'student'
                  where me.user_id = auth.uid() and me.active and me.role in ('staff', 'admin') and p.id = pid)
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
                                 where me.user_id = auth.uid() and me.active and me.role in ('staff', 'admin')), '[]'::jsonb),
    'org_name', (select data->>'org_name' from hr_settings where id = 1),
    'last_sync', (select last_sync from hr_settings where id = 1)
  )
$$;
