#!/usr/bin/env python3
"""
lg_roap_control.py - controle por rede de TVs LG NetCast 2012/2013 (ROAP / UDAP 2.0)

Alvo principal: LG xxLN5700 / xxLN5700-SA (NetCast 4.0, 2013), controlada a partir
de um Mac (Apple Silicon) usando apenas HTTP na porta 8080 da TV.

Como a TV e controlada (resumo do protocolo)
-------------------------------------------
1. Discovery: SSDP M-SEARCH em multicast (239.255.255.250:1900). A TV responde com
   o IP dela. O spec da LG tambem preve B-SEARCH em broadcast (255.255.255.255:1990)
   quando o roteador bloqueia multicast. Opcionalmente varremos a sub-rede
   procurando a porta 8080 aberta.
2. Pairing: POST "AuthKeyReq" (ROAP) ou "showKey" (UDAP) faz a TV mostrar um codigo
   de 6 digitos na tela. O usuario digita o codigo e enviamos "AuthReq" (ROAP) ou
   "hello" (UDAP). No ROAP a TV devolve um <session>; no UDAP a pareacao fica
   registrada por IP do controlador. O codigo e fixo por TV (so muda em reset de
   fabrica) e e salvo em ~/.config/lg_roap_control/config.json.
3. Comando: POST em /{roap|hdcp|udap}/api/command com HandleKeyInput e o key code
   numerico (tabela oficial LG UDAP 2.0, Anexo A). 401 significa "nao pareado":
   refazemos o auth e reenviamos uma vez.
4. Consulta: GET /{...}/api/data?target=volume_info (e outros) devolve XML.

Variantes de caminho suportadas (auto-detectadas):
  roap        /roap/api/{auth,command,data}         (NetCast 3.0/4.0, app LG TV Remote)
  hdcp        /hdcp/api/{auth,command,data}         (relatado em alguns modelos 2013)
  hdcp_wifirc /hdcp/api/dtv_wifirc + /hdcp/api/command (variante usada pela pylgnetcast)
  udap        /udap/api/{pairing,command,data}      (spec oficial LG UDAP 2.0)

Dependencias: somente a biblioteca padrao. Se "requests" estiver instalado ele e
usado; caso contrario cai em urllib automaticamente.

Uso rapido:
  python3 lg_roap_control.py discover          # acha a TV e salva o IP
  python3 lg_roap_control.py info              # modelo + variante do protocolo (sem popup)
  python3 lg_roap_control.py pair              # mostra o codigo na TV e salva a chave
  python3 lg_roap_control.py volume_up         # atalho de 'send volume_up'
  python3 lg_roap_control.py send mute ch+
  python3 lg_roap_control.py live              # setas/Enter/+/- no terminal
  python3 lg_roap_control.py remote            # controle virtual no navegador (--lan: celular)

Validado na TV real xxLN5700-SA_11 (NetCast 4.0, fw 05.02.11) em 15/10/2026: discovery,
descricao UDAP, deteccao de variante (ROAP e UDAP existem; /hdcp nao), pairing ROAP com o
codigo da tela, teclas de volume/mute e consultas volume_info/cur_channel/context_ui.
Re-autenticacao apos 401, modo live e as 4 variantes de caminho foram validados contra um
simulador. Observado: 3x vol+ a cada 0,3 s registram os tres; so o "mute" repetido em
menos de ~1 s teve o segundo toque descartado pela TV.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import select
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Iterable, List, NoReturn, Optional, Tuple

import warnings

# O python3 da Apple (Xcode CLT) e compilado com LibreSSL e o urllib3 v2 avisa isso
# toda vez que "requests" e importado. So falamos HTTP simples com a TV, entao o
# aviso e irrelevante aqui.
warnings.filterwarnings("ignore", message="urllib3 v2 only supports OpenSSL")

try:  # "requests" e opcional; urllib da conta do recado.
    import requests  # type: ignore
except Exception:  # pragma: no cover - ambiente sem requests
    requests = None  # type: ignore

__version__ = "1.0.0"

# --------------------------------------------------------------------------- #
# Constantes de rede e arquivos
# --------------------------------------------------------------------------- #

DEFAULT_PORT = 8080
HTTP_TIMEOUT = 4.0           # segundos por requisicao HTTP
SSDP_MCAST = ("239.255.255.250", 1900)
SSDP_BCAST = ("255.255.255.255", 1990)   # B-SEARCH do spec UDAP 2.0 da LG

# ATENCAO (verificado na xxLN5700-SA fw 05.02.11): o servidor da TV escolhe o handler pelo
# User-Agent. Se a string contiver "UDAP/2.0", ela responde "SERVER: ... UDAP/2.0" e devolve
# HTTP 400 para o XML do ROAP (<auth>, <command>). Sem "UDAP/2.0" ela usa o handler ROAP
# ("SERVER: ... UDAP/1.0") e aceita. Por isso ha dois User-Agents:
USER_AGENT_UDAP = f"macOS/1.0 UDAP/2.0 lg_roap_control/{__version__}"   # SSDP e variante udap
USER_AGENT_ROAP = f"lg_roap_control/{__version__} (macOS)"              # roap, hdcp, hdcp_wifirc
USER_AGENT = USER_AGENT_UDAP  # usado no SSDP e na descricao UDAP (rootservice.xml)


def user_agent_for(protocol: str) -> str:
    return USER_AGENT_UDAP if protocol == "udap" else USER_AGENT_ROAP

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "lg_roap_control"
CONFIG_PATH = CONFIG_DIR / "config.json"

# Caminhos HTTP de cada variante do protocolo. "auth" e o endpoint de pairing.
PROTOCOLS: Dict[str, Dict[str, str]] = {
    "roap": {"auth": "/roap/api/auth", "command": "/roap/api/command", "data": "/roap/api/data"},
    "hdcp": {"auth": "/hdcp/api/auth", "command": "/hdcp/api/command", "data": "/hdcp/api/data"},
    "hdcp_wifirc": {"auth": "/hdcp/api/dtv_wifirc", "command": "/hdcp/api/command", "data": "/hdcp/api/dtv_wifirc"},
    "udap": {"auth": "/udap/api/pairing", "command": "/udap/api/command", "data": "/udap/api/data"},
}
PROTOCOL_ORDER = ["roap", "hdcp", "hdcp_wifirc", "udap"]

XML_HEADER = '<?xml version="1.0" encoding="utf-8"?>'

# --------------------------------------------------------------------------- #
# Tabela de key codes (LG UDAP 2.0, Anexo A; identica a usada pelo ROAP/pylgnetcast)
# --------------------------------------------------------------------------- #

KEYS: Dict[str, int] = {
    # energia e numeros
    "power": 1,
    "0": 2, "1": 3, "2": 4, "3": 5, "4": 6, "5": 7, "6": 8, "7": 9, "8": 10, "9": 11,
    # navegacao
    "up": 12, "down": 13, "left": 14, "right": 15, "ok": 20,
    "home": 21, "menu": 22, "back": 23, "exit": 412,
    # volume e canal
    "volume_up": 24, "volume_down": 25, "mute": 26,
    "channel_up": 27, "channel_down": 28, "previous_channel": 403, "favorite_channel": 404,
    # teclas coloridas
    "blue": 29, "green": 30, "red": 31, "yellow": 32,
    # midia
    "play": 33, "pause": 34, "stop": 35, "fast_forward": 36, "rewind": 37,
    "skip_forward": 38, "skip_backward": 39, "record": 40, "recording_list": 41, "repeat": 42,
    # TV / guia / entrada
    "live_tv": 43, "epg": 44, "info": 45, "aspect_ratio": 46, "input": 47,
    "pip": 48, "subtitle": 49, "program_list": 50, "teletext": 51, "mark": 52,
    # extras
    "3d": 400, "3d_lr": 401, "dash": 402, "quick_menu": 405, "text_option": 406,
    "audio_description": 407, "netcast": 408, "energy_saving": 409, "av_mode": 410,
    "simplink": 411, "reservation_list": 413, "pip_channel_up": 414, "pip_channel_down": 415,
    "switch_video": 416, "apps": 417,
}

# Nomes alternativos aceitos na linha de comando (todos em minusculas).
ALIASES: Dict[str, str] = {
    "power_off": "power", "off": "power", "poweroff": "power",
    "vol_up": "volume_up", "volup": "volume_up", "volume+": "volume_up", "vol+": "volume_up", "+": "volume_up",
    "vol_down": "volume_down", "voldown": "volume_down", "volume-": "volume_down", "vol-": "volume_down", "-": "volume_down",
    "mute_toggle": "mute",
    "ch_up": "channel_up", "chup": "channel_up", "channel+": "channel_up", "ch+": "channel_up",
    "ch_down": "channel_down", "chdown": "channel_down", "channel-": "channel_down", "ch-": "channel_down",
    "enter": "ok", "select": "ok", "return": "back", "prev": "back",
    "smart": "home", "home_menu": "home", "smart_home": "home",
    "source": "input", "external_input": "input", "ext_input": "input",
    "ff": "fast_forward", "rew": "rewind", "my_apps": "apps", "myapps": "apps",
    "guide": "epg", "ratio": "aspect_ratio", "qmenu": "quick_menu",
}

# Perguntas suportadas pelo endpoint /data.
QUERIES = ("volume_info", "cur_channel", "context_ui", "is_3d", "channel_list", "screen_image")


def resolve_key(name: str) -> Optional[int]:
    """Converte nome/alias/numero em key code. Devolve None se desconhecido."""
    low = name.strip().lower()
    for cand in (low, low.replace("-", "_")):
        if cand in KEYS:
            return KEYS[cand]
        if cand in ALIASES:
            return KEYS[ALIASES[cand]]
    if re.fullmatch(r"\d{2,3}", low):
        # codigo numerico cru (ex.: "412"). Digitos unicos sao as teclas 0-9.
        return int(low)
    return None


# --------------------------------------------------------------------------- #
# Erros
# --------------------------------------------------------------------------- #

class TVError(Exception):
    """Erro generico ao falar com a TV."""


class TVConnectionError(TVError):
    """A TV nao respondeu (desligada, IP errado, outra rede, firewall)."""


class TVAuthError(TVError):
    """Pairing key invalida ou sessao rejeitada."""


class TVProtocolError(TVError):
    """A TV respondeu, mas nao do jeito esperado (caminho errado, firmware diferente)."""


# --------------------------------------------------------------------------- #
# HTTP minimo (requests se existir, senao urllib)
# --------------------------------------------------------------------------- #

class HttpResponse:
    def __init__(self, status: int, text: str, headers: Dict[str, str]):
        self.status = status
        self.text = text
        self.headers = headers

    def __repr__(self) -> str:  # pragma: no cover
        return f"HttpResponse(status={self.status}, len={len(self.text)})"


def _friendly_net_error(url: str, exc: Exception) -> str:
    """Resume erros de rede do requests/urllib em uma frase util."""
    text = str(exc).lower()
    where = urllib.parse.urlsplit(url).netloc
    if "refused" in text or "errno 61" in text:
        why = "conexao recusada (porta 8080 fechada: TV desligada/standby ou IP de outro aparelho)"
    elif "timed out" in text or "timeout" in text:
        why = "tempo esgotado (TV em standby, IP errado ou outra rede/VLAN)"
    elif "no route" in text or "errno 65" in text or "unreachable" in text:
        why = "sem rota ate o IP (o Mac esta na mesma rede Wi-Fi/LAN da TV?)"
    elif "name or service not known" in text or "nodename" in text:
        why = "nome de host nao resolve (use o IP numerico)"
    else:
        why = f"{exc.__class__.__name__}: {exc}"
    return f"sem resposta de {where}: {why}"


def http_request(method: str, url: str, body: Optional[str] = None,
                 headers: Optional[Dict[str, str]] = None,
                 timeout: float = HTTP_TIMEOUT, debug: bool = False) -> HttpResponse:
    """Faz uma requisicao HTTP e devolve status/texto. Nunca levanta por status 4xx/5xx."""
    headers = dict(headers or {})
    data = body.encode("utf-8") if body is not None else None
    if debug:
        print(f"[http] {method} {url}", file=sys.stderr)
        if body:
            print(f"[http] >> {body}", file=sys.stderr)
    try:
        if requests is not None:
            r = requests.request(method, url, data=data, headers=headers, timeout=timeout)
            resp = HttpResponse(r.status_code, r.text, dict(r.headers))
        else:
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=timeout) as f:
                    resp = HttpResponse(f.status, f.read().decode("utf-8", "replace"), dict(f.headers))
            except urllib.error.HTTPError as e:
                resp = HttpResponse(e.code, e.read().decode("utf-8", "replace"), dict(e.headers))
    except Exception as e:  # ConnectionError, timeout, URLError...
        raise TVConnectionError(_friendly_net_error(url, e)) from e
    if debug:
        print(f"[http] << {resp.status} {resp.text[:300]!r}", file=sys.stderr)
    return resp


# --------------------------------------------------------------------------- #
# Configuracao persistente
# --------------------------------------------------------------------------- #

def load_config() -> dict:
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
            return cfg if isinstance(cfg, dict) else {}
    except FileNotFoundError:
        return {}
    except Exception as e:
        print(f"[aviso] config ilegivel em {CONFIG_PATH}: {e}", file=sys.stderr)
        return {}


def save_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_PATH)


# --------------------------------------------------------------------------- #
# Cliente da TV
# --------------------------------------------------------------------------- #

class LGNetCastTV:
    """Cliente ROAP/UDAP para uma TV LG NetCast 2012/2013."""

    def __init__(self, host: str, pairing_key: Optional[str] = None, protocol: str = "auto",
                 port: int = DEFAULT_PORT, session: Optional[str] = None,
                 timeout: float = HTTP_TIMEOUT, debug: bool = False):
        self.host = host
        self.port = port
        self.pairing_key = (pairing_key or "").strip() or None
        self.protocol = protocol if protocol in PROTOCOLS else "auto"
        self.session = session
        self.timeout = timeout
        self.debug = debug
        self._udap_hello_done = False  # UDAP: "hello" ja enviado neste processo?

    # ---- infra ----------------------------------------------------------- #

    def _base(self) -> str:
        return f"http://{self.host}:{self.port}"

    def _url(self, kind: str) -> str:
        if self.protocol == "auto":
            self.detect_protocol()
        return self._base() + PROTOCOLS[self.protocol][kind]

    def _headers(self) -> Dict[str, str]:
        if self.protocol == "udap":
            return {"Content-Type": "text/xml; charset=utf-8", "Connection": "Close",
                    "User-Agent": USER_AGENT_UDAP, "Cache-Control": "no-cache"}
        # ROAP/HDCP: Content-Type atom+xml e User-Agent SEM "UDAP/2.0" (ver nota no topo).
        return {"Content-Type": "application/atom+xml", "Connection": "Close",
                "User-Agent": USER_AGENT_ROAP}

    def _post(self, kind: str, xml: str) -> HttpResponse:
        return http_request("POST", self._url(kind), xml, self._headers(), self.timeout, self.debug)

    def _get(self, kind: str, params: Dict[str, str]) -> HttpResponse:
        url = self._url(kind) + "?" + urllib.parse.urlencode(params)
        return http_request("GET", url, None, self._headers(), self.timeout, self.debug)

    # ---- deteccao da variante de protocolo ------------------------------- #

    def detect_protocol(self, order: Iterable[str] = PROTOCOL_ORDER) -> str:
        """Descobre qual caminho a TV responde SEM mostrar o codigo de pairing.

        Faz GET em .../data?target=volume_info em cada variante. 404 = caminho nao
        existe; qualquer outro status (200, 401, 400...) = o endpoint existe.
        """
        last_err: Optional[Exception] = None
        for proto in order:
            url = self._base() + PROTOCOLS[proto]["data"] + "?target=volume_info"
            ua = {"User-Agent": user_agent_for(proto), "Connection": "Close",
                  "Content-Type": "text/xml; charset=utf-8" if proto == "udap" else "application/atom+xml"}
            try:
                r = http_request("GET", url, None, ua, self.timeout, self.debug)
            except TVConnectionError as e:
                last_err = e
                # Conexao recusada ou timeout: nao adianta testar outros caminhos.
                raise TVConnectionError(
                    f"nao foi possivel conectar em {self.host}:{self.port}. "
                    "A TV esta ligada e na mesma rede? Use 'discover' para achar o IP.") from e
            if r.status != 404:
                self.protocol = proto
                if self.debug:
                    print(f"[proto] detectado '{proto}' (HTTP {r.status})", file=sys.stderr)
                return proto
        raise TVProtocolError(
            f"{self.host}:{self.port} responde HTTP mas nenhum caminho conhecido existe "
            f"({', '.join(PROTOCOLS[p]['data'] for p in order)}). "
            f"E mesmo uma LG NetCast? Ultimo erro: {last_err}")

    # ---- pairing --------------------------------------------------------- #

    def request_pairing_key(self) -> None:
        """Pede para a TV mostrar o codigo de 6 digitos na tela."""
        if self.protocol == "auto":
            self.detect_protocol()
        if self.protocol == "udap":
            xml = f'{XML_HEADER}<envelope><api type="pairing"><name>showKey</name></api></envelope>'
        else:
            xml = f"{XML_HEADER}<auth><type>AuthKeyReq</type></auth>"
        r = self._post("auth", xml)
        if r.status != 200:
            raise TVProtocolError(f"TV respondeu HTTP {r.status} ao pedir o codigo de pairing "
                                  f"(variante '{self.protocol}'). Resposta: {r.text[:200]!r}")

    def pair(self, pairing_key: Optional[str] = None) -> Optional[str]:
        """Autentica com a pairing key. Devolve o session id (ROAP) ou None (UDAP)."""
        key = (pairing_key or self.pairing_key or "").replace(" ", "").strip()
        if not key:
            raise TVAuthError("pairing key vazia. Rode 'pair' e digite o codigo mostrado na TV.")
        if self.protocol == "auto":
            self.detect_protocol()
        if self.protocol == "udap":
            xml = (f'{XML_HEADER}<envelope><api type="pairing"><name>hello</name>'
                   f'<value>{key}</value><port>{self.port}</port></api></envelope>')
        else:
            xml = f"{XML_HEADER}<auth><type>AuthReq</type><value>{key}</value></auth>"
        r = self._post("auth", xml)
        if r.status == 401:
            raise TVAuthError("a TV recusou a pairing key (HTTP 401). Confira os 6 digitos; "
                              "se o codigo mudou (reset de fabrica), rode 'pair' de novo.")
        if r.status == 503:
            raise TVAuthError("a TV diz que ja ha controladores demais pareados (HTTP 503). "
                              "Desligue/ligue a TV ou feche o app LG TV Remote no celular.")
        if r.status != 200:
            raise TVProtocolError(f"HTTP {r.status} no pairing: {r.text[:200]!r}")
        self.pairing_key = key
        if self.protocol == "udap":
            self.session = None
            self._udap_hello_done = True
            return None
        session = _xml_find_text(r.text, "session")
        if session and len(session) >= 8:
            self.session = session
        else:
            # Alguns firmwares respondem 200 sem session; seguimos sem ele.
            self.session = session or None
        return self.session

    def ensure_auth(self) -> None:
        """Garante sessao valida (ROAP) ou 'hello' enviado (UDAP)."""
        if self.protocol == "auto":
            self.detect_protocol()
        if self.protocol == "udap":
            if not self._udap_hello_done:
                self.pair()
        elif not self.session:
            self.pair()

    def byebye(self) -> None:
        """UDAP: avisa a TV que o controlador saiu. Inofensivo no ROAP (ignorado)."""
        if self.protocol != "udap":
            return
        xml = (f'{XML_HEADER}<envelope><api type="pairing"><name>byebye</name>'
               f'<port>{self.port}</port></api></envelope>')
        try:
            self._post("auth", xml)
        except TVError:
            pass

    # ---- comandos -------------------------------------------------------- #

    def _command_xml(self, code: int) -> str:
        if self.protocol == "udap":
            return (f'{XML_HEADER}<envelope><api type="command"><name>HandleKeyInput</name>'
                    f'<value>{code}</value></api></envelope>')
        sess = self.session or ""
        return (f"{XML_HEADER}<command><session>{sess}</session>"
                f"<type>HandleKeyInput</type><value>{code}</value></command>")

    def send_key(self, code: int, _retry: bool = True) -> None:
        """Envia um key code. Em 401 refaz o pairing e tenta mais uma vez."""
        self.ensure_auth()
        r = self._post("command", self._command_xml(code))
        if r.status == 200:
            return
        if r.status == 401 and _retry:
            if self.debug:
                print("[auth] 401 no comando; refazendo pairing e reenviando", file=sys.stderr)
            self.session = None
            self._udap_hello_done = False
            self.pair()
            return self.send_key(code, _retry=False)
        if r.status == 401:
            raise TVAuthError("TV respondeu 401 mesmo apos refazer o pairing. "
                              "Rode 'pair' de novo e confira o codigo na tela.")
        raise TVProtocolError(f"TV respondeu HTTP {r.status} ao comando {code}: {r.text[:200]!r}")

    def send_keys(self, codes: Iterable[int], delay: float = 0.25) -> None:
        first = True
        for c in codes:
            if not first and delay > 0:
                time.sleep(delay)
            self.send_key(c)
            first = False

    # ---- consultas ------------------------------------------------------- #

    def query(self, target: str) -> Dict[str, str]:
        """GET .../data?target=<alvo>. Devolve {tag: texto} do primeiro <data>."""
        self.ensure_auth()
        params = {"target": target}
        if self.session:
            params["session"] = self.session  # ignorado pela TV se nao for necessario
        r = self._get("data", params)
        if r.status == 401:
            self.session = None
            self._udap_hello_done = False
            self.pair()
            if self.session:
                params["session"] = self.session
            r = self._get("data", params)
        if r.status != 200:
            raise TVProtocolError(f"HTTP {r.status} na consulta '{target}': {r.text[:200]!r}")
        return _xml_first_data(r.text)

    def device_info(self) -> Dict[str, str]:
        """Le modelo/nome via descricao UDAP (nao precisa de pairing)."""
        return identify_tv(self.host, self.port, self.timeout, self.debug) or {}


# --------------------------------------------------------------------------- #
# Utilidades XML
# --------------------------------------------------------------------------- #

def _xml_find_text(xml_text: str, tag: str) -> Optional[str]:
    try:
        root = ET.fromstring(xml_text.strip())
    except ET.ParseError:
        m = re.search(rf"<{tag}>\s*([^<]+?)\s*</{tag}>", xml_text)
        return m.group(1) if m else None
    el = root.find(f".//{tag}")
    return el.text.strip() if el is not None and el.text else None


def _xml_first_data(xml_text: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    try:
        root = ET.fromstring(xml_text.strip())
    except ET.ParseError:
        return {"raw": xml_text[:500]}
    data = root.find(".//data")
    node = data if data is not None else root
    for child in node:
        if child.text and child.text.strip():
            out[child.tag] = child.text.strip()
    return out


# --------------------------------------------------------------------------- #
# Discovery (SSDP + B-SEARCH + varredura opcional)
# --------------------------------------------------------------------------- #

def _local_ip() -> Optional[str]:
    """IP da interface com rota padrao. Nao envia pacotes (UDP connect e local)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 53))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


