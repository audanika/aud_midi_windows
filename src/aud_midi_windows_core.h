// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The portable building blocks of the aud_midi_windows shim: byte formats,
// buffers, threading helpers and clock arithmetic.
//
// Nothing here depends on Windows, so test/native/aud_midi_windows_core_test
// .cpp builds and runs this header on any platform with a C++20 compiler
// (tool/test_native_core.sh). aud_midi_windows.cpp adds the WinRT parts.

#ifndef AUD_MIDI_WINDOWS_CORE_H_
#define AUD_MIDI_WINDOWS_CORE_H_

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <future>
#include <iterator>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "aud_midi_windows.h"

namespace amw {

// ###########################################################################
// Clock arithmetic

// Converts ticks of a clock running at frequency ticks per second to
// microseconds; splits the division so that no uptime overflows.
constexpr int64_t TicksToMicros(int64_t ticks, int64_t frequency) noexcept {
  if (frequency <= 0) return 0;
  return ticks / frequency * 1000000 +
         ticks % frequency * 1000000 / frequency;
}

// Converts microseconds to ticks of a clock running at frequency ticks per
// second.
constexpr int64_t MicrosToTicks(int64_t micros, int64_t frequency) noexcept {
  return micros / 1000000 * frequency +
         micros % 1000000 * frequency / 1000000;
}

// Maps the timestamps of WinRT MIDI 1.0 messages, the time since the
// MidiInPort was created, to the native clock.
//
// The base is the native time taken right after the port was created. A
// mapped time never lies in the future and never runs backwards, so a base
// taken a little late cannot reorder or postdate messages.
class SinceOpenClock {
 public:
  explicit SinceOpenClock(int64_t base_us) noexcept : base_us_(base_us) {}

  // Returns the native time of a message received since_open_us after the
  // port was created; now_us is the current native time.
  int64_t Map(int64_t since_open_us, int64_t now_us) noexcept {
    int64_t time = base_us_ + since_open_us;
    if (time > now_us) time = now_us;
    if (time < last_us_) time = last_us_;
    last_us_ = time;
    return time;
  }

 private:
  int64_t base_us_;
  int64_t last_us_ = std::numeric_limits<int64_t>::min();
};

// ###########################################################################
// Little-endian byte formats

// Appends little-endian values and length-prefixed strings to a buffer.
class ByteWriter {
 public:
  void U8(uint8_t value) { data_.push_back(value); }

  void U16(uint16_t value) { Unsigned(value, 2); }

  void U32(uint32_t value) { Unsigned(value, 4); }

  void U64(uint64_t value) { Unsigned(value, 8); }

  void I32(int32_t value) { U32(static_cast<uint32_t>(value)); }

  void I64(int64_t value) { U64(static_cast<uint64_t>(value)); }

  // Writes the byte length of value as uint32, then its bytes.
  void String(std::string_view value) {
    U32(static_cast<uint32_t>(value.size()));
    Bytes(value.data(), value.size());
  }

  // Writes size raw bytes.
  void Bytes(const void* data, size_t size) {
    if (size == 0) return;
    const auto* bytes = static_cast<const uint8_t*>(data);
    data_.insert(data_.end(), bytes, bytes + size);
  }

  const std::vector<uint8_t>& data() const noexcept { return data_; }

  // Returns the buffer and leaves the writer empty.
  std::vector<uint8_t> Take() noexcept { return std::move(data_); }

 private:
  void Unsigned(uint64_t value, int count) {
    for (int i = 0; i < count; ++i) {
      data_.push_back(static_cast<uint8_t>(value >> (8 * i)));
    }
  }

  std::vector<uint8_t> data_;
};

// Reads what ByteWriter wrote; every read fails once the data runs out.
class ByteReader {
 public:
  ByteReader(const uint8_t* data, size_t size) noexcept
      : data_(data), size_(data == nullptr ? 0 : size) {}

  bool U8(uint8_t& value) noexcept {
    if (!Has(1)) return false;
    value = data_[offset_++];
    return true;
  }

  bool U32(uint32_t& value) noexcept {
    if (!Has(4)) return false;
    value = 0;
    for (int i = 0; i < 4; ++i) {
      value |= static_cast<uint32_t>(data_[offset_++]) << (8 * i);
    }
    return true;
  }

