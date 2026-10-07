// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The C API of the aud_midi_windows shim.
//
// The shim wraps Windows.Devices.Midi (WinRT MIDI 1.0) and, when built with
// AUD_MIDI_WITH_MIDI2, Windows.Devices.Midi2 (Windows MIDI Services) behind
// plain C functions that Dart binds with ffigen.
//
// Threading: every WinRT object is created on a worker thread the shim owns
// and initializes to the multithreaded apartment, so callers never block an
// STA thread such as Flutter's platform thread. WinRT raises its events on
// thread pool threads; the shim copies the data into its own buffers and
// calls the signal function given to amw_create. The caller then drains the
// buffers with amw_read_events and amw_port_read. The signal function is
// called from any thread, at most once until the next amw_rearm, and never
// after amw_destroy returned.
//
// Results: functions return an HRESULT-style status, 0 (AMW_OK) on success
// and a negative value on failure. amw_last_error returns the message of
// the last failure on the calling thread.
//
// Byte order: all buffers are little-endian. A string is a uint32 byte
// length followed by that many UTF-8 bytes.

#ifndef AUD_MIDI_WINDOWS_H_
#define AUD_MIDI_WINDOWS_H_

#include <stdint.h>

#if defined(_WIN32)
#define AMW_EXPORT __declspec(dllexport)
#else
#define AMW_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ###########################################################################
// Constants

// The version of this API; amw_version returns it.
#define AMW_VERSION 1

// Status codes. Windows HRESULTs pass through unchanged.
#define AMW_OK 0
// E_INVALIDARG: an argument is out of range or malformed.
#define AMW_E_INVALID_ARGUMENT (-2147024809)
// E_OUTOFMEMORY.
#define AMW_E_OUT_OF_MEMORY (-2147024882)
// E_ACCESSDENIED: the system or the user denied access.
#define AMW_E_ACCESS_DENIED (-2147024891)
// RO_E_CLOSED: the port was closed or its device disconnected.
#define AMW_E_CLOSED (-2147483629)
// E_UNEXPECTED: an internal error.
#define AMW_E_UNEXPECTED (-2147418113)
// 0xA0AD0001: no port is known under the handle.
#define AMW_E_UNKNOWN_HANDLE (-1599275007)
// 0xA0AD0002: the buffer cannot hold the next record; the length output
// holds the size it needs.
#define AMW_E_BUFFER_TOO_SMALL (-1599275006)
// 0xA0AD0003: the feature is not built in or not available on this PC.
#define AMW_E_UNSUPPORTED (-1599275005)
// 0xA0AD0004: Windows could not open the port, e.g. FromIdAsync returned
// no port or a connection did not open.
#define AMW_E_PORT_UNAVAILABLE (-1599275004)
// 0xA0AD0005: the operation does not fit the kind of the port, e.g.
// sending on an input.
#define AMW_E_WRONG_KIND (-1599275003)
// 0xA0AD0006: Windows MIDI Services did not accept the messages.
#define AMW_E_SEND_FAILED (-1599275002)
// 0xA0AD0007: the Bluetooth LE device was not found.
#define AMW_E_NOT_FOUND (-1599275001)
// 0xA0AD0008: the context is shutting down.
#define AMW_E_SHUTTING_DOWN (-1599275000)

// Features, bits of amw_features.
// WinRT MIDI 1.0 (Windows.Devices.Midi) is available.
#define AMW_FEATURE_MIDI1 1
// The shim was built with AUD_MIDI_WITH_MIDI2.
#define AMW_FEATURE_MIDI2_BUILT 2
// Windows MIDI Services is present and its service answered.
#define AMW_FEATURE_MIDI2 4
// Windows MIDI Services runs in hybrid legacy mode: devices with MIDI 1.0
// drivers are reachable through WinRT MIDI 1.0 only.
#define AMW_FEATURE_MIDI2_HYBRID 8
// A Bluetooth LE radio is present.
#define AMW_FEATURE_BLUETOOTH 16
// Windows MIDI Services can create virtual devices (app-to-app MIDI).
#define AMW_FEATURE_VIRTUAL_DEVICES 32

