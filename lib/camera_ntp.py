#!/usr/bin/env python3
"""Small ONVIF NTP client; never logs authentication material or raw replies."""
import base64
import datetime as dt
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

SOAP = 'http://www.w3.org/2003/05/soap-envelope'
DEVICE = 'http://www.onvif.org/ver10/device/wsdl'
SCHEMA = 'http://www.onvif.org/ver10/schema'
SECURITY = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd'
UTILITY = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd'
STATE_ROOT = Path('/var/lib/proxmox-bootstrap/camera-ntp')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('Camera HTTP redirects are refused')


def text(root, name):
    node = root.find('.//{' + SCHEMA + '}' + name)
    if node is None or node.text is None:
        raise RuntimeError('Camera response is missing ' + name)
    return node.text


def ntp_settings(root):
    info = root.find('.//{' + DEVICE + '}NTPInformation')
    if info is None:
        raise RuntimeError('Missing ONVIF NTPInformation')
    manual = []
    for host in info.findall('{' + SCHEMA + '}NTPManual'):
        kind = text(host, 'Type')
        key = {'IPv4': 'IPv4Address', 'IPv6': 'IPv6Address', 'DNS': 'DNSname'}.get(kind)
        if key is None:
            raise RuntimeError('Unsupported saved NTP address type')
        manual.append({'type': kind, 'address': text(host, key)})
    dhcp = text(info, 'FromDHCP')
    if dhcp not in ('true', 'false', '1', '0'):
        raise RuntimeError('Invalid ONVIF FromDHCP value')
    return {'dhcp': dhcp in ('true', '1'), 'manual': manual}


def desired_settings(server):
    return {'dhcp': False, 'manual': [{'type': 'IPv4', 'address': server}]}


def ntp_client_requests(ip):
    result = subprocess.run(['chronyc', '-n', 'clients'], capture_output=True, text=True, check=True)
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == ip:
            return int(fields[1])
    return 0


def validate_sync(camera, ip, server, minimum_requests=1):
    settings = camera.settings()
    if settings not in (desired_settings(server), {'dhcp': True, 'manual': []}):
        raise RuntimeError('Camera reports an unexpected NTP configuration')
    if ntp_client_requests(ip) < minimum_requests:
        raise RuntimeError('Host Chrony has not observed the required camera NTP requests')
    camera.validate_clock(server)
    if settings != desired_settings(server):
        print('WARNING: ONVIF reports DHCP/default NTP; synchronization is verified from clock and host client traffic, not configuration readback')


def utc_time(root):
    utc = root.find('.//{' + SCHEMA + '}UTCDateTime')
    if utc is None:
        raise RuntimeError('Camera does not report UTC time')
    return dt.datetime(*(int(text(utc, k)) for k in
                         ('Year', 'Month', 'Day', 'Hour', 'Minute', 'Second')),
                       tzinfo=dt.timezone.utc)