  bool String(std::string& value) {
    uint32_t size = 0;
    if (!U32(size) || !Has(size)) return false;
    value.assign(reinterpret_cast<const char*>(data_ + offset_), size);
    offset_ += size;
    return true;
  }

  bool AtEnd() const noexcept { return offset_ == size_; }

 private:
  bool Has(size_t count) const noexcept { return size_ - offset_ >= count; }

  const uint8_t* data_;
  size_t size_;
  size_t offset_ = 0;
};

// Formats a GUID the way Windows shows it: lower-case, with braces.
inline std::string FormatGuid(uint32_t data1, uint16_t data2, uint16_t data3,
                              const uint8_t (&data4)[8]) {
  static constexpr char kDigits[] = "0123456789abcdef";
  std::string text = "{";
  auto hex = [&](uint64_t value, int digits) {
    for (int i = digits - 1; i >= 0; --i) {
      text.push_back(kDigits[(value >> (4 * i)) & 0xF]);
    }
  };
  hex(data1, 8);
  text.push_back('-');
  hex(data2, 4);
  text.push_back('-');
  hex(data3, 4);
  text.push_back('-');
  hex(data4[0], 2);
  hex(data4[1], 2);
  text.push_back('-');
  for (int i = 2; i < 8; ++i) hex(data4[i], 2);
  text.push_back('}');
  return text;
}

// ###########################################################################
// MIDI framing

// Returns the number of 32-bit words of the UMP that starts with
// first_word (M2-104-UM 2.1.4).
constexpr uint32_t UmpWordCount(uint32_t first_word) noexcept {
  constexpr uint8_t kWords[16] = {1, 1, 1, 2, 2, 4, 1, 1,
                                  2, 2, 2, 3, 3, 4, 4, 4};
  return kWords[first_word >> 28];
}

// Splits a MIDI 1.0 byte stream into the chunks WinRT sends one by one:
// each status byte starts a chunk that runs to the next status byte, a
// System Exclusive chunk runs to its End of Exclusive, real-time bytes are
// chunks of their own and leading data bytes form one chunk. emit receives
// the offset and the length of every chunk.
inline void SplitMidi1(const uint8_t* data, size_t size,
                       const std::function<void(size_t, size_t)>& emit) {
  size_t start = 0;
  while (start < size) {
    const uint8_t status = data[start];
    size_t end = start + 1;
    if (status == 0xF0) {
      while (end < size && data[end] != 0xF7 &&
             !(data[end] >= 0x80 && data[end] < 0xF8)) {
        ++end;
      }
      if (end < size && data[end] == 0xF7) ++end;
    } else if (status < 0xF8) {
      while (end < size && data[end] < 0x80) ++end;
    }
    emit(start, end - start);
    start = end;
  }
}

// ###########################################################################
// Records and events

// A function block of a UMP endpoint.
struct FunctionBlockRecord {
  uint8_t number = 0;
  uint8_t is_active = 0;
  uint8_t direction = 0;
  uint8_t ui_hint = 0;
  uint8_t midi1 = 0;
  uint8_t first_group = 0;
  uint8_t group_count = 0;
  uint8_t midi_ci_version = 0;
  uint8_t max_sysex8_streams = 0;
  std::string name;
};

// A group terminal block of a USB MIDI 2.0 device.
struct GroupTerminalBlockRecord {
  uint8_t number = 0;
  uint8_t direction = 0;
  uint8_t protocol = 0;
  uint8_t first_group = 0;
  uint8_t group_count = 0;
  std::string name;
};

// What Windows MIDI Services reports about a UMP endpoint.
struct EndpointRecord {
  uint32_t purpose = 0;
  uint32_t native_data_format = 0;
  std::string transport_code;
  std::string manufacturer;
  std::string serial_number;
  std::string description;
  uint16_t vendor_id = 0;
  uint16_t product_id = 0;
  uint32_t flags = 0;
  std::string endpoint_name;
  std::string product_instance_id;
  uint8_t declared_function_block_count = 0;
  uint8_t ump_version_major = 0;
  uint8_t ump_version_minor = 0;
  uint8_t protocol = 0;
  std::array<uint8_t, 11> identity{};
  std::vector<FunctionBlockRecord> function_blocks;
  std::vector<GroupTerminalBlockRecord> group_terminal_blocks;
};

// A port as a watcher reports it.
struct PortRecord {
  uint32_t source = 0;
  std::string id;
  std::string name;
  uint32_t flags = 0;
  std::string device_instance_id;
  std::string container_id;
  std::optional<EndpointRecord> endpoint;
};

// A BLE-MIDI peripheral as a scan reports it.
struct BleAdvertisement {
  uint64_t address = 0;
  int32_t rssi = 0;
  uint32_t flags = 0;
  std::string name;
};

// The specification of a virtual device.
struct VirtualDeviceSpec {
  std::string name;
  std::string description;
  std::string manufacturer;
  std::string product_instance_id;
  uint32_t flags = 0;
  uint8_t first_group = 0;
  uint8_t group_count = 1;
  uint8_t direction = 3;
};

// Builders of the events amw_read_events returns; see aud_midi_windows.h.
namespace events {

inline std::vector<uint8_t> Event(uint32_t kind, const ByteWriter& payload) {
  ByteWriter event;
  event.U32(kind);
  event.U32(static_cast<uint32_t>(payload.data().size()));
  event.Bytes(payload.data().data(), payload.data().size());
  return event.Take();
}

inline void WriteEndpoint(ByteWriter& out, const EndpointRecord& endpoint) {
  out.U32(endpoint.purpose);
  out.U32(endpoint.native_data_format);
  out.String(endpoint.transport_code);
  out.String(endpoint.manufacturer);
  out.String(endpoint.serial_number);
  out.String(endpoint.description);
  out.U16(endpoint.vendor_id);
  out.U16(endpoint.product_id);
  out.U32(endpoint.flags);
  out.String(endpoint.endpoint_name);
  out.String(endpoint.product_instance_id);
  out.U8(endpoint.declared_function_block_count);
  out.U8(endpoint.ump_version_major);
  out.U8(endpoint.ump_version_minor);
  out.U8(endpoint.protocol);
  out.Bytes(endpoint.identity.data(), endpoint.identity.size());
  out.U32(static_cast<uint32_t>(endpoint.function_blocks.size()));
  for (const auto& block : endpoint.function_blocks) {
    out.U8(block.number);
    out.U8(block.is_active);
    out.U8(block.direction);
    out.U8(block.ui_hint);
    out.U8(block.midi1);
    out.U8(block.first_group);
    out.U8(block.group_count);
    out.U8(block.midi_ci_version);
    out.U8(block.max_sysex8_streams);
    out.String(block.name);
  }
  out.U32(static_cast<uint32_t>(endpoint.group_terminal_blocks.size()));
  for (const auto& block : endpoint.group_terminal_blocks) {
    out.U8(block.number);
    out.U8(block.direction);
    out.U8(block.protocol);
    out.U8(block.first_group);
    out.U8(block.group_count);
    out.String(block.name);
  }
}

// PORT_ADDED or PORT_UPDATED, depending on kind.
inline std::vector<uint8_t> Port(uint32_t kind, const PortRecord& port) {
  ByteWriter out;
  out.U32(port.source);
  out.String(port.id);
  out.String(port.name);
  out.U32(port.flags);
  out.String(port.device_instance_id);
  out.String(port.container_id);
  out.U8(port.endpoint.has_value() ? 1 : 0);
  if (port.endpoint.has_value()) WriteEndpoint(out, *port.endpoint);
  return Event(kind, out);
}

inline std::vector<uint8_t> PortRemoved(uint32_t source, std::string_view id) {
  ByteWriter out;
  out.U32(source);
  out.String(id);
  return Event(AMW_EVENT_PORT_REMOVED, out);
}

inline std::vector<uint8_t> EnumerationCompleted(uint32_t source) {
  ByteWriter out;
  out.U32(source);
  return Event(AMW_EVENT_ENUMERATION_COMPLETED, out);
}

inline std::vector<uint8_t> WatcherStopped(uint32_t source, uint32_t status) {
  ByteWriter out;
  out.U32(source);
  out.U32(status);
  return Event(AMW_EVENT_WATCHER_STOPPED, out);
}

inline std::vector<uint8_t> OpenCompleted(int64_t request, int32_t status,
                                          int32_t handle,
                                          std::string_view message) {
  ByteWriter out;
  out.I64(request);
  out.I32(status);
  out.I32(handle);
  out.String(message);
  return Event(AMW_EVENT_OPEN_COMPLETED, out);
}

inline std::vector<uint8_t> PortDisconnected(int32_t handle) {
  ByteWriter out;
  out.I32(handle);
  return Event(AMW_EVENT_PORT_DISCONNECTED, out);
}

inline std::vector<uint8_t> BleFound(const BleAdvertisement& advertisement) {
  ByteWriter out;
  out.U64(advertisement.address);
  out.I32(advertisement.rssi);
  out.U32(advertisement.flags);
  out.String(advertisement.name);
  return Event(AMW_EVENT_BLE_ADVERTISEMENT, out);
}

inline std::vector<uint8_t> BleScanStopped(int32_t error) {
  ByteWriter out;
  out.I32(error);
  return Event(AMW_EVENT_BLE_SCAN_STOPPED, out);
}

// BLE_PAIR_COMPLETED or BLE_UNPAIR_COMPLETED, depending on kind.
inline std::vector<uint8_t> BlePairing(uint32_t kind, int64_t request,
                                       int32_t status, int32_t result,
                                       std::string_view message) {
  ByteWriter out;
  out.I64(request);
  out.I32(status);
  out.I32(result);
  out.String(message);
  return Event(kind, out);
}

inline std::vector<uint8_t> VirtualCreated(int64_t request, int32_t status,
                                           int32_t handle,
                                           std::string_view endpoint_id,
                                           std::string_view message) {
  ByteWriter out;
  out.I64(request);
  out.I32(status);
  out.I32(handle);
  out.String(endpoint_id);
  out.String(message);
  return Event(AMW_EVENT_VIRTUAL_CREATED, out);
}

inline std::vector<uint8_t> Error(int32_t status, uint32_t source,
                                  std::string_view api,
                                  std::string_view message) {
  ByteWriter out;
  out.I32(status);
  out.U32(source);
  out.String(api);
  out.String(message);
  return Event(AMW_EVENT_ERROR, out);
}

inline std::vector<uint8_t> EventsDropped(uint64_t count) {
  ByteWriter out;
  out.U64(count);
  return Event(AMW_EVENT_EVENTS_DROPPED, out);
}

}  // namespace events

// Reads a virtual device specification; returns nothing when it is
// malformed.
inline std::optional<VirtualDeviceSpec> ReadVirtualDeviceSpec(
    const uint8_t* data, size_t size) {
  ByteReader in(data, size);
  VirtualDeviceSpec spec;
  if (!in.String(spec.name) || !in.String(spec.description) ||
      !in.String(spec.manufacturer) || !in.String(spec.product_instance_id) ||
      !in.U32(spec.flags) || !in.U8(spec.first_group) ||
      !in.U8(spec.group_count) || !in.U8(spec.direction) || !in.AtEnd()) {
    return std::nullopt;
  }
  if (spec.first_group > 15 || spec.group_count < 1 ||
      spec.first_group + spec.group_count > 16 || spec.direction < 1 ||
      spec.direction > 3) {
    return std::nullopt;
  }
  return spec;
}

// ###########################################################################
// Buffers

// The queue of whole events between the WinRT threads and the reader.
class EventQueue {
 public:
  explicit EventQueue(size_t max_bytes) noexcept : max_bytes_(max_bytes) {}

