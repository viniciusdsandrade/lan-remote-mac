"""Prova que o app não dá a TV como desligada em falhas HTTP momentâneas quando o ping responde.

Em standby a TV LG NetCast desliga a interface de rede e não responde ao ping; ligada, se uma
requisição à porta 8080 expirar (oscilação de Wi-Fi, subida do sistema ou conflito de IP na LAN),
o ping distingue a TV acordada de standby. O teste compila o app com tests/swift/DeafTVCheck.swift,
que responde pela TV num URLProtocol: nenhuma requisição HTTP vai para a porta 8080 real. A TV
acordada é simulada em 127.0.0.1 (responde ao ping), cobrindo fila de teclas em ordem, re-pareamento
em 401 após espera, descarte de teclas vencidas (keyPatience), preservação do estado Ligando até o
HTTP subir, standby sem ping e janela pós-desligamento.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "mac_app"
NOT_APP = ("AppMain.swift", "make_icon.swift")   # o @main do app e o script do ícone


@unittest.skipUnless(shutil.which("swiftc"), "precisa do swiftc (Xcode)")
class LgDeafControlServerTest(unittest.TestCase):
    def test_tv_on_with_a_deaf_control_server(self):
        sources = sorted(str(p) for p in APP.glob("*.swift") if p.name not in NOT_APP)
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "deaf_check"
            build = subprocess.run(
                ["swiftc", "-parse-as-library", *sources, str(ROOT / "tests/swift/DeafTVCheck.swift"),
                 "-o", str(binary)],
                capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr[-3000:])
            # O app lê e grava a configuração em ~/.config: aqui, numa pasta vazia
            home = Path(tmp) / "home"
            home.mkdir()
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120,
                                 env={**os.environ, "CFFIXED_USER_HOME": str(home)})
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertNotIn("FALHA", run.stdout)


if __name__ == "__main__":
    unittest.main()