def _parse_ssdp(payload: str) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    for line in payload.split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().upper()] = v.strip()
    return headers


def ssdp_search(timeout: float = 3.0, debug: bool = False) -> List[Dict[str, str]]:
    """Envia M-SEARCH (varios ST) e B-SEARCH; devolve lista de respostas por IP."""
    mx = max(1, min(int(timeout), 5))
    searches = [
        ("M-SEARCH", SSDP_MCAST, "udap:rootservice"),
        ("M-SEARCH", SSDP_MCAST, "urn:schemas-upnp-org:device:MediaRenderer:1"),
        ("M-SEARCH", SSDP_MCAST, "ssdp:all"),
        ("B-SEARCH", SSDP_BCAST, "udap:rootservice"),
    ]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.bind(("", 0))
    sock.setblocking(False)

    for method, dest, st in searches:
        host = f"{dest[0]}:{dest[1]}"
        msg = (f"{method} * HTTP/1.1\r\nHOST: {host}\r\nMAN: \"ssdp:discover\"\r\n"
               f"MX: {mx}\r\nST: {st}\r\nUSER-AGENT: {USER_AGENT}\r\n\r\n")
        try:
            sock.sendto(msg.encode(), dest)
        except OSError as e:
            if debug:
                print(f"[ssdp] falha ao enviar {method} {st}: {e}", file=sys.stderr)

    found: Dict[str, Dict[str, str]] = {}
    deadline = time.time() + timeout
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        ready, _, _ = select.select([sock], [], [], remaining)
        if not ready:
            continue
        try:
            data, addr = sock.recvfrom(65535)
        except OSError:
            continue
        text = data.decode("utf-8", "replace")
        if not text.startswith("HTTP/1.1 200"):
            continue
        h = _parse_ssdp(text)
        ip = addr[0]
        entry = found.setdefault(ip, {"ip": ip})
        for k in ("SERVER", "LOCATION", "ST", "USN"):
            if k in h and k not in entry:
                entry[k] = h[k]
        if debug:
            print(f"[ssdp] {ip} ST={h.get('ST')} SERVER={h.get('SERVER')}", file=sys.stderr)
    sock.close()
    return list(found.values())