  // Appends event; returns false and counts it when the queue is full.
  bool Push(std::vector<uint8_t> event) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (event.size() > max_bytes_ - bytes_) {
      ++dropped_;
      return false;
    }
    bytes_ += event.size();
    events_.push_back(std::move(event));
    return true;
  }

  // Moves whole events into buffer, an EVENTS_DROPPED event first when
  // events were lost; see amw_read_events.
  int32_t Read(uint8_t* buffer, int32_t capacity, int32_t* length) {
    if (length == nullptr || capacity < 0 ||
        (buffer == nullptr && capacity > 0)) {
      return AMW_E_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const auto limit = static_cast<size_t>(capacity);
    size_t written = 0;
    if (dropped_ > 0) {
      const auto event = events::EventsDropped(dropped_);
      if (event.size() > limit) {
        *length = static_cast<int32_t>(event.size());
        return AMW_E_BUFFER_TOO_SMALL;
      }
      std::memcpy(buffer, event.data(), event.size());
      written = event.size();
      dropped_ = 0;
    }
    while (!events_.empty() && events_.front().size() <= limit - written) {
      const auto& event = events_.front();
      std::memcpy(buffer + written, event.data(), event.size());
      written += event.size();
      bytes_ -= event.size();
      events_.pop_front();
    }
    if (written == 0 && !events_.empty()) {
      *length = static_cast<int32_t>(events_.front().size());
      return AMW_E_BUFFER_TOO_SMALL;
    }
    *length = static_cast<int32_t>(written);
    return AMW_OK;
  }

 private:
  std::mutex mutex_;
  std::deque<std::vector<uint8_t>> events_;
  size_t bytes_ = 0;
  size_t max_bytes_;
  uint64_t dropped_ = 0;
};

// The ring buffer of one input port: the WinRT receive thread writes data
// records, the reader moves them out. A short mutex guards both sides; a
// record that does not fit is dropped and counted.
class PortQueue {
 public:
  // The size of the record header: time, flags and payload length.
  static constexpr size_t kHeaderSize = 16;