// Port sources: the watchers amw_watch_start starts, and the source field
// of port records.
#define AMW_SOURCE_MIDI1_IN 1
#define AMW_SOURCE_MIDI1_OUT 2
#define AMW_SOURCE_MIDI2 4
// Only for amw_watch_start: include the diagnostic loopback endpoints of
// Windows MIDI Services.
#define AMW_SOURCE_MIDI2_LOOPBACK 8

// Port kinds for amw_port_open.
// A MidiInPort; records carry MIDI 1.0 bytes.
#define AMW_KIND_MIDI1_IN 1
// A MidiOutPort; amw_port_send takes MIDI 1.0 bytes.
#define AMW_KIND_MIDI1_OUT 2
// A receiving MidiEndpointConnection; records carry UMP words.
#define AMW_KIND_MIDI2_IN 3
// A sending MidiEndpointConnection; amw_port_send takes UMP words.
#define AMW_KIND_MIDI2_OUT 4
// The device side of an own virtual device; it receives and sends UMP
// words. Created by amw_virtual_create only.
#define AMW_KIND_VIRTUAL 5

// Flags of a port record.
// The device interface is enabled.
#define AMW_PORT_ENABLED 1

// Flags of the endpoint part of a port record.
#define AMW_ENDPOINT_SUPPORTS_MIDI1 1
#define AMW_ENDPOINT_SUPPORTS_MIDI2 2
#define AMW_ENDPOINT_SUPPORTS_RX_JR 4
#define AMW_ENDPOINT_SUPPORTS_TX_JR 8
#define AMW_ENDPOINT_STATIC_BLOCKS 16
#define AMW_ENDPOINT_HAS_IDENTITY 32
#define AMW_ENDPOINT_MULTI_CLIENT 64
#define AMW_ENDPOINT_RECEIVES_JR 128
#define AMW_ENDPOINT_TRANSMITS_JR 256
#define AMW_ENDPOINT_DISCOVERY_COMPLETE 512

// Flags of a data record.
// The payload holds UMP words instead of MIDI 1.0 bytes.
#define AMW_RECORD_UMP 1

// Flags of a Bluetooth LE advertisement event.
#define AMW_BLE_CONNECTABLE 1

// Flags of a virtual device specification.
// The device side receives what other apps send to the device.
#define AMW_VIRTUAL_RECEIVE 1
// The device declares MIDI 2.0 protocol support.
#define AMW_VIRTUAL_MIDI2 2

// Event kinds of amw_read_events.
#define AMW_EVENT_PORT_ADDED 1
#define AMW_EVENT_PORT_UPDATED 2
#define AMW_EVENT_PORT_REMOVED 3
#define AMW_EVENT_ENUMERATION_COMPLETED 4
#define AMW_EVENT_WATCHER_STOPPED 5
#define AMW_EVENT_OPEN_COMPLETED 6
#define AMW_EVENT_PORT_DISCONNECTED 7
#define AMW_EVENT_BLE_ADVERTISEMENT 8
#define AMW_EVENT_BLE_SCAN_STOPPED 9
#define AMW_EVENT_BLE_PAIR_COMPLETED 10
#define AMW_EVENT_BLE_UNPAIR_COMPLETED 11
#define AMW_EVENT_VIRTUAL_CREATED 12
#define AMW_EVENT_ERROR 13
#define AMW_EVENT_EVENTS_DROPPED 14

