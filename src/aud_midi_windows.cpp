// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The WinRT implementation of the C API in aud_midi_windows.h.
//
// Built by hook/build.dart with MSVC as C++20 and linked against
// WindowsApp.lib. Windows.Devices.Midi2 needs the projection headers of the
// Windows.Devices.Midi2 NuGet package and AUD_MIDI_WITH_MIDI2=1; see the
// README.
//
// Who runs what:
// - The worker thread (MTA) creates, starts, stops and closes every WinRT
//   object: watchers, ports, connections, the scan and the session.
// - WinRT thread pool threads raise the events and complete the async
//   operations. They only copy data into PortQueue and EventQueue and
//   signal, inside the CallbackGate.
// - The caller's thread reads the queues and sends; a send from an STA
//   thread is handed to the worker.

// AMW_COMPILE_CHECK marks the syntax check of tool/test_native_core.sh,
// which compiles this file against stand-in headers on other hosts.
#if !defined(_WIN32) && !defined(AMW_COMPILE_CHECK)
#error "aud_midi_windows.cpp builds for Windows only; hook/build.dart skips it."
#endif

#ifndef NOMINMAX
#define NOMINMAX
#endif

// clang-format off
#include <windows.h>
#include <objbase.h>
#include <unknwn.h>
#include <robuffer.h>
// clang-format on

#include <winrt/base.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Midi.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>

#if AUD_MIDI_WITH_MIDI2
#include <winrt/Windows.Devices.Midi2.Enumeration.h>
#include <winrt/Windows.Devices.Midi2.Transports.Virtual.h>
#include <winrt/Windows.Devices.Midi2.h>
#endif

#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <vector>

#include "aud_midi_windows.h"
#include "aud_midi_windows_core.h"

namespace advertisement = winrt::Windows::Devices::Bluetooth::Advertisement;
namespace bluetooth = winrt::Windows::Devices::Bluetooth;
namespace collections = winrt::Windows::Foundation::Collections;
namespace enumeration = winrt::Windows::Devices::Enumeration;
namespace foundation = winrt::Windows::Foundation;
namespace metadata = winrt::Windows::Foundation::Metadata;
namespace midi1 = winrt::Windows::Devices::Midi;
namespace streams = winrt::Windows::Storage::Streams;
#if AUD_MIDI_WITH_MIDI2
namespace midi2 = winrt::Windows::Devices::Midi2;
namespace midi2enum = winrt::Windows::Devices::Midi2::Enumeration;
namespace midi2virtual = winrt::Windows::Devices::Midi2::Transports::Virtual;
#endif