  explicit PortQueue(size_t capacity) : ring_(capacity < 64 ? 64 : capacity) {}

  // Appends a record; returns false when it was dropped or the queue is
  // closed.
  bool Push(int64_t time_us, uint32_t flags, const uint8_t* data,
            uint32_t size) {
    std::lock_guard<std::mutex> lock(mutex_);
    return PushLocked(time_us, flags, data, size);
  }

  // Appends a record whose time is the time since the port was opened; the
  // clock set by StartSinceOpenClock maps it to the native clock.
  bool PushSinceOpen(int64_t since_open_us, int64_t now_us, uint32_t flags,
                     const uint8_t* data, uint32_t size) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!since_open_.has_value()) since_open_.emplace(now_us);
    return PushLocked(since_open_->Map(since_open_us, now_us), flags, data,
                      size);
  }

  // Sets the base of the clock of PushSinceOpen, the native time at which
  // the port was opened.
  void StartSinceOpenClock(int64_t base_us) {
    std::lock_guard<std::mutex> lock(mutex_);
    since_open_.emplace(base_us);
  }

  // Moves whole records into buffer; see amw_port_read.
  int32_t Read(uint8_t* buffer, int32_t capacity, int32_t* length,
               int64_t* dropped) {
    if (length == nullptr || dropped == nullptr || capacity < 0 ||
        (buffer == nullptr && capacity > 0)) {
      return AMW_E_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const auto limit = static_cast<size_t>(capacity);
    size_t written = 0;
    while (used_ > 0) {
      uint8_t header[kHeaderSize];
      CopyOut(head_, header, kHeaderSize);
      const size_t total = kHeaderSize + LoadU32(header + 12);
      if (total > limit - written) {
        if (written == 0) {
          *length = static_cast<int32_t>(total);
          *dropped = 0;
          return AMW_E_BUFFER_TOO_SMALL;
        }
        break;
      }
      CopyOut(head_, buffer + written, total);
      head_ = (head_ + total) % ring_.size();
      used_ -= total;
      written += total;
    }
    if (used_ == 0) head_ = 0;
    *length = static_cast<int32_t>(written);
    *dropped = static_cast<int64_t>(dropped_);
    dropped_ = 0;
    return AMW_OK;
  }

  // Stops accepting records; later pushes are discarded without counting.
  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
  }

  bool IsClosed() {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
  }

 private:
  static uint32_t LoadU32(const uint8_t* bytes) noexcept {
    return static_cast<uint32_t>(bytes[0]) |
           static_cast<uint32_t>(bytes[1]) << 8 |
           static_cast<uint32_t>(bytes[2]) << 16 |
           static_cast<uint32_t>(bytes[3]) << 24;
  }

  bool PushLocked(int64_t time_us, uint32_t flags, const uint8_t* data,
                  uint32_t size) {
    if (closed_) return false;
    const size_t total = kHeaderSize + size;
    if (total > ring_.size() - used_) {
      ++dropped_;
      return false;
    }
    ByteWriter header;
    header.I64(time_us);
    header.U32(flags);
    header.U32(size);
    const size_t tail = (head_ + used_) % ring_.size();
    CopyIn(tail, header.data().data(), kHeaderSize);
    CopyIn((tail + kHeaderSize) % ring_.size(), data, size);
    used_ += total;
    return true;
  }

  void CopyIn(size_t offset, const uint8_t* data, size_t size) {
    if (size == 0) return;
    const size_t first = size < ring_.size() - offset ? size
                                                      : ring_.size() - offset;
    std::memcpy(ring_.data() + offset, data, first);
    if (size > first) std::memcpy(ring_.data(), data + first, size - first);
  }

  void CopyOut(size_t offset, uint8_t* data, size_t size) const {
    if (size == 0) return;
    const size_t first = size < ring_.size() - offset ? size
                                                      : ring_.size() - offset;
    std::memcpy(data, ring_.data() + offset, first);
    if (size > first) std::memcpy(data + first, ring_.data(), size - first);
  }

  std::mutex mutex_;
  std::vector<uint8_t> ring_;
  size_t head_ = 0;
  size_t used_ = 0;
  uint64_t dropped_ = 0;
  bool closed_ = false;
  std::optional<SinceOpenClock> since_open_;
};

