# Plan: a verified `atomx-transfer` CLI that an agent can use as a tool

## Goal

Turn the shell scripts in `scripts/` into one tool that:

1. Copies an AtoMx sample (raw and additional files) into a GCS bucket and **proves** the copy is
   complete: every file checked by size against AtoMx and by crc32c against GCS.
2. Writes **status markers** in the bucket (`in_progress` → `done` / `failed`), so anything
   downstream (for example a segmentation trigger) can tell a finished transfer from one that is
   still running.
3. Can be **run by an agent as a tool**: the agent proposes the transfer and the user confirms it.
   The AtoMx login is entered once through a secure form (never in chat), saved, and reused.

The same CLI stays usable by hand on any machine, like the scripts are today.

---

## 1. How the agent uses this repo

**Yes: the agent uses this repo's code directly as its transfer tool, and it asks for the AtoMx
login the first time, then saves it.** Two details determine *where* the code runs and *how* the
login is collected.

### 1.1 Where it runs: a transfer job, not the agent's own sandbox

An analysis agent's code-execution sandbox normally has **no network access** (it should not be
able to send data anywhere) and runs for minutes. A transfer needs outbound SFTP plus bucket write
access, and it runs for hours. So:

- The agent's **tool call** is `start_transfer(export_root, sample, …)`.
- The agent platform runs this repo's CLI in a **separate transfer job**: a container built from
  a pinned commit of this repo, with network egress, a bucket-write identity limited to the
  destination prefixes, and the user's credential (§1.2).
- The job reports progress and the final result, and the markers (§3) record the outcome in the
  bucket.
- The agent also gets a **read-only status tool** (`transfer_status`) built on the markers and
  the inventory (§2.2), so it can answer "what's transferred, what's in progress, what's still on
  AtoMx?".

No always-on transfer server is needed. A job is started per transfer.

### 1.2 Credentials: asked once through a secure form, then saved and reused

The agent asks for the AtoMx login **once**. The first person to start a transfer enters it,
the agent saves it, and every later transfer reuses it without asking again. Nothing is
hardcoded in the code or config.

**Never in chat.** The agent must not ask for the login as a chat message:

- Chat messages are kept in Slack's history.
- Agent platforms typically store the incoming message (event receipts, request records,
  conversation memory) and send its text to the language model. A password typed in chat ends up
  in all of those places.

**Flow:**

1. **No saved login yet.** On the first transfer request, the agent replies with an **"Enter
   AtoMx login"** button. The button opens a **Slack modal** (a pop-up form) with username and
   password.
2. **Save.** The form submission goes straight from Slack to the platform's interaction endpoint.
   That handler adds it as a new version of **one saved-login secret** in a secret manager
   (scoped to the project, no expiry), and **nothing else** gets the password: no logs, no
   conversation record, no model context.
   - Non-secret details go in a small record next to it: username, who saved it, and when.
   - The agent replies "AtoMx login saved by @person. Future transfers will use it."