namespace amw {
namespace {

// ###########################################################################
// Constants

constexpr size_t kEventQueueBytes = size_t{4} << 20;
constexpr size_t kPortQueueBytes = size_t{1} << 20;
// HRESULT_FROM_WIN32(ERROR_CANCELLED).
constexpr int32_t kCanceled = -2147023673;
// DevicePairingResultStatus::Failed and DeviceUnpairingResultStatus::Failed.
constexpr int32_t kPairingFailed = 19;
constexpr int32_t kUnpairingFailed = 4;
// BluetoothError::OtherError.
constexpr int32_t kBluetoothOtherError = 4;

constexpr wchar_t kContainerIdKey[] = L"System.Devices.ContainerId";
constexpr wchar_t kDeviceInstanceIdKey[] = L"System.Devices.DeviceInstanceId";

// The BLE-MIDI service, 03B80E5A-EDE8-4B33-A751-6CE34EC4C700.
constexpr winrt::guid kBleMidiService{
    0x03B80E5A, 0xEDE8, 0x4B33, {0xA7, 0x51, 0x6C, 0xE3, 0x4E, 0xC4, 0xC7, 0x00}};

// ###########################################################################
// Helpers

int64_t QpcFrequency() noexcept {
  static const int64_t frequency = [] {
    LARGE_INTEGER value{};
    QueryPerformanceFrequency(&value);
    return static_cast<int64_t>(value.QuadPart);
  }();
  return frequency;
}

int64_t NowMicros() noexcept {
  LARGE_INTEGER value{};
  QueryPerformanceCounter(&value);
  return TicksToMicros(static_cast<int64_t>(value.QuadPart), QpcFrequency());
}

std::string Utf8(winrt::hstring const& text) { return winrt::to_string(text); }

std::string GuidText(winrt::guid const& guid) {
  return FormatGuid(guid.Data1, guid.Data2, guid.Data3, guid.Data4);
}

// Returns the message of error prefixed with api; never throws.
std::string Describe(std::string_view api,
                     winrt::hresult_error const& error) noexcept {
  try {
    return std::string(api) + ": " + Utf8(error.message());
  } catch (...) {
    return {};
  }
}

std::string Describe(std::string_view api, int32_t status) noexcept {
  if (status >= 0) {
    try {
      return std::string(api);
    } catch (...) {
      return {};
    }
  }
  return Describe(api, winrt::hresult_error(winrt::hresult(status)));
}

// Runs body and turns every exception into a status with a last error
// message, so that no exception crosses the C API.
template <typename Body>
int32_t Guarded(std::string_view api, Body&& body) noexcept {
  try {
    return body();
  } catch (winrt::hresult_error const& error) {
    return Fail(static_cast<int32_t>(error.code()), Describe(api, error));
  } catch (std::bad_alloc const&) {
    return Fail(AMW_E_OUT_OF_MEMORY, std::string());
  } catch (...) {
    return Fail(AMW_E_UNEXPECTED, std::string());
  }
}

// Returns a pointer to the bytes of buffer.
uint8_t* BufferData(streams::IBuffer const& buffer) {
  uint8_t* data = nullptr;
  winrt::check_hresult(
      buffer.as<::Windows::Storage::Streams::IBufferByteAccess>()->Buffer(
          &data));
  return data;
}

// Whether the calling thread lives in a single-threaded apartment.
bool CurrentThreadIsSta() noexcept {
  APTTYPE type{};
  APTTYPEQUALIFIER qualifier{};
  if (FAILED(CoGetApartmentType(&type, &qualifier))) return false;
  return type == APTTYPE_STA || type == APTTYPE_MAINSTA;
}

template <typename Closable>
void CloseQuietly(Closable const& closable) noexcept {
  try {
    if (closable) closable.Close();
  } catch (...) {
  }
}

std::string StringProperty(
    collections::IMapView<winrt::hstring, foundation::IInspectable> const&
        properties,
    wchar_t const* key) {
  if (!properties || !properties.HasKey(key)) return {};
  const auto value = properties.Lookup(key);
  if (!value) return {};
  return Utf8(winrt::unbox_value_or<winrt::hstring>(value, winrt::hstring()));
}

std::string GuidProperty(
    collections::IMapView<winrt::hstring, foundation::IInspectable> const&
        properties,
    wchar_t const* key) {
  if (!properties || !properties.HasKey(key)) return {};
  const auto value = properties.Lookup(key);
  if (!value) return {};
  return GuidText(winrt::unbox_value_or<winrt::guid>(value, winrt::guid{}));
}

PortRecord Midi1Record(uint32_t source,
                       enumeration::DeviceInformation const& info) {
  PortRecord record;
  record.source = source;
  record.id = Utf8(info.Id());
  record.name = Utf8(info.Name());
  record.flags = info.IsEnabled() ? AMW_PORT_ENABLED : 0;
  const auto properties = info.Properties();
  record.device_instance_id = StringProperty(properties, kDeviceInstanceIdKey);
  record.container_id = GuidProperty(properties, kContainerIdKey);
  return record;
}

// The result of an async operation that yields a WinRT object.
struct Outcome {
  int32_t status = AMW_OK;
  std::string message;
};

template <typename T>
Outcome Finish(foundation::IAsyncOperation<T> const& operation,
               foundation::AsyncStatus status, T& result,
               std::string_view api) noexcept {
  Outcome outcome;
  try {
    if (status == foundation::AsyncStatus::Completed) {
      result = operation.GetResults();
      if (!result) {
        outcome.status = AMW_E_PORT_UNAVAILABLE;
        outcome.message = std::string(api) + " returned no object";
      }
    } else if (status == foundation::AsyncStatus::Canceled) {
      outcome.status = kCanceled;
      outcome.message = std::string(api) + " was canceled";
    } else {
      outcome.status = static_cast<int32_t>(operation.ErrorCode());
      outcome.message = Describe(api, outcome.status);
    }
  } catch (winrt::hresult_error const& error) {
    outcome.status = static_cast<int32_t>(error.code());
    outcome.message = Describe(api, error);
  } catch (...) {
    outcome.status = AMW_E_UNEXPECTED;
  }
  return outcome;
}

#if AUD_MIDI_WITH_MIDI2

uint32_t LoadU32(const uint8_t* bytes) noexcept {
  return static_cast<uint32_t>(bytes[0]) |
         static_cast<uint32_t>(bytes[1]) << 8 |
         static_cast<uint32_t>(bytes[2]) << 16 |
         static_cast<uint32_t>(bytes[3]) << 24;
}

void StoreU32(uint8_t* bytes, uint32_t value) noexcept {
  for (int i = 0; i < 4; ++i) {
    bytes[i] = static_cast<uint8_t>(value >> (8 * i));
  }
}

PortRecord Midi2Record(midi2enum::MidiEndpointDeviceInformation const& info) {
  PortRecord record;
  record.source = AMW_SOURCE_MIDI2;
  record.id = Utf8(info.EndpointDeviceId());
  record.name = Utf8(info.Name());
  record.flags = AMW_PORT_ENABLED;
  record.device_instance_id = Utf8(info.DeviceInstanceId());
  record.container_id = GuidText(info.ContainerId());
  EndpointRecord endpoint;
  endpoint.purpose = static_cast<uint32_t>(info.EndpointPurpose());
  if (info.IsEndpointDiscoveryComplete()) {
    endpoint.flags |= AMW_ENDPOINT_DISCOVERY_COMPLETE;
  }
  if (const auto transport = info.GetTransportSuppliedInfo()) {
    endpoint.native_data_format =
        static_cast<uint32_t>(transport.NativeDataFormat());
    endpoint.transport_code = Utf8(transport.TransportCode());
    endpoint.manufacturer = Utf8(transport.ManufacturerName());
    endpoint.serial_number = Utf8(transport.SerialNumber());
    endpoint.description = Utf8(transport.Description());
    endpoint.vendor_id = transport.VendorId();
    endpoint.product_id = transport.ProductId();
    if (transport.SupportsMultiClient()) {
      endpoint.flags |= AMW_ENDPOINT_MULTI_CLIENT;
    }
  }
  if (const auto declared = info.GetDeclaredEndpointInfo()) {
    endpoint.endpoint_name = Utf8(declared.Name());
    endpoint.product_instance_id = Utf8(declared.ProductInstanceId());
    if (declared.SupportsMidi10Protocol()) {
      endpoint.flags |= AMW_ENDPOINT_SUPPORTS_MIDI1;
    }
    if (declared.SupportsMidi20Protocol()) {
      endpoint.flags |= AMW_ENDPOINT_SUPPORTS_MIDI2;
    }
    if (declared.SupportsReceivingJitterReductionTimestamps()) {
      endpoint.flags |= AMW_ENDPOINT_SUPPORTS_RX_JR;
    }
    if (declared.SupportsSendingJitterReductionTimestamps()) {
      endpoint.flags |= AMW_ENDPOINT_SUPPORTS_TX_JR;
    }
    if (declared.HasStaticFunctionBlocks()) {
      endpoint.flags |= AMW_ENDPOINT_STATIC_BLOCKS;
    }
    endpoint.declared_function_block_count =
        declared.DeclaredFunctionBlockCount();
    endpoint.ump_version_major = declared.SpecificationVersionMajor();
    endpoint.ump_version_minor = declared.SpecificationVersionMinor();
  }
  if (const auto stream = info.GetDeclaredStreamConfiguration()) {
    endpoint.protocol = static_cast<uint8_t>(stream.Protocol());
    if (stream.ReceiveJitterReductionTimestamps()) {
      endpoint.flags |= AMW_ENDPOINT_RECEIVES_JR;
    }
    if (stream.SendJitterReductionTimestamps()) {
      endpoint.flags |= AMW_ENDPOINT_TRANSMITS_JR;
    }
  }
  if (const auto identity = info.GetDeclaredDeviceIdentity()) {
    const auto sysex = identity.SystemExclusiveId();
    const auto revision = identity.SoftwareRevisionLevel();
    if (sysex.size() == 3 && revision.size() == 4) {
      endpoint.identity = {sysex[0],
                           sysex[1],
                           sysex[2],
                           identity.DeviceFamilyLsb(),
                           identity.DeviceFamilyMsb(),
                           identity.DeviceFamilyModelNumberLsb(),
                           identity.DeviceFamilyModelNumberMsb(),
                           revision[0],
                           revision[1],
                           revision[2],
                           revision[3]};
      for (const uint8_t byte : endpoint.identity) {
        if (byte != 0) endpoint.flags |= AMW_ENDPOINT_HAS_IDENTITY;
      }
    }
  }
  for (auto const& block : info.GetDeclaredFunctionBlocks()) {
    FunctionBlockRecord record_block;
    record_block.number = block.Number();
    record_block.is_active = block.IsActive() ? 1 : 0;
    record_block.direction = static_cast<uint8_t>(block.Direction());
    record_block.ui_hint = static_cast<uint8_t>(block.UIHint());
    record_block.midi1 =
        static_cast<uint8_t>(block.RepresentsMidi10Connection());
    record_block.first_group =
        block.FirstGroup() ? block.FirstGroup().Index() : uint8_t{0};
    record_block.group_count = block.GroupCount();
    record_block.midi_ci_version = block.MidiCIMessageVersionFormat();
    record_block.max_sysex8_streams = block.MaxSystemExclusive8Streams();
    record_block.name = Utf8(block.Name());
    endpoint.function_blocks.push_back(std::move(record_block));
  }
  for (auto const& block : info.GetGroupTerminalBlocks()) {
    GroupTerminalBlockRecord record_block;
    record_block.number = block.Number();
    record_block.direction = static_cast<uint8_t>(block.Direction());
    record_block.protocol = static_cast<uint8_t>(block.Protocol());
    record_block.first_group =
        block.FirstGroup() ? block.FirstGroup().Index() : uint8_t{0};
    record_block.group_count = block.GroupCount();
    record_block.name = Utf8(block.Name());
    endpoint.group_terminal_blocks.push_back(std::move(record_block));
  }
  record.endpoint = std::move(endpoint);
  return record;
}

#endif  // AUD_MIDI_WITH_MIDI2

// ###########################################################################
// State

// An open port and the WinRT objects behind it.
struct Port {
  int32_t handle = 0;
  int32_t kind = 0;
  // The records of a receiving port; null for sending ports.
  std::shared_ptr<PortQueue> queue;
  // Guards the members below against a close while a send runs.
  std::mutex mutex;
  bool closed = false;
  midi1::MidiInPort midi1_in{nullptr};
  winrt::event_token midi1_in_token{};
  midi1::IMidiOutPort midi1_out{nullptr};
#if AUD_MIDI_WITH_MIDI2
  midi2::MidiEndpointConnection connection{nullptr};
  winrt::event_token message_token{};
  winrt::event_token disconnected_token{};
  uint32_t max_words = 0;
  midi2virtual::MidiVirtualDevice virtual_device{nullptr};
#endif
};

// A WinRT MIDI 1.0 device watcher and the devices it reported, which its
// Updated events modify.
struct Midi1Watcher {
  uint32_t source = 0;
  enumeration::DeviceWatcher watcher{nullptr};
  winrt::event_token added{};
  winrt::event_token updated{};
  winrt::event_token removed{};
  winrt::event_token completed{};
  winrt::event_token stopped{};
  std::mutex mutex;
  std::map<winrt::hstring, enumeration::DeviceInformation> devices;
};

#if AUD_MIDI_WITH_MIDI2
struct Midi2Watcher {
  midi2enum::MidiEndpointDeviceWatcher watcher{nullptr};
  winrt::event_token added{};
  winrt::event_token updated{};
  winrt::event_token removed{};
  winrt::event_token completed{};
  winrt::event_token stopped{};
};
#endif

// ###########################################################################
// Core

class Core : public std::enable_shared_from_this<Core> {
 public:
  explicit Core(amw_signal_fn signal) : signaller_(signal) {}

  // Starts the worker and detects the features on it.
  int32_t Start() {
    CO_MTA_USAGE_COOKIE cookie{};
    // Keeps the MTA alive for threads that never initialize COM, such as
    // the Dart threads that send. Never decremented: late WinRT callbacks
    // may still run after the context is gone.
    (void)CoIncrementMTAUsage(&cookie);
    worker_ = std::make_unique<Worker>(
        [this] {
          try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            apartment_ready_ = true;
          } catch (...) {
            apartment_ready_ = false;
          }
        },
        [this] {
          if (apartment_ready_) winrt::uninit_apartment();
        });
    return worker_->Call<int32_t>([this] { return DetectFeatures(); },
                                  AMW_E_SHUTTING_DOWN);
  }