// ###########################################################################
// Threading

// Counts the callbacks running inside the shim, so that shutdown can wait
// until none touches the signal function or the buffers any more.
class CallbackGate {
 public:
  // Enters the gate; returns false once it is closed.
  bool Enter() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return false;
    ++inside_;
    return true;
  }

  void Leave() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (--inside_ == 0) idle_.notify_all();
  }

  // Closes the gate and waits until every entered callback left. Must not
  // be called from inside the gate.
  void CloseAndWait() {
    std::unique_lock<std::mutex> lock(mutex_);
    closed_ = true;
    idle_.wait(lock, [this] { return inside_ == 0; });
  }

  bool IsClosed() {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
  }

 private:
  std::mutex mutex_;
  std::condition_variable idle_;
  int inside_ = 0;
  bool closed_ = false;
};

// Enters a CallbackGate for one scope.
class GateGuard {
 public:
  explicit GateGuard(CallbackGate& gate) : gate_(gate), entered_(gate.Enter()) {}

  ~GateGuard() {
    if (entered_) gate_.Leave();
  }

  GateGuard(const GateGuard&) = delete;
  GateGuard& operator=(const GateGuard&) = delete;

  explicit operator bool() const noexcept { return entered_; }

 private:
  CallbackGate& gate_;
  bool entered_;
};

