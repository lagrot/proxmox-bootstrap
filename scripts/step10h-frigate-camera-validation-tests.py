#!/usr/bin/env python3
"""Exercise Step 10H camera validation without contacting live services."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("frigate_rtsp_smoke", REPO / "lib/frigate-rtsp-smoke.py")
rtsp_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rtsp_helper)


class RtspSmokeHelperTests(unittest.TestCase):
    def test_url_encodes_credentials_and_probe_writes_no_media_file(self):
        self.assertEqual(rtsp_helper.build_url("camera user", "p@ss:/?x", "192.168.8.107", "554", "/stream1"),
                         "rtsp://camera%20user:p%40ss%3A%2F%3Fx@192.168.8.107:554/stream1")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ffmpeg = root / "ffmpeg"
            args_file = root / "args"
            ffmpeg.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ARGS_FILE\"\nexit \"${SMOKE_CODE:-0}\"\n")
            ffmpeg.chmod(0o755)
            payload = b"\0".join((b"camera", b"password", b"192.168.8.107", b"554", b"/stream1")) + b"\0"
            result = subprocess.run(["python3", str(REPO / "lib/frigate-rtsp-smoke.py"), str(ffmpeg)],
                                    input=payload, env=dict(os.environ, ARGS_FILE=str(args_file)),
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = args_file.read_text().splitlines()
            self.assertIn("rtsp://camera:password@192.168.8.107:554/stream1", args)
            self.assertEqual(args[-3:], ["-f", "null", "-"])
            self.assertEqual(set(root.iterdir()), {ffmpeg, args_file})

    def test_helper_rejects_incomplete_stdin_and_propagates_timeout_failure(self):
        short = subprocess.run(["python3", str(REPO / "lib/frigate-rtsp-smoke.py"), "/bin/true"],
                               input=b"short\0", capture_output=True)
        self.assertNotEqual(short.returncode, 0)
        self.assertIn(b"incomplete camera settings", short.stderr)


class CameraValidationScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin", "remote-tmp", "app"):
            (self.root / name).mkdir()
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib" / name)
        shutil.copy(REPO / "lib/frigate-rtsp-smoke.py", self.root / "lib/frigate-rtsp-smoke.py")
        defaults = (REPO / "config/defaults.conf").read_text()
        defaults = defaults.replace('FRIGATE_APP_DIR="/opt/frigate"',
                                    f'FRIGATE_APP_DIR="{self.root / "app"}"')
        (self.root / "config/defaults.conf").write_text(defaults)
        (self.root / "config/local.conf").write_text(
            'TAPO_C200_IP="192.168.8.107"\nTAPO_C200_USERNAME="camera user"\n'
            'TAPO_C200_PASSWORD="camera secret"\nFRIGATE_USERNAME="ha user"\n'
            'FRIGATE_PASSWORD="frigate secret"\n')
        shutil.copy(REPO / "scripts/step10h-frigate-camera-validation.sh",
                    self.root / "scripts/step10h-frigate-camera-validation.sh")
        self.config = self.root / "guest-config.yml"
        self.config.write_text("cameras:\n  tplink_c200_1:\n    host: 192.168.8.107\n")
        fake = r'''#!/bin/bash
printf '%s\n' "$*" >> "$PCT_CALLS"
case "$1" in
  status)
    [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
    [[ "$STATUS_STOPPED" != 1 ]] && echo 'status: running' || echo 'status: stopped' ;;
  exec)
    shift 3
    case "$1" in
      ip) echo '2: eth0 inet 192.0.2.20/24' ;;
      test) [[ "$2" == -f && -f "$TEST_CONFIG" ]] ;;
      grep)
        args=("${@:2}")
        for index in "${!args[@]}"; do
          [[ "${args[$index]}" != /opt/frigate/config/config.yml ]] || args[$index]="$TEST_CONFIG"
          if [[ "${args[$index]}" == /tmp/step10h-api.* ]]; then
            args[$index]="$REMOTE_TMP/${args[$index]#/tmp/}"
          fi
        done
        grep "${args[@]}" ;;
      docker)
        case "$2" in
          exec) echo 'preset-rtsp-generic'; echo 'preset-rtsp-generic' ;;
          ps) echo frigate ;;
          inspect)
            if [[ "$3" == --format ]]; then echo "$HEALTH"; else exit 0; fi ;;
          logs)
            [[ " ${*:2} " == *" --tail 1000 "* ]] || exit 8
            printf '%s\n' "$LOG_TEXT" ;;
          *) exit 0 ;;
        esac ;;
      bash)
        if [[ "$3" == *'command -v'* ]]; then
          [[ "$3" != *'command -v ffmpeg'* || -n "$5" ]] || echo "$FAKE_FFMPEG"
          exit 0
        fi
        [[ "$3" == *'docker compose config'* ]] && exit 0
        if [[ "$3" == *'python3 -c'* ]]; then
          /bin/bash -c "$3" "$4" "$5" "$6" "$7"
          exit $?
        fi
        exit 1 ;;
      python3)
        shift
        if [[ "$3" == /tmp/step10h-api.* ]]; then
          set -- "$1" "$2" "$REMOTE_TMP/${3#/tmp/}" "${@:4}"
        fi
        /usr/bin/python3 "$@" ;;
      mktemp)
        dir=$(mktemp -d "$REMOTE_TMP/step10h-api.XXXXXX") || exit 1
        echo "/tmp/$(basename "$dir")" ;;
      curl)
        args=("$@")
        output=""
        for ((i=0; i<${#args[@]}; i++)); do
          [[ "${args[$i]}" != -o ]] || output="${args[$((i+1))]}"
        done
        [[ "$output" != /tmp/step10h-api.* ]] || output="$REMOTE_TMP/${output#/tmp/}"
        if [[ "$API_CODE" == 200 && "$*" == *api/config* ]]; then
          printf '{"tplink_c200_1": {}}\n' > "$output"
        elif [[ "$API_CODE" == 200 && "$*" == *api/stats* ]]; then
          printf '{"cameras":{"tplink_c200_1":{"camera_fps":%s}}}\n' "$CAMERA_FPS" > "$output"
        else
          : > "$output"
        fi
        echo "$API_CODE" ;;
      rm)
        target="${@: -1}"
        [[ "$target" != /tmp/step10h-api.* ]] || target="$REMOTE_TMP/${target#/tmp/}"
        rm -rf -- "$target" ;;
      *) exit 1 ;;
    esac ;;
esac
'''
        pct = self.root / "bin/pct"
        pct.write_text(fake)
        pct.chmod(0o755)
        ffmpeg = self.root / "bin/ffmpeg"
        ffmpeg.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$FFMPEG_ARGS"
if [[ -n "$RTSP_FAIL_PATH" && "$*" == *"$RTSP_FAIL_PATH"* ]]; then exit 1; fi
exit 0
''')
        ffmpeg.chmod(0o755)
        curl = self.root / "bin/curl"
        curl.write_text(r'''#!/bin/bash
output=""; cookie=""
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -c) cookie="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$output" != /tmp/step10h-api.* ]] || output="$REMOTE_TMP/${output#/tmp/}"
[[ "$cookie" != /tmp/step10h-api.* ]] || cookie="$REMOTE_TMP/${cookie#/tmp/}"
: > "$output"
: > "$cookie"
printf '%s' "$API_CODE"
''')
        curl.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        TEST_CONFIG=str(self.config), FAKE_FFMPEG=str(ffmpeg),
                        REMOTE_TMP=str(self.root / "remote-tmp"),
                        PCT_CALLS=str(self.root / "pct-calls"), FFMPEG_ARGS=str(self.root / "ffmpeg-args"),
                        STATUS_FAIL="0", STATUS_STOPPED="0", HEALTH="healthy", API_CODE="200",
                        CAMERA_FPS="5.0",
                        RTSP_FAIL_PATH="", LOG_TEXT="", FRIGATE_CAMERA_LOG_LOOKBACK="1h")

    def run_script(self, *args, **extra):
        return subprocess.run(["bash", str(self.root / "scripts/step10h-frigate-camera-validation.sh"), *args],
                              env=dict(self.env, **extra), text=True, capture_output=True)

    def temp_dirs(self):
        return list((self.root / "remote-tmp").iterdir())

    def test_success_probes_both_streams_without_output_files_or_secret_logs(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Direct RTSP record stream is accessible", result.stdout)
        self.assertIn("Direct RTSP detect stream is accessible", result.stdout)
        self.assertIn("Frigate API reports camera tplink_c200_1", result.stdout)
        self.assertIn("Frigate camera reports live frame rate: 5.0 FPS", result.stdout)
        self.assertNotIn("camera secret", result.stdout + result.stderr)
        self.assertNotIn("frigate secret", result.stdout + result.stderr)
        pct_calls = (self.root / "pct-calls").read_text()
        self.assertNotIn("camera secret", pct_calls)
        self.assertNotIn("frigate secret", pct_calls)
        ffmpeg_args = (self.root / "ffmpeg-args").read_text()
        self.assertIn("rtsp://camera%20user:camera%20secret@192.168.8.107:554/stream1", ffmpeg_args)
        self.assertIn("-f null -", ffmpeg_args)
        self.assertEqual(self.temp_dirs(), [])

    def test_invalid_values_and_status_query_error_stop_early(self):
        invalid_lookback = self.run_script(FRIGATE_CAMERA_LOG_LOOKBACK="0h")
        self.assertNotEqual(invalid_lookback.returncode, 0)
        self.assertFalse((self.root / "pct-calls").exists())
        bad_name = self.run_script(TAPO_C200_NAME="camera-name")
        self.assertNotEqual(bad_name.returncode, 0)
        self.assertFalse((self.root / "pct-calls").exists())
        status_error = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(status_error.returncode, 0)
        self.assertIn("Could not query status", status_error.stdout)
        self.assertNotIn("is not running", status_error.stdout)
        bad_port = self.run_script(TAPO_CAMERA_RTSP_PORT="65536")
        self.assertNotEqual(bad_port.returncode, 0)
        self.assertIn("TAPO_CAMERA_RTSP_PORT must be an integer", bad_port.stdout)
        stopped = self.run_script(STATUS_STOPPED="1")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertIn("CT 200 is not running", stopped.stdout)
        self.assertNotIn("Could not query status", stopped.stdout)
        local_config = self.root / "config/local.conf"
        local_config.write_text(local_config.read_text().replace("192.168.8.107", "8.8.8.8"))
        bad_ip = self.run_script()
        self.assertNotEqual(bad_ip.returncode, 0)
        self.assertIn("private IPv4 address", bad_ip.stdout)
        self.assertEqual(self.temp_dirs(), [])

    def test_rtsp_log_and_api_failures_are_reported_and_temp_files_cleaned(self):
        rtsp_failure = self.run_script(RTSP_FAIL_PATH="/stream2")
        self.assertNotEqual(rtsp_failure.returncode, 0)
        self.assertIn("Direct RTSP detect stream test failed", rtsp_failure.stdout)
        self.assertEqual(self.temp_dirs(), [])
        recovered_log = self.run_script(LOG_TEXT="tplink_c200_1: no frames received")
        self.assertEqual(recovered_log.returncode, 0, recovered_log.stdout + recovered_log.stderr)
        self.assertIn("but Frigate is healthy", recovered_log.stdout)
        log_failure = self.run_script(LOG_TEXT="tplink_c200_1: no frames received", CAMERA_FPS="0")
        self.assertNotEqual(log_failure.returncode, 0)
        self.assertIn("camera-specific error messages", log_failure.stdout)
        api_unavailable = self.run_script(API_CODE="503")
        self.assertEqual(api_unavailable.returncode, 0)
        self.assertIn("Frigate API login returned HTTP 503", api_unavailable.stdout)
        self.assertEqual(self.temp_dirs(), [])


if __name__ == "__main__":
    unittest.main()
