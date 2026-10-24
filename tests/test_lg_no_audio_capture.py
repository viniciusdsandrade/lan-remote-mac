"""Prova que o cliente LG deste repositório não captura microfone nem envia áudio.

O teste chama o cliente que está no repositório (`LGNetCastTV.send_key` e
`query`) com a rede substituída, e lê o binário entregue em
`Controle Remoto LG.app`. Não fala com a TV e não abre microfone.
"""

import re
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import lg_roap_control as lg  # noqa: E402


CLIENT_FILES = (
    "lg_roap_control.py",
    "lg_remote_gui.py",
    "mac_app/LGTVClient.swift",
    "mac_app/LGTVDiscovery.swift",
    "mac_app/AppMain.swift",
    "mac_app/ScreenText.swift",
    "mac_app/Info.plist",
    "Controle Remoto LG.app/Contents/Info.plist",
)

BINARIES = (
    "Controle Remoto LG.app/Contents/MacOS/Controle Remoto LG",
    "mac_app/Controle Remoto LG",
)

# APIs que abririam o microfone ou um fluxo de voz. Nome de tecla e OCR não entram.
CAPTURE_APIS = (
    "NSMicrophoneUsageDescription",
    "AVAudioSession",
    "AVAudioRecorder",
    "AVAudioEngine",
    "AVCaptureDevice",
    "AVCaptureSession",
    "SFSpeechRecognizer",
    "requestRecordPermission",
    "getUserMedia",
    "pyaudio",
    "sounddevice",
    "import AVFoundation",
    "import Speech",
)

FORCE_LOAD = re.compile(
    r"__swift_FORCE_LOAD_\$_swift(AVFoundation|CoreAudio|CoreMIDI)(_\$_main)?$"
)


def _read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def _event_names() -> list[str]:
    text = _read("PROTOCOLO.md")
    block = re.search(r'type="event">(.*?)</api>', text, re.S)
    if block is None:
        raise AssertionError("PROTOCOLO.md não tem o bloco api type=event")
    return re.findall(r"<name>([^<]+)</name>", block.group(1))


class LgNoAudioCaptureTest(unittest.TestCase):
    def test_record_and_every_other_key_are_handle_key_input(self):
        record = lg.resolve_key("record")
        self.assertIsInstance(record, int)
        self.assertEqual(record, lg.KEYS["record"])
        described = lg.resolve_key("audio_description")
        self.assertIsInstance(described, int)

        for protocol in ("roap", "udap"):
            tv = lg.LGNetCastTV(
                "192.0.2.100", protocol=protocol, session="sess", pairing_key="000000"
            )
            record_xml = tv._command_xml(record)
            self.assertIn("HandleKeyInput", record_xml)
            self.assertIn(f"<value>{record}</value>", record_xml)
            for code in lg.KEYS.values():
                xml = tv._command_xml(code)
                root = ET.fromstring(xml)
                if protocol == "udap":
                    api = root.find("api")
                    self.assertIsNotNone(api)
                    self.assertEqual(api.get("type"), "command")
                    names = [el.text for el in api.findall("name")]
                    values = [el.text for el in api.findall("value")]
                else:
                    names = [root.findtext("type")]
                    values = [root.findtext("value")]
                self.assertEqual(names, ["HandleKeyInput"])
                self.assertEqual(values, [str(code)])
                for api_name in CAPTURE_APIS:
                    self.assertNotIn(api_name, xml)

    def test_queries_are_empty_gets_and_record_is_a_key_post(self):
        calls = []

        def fake(method, url, body=None, headers=None, timeout=0, debug=False):
            calls.append((method, url, body or ""))
            sample = (
                '<?xml version="1.0" encoding="utf-8"?>'
                "<envelope><data><level>1</level><mute>false</mute></data></envelope>"
            )
            return lg.HttpResponse(200, sample, {})

        original = lg.http_request
        lg.http_request = fake
        try:
            tv = lg.LGNetCastTV(
                "192.0.2.100", protocol="roap", session="sess", pairing_key="000000"
            )
            for target in lg.QUERIES:
                calls.clear()
                parsed = tv.query(target)
                self.assertEqual(parsed.get("level"), "1")
                self.assertEqual(len(calls), 1)
                method, url, body = calls[0]
                self.assertEqual(method, "GET")
                self.assertIn("/api/data?", url)
                self.assertIn("target=" + target, url)
                self.assertEqual(body, "")
                for api_name in CAPTURE_APIS:
                    self.assertNotIn(api_name, url)

            calls.clear()
            code = lg.resolve_key("record")
            tv.send_key(code)
            self.assertEqual(len(calls), 1)
            method, url, body = calls[0]
            self.assertEqual(method, "POST")
            self.assertIn("/roap/api/command", url)
            self.assertIn("HandleKeyInput", body)
            self.assertIn(f"<value>{code}</value>", body)
            for api_name in CAPTURE_APIS:
                self.assertNotIn(api_name, body)
        finally:
            lg.http_request = original

    def test_idle_poll_and_advertised_events_do_not_forward_audio(self):
        events = _event_names()
        self.assertCountEqual(
            events,
            ["CursorVisible", "ChannelChanged", "CallStateChanged", "DragMode", "3DMode"],
        )
        for rel in CLIENT_FILES:
            text = _read(rel)
            for event in events:
                self.assertNotIn(event, text, f"{event} apareceu em {rel}")
            for api_name in CAPTURE_APIS:
                self.assertNotIn(api_name, text, f"{api_name} apareceu em {rel}")

        gui = _read("lg_remote_gui.py")
        self.assertIn("self.root.after(10000, self._poll_task)", gui)
        gui_targets = re.findall(r'query\("([^"]+)"\)', gui)
        self.assertCountEqual(gui_targets, ["volume_info", "cur_channel"])

        swift = _read("mac_app/LGTVClient.swift")
        self.assertIn("withTimeInterval: 10.0", swift)
        swift_targets = set(re.findall(r"target=([A-Za-z0-9_]+)", swift))
        self.assertEqual(swift_targets, {"screen_image", "volume_info", "cur_channel"})

        remote = _read("lg_roap_control.py")
        status_targets = re.findall(
            r'self\.tv\.query\("([^"]+)"\)',
            remote[remote.index("def _status"): remote.index("def cmd_remote")],
        )
        self.assertCountEqual(status_targets, ["volume_info", "cur_channel"])

    def test_shipped_binary_has_no_capture_symbols(self):
        for rel in BINARIES:
            path = ROOT / rel
            self.assertTrue(path.is_file(), rel)
            strings = subprocess.check_output(
                ["strings", "-a", str(path)], text=True, errors="replace"
            )
            self.assertIn("HandleKeyInput", strings)
            self.assertIn("?target=volume_info&session=", strings)
            self.assertIn("?target=cur_channel&session=", strings)
            self.assertIn("?target=screen_image&session=", strings)
            for api_name in CAPTURE_APIS:
                self.assertNotIn(api_name, strings, f"{api_name} em {rel}")
            for event in _event_names():
                self.assertNotIn(event, strings, f"{event} em {rel}")

            undefined = subprocess.check_output(
                ["nm", "-u", str(path)], text=True, errors="replace"
            )
            audio_lines = [
                line.strip()
                for line in undefined.splitlines()
                if re.search(r"Audio|AVFoundation|AVCapture|Speech|Microphone|MIDI", line)
            ]
            self.assertTrue(audio_lines, f"nm -u não leu símbolos de {rel}")
            for line in audio_lines:
                self.assertRegex(line, FORCE_LOAD, f"símbolo de áudio inesperado em {rel}: {line}")


if __name__ == "__main__":
    unittest.main()
