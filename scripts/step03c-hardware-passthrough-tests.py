#!/usr/bin/env python3
"""Isolated behavior tests for Step 03C; no Proxmox or host config is touched."""

import os
import pathlib
import subprocess
import tempfile

SCRIPT = pathlib.Path(__file__).with_name("step03c-hardware-passthrough.sh")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def fixture(status="running", status_fails=False, start_fails=False):
    root = pathlib.Path(tempfile.mkdtemp(prefix="step03c-test-"))
    bindir = root / "bin"
    bindir.mkdir()
    confdir, udevedir, sysctldir, dri = [root / x for x in ("lxc", "udev", "sysctl", "dri")]
    for path in (confdir, udevedir, sysctldir, dri):
        path.mkdir()
    (confdir / "200.conf").write_text("hostname: docker-core\n")
    (root / "ct-status").write_text(status)
    (root / "calls").write_text("")

    mocks = {
        "pct": r'''#!/bin/bash
echo "pct $*" >> "$TEST_CALLS"
case "$1" in
  config) exit 0 ;;
  status)
    if [[ "${STATUS_FAIL:-0}" == 1 ]]; then exit 1; fi
    printf 'status: %s\n' "$(cat "$CT_STATUS_FILE")" ;;
  stop) echo stopped > "$CT_STATUS_FILE" ;;
  start)
    if [[ "${START_FAIL:-0}" == 1 ]]; then exit 1; fi
    echo running > "$CT_STATUS_FILE" ;;
  exec)
    shift 2
    case "$*" in
      *"test -e /dev/dri/renderD128"*|*"test -d /dev/bus/usb"*) exit 0 ;;
      *"lsusb"*) echo 'Bus 001 Device 002: ID 18d1:9302 Google Inc.' ;;
      *"find /dev/bus/usb"*) echo /dev/bus/usb/001/002 ;;
      *) exit 0 ;;
    esac ;;
esac
''',
        "lspci": "#!/bin/sh\nprintf '%s\\n' '00:02.0 VGA compatible controller: Intel Corporation Graphics'\n",
        "lsusb": "#!/bin/sh\nprintf '%s\\n' 'Bus 001 Device 002: ID 18d1:9302 Google Inc.'\n",
        "udevadm": "#!/bin/sh\necho \"udevadm $*\" >> \"$TEST_CALLS\"\n",
        "sysctl": "#!/bin/bash\necho \"sysctl $*\" >> \"$TEST_CALLS\"\nif [[ \"$1\" == -n ]]; then echo 0; fi\n",
        "sleep": "#!/bin/sh\nexit 0\n",
    }
    for name, content in mocks.items():
        path = bindir / name
        path.write_text(content)
        path.chmod(0o755)
    env = os.environ.copy()
    env.update({
        "PATH": f"{bindir}:/usr/bin:/bin",
        "TEST_CALLS": str(root / "calls"),
        "CT_STATUS_FILE": str(root / "ct-status"),
        "PROXMOX_LXC_CONFIG_DIR": str(confdir),
        "FRIGATE_UDEV_RULE_DIR": str(udevedir),
        "FRIGATE_SYSCTL_CONFIG_DIR": str(sysctldir),
        "FRIGATE_DRI_DIR": str(dri),
        "STATUS_FAIL": "1" if status_fails else "0",
        "START_FAIL": "1" if start_fails else "0",
        "LOG_FILE": "/dev/null",
    })
    return root, env


def run(args, status="running", status_fails=False, start_fails=False):
    root, env = fixture(status, status_fails, start_fails)
    proc = subprocess.run(["bash", str(SCRIPT), *args], env=env, text=True, capture_output=True)
    return root, proc


def test_cli():
    for args in ([], ["--dry-run", "--apply"], ["--dry-run", "--confirm-restart"], ["--wat"]):
        proc = subprocess.run(["bash", str(SCRIPT), *args], text=True, capture_output=True)
        require(proc.returncode == 2, f"invalid CLI accepted: {args}")
    proc = subprocess.run(["bash", str(SCRIPT), "--help"], text=True, capture_output=True)
    require(proc.returncode == 0 and "--confirm-restart" in proc.stdout, "help failed")