// Calls the signal function at most once until the reader rearms it.
//
// The reader rearms before it drains. A producer that pushes after the
// drain read its queue then sees the flag cleared and signals again, so no
// wake-up is lost.
class Signaller {
 public:
  explicit Signaller(amw_signal_fn signal) noexcept : signal_(signal) {}

  void Notify() {
    if (signal_ != nullptr && !pending_.exchange(true)) signal_();
  }

  void Rearm() noexcept { pending_.store(false); }

 private:
  amw_signal_fn signal_;
  std::atomic<bool> pending_{false};
};

// A thread that runs posted tasks one after the other.
class Worker {
 public:
  // Starts the thread; it calls on_start first and on_stop last.
  Worker(std::function<void()> on_start, std::function<void()> on_stop)
      : on_start_(std::move(on_start)), on_stop_(std::move(on_stop)) {
    thread_ = std::thread([this] { Run(); });
  }

  ~Worker() { StopAndJoin(); }

  Worker(const Worker&) = delete;
  Worker& operator=(const Worker&) = delete;

  // Queues task; returns false once the worker stops.
  bool Post(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return false;
      tasks_.push_back(std::move(task));
    }
    wake_.notify_one();
    return true;
  }

  // Runs task on the worker and returns its result, or stopped when the
  // worker no longer runs tasks or task throws. Runs task directly when
  // called on the worker itself.
  template <typename T>
  T Call(std::function<T()> task, T stopped) {
    if (IsWorkerThread()) return task();
    auto promise = std::make_shared<std::promise<T>>();
    auto result = promise->get_future();
    if (!Post([promise, task = std::move(task), stopped] {
          try {
            promise->set_value(task());
          } catch (...) {
            promise->set_value(stopped);
          }
        })) {
      return stopped;
    }
    return result.get();
  }

  // Runs the queued tasks, stops the thread and joins it. The worker must
  // not be destroyed by one of its own tasks.
  void StopAndJoin() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    wake_.notify_all();
    if (thread_.joinable() && !IsWorkerThread()) thread_.join();
  }

  bool IsWorkerThread() const noexcept {
    return std::this_thread::get_id() == thread_.get_id();
  }

 private:
  void Run() {
    if (on_start_) on_start_();
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        wake_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
        if (tasks_.empty()) break;
        task = std::move(tasks_.front());
        tasks_.pop_front();
      }
      try {
        task();
      } catch (...) {
        // A task reports its own failures; none may end the worker.
      }
    }
    if (on_stop_) on_stop_();
  }

  std::function<void()> on_start_;
  std::function<void()> on_stop_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;
};

