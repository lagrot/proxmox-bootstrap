# Step 13: Frigate Media Retention

This step completes the media-retention policy for both Frigate cameras on the
dedicated `/mnt/frigate` SSD.

## Policy

- Retain C200 and C320WS snapshots for ten days.
- Use one global snapshot policy; do not maintain per-camera retention values.
- Retain alert and detection video for ten days as configured by Step 10O.
- Treat exports as deliberate operator-created files.
- Never delete exports automatically.
- Warn when an export is older than 30 days so it can be reviewed manually.
- Warn when dedicated media SSD usage reaches 80 percent.

Frigate stores snapshot images beneath `/mnt/frigate/clips`; the separately
created `/mnt/frigate/snapshots` directory is not the active Frigate snapshot
location. Exports are stored beneath `/mnt/frigate/exports`.

## Apply The Policy

Run from the Proxmox host as root:

```bash
bash scripts/step13-frigate-media-retention.sh
```

The script:

1. Creates a candidate configuration without changing the active file.
2. Sets global snapshot retention to ten days.
3. Removes only nested per-camera snapshot-retention overrides.
4. Preserves all other camera, recording, MQTT, detector, and hardware settings.
5. Validates the candidate with the exact pinned Frigate container image in an
   isolated writable directory.
6. Saves the previous configuration as
   `/opt/frigate/config/config.yml.bak-media-retention`.
7. Installs the candidate, restarts Frigate, and waits for healthy status.

The script is idempotent. If the active file already represents the policy, it
does not restart Frigate.

Defaults can be overridden in untracked local configuration:

```bash
FRIGATE_SNAPSHOT_RETENTION_DAYS=10
FRIGATE_EXPORT_WARN_AGE_DAYS=30
FRIGATE_MEDIA_WARN_PERCENT=80
```

## Validate And Audit

Run:

```bash
bash scripts/step13b-frigate-media-retention-validation.sh
```

The validation checks:

- Frigate container health;
- the effective API snapshot policy globally and for both cameras;
- dedicated SSD used, total, and percentage capacity;
- snapshot/clip file count and total size;
- export count and total size;
- oldest export name and modification time;
- exports older than the warning threshold.

The validation is read-only. Export age and SSD-capacity findings are warnings,
not deletion instructions. Remove an export only after confirming it is no
longer needed through Frigate's Export view.

## Rollback

If a policy rollback is required, stop Frigate, restore the matching backup,
and start it again:

```bash
pct exec 200 -- bash -c 'cd /opt/frigate && docker compose stop frigate'
pct exec 200 -- cp -a \
  /opt/frigate/config/config.yml.bak-media-retention \
  /opt/frigate/config/config.yml
pct exec 200 -- bash -c 'cd /opt/frigate && docker compose up -d frigate'
```

Then run Step 04B, Step 10I, Step 10N, and Step 13B validation. Restoring the
backup also restores the previous per-camera snapshot values.

## Verified Baseline

The first Step 13 validation completed with both cameras using ten-day snapshot
retention. The dedicated 500 GB-class SSD was 5 percent used. Snapshot/clip
storage was approximately 525 MiB, and one approximately 1 MiB export remained
untouched. There were no policy errors or age/capacity warnings.

## References

- [Frigate snapshot configuration](https://docs.frigate.video/configuration/snapshots/)
- [Frigate recording and export configuration](https://docs.frigate.video/configuration/record/)
- [Frigate configuration validation](https://docs.frigate.video/configuration/advanced/#validating-your-configyml-file-updates)
