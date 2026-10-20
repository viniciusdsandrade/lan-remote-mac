#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Controle Remoto LG"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"
# Instalado fora da Mesa: o macOS protege essa pasta e, como cada build tem assinatura nova,
# voltava a perguntar se o app podia acessar a Mesa. Na Mesa fica só um atalho.
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
DESKTOP_LINK="$HOME/Desktop/$APP_NAME.app"

echo "==> Compilando código Swift nativo..."
swiftc -parse-as-library -O \
  "$SCRIPT_DIR/LGTVClient.swift" \
  "$SCRIPT_DIR/AndroidTVRemote.swift" \
  "$SCRIPT_DIR/TVBoxLink.swift" \
  "$SCRIPT_DIR/PlayStationRemote.swift" \
  "$SCRIPT_DIR/PlayStationLink.swift" \
  "$SCRIPT_DIR/PlayStationRestart.swift" \
  "$SCRIPT_DIR/PSNLoginView.swift" \
  "$SCRIPT_DIR/RemoteHelp.swift" \
  "$SCRIPT_DIR/RemoteComponents.swift" \
  "$SCRIPT_DIR/SettingsView.swift" \
  "$SCRIPT_DIR/RemoteView.swift" \
  "$SCRIPT_DIR/AppMain.swift" \
  -o "$SCRIPT_DIR/Controle Remoto LG"

echo "==> Montando bundle $APP_NAME.app..."
rm -rf "$APP_DIR" "$INSTALLED_APP"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/"
cp "$SCRIPT_DIR/Controle Remoto LG" "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/Controle Remoto LG"

# Sem isto o binário só tem a assinatura do linker, com o nome do arquivo como identificador, e o
# macOS o trata como outro app: perde a permissão de "Rede local", que vale para o bundle id.
echo "==> Assinando (ad-hoc) com o identificador do app..."
codesign --force --sign - "$APP_DIR"

echo "==> Instalando em ~/Applications (atalho na Mesa)..."
mkdir -p "$(dirname "$INSTALLED_APP")"
cp -R "$APP_DIR" "$INSTALLED_APP"
if [[ -d "$DESKTOP_LINK" && ! -L "$DESKTOP_LINK" ]]; then
  rm -rf "$DESKTOP_LINK"   # cópia antiga instalada direto na Mesa
fi
[[ -L "$DESKTOP_LINK" ]] || ln -s "$INSTALLED_APP" "$DESKTOP_LINK"

# No macOS 26 o Dock enquadra ícones fora do formato "squircle" numa moldura cinza; ícone
# personalizado (como o do "Obter Informações") não. Último passo: o codesign recusa o bundle depois.
echo "==> Aplicando ícone personalizado (sem moldura no Dock)..."
for app in "$APP_DIR" "$INSTALLED_APP"; do
  result=$(osascript -l JavaScript -e '
    ObjC.import("AppKit");
    function run(argv) {
      const img = $.NSImage.alloc.initWithContentsOfFile(argv[0]);
      if (img.isNil()) return "imagem inválida";
      return $.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, argv[1], 0) ? "ok" : "falhou";
    }' "$SCRIPT_DIR/AppIcon.icns" "$app" 2>&1) || true
  [[ "$result" == "ok" ]] || echo "    Aviso: ícone não aplicado em $app ($result)"
done

echo "==> Aplicativo criado com sucesso!"
echo "    Local no projeto: $APP_DIR"
echo "    Instalado em:     $INSTALLED_APP"
echo "    Atalho na Mesa:   $DESKTOP_LINK"