  // Stops everything on the worker, joins it and waits until no callback
  // runs any more.
  void Shutdown() {
    if (!worker_) return;
    worker_->Post([this] { ShutdownOnWorker(); });
    worker_->StopAndJoin();
    gate_.CloseAndWait();
  }

  // Queues a command for the worker.
  int32_t Post(std::function<void()> task) {
    return worker_->Post(std::move(task))
               ? AMW_OK
               : Fail(AMW_E_SHUTTING_DOWN, "the context is shutting down");
  }

  // Queues event and signals, unless the gate is closed.
  void Emit(std::vector<uint8_t> event) {
    GateGuard guard(gate_);
    if (!guard) return;
    events_.Push(std::move(event));
    signaller_.Notify();
  }

  void Rearm() noexcept { signaller_.Rearm(); }

  int32_t ReadEvents(uint8_t* buffer, int32_t capacity, int32_t* length) {
    return events_.Read(buffer, capacity, length);
  }

  uint32_t features() const noexcept { return features_; }

  Worker& worker() noexcept { return *worker_; }

  // ...........................................................................
  // Ports

  std::shared_ptr<Port> FindPort(int32_t handle) {
    std::lock_guard<std::mutex> lock(ports_mutex_);
    const auto it = ports_.find(handle);
    return it == ports_.end() ? nullptr : it->second;
  }

  std::shared_ptr<Port> TakePort(int32_t handle) {
    std::lock_guard<std::mutex> lock(ports_mutex_);
    const auto it = ports_.find(handle);
    if (it == ports_.end()) return nullptr;
    auto port = it->second;
    ports_.erase(it);
    return port;
  }

  void Open(int64_t request, winrt::hstring const& id, int32_t kind) {
    try {
      switch (kind) {
        case AMW_KIND_MIDI1_IN:
          OpenMidi1In(request, id);
          return;
        case AMW_KIND_MIDI1_OUT:
          OpenMidi1Out(request, id);
          return;
#if AUD_MIDI_WITH_MIDI2
        case AMW_KIND_MIDI2_IN:
        case AMW_KIND_MIDI2_OUT:
          OpenMidi2(request, id, kind);
          return;
#endif
        default:
          Emit(events::OpenCompleted(request, AMW_E_UNSUPPORTED, 0,
                                     "the port kind is not available"));
      }
    } catch (winrt::hresult_error const& error) {
      Emit(events::OpenCompleted(request, static_cast<int32_t>(error.code()),
                                 0, Describe("amw_port_open", error)));
    } catch (...) {
      Emit(events::OpenCompleted(request, AMW_E_UNEXPECTED, 0,
                                 "amw_port_open failed"));
    }
  }

  // Releases the WinRT objects of port; on the worker or, for ports a late
  // completion could not register, on that completion's thread.
  void ClosePortObjects(Port& port) {
    if (port.queue) port.queue->Close();
    std::lock_guard<std::mutex> lock(port.mutex);
    port.closed = true;
    if (port.midi1_in) {
      try {
        if (port.midi1_in_token) port.midi1_in.MessageReceived(port.midi1_in_token);
      } catch (...) {
      }
      CloseQuietly(port.midi1_in);
      port.midi1_in = nullptr;
    }
    CloseQuietly(port.midi1_out);
    port.midi1_out = nullptr;
#if AUD_MIDI_WITH_MIDI2
    if (port.connection) DetachConnection(port, port.connection);
    port.connection = nullptr;
    port.virtual_device = nullptr;
#endif
  }

  // Sends size bytes of data to port at due_us; see amw_port_send.
  int32_t Send(Port& port, const uint8_t* data, size_t size, int64_t due_us) {
    (void)due_us;
    switch (port.kind) {
      case AMW_KIND_MIDI1_OUT:
        return SendMidi1(port, data, size);
#if AUD_MIDI_WITH_MIDI2
      case AMW_KIND_MIDI2_OUT:
      case AMW_KIND_VIRTUAL:
        return SendUmp(port, data, size, due_us);
#endif
      default:
        return Fail(AMW_E_WRONG_KIND, "amw_port_send: the port does not send");
    }
  }

  // ...........................................................................
  // Watchers

  void StartWatchers(uint32_t sources) {
    if ((sources & AMW_SOURCE_MIDI1_IN) != 0) {
      StartMidi1Watcher(AMW_SOURCE_MIDI1_IN);
    }
    if ((sources & AMW_SOURCE_MIDI1_OUT) != 0) {
      StartMidi1Watcher(AMW_SOURCE_MIDI1_OUT);
    }
    if ((sources & AMW_SOURCE_MIDI2) != 0) {
#if AUD_MIDI_WITH_MIDI2
      StartMidi2Watcher((sources & AMW_SOURCE_MIDI2_LOOPBACK) != 0);
#else
      Emit(events::Error(AMW_E_UNSUPPORTED, AMW_SOURCE_MIDI2,
                         "MidiEndpointDeviceWatcher",
                         "the shim was built without AUD_MIDI_WITH_MIDI2"));
#endif
    }
  }

  void StopWatchers() {
    StopMidi1Watcher(midi1_in_watcher_);
    StopMidi1Watcher(midi1_out_watcher_);
#if AUD_MIDI_WITH_MIDI2
    StopMidi2Watcher();
#endif
  }

  // ...........................................................................
  // Bluetooth LE

  void StartBleScan() {
    StopBleScan();
    ble_filter_.Clear();
    try {
      ble_watcher_ = advertisement::BluetoothLEAdvertisementWatcher();
      ble_watcher_.ScanningMode(advertisement::BluetoothLEScanningMode::Active);
      std::weak_ptr<Core> weak = weak_from_this();
      ble_received_ = ble_watcher_.Received(
          [weak](advertisement::BluetoothLEAdvertisementWatcher const&,
                 advertisement::BluetoothLEAdvertisementReceivedEventArgs const&
                     args) {
            if (auto core = weak.lock()) core->OnBleAdvertisement(args);
          });
      ble_stopped_ = ble_watcher_.Stopped(
          [weak](advertisement::BluetoothLEAdvertisementWatcher const&,
                 advertisement::BluetoothLEAdvertisementWatcherStoppedEventArgs const&
                     args) {
            if (auto core = weak.lock()) {
              core->Emit(events::BleScanStopped(
                  static_cast<int32_t>(args.Error())));
            }
          });
      ble_watcher_.Start();
    } catch (winrt::hresult_error const& error) {
      StopBleScan();
      Emit(events::Error(static_cast<int32_t>(error.code()), 0,
                         "BluetoothLEAdvertisementWatcher",
                         Describe("Start", error)));
      Emit(events::BleScanStopped(kBluetoothOtherError));
    } catch (...) {
      StopBleScan();
      Emit(events::BleScanStopped(kBluetoothOtherError));
    }
  }

  void StopBleScan() {
    if (!ble_watcher_) return;
    try {
      if (ble_watcher_.Status() ==
          advertisement::BluetoothLEAdvertisementWatcherStatus::Started) {
        ble_watcher_.Stop();
      }
    } catch (...) {
    }
    try {
      if (ble_received_) ble_watcher_.Received(ble_received_);
      if (ble_stopped_) ble_watcher_.Stopped(ble_stopped_);
    } catch (...) {
    }
    ble_received_ = {};
    ble_stopped_ = {};
    ble_watcher_ = nullptr;
  }

  void Pair(int64_t request, uint64_t address, bool pair) {
    const uint32_t kind =
        pair ? AMW_EVENT_BLE_PAIR_COMPLETED : AMW_EVENT_BLE_UNPAIR_COMPLETED;
    const int32_t failed = pair ? kPairingFailed : kUnpairingFailed;
    try {
      std::weak_ptr<Core> weak = weak_from_this();
      auto operation =
          bluetooth::BluetoothLEDevice::FromBluetoothAddressAsync(address);
      operation.Completed(
          [weak, request, pair, kind, failed](
              foundation::IAsyncOperation<bluetooth::BluetoothLEDevice> const&
                  sender,
              foundation::AsyncStatus status) {
            bluetooth::BluetoothLEDevice device{nullptr};
            Outcome outcome = Finish(sender, status, device,
                                     "BluetoothLEDevice.FromBluetoothAddressAsync");
            if (outcome.status == AMW_E_PORT_UNAVAILABLE) {
              outcome.status = AMW_E_NOT_FOUND;
            }
            auto core = weak.lock();
            if (!core || outcome.status < 0) {
              if (core) {
                core->Emit(events::BlePairing(kind, request, outcome.status,
                                              failed, outcome.message));
              }
              CloseQuietly(device);
              return;
            }
            if (pair) {
              core->PairDevice(request, device);
            } else {
              core->UnpairDevice(request, device);
            }
          });
    } catch (winrt::hresult_error const& error) {
      Emit(events::BlePairing(kind, request, static_cast<int32_t>(error.code()),
                              failed, Describe("FromBluetoothAddressAsync", error)));
    } catch (...) {
      Emit(events::BlePairing(kind, request, AMW_E_UNEXPECTED, failed,
                              "FromBluetoothAddressAsync failed"));
    }
  }

