# OmaTiel

An Omarchy shell bar widget for the **Tiel-Coder-35B-A3B local LLM**
(llama.cpp `llama-server` on a tuned 262k-context + MTP configuration):

- **On/off from the bar** — left-click opens the panel, right-click toggles
  the service (or use the panel switch, or keys `s`/`x`).
- Shows **service state, served model, context window and VRAM use**.
- Controls the existing `tiel-coder.service` **user systemd unit** — the
  plugin never creates or edits units, never sudo, no polkit.

The tuned llama.cpp configuration itself (context, `--n-cpu-moe`, MTP
draft head, KV cache quant) lives in
`~/.config/systemd/user/tiel-coder.service` — see `Reference/Local_LLM.md`
in the house vault for the measured values. This widget is only the
switch + status surface.

## Install

```sh
omarchy plugin add https://github.com/LinuxGamerUK/omatiel.git --enable
```

Requires the `tiel-coder.service` user unit to exist. Without it the
widget shows "No service" with a pointer to where the unit comes from;
nothing else breaks.

## Usage

- **Click** the bar icon to open the panel
- **Toggle switch** to start/stop `tiel-coder.service`
- **Right-click** the bar icon toggles the service without the panel
- **Middle-click** refreshes

The panel shows: state (running / stopped), VRAM used/total, served
model + context size, unit name and API port, plus a one-line reminder
that the tuning lives in the unit file, not the plugin.

Keyboard: `s` start · `x` stop · `r` refresh.

## Configure

```sh
# Refresh interval (default: 10 s)
omarchy bar set com.github.linuxgameruk.omatiel refreshIntervalSec 30

# systemd user unit to control (default: tiel-coder, without .service)
omarchy bar set com.github.linuxgameruk.omatiel unitName tiel-coder

# Server API port (default: 8080)
omarchy bar set com.github.linuxgameruk.omatiel port 8080
```

## Remove

```sh
omarchy plugin remove com.github.linuxgameruk.omatiel
```

The systemd unit is untouched by removal.

## Requirements

- The `tiel-coder.service` user unit (see house vault,
  `Reference/Local_LLM.md`, for the tuned ExecStart)
- systemd user services (every mainstream distro)
- NVIDIA GPUs get VRAM reporting via `nvidia-smi`; otherwise the field
  is simply hidden

## Privileges & security

- **None.** Every action is `systemctl --user`. No sudo, no pkexec, no
  polkit. The plugin never writes units or any other file.
- The plugin **never downloads or executes third-party code at
  runtime** — the only outbound calls are the local API probe
  (127.0.0.1) and `nvidia-smi`.
- All subprocess output is capped (`timeout -k 2 N` + `head -c` at the
  OS pipe + QML watchdog timers); external strings are sanitized and
  rendered as `Text.PlainText`.
- The unit name from settings is validated against `[A-Za-z0-9_.@-]`
  before any use.

## License

MIT
