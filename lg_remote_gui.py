#!/usr/bin/env python3
"""
lg_remote_gui.py - Interface gráfica desktop em Python/Tkinter para o controle remoto da TV LG NetCast.
Compatível com macOS, sem necessidade de pacotes externos (apenas biblioteca padrão Python).
"""

import sys
import os
import threading
import time
from pathlib import Path

# Suprime o aviso de depreciação do Tk no macOS
os.environ["TK_SILENCE_DEPRECATION"] = "1"

try:
    import tkinter as tk
    from tkinter import ttk, messagebox
except ImportError:
    print("Erro: tkinter não está disponível neste Python.", file=sys.stderr)
    sys.exit(1)

# Importa a biblioteca base do projeto
sys.path.insert(0, str(Path(__file__).parent))
try:
    from lg_roap_control import LGNetCastTV, load_config, save_config, KEYS, TVError
except ImportError as e:
    print(f"Erro ao importar lg_roap_control: {e}", file=sys.stderr)
    sys.exit(1)


class LGRemoteGUI:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Controle LG")
        self.root.geometry("340x740")
        self.root.resizable(False, False)
        self.root.configure(bg="#161618")

        self.cfg = load_config()
        self.tv = None
        self.lock = threading.Lock()
        self.min_gap = 0.30
        self.last_send = 0.0

        self.is_connected = False
        self.volume_level = 10
        self.is_muted = False
        self.current_source = "---"
        self.status_text = tk.StringVar(value="Iniciando...")
        self.header_text = tk.StringVar(value=self.cfg.get("model", "LG NetCast"))
        self.vol_src_text = tk.StringVar(value="Vol: ? | Fonte: ---")

        self.setup_ui()
        self.setup_keyboard()
        self.init_tv()

    def init_tv(self):
        host = self.cfg.get("host", "192.0.2.100")
        key = self.cfg.get("pairing_key", "")
        proto = self.cfg.get("protocol", "roap")
        session = self.cfg.get("session")
        self.tv = LGNetCastTV(host=host, pairing_key=key, protocol=proto, session=session)

        threading.Thread(target=self.refresh_status, daemon=True).start()
        # Polling a cada 10 segundos
        self.schedule_poll()

    def schedule_poll(self):
        self.root.after(10000, self._poll_task)

    def _poll_task(self):
        threading.Thread(target=self.refresh_status, daemon=True).start()
        self.schedule_poll()

    def setup_ui(self):
        pad_x = 12

        # Header Frame
        header_frame = tk.Frame(self.root, bg="#202024", highlightbackground="#303036", highlightthickness=1)
        header_frame.pack(fill=tk.X, padx=pad_x, pady=(12, 8))

        top_line = tk.Frame(header_frame, bg="#202024")
        top_line.pack(fill=tk.X, padx=8, pady=(6, 2))

        self.led = tk.Canvas(top_line, width=10, height=10, bg="#202024", highlightthickness=0)
        self.led.pack(side=tk.LEFT, padx=(2, 6))
        self.led_id = self.led.create_oval(1, 1, 9, 9, fill="#f44", outline="")

        title_lbl = tk.Label(top_line, textvariable=self.header_text, font=("SF Pro Display", 12, "bold"), fg="#eee", bg="#202024")
        title_lbl.pack(side=tk.LEFT)

        refresh_btn = tk.Button(top_line, text="↻", font=("SF Pro Display", 11, "bold"), fg="#aaa", bg="#2a2a2e",
                                activebackground="#3a3a40", activeforeground="#fff", relief=tk.FLAT, bd=0,
                                command=lambda: threading.Thread(target=self.refresh_status, daemon=True).start())
        refresh_btn.pack(side=tk.RIGHT, padx=2)

        sub_line = tk.Frame(header_frame, bg="#202024")
        sub_line.pack(fill=tk.X, padx=8, pady=(2, 6))

        vol_lbl = tk.Label(sub_line, textvariable=self.vol_src_text, font=("SF Pro Text", 10), fg="#8fd", bg="#202024")
        vol_lbl.pack(side=tk.LEFT)

        # Top Buttons Frame (Power, Input, 123)
        top_btn_frame = tk.Frame(self.root, bg="#161618")
        top_btn_frame.pack(fill=tk.X, padx=pad_x, pady=4)

        power_btn = tk.Button(top_btn_frame, text="⏻ Power", font=("SF Pro Text", 11, "bold"), fg="#fff", bg="#c32",
                              activebackground="#e43", activeforeground="#fff", relief=tk.FLAT, bd=0, height=2,
                              command=self.confirm_power)
        power_btn.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 4))

        input_btn = self.create_btn(top_btn_frame, "Entrada", "input", height=2)
        input_btn.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)

        self.numpad_visible = False
        self.numpad_toggle = tk.Button(top_btn_frame, text="123", font=("SF Pro Text", 11, "bold"), fg="#ddd", bg="#28282e",
                                       activebackground="#3a3a42", activeforeground="#fff", relief=tk.FLAT, bd=0, height=2,
                                       command=self.toggle_numpad)
        self.numpad_toggle.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(4, 0))

        # Numpad Frame (collapsible)
        self.numpad_frame = tk.Frame(self.root, bg="#1c1c20", highlightbackground="#303036", highlightthickness=1)
        self.setup_numpad()

        # D-Pad Frame
        dpad_container = tk.Frame(self.root, bg="#1e1e22", highlightbackground="#2e2e34", highlightthickness=1)
        dpad_container.pack(fill=tk.X, padx=pad_x, pady=8)

        # Row above D-Pad
        row_above = tk.Frame(dpad_container, bg="#1e1e22")
        row_above.pack(fill=tk.X, padx=6, pady=(6, 4))
        self.create_btn(row_above, "Q.Menu", "quick_menu", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
        home_btn = self.create_btn(row_above, "⌂ Home", "home", bg="#1b4a78", fg="#fff", height=1)
        home_btn.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
        self.create_btn(row_above, "Menu", "menu", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)

        # Center D-Pad
        dpad_center = tk.Frame(dpad_container, bg="#1e1e22")
        dpad_center.pack(pady=6)

        up_btn = self.create_btn(dpad_center, "▲", "up", width=6, height=2)
        up_btn.grid(row=0, column=1, pady=2)

        left_btn = self.create_btn(dpad_center, "◀", "left", width=6, height=2)
        left_btn.grid(row=1, column=0, padx=2)

        ok_btn = self.create_btn(dpad_center, "OK", "ok", bg="#16528e", fg="#fff", width=6, height=2)
        ok_btn.grid(row=1, column=1, padx=2, pady=2)

        right_btn = self.create_btn(dpad_center, "▶", "right", width=6, height=2)
        right_btn.grid(row=1, column=2, padx=2)

        down_btn = self.create_btn(dpad_center, "▼", "down", width=6, height=2)
        down_btn.grid(row=2, column=1, pady=2)

        # Row below D-Pad
        row_below = tk.Frame(dpad_container, bg="#1e1e22")
        row_below.pack(fill=tk.X, padx=6, pady=(4, 6))
        self.create_btn(row_below, "↩ Voltar", "back", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
        self.create_btn(row_below, "✕ Sair", "exit", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
        self.create_btn(row_below, "Guia", "epg", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)

        # Rockers Frame (Volume & Channel)
        rockers_frame = tk.Frame(self.root, bg="#161618")
        rockers_frame.pack(fill=tk.X, padx=pad_x, pady=6)

        # Vol rocker
        vol_box = tk.Frame(rockers_frame, bg="#24242a", highlightbackground="#36363e", highlightthickness=1)
        vol_box.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, padx=(0, 4))
        self.create_btn(vol_box, "+ VOL", "volume_up", height=2).pack(fill=tk.X, padx=2, pady=2)
        self.create_btn(vol_box, "- VOL", "volume_down", height=2).pack(fill=tk.X, padx=2, pady=2)

        # Center stack (Mute, Live TV)
        mid_stack = tk.Frame(rockers_frame, bg="#161618")
        mid_stack.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, padx=2)
        self.mute_btn = self.create_btn(mid_stack, "Mute", "mute", height=2)
        self.mute_btn.pack(fill=tk.X, pady=(0, 3))
        self.create_btn(mid_stack, "Live TV", "live_tv", height=2).pack(fill=tk.X, pady=(3, 0))

        # Channel rocker
        ch_box = tk.Frame(rockers_frame, bg="#24242a", highlightbackground="#36363e", highlightthickness=1)
        ch_box.pack(side=tk.LEFT, expand=True, fill=tk.BOTH, padx=(4, 0))
        self.create_btn(ch_box, "+ CH", "channel_up", height=2).pack(fill=tk.X, padx=2, pady=2)
        self.create_btn(ch_box, "- CH", "channel_down", height=2).pack(fill=tk.X, padx=2, pady=2)

        # Smart keys row
        smart_row = tk.Frame(self.root, bg="#161618")
        smart_row.pack(fill=tk.X, padx=pad_x, pady=4)
        self.create_btn(smart_row, "Apps", "apps", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
        self.create_btn(smart_row, "3D", "3d", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
        self.create_btn(smart_row, "Formato", "aspect_ratio", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
        self.create_btn(smart_row, "SIMPLINK", "simplink", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)

        # Media controls row
        media_row = tk.Frame(self.root, bg="#161618")
        media_row.pack(fill=tk.X, padx=pad_x, pady=4)
        self.create_btn(media_row, "⏪", "rewind", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
        self.create_btn(media_row, "▶", "play", bg="#1a5a2e", fg="#fff", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
        self.create_btn(media_row, "⏸", "pause", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
        self.create_btn(media_row, "⏹", "stop", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)
        self.create_btn(media_row, "⏩", "fast_forward", height=1).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=1)

        # Color keys row
        color_row = tk.Frame(self.root, bg="#161618")
        color_row.pack(fill=tk.X, padx=pad_x, pady=6)
        tk.Button(color_row, bg="#d33", activebackground="#f44", relief=tk.FLAT, bd=0, height=1,
                  command=lambda: self.press_key("red")).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
        tk.Button(color_row, bg="#293", activebackground="#3b4", relief=tk.FLAT, bd=0, height=1,
                  command=lambda: self.press_key("green")).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
        tk.Button(color_row, bg="#db2", activebackground="#ec3", relief=tk.FLAT, bd=0, height=1,
                  command=lambda: self.press_key("yellow")).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)
        tk.Button(color_row, bg="#26d", activebackground="#38f", relief=tk.FLAT, bd=0, height=1,
                  command=lambda: self.press_key("blue")).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)

        # Footer Status
        status_lbl = tk.Label(self.root, textvariable=self.status_text, font=("SF Pro Text", 10), fg="#aaa", bg="#161618")
        status_lbl.pack(pady=(4, 2))

        hint_lbl = tk.Label(self.root, text="Atalhos: Setas | Enter | Esc | + - | m", font=("SF Pro Text", 8), fg="#666", bg="#161618")
        hint_lbl.pack(pady=(0, 8))

    def setup_numpad(self):
        pad = 3
        for r, row in enumerate([("1", "2", "3"), ("4", "5", "6"), ("7", "8", "9"), ("previous_channel", "0", "info")]):
            row_frame = tk.Frame(self.numpad_frame, bg="#1c1c20")
            row_frame.pack(fill=tk.X, padx=6, pady=pad)
            for key in row:
                label = "Canal ↩" if key == "previous_channel" else ("Info" if key == "info" else key)
                b = self.create_btn(row_frame, label, key, height=1)
                b.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=2)

    def toggle_numpad(self):
        if self.numpad_visible:
            self.numpad_frame.pack_forget()
            self.numpad_toggle.configure(bg="#28282e")
            self.numpad_visible = False
        else:
            self.numpad_frame.pack(after=self.root.children["!frame2"], fill=tk.X, padx=12, pady=4)
            self.numpad_toggle.configure(bg="#1b4a78")
            self.numpad_visible = True

    def create_btn(self, parent, text: str, key_name: str, bg="#28282e", fg="#eee", width=None, height=1):
        def on_click():
            self.press_key(key_name)
        b = tk.Button(parent, text=text, font=("SF Pro Text", 10, "bold"), fg=fg, bg=bg,
                      activebackground="#44444c", activeforeground="#fff", relief=tk.FLAT, bd=0,
                      width=width, height=height, command=on_click)
        return b

    def setup_keyboard(self):
        keymap = {
            "<Up>": "up", "<Down>": "down", "<Left>": "left", "<Right>": "right",
            "<Return>": "ok", "<KP_Enter>": "ok",
            "<BackSpace>": "back", "<Escape>": "back",
            "+": "volume_up", "=": "volume_up", "-": "volume_down", "_": "volume_down",
            "m": "mute", "M": "mute",
            "]": "channel_up", "[": "channel_down",
            "<Prior>": "channel_up", "<Next>": "channel_down",
            "h": "home", "H": "home", "i": "input", "I": "input", "x": "exit", "X": "exit",
            "<space>": "play",
        }
        for d in "0123456789":
            keymap[d] = d

        for event_key, tv_key in keymap.items():
            self.root.bind(event_key, lambda e, k=tv_key: self.press_key(k))

    def press_key(self, key_name: str):
        threading.Thread(target=self._send_thread, args=(key_name,), daemon=True).start()

    def _send_thread(self, key_name: str):
        if not self.tv:
            return
        code = KEYS.get(key_name)
        if code is None:
            return

        with self.lock:
            wait = self.min_gap - (time.monotonic() - self.last_send)
            if wait > 0:
                time.sleep(wait)
            self.last_send = time.monotonic()

            self.root.after(0, lambda: self.status_text.set(f"Enviando {key_name}..."))
            try:
                self.tv.send_key(code)
                self.root.after(0, lambda: self.status_text.set(f"{key_name} ok"))
                if key_name in ("volume_up", "volume_down", "mute"):
                    time.sleep(0.35)
                    self.refresh_status()
            except TVError as e:
                self.root.after(0, lambda: self.status_text.set(f"Erro: {e}"))

    def refresh_status(self):
        if not self.tv:
            return
        try:
            vol = self.tv.query("volume_info")
            ch = self.tv.query("cur_channel")
            self.is_connected = True
            lvl = vol.get("level", "?")
            mute = vol.get("mute") == "true"
            src = ch.get("inputSourceName") or (f"Canal {ch.get('major')}" if ch.get("major") != "65520" else "TV")

            def update_ui():
                self.led.itemconfig(self.led_id, fill="#3d5")
                mute_str = " (Mudo)" if mute else ""
                self.vol_src_text.set(f"Vol: {lvl}{mute_str}  |  {src}")
                self.mute_btn.configure(bg="#852" if mute else "#28282e")

            self.root.after(0, update_ui)
        except Exception as e:
            self.is_connected = False
            def mark_offline():
                self.led.itemconfig(self.led_id, fill="#e33")
                self.status_text.set("TV desconectada")
            self.root.after(0, mark_offline)

    def confirm_power(self):
        if messagebox.askyesno("Power", "Desligar a TV? Ela normalmente não liga de novo pela rede."):
            self.press_key("power")


def main():
    root = tk.Tk()
    app = LGRemoteGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