// ###########################################################################
// Buffer formats
//
// Event: uint32 kind, uint32 payload length, payload. Payloads:
//
// PORT_ADDED, PORT_UPDATED: a port record
//   uint32 source (AMW_SOURCE_*), string id, string name, uint32 flags
//   (AMW_PORT_*), string device instance id, string container id,
//   uint8 has endpoint; when 1 the endpoint part follows:
//   uint32 purpose (MidiEndpointDevicePurpose), uint32 native data format
//   (MidiEndpointNativeDataFormat), string transport code, string
//   manufacturer, string serial number, string description, uint16 vendor
//   id, uint16 product id, uint32 flags (AMW_ENDPOINT_*), string endpoint
//   name, string product instance id, uint8 declared function block count,
//   uint8 UMP version major, uint8 UMP version minor, uint8 protocol
//   (0 default, 1 MIDI 1.0, 2 MIDI 2.0), 11 identity bytes (3 SysEx id,
//   family LSB, family MSB, model LSB, model MSB, 4 software revision),
//   uint32 function block count, per block: uint8 number, uint8 active,
//   uint8 direction, uint8 UI hint, uint8 MIDI 1.0, uint8 first group,
//   uint8 group count, uint8 MIDI-CI version, uint8 max SysEx8 streams,
//   string name; uint32 group terminal block count, per block: uint8
//   number, uint8 direction, uint8 protocol, uint8 first group, uint8 group
//   count, string name.
// PORT_REMOVED: uint32 source, string id.
// ENUMERATION_COMPLETED: uint32 source.
// WATCHER_STOPPED: uint32 source, uint32 status (DeviceWatcherStatus).
// OPEN_COMPLETED: int64 request, int32 status, int32 handle, string
//   message.
// PORT_DISCONNECTED: int32 handle.
// BLE_ADVERTISEMENT: uint64 address, int32 RSSI in dBm, uint32 flags
//   (AMW_BLE_*), string local name.
// BLE_SCAN_STOPPED: int32 BluetoothError.
// BLE_PAIR_COMPLETED: int64 request, int32 status, int32 result
//   (DevicePairingResultStatus), string message.
// BLE_UNPAIR_COMPLETED: int64 request, int32 status, int32 result
//   (DeviceUnpairingResultStatus), string message.
// VIRTUAL_CREATED: int64 request, int32 status, int32 handle, string
//   device endpoint id, string message.
// ERROR: int32 status, uint32 source (0 when no watcher failed), string
//   api, string message.
// EVENTS_DROPPED: uint64 number of events dropped because the queue was
//   full.
//
// Data record of amw_port_read: int64 native receive time in
// microseconds (the clock of amw_clock_now_us), uint32 flags
// (AMW_RECORD_*), uint32 payload length in bytes, payload (MIDI 1.0 bytes
// of one message, or the 32-bit words of one UMP).
//
// Virtual device specification of amw_virtual_create: string name, string
// description, string manufacturer, string product instance id, uint32
// flags (AMW_VIRTUAL_*), uint8 first group, uint8 group count, uint8
// function block direction (1 input, 2 output, 3 bidirectional).

// ###########################################################################
// Types

// A shim instance: its worker thread, watchers, ports and buffers.
typedef struct amw_context amw_context;

// The function the shim calls when events or data are waiting. It must
// return quickly and must not call back into the shim synchronously.
typedef void (*amw_signal_fn)(void);

// ###########################################################################
// Context

// Returns AMW_VERSION of the built shim.
AMW_EXPORT int32_t amw_version(void);

// Creates a context, starts its worker thread and detects the features.
// signal is called whenever events or data are waiting.
AMW_EXPORT int32_t amw_create(amw_signal_fn signal, amw_context** context);

// Stops watchers and scans, closes all ports, joins the worker thread,
// waits until no callback is running and frees the context. The signal
// function is not called after this returns.
AMW_EXPORT void amw_destroy(amw_context* context);

// Returns the AMW_FEATURE_* bits detected by amw_create.
AMW_EXPORT uint32_t amw_features(amw_context* context);

// Returns the native monotonic clock (QueryPerformanceCounter) in
// microseconds; all record times use this clock.
AMW_EXPORT int64_t amw_clock_now_us(void);