def identify_tv(ip: str, port: int = DEFAULT_PORT, timeout: float = 2.0,
                debug: bool = False, location: Optional[str] = None) -> Optional[Dict[str, str]]:
    """Confirma que o IP e uma LG NetCast e le modelo/nome. Nao precisa de pairing."""
    info: Dict[str, str] = {"ip": ip, "port": str(port)}
    hdr = {"User-Agent": USER_AGENT, "Connection": "Close"}
    # 1) Descricao UDAP (rootservice.xml). Em NetCast 3.0/4.0 costuma existir.
    try:
        r = http_request("GET", f"http://{ip}:{port}/udap/api/data?target=rootservice.xml",
                         None, hdr, timeout, debug)
        if r.status == 200 and "<" in r.text:
            for tag in ("modelName", "friendlyName", "manufacturer", "uuid", "deviceType"):
                v = _xml_find_text(r.text, tag)
                if v:
                    info[tag] = v
            if info.get("manufacturer", "LG").lower().startswith("lg") or "modelName" in info:
                info["via"] = "udap-description"
                return info
    except TVConnectionError:
        return None  # porta 8080 fechada: nao e uma NetCast ligada
    # 2) Descricao UPnP apontada pelo LOCATION do SSDP.
    if location:
        try:
            r = http_request("GET", location, None, hdr, timeout, debug)
            if r.status == 200:
                man = (_xml_find_text(r.text, "manufacturer") or "")
                if "lg" in man.lower():
                    for tag in ("modelName", "friendlyName", "manufacturer", "UDN"):
                        v = _xml_find_text(r.text, tag)
                        if v:
                            info[tag] = v
                    info["via"] = "upnp-description"
                    return info
        except TVConnectionError:
            pass
    # 3) Ultimo recurso: algum caminho ROAP/HDCP/UDAP existe na porta 8080?
    for proto in PROTOCOL_ORDER:
        try:
            r = http_request("GET", f"http://{ip}:{port}{PROTOCOLS[proto]['data']}?target=volume_info",
                             None, {"User-Agent": user_agent_for(proto), "Connection": "Close"},
                             timeout, debug)
        except TVConnectionError:
            return None
        if r.status != 404:
            info["via"] = f"probe-{proto}"
            info["protocol_hint"] = proto
            return info
    return None


