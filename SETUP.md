# Full setup — server + GUI + hotkey

The [README](./README.md) covers the transcription server on its own. This document covers the
**whole system**: the dockerized server, the OpenWhispr GUI, the wrapper that ties them together,
and the global hotkey that starts and stops dictation.

Verified end to end on two machines:

| | Laptop (`OMEN`) | Desktop (`uburez`) |
|---|---|---|
| OS | Ubuntu 24.04.4, GNOME 46, X11 | Ubuntu 24.04.1, GNOME 46, X11 |
| GPU | GTX 1080 (Pascal) | RTX 4090 (Ada) |
| `COMPUTE_TYPE` | `int8` | `float16` |
| OpenWhispr | 1.6.7 | 1.9.2 |
| Hotkey mechanism | Electron `globalShortcut` | GNOME keybinding → D-Bus |

---

## 1. How the pieces fit

```
   press Control+Alt+Z
        │
        ▼
   GNOME custom keybinding  ──dbus-send──►  OpenWhispr GUI (Electron AppImage)
   (v1.9.x; see §5)                         /opt/openwhispr/openwhispr
                                            records mic, shows on-screen indicator
        │
        │  POST multipart audio → http://localhost:8080/audio/transcriptions
        ▼
   transcription server (this repo, docker compose)
   container openwhispr-server, FastAPI, GPU via the nvidia runtime
   model loaded ONCE at container start from MODEL= in .env
        │
        │  {"text": "..."}
        ▼
   GUI types the text into the focused window,
   logs a row to ~/.config/open-whispr/transcriptions.db

   /usr/local/bin/openwhispr                       wrapper: starts/stops both halves
   ~/.local/share/applications/openwhispr.desktop  openwhispr:// handler (needed for SSO)
```

**The model that runs is the one in `.env`, not the one in the GUI.** The server's endpoints
accept a `model` form field and then ignore it — `_handle()` is called without it. Whatever the
GUI sends is cosmetic. To actually change models, edit `MODEL=` here and
`docker compose up -d`.

Server routes: `GET /health`, `GET /v1/models`, and three equivalent transcription endpoints —
`POST /v1/audio/transcriptions`, `POST /audio/transcriptions` (**the one the GUI calls**), and
`POST /inference`. Anything else logs `UNMATCHED …` and 404s; those lines are normal.

---

## 2. Prerequisites

```bash
echo $XDG_SESSION_TYPE          # x11 or wayland — see §5 for which you need
id -nG | grep -q docker && echo "docker group OK"   # else: sudo usermod -aG docker $USER, then re-login
docker info | grep -i runtime   # must list: nvidia
command -v notify-send curl     # the wrapper needs both
```

---

## 3. Server first

Nothing downstream matters until this returns ok.

```bash
git clone --recurse-submodules https://github.com/chrisdreid/openwhispr-docker.git
cd openwhispr-docker
./setup.sh
docker compose up -d
curl -s http://127.0.0.1:8080/health     # {"status":"ok","model":"turbo","device":"cuda"}
```

Allow ~2 minutes on first start — the healthcheck `start_period` is 120 s to cover model load,
and the model downloads from HuggingFace on first use.

> **If you cloned without `--recurse-submodules`**, `multi-model-audio-transcript-server/` will be
> empty and the build fails with `"/multi-model-audio-transcript-server/transcribe.py": not found`.
> Fix with `git submodule update --init`.

Set `COMPUTE_TYPE` in `.env` for your GPU — this is the one server setting that does not port
between machines:

| GPU generation | `COMPUTE_TYPE` |
|---|---|
| Pascal (GTX 10xx) | `int8` — no usable fp16 |
| Turing (RTX 20xx) | `float16` or `int8_float16` |
| Ampere / Ada (RTX 30xx, 40xx) | `float16` |
| CPU only | `int8` |

---

## 4. GUI, wrapper, URL handler

**4a. AppImage.** The symlink must be exactly `/opt/openwhispr/openwhispr` — the wrapper
hardcodes that path, which is what makes upgrades a matter of dropping in a new AppImage and
repointing the symlink.

```bash
V=1.9.2
sudo mkdir -p /opt/openwhispr && cd /opt/openwhispr
sudo curl -L -O "https://github.com/OpenWhispr/openwhispr/releases/download/v${V}/OpenWhispr-${V}-linux-x86_64.AppImage"
sudo chmod +x "OpenWhispr-${V}-linux-x86_64.AppImage"
sudo ln -sfn "OpenWhispr-${V}-linux-x86_64.AppImage" openwhispr
```

