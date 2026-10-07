# aud_midi_windows

The Windows backend of aud_midi: Windows.Devices.Midi and, when present,
Windows MIDI Services through a C++/WinRT shim, Bluetooth LE MIDI pairing
and DNS-SD advertising for network sessions.

Part of the aud_midi family, see [aud_midi](https://github.com/audanika/aud_midi).

## Goals

- Windows.Devices.Midi ports with receive time stamps and DeviceWatcher
  hotplug
- Windows MIDI Services (Midi2) detected at runtime: UMP, scheduling,
  virtual devices, function blocks
- C++/WinRT shim built by a hook, never blocking an STA thread
- In-app pairing of BLE-MIDI peripherals
- Advertising via DnsServiceRegister

## State

Implemented; **not yet built or run on Windows** in this ticket. All Dart
logic is tested on the Dart VM, the portable half of the shim on macOS;
the WinRT half is reviewed against the Windows SDK reference and the
Windows MIDI Services IDL, but never compiled against the real headers.

- `WindowsMidiBackend` (`MidiBackend`, name `winrt`) with
  `WindowsMidiApi.auto` (default), `midi1` or `midi2`:
  - WinRT MIDI 1.0: every `MidiInPort` is a byte input with time stamps,
    every `MidiOutPort` a byte output that sends at once (the engine
    schedules in software). Each port is a synthetic one-port device.
    Ids: `winrt:in:<DeviceInformation.Id>`, `winrt:out:<…>`.
  - Windows MIDI Services (when built in, present and not in legacy
    mode): every endpoint is a UMP input and output on one device, with
    groups, function blocks and endpoint info; outputs schedule in the
    service (`scheduledSend`). Ids: `winrt:umpin:<endpoint id>`,
    `winrt:umpout:<…>`. In hybrid legacy mode both APIs run side by side.
  - Hotplug: DeviceWatcher / MidiEndpointDeviceWatcher → added, removed
    and changed ports; ports that disappear are closed; a disconnected
    endpoint becomes `MidiPortState.disconnected`.
  - Time: WinRT MIDI 1.0 time stamps (time since the port was created)
    plus a QueryPerformanceCounter base taken at open; Midi2 time stamps
    are QPC ticks. `MidiClockMapper` maps QPC to the package clock,
    every 10 s and on hotplug.
  - `bluetooth`: scans the BLE-MIDI service with an active advertisement
    watcher, connects by pairing (confirm-only ceremony) and waits for
    the WinRT ports of the peripheral; disconnect unpairs.
  - `virtualPorts`: virtual devices of Windows MIDI Services, one
    function block each; `null` without Midi2.
- `WindowsMidiServiceAdvertiser` (`MidiServiceAdvertiser`):
  `DnsServiceRegister` / `DnsServiceDeRegister` of dnsapi.dll through
  `package:win32`, completion through `NativeCallable.listener`.
- `WindowsMidiFakeShim`: simulates the shim for tests of apps.

How it is verified:

| Check | Result |
| --- | --- |
| Dart unit tests, macOS VM | 100 % line coverage per file from its own test |
| Portable shim core (`tool/test_native_core.sh`) | ring buffer, event queue, callback gate, worker, BLE filter, clock math, MIDI splitting; ASan/UBSan and TSan clean |
| Byte format C++ ↔ Dart | golden files written by the C++ test, decoded by the Dart tests; the virtual device spec the other way round |
| WinRT shim | compiles with `-Wall -Wextra -Wconversion -Werror` against stand-in headers of the used projection surface (catches errors inside the shim, not API mismatches) |
| Hook | builds nothing for macOS, Linux, Android and iOS |

Not verified: the shim against the real Windows SDK and C++/WinRT
headers, every native call (FFI glue `lib/src/shim/windows_midi_ffi_shim.dart`,
`lib/src/advertiser/windows_dns_sd_ffi_api.dart`, both coverage-ignored),
real devices, BLE pairing, the Midi2 path and the hook build with MSVC.
The Windows tests below cover them.

### Build and test on Windows

Needs Windows 10 1607+ (DNS-SD advertising 1903+) and Visual Studio 2022
or its Build Tools with "Desktop development with C++" and a Windows 11
SDK; native_toolchain_c finds `cl.exe` through vswhere. Then:

```powershell
dart test
```

The hook compiles `src/aud_midi_windows.cpp` (C++20, `/EHsc`,
`WindowsApp.lib`) into the code asset
`package:aud_midi_windows/aud_midi_windows_shim`. Windows-only tests:

- `test/shim/windows_midi_ffi_shim_test.dart`: context, clock, every
  port opened and closed, UMP loopback through the diagnostic loopback
  endpoints (Midi2), byte loopback through a loopMIDI-style driver, a
  note on the Microsoft GS Wavetable Synth (smoke test).
- `test/advertiser/windows_dns_sd_ffi_api_test.dart`: registers and
  withdraws `_apple-midi._udp` and `_midi2._udp` services.
- `test/hook/build_test.dart`: the hook emits the shim.

### Enable Windows MIDI Services

The Midi2 path is compiled only with `AUD_MIDI_WITH_MIDI2`, because the
`Windows.Devices.Midi2` projection comes from NuGet, not from the Windows
SDK:

1. Get the NuGet packages `Windows.Devices.Midi2` (winmd) and
   `Microsoft.Windows.CppWinRT` 3.x (`cppwinrt.exe`).
2. Generate the projection, including the Windows SDK it refers to:

   ```powershell
   cppwinrt -input <package>\ref\native\Windows.Devices.Midi2.winmd `
     -reference sdk -output third_party\midi2
   ```

3. Turn it on in the `pubspec.yaml` of the app:

   ```yaml
   hooks:
     user_defines:
       aud_midi_windows:
         midi2: true
         midi2_include: third_party/midi2
   ```

At runtime the shim asks for `MidiApi` (`try_get_activation_factory`),
`EnsureServiceAvailable` and the API mode; without them it reports byte
ports only. Where the API is not in-box yet, `Windows.Devices.Midi2.dll`
of the package (`runtimes\win-<arch>\native`) must lie next to the
executable. Windows MIDI Services before the November 2026 release can
hang when a virtual device is torn down (microsoft/MIDI#1047).

### Permissions and packaging

- Unpackaged apps need nothing.
- MSIX: `<DeviceCapability Name="bluetooth" />` for BLE-MIDI, and
  `<Capability Name="internetClient" />` plus
  `<Capability Name="privateNetworkClientServer" />` for network
  sessions; the firewall asks for UDP 5004/5005 on first use.

### Regenerate

```bash
dart run ffigen --config ffigen.yaml  # bindings of src/aud_midi_windows.h
tool/test_native_core.sh              # native core test, checks the goldens
tool/test_native_core.sh --update     # rewrites test/goldens
```

See the plan in [aud_midi_pm](https://github.com/audanika/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md).

## Installation

```bash
dart pub add aud_midi_windows
```

## How It Works

- `src/aud_midi_windows.h`: a plain C API with opaque handles; results
  are HRESULTs, events and data leave the shim as little-endian byte
  buffers.
- `src/aud_midi_windows.cpp`: a worker thread in the multithreaded
  apartment owns every WinRT object, so callers never block an STA
  thread. WinRT raises events on thread pool threads; they copy messages
  into a ring buffer per port and events into a queue, then call a
  `NativeCallable.listener` once until the backend drains. A callback
  gate makes `amw_destroy` wait until no callback runs before the Dart
  side closes the callable.
- `src/aud_midi_windows_core.h`: the portable parts, tested natively.
- The Dart side decodes the buffers and owns all logic.

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