def test_dry_run_is_read_only():
    root, proc = run(["--dry-run"])
    require(proc.returncode == 0, f"dry-run failed: {proc.stderr}")
    require("[DRY-RUN] Would add" in proc.stdout, "dry-run did not report planned changes")
    require((root / "lxc/200.conf").read_text() == "hostname: docker-core\n", "dry-run changed CT config")
    require(not list((root / "udev").iterdir()) and not list((root / "sysctl").iterdir()), "dry-run wrote host config")
    require((root / "calls").read_text() == "pct config 200\npct status 200\n", "dry-run called mutating command")


def test_apply_without_restart():
    root, proc = run(["--apply"])
    require(proc.returncode == 0, f"apply failed: {proc.stderr}")
    calls = (root / "calls").read_text()
    require("stop" not in calls and "start" not in calls, "apply restarted CT without consent")
    require("kernel.perf_event_paranoid=0" in (root / "sysctl/99-frigate-gpu-stats.conf").read_text(), "sysctl config absent")
    require("lxc.cgroup2.devices.allow: c 226:* rwm" in (root / "lxc/200.conf").read_text(), "CT config absent")


def test_explicit_restart_and_stopped_preservation():
    root, proc = run(["--apply", "--confirm-restart"])
    require(proc.returncode == 0, f"confirmed restart failed: {proc.stderr}")
    calls = (root / "calls").read_text()
    require("pct stop 200" in calls and "pct start 200" in calls, "explicit restart not performed")
    root, proc = run(["--apply", "--confirm-restart"], status="stopped")
    require(proc.returncode == 0, f"stopped CT apply failed: {proc.stderr}")
    calls = (root / "calls").read_text()
    require("stop" not in calls and "start" not in calls, "initially stopped CT was started")


def test_status_failure_prevents_changes():
    root, proc = run(["--apply"], status_fails=True)
    require(proc.returncode != 0, "status failure was accepted")
    require((root / "lxc/200.conf").read_text() == "hostname: docker-core\n", "changed CT config after status failure")
    require(not list((root / "udev").iterdir()) and not list((root / "sysctl").iterdir()), "changed host config after status failure")


def test_apply_is_idempotent():
    root, env = fixture()
    conf = root / "lxc/200.conf"
    conf.write_text("""hostname: docker-core
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
""")
    rules = root / "udev/99-frigate-gpu.rules"
    rules.write_text('SUBSYSTEM=="drm", KERNEL=="card0", MODE="0666"\nSUBSYSTEM=="drm", KERNEL=="renderD128", MODE="0666"\n')
    (root / "udev/99-coral-edgetpu.rules").write_text('SUBSYSTEM=="usb", ATTR{idVendor}=="1a6e", ATTR{idProduct}=="089a", MODE="0666"\nSUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="9302", MODE="0666"\n')
    (root / "sysctl/99-frigate-gpu-stats.conf").write_text("kernel.perf_event_paranoid=0\n")
    proc = subprocess.run(["bash", str(SCRIPT), "--apply"], env=env, text=True, capture_output=True)
    require(proc.returncode == 0, f"idempotent apply failed: {proc.stderr}")
    calls = (root / "calls").read_text()
    require("udevadm" not in calls, "unchanged rules unnecessarily reloaded udev")
    require("sysctl -w" not in calls, "unchanged sysctl unnecessarily rewritten")


def test_restart_failure_has_recovery_guidance():
    _, proc = run(["--apply", "--confirm-restart"], start_fails=True)
    require(proc.returncode != 0, "failed CT start was accepted")
    require("Recovery command: pct start 200" in proc.stdout, "restart failure omitted recovery command")


def main():
    tests = (test_cli, test_dry_run_is_read_only, test_apply_without_restart,
             test_explicit_restart_and_stopped_preservation, test_status_failure_prevents_changes,
             test_apply_is_idempotent, test_restart_failure_has_recovery_guidance)
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"Passed {len(tests)} isolated Step 03C tests")


if __name__ == "__main__":
    main()