// ###########################################################################
// Bluetooth LE

// Picks the advertisements of BLE-MIDI peripherals worth reporting from the
// stream a scan delivers: the first one of a peripheral, a new name, a
// clear change of the signal strength, and a refresh every second.
//
// Names often arrive in scan responses, which do not carry the service
// UUID, so names are remembered for every address.
class BleAdvertisementFilter {
 public:
  static constexpr int32_t kRssiStep = 6;
  static constexpr int64_t kRefreshUs = 1000000;
  static constexpr size_t kMaxEntries = 512;

  // Returns the advertisement to report, or nothing. connectable is empty
  // for packets that do not tell, such as scan responses.
  std::optional<BleAdvertisement> Accept(uint64_t address, bool midi_service,
                                         std::string_view name, int32_t rssi,
                                         std::optional<bool> connectable,
                                         int64_t now_us) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (entries_.size() >= kMaxEntries && entries_.count(address) == 0) {
      Prune();
    }
    Entry& entry = entries_[address];
    if (midi_service) entry.is_midi = true;
    bool renamed = false;
    if (!name.empty() && name != entry.name) {
      entry.name = std::string(name);
      renamed = true;
    }
    if (connectable.has_value()) entry.connectable = *connectable;
    if (!entry.is_midi) return std::nullopt;
    const bool due = !entry.reported || renamed ||
                     std::abs(rssi - entry.reported_rssi) >= kRssiStep ||
                     now_us - entry.reported_at_us >= kRefreshUs;
    if (!due) return std::nullopt;
    entry.reported = true;
    entry.reported_rssi = rssi;
    entry.reported_at_us = now_us;
    BleAdvertisement result;
    result.address = address;
    result.rssi = rssi;
    result.flags = entry.connectable ? AMW_BLE_CONNECTABLE : 0;
    result.name = entry.name;
    return result;
  }

  // Forgets every peripheral, e.g. when a new scan starts.
  void Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.clear();
  }

 private:
  struct Entry {
    bool is_midi = false;
    bool reported = false;
    bool connectable = true;
    std::string name;
    int32_t reported_rssi = 0;
    int64_t reported_at_us = 0;
  };

  // Drops the peripherals without the MIDI service, or all when that is not
  // enough.
  void Prune() {
    for (auto it = entries_.begin(); it != entries_.end();) {
      it = it->second.is_midi ? std::next(it) : entries_.erase(it);
    }
    if (entries_.size() >= kMaxEntries) entries_.clear();
  }

  std::mutex mutex_;
  std::map<uint64_t, Entry> entries_;
};

// ###########################################################################
// Errors

// Returns the message of the last failure on the calling thread.
inline std::string& LastErrorMessage() {
  thread_local std::string message;
  return message;
}

// Stores message as the last failure on the calling thread and returns
// status.
inline int32_t Fail(int32_t status, std::string message) {
  LastErrorMessage() = std::move(message);
  return status;
}

// Copies the last failure on the calling thread; see amw_last_error.
inline int32_t CopyLastError(uint8_t* buffer, int32_t capacity) {
  const std::string& message = LastErrorMessage();
  if (buffer != nullptr && capacity > 0) {
    const size_t count = message.size() < static_cast<size_t>(capacity)
                             ? message.size()
                             : static_cast<size_t>(capacity);
    if (count > 0) std::memcpy(buffer, message.data(), count);
  }
  return static_cast<int32_t>(message.size());
}

}  // namespace amw

#endif  // AUD_MIDI_WINDOWS_CORE_H_