// Copies the UTF-8 message of the last failure on the calling thread into
// buffer and returns its full length in bytes, which may exceed capacity.
AMW_EXPORT int32_t amw_last_error(uint8_t* buffer, int32_t capacity);

// Allows the next signal. Call it before draining the buffers.
AMW_EXPORT void amw_rearm(amw_context* context);

// ###########################################################################
// Events

// Moves as many whole events as fit into buffer and stores their length in
// length, 0 when no event waits. Returns AMW_E_BUFFER_TOO_SMALL with the
// size of the next event in length when not even that one fits.
AMW_EXPORT int32_t amw_read_events(
    amw_context* context,
    uint8_t* buffer,
    int32_t capacity,
    int32_t* length);

// ###########################################################################
// Watchers

// Starts the watchers of the AMW_SOURCE_* bits in sources. Each watcher
// reports its ports with PORT_ADDED events and then ENUMERATION_COMPLETED,
// or an ERROR event naming its source.
AMW_EXPORT int32_t amw_watch_start(amw_context* context, uint32_t sources);

// Stops all watchers.
AMW_EXPORT int32_t amw_watch_stop(amw_context* context);

// ###########################################################################
// Ports

// Starts to open the port id (UTF-8, id_length bytes) as kind
// (AMW_KIND_*). The result follows as OPEN_COMPLETED carrying request.
AMW_EXPORT int32_t amw_port_open(
    amw_context* context,
    int64_t request,
    const uint8_t* id,
    int32_t id_length,
    int32_t kind);

// Closes the port handle; its records are discarded.
AMW_EXPORT int32_t amw_port_close(amw_context* context, int32_t handle);

// Moves as many whole data records of the input handle as fit into buffer
// and stores their length in length; dropped receives the number of
// messages lost since the last read because the port's buffer was full.
// Returns AMW_E_BUFFER_TOO_SMALL with the size of the next record in
// length when not even that one fits.
AMW_EXPORT int32_t amw_port_read(
    amw_context* context,
    int32_t handle,
    uint8_t* buffer,
    int32_t capacity,
    int32_t* length,
    int64_t* dropped);

// Sends length bytes of data to the output handle: MIDI 1.0 bytes for
// AMW_KIND_MIDI1_OUT, complete UMPs as 32-bit words for UMP kinds. due_us
// is the native time in microseconds at which a UMP port delivers the
// data; 0 sends at once. MIDI 1.0 ports always send at once.
AMW_EXPORT int32_t amw_port_send(
    amw_context* context,
    int32_t handle,
    const uint8_t* data,
    int32_t length,
    int64_t due_us);

// ###########################################################################
// Bluetooth LE

// Starts to scan for BLE-MIDI peripherals; findings follow as
// BLE_ADVERTISEMENT events.
AMW_EXPORT int32_t amw_ble_scan_start(amw_context* context);

// Stops the scan.
AMW_EXPORT int32_t amw_ble_scan_stop(amw_context* context);

// Starts to pair the Bluetooth LE device address; the result follows as
// BLE_PAIR_COMPLETED carrying request. Paired BLE-MIDI devices appear as
// WinRT MIDI 1.0 ports.
AMW_EXPORT int32_t amw_ble_pair(
    amw_context* context,
    int64_t request,
    uint64_t address);

// Starts to unpair the Bluetooth LE device address; the result follows as
// BLE_UNPAIR_COMPLETED carrying request.
AMW_EXPORT int32_t amw_ble_unpair(
    amw_context* context,
    int64_t request,
    uint64_t address);

// ###########################################################################
// Virtual devices (Windows MIDI Services)

// Starts to create a virtual device from the specification spec
// (spec_length bytes); the result follows as VIRTUAL_CREATED carrying
// request and the handle of the device side, an AMW_KIND_VIRTUAL port.
// Closing that handle removes the device.
AMW_EXPORT int32_t amw_virtual_create(
    amw_context* context,
    int64_t request,
    const uint8_t* spec,
    int32_t spec_length);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AUD_MIDI_WINDOWS_H_