  // ...........................................................................
  // Virtual devices

  void CreateVirtual(int64_t request, VirtualDeviceSpec const& spec) {
#if AUD_MIDI_WITH_MIDI2
    CreateVirtualDevice(request, spec);
#else
    (void)spec;
    Emit(events::VirtualCreated(request, AMW_E_UNSUPPORTED, 0, "",
                                "the shim was built without AUD_MIDI_WITH_MIDI2"));
#endif
  }

 private:
  // ...........................................................................
  // Start and shutdown

  int32_t DetectFeatures() {
    if (!apartment_ready_) {
      return Fail(AMW_E_UNEXPECTED, "winrt::init_apartment failed");
    }
    try {
      if (metadata::ApiInformation::IsTypePresent(
              L"Windows.Devices.Midi.MidiInPort")) {
        features_ |= AMW_FEATURE_MIDI1;
      }
    } catch (...) {
    }
    try {
      const auto adapter = bluetooth::BluetoothAdapter::GetDefaultAsync().get();
      if (adapter && adapter.IsLowEnergySupported()) {
        features_ |= AMW_FEATURE_BLUETOOTH;
      }
    } catch (...) {
    }
#if AUD_MIDI_WITH_MIDI2
    features_ |= AMW_FEATURE_MIDI2_BUILT;
    DetectMidi2();
#endif
    return AMW_OK;
  }

  void ShutdownOnWorker() {
    std::vector<std::shared_ptr<Port>> ports;
    {
      std::lock_guard<std::mutex> lock(ports_mutex_);
      shutting_down_ = true;
      for (auto& entry : ports_) ports.push_back(entry.second);
      ports_.clear();
    }
    StopWatchers();
    StopBleScan();
    for (auto& port : ports) ClosePortObjects(*port);
#if AUD_MIDI_WITH_MIDI2
    CloseQuietly(session_);
    session_ = nullptr;
#endif
  }

  int32_t ReserveHandle() {
    std::lock_guard<std::mutex> lock(ports_mutex_);
    return next_handle_++;
  }

  // Registers port; false while shutting down, then the caller closes it.
  bool InsertPort(std::shared_ptr<Port> const& port) {
    std::lock_guard<std::mutex> lock(ports_mutex_);
    if (shutting_down_) return false;
    ports_.emplace(port->handle, port);
    return true;
  }

  // ...........................................................................
  // WinRT MIDI 1.0 ports

  void OpenMidi1In(int64_t request, winrt::hstring const& id) {
    std::weak_ptr<Core> weak = weak_from_this();
    auto operation = midi1::MidiInPort::FromIdAsync(id);
    operation.Completed(
        [weak, request](
            foundation::IAsyncOperation<midi1::MidiInPort> const& sender,
            foundation::AsyncStatus status) {
          midi1::MidiInPort port{nullptr};
          const Outcome outcome =
              Finish(sender, status, port, "MidiInPort.FromIdAsync");
          auto core = weak.lock();
          if (!core || !core->FinishMidi1In(request, port, outcome)) {
            CloseQuietly(port);
          }
        });
  }

  void OpenMidi1Out(int64_t request, winrt::hstring const& id) {
    std::weak_ptr<Core> weak = weak_from_this();
    auto operation = midi1::MidiOutPort::FromIdAsync(id);
    operation.Completed(
        [weak, request](
            foundation::IAsyncOperation<midi1::IMidiOutPort> const& sender,
            foundation::AsyncStatus status) {
          midi1::IMidiOutPort port{nullptr};
          const Outcome outcome =
              Finish(sender, status, port, "MidiOutPort.FromIdAsync");
          auto core = weak.lock();
          if (!core || !core->FinishMidi1Out(request, port, outcome)) {
            CloseQuietly(port);
          }
        });
  }

  // Takes over port after FromIdAsync; returns false when the caller must
  // close it.
  bool FinishMidi1In(int64_t request, midi1::MidiInPort const& port,
                     Outcome const& outcome) {
    GateGuard guard(gate_);
    if (!guard) return false;
    if (outcome.status < 0) {
      Emit(events::OpenCompleted(request, outcome.status, 0, outcome.message));
      return false;
    }
    auto state = std::make_shared<Port>();
    state->kind = AMW_KIND_MIDI1_IN;
    state->handle = ReserveHandle();
    state->queue = std::make_shared<PortQueue>(kPortQueueBytes);
    state->queue->StartSinceOpenClock(NowMicros());
    state->midi1_in = port;
    try {
      std::weak_ptr<Core> weak = weak_from_this();
      state->midi1_in_token = port.MessageReceived(
          [weak, queue = state->queue](
              midi1::MidiInPort const&,
              midi1::MidiMessageReceivedEventArgs const& args) {
            if (auto core = weak.lock()) core->OnMidi1Message(*queue, args);
          });
    } catch (winrt::hresult_error const& error) {
      Emit(events::OpenCompleted(request, static_cast<int32_t>(error.code()),
                                 0, Describe("MidiInPort.MessageReceived", error)));
      state->midi1_in = nullptr;
      return false;
    }
    if (!InsertPort(state)) {
      ClosePortObjects(*state);
      return true;
    }
    Emit(events::OpenCompleted(request, AMW_OK, state->handle, ""));
    return true;
  }

  bool FinishMidi1Out(int64_t request, midi1::IMidiOutPort const& port,
                      Outcome const& outcome) {
    GateGuard guard(gate_);
    if (!guard) return false;
    if (outcome.status < 0) {
      Emit(events::OpenCompleted(request, outcome.status, 0, outcome.message));
      return false;
    }
    auto state = std::make_shared<Port>();
    state->kind = AMW_KIND_MIDI1_OUT;
    state->handle = ReserveHandle();
    state->midi1_out = port;
    if (!InsertPort(state)) {
      ClosePortObjects(*state);
      return true;
    }
    Emit(events::OpenCompleted(request, AMW_OK, state->handle, ""));
    return true;
  }

  void OnMidi1Message(PortQueue& queue,
                      midi1::MidiMessageReceivedEventArgs const& args) {
    GateGuard guard(gate_);
    if (!guard) return;
    try {
      const midi1::IMidiMessage message = args.Message();
      const streams::IBuffer raw = message.RawData();
      const uint32_t length = raw ? raw.Length() : 0;
      const uint8_t* bytes = length > 0 ? BufferData(raw) : nullptr;
      // TimeSpan counts 100 ns units since the port was created.
      const int64_t since_open_us = message.Timestamp().count() / 10;
      queue.PushSinceOpen(since_open_us, NowMicros(), 0, bytes, length);
      if (!queue.IsClosed()) signaller_.Notify();
    } catch (...) {
    }
  }

  int32_t SendMidi1(Port& port, const uint8_t* data, size_t size) {
    std::lock_guard<std::mutex> lock(port.mutex);
    if (port.closed || !port.midi1_out) {
      return Fail(AMW_E_CLOSED, "IMidiOutPort.SendBuffer: the port is closed");
    }
    // WinRT MIDI 1.0 takes one message per buffer.
    SplitMidi1(data, size, [&](size_t offset, size_t count) {
      streams::Buffer buffer(static_cast<uint32_t>(count));
      buffer.Length(static_cast<uint32_t>(count));
      std::memcpy(BufferData(buffer), data + offset, count);
      port.midi1_out.SendBuffer(buffer);
    });
    return AMW_OK;
  }

  // ...........................................................................
  // WinRT MIDI 1.0 watchers

