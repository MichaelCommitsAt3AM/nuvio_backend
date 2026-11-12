# nuvio_backend

The Supabase backend shared by the Nuvio desktop app ([NuvioDesktopButBetter](https://github.com/MichaelCommitsAt3AM/NuvioDesktopButBetter))
and the mobile app ([NuvioMobileButBetter](https://github.com/MichaelCommitsAt3AM/NuvioMobileButBetter)). Both clients use the
same hosted Supabase project, so schema changes here affect both.

## Layout

| Path | Contents |
| --- | --- |
| `supabase/migrations/` | Schema history. Timestamped, forward-only. |
| `supabase/functions/` | Edge functions (`delete-account`). |
| `supabase/tests/database/` | pgTAP contract tests. |
| `supabase/assets/avatars/` | Built-in profile avatar artwork (from the Nuvio self-hosted distribution, Apache-2.0). |
| `scripts/` | Contract check, DB test scripts and the avatar uploader. |

## Rules

- Never edit a migration that has been applied to the hosted project; add a new timestamped one.
- Apply migrations first, then ship the client change that needs them. Both apps must keep working against the previous schema until they update.
- Never commit keys, `.env` files or `supabase/.temp` (ignored). The service-role key stays in your shell.

## Common tasks

```bash
supabase link --project-ref <ref>        # once per machine
supabase migration list --linked         # what is applied
supabase db push --linked                # apply pending migrations

SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=... scripts/upload_avatars.sh

supabase db reset && supabase test db    # local database + pgTAP (needs Docker)
python scripts/check_supabase_rpc_contracts.py ../NuvioDesktopButBetter ../NuvioMobileButBetter
```

CI (`.github/workflows/supabase-database-tests.yml`) runs the contract check against both client repositories, a fresh
database build with pgTAP, and an upgrade test. If the client repositories are private, add a `CLIENT_REPO_TOKEN` secret.
