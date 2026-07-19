# Step 18: Controlled Frigate Stable Upgrades

This runbook upgrades the standalone Frigate Docker Compose deployment in CT
200 to a deliberately selected stable release. It is version-independent and
is not specific to Frigate 0.18.

Frigate currently remains pinned to `ghcr.io/blakeblackshear/frigate:0.17.2`.
The procedure has been tested without performing a production upgrade.

## Non-Negotiable Rules

- Use an exact `X.Y.Z` target such as `0.18.0` or `0.18.1`.
- Never use `stable`, `latest`, beta, RC, development, or nightly targets.
- Confirm the release is officially stable and review its release notes and
  breaking changes before passing `--release-notes-reviewed`.
- Never skip the stopped-state Step 18B backup.
- Keep the previous exact Docker image until the new version is accepted.
- Restore matching Compose and `/config` together because upgrades may migrate
  `frigate.db`.
- Do not delete `/mnt/frigate` recordings, snapshots, or exports during upgrade
  or rollback.

## Tested Status

| Stage | Safe test performed | Production mutation |
|---|---|---|
| 18A preflight | exact local 0.17.2 config validation | none |
| 18B executor | 0.17.2 same-version dry run | none |
| 18C validation | seven-track 0.17.2 baseline test | none |
| 18D rollback | disposable archive restore test | none |

These tests prove the workflow mechanics available without claiming that a
future Frigate release is compatible.

## Stage 18A: Preflight

After confirming the target is officially stable:

```bash
bash scripts/step18a-frigate-upgrade-preflight.sh \
  --target X.Y.Z \
  --release-notes-reviewed
```

Preflight checks health, current image/API version, Compose validity, backup
capacity, exact target-image availability, and target-image config validation.
Pulling the target image does not alter the running container.

Use `--skip-pull` only when the exact target image is already local. This is
primarily useful for repeat tests.

## Stage 18B: Dry Run

Always review the generated action summary first:

```bash
bash scripts/step18b-frigate-upgrade.sh \
  --target X.Y.Z \
  --release-notes-reviewed \
  --dry-run
```

Record the planned backup path and confirm Frigate was not restarted.

## Stage 18B: Controlled Upgrade

Schedule a maintenance window, then run:

```bash
bash scripts/step18b-frigate-upgrade.sh \
  --target X.Y.Z \
  --release-notes-reviewed \
  --confirm-upgrade
```

The executor:

1. Re-runs Step 18A.
2. Rejects a real same-version upgrade.
3. Stops Frigate for a consistent database/config backup.
4. Creates `/var/lib/frigate-upgrades/<timestamp>-<old>-to-<target>/`.
5. Archives Compose and complete `/opt/frigate/config`.
6. Records exact old/target image metadata.
7. Verifies checksums and archive readability.
8. Changes exactly one Compose image entry.
9. Validates Compose, starts Frigate, waits for health, and checks API version.

Copy the reported backup directory; Step 18C and Step 18D require it.

## Stage 18C: Accept Or Reject

Run the matching post-upgrade validation:

```bash
bash scripts/step18c-frigate-post-upgrade-validation.sh \
  --expected-version X.Y.Z \
  --backup-dir /var/lib/frigate-upgrades/<run>
```

Normal mode validates backup checksums, archive readability, target metadata,
exact running image/API version, health, both cameras, Coral, VAAPI, event
recording, MQTT, Home Assistant, and media retention. Any failed track means
the upgrade is not accepted.

`--baseline-test` skips backup validation and is only for testing orchestration
without claiming an upgrade.

## Stage 18D: Rollback

First inspect the rollback without mutation:

```bash
bash scripts/step18d-frigate-rollback.sh \
  --backup-dir /var/lib/frigate-upgrades/<run> \
  --dry-run
```

Optionally test extraction into temporary storage:

```bash
bash scripts/step18d-frigate-rollback.sh \
  --backup-dir /var/lib/frigate-upgrades/<run> \
  --restore-test
```

Perform rollback only when the new release is rejected:

```bash
bash scripts/step18d-frigate-rollback.sh \
  --backup-dir /var/lib/frigate-upgrades/<run> \
  --confirm-rollback
```

Rollback verifies the original backup and exact old image, extracts into
staging, stops Frigate, archives the failed/current state, restores matching
Compose plus complete config/database, verifies old health/API version, and
runs Step 18C baseline regression. The failed state remains available for
diagnosis.

## Cleanup

Do not clean up immediately. Keep the old image, upgrade backup, and any failed
state until the new version has operated normally for an agreed observation
period. Cleanup remains a deliberate manual action; none of these scripts
automatically deletes backups or images.

## References

- [Frigate updating guide](https://docs.frigate.video/frigate/updating/)
- [Frigate releases](https://github.com/blakeblackshear/frigate/releases)
- [Frigate configuration validation](https://docs.frigate.video/configuration/advanced/#validating-your-configyml-file-updates)
