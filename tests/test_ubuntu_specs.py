"""Regression checks; run python3 -m unittest discover -s tests -p 'test_ubuntu_specs.py'."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'ubuntu-specs.sh'
SOURCE = SCRIPT.read_text().split("<<'CAR_PYTHON'\n", 1)[1].split('\nCAR_PYTHON\n', 1)[0]
MOD = types.ModuleType('ubuntu_specs')
exec(compile(SOURCE, str(SCRIPT), 'exec'), MOD.__dict__)


def probe(props=None, protocol='Drive.Ata', status='detected'):
    p = MOD.Probe()
    objects = {
        '/block/sda': {MOD.UDISKS + 'Block': {
            'Device': list(b'/dev/sda\0'), 'Symlinks': [list(b'/dev/disk/by-id/test\0')], 'Drive': '/drive/test'}},
        '/drive/test': {MOD.UDISKS + protocol: props or {}}
    }
    p.udisks = Mock(return_value=(objects, status))
    p.run = Mock(return_value={'status': 'tool_unavailable', 'stdout': '', 'stderr': '', 'returncode': None})
    return p


def ata(**overrides):
    return dict(SmartSupported=True, SmartEnabled=True, SmartUpdated=1792070000,
                SmartFailing=False, SmartNumBadSectors=0, **overrides)


class SmartHealthTests(unittest.TestCase):
    def test_ata_pass_uses_base_service_without_smartctl(self):
        p = probe(ata())
        health, raw = MOD.smart_health(p, '/dev/sda')
        self.assertEqual(health['value'], 'SMART reports PASS')
        self.assertIn('snapshot', health['detail'])
        self.assertIn('udisks', raw)
        p.run.assert_not_called()

    def test_device_alias(self):
        health, _ = MOD.smart_health(probe(ata()), '/dev/disk/by-id/test')
        self.assertEqual(health['value'], 'SMART reports PASS')

    def test_ata_failure(self):
        props = ata()
        props['SmartFailing'] = True
        self.assertEqual(MOD.smart_health(probe(props), '/dev/sda')[0]['value'], 'SMART FAIL')

    def test_warnings_prevent_clean_pass(self):
        for key in ['SmartNumBadSectors', 'SmartNumAttributesFailing', 'SmartNumAttributesFailedInThePast']:
            with self.subTest(key=key):
                props = ata()
                props[key] = 3
                health, _ = MOD.smart_health(probe(props), '/dev/sda')
                self.assertIn('SMART WARNING', health['value'])
        props = ata(SmartSelftestStatus='error_read')
        self.assertIn('SMART WARNING', MOD.smart_health(probe(props), '/dev/sda')[0]['value'])

    def test_uncollected_disabled_unsupported_and_missing_never_pass(self):
        for key, value in [('SmartUpdated', 0), ('SmartSupported', False), ('SmartEnabled', False), ('SmartFailing', None)]:
            with self.subTest(key=key):
                props = ata()
                props[key] = value
                health, _ = MOD.smart_health(probe(props), '/dev/sda')
                self.assertIsNone(health['value'])
                self.assertIn('not verified', health['detail'])

    def test_nvme_no_critical_warnings(self):
        p = probe({'SmartUpdated': 1792070000, 'SmartCriticalWarning': []}, 'NVMe.Controller')
        health, _ = MOD.smart_health(p, '/dev/sda')
        self.assertEqual(health['value'], 'NVMe reports no critical warnings')
        p.run.assert_not_called()

    def test_nvme_warnings(self):
        p = probe({'SmartUpdated': 1792070000, 'SmartCriticalWarning': ['spare', 'degraded']}, 'NVMe.Controller')
        self.assertIn('spare, degraded', MOD.smart_health(p, '/dev/sda')[0]['value'])

    def test_nvme_missing_or_uncollected_is_unknown(self):
        for props in [{'SmartUpdated': 0, 'SmartCriticalWarning': []}, {'SmartUpdated': 1792070000}]:
            self.assertIsNone(MOD.smart_health(probe(props, 'NVMe.Controller'), '/dev/sda')[0]['value'])

    def test_nvme_previous_failed_test(self):
        props = {'SmartUpdated': 1792070000, 'SmartCriticalWarning': [], 'SmartSelftestStatus': 'known_seg_fail'}
        self.assertIn('WARNING', MOD.smart_health(probe(props, 'NVMe.Controller'), '/dev/sda')[0]['value'])

    def test_usb_raid_hidden_health(self):
        self.assertIsNone(MOD.smart_health(probe({}, 'Drive'), '/dev/sda')[0]['value'])
        self.assertIsNone(MOD.smart_health(probe(ata()), '/dev/sdb')[0]['value'])

    def test_smartctl_optional_fallback_and_bitmask(self):
        for exit_status, expected in [(0, 'PASS (not'), (8, 'FAIL'), (64, 'warnings'), (2, 'incomplete')]:
            p = probe(status='tool_unavailable')
            p.run.return_value = {'status': 'detected' if exit_status == 0 else 'unknown',
                                  'stdout': json.dumps({'smart_status': {'passed': True}, 'smartctl': {'exit_status': exit_status}}),
                                  'stderr': '', 'returncode': exit_status}
            self.assertIn(expected, MOD.smart_health(p, '/dev/sda')[0]['value'])

    def test_permission_denial_is_not_pass(self):
        p = probe(status='permission_required')
        health, _ = MOD.smart_health(p, '/dev/sda')
        self.assertEqual(health['status'], 'permission_required')
        self.assertIsNone(health['value'])

    def test_real_gio_query_shape_is_read_only_and_cached(self):
        bus = Mock()
        bus.call_sync.return_value.unpack.return_value = ({'/drive/test': {}},)
        gio = types.SimpleNamespace(bus_get_sync=Mock(return_value=bus),
                                    BusType=types.SimpleNamespace(SYSTEM=1), DBusCallFlags=types.SimpleNamespace(NONE=0))
        gi = types.ModuleType('gi')
        gi.require_version = Mock()
        repository = types.ModuleType('gi.repository')
        repository.Gio = gio
        with patch.dict('sys.modules', {'gi': gi, 'gi.repository': repository}):
            p = MOD.Probe()
            self.assertEqual(p.udisks(), ({'/drive/test': {}}, 'detected'))
            self.assertEqual(p.udisks()[1], 'detected')
        bus.call_sync.assert_called_once_with('org.freedesktop.UDisks2', '/org/freedesktop/UDisks2',
                'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects', None, None, 0, 5000, None)

    def test_storage_totals_exclude_live_media_and_partitions(self):
        disks = [
            {'name': 'sda', 'kname': 'sda', 'path': '/dev/sda', 'type': 'disk', 'size': 500000000000,
             'model': 'Test SSD', 'tran': 'sata', 'rota': False},
            {'name': 'sdb', 'kname': 'sdb', 'path': '/dev/sdb', 'type': 'disk', 'size': 16000000000,
             'tran': 'usb', 'children': [{'name': 'sdb1', 'type': 'part', 'size': 16000000000, 'mountpoints': ['/cdrom']}]}
        ]
        p = probe(ata())
        original = p.run
        p.run = lambda args, **kwargs: {'stdout': json.dumps({'blockdevices': disks}), 'status': 'detected'} if args[0] == 'lsblk' else original(args, **kwargs)
        data, _, _ = MOD.storage_data(p, [])
        self.assertEqual(data['count'], 1)
        self.assertEqual(data['bytes'], 500000000000)
        self.assertEqual(len(data['disks']), 2)


class LaunchTests(unittest.TestCase):
    def test_desktop_quoting_roundtrip(self):
        for value in ['/media/ubuntu/NO NAME 1/ubuntu-specs.sh', '/tmp/a"b$c`d\\e%f.sh']:
            escaped = MOD.desktop_quote(value)
            # Decode desktop-string escapes, then Exec argument escapes/field codes.
            decoded = escaped.replace('\\\\', '\\')
            self.assertEqual(re.sub(r'\\(.)', r'\1', decoded[1:-1]).replace('%%', '%'), value)

    def test_launcher_install_on_path_with_spaces_via_shell(self):
        with tempfile.TemporaryDirectory(prefix='ubuntu specs ') as tmp:
            home = Path(tmp)
            bindir = home / 'bin'
            bindir.mkdir()
            for name, content in {
                'uname': '#!/bin/sh\necho Linux\n',
                'gnome-terminal': '#!/bin/sh\nexit 0\n',
                'xdg-user-dir': '#!/bin/sh\nprintf "%s/Desktop\\n" "$HOME"\n',
                'gio': '#!/bin/sh\nexit 0\n',
                'sudo': '#!/bin/sh\necho "sudo should not be called" >&2\nexit 99\n'
            }.items():
                executable = bindir/name
                executable.write_text(content)
                executable.chmod(0o755)
            script = home/'USB drive'/'ubuntu-specs.sh'
            script.parent.mkdir()
            script.write_text(SCRIPT.read_text())
            env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home/'data'), PATH=str(bindir)+':/usr/bin:/bin')
            result = subprocess.run(['/bin/bash', str(script), '--install-launcher'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('sudo should', result.stderr)
            desktop = home/'Desktop'/'Ubuntu Specs.desktop'
            self.assertTrue(desktop.stat().st_mode & 0o111)
            entry = desktop.read_text()
            self.assertIn(MOD.desktop_quote(script.resolve()), entry)
            self.assertIn('--wait', entry)
            self.assertEqual(entry, (home/'data/applications/ctrl-alt-recycle-ubuntu-specs.desktop').read_text())

    def test_help_does_not_prompt_for_sudo(self):
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp)
            uname = bindir/'uname'
            uname.write_text('#!/bin/sh\necho Linux\n')
            uname.chmod(0o755)
            result = subprocess.run(['/bin/bash', str(SCRIPT), '--help'], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=str(bindir)+':/usr/bin:/bin'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--install-launcher', result.stdout)
            self.assertNotIn('password', result.stdout.split('usage:')[0])

    def test_report_generation_without_hardware(self):
        p = MOD.Probe()
        p.run = Mock(return_value={'status': 'tool_unavailable', 'stdout': '', 'stderr': '', 'returncode': None})
        p.read = lambda path: MOD.field(source=str(path))
        with patch.object(MOD.Path, 'glob', return_value=[]), patch.object(MOD.Path, 'exists', return_value=False):
            data = MOD.collect(p)
        data['hostname'] = '<test-host>'
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp)/'input.json'
            fixture.write_text(json.dumps(data))
            outdir = Path(tmp)/'Reports'
            args = ['ubuntu-specs.sh', '--script-path', str(SCRIPT), '--render-json', str(fixture), '--output-dir', str(outdir)]
            with patch.object(MOD.sys, 'argv', args), patch.object(MOD.os, 'geteuid', return_value=1000), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(MOD.main(), 0)
            reports = list(outdir.glob('*.html'))
            self.assertEqual(len(reports), 1)
            self.assertEqual(len(list(outdir.glob('*.json'))), 1)
            rendered = reports[0].read_text()
            self.assertIn('&lt;test-host&gt;', rendered)
            self.assertIn('Save JSON', rendered)
            self.assertNotIn('SMART reports PASS', rendered)


if __name__ == '__main__':
    unittest.main()
