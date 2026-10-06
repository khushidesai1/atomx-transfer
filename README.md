# atomx-transfer

Scripts for copying CosMx runs from an **AtoMx export SFTP server** into a **Google Cloud Storage**
bucket, one sample (e.g. one TMA) at a time.

These are the shell scripts currently used by hand on a transfer VM. The next step turns them into
a verified, resumable Python CLI that an agent can run as a tool. See [docs/PLAN.md](docs/PLAN.md).

## What gets copied where

An AtoMx export looks like:

```
/<EXPORT_ROOT>/                          e.g. /MyExport_17_08_2026_10_31_17_209 (may hold several samples)
  DecodedFiles/<sample>/<YYYYMMDD_HHMMSS_S#>/   run folder (the latest one is used)
    CellStatsDir/Morphology2D/*.TIF
    RunSummary/Morphology_ChannelID_Dictionary.txt
    ... everything else
  flatFiles/<sample>/                    *_tx_file.csv.gz, *_fov_positions_file.csv.gz, ...
```

| Script | Copies | To |
|---|---|---|
| `scripts/get_tma.sh` | `Morphology2D/`, the channel dictionary, `flatFiles/<sample>/*` | `$GCS_RAW_DEST_BASE/<sample>/` |
| `scripts/get_tma_addfiles.sh` | the rest of the run folder | `$GCS_ADDITIONAL_DEST_BASE/<sample>/` |
| `scripts/run_batch.sh` | runs either script for every line of a batch file, stopping at the first failure, with optional Slack webhook updates | |
| `scripts/sftp_inventory.sh` | lists which samples each export root contains | |

## Quick start

Requirements: `bash`, `sftp`, `sshpass`, `gcloud` (logged in with write access to the bucket),
`python3`, and `curl`.

```bash
cp examples/env.example ~/.atomx-transfer.env && chmod 600 ~/.atomx-transfer.env
# edit it: your AtoMx login, password file, and bucket destinations
source ~/.atomx-transfer.env

# What's in an export?
SFTP_PASSWORD="$(cat "$ATOMX_PASSWORD_FILE")" scripts/sftp_inventory.sh /MyExport_17_08_2026_10_31_17_209

# One sample
export SFTP_PASSWORD="$(cat "$ATOMX_PASSWORD_FILE")"
scripts/get_tma.sh /MyExport_17_08_2026_10_31_17_209 tma33
scripts/get_tma_addfiles.sh /MyExport_17_08_2026_10_31_17_209 tma33

# Many samples (see examples/batch.example.tsv)
scripts/run_batch.sh raw my_batch.tsv
scripts/run_batch.sh additional my_batch.tsv
```

Credentials are never stored in this repo. The password comes from `SFTP_PASSWORD`, or from a
file you name in `ATOMX_PASSWORD_FILE`.

## Known limitations of the current scripts

These are fixed by the plan in [docs/PLAN.md](docs/PLAN.md):

- **"SUCCESS" is not verification.** It only means `sftp` and `gcloud storage cp` exited 0. No
  sizes or checksums are compared.
- **Re-running can nest a duplicate copy.** `cp -r` into a destination that already exists can
  create `<sample>/<sample>/…`.
- **Raw and additional files are separate runs**, often days apart, and nothing marks a sample as
  completely transferred.
- **Downloaded data is never cleaned up** from local disk.
- **The SFTP host key is accepted on first use** (`StrictHostKeyChecking=accept-new`) rather than
  pinned.