  void StartMidi1Watcher(uint32_t source) {
    auto& slot = source == AMW_SOURCE_MIDI1_IN ? midi1_in_watcher_
                                               : midi1_out_watcher_;
    StopMidi1Watcher(slot);
    try {
      auto state = std::make_shared<Midi1Watcher>();
      state->source = source;
      const winrt::hstring selector = source == AMW_SOURCE_MIDI1_IN
                                          ? midi1::MidiInPort::GetDeviceSelector()
                                          : midi1::MidiOutPort::GetDeviceSelector();
      const auto properties = winrt::single_threaded_vector<winrt::hstring>(
          {winrt::hstring(kContainerIdKey), winrt::hstring(kDeviceInstanceIdKey)});
      state->watcher =
          enumeration::DeviceInformation::CreateWatcher(selector, properties);
      std::weak_ptr<Core> weak = weak_from_this();
      std::weak_ptr<Midi1Watcher> weak_state = state;
      state->added = state->watcher.Added(
          [weak, weak_state](enumeration::DeviceWatcher const&,
                             enumeration::DeviceInformation const& info) {
            auto core = weak.lock();
            auto watcher = weak_state.lock();
            if (core && watcher) core->OnMidi1Added(*watcher, info);
          });
      state->updated = state->watcher.Updated(
          [weak, weak_state](enumeration::DeviceWatcher const&,
                             enumeration::DeviceInformationUpdate const& update) {
            auto core = weak.lock();
            auto watcher = weak_state.lock();
            if (core && watcher) core->OnMidi1Updated(*watcher, update);
          });
      state->removed = state->watcher.Removed(
          [weak, weak_state](enumeration::DeviceWatcher const&,
                             enumeration::DeviceInformationUpdate const& update) {
            auto core = weak.lock();
            auto watcher = weak_state.lock();
            if (core && watcher) core->OnMidi1Removed(*watcher, update);
          });
      state->completed = state->watcher.EnumerationCompleted(
          [weak, source](enumeration::DeviceWatcher const&,
                         foundation::IInspectable const&) {
            if (auto core = weak.lock()) {
              core->Emit(events::EnumerationCompleted(source));
            }
          });
      state->stopped = state->watcher.Stopped(
          [weak, source](enumeration::DeviceWatcher const& sender,
                         foundation::IInspectable const&) {
            if (auto core = weak.lock()) {
              core->Emit(events::WatcherStopped(
                  source, static_cast<uint32_t>(sender.Status())));
            }
          });
      state->watcher.Start();
      slot = state;
    } catch (winrt::hresult_error const& error) {
      Emit(events::Error(static_cast<int32_t>(error.code()), source,
                         "DeviceWatcher", Describe("Start", error)));
    } catch (...) {
      Emit(events::Error(AMW_E_UNEXPECTED, source, "DeviceWatcher",
                         "Start failed"));
    }
  }

  void StopMidi1Watcher(std::shared_ptr<Midi1Watcher>& slot) {
    if (!slot) return;
    Midi1Watcher& state = *slot;
    try {
      const auto status = state.watcher.Status();
      if (status == enumeration::DeviceWatcherStatus::Started ||
          status == enumeration::DeviceWatcherStatus::EnumerationCompleted) {
        state.watcher.Stop();
      }
    } catch (...) {
    }
    try {
      if (state.added) state.watcher.Added(state.added);
      if (state.updated) state.watcher.Updated(state.updated);
      if (state.removed) state.watcher.Removed(state.removed);
      if (state.completed) state.watcher.EnumerationCompleted(state.completed);
      if (state.stopped) state.watcher.Stopped(state.stopped);
    } catch (...) {
    }
    slot.reset();
  }

  void OnMidi1Added(Midi1Watcher& watcher,
                    enumeration::DeviceInformation const& info) {
    GateGuard guard(gate_);
    if (!guard) return;
    try {
      {
        std::lock_guard<std::mutex> lock(watcher.mutex);
        watcher.devices.insert_or_assign(info.Id(), info);
      }
      Emit(events::Port(AMW_EVENT_PORT_ADDED, Midi1Record(watcher.source, info)));
    } catch (...) {
    }
  }

  void OnMidi1Updated(Midi1Watcher& watcher,
                      enumeration::DeviceInformationUpdate const& update) {
    GateGuard guard(gate_);
    if (!guard) return;
    try {
      std::optional<PortRecord> record;
      {
        std::lock_guard<std::mutex> lock(watcher.mutex);
        const auto it = watcher.devices.find(update.Id());
        if (it == watcher.devices.end()) return;
        it->second.Update(update);
        record = Midi1Record(watcher.source, it->second);
      }
      Emit(events::Port(AMW_EVENT_PORT_UPDATED, *record));
    } catch (...) {
    }
  }

  void OnMidi1Removed(Midi1Watcher& watcher,
                      enumeration::DeviceInformationUpdate const& update) {
    GateGuard guard(gate_);
    if (!guard) return;
    try {
      const winrt::hstring id = update.Id();
      {
        std::lock_guard<std::mutex> lock(watcher.mutex);
        watcher.devices.erase(id);
      }
      Emit(events::PortRemoved(watcher.source, Utf8(id)));
    } catch (...) {
    }
  }

  // ...........................................................................
  // Bluetooth LE

  void OnBleAdvertisement(
      advertisement::BluetoothLEAdvertisementReceivedEventArgs const& args) {
    GateGuard guard(gate_);
    if (!guard) return;
    try {
      const auto advertised = args.Advertisement();
      bool midi = false;
      for (auto const& uuid : advertised.ServiceUuids()) {
        if (uuid == kBleMidiService) {
          midi = true;
          break;
        }
      }
      std::optional<bool> connectable;
      switch (args.AdvertisementType()) {
        case advertisement::BluetoothLEAdvertisementType::ConnectableUndirected:
        case advertisement::BluetoothLEAdvertisementType::ConnectableDirected:
          connectable = true;
          break;
        case advertisement::BluetoothLEAdvertisementType::ScannableUndirected:
        case advertisement::BluetoothLEAdvertisementType::NonConnectableUndirected:
          connectable = false;
          break;
        default:
          break;
      }
      const auto report = ble_filter_.Accept(
          args.BluetoothAddress(), midi, Utf8(advertised.LocalName()),
          args.RawSignalStrengthInDBm(), connectable, NowMicros());
      if (report.has_value()) Emit(events::BleFound(*report));
    } catch (...) {
    }
  }

  // Pairs device with the confirm-only ceremony that BLE-MIDI instruments
  // use; runs on the thread that completed FromBluetoothAddressAsync.
  void PairDevice(int64_t request, bluetooth::BluetoothLEDevice const& device) {
    try {
      const auto pairing = device.DeviceInformation().Pairing();
      if (pairing.IsPaired()) {
        CloseQuietly(device);
        Emit(events::BlePairing(AMW_EVENT_BLE_PAIR_COMPLETED, request, AMW_OK,
                                static_cast<int32_t>(
                                    enumeration::DevicePairingResultStatus::AlreadyPaired),
                                ""));
        return;
      }
      const auto custom = pairing.Custom();
      const auto token = custom.PairingRequested(
          [](enumeration::DeviceInformationCustomPairing const&,
             enumeration::DevicePairingRequestedEventArgs const& args) {
            if (args.PairingKind() == enumeration::DevicePairingKinds::ConfirmOnly) {
              args.Accept();
            }
          });
      std::weak_ptr<Core> weak = weak_from_this();
      auto operation = custom.PairAsync(enumeration::DevicePairingKinds::ConfirmOnly);
      operation.Completed(
          [weak, request, device, custom, token](
              foundation::IAsyncOperation<enumeration::DevicePairingResult> const&
                  sender,
              foundation::AsyncStatus status) {
            try {
              custom.PairingRequested(token);
            } catch (...) {
            }
            enumeration::DevicePairingResult result{nullptr};
            const Outcome outcome = Finish(sender, status, result,
                                           "DeviceInformationCustomPairing.PairAsync");
            int32_t code = kPairingFailed;
            try {
              if (result) code = static_cast<int32_t>(result.Status());
            } catch (...) {
            }
            CloseQuietly(device);
            if (auto core = weak.lock()) {
              core->Emit(events::BlePairing(AMW_EVENT_BLE_PAIR_COMPLETED, request,
                                            outcome.status, code,
                                            outcome.message));
            }
          });
    } catch (winrt::hresult_error const& error) {
      CloseQuietly(device);
      Emit(events::BlePairing(AMW_EVENT_BLE_PAIR_COMPLETED, request,
                              static_cast<int32_t>(error.code()), kPairingFailed,
                              Describe("PairAsync", error)));
    } catch (...) {
      CloseQuietly(device);
      Emit(events::BlePairing(AMW_EVENT_BLE_PAIR_COMPLETED, request,
                              AMW_E_UNEXPECTED, kPairingFailed,
                              "PairAsync failed"));
    }
  }

