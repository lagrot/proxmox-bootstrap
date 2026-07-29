#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${TEST_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

UPDATER="${TEST_SCRIPT_DIR}/step20-update-ct.sh"
errors=0
TEST_STATE_DIR=""

cleanup() {
  [[ -n "${TEST_STATE_DIR}" ]] && rm -rf -- "${TEST_STATE_DIR}"
}
trap cleanup EXIT

pass() {
  log_info "PASS: $1"
}

fail_test() {
  log_error "FAIL: $1"
  ((errors+=1))
}

expect_success() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "${label}"
  else
    fail_test "${label}"
  fi
}

expect_failure() {
  local label="$1" pattern="$2" output rc
  shift 2
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  if (( rc != 0 )) && grep -qiE "${pattern}" <<<"${output}"; then
    pass "${label}"
  else
    fail_test "${label} (exit=${rc})"
  fi
}

write_test_state() {
  local result="$1" created_epoch="$2" snapshot="${3:-pbsec-test-ct210}"
  mkdir -p "${TEST_STATE_DIR}"
  printf 'target=ct210\nct_id=210\nsnapshot=%s\ncreated_epoch=%s\ncreated_at=test\nresult=%s\nstage=test\n' \
    "${snapshot}" "${created_epoch}" "${result}" >"${TEST_STATE_DIR}/ct210.state"
}

[[ "${EUID}" -eq 0 ]] || die "Run as root"
TEST_STATE_DIR="$(mktemp -d /tmp/step20-update-ct-tests.XXXXXX)"

expect_success "Updater Bash syntax" bash -n "${UPDATER}"
expect_success "Setup Bash syntax" bash -n "${TEST_SCRIPT_DIR}/step20f-unattended-upgrades.sh"
expect_success "Validation Bash syntax" bash -n "${TEST_SCRIPT_DIR}/step20g-unattended-upgrades-validation.sh"
expect_success "Status Bash syntax" bash -n "${TEST_SCRIPT_DIR}/step20-status.sh"
expect_success "CT 200 restore-test Bash syntax" \
  bash -n "${TEST_SCRIPT_DIR}/step20i-ct200-restore-test.sh"
expect_success "Status reports managed snapshot observation state" \
  grep -q 'SNAPSHOT RETAINED' "${TEST_SCRIPT_DIR}/step20-status.sh"
expect_success "Status reports managed snapshot cleanup state" \
  grep -q 'CLEANUP DUE' "${TEST_SCRIPT_DIR}/step20-status.sh"
expect_success "Help command" bash "${UPDATER}" --help
expect_success "Updater uses a collision-safe script directory variable" \
  grep -q '^STEP20_UPDATE_SCRIPT_DIR=' "${UPDATER}"
expect_success "Preview uses Debian's security-only engine" \
  grep -q 'unattended-upgrade --dry-run --verbose' "${UPDATER}"
expect_success "No-update discovery precedes the full service baseline" \
  awk '
    /^pct status .*CT_ID/ { main = 1 }
    main && /apt-get update/ && !refresh { refresh = NR }
    main && /^security_plan$/ && !plan { plan = NR }
    main && /SECURITY_COUNT == 0/ && !empty { empty = NR }
    main && /^run_baseline$/ && !baseline { baseline = NR }
    END {
      exit !(refresh && plan > refresh && empty > plan && baseline > empty)
    }
  ' "${UPDATER}"
expect_success "No-update result uses rollback-neutral wording" \
  grep -Fq 'no rollback protection or service change is needed' "${UPDATER}"
expect_success "Updater restores the metadata timer on exit" \
  grep -Fq 'systemctl start apt-daily.timer' "${UPDATER}"
expect_success "Failure restart waits before in-guest timer restoration" \
  grep -Fq 'pct start "${CT_ID}" >/dev/null 2>&1 && wait_running' "${UPDATER}"
expect_success "Snapshot preflight checks the CT feature API" \
  grep -Fq -- '--feature snapshot --output-format json' "${UPDATER}"
expect_success "CT 200 uses stopped full-rootfs backup protection" \
  grep -Fq 'vzdump "${CT_ID}" --mode stop --compress zstd' "${UPDATER}"
expect_success "CT 200 backup preserves media bind-mount configuration" \
  grep -Fq 'Rollback archive does not preserve the CT ${CT_ID} media bind mount' \
    "${UPDATER}"
expect_success "CT 200 restore drill never starts its temporary CT" \
  grep -Fq -- '--unique 1 --start 0 --onboot 0' \
    "${TEST_SCRIPT_DIR}/step20i-ct200-restore-test.sh"
expect_success "CT 200 restore drill rejects a VM ID collision" \
  grep -Fq 'qm status "${RESTORE_CT_ID}"' \
    "${TEST_SCRIPT_DIR}/step20i-ct200-restore-test.sh"
