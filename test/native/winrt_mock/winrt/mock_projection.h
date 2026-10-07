// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Declarations of the C++/WinRT projection surface that
// src/aud_midi_windows.cpp uses, transcribed from the Windows API reference
// (learn.microsoft.com/uwp/api) and the Windows MIDI Services IDL
// (github.com/microsoft/MIDI, src/in-box/Client/WinRT/core). Every
// winrt/*.h of this folder includes it.
//
// It exists only for the compile check of tool/test_native_core.sh on hosts
// without the Windows SDK: it catches errors inside the shim, never a
// mismatch with the real projection. Nothing is defined, nothing links.

#pragma once

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

#include "../windows.h"

namespace winrt {

// ###########################################################################
// base.h

struct hstring {
  hstring() noexcept;
  hstring(wchar_t const* value);
  hstring(std::wstring_view const& value);
  bool empty() const noexcept;
};
bool operator<(hstring const& left, hstring const& right) noexcept;
bool operator==(hstring const& left, hstring const& right) noexcept;
std::string to_string(hstring const& value);
hstring to_hstring(std::string_view value);

struct guid {
  uint32_t Data1;
  uint16_t Data2;
  uint16_t Data3;
  uint8_t Data4[8];
  guid() noexcept = default;
  constexpr guid(uint32_t const data1, uint16_t const data2,
                 uint16_t const data3,
                 std::array<uint8_t, 8> const& data4) noexcept
      : Data1(data1),
        Data2(data2),
        Data3(data3),
        Data4{data4[0], data4[1], data4[2], data4[3],
              data4[4], data4[5], data4[6], data4[7]} {}
};
bool operator==(guid const& left, guid const& right) noexcept;

struct hresult {
  int32_t value{};
  constexpr hresult() noexcept = default;
  constexpr hresult(int32_t const code) noexcept : value(code) {}
  constexpr operator int32_t() const noexcept { return value; }
};

struct hresult_error {
  hresult_error() noexcept;
  hresult_error(hresult const code) noexcept;
  hresult code() const noexcept;
  hstring message() const noexcept;
};

void check_hresult(hresult const result);

struct event_token {
  int64_t value{};
  explicit operator bool() const noexcept { return value != 0; }
};

enum class apartment_type : int32_t { multi_threaded = 0, single_threaded = 2 };
void init_apartment(apartment_type const type = apartment_type::multi_threaded);
void uninit_apartment() noexcept;

template <typename T>
struct com_ptr {
  T* operator->() const noexcept;
  explicit operator bool() const noexcept;
};

template <typename T>
struct array_view {
  array_view(std::vector<std::remove_const_t<T>>& value) noexcept;
  array_view(std::vector<std::remove_const_t<T>> const& value) noexcept;
};

template <typename T>
struct com_array {
  uint32_t size() const noexcept;
  T& operator[](uint32_t index) noexcept;
  T const& operator[](uint32_t index) const noexcept;
};

namespace Windows::Foundation {

struct IInspectable {
  IInspectable(std::nullptr_t = nullptr) noexcept;
  explicit operator bool() const noexcept;
  template <typename I>
  com_ptr<I> as() const;
};

using TimeSpan = std::chrono::duration<int64_t, std::ratio<1, 10000000>>;

enum class AsyncStatus : int32_t {
  Canceled = 2,
  Completed = 1,
  Error = 3,
  Started = 0,
};

template <typename TSender, typename TResult>
using TypedEventHandler =
    std::function<void(TSender const&, TResult const&)>;

template <typename TResult>
struct IAsyncOperation;

template <typename TResult>
using AsyncOperationCompletedHandler =
    std::function<void(IAsyncOperation<TResult> const&, AsyncStatus)>;

template <typename TResult>
struct IAsyncOperation : IInspectable {
  IAsyncOperation(std::nullptr_t = nullptr) noexcept;
  void Completed(AsyncOperationCompletedHandler<TResult> const& handler) const;
  TResult GetResults() const;
  hresult ErrorCode() const;
  AsyncStatus Status() const;
  TResult get() const;
};

}  // namespace Windows::Foundation

namespace Windows::Foundation::Collections {

template <typename T>
struct IIterable : Windows::Foundation::IInspectable {
  IIterable(std::nullptr_t = nullptr) noexcept;
  T* begin() const;
  T* end() const;
};

template <typename T>
struct IVectorView : IIterable<T> {
  IVectorView(std::nullptr_t = nullptr) noexcept;
  uint32_t Size() const;
  T GetAt(uint32_t index) const;
};

template <typename T>
struct IVector : IIterable<T> {
  IVector(std::nullptr_t = nullptr) noexcept;
  uint32_t Size() const;
  T GetAt(uint32_t index) const;
  void Append(T const& value) const;
};

template <typename K, typename V>
struct IMapView : Windows::Foundation::IInspectable {
  IMapView(std::nullptr_t = nullptr) noexcept;
  bool HasKey(K const& key) const;
  V Lookup(K const& key) const;
  uint32_t Size() const;
};

}  // namespace Windows::Foundation::Collections

template <typename T>
Windows::Foundation::Collections::IVector<T> single_threaded_vector(
    std::vector<T>&& values = {});

template <typename T, typename U>
T unbox_value_or(Windows::Foundation::IInspectable const& value,
                 U&& default_value);

template <typename Class, typename Interface>
Interface try_get_activation_factory(hresult_error& exception) noexcept;

// ###########################################################################
// Windows.Foundation.Metadata

namespace Windows::Foundation::Metadata {
struct ApiInformation {
  static bool IsTypePresent(hstring const& typeName);
};
}  // namespace Windows::Foundation::Metadata

// ###########################################################################
// Windows.Storage.Streams

namespace Windows::Storage::Streams {

struct IBuffer : Windows::Foundation::IInspectable {
  IBuffer(std::nullptr_t = nullptr) noexcept;
  uint32_t Capacity() const;
  uint32_t Length() const;
  void Length(uint32_t value) const;
};

struct Buffer : IBuffer {
  Buffer(std::nullptr_t) noexcept;
  explicit Buffer(uint32_t capacity);
};

}  // namespace Windows::Storage::Streams

// ###########################################################################
// Windows.Devices.Enumeration

namespace Windows::Devices::Enumeration {

using Windows::Foundation::IAsyncOperation;
using Windows::Foundation::IInspectable;
using Windows::Foundation::TypedEventHandler;

enum class DeviceWatcherStatus : int32_t {
  Created = 0,
  Started = 1,
  EnumerationCompleted = 2,
  Stopping = 3,
  Stopped = 4,
  Aborted = 5,
};

enum class DevicePairingKinds : uint32_t {
  None = 0x0,
  ConfirmOnly = 0x1,
  DisplayPin = 0x2,
  ProvidePin = 0x4,
  ConfirmPinMatch = 0x8,
};

enum class DevicePairingResultStatus : int32_t {
  Paired = 0,
  NotReadyToPair = 1,
  NotPaired = 2,
  AlreadyPaired = 3,
  Failed = 19,
};

enum class DeviceUnpairingResultStatus : int32_t {
  Unpaired = 0,
  AlreadyUnpaired = 1,
  OperationAlreadyInProgress = 2,
  AccessDenied = 3,
  Failed = 4,
};

struct DeviceInformationUpdate : IInspectable {
  DeviceInformationUpdate(std::nullptr_t) noexcept;
  hstring Id() const;
};

struct DevicePairingResult : IInspectable {
  DevicePairingResult(std::nullptr_t) noexcept;
  DevicePairingResultStatus Status() const;
};

struct DeviceUnpairingResult : IInspectable {
  DeviceUnpairingResult(std::nullptr_t) noexcept;
  DeviceUnpairingResultStatus Status() const;
};

struct DevicePairingRequestedEventArgs : IInspectable {
  DevicePairingRequestedEventArgs(std::nullptr_t) noexcept;
  DevicePairingKinds PairingKind() const;
  void Accept() const;
};

struct DeviceInformationCustomPairing : IInspectable {
  DeviceInformationCustomPairing(std::nullptr_t) noexcept;
  IAsyncOperation<DevicePairingResult> PairAsync(
      DevicePairingKinds const& pairingKindsSupported) const;
  event_token PairingRequested(
      TypedEventHandler<DeviceInformationCustomPairing,
                        DevicePairingRequestedEventArgs> const& handler) const;
  void PairingRequested(event_token const& token) const noexcept;
};

struct DeviceInformationPairing : IInspectable {
  DeviceInformationPairing(std::nullptr_t) noexcept;
  bool IsPaired() const;
  bool CanPair() const;
  DeviceInformationCustomPairing Custom() const;
  IAsyncOperation<DeviceUnpairingResult> UnpairAsync() const;
};

struct DeviceWatcher;

struct DeviceInformation : IInspectable {
  DeviceInformation(std::nullptr_t) noexcept;
  hstring Id() const;
  hstring Name() const;
  bool IsEnabled() const;
  Windows::Foundation::Collections::IMapView<hstring, IInspectable> Properties()
      const;
  void Update(DeviceInformationUpdate const& updateInfo) const;
  DeviceInformationPairing Pairing() const;
  static DeviceWatcher CreateWatcher(
      hstring const& aqsFilter,
      Windows::Foundation::Collections::IIterable<hstring> const&
          additionalProperties);
};

struct DeviceWatcher : IInspectable {
  DeviceWatcher(std::nullptr_t) noexcept;
  DeviceWatcherStatus Status() const;
  void Start() const;
  void Stop() const;
  event_token Added(
      TypedEventHandler<DeviceWatcher, DeviceInformation> const& handler) const;
  void Added(event_token const& token) const noexcept;
  event_token Updated(TypedEventHandler<DeviceWatcher, DeviceInformationUpdate> const&
                          handler) const;
  void Updated(event_token const& token) const noexcept;
  event_token Removed(TypedEventHandler<DeviceWatcher, DeviceInformationUpdate> const&
                          handler) const;
  void Removed(event_token const& token) const noexcept;
  event_token EnumerationCompleted(
      TypedEventHandler<DeviceWatcher, IInspectable> const& handler) const;
  void EnumerationCompleted(event_token const& token) const noexcept;
  event_token Stopped(
      TypedEventHandler<DeviceWatcher, IInspectable> const& handler) const;
  void Stopped(event_token const& token) const noexcept;
};

}  // namespace Windows::Devices::Enumeration

// ###########################################################################
// Windows.Devices.Midi

namespace Windows::Devices::Midi {

using Windows::Foundation::IAsyncOperation;
using Windows::Foundation::IInspectable;
using Windows::Foundation::TypedEventHandler;

struct IMidiMessage : IInspectable {
  IMidiMessage(std::nullptr_t = nullptr) noexcept;
  Windows::Foundation::TimeSpan Timestamp() const;
  Windows::Storage::Streams::IBuffer RawData() const;
};

struct MidiMessageReceivedEventArgs : IInspectable {
  MidiMessageReceivedEventArgs(std::nullptr_t) noexcept;
  IMidiMessage Message() const;
};

struct MidiInPort : IInspectable {
  MidiInPort(std::nullptr_t) noexcept;
  hstring DeviceId() const;
  void Close() const;
  event_token MessageReceived(
      TypedEventHandler<MidiInPort, MidiMessageReceivedEventArgs> const&
          handler) const;
  void MessageReceived(event_token const& token) const noexcept;
  static IAsyncOperation<MidiInPort> FromIdAsync(hstring const& deviceId);
  static hstring GetDeviceSelector();
};

struct IMidiOutPort : IInspectable {
  IMidiOutPort(std::nullptr_t = nullptr) noexcept;
  void SendMessage(IMidiMessage const& midiMessage) const;
  void SendBuffer(Windows::Storage::Streams::IBuffer const& midiData) const;
  hstring DeviceId() const;
  void Close() const;
};

struct MidiOutPort : IMidiOutPort {
  MidiOutPort(std::nullptr_t) noexcept;
  static IAsyncOperation<IMidiOutPort> FromIdAsync(hstring const& deviceId);
  static hstring GetDeviceSelector();
};

}  // namespace Windows::Devices::Midi

// ###########################################################################
// Windows.Devices.Bluetooth

namespace Windows::Devices::Bluetooth {

using Windows::Foundation::IAsyncOperation;
using Windows::Foundation::IInspectable;

enum class BluetoothError : int32_t {
  Success = 0,
  RadioNotAvailable = 1,
  ResourceInUse = 2,
  DeviceNotConnected = 3,
  OtherError = 4,
  DisabledByPolicy = 5,
  NotSupported = 6,
  DisabledByUser = 7,
  ConsentRequired = 8,
  TransportNotSupported = 9,
};

struct BluetoothAdapter : IInspectable {
  BluetoothAdapter(std::nullptr_t) noexcept;
  bool IsLowEnergySupported() const;
  static IAsyncOperation<BluetoothAdapter> GetDefaultAsync();
};

struct BluetoothLEDevice : IInspectable {
  BluetoothLEDevice(std::nullptr_t) noexcept;
  Windows::Devices::Enumeration::DeviceInformation DeviceInformation() const;
  void Close() const;
  static IAsyncOperation<BluetoothLEDevice> FromBluetoothAddressAsync(
      uint64_t bluetoothAddress);
};

}  // namespace Windows::Devices::Bluetooth

namespace Windows::Devices::Bluetooth::Advertisement {

using Windows::Foundation::IInspectable;
using Windows::Foundation::TypedEventHandler;

enum class BluetoothLEScanningMode : int32_t { Passive = 0, Active = 1, None = 2 };

enum class BluetoothLEAdvertisementType : int32_t {
  ConnectableUndirected = 0,
  ConnectableDirected = 1,
  ScannableUndirected = 2,
  NonConnectableUndirected = 3,
  ScanResponse = 4,
  Extended = 5,
};

enum class BluetoothLEAdvertisementWatcherStatus : int32_t {
  Created = 0,
  Started = 1,
  Stopping = 2,
  Stopped = 3,
  Aborted = 4,
};

struct BluetoothLEAdvertisement : IInspectable {
  BluetoothLEAdvertisement(std::nullptr_t) noexcept;
  hstring LocalName() const;
  Windows::Foundation::Collections::IVector<guid> ServiceUuids() const;
};

struct BluetoothLEAdvertisementReceivedEventArgs : IInspectable {
  BluetoothLEAdvertisementReceivedEventArgs(std::nullptr_t) noexcept;
  int16_t RawSignalStrengthInDBm() const;
  uint64_t BluetoothAddress() const;
  BluetoothLEAdvertisementType AdvertisementType() const;
  BluetoothLEAdvertisement Advertisement() const;
};

struct BluetoothLEAdvertisementWatcherStoppedEventArgs : IInspectable {
  BluetoothLEAdvertisementWatcherStoppedEventArgs(std::nullptr_t) noexcept;
  Windows::Devices::Bluetooth::BluetoothError Error() const;
};

struct BluetoothLEAdvertisementWatcher : IInspectable {
  BluetoothLEAdvertisementWatcher();
  BluetoothLEAdvertisementWatcher(std::nullptr_t) noexcept;
  BluetoothLEAdvertisementWatcherStatus Status() const;
  void ScanningMode(BluetoothLEScanningMode const& value) const;
  void Start() const;
  void Stop() const;
  event_token Received(
      TypedEventHandler<BluetoothLEAdvertisementWatcher,
                        BluetoothLEAdvertisementReceivedEventArgs> const& handler)
      const;
  void Received(event_token const& token) const noexcept;
  event_token Stopped(
      TypedEventHandler<BluetoothLEAdvertisementWatcher,
                        BluetoothLEAdvertisementWatcherStoppedEventArgs> const&
          handler) const;
  void Stopped(event_token const& token) const noexcept;
};

}  // namespace Windows::Devices::Bluetooth::Advertisement

// ###########################################################################
// Windows.Devices.Midi2 (Windows MIDI Services)

namespace Windows::Devices::Midi2 {

using Windows::Foundation::IInspectable;
using Windows::Foundation::TypedEventHandler;

enum class MidiApiMode : int32_t {
  FullWindowsMidiServicesMode = 0,
  LegacyMode = 1,
  HybridLegacyMode = 2,
};

enum class MidiMessageProcessingPluginAddResult : int32_t {
  Succeeded = 0,
  FailedPluginIsNull = 1,
  FailedRawCallbackRegistered = 2,
  FailedPluginAlreadyAdded = 3,
  FailedPluginInitializationError = 4,
};

enum class MidiSendMessageResults : uint32_t {
  Succeeded = 0x80000000,
  Failed = 0x10000000,
  BufferFull = 0x00010000,
  EndpointConnectionClosedOrInvalid = 0x00040000,
};

struct IMidiApiStatics : IInspectable {
  IMidiApiStatics(std::nullptr_t = nullptr) noexcept;
  bool EnsureServiceAvailable() const;
  MidiApiMode GetCurrentlySelectedApiMode() const;
};

struct MidiApi {
  static bool EnsureServiceAvailable();
  static MidiApiMode GetCurrentlySelectedApiMode();
};

struct MidiGroup : IInspectable {
  MidiGroup();
  MidiGroup(std::nullptr_t) noexcept;
  explicit MidiGroup(uint8_t index);
  uint8_t Index() const;
  void Index(uint8_t value) const;
};

struct MidiMessageReceivedEventArgs : IInspectable {
  MidiMessageReceivedEventArgs(std::nullptr_t) noexcept;
  uint64_t Timestamp() const;
  uint8_t FillWords(uint32_t& word0, uint32_t& word1, uint32_t& word2,
                    uint32_t& word3) const;
};

struct IMidiEndpointMessageProcessingPlugin : IInspectable {
  IMidiEndpointMessageProcessingPlugin(std::nullptr_t = nullptr) noexcept;
};

struct IMidiEndpointConnectionSource : IInspectable {
  IMidiEndpointConnectionSource(std::nullptr_t = nullptr) noexcept;
  event_token EndpointDeviceDisconnected(
      TypedEventHandler<IMidiEndpointConnectionSource, IInspectable> const&
          handler) const;
  void EndpointDeviceDisconnected(event_token const& token) const noexcept;
  guid ConnectionId() const;
  hstring ConnectedEndpointDeviceId() const;
  bool IsOpen() const;
};

struct IMidiMessageReceivedEventSource : IInspectable {
  IMidiMessageReceivedEventSource(std::nullptr_t = nullptr) noexcept;
  event_token MessageReceived(
      TypedEventHandler<IMidiMessageReceivedEventSource,
                        MidiMessageReceivedEventArgs> const& handler) const;
  void MessageReceived(event_token const& token) const noexcept;
};

struct MidiEndpointConnection : IInspectable {
  MidiEndpointConnection(std::nullptr_t) noexcept;
  event_token MessageReceived(
      TypedEventHandler<IMidiMessageReceivedEventSource,
                        MidiMessageReceivedEventArgs> const& handler) const;
  void MessageReceived(event_token const& token) const noexcept;
  event_token EndpointDeviceDisconnected(
      TypedEventHandler<IMidiEndpointConnectionSource, IInspectable> const&
          handler) const;
  void EndpointDeviceDisconnected(event_token const& token) const noexcept;
  guid ConnectionId() const;
  bool Open() const;
  MidiMessageProcessingPluginAddResult AddMessageProcessingPlugin(
      IMidiEndpointMessageProcessingPlugin const& plugin) const;
  MidiSendMessageResults SendMultipleMessagesWordArray(
      uint64_t timestamp, uint32_t startIndex, uint32_t wordCount,
      array_view<uint32_t const> words) const;
  uint32_t GetSupportedMaxMidiWordsPerTransmission() const;
  static bool SendMessageFailed(MidiSendMessageResults const& sendResult);
};

struct MidiSession : IInspectable {
  MidiSession(std::nullptr_t) noexcept;
  static MidiSession Create(hstring const& sessionName);
  MidiEndpointConnection CreateEndpointConnection(
      hstring const& endpointDeviceId) const;
  void DisconnectEndpointConnection(guid const& endpointConnectionId) const;
  void Close() const;
};

}  // namespace Windows::Devices::Midi2

namespace Windows::Devices::Midi2::Enumeration {

using Windows::Foundation::IInspectable;
using Windows::Foundation::TypedEventHandler;

enum class MidiEndpointDeviceInformationFilters : uint32_t {
  StandardNativeUniversalMidiPacketFormat = 0x00000001,
  StandardNativeMidi1ByteFormat = 0x00000002,
  VirtualDeviceResponder = 0x00000100,
  DiagnosticLoopback = 0x00010000,
  DiagnosticPing = 0x00020000,
  AllStandardEndpoints = 0x00000003,
};
constexpr MidiEndpointDeviceInformationFilters operator|(
    MidiEndpointDeviceInformationFilters const left,
    MidiEndpointDeviceInformationFilters const right) noexcept {
  return static_cast<MidiEndpointDeviceInformationFilters>(
      static_cast<uint32_t>(left) | static_cast<uint32_t>(right));
}

enum class MidiEndpointDevicePurpose : int32_t {
  NormalMessageEndpoint = 0,
  VirtualDeviceResponder = 100,
  InBoxGeneralMidiSynth = 400,
  DiagnosticLoopback = 500,
  DiagnosticPing = 510,
};

enum class MidiEndpointNativeDataFormat : int32_t {
  Unknown = 0,
  Midi1ByteFormat = 1,
  UniversalMidiPacketFormat = 2,
};

enum class MidiProtocol : int32_t { Default = 0, Midi1 = 1, Midi2 = 2 };

enum class MidiFunctionBlockDirection : int32_t {
  Undefined = 0,
  BlockInput = 1,
  BlockOutput = 2,
  Bidirectional = 3,
};

enum class MidiFunctionBlockUIHint : int32_t {
  Unknown = 0,
  Receiver = 1,
  Sender = 2,
  Bidirectional = 3,
};

enum class MidiFunctionBlockRepresentsMidi10Connection : int32_t {
  Not10 = 0,
  YesBandwidthUnrestricted = 1,
  YesBandwidthRestricted = 2,
  Reserved = 3,
};

enum class MidiGroupTerminalBlockDirection : int32_t {
  Bidirectional = 0,
  BlockInput = 1,
  BlockOutput = 2,
};

enum class MidiGroupTerminalBlockProtocol : int32_t {
  Unknown = 0x00,
  Midi1Message64 = 0x01,
  Midi2 = 0x11,
};

struct MidiEndpointTransportSuppliedInfo : IInspectable {
  MidiEndpointTransportSuppliedInfo(std::nullptr_t) noexcept;
  hstring Name() const;
  hstring Description() const;
  hstring SerialNumber() const;
  uint16_t VendorId() const;
  uint16_t ProductId() const;
  hstring ManufacturerName() const;
  bool SupportsMultiClient() const;
  MidiEndpointNativeDataFormat NativeDataFormat() const;
  guid TransportId() const;
  hstring TransportCode() const;
};

struct MidiDeclaredEndpointInfo : IInspectable {
  MidiDeclaredEndpointInfo();
  MidiDeclaredEndpointInfo(std::nullptr_t) noexcept;
  hstring Name() const;
  void Name(hstring const& value) const;
  hstring ProductInstanceId() const;
  void ProductInstanceId(hstring const& value) const;
  bool SupportsMidi10Protocol() const;
  void SupportsMidi10Protocol(bool value) const;
  bool SupportsMidi20Protocol() const;
  void SupportsMidi20Protocol(bool value) const;
  bool SupportsReceivingJitterReductionTimestamps() const;
  void SupportsReceivingJitterReductionTimestamps(bool value) const;
  bool SupportsSendingJitterReductionTimestamps() const;
  void SupportsSendingJitterReductionTimestamps(bool value) const;
  bool HasStaticFunctionBlocks() const;
  void HasStaticFunctionBlocks(bool value) const;
  uint8_t DeclaredFunctionBlockCount() const;
  void DeclaredFunctionBlockCount(uint8_t value) const;
  uint8_t SpecificationVersionMajor() const;
  void SpecificationVersionMajor(uint8_t value) const;
  uint8_t SpecificationVersionMinor() const;
  void SpecificationVersionMinor(uint8_t value) const;
};

struct MidiDeclaredDeviceIdentity : IInspectable {
  MidiDeclaredDeviceIdentity(std::nullptr_t) noexcept;
  com_array<uint8_t> SystemExclusiveId() const;
  uint8_t DeviceFamilyLsb() const;
  uint8_t DeviceFamilyMsb() const;
  uint8_t DeviceFamilyModelNumberLsb() const;
  uint8_t DeviceFamilyModelNumberMsb() const;
  com_array<uint8_t> SoftwareRevisionLevel() const;
};

struct MidiDeclaredStreamConfiguration : IInspectable {
  MidiDeclaredStreamConfiguration(std::nullptr_t) noexcept;
  MidiProtocol Protocol() const;
  bool ReceiveJitterReductionTimestamps() const;
  bool SendJitterReductionTimestamps() const;
};

struct MidiFunctionBlock : IInspectable {
  MidiFunctionBlock();
  MidiFunctionBlock(std::nullptr_t) noexcept;
  uint8_t Number() const;
  void Number(uint8_t value) const;
  hstring Name() const;
  void Name(hstring const& value) const;
  bool IsActive() const;
  void IsActive(bool value) const;
  MidiFunctionBlockDirection Direction() const;
  void Direction(MidiFunctionBlockDirection const& value) const;
  MidiFunctionBlockUIHint UIHint() const;
  void UIHint(MidiFunctionBlockUIHint const& value) const;
  MidiFunctionBlockRepresentsMidi10Connection RepresentsMidi10Connection() const;
  void RepresentsMidi10Connection(
      MidiFunctionBlockRepresentsMidi10Connection const& value) const;
  Windows::Devices::Midi2::MidiGroup FirstGroup() const;
  void FirstGroup(Windows::Devices::Midi2::MidiGroup const& value) const;
  uint8_t GroupCount() const;
  void GroupCount(uint8_t value) const;
  uint8_t MidiCIMessageVersionFormat() const;
  uint8_t MaxSystemExclusive8Streams() const;
};

struct MidiGroupTerminalBlock : IInspectable {
  MidiGroupTerminalBlock(std::nullptr_t) noexcept;
  uint8_t Number() const;
  hstring Name() const;
  MidiGroupTerminalBlockDirection Direction() const;
  MidiGroupTerminalBlockProtocol Protocol() const;
  Windows::Devices::Midi2::MidiGroup FirstGroup() const;
  uint8_t GroupCount() const;
};

struct MidiEndpointDeviceInformation : IInspectable {
  MidiEndpointDeviceInformation(std::nullptr_t) noexcept;
  hstring EndpointDeviceId() const;
  hstring Name() const;
  guid ContainerId() const;
  hstring DeviceInstanceId() const;
  MidiEndpointDevicePurpose EndpointPurpose() const;
  MidiDeclaredEndpointInfo GetDeclaredEndpointInfo() const;
  MidiDeclaredDeviceIdentity GetDeclaredDeviceIdentity() const;
  MidiDeclaredStreamConfiguration GetDeclaredStreamConfiguration() const;
  Windows::Foundation::Collections::IVectorView<MidiFunctionBlock>
  GetDeclaredFunctionBlocks() const;
  Windows::Foundation::Collections::IVectorView<MidiGroupTerminalBlock>
  GetGroupTerminalBlocks() const;
  MidiEndpointTransportSuppliedInfo GetTransportSuppliedInfo() const;
  bool IsEndpointDiscoveryComplete() const;
};

struct MidiEndpointDeviceInformationAddedEventArgs : IInspectable {
  MidiEndpointDeviceInformationAddedEventArgs(std::nullptr_t) noexcept;
  MidiEndpointDeviceInformation AddedDevice() const;
};

struct MidiEndpointDeviceInformationRemovedEventArgs : IInspectable {
  MidiEndpointDeviceInformationRemovedEventArgs(std::nullptr_t) noexcept;
  MidiEndpointDeviceInformation RemovedDevice() const;
};

struct MidiEndpointDeviceInformationUpdatedEventArgs : IInspectable {
  MidiEndpointDeviceInformationUpdatedEventArgs(std::nullptr_t) noexcept;
  MidiEndpointDeviceInformation UpdatedDevice() const;
};

struct MidiEndpointDeviceWatcher : IInspectable {
  MidiEndpointDeviceWatcher(std::nullptr_t) noexcept;
  static MidiEndpointDeviceWatcher Create(
      MidiEndpointDeviceInformationFilters const& endpointFilters);
  void Start() const;
  void Stop() const;
  Windows::Devices::Enumeration::DeviceWatcherStatus Status() const;
  event_token Added(
      TypedEventHandler<MidiEndpointDeviceWatcher,
                        MidiEndpointDeviceInformationAddedEventArgs> const&
          handler) const;
  void Added(event_token const& token) const noexcept;
  event_token Removed(
      TypedEventHandler<MidiEndpointDeviceWatcher,
                        MidiEndpointDeviceInformationRemovedEventArgs> const&
          handler) const;
  void Removed(event_token const& token) const noexcept;
  event_token Updated(
      TypedEventHandler<MidiEndpointDeviceWatcher,
                        MidiEndpointDeviceInformationUpdatedEventArgs> const&
          handler) const;
  void Updated(event_token const& token) const noexcept;
  event_token EnumerationCompleted(
      TypedEventHandler<MidiEndpointDeviceWatcher, IInspectable> const& handler)
      const;
  void EnumerationCompleted(event_token const& token) const noexcept;
  event_token Stopped(
      TypedEventHandler<MidiEndpointDeviceWatcher, IInspectable> const& handler)
      const;
  void Stopped(event_token const& token) const noexcept;
};

}  // namespace Windows::Devices::Midi2::Enumeration

namespace Windows::Devices::Midi2::Transports::Virtual {

struct MidiVirtualDevice : Windows::Devices::Midi2::IMidiEndpointMessageProcessingPlugin {
  MidiVirtualDevice(std::nullptr_t) noexcept;
  hstring DeviceEndpointDeviceId() const;
  guid AssociationId() const;
};

struct MidiVirtualDeviceCreationConfig : Windows::Foundation::IInspectable {
  MidiVirtualDeviceCreationConfig(std::nullptr_t) noexcept;
  MidiVirtualDeviceCreationConfig(
      hstring const& name, hstring const& description,
      hstring const& manufacturer,
      Windows::Devices::Midi2::Enumeration::MidiDeclaredEndpointInfo const&
          declaredEndpointInfo);
  Windows::Foundation::Collections::IVector<
      Windows::Devices::Midi2::Enumeration::MidiFunctionBlock>
  FunctionBlocks() const;
};

struct MidiVirtualDeviceManager {
  static bool IsTransportAvailable();
  static guid TransportId();
  static MidiVirtualDevice CreateVirtualDevice(
      MidiVirtualDeviceCreationConfig const& creationConfig);
  static hstring GetAssociatedClientEndpointDeviceId(guid const& associationId);
};

}  // namespace Windows::Devices::Midi2::Transports::Virtual

}  // namespace winrt