**4b. Wrapper.** Overwrites a file in `/usr/local/bin` — inspect first if one exists.

```bash
cd /path/to/openwhispr-docker
diff /usr/local/bin/openwhispr ./openwhispr-wrapper.sh 2>/dev/null
sudo cp /usr/local/bin/openwhispr /usr/local/bin/openwhispr.bak 2>/dev/null || true
sudo install -m 755 ./openwhispr-wrapper.sh /usr/local/bin/openwhispr
```

The wrapper finds the compose project via, in order: `$WHISPR_COMPOSE_DIR` in the environment →
the path inside `~/.config/openwhispr-docker/compose-dir` → `~/docker/openwhispr-docker`.

If your repo lives elsewhere, use the config file rather than exporting the variable in
`~/.bashrc` — **the `.desktop` launcher does not inherit an interactive shell's environment**:

```bash
mkdir -p ~/.config/openwhispr-docker
echo "/path/to/openwhispr-docker" > ~/.config/openwhispr-docker/compose-dir
```

When this path is wrong the GUI still launches fine, but container auto-start and
`openwhispr --stop`'s `docker compose down` both silently no-op, and `PORT` falls back to 8080
instead of being read from `.env`. With `restart: unless-stopped` on the container, that can stay
invisible for a long time.

**4c. URL handler — required, not optional.** This registers the `openwhispr://` scheme.
**Account sign-in (Google SSO) uses an `openwhispr://` OAuth callback and cannot complete without
it.**

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/openwhispr.desktop <<'EOF'
[Desktop Entry]
Name=OpenWhispr
Exec=/usr/local/bin/openwhispr %u
Terminal=false
Type=Application
MimeType=x-scheme-handler/openwhispr;
EOF
update-desktop-database ~/.local/share/applications
xdg-mime query default x-scheme-handler/openwhispr    # -> openwhispr.desktop
```

This is a URL handler, not an app-grid launcher and not an autostart entry. Day-to-day launching
is `openwhispr` from a terminal, and **nothing grabs the hotkey until the app is running.**

---

## 5. The hotkey — mechanism changed in 1.9.x

**This is the biggest difference between versions. Check which one you have.**

### v1.9.x — GNOME keybinding + D-Bus

The app creates a GNOME custom keybinding that pokes it over D-Bus:

```
name      'OpenWhispr Toggle'
command   'dbus-send --session --type=method_call --dest=com.openwhispr.App
           /com/openwhispr/App com.openwhispr.App.Toggle'
binding   'F8'          ← default; change to your preference
```

GNOME owns the grab, not Electron. **This works under Wayland as well as X11.**

Inspect or repair it directly:

```bash
P=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/openwhispr/
S=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$P
gsettings get $S binding
gsettings set $S binding '<Control><Alt>z'
```

Prefer setting it in the app's own UI so the app's stored value and the GNOME binding agree;
change gsettings directly only to repair drift.

### v1.6.x — Electron `globalShortcut`

Registered in-process by the app; `gsettings ... custom-keybindings` stays `@as []`.
**X11 is mandatory** — Electron cannot reliably grab global keys under Wayland, where the
compositor owns shortcuts. The failure is silent: everything looks installed, the key just never
fires. Pick "Ubuntu on Xorg" at the GDM gear menu and confirm with `echo $XDG_SESSION_TYPE`.

### Choosing a combination

| | |
|---|---|
| Dictation | `Control+Alt+Z` |
| Agent | `Control+Alt+A` |
| Activation mode | `tap` — press to start, press again to stop (not push-to-talk) |

**Avoid `Control+Shift+Z`.** It is *redo* in browsers, VS Code, GIMP, Photoshop and most editors.
A global grab intercepts it before any application sees it, silently breaking redo system-wide.
The GUI's key capture can register Shift when you meant Alt — always verify with
`gsettings get` afterwards.

Check for conflicts before committing to a combination:

```bash
{ gsettings list-recursively org.gnome.settings-daemon.plugins.media-keys
  gsettings list-recursively org.gnome.desktop.wm.keybindings
  gsettings list-recursively org.gnome.shell.keybindings
  gsettings list-recursively org.gnome.mutter.keybindings
} 2>/dev/null | grep -iE "<control><alt>z"
```

---

## 6. App settings

First launch: `openwhispr`. Complete onboarding and grant microphone access.

**Sign-in is optional.** It gates the OpenWhispr *account* (cloud/pro features). Local dictation
is BYOK pointed at your own server and sends no credential, so skipping sign-in does not affect
the pipeline.

| Setting | Value | Note |
|---|---|---|
| Transcription mode | `byok` | |
| Provider | `custom` | |
| **Base URL** | **`http://localhost:8080`** | `127.0.0.1` works equally |
| Model name | `turbo` | cosmetic — the server ignores it (§1) |
| API key | *(empty)* | local server needs none |
| **Use local Whisper** | **off** | ⚠️ if on, the app downloads a ~686 MB local binary and transcribes in-process, bypassing this server entirely |
| Dictation hotkey | `Control+Alt+Z` | |
| Activation mode | `tap` | |

