"""Prova a orquestração de ligar a TV (TV Box + fallback PS5) sem efeitos colaterais fantasmas.

Cobre:
- cancelamento imediato do fluxo de ligar (sem acordar nem reiniciar o PS5 em background) quando a
  TV responde na porta 8080 durante a tentativa da TV Box, durante o wake do PS5 (inclusive via
  refreshStatus 401 -> re-pareamento -> 200) ou no meio da navegação de Uso remoto;
- propagação do IP DHCP atualizado do PS5 para o PlayStationRestart (--host <ip> no ps5ctl) e
  execução do relogin pós-boot para não deixar o console deslogado na tela de boas-vindas;
- filtro de endereços transitórios (0.0.0.0 / link-local) e diagnóstico claro quando ambos os
  aparelhos auxiliares estão fora da rede / desligados por completo.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "mac_app"
NOT_APP = ("AppMain.swift", "make_icon.swift")


@unittest.skipUnless(shutil.which("swiftc"), "precisa do swiftc (Xcode)")
class LgTurnOnFlowTest(unittest.TestCase):
    def test_turn_on_cancellation_dhcp_sync_and_post_boot_relogin(self):
        sources = sorted(str(p) for p in APP.glob("*.swift") if p.name not in NOT_APP)
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "turn_on_flow_check"
            build = subprocess.run(
                ["swiftc", "-parse-as-library", *sources, str(ROOT / "tests/swift/TurnOnFlowCheck.swift"),
                 "-o", str(binary)],
                capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr[-3000:])
            home = Path(tmp) / "home"
            home.mkdir()
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60,
                                 env={**os.environ, "CFFIXED_USER_HOME": str(home)})
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertNotIn("FALHA", run.stdout)


if __name__ == "__main__":
    unittest.main()
