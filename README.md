# hr.datascienceacademia.in: HR & attendance portal

The online view of the fingerprint attendance system. **Fingerprints never leave the attendance PC.** Only
attendance records (ID, name, batch, emails, check-in/out times) are pushed here.

```
Attendance PC (MFS100 + local app, e:\Projects\Biometrics\attendance)
   │  every 60 s, queued while offline
   ▼
Supabase Edge Function  hr-sync   (shared secret HR_SYNC_KEY)
   ▼
Supabase project "datascienceacademia": hr_* tables + row-level security
   ▲
hr.datascienceacademia.in (this repo, GitHub Pages): sign-in with the same accounts as the student portal
```

| Who | Sees |
|---|---|
| Admin (`profiles.role = 'admin'`) | everything, plus People & access (invites, trainer batches) |
| Trainer (staff record + batches ticked on People & access) | own record + those student batches |
| Student / staff | own record (linked by the email on their record) |
| Parent / guardian | their child (linked by the guardian email on the child's record) |

## Folder map

| Path | What |
|---|---|
| `site/` | the static site (published) |
| `supabase/migrations/` | SQL for the `hr_*` tables, access rules and report functions |
| `supabase/functions/hr-sync` | receives pushes from the attendance PC (`verify_jwt = false`, checks `x-sync-key`) |
| `supabase/functions/hr-invite` | admin-only: emails account invites |

## One-time setup

1. **Database**: in Supabase → SQL Editor, run `supabase/migrations/20261111000001_hr_attendance_projection.sql`,
   then `20261111000002_hr_reports.sql`. They only add new `hr_*` objects.
2. **Sync secret**: Supabase → Edge Functions → Secrets → add `HR_SYNC_KEY` = the key stored in the attendance
   app (Admin → Settings → Online sync; the same value is already saved there).
3. **Auth URLs**: Supabase → Authentication → URL Configuration → Redirect URLs → add
   `https://hr.datascienceacademia.in/**`. Keep the main site as Site URL.
4. **Email**: invites and password links need custom SMTP (Authentication → Emails → SMTP). The built-in
   sender only delivers to project team members.
5. **GitHub**: create a repo (e.g. `datascienceacademia-hr`), push this folder, then Settings → Pages →
   Source = GitHub Actions, custom domain `hr.datascienceacademia.in`, Enforce HTTPS.
6. **DNS (Hostinger)**: add a `CNAME` record, host `hr`, target `<github-username>.github.io`.
7. **Turn on sync**: on the attendance PC → Admin → Settings → Online sync → On → Save → Sync now.