  void UnpairDevice(int64_t request,
                    bluetooth::BluetoothLEDevice const& device) {
    try {
      std::weak_ptr<Core> weak = weak_from_this();
      auto operation = device.DeviceInformation().Pairing().UnpairAsync();
      operation.Completed(
          [weak, request, device](
              foundation::IAsyncOperation<enumeration::DeviceUnpairingResult> const&
                  sender,
              foundation::AsyncStatus status) {
            enumeration::DeviceUnpairingResult result{nullptr};
            const Outcome outcome = Finish(sender, status, result,
                                           "DeviceInformationPairing.UnpairAsync");
            int32_t code = kUnpairingFailed;
            try {
              if (result) code = static_cast<int32_t>(result.Status());
            } catch (...) {
            }
            CloseQuietly(device);
            if (auto core = weak.lock()) {
              core->Emit(events::BlePairing(AMW_EVENT_BLE_UNPAIR_COMPLETED,
                                            request, outcome.status, code,
                                            outcome.message));
            }
          });
    } catch (winrt::hresult_error const& error) {
      CloseQuietly(device);
      Emit(events::BlePairing(AMW_EVENT_BLE_UNPAIR_COMPLETED, request,
                              static_cast<int32_t>(error.code()),
                              kUnpairingFailed, Describe("UnpairAsync", error)));
    } catch (...) {
      CloseQuietly(device);
      Emit(events::BlePairing(AMW_EVENT_BLE_UNPAIR_COMPLETED, request,
                              AMW_E_UNEXPECTED, kUnpairingFailed,
                              "UnpairAsync failed"));
    }
  }

#if AUD_MIDI_WITH_MIDI2
  // ...........................................................................
  // Windows MIDI Services

  void DetectMidi2() {
    try {
      winrt::hresult_error error;
      const auto statics =
          winrt::try_get_activation_factory<midi2::MidiApi, midi2::IMidiApiStatics>(
              error);
      if (!statics || !statics.EnsureServiceAvailable()) return;
      const auto mode = statics.GetCurrentlySelectedApiMode();
      if (mode == midi2::MidiApiMode::LegacyMode) return;
      session_ = midi2::MidiSession::Create(L"aud_midi");
      if (!session_) return;
      features_ |= AMW_FEATURE_MIDI2;
      if (mode == midi2::MidiApiMode::HybridLegacyMode) {
        features_ |= AMW_FEATURE_MIDI2_HYBRID;
      }
      try {
        if (midi2virtual::MidiVirtualDeviceManager::IsTransportAvailable()) {
          features_ |= AMW_FEATURE_VIRTUAL_DEVICES;
        }
      } catch (...) {
      }
    } catch (...) {
      session_ = nullptr;
    }
  }

  void OpenMidi2(int64_t request, winrt::hstring const& id, int32_t kind) {
    if (!session_) {
      Emit(events::OpenCompleted(request, AMW_E_UNSUPPORTED, 0,
                                 "Windows MIDI Services is not available"));
      return;
    }
    auto port = std::make_shared<Port>();
    port->kind = kind;
    port->handle = ReserveHandle();
    midi2::MidiEndpointConnection connection{nullptr};
    try {
      connection = session_.CreateEndpointConnection(id);
      if (!connection) {
        Emit(events::OpenCompleted(request, AMW_E_PORT_UNAVAILABLE, 0,
                                   "MidiSession.CreateEndpointConnection "
                                   "returned no connection"));
        return;
      }
      AttachConnection(*port, connection, kind == AMW_KIND_MIDI2_IN);
      if (!connection.Open()) {
        DetachConnection(*port, connection);
        Emit(events::OpenCompleted(request, AMW_E_PORT_UNAVAILABLE, 0,
                                   "MidiEndpointConnection.Open failed"));
        return;
      }
      port->max_words = connection.GetSupportedMaxMidiWordsPerTransmission();
      port->connection = connection;
      if (!InsertPort(port)) {
        ClosePortObjects(*port);
        return;
      }
      Emit(events::OpenCompleted(request, AMW_OK, port->handle, ""));
    } catch (winrt::hresult_error const& error) {
      if (connection) DetachConnection(*port, connection);
      Emit(events::OpenCompleted(request, static_cast<int32_t>(error.code()), 0,
                                 Describe("MidiEndpointConnection", error)));
    } catch (...) {
      if (connection) DetachConnection(*port, connection);
      Emit(events::OpenCompleted(request, AMW_E_UNEXPECTED, 0,
                                 "MidiEndpointConnection failed"));
    }
  }

  void CreateVirtualDevice(int64_t request, VirtualDeviceSpec const& spec) {
    if (!session_ || (features_ & AMW_FEATURE_VIRTUAL_DEVICES) == 0) {
      Emit(events::VirtualCreated(request, AMW_E_UNSUPPORTED, 0, "",
                                  "virtual devices are not available"));
      return;
    }
    auto port = std::make_shared<Port>();
    port->kind = AMW_KIND_VIRTUAL;
    port->handle = ReserveHandle();
    midi2::MidiEndpointConnection connection{nullptr};
    try {
      const winrt::hstring name = winrt::to_hstring(spec.name);
      midi2enum::MidiDeclaredEndpointInfo info;
      info.Name(name);
      info.ProductInstanceId(winrt::to_hstring(spec.product_instance_id));
      info.SupportsMidi10Protocol(true);
      info.SupportsMidi20Protocol((spec.flags & AMW_VIRTUAL_MIDI2) != 0);
      info.SupportsReceivingJitterReductionTimestamps(false);
      info.SupportsSendingJitterReductionTimestamps(false);
      info.HasStaticFunctionBlocks(true);
      info.DeclaredFunctionBlockCount(1);
      info.SpecificationVersionMajor(1);
      info.SpecificationVersionMinor(1);
      midi2virtual::MidiVirtualDeviceCreationConfig config(
          name, winrt::to_hstring(spec.description),
          winrt::to_hstring(spec.manufacturer), info);
      midi2enum::MidiFunctionBlock block;
      block.Number(0);
      block.IsActive(true);
      block.Name(name);
      block.FirstGroup(midi2::MidiGroup(spec.first_group));
      block.GroupCount(spec.group_count);
      // Direction and UI hint share their values: input 1, output 2, both 3.
      block.Direction(static_cast<midi2enum::MidiFunctionBlockDirection>(spec.direction));
      block.UIHint(static_cast<midi2enum::MidiFunctionBlockUIHint>(spec.direction));
      block.RepresentsMidi10Connection(
          midi2enum::MidiFunctionBlockRepresentsMidi10Connection::Not10);
      config.FunctionBlocks().Append(block);
      const auto device =
          midi2virtual::MidiVirtualDeviceManager::CreateVirtualDevice(config);
      if (!device) {
        Emit(events::VirtualCreated(request, AMW_E_PORT_UNAVAILABLE, 0, "",
                                    "MidiVirtualDeviceManager.CreateVirtualDevice "
                                    "returned no device"));
        return;
      }
      const winrt::hstring device_id = device.DeviceEndpointDeviceId();
      connection = session_.CreateEndpointConnection(device_id);
      if (!connection) {
        Emit(events::VirtualCreated(request, AMW_E_PORT_UNAVAILABLE, 0, "",
                                    "MidiSession.CreateEndpointConnection "
                                    "returned no connection"));
        return;
      }
      AttachConnection(*port, connection, (spec.flags & AMW_VIRTUAL_RECEIVE) != 0);
      if (connection.AddMessageProcessingPlugin(device) !=
              midi2::MidiMessageProcessingPluginAddResult::Succeeded ||
          !connection.Open()) {
        DetachConnection(*port, connection);
        Emit(events::VirtualCreated(request, AMW_E_PORT_UNAVAILABLE, 0, "",
                                    "the virtual device did not open"));
        return;
      }
      port->max_words = connection.GetSupportedMaxMidiWordsPerTransmission();
      port->connection = connection;
      port->virtual_device = device;
      if (!InsertPort(port)) {
        ClosePortObjects(*port);
        return;
      }
      Emit(events::VirtualCreated(request, AMW_OK, port->handle, Utf8(device_id),
                                  ""));
    } catch (winrt::hresult_error const& error) {
      if (connection) DetachConnection(*port, connection);
      Emit(events::VirtualCreated(request, static_cast<int32_t>(error.code()), 0,
                                  "", Describe("MidiVirtualDevice", error)));
    } catch (...) {
      if (connection) DetachConnection(*port, connection);
      Emit(events::VirtualCreated(request, AMW_E_UNEXPECTED, 0, "",
                                  "MidiVirtualDevice failed"));
    }
  }

