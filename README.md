# aud_midi_windows

The Windows backend of aud_midi: Windows.Devices.Midi and, when present, Windows MIDI Services, through a C++/WinRT shim.

Part of the aud_midi family, see [aud_midi](https://github.com/audanika/aud_midi).

## Goals

- Windows.Devices.Midi ports and DeviceWatcher hotplug
- Windows MIDI Services (Midi2) detected at runtime
- C++/WinRT shim built by a hook
- Advertising via DnsServiceRegister

## State

Boilerplate only. The implementation follows in later tickets, see the plan in [aud_midi](https://github.com/audanika/aud_midi/blob/main/blog/2026/10/01_plan_the_package_implementation.md).

## Installation

```bash
dart pub add aud_midi_windows
```

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
