# Landet local viewer backend

The one-camera integration proof has been extended to the complete local
TV-fönstret. Use [the local viewer guide](../LOCAL-VIEWER.md) and
`scripts/step22c-landet-viewer.sh` for both cameras, twelve recent clips, and
four thermometers. The earlier `step22c-landet-proof.sh` launcher is historical
pilot work; its one-source relay does not supply the full viewer's channels.

The original Windows pilot verified real clip play/seek and live fullscreen.
Subsequent local Chromium tests proved HQ main-stream video and HLS VOD.
The full-viewer guide records current commands, boundaries and remaining checks.
No production deployment or public Cloudflare route has been created.