def scan_subnet(timeout: float = 0.4, port: int = DEFAULT_PORT, cidr: Optional[str] = None,
                debug: bool = False) -> List[str]:
    """Varre a sub-rede /24 local procurando a porta 8080 aberta. Devolve IPs."""
    if cidr is None:
        ip = _local_ip()
        if not ip:
            raise TVError("nao consegui descobrir o IP local para varrer a rede; use --cidr")
        cidr = str(ipaddress.ip_network(ip + "/24", strict=False))
    net = ipaddress.ip_network(cidr, strict=False)
    hosts = [str(h) for h in net.hosts()]
    if len(hosts) > 1024:
        raise TVError(f"rede {cidr} grande demais para varrer ({len(hosts)} hosts); use um /24")

    def probe(h: str) -> Optional[str]:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect((h, port))
            return h
        except OSError:
            return None
        finally:
            s.close()

    with ThreadPoolExecutor(max_workers=64) as ex:
        results = list(ex.map(probe, hosts))
    open_hosts = [h for h in results if h]
    if debug:
        print(f"[scan] {cidr}: porta {port} aberta em {open_hosts}", file=sys.stderr)
    return open_hosts


def discover(timeout: float = 3.0, scan: bool = False, cidr: Optional[str] = None,
             port: int = DEFAULT_PORT, debug: bool = False) -> List[Dict[str, str]]:
    """SSDP primeiro; se pedido (ou nada encontrado), varre a sub-rede."""
    candidates: Dict[str, Optional[str]] = {}
    try:
        for entry in ssdp_search(timeout, debug):
            candidates.setdefault(entry["ip"], entry.get("LOCATION"))
    except OSError as e:
        print(f"[aviso] SSDP falhou ({e}). No macOS 15+, confira Ajustes > Privacidade e "
              "Seguranca > Rede Local para o seu terminal.", file=sys.stderr)
    if scan or not candidates:
        try:
            for ip in scan_subnet(port=port, cidr=cidr, debug=debug):
                candidates.setdefault(ip, None)
        except TVError as e:
            print(f"[aviso] varredura: {e}", file=sys.stderr)
    tvs: List[Dict[str, str]] = []
    with ThreadPoolExecutor(max_workers=16) as ex:
        futs = {ip: ex.submit(identify_tv, ip, port, 2.0, debug, loc) for ip, loc in candidates.items()}
        for ip, fut in futs.items():
            try:
                info = fut.result()
            except Exception:
                info = None
            if info:
                tvs.append(info)
    return tvs


# --------------------------------------------------------------------------- #
# Wake-on-LAN (melhor esforco; NetCast 2013 normalmente NAO liga por rede)
# --------------------------------------------------------------------------- #