  // Subscribes port to connection: received UMPs when receive is set, and
  // the disconnection of the endpoint.
  void AttachConnection(Port& port,
                        midi2::MidiEndpointConnection const& connection,
                        bool receive) {
    std::weak_ptr<Core> weak = weak_from_this();
    if (receive) {
      port.queue = std::make_shared<PortQueue>(kPortQueueBytes);
      port.message_token = connection.MessageReceived(
          [weak, queue = port.queue](
              midi2::IMidiMessageReceivedEventSource const&,
              midi2::MidiMessageReceivedEventArgs const& args) {
            if (auto core = weak.lock()) core->OnUmp(*queue, args);
          });
    }
    const int32_t handle = port.handle;
    port.disconnected_token = connection.EndpointDeviceDisconnected(
        [weak, handle](midi2::IMidiEndpointConnectionSource const&,
                       foundation::IInspectable const&) {
          if (auto core = weak.lock()) {
            core->Emit(events::PortDisconnected(handle));
          }
        });
  }

  // Unsubscribes port and disconnects connection from the session.
  void DetachConnection(Port& port,
                        midi2::MidiEndpointConnection const& connection) {
    try {
      if (port.message_token) connection.MessageReceived(port.message_token);
      if (port.disconnected_token) {
        connection.EndpointDeviceDisconnected(port.disconnected_token);
      }
    } catch (...) {
    }
    port.message_token = {};
    port.disconnected_token = {};
    try {
      if (session_) session_.DisconnectEndpointConnection(connection.ConnectionId());
    } catch (...) {
    }
  }

  void OnUmp(PortQueue& queue, midi2::MidiMessageReceivedEventArgs const& args) {
    GateGuard guard(gate_);
    if (!guard) return;
    try {
      uint32_t words[4] = {};
      const uint8_t count = args.FillWords(words[0], words[1], words[2], words[3]);
      if (count == 0 || count > 4) return;
      uint8_t bytes[16] = {};
      for (uint8_t i = 0; i < count; ++i) StoreU32(bytes + 4 * i, words[i]);
      const int64_t time_us =
          TicksToMicros(static_cast<int64_t>(args.Timestamp()), QpcFrequency());
      queue.Push(time_us, AMW_RECORD_UMP, bytes, static_cast<uint32_t>(count) * 4);
      if (!queue.IsClosed()) signaller_.Notify();
    } catch (...) {
    }
  }

  int32_t SendUmp(Port& port, const uint8_t* data, size_t size, int64_t due_us) {
    constexpr std::string_view api =
        "MidiEndpointConnection.SendMultipleMessagesWordArray";
    if (size % 4 != 0) {
      return Fail(AMW_E_INVALID_ARGUMENT,
                  std::string(api) + ": the data is no whole number of words");
    }
    std::vector<uint32_t> words(size / 4);
    for (size_t i = 0; i < words.size(); ++i) words[i] = LoadU32(data + 4 * i);
    for (size_t i = 0; i < words.size(); i += UmpWordCount(words[i])) {
      if (i + UmpWordCount(words[i]) > words.size()) {
        return Fail(AMW_E_INVALID_ARGUMENT,
                    std::string(api) + ": the last UMP is incomplete");
      }
    }
    const uint64_t timestamp =
        due_us > 0 ? static_cast<uint64_t>(MicrosToTicks(due_us, QpcFrequency()))
                   : 0;
    std::lock_guard<std::mutex> lock(port.mutex);
    if (port.closed || !port.connection) {
      return Fail(AMW_E_CLOSED, std::string(api) + ": the port is closed");
    }
    const uint32_t max_words = port.max_words >= 4 ? port.max_words : 4;
    size_t offset = 0;
    while (offset < words.size()) {
      size_t count = 0;
      while (offset + count < words.size()) {
        const uint32_t next = UmpWordCount(words[offset + count]);
        if (count + next > max_words) break;
        count += next;
      }
      const auto result = port.connection.SendMultipleMessagesWordArray(
          timestamp, static_cast<uint32_t>(offset), static_cast<uint32_t>(count),
          words);
      if (midi2::MidiEndpointConnection::SendMessageFailed(result)) {
        return Fail(AMW_E_SEND_FAILED,
                    std::string(api) + ": result " +
                        std::to_string(static_cast<uint32_t>(result)));
      }
      offset += count;
    }
    return AMW_OK;
  }

  void StartMidi2Watcher(bool loopback) {
    StopMidi2Watcher();
    if (!session_) {
      Emit(events::Error(AMW_E_UNSUPPORTED, AMW_SOURCE_MIDI2,
                         "MidiEndpointDeviceWatcher",
                         "Windows MIDI Services is not available"));
      return;
    }
    try {
      auto filters =
          midi2enum::MidiEndpointDeviceInformationFilters::StandardNativeUniversalMidiPacketFormat |
          midi2enum::MidiEndpointDeviceInformationFilters::StandardNativeMidi1ByteFormat;
      if (loopback) {
        filters = filters |
                  midi2enum::MidiEndpointDeviceInformationFilters::DiagnosticLoopback;
      }
      auto state = std::make_shared<Midi2Watcher>();
      state->watcher = midi2enum::MidiEndpointDeviceWatcher::Create(filters);
      std::weak_ptr<Core> weak = weak_from_this();
      state->added = state->watcher.Added(
          [weak](midi2enum::MidiEndpointDeviceWatcher const&,
                 midi2enum::MidiEndpointDeviceInformationAddedEventArgs const& args) {
            if (auto core = weak.lock()) {
              core->OnMidi2Port(AMW_EVENT_PORT_ADDED, args.AddedDevice());
            }
          });
      state->updated = state->watcher.Updated(
          [weak](midi2enum::MidiEndpointDeviceWatcher const&,
                 midi2enum::MidiEndpointDeviceInformationUpdatedEventArgs const& args) {
            if (auto core = weak.lock()) {
              core->OnMidi2Port(AMW_EVENT_PORT_UPDATED, args.UpdatedDevice());
            }
          });
      state->removed = state->watcher.Removed(
          [weak](midi2enum::MidiEndpointDeviceWatcher const&,
                 midi2enum::MidiEndpointDeviceInformationRemovedEventArgs const& args) {
            auto core = weak.lock();
            if (!core) return;
            try {
              const auto device = args.RemovedDevice();
              if (device) {
                core->Emit(events::PortRemoved(AMW_SOURCE_MIDI2,
                                               Utf8(device.EndpointDeviceId())));
              }
            } catch (...) {
            }
          });
      state->completed = state->watcher.EnumerationCompleted(
          [weak](midi2enum::MidiEndpointDeviceWatcher const&,
                 foundation::IInspectable const&) {
            if (auto core = weak.lock()) {
              core->Emit(events::EnumerationCompleted(AMW_SOURCE_MIDI2));
            }
          });
      state->stopped = state->watcher.Stopped(
          [weak](midi2enum::MidiEndpointDeviceWatcher const& sender,
                 foundation::IInspectable const&) {
            if (auto core = weak.lock()) {
              core->Emit(events::WatcherStopped(
                  AMW_SOURCE_MIDI2, static_cast<uint32_t>(sender.Status())));
            }
          });
      state->watcher.Start();
      midi2_watcher_ = state;
    } catch (winrt::hresult_error const& error) {
      Emit(events::Error(static_cast<int32_t>(error.code()), AMW_SOURCE_MIDI2,
                         "MidiEndpointDeviceWatcher", Describe("Start", error)));
    } catch (...) {
      Emit(events::Error(AMW_E_UNEXPECTED, AMW_SOURCE_MIDI2,
                         "MidiEndpointDeviceWatcher", "Start failed"));
    }
  }

  void StopMidi2Watcher() {
    if (!midi2_watcher_) return;
    Midi2Watcher& state = *midi2_watcher_;
    try {
      const auto status = state.watcher.Status();
      if (status == enumeration::DeviceWatcherStatus::Started ||
          status == enumeration::DeviceWatcherStatus::EnumerationCompleted) {
        state.watcher.Stop();
      }
    } catch (...) {
    }
    try {
      if (state.added) state.watcher.Added(state.added);
      if (state.updated) state.watcher.Updated(state.updated);
      if (state.removed) state.watcher.Removed(state.removed);
      if (state.completed) state.watcher.EnumerationCompleted(state.completed);
      if (state.stopped) state.watcher.Stopped(state.stopped);
    } catch (...) {
    }
    midi2_watcher_.reset();
  }

