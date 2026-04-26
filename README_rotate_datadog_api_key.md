# Rotate Datadog API Key

Updates the Datadog Agent's `api_key` on already-installed agents (Linux + Windows)
by pulling the current key from AWS Secrets Manager. Designed to drop into the
existing **Ansible Core** repo and run as a normal GitLab CI pipeline job.

## What it does (and doesn't)

| Does | Does not |
| --- | --- |
| Fetches the API key from AWS Secrets Manager once on the runner | Install the Datadog Agent |
| Updates `api_key:` line in `datadog.yaml` (Linux + Windows) | Touch any other Datadog config |
| Backs up the existing config before changing it | Send the key to target hosts via env vars or files on disk |
| Restarts the agent and verifies it returns to healthy | Log the key (everything that touches it has `no_log: true`) |
| Rolls back to the backup if anything fails | Fail the entire pipeline if some hosts don't have the agent (it skips them) |

## File placement in the repo

```
playbooks/
  config/
    rotate_datadog_api_key.yml   <-- this file
```

The repo's existing `playbooks/config/` directory is the right home (see "Repository
Structure" in the project README — `config/` is for "Configuration management").

## Required pipeline variables

| Variable | Required | Default | Example |
| --- | --- | --- | --- |
| `datadog_secret_name` | yes | — | `datadog/prod/api_key` |
| `aws_region` | no | `us-gov-west-1` | `us-gov-west-1` |
| `datadog_secret_json_key` | no (only if secret is JSON) | unset | `api_key` |
| `dry_run` | no | `false` | `true` |
| `datadog_restart_agent` | no | `true` | `false` |
| `LIMIT_PATTERN` | yes (set on the CI job) | — | `env_Production:&os_linux` |

## AWS Secrets Manager — secret formats supported

**Plain string** (recommended for simplicity):
```
secret_name: datadog/prod/api_key
secret_value: a1b2c3d4...   <-- the API key, nothing else
```
No `datadog_secret_json_key` needed.

**JSON object** (if you store other Datadog keys alongside it):
```json
{
  "api_key": "a1b2c3d4...",
  "app_key": "e5f6g7h8..."
}
```
Set `datadog_secret_json_key=api_key`.

## IAM permissions the runner needs

The GitLab runner's role must already be able to assume the cross-account role used
by the inventory generator. On top of that, in whichever account holds the secret,
the runner role needs:

```
secretsmanager:GetSecretValue   on  arn:aws-us-gov:secretsmanager:us-gov-west-1:<acct>:secret:datadog/prod/api_key-*
kms:Decrypt                     on  the KMS key that encrypts the secret (if CMK)
```

## How to run it (matches existing `bootstrap_linux_hosts` pattern)

1. Go to **CI/CD → Pipelines → Run Pipeline**
2. Select job: `rotate_datadog_api_key`
3. Set variables:
   - `LIMIT_PATTERN`: e.g. `env_Production:&os_linux` or `env_Production:&os_windows`
     or just `env_Production` to hit both
   - `datadog_secret_name`: e.g. `datadog/prod/api_key`
   - `dry_run`: `true` for first run (recommended), then `false`
4. Click **Run Pipeline → Play**
5. Review `ansible_output.log` artifact when the job finishes

### Recommended rollout sequence

```
# 1. Dry run on one host
LIMIT_PATTERN=env_Sandbox:&os_linux
dry_run=true

# 2. Real run on sandbox
LIMIT_PATTERN=env_Sandbox:&os_linux
dry_run=false

# 3. Production Linux
LIMIT_PATTERN=env_Production:&os_linux
dry_run=false

# 4. Production Windows
LIMIT_PATTERN=env_Production:&os_windows
dry_run=false
```

## How the safety model works

```
1. Fetch key on the runner (delegate_to: localhost, run_once)
   |
   |  [no_log on every task; key never written to disk on the runner]
   v
2. For each Linux host (parallel):
       Backup datadog.yaml -> datadog.yaml.bak.<epoch>
       lineinfile: replace api_key line
       systemd: restart datadog-agent
       Wait for `datadog-agent status` to return 0  (6 retries x 10s)
       Verify ActiveState == active
       |
       +-- on failure: rescue
           Restore backup, restart agent on old config, fail loudly

3. For each Windows host (parallel):
       Backup C:\ProgramData\Datadog\datadog.yaml
       win_lineinfile: replace api_key line
       win_service: restart datadogagent
       Wait for `agent.exe status` to return 0
       Verify state == running
       |
       +-- on failure: rescue
           Restore backup, restart agent on old config, fail loudly
```

## Why it's structured the way it is

- **Single fetch on `localhost`, then `hostvars` to share** — the runner has the
  IAM role to call Secrets Manager. Target EC2s do not need to. Faster too:
  one API call per pipeline run instead of N calls.
- **`no_log: true` on every task that touches the key** — Ansible's default
  output (and GitLab job logs, which retain artifacts for 30 days) would
  otherwise leak the key.
- **`lineinfile` instead of templating the whole file** — leaves the rest of
  `datadog.yaml` (site, tags, integrations, log config, etc.) alone. Templating
  the whole file would silently wipe everything that wasn't explicitly modeled
  in the role.
- **Backup → modify → restart → verify → rescue** — matches the repo's stated
  "Block/rescue: Critical operations have automatic rollback" guarantee.
- **`meta: end_host` when `datadog.yaml` is missing** — hosts that never had
  the agent installed get cleanly skipped instead of failing the play.
- **Hex-format check on the retrieved value** — Datadog API keys are always
  32 hex characters. If something else comes back, that's a clear sign the
  wrong secret was named or the JSON key is wrong, and we want to fail before
  writing a bad key onto every host.

## Troubleshooting

**`datadog_secret_name must be provided`**
Pipeline variable wasn't set. Re-run with `datadog_secret_name=...`.

**`The value retrieved from Secrets Manager does not look like a Datadog API key`**
Either you pointed at the wrong secret, or the secret is JSON and you forgot
`datadog_secret_json_key=api_key`.

**`AccessDeniedException` on the secrets lookup**
The runner role can't read that secret. Add `secretsmanager:GetSecretValue` (and
`kms:Decrypt` if CMK-encrypted) on the secret's ARN. If the secret lives in a
different account, the secret's resource policy also needs to allow the runner
role.

**Some hosts skipped silently**
That's intentional — those hosts don't have `datadog.yaml`, so there's no agent
to rotate. To find them, after the run check the inventory:
```
ansible -i inventories/generated/static_inventory.yml '<your_pattern>' --list-hosts
```
and compare to the host list in the playbook output.

**`datadog-agent did not return to active state`**
The new key was written and the restart failed. The rescue block has already
restored the previous `datadog.yaml`, so the host is back on the old key. Check
`/var/log/datadog/agent.log` (Linux) or `C:\ProgramData\Datadog\logs\agent.log`
(Windows). Most common cause: the new key is invalid in Datadog's backend.
