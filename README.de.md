# aud_midi_windows

Das Windows-Backend von aud_midi: Windows.Devices.Midi und, falls vorhanden, Windows MIDI Services über einen C++/WinRT-Shim.

Teil der aud_midi-Familie, siehe [aud_midi](https://github.com/audanika/aud_midi).

## Ziele

- Windows.Devices.Midi-Ports und DeviceWatcher-Hotplug
- Windows MIDI Services (Midi2) zur Laufzeit erkannt
- C++/WinRT-Shim, gebaut per Hook
- Advertising über DnsServiceRegister

## Stand

Nur Boilerplate. Die Implementierung folgt in späteren Tickets, siehe den Plan in [aud_midi](https://github.com/audanika/aud_midi/blob/main/blog/2026/10/01_plan_the_package_implementation.md).

## Installation

```bash
dart pub add aud_midi_windows
```

## Mitwirken

Siehe [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
