# aud_midi_windows

The Windows backend of aud_midi: Windows.Devices.Midi and, when present, Windows MIDI Services, through a C++/WinRT shim.

Part of the aud_midi family, see [aud_midi](https://github.com/audanika/aud_midi).

## Goals

- Windows.Devices.Midi ports and DeviceWatcher hotplug
- Windows MIDI Services (Midi2) detected at runtime
- C++/WinRT shim built by a hook
- Advertising via DnsServiceRegister
- BLE peripheral through GattServiceProvider

## State

Boilerplate only. The implementation follows in later tickets, see the plan in [aud_midi_pm](https://github.com/audanika/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md).

## Installation

```bash
dart pub add aud_midi_windows
```

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