class Camera:
    def __init__(self, ip, port, username, password):
        ipaddress.IPv4Address(ip)
        if not 1 <= int(port) <= 65535:
            raise ValueError('Invalid ONVIF port')
        self.url = f'http://{ip}:{int(port)}/onvif/device_service'
        self.username, self.password = username, password
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, action, children=()):
        envelope = ET.Element('{' + SOAP + '}Envelope')
        header = ET.SubElement(envelope, '{' + SOAP + '}Header')
        security = ET.SubElement(header, '{' + SECURITY + '}Security')
        token = ET.SubElement(security, '{' + SECURITY + '}UsernameToken')
        nonce = secrets.token_bytes(16)
        created = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + self.password.encode()).digest()).decode()
        ET.SubElement(token, '{' + SECURITY + '}Username').text = self.username
        ET.SubElement(token, '{' + SECURITY + '}Password', Type='http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest').text = digest
        ET.SubElement(token, '{' + SECURITY + '}Nonce', EncodingType='http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary').text = base64.b64encode(nonce).decode()
        ET.SubElement(token, '{' + UTILITY + '}Created').text = created
        operation = ET.SubElement(ET.SubElement(envelope, '{' + SOAP + '}Body'), '{' + DEVICE + '}' + action)
        operation.extend(children)
        request = urllib.request.Request(self.url, data=ET.tostring(envelope), headers={
            'Content-Type': f'application/soap+xml; charset=utf-8; action="{DEVICE}/{action}"'})
        try:
            with self.opener.open(request, timeout=10) as reply:
                raw = reply.read(262145)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f'{action} failed: HTTP {error.code}; credentials and reply withheld') from None
        if len(raw) > 262144:
            raise RuntimeError('Oversized camera response')
        root = ET.fromstring(raw)
        if root.find('.//{' + SOAP + '}Fault') is not None:
            raise RuntimeError(action + ' returned an ONVIF fault')
        if root.find('.//{' + DEVICE + '}' + action + 'Response') is None:
            raise RuntimeError('Unexpected response to ' + action)
        return root

    def settings(self):
        return ntp_settings(self.call('GetNTP'))

    def set_ntp(self, settings):
        dhcp = ET.Element('{' + DEVICE + '}FromDHCP')
        dhcp.text = 'true' if settings['dhcp'] else 'false'
        children = [dhcp]
        for host in settings['manual']:
            item = ET.Element('{' + DEVICE + '}NTPManual')
            ET.SubElement(item, '{' + SCHEMA + '}Type').text = host['type']
            key = {'IPv4': 'IPv4Address', 'IPv6': 'IPv6Address', 'DNS': 'DNSname'}[host['type']]
            ET.SubElement(item, '{' + SCHEMA + '}' + key).text = host['address']
            children.append(item)
        self.call('SetNTP', children)

    def inspect(self):
        root = self.call('GetSystemDateAndTime')
        return {'mode': text(root, 'DateTimeType'), 'utc': utc_time(root),
                'timezone': text(root, 'TZ'), 'daylight_savings': text(root, 'DaylightSavings')}

    def validate(self, server):
        if self.settings() != desired_settings(server):
            raise RuntimeError('Camera did not retain the requested NTP server')
        self.validate_clock(server)

    def validate_clock(self, server):
        status = self.inspect()
        offset = (status['utc'] - dt.datetime.now(dt.timezone.utc)).total_seconds()
        if status['mode'] != 'NTP' or abs(offset) > 5:
            raise RuntimeError(f'Camera is not synchronized: mode={status["mode"]}, offset={offset:.1f}s')
        print(f'Camera NTP server {server}; UTC offset {offset:.1f}s; timezone {status["timezone"]}')


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('--inspect', '--dry-run', '--apply', '--apply-reboot', '--validate', '--validate-sync', '--rollback') or sys.argv[2] not in ('c200', 'c320ws'):
        raise ValueError('Use scripts/step21d-camera-ntp.sh')
    mode, profile, server = sys.argv[1:]
    if not ipaddress.IPv4Address(server).is_private:
        raise ValueError('NTP server must be a private IPv4 address')
    prefix = 'TAPO_C200' if profile == 'c200' else 'TAPO_C320WS'
    def setting(name):
        return os.environ.get(prefix + '_' + name) or (os.environ.get('TAPO_CAMERA_' + name, '') if profile == 'c200' else '')
    ip, username, password = (setting(k) for k in ('IP', 'USERNAME', 'PASSWORD'))
    if not all((ip, username, password)):
        raise RuntimeError('Camera address or credentials are missing')
    camera = Camera(ip, os.environ.get('TAPO_CAMERA_ONVIF_PORT', '2020'), username, password)
    before, status = camera.settings(), camera.inspect()
    print(f'{profile} {ip}: NTP={json.dumps(before)}, mode={status["mode"]}, UTC={status["utc"].isoformat()}, timezone={status["timezone"]}, DST={status["daylight_savings"]}')
    if mode == '--inspect':
        return
    if mode == '--dry-run':
        print(f'Would set manual NTP server {server}, preserving timezone and DST. No camera changes made.')
        return
    if mode == '--validate':
        camera.validate(server)
        return
    if mode == '--validate-sync':
        validate_sync(camera, ip, server)
        return
    state_path = STATE_ROOT / (profile + '.json')
    if mode == '--rollback':
        saved = json.loads(state_path.read_text())
        if saved['ip'] != ip:
            raise RuntimeError('Saved camera IP does not match')
        camera.set_ntp(saved['ntp'])
        if camera.settings() != saved['ntp']:
            raise RuntimeError('Camera NTP rollback readback failed')
        print('Previous NTP configuration restored; saved state retained')
        return
    if mode == '--apply-reboot':
        try:
            # Repeated apply must not reboot a camera already proven synchronized.
            validate_sync(camera, ip, server)
        except RuntimeError:
            pass
        else:
            print('Already synchronized with host client evidence; no changes or reboot needed')
            return
    elif before == desired_settings(server):
        camera.validate(server)
        print('Already configured; no camera changes made')
        return
    if status['mode'] != 'NTP':
        raise RuntimeError('Camera must already be in NTP mode; refusing to change clock mode implicitly')
    saved_state = {'ip': ip, 'ntp': before}
    if state_path.exists():
        saved = json.loads(state_path.read_text())
        if saved != saved_state and not (before == desired_settings(server) and saved.get('ip') == ip and 'ntp' in saved):
            raise RuntimeError('Prior rollback state differs; inspect it before another change')
    else:
        state_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(state_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(saved_state, stream)
            stream.flush()
            os.fsync(stream.fileno())
    try:
        prior_requests = ntp_client_requests(ip) if mode == '--apply-reboot' else 0
        camera.set_ntp(desired_settings(server))
        if mode == '--apply-reboot':
            if camera.settings() != desired_settings(server):
                raise RuntimeError('NTP server readback failed before reboot')
            print(f'Rebooting {profile} once; waiting for ONVIF and clock synchronization')
            try:
                camera.call('SystemReboot')
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                print('Reboot request connection closed; waiting without resending')
            time.sleep(10)
        attempts = 35 if mode == '--apply-reboot' else 12
        for attempt in range(attempts + 1):
            try:
                if mode == '--apply-reboot':
                    validate_sync(camera, ip, server, prior_requests + 1)
                else:
                    camera.validate(server)
                if mode == '--apply-reboot':
                    print('Camera clock and new host NTP traffic verified; rollback state retained')
                else:
                    print('Camera NTP configuration and current clock verified; use --validate-sync for host traffic evidence')
                return
            except (RuntimeError, urllib.error.URLError, TimeoutError, ConnectionError):
                if attempt == attempts:
                    raise
                time.sleep(5)
    except Exception:
        try:
            camera.set_ntp(before)
            if camera.settings() != before:
                raise RuntimeError('Rollback readback mismatch')
            print('Previous camera NTP settings restored after failure', file=sys.stderr)
        except Exception:
            print('Automatic camera rollback failed; use saved state and inspect camera locally', file=sys.stderr)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never print a URL, credential-bearing request, or raw camera response.
        if isinstance(error, (RuntimeError, ValueError)):
            print('ERROR: ' + str(error), file=sys.stderr)
        else:
            print('ERROR: ' + type(error).__name__ + '; request details withheld', file=sys.stderr)
        sys.exit(1)
