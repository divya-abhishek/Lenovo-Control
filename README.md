# Lenovo Control

A small always-on-top widget for Lenovo Legion and IdeaPad laptops: charging
mode, keyboard lighting and Fn Lock, with a live battery gauge in the system
tray.

It talks to the hardware directly. **No Lenovo Vantage, no Legion Toolkit, no
background service required.**

---

## Files

| File | What it is |
|---|---|
| `Lenovo_Control.ps1` | The widget itself. Everything lives in this one file. |
| `Lenovo_Control.bat` | Launcher — elevates, then starts the widget. Use this if you don't build the .exe. |
| `Build_Lenovo_Control_Exe.bat` | One-time: compiles the .ps1 into `Lenovo_Control.exe`. |
| `Startup_Setup.bat` | Optional: enable/disable "start at logon" from outside the app. |
| `Lenovo_Control_Icon.ico` | App icon, embedded into the .exe by the build script. |
| `Lenovo_Control_Icon.svg` | Vector source for the icon. |

---

## Setup

Put every file in one folder, then either:

**Option A — build a real .exe (recommended)**

1. Run `Build_Lenovo_Control_Exe.bat` once. It installs `ps2exe` from the
   PowerShell Gallery and compiles the widget.
2. Run `Lenovo_Control.exe`. It elevates itself.
3. Optional: right-click it → Pin to taskbar.

**Option B — run the script directly**

Double-click `Lenovo_Control.bat`.

Administrator is required either way: the Lenovo energy driver cannot be
opened without it, so charging mode and Fn Lock would silently do nothing.

---

## Using it

- The battery percentage sits in the **system tray**, next to the clock.
- **Click the tray icon** to open or close the panel.
- **Right-click the tray icon** for Show / Exit.
- Drag the panel by its title bar. The pin keeps it above other windows.
- Closing with `X` hides to the tray; Exit on the tray menu quits properly.

### Settings (inside the panel)

- **Start with Windows** — creates an elevated logon task, so there's no UAC
  prompt every boot. It starts minimised to the tray.
- **Always show in tray** — asks Windows to keep the icon beside the clock
  rather than inside the hidden-icons arrow.

---

## What adapts to your laptop

Nothing is hard-coded to a model list. At startup the widget *asks the
hardware* what it supports and shows only what answers:

| Feature | How it is detected |
|---|---|
| Charging mode | Energy driver responds to the battery IOCTL |
| Fn Lock | Energy driver responds to the settings IOCTL |
| Keyboard lighting | HID feature-report **length** decides the type |

Keyboard type comes from the report length rather than the USB product ID,
because Lenovo has shipped many IDs but the length has stayed constant:

- **33 bytes** → 4-zone RGB (zone selector, effects, brightness)
- **960 bytes** → per-key Spectrum (target groups, effects, brightness)
- neither, but the energy driver answers → single-colour backlight (Off/Low/High)
- nothing answers → the card explains, and lists every Lenovo USB device seen

**Rapid Charge** is not on every model. There is no documented capability bit
to read up front, so the widget finds out the first time you use it: if the
mode refuses to take, the button is disabled and the finding is remembered.

---

## Colours in the tray icon

| Colour | Meaning |
|---|---|
| Green | Charging |
| Blue | Plugged in but not charging (usually Conservation holding it) |
| Crimson | On battery |
| Amber | 30% or below |
| Red | 15% or below |

---

## If something doesn't work

The widget is built to tell you when it fails rather than pretend it worked.

- **Lighting says "no keyboard"** — the panel lists every Lenovo USB interface
  it found, with its report length. That line is enough to widen the match.
- **Fn Lock says the model ignored it** — it reports the raw driver value. The
  first toggle also measures which bit actually changed and adapts to it.
- **A charging mode doesn't stick** — Lenovo Vantage, if installed and running,
  re-applies its own setting. Close it. The widget writes Lenovo's registry
  value too, which normally prevents this.
- **Lighting write rejected** — Vantage holds exclusive control of the
  keyboard. Close it and try again.

---

## Credits

Hardware protocols were taken from open-source projects that reverse-engineered
them, not guessed:

- [LenovoLegionToolkit](https://github.com/BartoszCichecki/LenovoLegionToolkit) —
  battery mode, Fn Lock, RGB keyboard
- [4JX/L5P-Keyboard-RGB](https://github.com/4JX/L5P-Keyboard-RGB) — 4-zone
  33-byte report layout
- [Triangle-GitHub/LegionLaptopToolkitCLI](https://github.com/Triangle-GitHub/LegionLaptopToolkitCLI) —
  single-colour backlight, energy driver IOCTLs
- [alstergee/legion-spectrum-control](https://github.com/alstergee/legion-spectrum-control) —
  Spectrum per-key protocol