expect_success "Status reports CT 200 full-backup protection" \
  grep -Fq 'READY | stopped full-backup rollback' \
    "${TEST_SCRIPT_DIR}/step20-status.sh"
expect_success "Policy validation checks that the metadata timer is active" \
  grep -Fq 'apt-daily timer active' \
    "${TEST_SCRIPT_DIR}/step20g-unattended-upgrades-validation.sh"

expect_failure "Missing target and mode rejected" 'Target and mode are required' \
  bash "${UPDATER}"
expect_failure "Literal CTID rejected" 'placeholder.*ct200' \
  bash "${UPDATER}" CTID --dry-run
expect_failure "Home Assistant VM rejected" 'Home Assistant OS.*not supported' \
  bash "${UPDATER}" vm100 --dry-run
expect_failure "Unknown target rejected" 'Unknown target' \
  bash "${UPDATER}" ct999 --dry-run
expect_failure "Unknown option rejected" 'Unknown option' \
  bash "${UPDATER}" ct210 --wrong
expect_failure "Conflicting modes rejected" 'Choose exactly one mode' \
  bash "${UPDATER}" ct210 --dry-run --confirm

expect_failure "Missing cleanup state rejected" 'No managed security-update snapshot' \
  env SECURITY_UPDATE_STATE_DIR="${TEST_STATE_DIR}" \
    bash "${UPDATER}" ct210 --cleanup

write_test_state success "$(date +%s)"
expect_failure "Cleanup before 24 hours rejected" 'wait 24 hours' \
  env SECURITY_UPDATE_STATE_DIR="${TEST_STATE_DIR}" \
    bash "${UPDATER}" ct210 --cleanup

write_test_state failed "$(( $(date +%s) - 90000 ))"
expect_failure "Failed update snapshot protected" 'failed updates require manual inspection' \
  env SECURITY_UPDATE_STATE_DIR="${TEST_STATE_DIR}" \
    bash "${UPDATER}" ct210 --cleanup

write_test_state success "$(( $(date +%s) - 90000 ))" unsafe-name
expect_failure "Unowned snapshot name protected" 'snapshot name is invalid' \
  env SECURITY_UPDATE_STATE_DIR="${TEST_STATE_DIR}" \
    bash "${UPDATER}" ct210 --cleanup

expect_failure "Concurrent update rejected" 'Another security-update operation' \
  bash -c "exec 7>/run/lock/proxmox-bootstrap-security-update.lock
    flock -n 7
    bash '${UPDATER}' ct210 --dry-run"

expect_success "Manual install policy configured in repository" \
  grep -Fq 'APT::Periodic::Unattended-Upgrade "0";' \
    "${PROJECT_ROOT}/config/20homelab-auto-upgrades"
expect_success "Automatic reboot disabled in repository" \
  grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' \
    "${PROJECT_ROOT}/config/52homelab-unattended-upgrades"
expect_success "Quick guide has exact dry-run command" \
  grep -Fq 'bash scripts/step20-update-ct.sh ct210 --dry-run' \
    "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "Quick guide has exact confirm command" \
  grep -Fq 'bash scripts/step20-update-ct.sh ct210 --confirm' \
    "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "Quick guide has exact cleanup command" \
  grep -Fq 'bash scripts/step20-update-ct.sh ct210 --cleanup' \
    "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "Quick guide documents explicit snapshot rollback" \
  grep -Fq 'pct rollback 210 EXACT_SNAPSHOT_NAME' \
    "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "Quick guide documents explicit CT 200 full-backup restore" \
  grep -Fq 'pct restore 200 CT200_BACKUP --force 1 --storage local-lvm' \
    "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "Quick guide excludes third-party Docker packages" \
  grep -Fq 'download.docker.com' "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "Quick guide explains native Debian Mosquitto scope" \
  grep -Fq 'Mosquitto is installed as a native Debian package' \
    "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "Quick guide excludes the Hermes application" \
  grep -Fq 'excludes the Hermes application' \
    "${PROJECT_ROOT}/UPDATE-QUICK-GUIDE.txt"
expect_success "README lists the controlled updater" \
  grep -Fq 'scripts/step20-update-ct.sh' "${PROJECT_ROOT}/README.md"
expect_success "Status prints an exact runnable update command" \
  grep -Fq 'bash scripts/step20-update-ct.sh ct200 --confirm' \
    "${PROJECT_ROOT}/scripts/step20-status.sh"
expect_success "Status explains that CT targets contain no space" \
  grep -Fq 'one token, with no space' \
    "${PROJECT_ROOT}/scripts/step20-status.sh"
expect_success "Audit uses the same Debian security engine as the updater" \
  grep -Fq 'unattended-upgrade --dry-run --verbose' \
    "${PROJECT_ROOT}/scripts/step20a-update-audit.sh"

(( errors == 0 )) || die "Security-update MVP tests failed with ${errors} error(s)"
log_info "Security-update MVP tests completed successfully"
