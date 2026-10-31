"""Prova que a redescoberta automática da TV não faz busca UDAP.

Toda resposta da LG NetCast a uma busca UDAP (`udap:rootservice`, por M-SEARCH ou B-SEARCH) põe
na tela o pop-up de descoberta: "modelo_XX", um celular apontando para a TV e o campo "Pairing
Key" (spec UDAP 2.0, figura "Host screen after discovery response"). A redescoberta roda sozinha
a cada falha, então só pode usar a busca DLNA. O teste roda a do CLI com a rede substituída e lê
as fontes do app. Não fala com a TV.
"""

import re
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import lg_roap_control as lg  # noqa: E402

TV_IP = "192.0.2.50"
TV_MAC = "02:00:5e:00:00:01"
DLNA_REPLY = (
    "HTTP/1.1 200 OK\r\n"
    "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"
    f"LOCATION: http://{TV_IP}:1234/description.xml\r\n"
    "SERVER: Linux/i686 UPnP/1.0 DLNADOC/1.50 Platinum/1.0.3.0\r\n\r\n"
)
UPNP_DESCRIPTION = (
    "<root><device><manufacturer>LG Electronics</manufacturer>"
    "<friendlyName>[TV][LG]xxLN5700-SA</friendlyName><modelName>xxLN5700-SA</modelName>"
    "</device></root>"
)


def _read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


class _FakeSocket:
    """Socket UDP que registra o que seria enviado e entrega as respostas preparadas."""

    def __init__(self, sent, replies):
        self.sent = sent
        self.replies = replies

    def setsockopt(self, *args):
        pass

    def bind(self, address):
        pass

    def setblocking(self, flag):
        pass

    def sendto(self, data, address):
        self.sent.append(data.decode())

    def recvfrom(self, size):
        return self.replies.pop(0)

    def close(self):
        pass


class LgDiscoveryWithoutPopupTest(unittest.TestCase):
    def setUp(self):
        self.datagrams = []
        self.replies = []
        self.requests = []
        self.arp_table = ""
        self.saved = (lg.socket.socket, lg.select.select, lg.http_request, lg.scan_subnet,
                      lg.subprocess.run)

        def fake_select(readable, writable, failed, timeout=None):
            sock = readable[0]
            if sock.sent and sock.replies:
                return readable, [], []
            time.sleep(min(timeout or 0, 0.02))
            return [], [], []

        def fake_http(method, url, body=None, headers=None, timeout=0, debug=False):
            self.requests.append((url, dict(headers or {})))
            if url.endswith("/description.xml"):
                return lg.HttpResponse(200, UPNP_DESCRIPTION, {})
            if "/roap/api/data" in url:
                return lg.HttpResponse(401, "", {})
            return lg.HttpResponse(404, "", {})

        def fake_run(args, **kwargs):
            if args[:2] == ["arp", "-an"]:
                out = self.arp_table
            elif args[:2] == ["arp", "-n"] and args[2] == TV_IP:
                out = f"? ({TV_IP}) at 2:0:5e:0:0:1 on en0 ifscope [ethernet]\n"
            elif args[:2] == ["arp", "-n"]:
                out = ""
            else:
                raise AssertionError(f"comando inesperado: {args}")
            return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")

        lg.socket.socket = lambda *args, **kwargs: _FakeSocket(self.datagrams, self.replies)
        lg.select.select = fake_select
        lg.http_request = fake_http
        lg.scan_subnet = lambda **kwargs: []
        lg.subprocess.run = fake_run

    def tearDown(self):
        (lg.socket.socket, lg.select.select, lg.http_request, lg.scan_subnet,
         lg.subprocess.run) = self.saved

    def assertNothingUdap(self):
        for datagram in self.datagrams:
            self.assertNotIn("udap", datagram.lower())
            self.assertNotIn("B-SEARCH", datagram)
            self.assertNotIn("ssdp:all", datagram)
        for url, headers in self.requests:
            self.assertNotIn("/udap/", url)
            self.assertNotIn("UDAP/2.0", headers.get("User-Agent", ""))

    def test_relocation_through_arp_does_not_speak_udap(self):
        self.arp_table = f"? ({TV_IP}) at 2:0:5e:0:0:1 on en0 ifscope [ethernet]\n"
        found = lg.auto_locate_tv({"mac": TV_MAC, "host": "192.0.2.10"}, timeout=0.2)
        self.assertEqual(found["ip"], TV_IP)
        self.assertEqual(self.datagrams, [])
        self.assertNothingUdap()

    def test_relocation_searches_only_the_dlna_renderer(self):
        self.replies.append((DLNA_REPLY.encode(), (TV_IP, 1900)))
        found = lg.auto_locate_tv({"mac": TV_MAC, "host": "192.0.2.10"}, timeout=0.2)
        self.assertEqual(found["ip"], TV_IP)
        self.assertEqual(len(self.datagrams), 1)
        self.assertIn("ST: urn:schemas-upnp-org:device:MediaRenderer:1", self.datagrams[0])
        self.assertNothingUdap()

    def test_explicit_discover_keeps_the_udap_search(self):
        lg.discover(timeout=0.2)
        sent = "\n".join(self.datagrams)
        self.assertIn("ST: udap:rootservice", sent)
        self.assertIn("B-SEARCH", sent)

    def test_app_searches_through_dlna_unless_the_user_asks(self):
        discovery = _read("mac_app/LGTVDiscovery.swift")
        literal = re.search(r'static let dlnaSearch = "((?:[^"\\]|\\.)*)"', discovery)
        self.assertIsNotNone(literal, "dlnaSearch sumiu de LGTVDiscovery.swift")
        self.assertIn("ST: urn:schemas-upnp-org:device:MediaRenderer:1", literal.group(1))
        self.assertNotIn("udap", literal.group(1).lower())
        self.assertIn("func locate(matching config: TVConfig, allowUDAP: Bool = false)", discovery)
        self.assertIn("search(timeout: 2.0, udap: false)", discovery)

        body = discovery[discovery.index("func discoverCandidates"):discovery.index("func sendUDP")]
        gate = body.index("if udap {")
        dlna = body.index("sendUDP(payload: dlnaSearch")
        payloads = list(re.finditer(r'"[MB]-SEARCH \* HTTP/1\.1(?:[^"\\]|\\.)*"', body))
        self.assertTrue(payloads)
        for payload in payloads:
            if "udap" in payload.group(0).lower():
                self.assertTrue(gate < payload.start() < dlna, "busca UDAP fora do `if udap`")

        client = _read("mac_app/LGTVClient.swift")
        self.assertIn("allowUDAP: askedByUser", client)
        self.assertIn("timeIntervalSince(lastAutomaticSearch) >= 30", client)
        for path in sorted((ROOT / "mac_app").glob("*.swift")):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("allowUDAP: true", text, path.name)
            if "askedByUser: true" in text:
                self.assertEqual(path.name, "SettingsView.swift")


if __name__ == "__main__":
    unittest.main()