> **Known cosmetic issue (1.9.2):** the app requests `GET /models`, but the server implements
> `GET /v1/models`. The request 404s and logs `UNMATCHED GET /models`, so the model dropdown may
> appear empty. Transcription is unaffected — it posts to `/audio/transcriptions`. Type the model
> name manually.

---

## 7. Verify end to end

```bash
curl -s http://127.0.0.1:8080/health            # {"status":"ok",...}
curl -s http://127.0.0.1:8080/v1/models | jq -r '.data[].id'
grep -A9 'Resolved in order' /usr/local/bin/openwhispr
xdg-mime query default x-scheme-handler/openwhispr

openwhispr                                       # launch, then press Control+Alt+Z, speak, press again

# did the round trip reach the local server?
docker compose logs --tail 20 whispr | grep POST
sqlite3 "file:$HOME/.config/open-whispr/transcriptions.db?mode=ro" \
  "select id,timestamp,provider,model,status from transcriptions order by id desc limit 3;"

openwhispr --stop && docker ps --filter name=openwhispr-server   # GUI dies AND container comes down
```

A successful dictation is a row with `status=completed` and a non-empty `provider`. Rows with
empty `provider`/`model` and `status=failed` are what a broken base URL looks like.

---

## 8. What does not port between machines

- **`COMPUTE_TYPE`** — per GPU generation (§3). The only intentional `.env` divergence.
- **`MODEL` / VRAM sizing** — a smaller card may need `small` or `base`; a larger one affords `large-v3`.
- **Hotkey mechanism** — version-dependent (§5).
- **Repo path** — use `~/.config/openwhispr-docker/compose-dir` (§4b).
- **`BIND_HOST=127.0.0.1`** — fine while GUI and server share a machine. Pointing a remote GUI at
  this server means `0.0.0.0`, an opened port, and **an unauthenticated transcription endpoint on
  your LAN**. Gate it if you go there.
- **Default audio input** — named by PCI address, machine-specific. Set it in GNOME Settings → Sound.
- **The app profile `~/.config/open-whispr/`** — **do not copy between machines.** It holds a
  signed-in session JWT in `Local Storage/leveldb`, plus your recordings and Chromium state.
  `~/.config/open-whispr/.env` holds `DICTATION_KEY` / `AGENT_KEY`, which despite the names are
  **keyboard shortcuts, not API keys**.

---

## 9. Troubleshooting

| Symptom | Cause |
|---|---|
| **Hotkey does nothing, no error** | v1.6.x under Wayland (§5) — log into Xorg. Or the app isn't running (there is no autostart). Or another app owns the combination — Electron fails the grab silently. |
| **Google SSO never completes** | `openwhispr://` handler not registered (§4c). |
| **Container doesn't auto-start; `--stop` leaves it up** | `WHISPR_COMPOSE_DIR` wrong (§4b). Confirm with `WHISPR_COMPOSE_DIR=/path/to/repo openwhispr`. |
| **GUI opens, transcription fails** | Check base URL, then `/health`. `docker compose logs -f whispr` shows every request; `UNMATCHED POST /…` means the app called a path the server lacks. |
| **Model dropdown empty** | `GET /models` vs `GET /v1/models` (§6). Cosmetic. |
| **Wrong model despite changing it in the GUI** | The GUI cannot select the model. Edit `MODEL=` in `.env`, then `docker compose up -d` (§1). |
| **Build: `transcribe.py not found`** | Submodule not initialised — `git submodule update --init` (§3). |
| **`could not select device driver "nvidia"`** | Install `nvidia-container-toolkit`, restart Docker. |
| **CUDA OOM or unexpectedly slow** | Wrong `COMPUTE_TYPE` for the GPU, or too large a `MODEL`. |
| **`unhealthy` for the first two minutes** | Expected — `start_period` is 120 s. |
| **Parakeet runs on CPU despite `DEVICE=cuda`** | Expected — the PyPI `sherpa-onnx` wheel has no CUDA support. Only Whisper uses the GPU. |