def mac_from_arp(ip: str) -> Optional[str]:
    """Le o MAC da tabela ARP do macOS (`arp -n IP`) apos ter falado com a TV."""
    try:
        out = subprocess.run(["arp", "-n", ip], capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return None
    m = re.search(r"(([0-9a-f]{1,2}:){5}[0-9a-f]{1,2})", out, re.I)
    if not m:
        return None
    return ":".join(p.zfill(2) for p in m.group(1).split(":")).lower()


def send_wol(mac: str, broadcast: str = "255.255.255.255") -> None:
    mac_clean = re.sub(r"[^0-9a-fA-F]", "", mac)
    if len(mac_clean) != 12:
        raise TVError(f"MAC invalido: {mac!r}")
    packet = b"\xff" * 6 + bytes.fromhex(mac_clean) * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for port in (9, 7):
        s.sendto(packet, (broadcast, port))
    s.close()


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _fail(msg: str, code: int = 1) -> NoReturn:
    print(f"erro: {msg}", file=sys.stderr)
    sys.exit(code)


def build_tv(args: argparse.Namespace, cfg: dict, need_host: bool = True) -> LGNetCastTV:
    host = args.host or os.environ.get("LG_TV_HOST") or cfg.get("host")
    if need_host and not host:
        _fail("nenhum IP configurado. Rode 'discover' (ou 'pair --host IP') primeiro, "
              "ou passe --host / LG_TV_HOST.")
    key = args.key or os.environ.get("LG_TV_KEY") or cfg.get("pairing_key")
    port = args.port or int(cfg.get("port", DEFAULT_PORT))
    # Protocolo e sessao em cache so valem para a mesma TV (e a sessao, para a mesma key).
    same_tv = host == cfg.get("host") and port == int(cfg.get("port", DEFAULT_PORT))
    proto = (args.protocol or os.environ.get("LG_TV_PROTOCOL")
             or (cfg.get("protocol") if same_tv else None) or "auto")
    session = cfg.get("session") if same_tv and key == cfg.get("pairing_key") else None
    return LGNetCastTV(host, key, proto, port, session, timeout=args.timeout, debug=args.debug)


def persist_tv(tv: LGNetCastTV, cfg: dict, extra: Optional[dict] = None) -> None:
    cfg.update({"host": tv.host, "port": tv.port, "protocol": tv.protocol,
                "pairing_key": tv.pairing_key, "session": tv.session})
    if extra:
        cfg.update(extra)
    mac = mac_from_arp(tv.host)
    if mac:
        cfg["mac"] = mac
    save_config(cfg)


def interactive_pair(tv: LGNetCastTV, cfg: dict, key: Optional[str]) -> None:
    """Fluxo completo de pairing com prompt para o codigo da tela."""
    if tv.protocol == "auto":
        print(f"Detectando variante do protocolo em {tv.host}:{tv.port} ...")
        tv.detect_protocol()
    print(f"Variante detectada: {tv.protocol}")
    def ask(prompt: str) -> str:
        try:
            return input(prompt).strip()
        except EOFError:
            _fail("sem entrada para digitar o codigo. Use: pair --key 123456")

    if not key:
        print("Pedindo para a TV mostrar o codigo de pairing na tela ...")
        tv.request_pairing_key()
        key = ask("Digite os 6 digitos mostrados na TV (ou ENTER para cancelar): ")
        if not key:
            _fail("pairing cancelado.", 2)
    for attempt in range(3):
        try:
            tv.pair(key)
            break
        except TVAuthError as e:
            print(f"[falhou] {e}")
            if attempt == 2:
                _fail("pairing nao concluido.")
            tv.request_pairing_key()
            key = ask("Tente de novo. Codigo na TV: ")
    info = {}
    try:
        info = tv.device_info()
    except Exception:
        pass
    persist_tv(tv, cfg, {"model": info.get("modelName", cfg.get("model", "")),
                         "name": info.get("friendlyName", cfg.get("name", ""))})
    print(f"Pareado com {tv.host} ({tv.protocol}). Config salva em {CONFIG_PATH}")
    if tv.session:
        print(f"Sessao: {tv.session}")


def cmd_discover(args: argparse.Namespace, cfg: dict) -> int:
    print(f"Procurando TVs LG NetCast (SSDP {args.timeout:.0f}s"
          f"{', + varredura da sub-rede' if args.scan else ''}) ...")
    tvs = discover(args.timeout, args.scan, args.cidr, args.port or DEFAULT_PORT, args.debug)
    if not tvs:
        print("Nenhuma TV encontrada.")
        print("Dicas: TV ligada (nao em standby)? Mac na mesma rede Wi-Fi/LAN? Tente "
              "'discover --scan'. No macOS 15+, libere 'Rede Local' para o terminal em "
              "Ajustes > Privacidade e Seguranca. Ou pegue o IP na TV em "
              "Ajustes > Rede > Status/Conexao e use --host.")
        return 1
    for t in tvs:
        print(f"- {t['ip']}:{t.get('port', DEFAULT_PORT)}  modelo={t.get('modelName', '?')}  "
              f"nome={t.get('friendlyName', '?')}  (via {t.get('via')})")
    if args.save or (len(tvs) == 1 and not cfg.get("host")):
        t = tvs[0]
        cfg.update({"host": t["ip"], "port": int(t.get("port", DEFAULT_PORT)),
                    "model": t.get("modelName", ""), "name": t.get("friendlyName", "")})
        if t.get("protocol_hint"):
            cfg["protocol"] = t["protocol_hint"]
        save_config(cfg)
        print(f"IP {t['ip']} salvo em {CONFIG_PATH}. Proximo passo: 'pair'.")
    return 0


def cmd_pair(args: argparse.Namespace, cfg: dict) -> int:
    if not (args.host or os.environ.get("LG_TV_HOST") or cfg.get("host")):
        print("Nenhum IP conhecido; tentando descobrir a TV ...")
        tvs = discover(3.0, False, None, args.port or DEFAULT_PORT, args.debug)
        if len(tvs) != 1:
            _fail("informe o IP: pair --host 192.168.x.y  (rode 'discover' para listar)")
        args.host = tvs[0]["ip"]
        print(f"Usando {args.host} ({tvs[0].get('modelName', '?')})")
    tv = build_tv(args, cfg)
    tv.session = None  # pairing sempre comeca do zero
    tv.pairing_key = None
    interactive_pair(tv, cfg, args.key)
    return 0


def _ensure_paired(tv: LGNetCastTV, cfg: dict) -> None:
    """Se nao ha pairing key, dispara o fluxo de pairing antes do comando."""
    if tv.pairing_key:
        return
    print("Esta TV ainda nao foi pareada.")
    interactive_pair(tv, cfg, None)


def cmd_send(args: argparse.Namespace, cfg: dict) -> int:
    codes: List[Tuple[str, int]] = []
    for name in args.keys:
        code = resolve_key(name)
        if code is None:
            _fail(f"tecla desconhecida: {name!r}. Veja 'keys'.")
        codes.append((name, code))
    tv = build_tv(args, cfg)
    _ensure_paired(tv, cfg)
    try:
        for i, (name, code) in enumerate(codes):
            if i and args.delay > 0:
                time.sleep(args.delay)
            tv.send_key(code)
            if not args.quiet:
                print(f"ok: {name} ({code})")
    except TVError as e:
        _fail(str(e))  # nada e salvo: um --key errado nao sobrescreve a chave boa
    _persist_if_changed(tv, cfg)
    return 0


def _persist_if_changed(tv: LGNetCastTV, cfg: dict) -> None:
    """Salva sessao/protocolo/chave novos apos uma operacao bem-sucedida."""
    if (tv.session != cfg.get("session") or tv.protocol != cfg.get("protocol")
            or tv.pairing_key != cfg.get("pairing_key") or tv.host != cfg.get("host")):
        persist_tv(tv, cfg)


def cmd_digits(args: argparse.Namespace, cfg: dict) -> int:
    if not re.fullmatch(r"\d+", args.number):
        _fail("use apenas digitos, ex.: digits 123")
    args.keys = list(args.number) + (["ok"] if args.enter else [])
    return cmd_send(args, cfg)


def cmd_status(args: argparse.Namespace, cfg: dict) -> int:
    tv = build_tv(args, cfg)
    _ensure_paired(tv, cfg)
    targets = [args.target] if args.target else ["volume_info", "cur_channel", "context_ui"]
    rc = 0
    try:
        info = tv.device_info()
        if info:
            print(f"TV: {info.get('modelName', '?')}  nome={info.get('friendlyName', '?')}  "
                  f"ip={tv.host}  protocolo={tv.protocol}")
        for t in targets:
            try:
                data = tv.query(t)
                print(f"[{t}] " + ", ".join(f"{k}={v}" for k, v in data.items()) if data else f"[{t}] (vazio)")
            except TVError as e:
                print(f"[{t}] falhou: {e}")
                rc = 1
    except TVError as e:
        _fail(str(e))
    if rc == 0:
        _persist_if_changed(tv, cfg)
    return rc


def cmd_info(args: argparse.Namespace, cfg: dict) -> int:
    """Mostra modelo/nome e a variante de protocolo da TV. Nao mostra codigo na tela."""
    tv = build_tv(args, cfg)
    try:
        info = tv.device_info()
        proto = tv.detect_protocol() if tv.protocol == "auto" else tv.protocol
    except TVError as e:
        _fail(str(e))
    print(f"TV em {tv.host}:{tv.port}")
    print(f"  modelo:    {info.get('modelName', '?')}")
    print(f"  nome:      {info.get('friendlyName', '?')}")
    print(f"  fabric.:   {info.get('manufacturer', '?')}")
    print(f"  uuid:      {info.get('uuid', '?')}")
    print(f"  protocolo: {proto}  (caminhos: {PROTOCOLS[proto]})")
    print(f"  pareada:   {'sim (chave salva)' if tv.pairing_key else 'nao (rode pair)'}")
    if tv.host == cfg.get("host") or not cfg.get("host"):
        cfg.update({"host": tv.host, "port": tv.port, "protocol": proto,
                    "model": info.get("modelName", cfg.get("model", "")),
                    "name": info.get("friendlyName", cfg.get("name", ""))})
        save_config(cfg)
    return 0


def cmd_keys(args: argparse.Namespace, cfg: dict) -> int:
    print("Teclas disponiveis (nome -> key code). Aliases aceitos: ex. vol+, vol-, ch+, ch-, off, enter, smart, source.")
    width = max(len(k) for k in KEYS)
    for name, code in KEYS.items():
        print(f"  {name:<{width}}  {code}")
    print("Tambem aceita codigo numerico cru (2-3 digitos): ex. 'raw 412' ou 'send 412'.")
    return 0


def cmd_raw(args: argparse.Namespace, cfg: dict) -> int:
    args.keys = [str(args.code)]
    return cmd_send(args, cfg)


def cmd_config(args: argparse.Namespace, cfg: dict) -> int:
    if args.reset:
        if CONFIG_PATH.exists():
            CONFIG_PATH.unlink()
            print(f"removido {CONFIG_PATH}")
        else:
            print("nada para remover.")
        return 0
    changed = False
    for field in ("host", "key", "protocol", "port"):
        val = getattr(args, f"set_{field}", None)
        if val:
            if field == "protocol" and val not in PROTOCOLS and val != "auto":
                _fail(f"protocolo invalido; use um de: auto, {', '.join(PROTOCOLS)}")
            cfg["pairing_key" if field == "key" else field] = int(val) if field == "port" else val
            if field in ("host", "key", "protocol"):
                cfg.pop("session", None)
            changed = True
    if changed:
        save_config(cfg)
        print(f"config atualizada em {CONFIG_PATH}")
    print(f"arquivo: {CONFIG_PATH}")
    if not cfg:
        print("(vazio)")
    for k, v in cfg.items():
        print(f"  {k}: {v}")
    return 0


def cmd_wol(args: argparse.Namespace, cfg: dict) -> int:
    mac = args.mac or cfg.get("mac")
    if not mac:
        _fail("MAC desconhecido. Passe 'wol aa:bb:cc:dd:ee:ff' ou rode 'pair'/'status' com a TV ligada "
              "para o MAC ser salvo automaticamente.")
    send_wol(mac)
    print(f"Magic packet enviado para {mac}. Aviso: TVs NetCast 2013 normalmente NAO acordam por "
          "rede; se nao ligar, use o controle fisico ou um dispositivo HDMI-CEC (SIMPLINK).")
    return 0


REPL_HELP = """Comandos do modo interativo:
  <tecla> [tecla ...]   envia teclas (ex.: volume_up, mute, 1 2 3 ok, vol+)
  digits 123            digita um numero de canal e confirma com ok
  status                mostra volume/canal/contexto
  keys                  lista as teclas
  help                  esta ajuda
  quit / exit / Ctrl-D  sair
"""


def cmd_interactive(args: argparse.Namespace, cfg: dict) -> int:
    tv = build_tv(args, cfg)
    _ensure_paired(tv, cfg)
    try:
        import readline  # noqa: F401  (historico e edicao de linha no macOS)
    except Exception:
        pass
    print(f"Conectado a {tv.host} ({cfg.get('model') or 'LG NetCast'}). Digite 'help'.")
    try:
        while True:
            try:
                line = input("lg> ").strip()
            except EOFError:
                print()
                break
            if not line:
                continue
            parts = line.split()
            cmd = parts[0].lower()
            if cmd in ("quit", "exit", "q"):
                break
            if cmd == "help":
                print(REPL_HELP)
                continue
            if cmd == "keys":
                cmd_keys(args, cfg)
                continue
            if cmd == "status":
                for t in ("volume_info", "cur_channel", "context_ui"):
                    try:
                        print(f"[{t}] " + ", ".join(f"{k}={v}" for k, v in tv.query(t).items()))
                    except TVError as e:
                        print(f"[{t}] falhou: {e}")
                continue
            if cmd == "digits" and len(parts) == 2 and parts[1].isdigit():
                parts = list(parts[1]) + ["ok"]
            try:
                for i, name in enumerate(parts):
                    code = resolve_key(name)
                    if code is None:
                        print(f"tecla desconhecida: {name!r} (veja 'keys')")
                        break
                    if i:
                        time.sleep(args.delay)
                    tv.send_key(code)
                    print(f"ok: {name} ({code})")
            except TVError as e:
                print(f"erro: {e}")
    except KeyboardInterrupt:
        print()
    finally:
        tv.byebye()
        _persist_if_changed(tv, cfg)
    return 0


LIVE_HELP = """Modo ao vivo (teclado -> TV). Teclas:
  setas = navegar   Enter = OK   Backspace/Esc = voltar   x = exit
  + / = volume+   - / _ volume-   m = mute   ] canal+   [ canal-
  h = home/smart   i = input   p = power (desliga!)   0-9 = numeros
  space = play/pause (play)   ? = ajuda   q = sair
"""


def cmd_live(args: argparse.Namespace, cfg: dict) -> int:
    """Modo 'controle remoto': le teclas cruas do terminal (termios) e envia na hora."""
    if not sys.stdin.isatty():
        _fail("o modo live precisa de um terminal interativo.")
    import termios
    import tty

    tv = build_tv(args, cfg)
    _ensure_paired(tv, cfg)
    keymap = {
        "\r": "ok", "\n": "ok", "\x7f": "back", "\x08": "back",
        "+": "volume_up", "=": "volume_up", "-": "volume_down", "_": "volume_down",
        "m": "mute", "]": "channel_up", "[": "channel_down", "h": "home", "i": "input",
        "p": "power", "x": "exit", " ": "play", "b": "back",
        **{d: d for d in "0123456789"},
    }
    arrows = {"A": "up", "B": "down", "C": "right", "D": "left"}
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    print(LIVE_HELP)
    print(f"Conectado a {tv.host}. (q para sair)")
    try:
        tty.setcbreak(fd)
        while True:
            ch = os.read(fd, 1).decode("utf-8", "replace")
            name: Optional[str] = None
            if ch == "\x1b":
                # Sequencia de escape (seta) ou Esc sozinho.
                r, _, _ = select.select([fd], [], [], 0.05)
                if r:
                    seq = os.read(fd, 2).decode("utf-8", "replace")
                    name = arrows.get(seq[-1:]) if seq.startswith("[") else None
                else:
                    name = "back"
            elif ch == "q":
                break
            elif ch == "?":
                print(LIVE_HELP)
                continue
            else:
                name = keymap.get(ch.lower())
            if not name:
                continue
            try:
                tv.send_key(KEYS[name])
                print(f"\r{name:<14}", end="", flush=True)
            except TVError as e:
                print(f"\rerro: {e}")
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        print()
        tv.byebye()
        _persist_if_changed(tv, cfg)
    return 0


# --------------------------------------------------------------------------- #
# Controle virtual no navegador (subcomando "remote")
# --------------------------------------------------------------------------- #
#
# Um servidor HTTP local (biblioteca padrao) serve uma pagina com os botoes do controle.
# A pagina chama POST /api/key/<tecla> e GET /api/status; o servidor fala com a TV.
# Por padrao escuta so em 127.0.0.1. Com --lan escuta em 0.0.0.0 para usar do celular
# na mesma rede (sem senha: use apenas em rede confiavel).

REMOTE_HTML = r"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>Controle LG</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body { margin: 0; font-family: -apple-system, system-ui, sans-serif; background: #111; color: #eee;
         display: flex; justify-content: center; }
  .remote { width: 100%; max-width: 380px; padding: 12px 12px 32px; user-select: none; }
  h1 { font-size: 15px; font-weight: 600; margin: 4px 0 2px; text-align: center; color: #aaa; }
  #status { font-size: 13px; color: #8fd; text-align: center; min-height: 18px; margin-bottom: 10px; }
  #status.err { color: #f88; }
  .row { display: grid; gap: 8px; margin: 8px 0; }
  .c3 { grid-template-columns: repeat(3, 1fr); }
  .c4 { grid-template-columns: repeat(4, 1fr); }
  .c5 { grid-template-columns: repeat(5, 1fr); }
  button { font: inherit; font-size: 16px; padding: 14px 0; border: 0; border-radius: 12px;
           background: #2a2a2e; color: #eee; cursor: pointer; touch-action: manipulation; }
  button:active, button.flash { background: #4a4a52; transform: scale(0.97); }
  .power { background: #7a1f1f; } .ok { background: #1f4f7a; font-weight: 700; }
  .vol, .ch { font-size: 18px; }
  .red { background: #7a2020; } .green { background: #1f6a2a; }
  .yellow { background: #8a7a1a; color: #111; } .blue { background: #1f3f8a; }
  .hint { font-size: 12px; color: #777; text-align: center; margin-top: 12px; }
</style>
</head>
<body>
<div class="remote">
  <h1 id="title">LG NetCast</h1>
  <div id="status">conectando...</div>
  <div class="row c3">
    <button class="power" data-key="power" data-confirm="1">&#x23FB; Power</button>
    <button data-key="input">Input</button>
    <button data-key="home">Home</button>
  </div>
  <div class="row c3">
    <button data-key="1">1</button><button data-key="2">2</button><button data-key="3">3</button>
    <button data-key="4">4</button><button data-key="5">5</button><button data-key="6">6</button>
    <button data-key="7">7</button><button data-key="8">8</button><button data-key="9">9</button>
    <button data-key="previous_channel">&#x21A9; Canal</button><button data-key="0">0</button><button data-key="info">Info</button>
  </div>
  <div class="row c3">
    <button data-key="menu">Menu</button><button data-key="up">&#x25B2;</button><button data-key="exit">Exit</button>
    <button data-key="left">&#x25C0;</button><button class="ok" data-key="ok">OK</button><button data-key="right">&#x25B6;</button>
    <button data-key="back">Voltar</button><button data-key="down">&#x25BC;</button><button data-key="epg">Guia</button>
  </div>
  <div class="row c4">
    <button class="vol" data-key="volume_up">Vol +</button><button class="ch" data-key="channel_up">Ch +</button>
    <button class="vol" data-key="volume_down">Vol &minus;</button><button class="ch" data-key="channel_down">Ch &minus;</button>
  </div>
  <div class="row c3">
    <button data-key="mute">Mute</button><button data-key="apps">Apps</button><button data-key="quick_menu">Q.Menu</button>
  </div>
  <div class="row c5">
    <button data-key="rewind">&#x23EA;</button><button data-key="play">&#x25B6;&#xFE0E;</button>
    <button data-key="pause">&#x23F8;</button><button data-key="stop">&#x23F9;</button><button data-key="fast_forward">&#x23E9;</button>
  </div>
  <div class="row c4">
    <button class="red" data-key="red"></button><button class="green" data-key="green"></button>
    <button class="yellow" data-key="yellow"></button><button class="blue" data-key="blue"></button>
  </div>
  <div class="hint">Teclado: setas, Enter, Backspace/Esc, + &minus; m, [ ] canal, h home, i input, 0-9, x exit</div>
</div>
<script>
const statusEl = document.getElementById('status');
let queue = Promise.resolve();   // envia uma tecla por vez, na ordem dos toques
function show(msg, err) { statusEl.textContent = msg; statusEl.className = err ? 'err' : ''; }
function press(key) {
  const b = document.querySelector('button[data-key="' + key + '"]');
  if (b) { b.classList.add('flash'); setTimeout(() => b.classList.remove('flash'), 150); }
  queue = queue.then(async () => {
    try {
      const r = await fetch('/api/key/' + encodeURIComponent(key), {method: 'POST'});
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || r.statusText);
      show(key + ' (' + j.code + ') ok');
      scheduleStatus();
    } catch (e) { show('erro: ' + e.message, true); }
  });
  return queue;
}
let timer = null;
function scheduleStatus() { clearTimeout(timer); timer = setTimeout(refresh, 900); }
async function refresh() {
  try {
    const r = await fetch('/api/status'); const j = await r.json();
    document.getElementById('title').textContent = j.model || 'LG NetCast';
    if (j.error) { show('TV: ' + j.error, true); return; }
    const v = j.volume || {}; const c = j.channel || {};
    const src = c.inputSourceName || (c.major && c.major !== '65520' ? 'canal ' + c.major : '');
    const vol = (v.level !== undefined ? 'vol ' + v.level : 'vol ?') + (v.mute === 'true' ? ' (mudo)' : '');
    show(vol + (src ? '  |  ' + src : ''));
  } catch (e) { show('sem status: ' + e.message, true); }
}
document.querySelectorAll('button[data-key]').forEach(b => b.addEventListener('click', () => {
  if (b.dataset.confirm && !confirm('Desligar a TV? Ela nao liga de novo pela rede.')) return;
  press(b.dataset.key);
}));
const keymap = {ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', Enter: 'ok',
  Backspace: 'back', Escape: 'back', '+': 'volume_up', '=': 'volume_up', '-': 'volume_down', '_': 'volume_down',
  m: 'mute', ']': 'channel_up', '[': 'channel_down', PageUp: 'channel_up', PageDown: 'channel_down',
  h: 'home', i: 'input', x: 'exit', ' ': 'play'};
for (let d = 0; d < 10; d++) keymap[String(d)] = String(d);
document.addEventListener('keydown', e => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const k = keymap[e.key]; if (!k) return;
  e.preventDefault(); press(k);
});
refresh(); setInterval(refresh, 20000);
</script>
</body>
</html>
"""


class _RemoteHandler(BaseHTTPRequestHandler):
    """Serve a pagina do controle e a API JSON que fala com a TV."""

    tv: Optional[LGNetCastTV] = None
    lock = threading.Lock()      # a TV e um recurso serial; um comando por vez
    model = "LG NetCast"
    debug = False
    server_version = f"lg_roap_control/{__version__}"
    sys_version = ""
    # Medido na xxLN5700: teclas iguais enviadas sem intervalo sao descartadas (3x vol+ em
    # rajada = 1 registrado); com 0,3 s entre envios os tres registram.
    min_gap = 0.3
    _last_send = 0.0

    @classmethod
    def _send_spaced(cls, code: int) -> None:
        """Envia uma tecla respeitando o intervalo minimo desde a ultima. Chamar com o lock."""
        assert cls.tv is not None
        wait = cls.min_gap - (time.monotonic() - cls._last_send)
        if wait > 0:
            time.sleep(wait)
        try:
            cls.tv.send_key(code)
        finally:
            cls._last_send = time.monotonic()

    def log_message(self, fmt: str, *args) -> None:  # silencioso, a nao ser com --debug
        if self.debug:
            super().log_message(fmt, *args)

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, obj: dict) -> None:
        self._send(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def do_GET(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/", "/index.html"):
            self._send(200, REMOTE_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/api/status":
            self._status()
        elif path == "/api/keys":
            self._json(200, {"keys": KEYS, "aliases": ALIASES})
        elif path.startswith("/api/key/"):
            self._key(path)  # conveniencia: GET tambem funciona (ex.: curl, Atalhos)
        else:
            self._json(404, {"error": "nao encontrado"})

    def do_POST(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith("/api/key/"):
            self._key(path)
        elif path == "/api/digits":
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n).decode("utf-8", "replace").strip()
            if not re.fullmatch(r"\d+", body):
                return self._json(400, {"error": "envie so digitos no corpo"})
            try:
                with self.lock:
                    for d in body:
                        self._send_spaced(KEYS[d])
                    self._send_spaced(KEYS["ok"])
            except TVError as e:
                return self._json(502, {"error": str(e)})
            self._json(200, {"ok": True, "digits": body})
        else:
            self._json(404, {"error": "nao encontrado"})

    def _key(self, path: str) -> None:
        name = urllib.parse.unquote(path[len("/api/key/"):])
        code = resolve_key(name)
        if code is None:
            return self._json(400, {"error": f"tecla desconhecida: {name}"})
        try:
            with self.lock:
                self._send_spaced(code)
        except TVError as e:
            return self._json(502, {"error": str(e)})
        self._json(200, {"ok": True, "key": name, "code": code})

    def _status(self) -> None:
        assert self.tv is not None
        out: dict = {"model": self.model, "host": self.tv.host, "protocol": self.tv.protocol}
        try:
            with self.lock:
                out["volume"] = self.tv.query("volume_info")
                out["channel"] = self.tv.query("cur_channel")
        except TVError as e:
            out["error"] = str(e)
        self._json(200, out)


def cmd_remote(args: argparse.Namespace, cfg: dict) -> int:
    """Abre o controle virtual no navegador (servidor local em 127.0.0.1:8765)."""
    tv = build_tv(args, cfg)
    _ensure_paired(tv, cfg)
    try:
        tv.ensure_auth()  # falha cedo se a TV estiver desligada/inalcancavel
    except TVError as e:
        _fail(str(e))
    _RemoteHandler.tv = tv
    _RemoteHandler.debug = args.debug
    _RemoteHandler.model = cfg.get("model") or cfg.get("name") or "LG NetCast"
    bind = "0.0.0.0" if args.lan else "127.0.0.1"
    try:
        httpd = ThreadingHTTPServer((bind, args.http_port), _RemoteHandler)
    except OSError as e:
        _fail(f"nao consegui escutar em {bind}:{args.http_port}: {e}. Tente --http-port 8766.")
    httpd.daemon_threads = True
    url = f"http://127.0.0.1:{args.http_port}/"
    print(f"Controle virtual da TV {tv.host} em {url}", flush=True)
    if args.lan:
        ip = _local_ip() or "<IP-do-Mac>"
        print(f"Pelo celular (mesma rede): http://{ip}:{args.http_port}/   (sem senha; so em rede confiavel)",
              flush=True)
    print("Ctrl-C para encerrar.", flush=True)
    if not args.no_open:
        webbrowser.open(url)

    # Encerramento limpo por Ctrl-C (SIGINT) e por 'kill' (SIGTERM), mesmo quando o processo
    # foi iniciado em background por um shell nao interativo (que herda SIGINT ignorado).
    def _stop(signum, frame):  # noqa: ARG001
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nEncerrando o controle virtual.", flush=True)
    finally:
        httpd.server_close()
        tv.byebye()
        _persist_if_changed(tv, cfg)
    return 0


def cmd_gui(args: argparse.Namespace, cfg: dict) -> int:
    """Abre a aplicacao desktop do controle remoto (app nativo macOS ou Tkinter)."""
    base_dir = Path(__file__).resolve().parent
    desktop_app = Path.home() / "Applications" / "Controle Remoto LG.app"   # atalho na Mesa aponta para cá
    bundle_app = base_dir / "Controle Remoto LG.app"
    python_gui = base_dir / "lg_remote_gui.py"

    if not getattr(args, "python", False):
        target_app = desktop_app if desktop_app.exists() else (bundle_app if bundle_app.exists() else None)
        if target_app:
            print(f"Abrindo aplicativo nativo do macOS: {target_app}")
            subprocess.run(["open", str(target_app)])
            return 0
        build_script = base_dir / "mac_app" / "build_app.sh"
        if build_script.exists():
            print("Aplicativo nativo nao compilado. Compilando com build_app.sh...")
            subprocess.run(["bash", str(build_script)], check=True)
            if desktop_app.exists():
                subprocess.run(["open", str(desktop_app)])
                return 0

    if python_gui.exists():
        print(f"Abrindo interface desktop Python: {python_gui}")
        subprocess.run([sys.executable, str(python_gui)])
        return 0

    _fail("Nenhuma interface grafica desktop encontrada.")


SUBCOMMANDS = ("discover", "pair", "send", "digits", "raw", "info", "status", "keys", "config",
               "wol", "interactive", "live", "remote", "gui", "app")


COMMON_DEFAULTS = {"host": None, "port": None, "key": None, "protocol": None,
                   "timeout": HTTP_TIMEOUT, "delay": 0.3, "debug": False, "quiet": False}


def _common_options() -> argparse.ArgumentParser:
    """Opcoes aceitas antes OU depois do subcomando (ex.: 'pair --host IP --key 123456').

    default=SUPPRESS evita que o subparser sobrescreva o valor dado antes do subcomando;
    os padroes reais sao aplicados em main() via COMMON_DEFAULTS.
    """
    S = argparse.SUPPRESS
    c = argparse.ArgumentParser(add_help=False)
    c.add_argument("--host", default=S, help="IP da TV (ou LG_TV_HOST; senao usa o config salvo)")
    c.add_argument("--port", type=int, default=S, help=f"porta HTTP da TV (padrao {DEFAULT_PORT})")
    c.add_argument("--key", default=S, help="pairing key de 6 digitos (ou LG_TV_KEY)")
    c.add_argument("--protocol", choices=["auto", *PROTOCOLS], default=S,
                   help="forca a variante do protocolo (padrao: auto-detecta)")
    c.add_argument("--timeout", type=float, default=S, help=f"timeout HTTP em segundos (padrao {HTTP_TIMEOUT})")
    c.add_argument("--delay", type=float, default=S,
                   help="pausa entre teclas em sequencia (padrao 0.3s; a TV descarta repeticoes mais rapidas)")
    c.add_argument("--debug", action="store_true", default=S, help="mostra as requisicoes HTTP")
    c.add_argument("-q", "--quiet", action="store_true", default=S, help="nao imprime 'ok' por tecla")
    return c


def build_parser() -> argparse.ArgumentParser:
    common = _common_options()
    p = argparse.ArgumentParser(
        prog="lg_roap_control.py",
        parents=[common],
        description="Controle por rede (ROAP/UDAP) de TVs LG NetCast 2012/2013, ex. xxLN5700.",
        epilog="Atalho: 'lg_roap_control.py volume_up' equivale a 'lg_roap_control.py send volume_up'.",
    )
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")

    sub = p.add_subparsers(dest="cmd", parser_class=lambda **kw: argparse.ArgumentParser(parents=[common], **kw))

    d = sub.add_parser("discover", help="procura a TV na rede (SSDP; --scan varre a sub-rede)")
    d.add_argument("--scan", action="store_true", help="tambem varre a sub-rede /24 na porta 8080")
    d.add_argument("--cidr", help="rede a varrer, ex. 192.0.2.0/24 (padrao: /24 do Mac)")
    d.add_argument("--save", action="store_true", help="salva a primeira TV achada no config")
    d.set_defaults(func=cmd_discover)

    pr = sub.add_parser("pair", help="faz o pairing: mostra o codigo na TV e salva a chave")
    pr.set_defaults(func=cmd_pair)

    s = sub.add_parser("send", help="envia uma ou mais teclas")
    s.add_argument("keys", nargs="+", help="nomes de tecla (veja 'keys') ou codigos numericos")
    s.set_defaults(func=cmd_send)

    dg = sub.add_parser("digits", help="digita um numero (ex. canal) e confirma com ok")
    dg.add_argument("number")
    dg.add_argument("--no-enter", dest="enter", action="store_false", help="nao envia ok no final")
    dg.set_defaults(func=cmd_digits)

    rw = sub.add_parser("raw", help="envia um key code numerico cru")
    rw.add_argument("code", type=int)
    rw.set_defaults(func=cmd_raw)

    inf = sub.add_parser("info", help="modelo e variante do protocolo da TV (sem pairing)")
    inf.set_defaults(func=cmd_info)

    st = sub.add_parser("status", help="consulta volume/canal/contexto da TV")
    st.add_argument("target", nargs="?", choices=QUERIES, help="consulta especifica")
    st.set_defaults(func=cmd_status)

    k = sub.add_parser("keys", help="lista os nomes de tecla e key codes")
    k.set_defaults(func=cmd_keys)

    c = sub.add_parser("config", help="mostra/altera a configuracao salva")
    c.add_argument("--set-host")
    c.add_argument("--set-key")
    c.add_argument("--set-protocol")
    c.add_argument("--set-port")
    c.add_argument("--reset", action="store_true", help="apaga o config (desfaz o pairing local)")
    c.set_defaults(func=cmd_config)

    w = sub.add_parser("wol", help="envia Wake-on-LAN (melhor esforco)")
    w.add_argument("mac", nargs="?")
    w.set_defaults(func=cmd_wol)

    i = sub.add_parser("interactive", help="prompt 'lg>' para digitar comandos")
    i.set_defaults(func=cmd_interactive)

    lv = sub.add_parser("live", help="modo controle remoto: setas/Enter/+/-/m direto no terminal")
    lv.set_defaults(func=cmd_live)

    rm = sub.add_parser("remote", help="controle virtual com botoes no navegador (e no celular com --lan)")
    rm.add_argument("--http-port", type=int, default=8765, help="porta local do servidor (padrao 8765)")
    rm.add_argument("--lan", action="store_true", help="aceita conexoes da rede local (celular/tablet)")
    rm.add_argument("--no-open", action="store_true", help="nao abre o navegador automaticamente")
    rm.set_defaults(func=cmd_remote)

    g = sub.add_parser("gui", aliases=["app"], help="abre o aplicativo desktop para macOS")
    g.add_argument("--python", action="store_true", help="abre a versao Python/Tkinter em vez do app nativo Swift")
    g.set_defaults(func=cmd_gui)
    return p


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    # Atalho: 'lg_roap_control.py volume_up mute' vira 'send volume_up mute'.
    # Opcoes globais com valor (--host X) precisam ser puladas na deteccao do atalho.
    valued = {"--host", "--port", "--key", "--protocol", "--timeout", "--delay"}
    cleaned: List[str] = []
    skip = False
    for a in argv:
        if skip:
            skip = False
            continue
        if a in valued:
            skip = True
            continue
        if a.startswith("-"):
            continue
        cleaned.append(a)
    if cleaned and cleaned[0] not in SUBCOMMANDS and resolve_key(cleaned[0]) is not None:
        idx = argv.index(cleaned[0])
        argv = argv[:idx] + ["send"] + argv[idx:]

    parser = build_parser()
    args = parser.parse_args(argv)
    for k, v in COMMON_DEFAULTS.items():
        vars(args).setdefault(k, v)
    if not args.cmd:
        parser.print_help()
        return 0
    cfg = load_config()
    try:
        return args.func(args, cfg)
    except KeyboardInterrupt:
        print()
        return 130
    except TVError as e:
        _fail(str(e))


if __name__ == "__main__":
    sys.exit(main())
