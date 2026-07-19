# Step 14: Frigate Face Recognition

Step 14 begins with a read-only readiness assessment. Native Frigate face
recognition is not enabled by Step 14A.

## Architecture And Boundaries

Frigate first detects a `person`, then looks for and recognizes a face in the
camera stream assigned the `detect` role. The current default COCO/Coral model
does not natively detect a `face` object, so a future pilot must not add `face`
to the tracked-object list. Frigate will use its lightweight CPU face detector
after the Coral detects a person.

The Coral accelerates object detection only. Face detection and the `small`
FaceNet recognition model run on the CPU. Frigate can use Intel OpenVINO for
supported enrichment acceleration, making the Iris Xe a possible later option
for the more accurate `large` model. The large model is not part of Step 14A.

All processing remains local to Frigate. Names, training images, recognition
attempts, and embeddings are sensitive biometric data and must not be
committed, copied into documentation, or sent to third-party services.

## Step 14A Readiness Assessment

Run from the Proxmox host as root:

```bash
bash scripts/step14a-frigate-face-recognition-readiness.sh
```

The script is read-only. It retrieves effective config and stats into protected
temporary files, reports selected non-secret fields, and removes the files on
exit. It does not restart Frigate or change camera, Home Assistant, MQTT, or
face-library data.

It checks:

- Frigate container health, pinned image, and API version;
- native face-recognition config availability and current enabled state;
- CPU model plus AVX and AVX2 requirements;
- CT CPU and memory allocation;
- Intel render-device visibility for a possible later large-model test;
- detect resolution, configured FPS, runtime FPS, and skipped FPS per camera;
- Coral inference, Intel GPU, Frigate CPU/memory, embeddings, and storage
  baselines;
- privacy and one-camera pilot gates.

## Verified Step 14A Results

| Check | Result |
|---|---|
| Frigate | `0.17.2-3d4dd3a`, healthy, pinned `0.17.2` image |
| Face recognition | supported, disabled |
| Default face model | `small` |
| Effective thresholds | detection `0.7`, recognition `0.9`, unknown `0.8` |
| Effective face controls | minimum area `750`, minimum faces `1` |
| CPU | Intel i9-12900H, AVX and AVX2 available |
| CT allocation | 4 cores, 4096 MiB RAM |
| Intel GPU | `/dev/dri/renderD128` readable inside Frigate |
| C200 detect stream | 640x360 at 5 FPS, no skipped FPS |
| C320WS detect stream | 640x360 at 5 FPS, no skipped FPS |
| Coral baseline | approximately 24.2 ms inference |
| Frigate resource sample | approximately 1.7% CPU and 50.9% memory |
| Recognition/embedding stats | idle, as expected |
| Readiness errors | 0 |
| Readiness warnings | 2, one resolution warning per camera |

The resource figures are point-in-time comparison baselines. They are not
promises about peak usage.

## Privacy Gate

Before Step 14B:

1. Enrol only household members who have agreed.
2. Do not automatically enrol visitors or delivery workers.
3. Keep recognition, training, and notifications local over the LAN/Tailscale.
4. Treat Frigate configuration/database backups containing face data as
   sensitive and protected.
5. Define how unknown and poor-quality training attempts will be reviewed and
   removed.
6. Prefer a camera scene where recognition is useful and expected; avoid a
   private room merely because that camera has the better sensor.

## Step 14B Decision Gate

No pilot should be deployed until these choices are explicit:

- pilot camera and final physical placement;
- one or more consenting test identities;
- acceptable false-match rate (recommended: zero during the initial pilot);
- acceptable unknown/missed recognition behavior;
- test periods covering daylight and evening;
- rollback command and post-change regression suite.

The first pilot should use the `small` CPU model on one camera and leave the
other camera unchanged as a control. Keep the current thresholds initially.
Train with 5-10 varied, clear colour images, then expand toward 20-30 only when
needed. Test the existing 640x360 stream before increasing detect resolution.

If face detail is inadequate, change only the pilot camera, keep detect at 5
FPS, and repeat Coral, VAAPI, camera, recording, MQTT, Home Assistant, CPU, and
memory validation. Consider the `large` Intel-GPU model only if the small model
remains inaccurate after image-quality and training improvements.

## Home Assistant Research Direction

Successful names are added to Frigate person objects as `sub_label` values.
Recognition attempts are also published through
`frigate/tracked_object_update`, while review updates can include recognized
names in `data.sub_labels`. The standard Home Assistant integration does not
document one entity per known face. Step 15 notifications should therefore
evaluate Frigate MQTT/review data instead of assuming a dedicated identity
sensor exists.

## References

- [Frigate face recognition](https://docs.frigate.video/configuration/face_recognition/)
- [Frigate hardware-accelerated enrichments](https://docs.frigate.video/configuration/hardware_acceleration_enrichments/)
- [Frigate MQTT integration](https://docs.frigate.video/integrations/mqtt/)
- [Frigate Home Assistant integration](https://docs.frigate.video/integrations/home-assistant/)