3. **Reuse.** Every later transfer, by anyone allowed to start one, uses the saved login without
   asking. The confirmation preview says which login will be used ("using the AtoMx login
   `user@…` saved by @person on 6 Oct").
4. **Ask again only when needed:**
   - **The login stopped working.** The transfer job reports `auth_failed` (for example after a
     password change). The agent marks the saved login invalid and shows the "Enter AtoMx login"
     button again. The new login replaces the old one.
   - **Someone replaces or removes it on purpose.** `replace atomx login` opens the form;
     `forget atomx login` disables the saved secret version. Allowed for the project owner or the
     person who saved it.
   - `atomx login status` shows the username, who saved it, when, and whether the last use
     worked. It never shows the password.
5. **Use at run time only.** The transfer job reads the secret when it starts. It never passes
   through environment variables or job metadata and never appears in logs or progress output.
   Only the transfer job's identity can read the secret, and only the interaction handler can
   add versions.
6. If someone pastes a password into chat anyway, the agent says not to and recommends changing
   that AtoMx password.

Because everyone's transfers run under the saved account, every marker and notice records both
`requested_by` (who asked) and `login_saved_by` (whose AtoMx account was used). A lab or service
AtoMx login is preferable to a personal one, if NanoString offers it (§5).

### 1.3 Confirmation

The agent may *propose* a transfer, but a person must confirm it:

- The agent posts a preview: export root, run folder, file count, size, destination prefixes,
  and whether the sample is already `done` or `in_progress`.
- It shows **Confirm / Cancel** buttons, and only the requesting user's click counts.
- The job never starts from the model's text alone.

---

## 2. The CLI (`atomx_transfer`, Python package)

Replaces `sshpass`/`sftp`/`gcloud` shell-outs with `paramiko` (SFTP, password auth, pinned host
key) and `google-cloud-storage` / `google-crc32c`.

### 2.1 Commands

- **`atomx-transfer pull --config project.yaml --export-root /… --sample tma37 [--as TMA37]`**
  1. **Claim:** create `transfer_status/<sample>.in_progress.json` (create-only). Refuse if
     `done` exists (unless `--force`) or if another live `in_progress` exists.
  2. **Plan:** list the remote run folder and `flatFiles/<sample>/` with sizes.
     - Use the latest run folder; record any others and warn.
     - Map every file to its exact destination object name from the config. This is a fixed
       per-file mapping, never `cp -r`, so nested duplicates are impossible.
  3. **Copy:** stream each file from SFTP to GCS, computing crc32c on the way. No local staging
     disk is needed.
     - An existing object with the same size and crc32c is skipped, which makes the command
       resumable.
     - An existing object that differs is an error.
     - Otherwise upload create-only (`if_generation_match=0`). Nothing is ever overwritten.
  4. **Verify:** list both destination prefixes. They must match the plan exactly: names,
     sizes, crc32c, and no extras.
  5. **Done:** write `<sample>.done.json` with the manifest (§3), then delete `in_progress`.
     - Refresh a `heartbeat` in `in_progress` every 5 minutes throughout.
     - On error, write `<sample>.failed.json` with the step and error, and exit non-zero.
       Re-running resumes.
  - Progress goes to stdout as JSON lines (`{"event": "progress", "files_done": …,
    "bytes_done": …}`) so a job runner or agent can relay it.
- **`atomx-transfer inventory --config project.yaml [--publish]`**
  - Lists export roots and samples on AtoMx (run folders, file counts, bytes) and compares them
    with the markers.
  - Each sample is reported as `on_atomx_only`, `in_progress`, `done`, `failed`,
    `changed_since_done` or `bucket_only`.
  - `--publish` writes `transfer_status/_inventory.json` for the agent's status tool.
- **`atomx-transfer verify --config project.yaml --sample T`:** read-only re-check of a `done`
  marker against the bucket.

### 2.2 Project config (one YAML per project; no secrets)

```yaml
bucket: your-bucket
status_prefix: transfer_status/
sftp:
  host: na.export.atomx.nanostring.com
  port: 22
  host_key: "ssh-ed25519 AAAA…"   # pinned (capture once with ssh-keyscan; verify by hand)
layout:
  raw:
    - {from: "{run}/CellStatsDir/Morphology2D/", to: "raw_outputs/raw/{sample}/Morphology2D/"}
    - {from: "{run}/RunSummary/Morphology_ChannelID_Dictionary.txt", to: "raw_outputs/raw/{sample}/"}
    - {from: "{export_root}/flatFiles/{remote_sample}/", to: "raw_outputs/raw/{sample}/"}
  additional_files:
    - {from: "{run}/", to: "raw_outputs/additional_files/{sample}/",
       exclude: ["CellStatsDir/Morphology2D/**", "RunSummary/Morphology_ChannelID_Dictionary.txt"]}
```

The username and password are **not** in the config. They come from the environment or a
password file when run by hand, or from the secret manager when run as an agent job (§1.2).

**Golden test:** a fake SFTP tree must map to exactly the object names the current scripts
produce. Build the fixture from a real bucket listing of one transferred sample.

---

## 3. Marker contract v1 (the interface for downstream tools)

Every marker is in `<bucket>/transfer_status/`:

| Object | Meaning |
|---|---|
| `<sample>.in_progress.json` | transfer running; `heartbeat` refreshed every 5 min |
| `<sample>.done.json` | bucket verified against the export |
| `<sample>.failed.json` | gave up; `step`, `error` |
| `_inventory.json` | latest AtoMx inventory (§2.1) |

Common fields:

```
version: 1
sample, remote_sample, export_root, run_folder
requested_by (email or "manual:<host>"), login_saved_by (whose AtoMx login was used)
started, heartbeat, finished
tool_version (git commit)
```

`done` adds:

- `manifest`: one `{name, size, crc32c}` per object.
- `n_files`, `total_bytes`.
- `source`: `{n_files, total_bytes}` from SFTP.

Consumers should:

1. Treat `in_progress` as "not ready", whatever else they see.
2. Trust `done` only after re-checking its manifest against a fresh listing.
3. Call a transfer stuck when the heartbeat is more than 60 minutes old.

Publish `schema/marker-v1.json` and example marker files under `tests/fixtures/markers/`.
Consumers copy these for their own tests instead of importing this package.

---

## 4. Milestones

- **M0 (done):** import the working shell scripts with no site-specific values, a single batch
  runner, an inventory script, and examples.
- **M1:** Python package skeleton, `schema/marker-v1.json`, marker fixtures, and the layout golden
  test, written failing first.
- **M2:** `pull` / `inventory` / `verify` against an in-memory fake SFTP server and fake GCS.
  - Tests: resume, create-only, skip-if-identical, fail-if-different, extra-object failure,
    heartbeat, the `failed` marker, and that a password never appears in logs or progress
    output.
- **M3:** a container image plus a job entrypoint (`atomx-transfer job --request request.json`)
  that reads the saved credential from a secret manager at runtime and reports `auth_failed`
  distinctly from other errors (so the agent knows to ask for the login again).
- **M4:** the first real transfer of a new sample by hand with the CLI, compared against the old
  scripts. Then retire `scripts/` (keep them in git history).
- **M5 (agent platform side, in the agent's own repo):**
  - The `start_transfer` and `transfer_status` tools.
  - The Confirm/Cancel buttons, the "Enter AtoMx login" modal, and `atomx login status` /
    `replace atomx login` / `forget atomx login`.
  - The secret-manager handler, and job launching with a least-privilege identity (write only
    to the destination prefixes and `transfer_status/`).

---

## 5. Open questions

1. **License for this public repo.** None yet, so it is "all rights reserved" by default.
   Options include MIT or BSD-3.
2. **Which account to save:** does NanoString offer a lab or service AtoMx export login? Otherwise
   the first person's personal login is saved and shared by everyone's transfers (§1.2).
3. **Who may start transfers from the agent:** project owner only, or any project member?
