#!/usr/bin/env python3
"""Exercise Step 10J VAAPI validation with a fake Proxmox command."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/step10j-frigate-gpu-validation.sh"


class FrigateGpuValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "bin").mkdir()
        (self.root / "app; harmless").mkdir()
        self.config = self.root / "config.yml"
        self.config.write_text("ffmpeg:\n  hwaccel_args: preset-vaapi\ntelemetry:\n  stats:\n    intel_gpu_stats: true\n")
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$PCT_CALLS"
case "$1" in
  status)
    [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
    [[ "$STATUS_STOPPED" == 1 ]] && echo 'status: stopped' || echo 'status: running' ;;
  exec)
    shift 3
    case "$1" in
      bash)
        if [[ "$3" == *'command -v docker'* ]]; then exit 0; fi
        if [[ "$3" == *'docker compose config | grep'* ]]; then
          [[ "$COMPOSE_OK" == 1 ]] || exit 1
          echo '/dev/dri/renderD128' >/dev/null; exit 0
        fi
        if [[ "$3" == *'docker compose config'* ]]; then [[ "$COMPOSE_OK" == 1 ]]; exit $?; fi
        exit 1 ;;
      test)
        if [[ "$2" == -f ]]; then [[ -f "$TEST_CONFIG" ]]; exit $?; fi
        [[ "$DEVICE_OK" == 1 ]] || exit 1
        case "$2 $3" in '-d /dev/dri'|'-c /dev/dri/renderD128'|'-r /dev/dri/renderD128'|'-w /dev/dri/renderD128') exit 0 ;; *) exit 1 ;; esac ;;
      grep)
        args=("${@:2}")
        for i in "${!args[@]}"; do [[ "${args[$i]}" != /opt/frigate/config/config.yml ]] || args[$i]="$TEST_CONFIG"; done
        grep "${args[@]}" ;;
      docker)
        if [[ "$2" == ps ]]; then echo frigate
        elif [[ "$2" == exec && "$3" == frigate && "$4" == test ]]; then [[ "$DEVICE_OK" == 1 ]]
        elif [[ "$2" == exec && "$3" == frigate && "$4" == sh ]]; then
          if [[ "$6" == *'command -v ffmpeg'* ]]; then echo "$FFMPEG_PATH"; exit 0
          elif [[ "$6" == *'command -v timeout'* ]]; then exit 0
          elif [[ "$6" == *'command -v intel_gpu_top'* ]]; then exit "$INTEL_GPU_TOP_OK"
          elif [[ "$6" == *'ps -eo args'* ]]; then printf '%s\n' "$FFMPEG_PROCESSES"
          else exit 1; fi
        elif [[ "$2" == exec && "$3" == frigate && "$4" == "$FFMPEG_PATH" && "$5" == -hide_banner ]]; then
          echo vaapi
        elif [[ "$2" == exec && "$3" == frigate && "$4" == timeout ]]; then
          [[ "$5" == 10 && "$6" == "$FFMPEG_PATH" ]] && exit "$VAAPI_INIT_OK"
          exit 1
        elif [[ "$2" == inspect ]]; then echo "$FRIGATE_STARTED_AT"
        elif [[ "$2" == logs ]]; then
          [[ "$LOG_OK" == 1 ]] || exit 1
          [[ " ${*:2} " == *" --tail 1000 "* || " ${*:2} " == *" --tail 300 "* ]] || exit 9
          printf '%s\n' "$LOG_TEXT"
        elif [[ "$2" == exec && "$3" == frigate && "$4" == python3 ]]; then
          [[ "$GPU_API_OK" == 1 ]] || exit 1
          if [[ "$GPU_STATS_JSON" == *'error-gpu'* ]]; then echo ERROR
          elif [[ "$GPU_STATS_JSON" == '{}' ]]; then echo MISSING
          elif [[ "$GPU_STATS_JSON" == *'"gpu":"","mem":""'* ]]; then echo 'EMPTY|intel-vaapi'
          else echo 'FOUND|intel-vaapi|gpu=1.25%|mem=-'; fi
        else exit 1; fi ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
''')
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        PCT_CALLS=str(self.root / "pct-calls"), TEST_CONFIG=str(self.config),
                        STATUS_FAIL="0", STATUS_STOPPED="0", DEVICE_OK="1", COMPOSE_OK="1",
                        FFMPEG_PATH="/usr/lib/ffmpeg/5.0/bin/ffmpeg", VAAPI_INIT_OK="0",
                        FRIGATE_STARTED_AT="2026-11-18T00:00:00Z", LOG_OK="1", LOG_TEXT="",
                        FFMPEG_PROCESSES="ffmpeg -hwaccel vaapi -i rtsp://camera",
                        GPU_API_OK="1", GPU_STATS_JSON='{"gpu_usages":{"intel-vaapi":{"gpu":"1.25%","mem":"-"}}}',
                        INTEL_GPU_TOP_OK="0")

    def run_script(self, **overrides):
        return subprocess.run(["bash", str(SCRIPT)], env=dict(self.env, **overrides),
                              text=True, capture_output=True)

    def test_complete_vaapi_route_passes_with_shell_safe_app_path_and_bounded_probe(self):
        app_dir = self.root / "app; harmless"
        result = self.run_script(FRIGATE_APP_DIR=str(app_dir))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FFmpeg can initialize VAAPI", result.stdout)
        self.assertIn("Live FFmpeg process arguments reference VAAPI", result.stdout)
        self.assertIn("Frigate reports GPU telemetry", result.stdout)
        calls = (self.root / "pct-calls").read_text()
        self.assertIn("--since 2026-11-18T00:00:00Z --tail 1000", calls)
        self.assertIn("timeout 10 /usr/lib/ffmpeg/5.0/bin/ffmpeg", calls)

    def test_status_errors_and_stopped_ct_are_distinct(self):
        query_error = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(query_error.returncode, 0)
        self.assertIn("Could not query status", query_error.stdout)
        self.assertNotIn("is not running", query_error.stdout)
        stopped = self.run_script(STATUS_STOPPED="1")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertIn("CT 200 is not running", stopped.stdout)
        self.assertNotIn("Could not query status", stopped.stdout)

    def test_hardware_errors_and_log_failures_are_reported(self):
        no_vaapi = self.run_script(VAAPI_INIT_OK="1")
        self.assertNotEqual(no_vaapi.returncode, 0)
        self.assertIn("could not initialize VAAPI", no_vaapi.stdout)
        log_error = self.run_script(LOG_TEXT="VAAPI error: failed to initialize device")
        self.assertNotEqual(log_error.returncode, 0)
        self.assertIn("logs contain VAAPI/hardware acceleration failures", log_error.stdout)
        log_failure = self.run_script(LOG_OK="0")
        self.assertEqual(log_failure.returncode, 0, log_failure.stdout + log_failure.stderr)
        self.assertIn("Could not read Frigate logs", log_failure.stdout)
        self.assertNotIn("No VAAPI/hardware acceleration failures found", log_failure.stdout)

    def test_live_process_and_gpu_stats_degraded_states_are_visible(self):
        no_process = self.run_script(FFMPEG_PROCESSES="")
        self.assertEqual(no_process.returncode, 0)
        self.assertIn("No live FFmpeg processes found", no_process.stdout)
        gpu_error = self.run_script(GPU_STATS_JSON='{"gpu_usages":{"error-gpu":{}}}')
        self.assertNotEqual(gpu_error.returncode, 0)
        self.assertIn("error-gpu", gpu_error.stdout)
        gpu_empty = self.run_script(GPU_STATS_JSON='{"gpu_usages":{"intel-vaapi":{"gpu":"","mem":""}}}')
        self.assertEqual(gpu_empty.returncode, 0)
        self.assertIn("usage values are currently empty", gpu_empty.stdout)
        gpu_missing = self.run_script(GPU_STATS_JSON="{}")
        self.assertEqual(gpu_missing.returncode, 0)
        self.assertIn("does not report GPU telemetry", gpu_missing.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