  void OnMidi2Port(uint32_t kind,
                   midi2enum::MidiEndpointDeviceInformation const& info) {
    GateGuard guard(gate_);
    if (!guard || !info) return;
    try {
      Emit(events::Port(kind, Midi2Record(info)));
    } catch (...) {
    }
  }
#endif  // AUD_MIDI_WITH_MIDI2

  // ...........................................................................
  // Fields

  CallbackGate gate_;
  Signaller signaller_;
  EventQueue events_{kEventQueueBytes};
  std::unique_ptr<Worker> worker_;
  bool apartment_ready_ = false;
  uint32_t features_ = 0;

  std::mutex ports_mutex_;
  std::map<int32_t, std::shared_ptr<Port>> ports_;
  int32_t next_handle_ = 1;
  bool shutting_down_ = false;

  // Owned by the worker thread.
  std::shared_ptr<Midi1Watcher> midi1_in_watcher_;
  std::shared_ptr<Midi1Watcher> midi1_out_watcher_;
  advertisement::BluetoothLEAdvertisementWatcher ble_watcher_{nullptr};
  winrt::event_token ble_received_{};
  winrt::event_token ble_stopped_{};
  BleAdvertisementFilter ble_filter_;
#if AUD_MIDI_WITH_MIDI2
  midi2::MidiSession session_{nullptr};
  std::shared_ptr<Midi2Watcher> midi2_watcher_;
#endif
};

}  // namespace
}  // namespace amw

// #############################################################################
// C API

struct amw_context {
  std::shared_ptr<amw::Core> core;
};

extern "C" {

AMW_EXPORT int32_t amw_version(void) { return AMW_VERSION; }

AMW_EXPORT int32_t amw_create(amw_signal_fn signal, amw_context** context) {
  return amw::Guarded("amw_create", [&]() -> int32_t {
    if (context == nullptr) return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_create");
    *context = nullptr;
    auto core = std::make_shared<amw::Core>(signal);
    const int32_t status = core->Start();
    if (status < 0) {
      core->Shutdown();
      return status;
    }
    *context = new amw_context{core};
    return AMW_OK;
  });
}

AMW_EXPORT void amw_destroy(amw_context* context) {
  if (context == nullptr) return;
  try {
    context->core->Shutdown();
  } catch (...) {
  }
  delete context;
}

AMW_EXPORT uint32_t amw_features(amw_context* context) {
  return context == nullptr ? 0 : context->core->features();
}

AMW_EXPORT int64_t amw_clock_now_us(void) { return amw::NowMicros(); }

AMW_EXPORT int32_t amw_last_error(uint8_t* buffer, int32_t capacity) {
  return amw::CopyLastError(buffer, capacity);
}

AMW_EXPORT void amw_rearm(amw_context* context) {
  if (context != nullptr) context->core->Rearm();
}

AMW_EXPORT int32_t amw_read_events(amw_context* context, uint8_t* buffer,
                                   int32_t capacity, int32_t* length) {
  return amw::Guarded("amw_read_events", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_read_events");
    }
    return context->core->ReadEvents(buffer, capacity, length);
  });
}

AMW_EXPORT int32_t amw_watch_start(amw_context* context, uint32_t sources) {
  return amw::Guarded("amw_watch_start", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_watch_start");
    }
    auto core = context->core;
    return core->Post([core, sources] { core->StartWatchers(sources); });
  });
}

AMW_EXPORT int32_t amw_watch_stop(amw_context* context) {
  return amw::Guarded("amw_watch_stop", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_watch_stop");
    }
    auto core = context->core;
    return core->Post([core] { core->StopWatchers(); });
  });
}

AMW_EXPORT int32_t amw_port_open(amw_context* context, int64_t request,
                                 const uint8_t* id, int32_t id_length,
                                 int32_t kind) {
  return amw::Guarded("amw_port_open", [&]() -> int32_t {
    if (context == nullptr || id == nullptr || id_length <= 0 ||
        kind < AMW_KIND_MIDI1_IN || kind > AMW_KIND_MIDI2_OUT) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_port_open");
    }
    const winrt::hstring native_id = winrt::to_hstring(std::string_view(
        reinterpret_cast<const char*>(id), static_cast<size_t>(id_length)));
    auto core = context->core;
    return core->Post(
        [core, request, native_id, kind] { core->Open(request, native_id, kind); });
  });
}

AMW_EXPORT int32_t amw_port_close(amw_context* context, int32_t handle) {
  return amw::Guarded("amw_port_close", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_port_close");
    }
    auto core = context->core;
    auto port = core->TakePort(handle);
    if (!port) return amw::Fail(AMW_E_UNKNOWN_HANDLE, "amw_port_close");
    if (port->queue) port->queue->Close();
    return core->Post([core, port] { core->ClosePortObjects(*port); });
  });
}

AMW_EXPORT int32_t amw_port_read(amw_context* context, int32_t handle,
                                 uint8_t* buffer, int32_t capacity,
                                 int32_t* length, int64_t* dropped) {
  return amw::Guarded("amw_port_read", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_port_read");
    }
    const auto port = context->core->FindPort(handle);
    if (!port) return amw::Fail(AMW_E_UNKNOWN_HANDLE, "amw_port_read");
    if (!port->queue) {
      return amw::Fail(AMW_E_WRONG_KIND, "amw_port_read: the port does not receive");
    }
    return port->queue->Read(buffer, capacity, length, dropped);
  });
}

AMW_EXPORT int32_t amw_port_send(amw_context* context, int32_t handle,
                                 const uint8_t* data, int32_t length,
                                 int64_t due_us) {
  return amw::Guarded("amw_port_send", [&]() -> int32_t {
    if (context == nullptr || length < 0 || (data == nullptr && length > 0)) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_port_send");
    }
    auto core = context->core;
    auto port = core->FindPort(handle);
    if (!port) return amw::Fail(AMW_E_UNKNOWN_HANDLE, "amw_port_send");
    if (length == 0) return AMW_OK;
    const auto size = static_cast<size_t>(length);
    if (!amw::CurrentThreadIsSta()) {
      return core->Send(*port, data, size, due_us);
    }
    // The WinRT objects live in the MTA; an STA caller hands over.
    auto copy = std::make_shared<std::vector<uint8_t>>(data, data + size);
    auto message = std::make_shared<std::string>();
    const int32_t status = core->worker().Call<int32_t>(
        [core, port, copy, message, due_us]() -> int32_t {
          const int32_t result =
              core->Send(*port, copy->data(), copy->size(), due_us);
          if (result < 0) *message = amw::LastErrorMessage();
          return result;
        },
        AMW_E_SHUTTING_DOWN);
    return status < 0 ? amw::Fail(status, *message) : status;
  });
}

AMW_EXPORT int32_t amw_ble_scan_start(amw_context* context) {
  return amw::Guarded("amw_ble_scan_start", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_ble_scan_start");
    }
    auto core = context->core;
    return core->Post([core] { core->StartBleScan(); });
  });
}

AMW_EXPORT int32_t amw_ble_scan_stop(amw_context* context) {
  return amw::Guarded("amw_ble_scan_stop", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_ble_scan_stop");
    }
    auto core = context->core;
    return core->Post([core] { core->StopBleScan(); });
  });
}

AMW_EXPORT int32_t amw_ble_pair(amw_context* context, int64_t request,
                                uint64_t address) {
  return amw::Guarded("amw_ble_pair", [&]() -> int32_t {
    if (context == nullptr) return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_ble_pair");
    auto core = context->core;
    return core->Post([core, request, address] { core->Pair(request, address, true); });
  });
}

AMW_EXPORT int32_t amw_ble_unpair(amw_context* context, int64_t request,
                                  uint64_t address) {
  return amw::Guarded("amw_ble_unpair", [&]() -> int32_t {
    if (context == nullptr) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_ble_unpair");
    }
    auto core = context->core;
    return core->Post(
        [core, request, address] { core->Pair(request, address, false); });
  });
}

AMW_EXPORT int32_t amw_virtual_create(amw_context* context, int64_t request,
                                      const uint8_t* spec, int32_t spec_length) {
  return amw::Guarded("amw_virtual_create", [&]() -> int32_t {
    if (context == nullptr || spec == nullptr || spec_length <= 0) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT, "amw_virtual_create");
    }
    auto parsed = amw::ReadVirtualDeviceSpec(spec, static_cast<size_t>(spec_length));
    if (!parsed.has_value()) {
      return amw::Fail(AMW_E_INVALID_ARGUMENT,
                       "amw_virtual_create: malformed specification");
    }
    auto core = context->core;
    return core->Post([core, request, value = std::move(*parsed)] {
      core->CreateVirtual(request, value);
    });
  });
}

}  // extern "C"
