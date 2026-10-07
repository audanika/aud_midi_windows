// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Tests the portable core of the shim (src/aud_midi_windows_core.h) on any
// platform and checks the golden files in test/goldens that the Dart
// decoders read. Build and run it with tool/test_native_core.sh; pass
// --update to rewrite the golden files after a deliberate format change.

#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "aud_midi_windows_core.h"

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition)                                              \
  do {                                                                \
    ++checks;                                                         \
    if (!(condition)) {                                               \
      ++failures;                                                     \
      std::cerr << __FILE__ << ":" << __LINE__ << ": " #condition "\n"; \
    }                                                                 \
  } while (false)

std::string Hex(const std::vector<uint8_t>& bytes) {
  static constexpr char kDigits[] = "0123456789abcdef";
  std::string text;
  for (const uint8_t byte : bytes) {
    text.push_back(kDigits[byte >> 4]);
    text.push_back(kDigits[byte & 0xF]);
  }
  return text;
}

std::vector<uint8_t> Unhex(const std::string& text) {
  std::vector<uint8_t> bytes;
  for (size_t i = 0; i + 1 < text.size(); i += 2) {
    bytes.push_back(static_cast<uint8_t>(std::stoi(text.substr(i, 2), nullptr,
                                                   16)));
  }
  return bytes;
}

// Reads the non-comment lines of a golden file.
std::vector<std::string> ReadLines(const std::string& path) {
  std::ifstream file(path);
  std::vector<std::string> lines;
  std::string line;
  while (std::getline(file, line)) {
    if (!line.empty() && line[0] != '#') lines.push_back(line);
  }
  return lines;
}

// Writes or checks a golden file: a comment header, then one hex line per
// entry.
void Golden(const std::string& path, const std::string& header,
            const std::vector<std::vector<uint8_t>>& entries, bool update) {
  std::vector<std::string> lines;
  for (const auto& entry : entries) lines.push_back(Hex(entry));
  if (update) {
    std::ofstream file(path);
    file << header;
    for (const auto& line : lines) file << line << "\n";
    return;
  }
  const auto existing = ReadLines(path);
  CHECK(existing == lines);
  if (existing != lines) std::cerr << "golden mismatch: " << path << "\n";
}

// ###########################################################################
// Clock arithmetic

void TestClock() {
  CHECK(amw::TicksToMicros(10000000, 10000000) == 1000000);
  CHECK(amw::TicksToMicros(15, 10) == 1500000);
  CHECK(amw::TicksToMicros(1, 3) == 333333);
  CHECK(amw::TicksToMicros(5, 0) == 0);
  // A year of uptime at 10 MHz does not overflow.
  const int64_t year = 365LL * 24 * 3600;
  CHECK(amw::TicksToMicros(year * 10000000, 10000000) == year * 1000000);
  CHECK(amw::TicksToMicros(year * 10000000 + 7, 10000000) ==
        year * 1000000);
  CHECK(amw::MicrosToTicks(1500000, 10) == 15);
  CHECK(amw::MicrosToTicks(year * 1000000, 10000000) == year * 10000000);
  CHECK(amw::MicrosToTicks(1, 10000000) == 10);

  amw::SinceOpenClock clock(1000);
  CHECK(clock.Map(500, 2000) == 1500);
  // A time in the future is clamped to now.
  CHECK(clock.Map(5000, 3000) == 3000);
  // Time never runs backwards.
  CHECK(clock.Map(100, 4000) == 3000);
  CHECK(clock.Map(2500, 4000) == 3500);
}

// ###########################################################################
// Byte formats

void TestBytes() {
  amw::ByteWriter writer;
  writer.U8(0x12);
  writer.U16(0x3456);
  writer.U32(0x789ABCDE);
  writer.U64(0x0102030405060708ULL);
  writer.I32(-2);
  writer.I64(-3);
  writer.String("ab");
  writer.String("");
  writer.Bytes(nullptr, 0);
  CHECK(Hex(writer.data()) ==
        "12" "5634" "debc9a78" "0807060504030201" "feffffff"
        "fdffffffffffffff" "020000006162" "00000000");

  const auto bytes = writer.Take();
  CHECK(writer.data().empty());
  amw::ByteReader reader(bytes.data(), bytes.size());
  uint8_t u8 = 0;
  uint32_t u32 = 0;
  std::string text;
  CHECK(reader.U8(u8) && u8 == 0x12);
  CHECK(reader.U8(u8) && u8 == 0x56);
  CHECK(reader.U8(u8) && u8 == 0x34);
  CHECK(reader.U32(u32) && u32 == 0x789ABCDE);
  CHECK(!reader.AtEnd());

  const std::vector<uint8_t> strings = Unhex("0200000061620000000005000000");
  amw::ByteReader string_reader(strings.data(), strings.size());
  CHECK(string_reader.String(text) && text == "ab");
  CHECK(string_reader.String(text) && text.empty());
  // A length beyond the data fails.
  CHECK(!string_reader.String(text));

  amw::ByteReader empty(nullptr, 10);
  CHECK(!empty.U8(u8));
  CHECK(!empty.U32(u32));
  CHECK(empty.AtEnd());

  const uint8_t data4[8] = {0xA7, 0x51, 0x6C, 0xE3, 0x4E, 0xC4, 0xC7, 0x00};
  CHECK(amw::FormatGuid(0x03B80E5A, 0xEDE8, 0x4B33, data4) ==
        "{03b80e5a-ede8-4b33-a751-6ce34ec4c700}");
}

// ###########################################################################
// MIDI framing

std::vector<std::string> Split(const std::string& hex) {
  const auto bytes = Unhex(hex);
  std::vector<std::string> chunks;
  amw::SplitMidi1(bytes.data(), bytes.size(), [&](size_t offset, size_t size) {
    chunks.push_back(Hex(std::vector<uint8_t>(
        bytes.begin() + static_cast<std::ptrdiff_t>(offset),
        bytes.begin() + static_cast<std::ptrdiff_t>(offset + size))));
  });
  return chunks;
}

void TestFraming() {
  CHECK(amw::UmpWordCount(0x00000000) == 1);
  CHECK(amw::UmpWordCount(0x20903C64) == 1);
  CHECK(amw::UmpWordCount(0x30160102) == 2);
  CHECK(amw::UmpWordCount(0x40903C00) == 2);
  CHECK(amw::UmpWordCount(0x50000000) == 4);
  CHECK(amw::UmpWordCount(0x60000000) == 1);
  CHECK(amw::UmpWordCount(0x80000000) == 2);
  CHECK(amw::UmpWordCount(0xB0000000) == 3);
  CHECK(amw::UmpWordCount(0xD0000000) == 4);
  CHECK(amw::UmpWordCount(0xF0000000) == 4);

  CHECK(Split("") == std::vector<std::string>{});
  CHECK(Split("903c64803c00") ==
        (std::vector<std::string>{"903c64", "803c00"}));
  CHECK(Split("c005d040f8fe") ==
        (std::vector<std::string>{"c005", "d040", "f8", "fe"}));
  CHECK(Split("f07e7f0601f7903c64") ==
        (std::vector<std::string>{"f07e7f0601f7", "903c64"}));
  // Real-time bytes stay inside System Exclusive.
  CHECK(Split("f00102f803f7") == (std::vector<std::string>{"f00102f803f7"}));
  // An unterminated System Exclusive ends at the next status byte.
  CHECK(Split("f00102903c64") ==
        (std::vector<std::string>{"f00102", "903c64"}));
  CHECK(Split("f00102") == (std::vector<std::string>{"f00102"}));
  // Running status stays with its status byte, leading data bytes form a
  // chunk of their own.
  CHECK(Split("3c64903c643e64") ==
        (std::vector<std::string>{"3c64", "903c643e64"}));
  CHECK(Split("f6f20010") == (std::vector<std::string>{"f6", "f20010"}));
}

// ###########################################################################
// Buffers

void TestEventQueue() {
  amw::EventQueue queue(64);
  std::vector<uint8_t> buffer(256);
  int32_t length = -1;
  CHECK(queue.Read(buffer.data(), 256, &length) == AMW_OK && length == 0);
  CHECK(queue.Read(nullptr, 4, &length) == AMW_E_INVALID_ARGUMENT);
  CHECK(queue.Read(buffer.data(), -1, &length) == AMW_E_INVALID_ARGUMENT);
  CHECK(queue.Read(buffer.data(), 4, nullptr) == AMW_E_INVALID_ARGUMENT);

  const auto first = amw::events::EnumerationCompleted(1);
  const auto second = amw::events::PortDisconnected(7);
  CHECK(first.size() == 12);
  CHECK(queue.Push(first));
  CHECK(queue.Push(second));
  // Only whole events move.
  CHECK(queue.Read(buffer.data(), 20, &length) == AMW_OK && length == 12);
  CHECK(std::vector<uint8_t>(buffer.begin(), buffer.begin() + 12) == first);
  CHECK(queue.Read(buffer.data(), 5, &length) == AMW_E_BUFFER_TOO_SMALL &&
        length == 12);
  CHECK(queue.Read(buffer.data(), 256, &length) == AMW_OK && length == 12);
  CHECK(std::vector<uint8_t>(buffer.begin(), buffer.begin() + 12) == second);

  // A full queue drops and reports the loss first.
  for (int i = 0; i < 5; ++i) CHECK(queue.Push(first));
  CHECK(!queue.Push(first));
  CHECK(!queue.Push(first));
  const auto dropped = amw::events::EventsDropped(2);
  CHECK(queue.Read(buffer.data(), 8, &length) == AMW_E_BUFFER_TOO_SMALL &&
        length == static_cast<int32_t>(dropped.size()));
  CHECK(queue.Read(buffer.data(), 30, &length) == AMW_OK &&
        length == static_cast<int32_t>(dropped.size() + first.size()));
  CHECK(std::vector<uint8_t>(buffer.begin(),
                             buffer.begin() + static_cast<std::ptrdiff_t>(
                                                  dropped.size())) == dropped);
  CHECK(queue.Read(buffer.data(), 256, &length) == AMW_OK && length == 48);
  CHECK(queue.Read(buffer.data(), 256, &length) == AMW_OK && length == 0);
}

void TestPortQueue() {
  amw::PortQueue queue(64);
  std::vector<uint8_t> buffer(256);
  int32_t length = -1;
  int64_t dropped = -1;
  CHECK(queue.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        length == 0 && dropped == 0);
  CHECK(queue.Read(nullptr, 1, &length, &dropped) == AMW_E_INVALID_ARGUMENT);
  CHECK(queue.Read(buffer.data(), 1, &length, nullptr) ==
        AMW_E_INVALID_ARGUMENT);

  const uint8_t note[] = {0x90, 0x3C, 0x64};
  CHECK(queue.Push(100, 0, note, 3));
  CHECK(queue.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        length == 19 && dropped == 0);
  CHECK(Hex(std::vector<uint8_t>(buffer.begin(), buffer.begin() + 19)) ==
        "6400000000000000" "00000000" "03000000" "903c64");

  // Records wrap around the end of the ring.
  for (int round = 0; round < 10; ++round) {
    CHECK(queue.Push(round, 1, note, 3));
    CHECK(queue.Push(round + 1, 1, note, 3));
    CHECK(queue.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
          length == 38);
    CHECK(buffer[0] == round && buffer[19] == round + 1);
    CHECK(buffer[16] == 0x90 && buffer[35] == 0x90 && buffer[37] == 0x64);
  }

  // A full ring drops the newest record and counts it.
  const std::vector<uint8_t> big(30, 0x11);
  CHECK(queue.Push(1, 0, big.data(), 30));
  CHECK(!queue.Push(2, 0, big.data(), 30));
  CHECK(!queue.Push(3, 0, big.data(), 30));
  CHECK(queue.Read(buffer.data(), 10, &length, &dropped) ==
            AMW_E_BUFFER_TOO_SMALL &&
        length == 46 && dropped == 0);
  CHECK(queue.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        length == 46 && dropped == 2);
  CHECK(queue.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        length == 0 && dropped == 0);

  // A partial read keeps the rest.
  CHECK(queue.Push(1, 0, note, 3));
  CHECK(queue.Push(2, 0, note, 3));
  CHECK(queue.Read(buffer.data(), 30, &length, &dropped) == AMW_OK &&
        length == 19);
  CHECK(queue.Read(buffer.data(), 30, &length, &dropped) == AMW_OK &&
        length == 19 && buffer[0] == 2);

  // Empty payloads are allowed.
  CHECK(queue.Push(5, 0, nullptr, 0));
  CHECK(queue.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        length == 16);

  // The since-open clock maps and orders times.
  amw::PortQueue timed(256);
  timed.StartSinceOpenClock(1000);
  CHECK(timed.PushSinceOpen(500, 2000, 0, note, 3));
  CHECK(timed.PushSinceOpen(9000, 2500, 0, note, 3));
  CHECK(timed.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        length == 38);
  CHECK(buffer[0] == 0xDC && buffer[1] == 0x05);
  CHECK(buffer[19] == 0xC4 && buffer[20] == 0x09);
  amw::PortQueue lazy(256);
  CHECK(lazy.PushSinceOpen(10, 777, 0, note, 3));
  CHECK(lazy.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        buffer[0] == 0x09 && buffer[1] == 0x03);

  // A closed queue discards silently.
  queue.Close();
  CHECK(queue.IsClosed());
  CHECK(!queue.Push(1, 0, note, 3));
  CHECK(queue.Read(buffer.data(), 256, &length, &dropped) == AMW_OK &&
        length == 0 && dropped == 0);

  // A tiny capacity grows to the minimum.
  amw::PortQueue tiny(1);
  CHECK(tiny.Push(1, 0, big.data(), 30));
}

// ###########################################################################
// Threading

int signals = 0;
void CountSignal() { ++signals; }

void TestThreading() {
  amw::CallbackGate gate;
  {
    amw::GateGuard guard(gate);
    CHECK(static_cast<bool>(guard));
  }
  std::atomic<bool> inside{false};
  std::atomic<bool> release{false};
  std::thread callback([&] {
    amw::GateGuard guard(gate);
    inside = true;
    while (!release) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  });
  while (!inside) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  std::atomic<bool> closed{false};
  std::thread closer([&] {
    gate.CloseAndWait();
    closed = true;
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  // Closing waits for the callback inside.
  CHECK(!closed);
  release = true;
  callback.join();
  closer.join();
  CHECK(closed);
  CHECK(gate.IsClosed());
  amw::GateGuard late(gate);
  CHECK(!static_cast<bool>(late));

  amw::Signaller signaller(CountSignal);
  signaller.Notify();
  signaller.Notify();
  CHECK(signals == 1);
  signaller.Rearm();
  signaller.Notify();
  CHECK(signals == 2);
  amw::Signaller silent(nullptr);
  silent.Notify();

  std::atomic<int> started{0};
  std::atomic<int> stopped{0};
  std::vector<int> order;
  {
    amw::Worker worker([&] { ++started; }, [&] { ++stopped; });
    CHECK(worker.Post([&] { order.push_back(1); }));
    CHECK(worker.Post([] { throw 1; }));
    CHECK(worker.Post([&] { order.push_back(2); }));
    CHECK(worker.Call<int>([&] { return worker.IsWorkerThread() ? 7 : 0; },
                           -1) == 7);
    CHECK(worker.Call<int>([]() -> int { throw 1; }, -1) == -1);
    CHECK(!worker.IsWorkerThread());
    // Tasks queued before the stop still run.
    CHECK(worker.Post([&] {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      order.push_back(3);
    }));
    worker.StopAndJoin();
    CHECK(!worker.Post([] {}));
    CHECK(worker.Call<int>([] { return 1; }, -1) == -1);
    worker.StopAndJoin();
  }
  CHECK(started == 1 && stopped == 1);
  CHECK(order == (std::vector<int>{1, 2, 3}));
}

// ###########################################################################
// Bluetooth LE

void TestBleFilter() {
  amw::BleAdvertisementFilter filter;
  // Devices without the MIDI service stay silent, but their names count.
  CHECK(!filter.Accept(1, false, "Synth", -50, std::nullopt, 0));
  auto first = filter.Accept(1, true, "", -50, true, 10);
  CHECK(first.has_value() && first->address == 1 && first->name == "Synth" &&
        first->rssi == -50 && first->flags == AMW_BLE_CONNECTABLE);
  // Nothing new.
  CHECK(!filter.Accept(1, true, "", -52, std::nullopt, 20));
  // A clear RSSI change.
  auto moved = filter.Accept(1, false, "", -60, std::nullopt, 30);
  CHECK(moved.has_value() && moved->rssi == -60);
  // A new name.
  auto renamed = filter.Accept(1, false, "Synth 2", -60, false, 40);
  CHECK(renamed.has_value() && renamed->name == "Synth 2" &&
        renamed->flags == 0);
  // The refresh.
  CHECK(!filter.Accept(1, false, "", -60, std::nullopt, 500000));
  CHECK(filter.Accept(1, false, "", -60, std::nullopt, 1000040).has_value());
  filter.Clear();
  CHECK(!filter.Accept(1, false, "", -60, std::nullopt, 1000050));

  // Pruning keeps the MIDI peripherals.
  amw::BleAdvertisementFilter crowded;
  CHECK(crowded.Accept(9999, true, "Keep", -40, true, 0).has_value());
  for (uint64_t address = 0; address < 600; ++address) {
    crowded.Accept(address, false, "", -70, std::nullopt, 0);
  }
  CHECK(!crowded.Accept(9999, true, "", -40, true, 10).has_value());
  amw::BleAdvertisementFilter full;
  for (uint64_t address = 0; address < 600; ++address) {
    full.Accept(address, true, "", -70, std::nullopt, 0);
  }
  CHECK(full.Accept(0, true, "", -70, std::nullopt, 1).has_value());
}

// ###########################################################################
// Errors

void TestErrors() {
  CHECK(amw::Fail(AMW_E_CLOSED, "closed") == AMW_E_CLOSED);
  uint8_t buffer[16] = {};
  CHECK(amw::CopyLastError(buffer, 16) == 6);
  CHECK(std::string(reinterpret_cast<char*>(buffer), 6) == "closed");
  CHECK(amw::CopyLastError(buffer, 3) == 6);
  CHECK(amw::CopyLastError(nullptr, 0) == 6);
  std::thread other([] { CHECK(amw::CopyLastError(nullptr, 0) == 0); });
  other.join();
}

// ###########################################################################
// Golden files

amw::PortRecord Midi1Port() {
  amw::PortRecord port;
  port.source = AMW_SOURCE_MIDI1_IN;
  port.id =
      "\\\\?\\SWD#MMDEVAPI#MIDII_4A3B2C1D.P_0000#"
      "{504be32c-ccf6-4d2c-b73f-6f8b3747e22b}";
  port.name = "Keystation 49";
  port.flags = AMW_PORT_ENABLED;
  port.device_instance_id = "USB\\VID_1C75&PID_0206&MI_01\\7&2A9D0B1C&0&0001";
  port.container_id = "{8e1f6d2a-3b4c-4d5e-8f60-718293a4b5c6}";
  return port;
}

amw::PortRecord BlePort() {
  amw::PortRecord port;
  port.source = AMW_SOURCE_MIDI1_OUT;
  port.id =
      "\\\\?\\BTHLEDEVICE#{03b80e5a-ede8-4b33-a751-6ce34ec4c700}_Dev_VID&"
      "0205e8_PID&2001_REV&0001_c0a1b2c3d4e5#8&1a2b3c4d&0&0010#"
      "{6dc23320-ab33-4ce4-80d4-bbb3ebbf2814}";
  port.name = "Ger\xC3\xA4t \xE2\x80\x94 \xF0\x9F\x8E\xB9";
  port.device_instance_id =
      "BTHLEDEVICE\\{03B80E5A-EDE8-4B33-A751-6CE34EC4C700}_DEV_VID&0205E8_PID&"
      "2001_REV&0001_C0A1B2C3D4E5\\8&1A2B3C4D&0&0010";
  return port;
}

amw::PortRecord Midi2Port() {
  amw::PortRecord port;
  port.source = AMW_SOURCE_MIDI2;
  port.id =
      "\\\\?\\swd#midisrv#midiu_ks_6799286025327820155_outpin.0_inpin.2#"
      "{e7cce071-3c03-423f-88d3-f1045d02552b}";
  port.name = "MIDI 2.0 Synth";
  port.flags = AMW_PORT_ENABLED;
  port.device_instance_id = "SWD\\MIDISRV\\MIDIU_KS_6799286025327820155";
  port.container_id = "{11111111-2222-3333-4444-555555555555}";
  amw::EndpointRecord endpoint;
  endpoint.purpose = 0;
  endpoint.native_data_format = 2;
  endpoint.transport_code = "KS";
  endpoint.manufacturer = "Audanika";
  endpoint.serial_number = "SN-42";
  endpoint.description = "A test synth";
  endpoint.vendor_id = 0x1234;
  endpoint.product_id = 0xABCD;
  endpoint.flags = AMW_ENDPOINT_SUPPORTS_MIDI1 | AMW_ENDPOINT_SUPPORTS_MIDI2 |
                   AMW_ENDPOINT_SUPPORTS_RX_JR | AMW_ENDPOINT_STATIC_BLOCKS |
                   AMW_ENDPOINT_HAS_IDENTITY | AMW_ENDPOINT_MULTI_CLIENT |
                   AMW_ENDPOINT_RECEIVES_JR |
                   AMW_ENDPOINT_DISCOVERY_COMPLETE;
  endpoint.endpoint_name = "Synth Endpoint";
  endpoint.product_instance_id = "PI-7";
  endpoint.declared_function_block_count = 2;
  endpoint.ump_version_major = 1;
  endpoint.ump_version_minor = 1;
  endpoint.protocol = 2;
  endpoint.identity = {0x00, 0x21, 0x09, 0x01, 0x02, 0x03, 0x04,
                       0x05, 0x06, 0x07, 0x08};
  amw::FunctionBlockRecord block0;
  block0.number = 0;
  block0.is_active = 1;
  block0.direction = 3;
  block0.ui_hint = 3;
  block0.midi1 = 0;
  block0.first_group = 0;
  block0.group_count = 2;
  block0.midi_ci_version = 1;
  block0.max_sysex8_streams = 4;
  block0.name = "Main";
  amw::FunctionBlockRecord block1;
  block1.number = 1;
  block1.is_active = 0;
  block1.direction = 1;
  block1.ui_hint = 1;
  block1.midi1 = 2;
  block1.first_group = 2;
  block1.group_count = 1;
  block1.name = "DIN In";
  endpoint.function_blocks = {block0, block1};
  amw::GroupTerminalBlockRecord terminal;
  terminal.number = 1;
  terminal.direction = 0;
  terminal.protocol = 0x11;
  terminal.first_group = 0;
  terminal.group_count = 3;
  terminal.name = "Terminal";
  endpoint.group_terminal_blocks = {terminal};
  port.endpoint = endpoint;
  return port;
}

std::vector<uint8_t> VirtualSpecBytes() {
  amw::ByteWriter out;
  out.String("aud_midi Out");
  out.String("A virtual port of aud_midi");
  out.String("Audanika");
  out.String("aud_midi-42");
  out.U32(AMW_VIRTUAL_MIDI2);
  out.U8(0);
  out.U8(1);
  out.U8(2);
  return out.Take();
}

void TestGoldens(const std::string& directory, bool update) {
  using namespace amw::events;
  Golden(directory + "/shim_events.hex",
         "# Events of the aud_midi_windows shim, one per line, written by\n"
         "# test/native/aud_midi_windows_core_test.cpp.\n",
         {
             Port(AMW_EVENT_PORT_ADDED, Midi1Port()),
             Port(AMW_EVENT_PORT_ADDED, BlePort()),
             Port(AMW_EVENT_PORT_UPDATED, Midi2Port()),
             PortRemoved(AMW_SOURCE_MIDI1_IN, Midi1Port().id),
             EnumerationCompleted(AMW_SOURCE_MIDI1_OUT),
             WatcherStopped(AMW_SOURCE_MIDI2, 5),
             OpenCompleted(41, AMW_OK, 3, ""),
             OpenCompleted(42, AMW_E_PORT_UNAVAILABLE, 0, "no port"),
             PortDisconnected(3),
             BleFound({0xC0A1B2C3D4E5ULL, -67, AMW_BLE_CONNECTABLE, "WIDI"}),
             BleScanStopped(1),
             BlePairing(AMW_EVENT_BLE_PAIR_COMPLETED, 43, AMW_OK, 0, ""),
             BlePairing(AMW_EVENT_BLE_UNPAIR_COMPLETED, 44, AMW_E_ACCESS_DENIED,
                        3, "denied"),
             VirtualCreated(45, AMW_OK, 9, "\\\\?\\swd#midisrv#midiu_app_1",
                            ""),
             Error(AMW_E_UNSUPPORTED, AMW_SOURCE_MIDI2,
                   "MidiEndpointDeviceWatcher", "not built in"),
             EventsDropped(3),
         },
         update);

  amw::PortQueue queue(1024);
  const uint8_t note[] = {0x90, 0x3C, 0x64};
  const uint8_t sysex[] = {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7};
  const uint8_t ump[] = {0x64, 0x00, 0x90, 0x40, 0x00, 0x00, 0x00, 0xC8};
  queue.Push(1000, 0, note, 3);
  queue.Push(-5, 0, sysex, 6);
  queue.Push(0x123456789ALL, AMW_RECORD_UMP, ump, 8);
  queue.Push(7, AMW_RECORD_UMP, nullptr, 0);
  std::vector<uint8_t> buffer(1024);
  int32_t length = 0;
  int64_t dropped = 0;
  queue.Read(buffer.data(), 1024, &length, &dropped);
  Golden(directory + "/shim_records.hex",
         "# Data records of amw_port_read in one buffer, written by\n"
         "# test/native/aud_midi_windows_core_test.cpp.\n",
         {std::vector<uint8_t>(buffer.begin(), buffer.begin() + length)},
         update);

  if (update) {
    Golden(directory + "/virtual_device_spec.hex",
           "# A virtual device specification as WindowsMidiVirtualPorts\n"
           "# encodes it; the shim parses it.\n",
           {VirtualSpecBytes()}, true);
  }
  const auto lines = ReadLines(directory + "/virtual_device_spec.hex");
  CHECK(lines.size() == 1);
  if (lines.size() == 1) {
    const auto bytes = Unhex(lines[0]);
    const auto spec = amw::ReadVirtualDeviceSpec(bytes.data(), bytes.size());
    CHECK(spec.has_value());
    if (spec.has_value()) {
      CHECK(spec->name == "aud_midi Out");
      CHECK(spec->description == "A virtual port of aud_midi");
      CHECK(spec->manufacturer == "Audanika");
      CHECK(spec->product_instance_id == "aud_midi-42");
      CHECK(spec->flags == AMW_VIRTUAL_MIDI2);
      CHECK(spec->first_group == 0 && spec->group_count == 1 &&
            spec->direction == 2);
    }
  }
}

void TestVirtualSpec() {
  auto bytes = VirtualSpecBytes();
  CHECK(amw::ReadVirtualDeviceSpec(bytes.data(), bytes.size()).has_value());
  CHECK(!amw::ReadVirtualDeviceSpec(bytes.data(), bytes.size() - 1));
  auto longer = bytes;
  longer.push_back(0);
  CHECK(!amw::ReadVirtualDeviceSpec(longer.data(), longer.size()));
  auto bad_group = bytes;
  bad_group[bad_group.size() - 3] = 16;
  CHECK(!amw::ReadVirtualDeviceSpec(bad_group.data(), bad_group.size()));
  auto bad_count = bytes;
  bad_count[bad_count.size() - 2] = 0;
  CHECK(!amw::ReadVirtualDeviceSpec(bad_count.data(), bad_count.size()));
  auto overflow = bytes;
  overflow[overflow.size() - 3] = 15;
  overflow[overflow.size() - 2] = 2;
  CHECK(!amw::ReadVirtualDeviceSpec(overflow.data(), overflow.size()));
  auto bad_direction = bytes;
  bad_direction[bad_direction.size() - 1] = 0;
  CHECK(!amw::ReadVirtualDeviceSpec(bad_direction.data(),
                                     bad_direction.size()));
  bad_direction[bad_direction.size() - 1] = 4;
  CHECK(!amw::ReadVirtualDeviceSpec(bad_direction.data(),
                                     bad_direction.size()));
  CHECK(!amw::ReadVirtualDeviceSpec(nullptr, 0));
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::cerr << "usage: aud_midi_windows_core_test <goldens dir> [--update]\n";
    return 2;
  }
  const bool update = argc > 2 && std::string(argv[2]) == "--update";
  TestClock();
  TestBytes();
  TestFraming();
  TestEventQueue();
  TestPortQueue();
  TestThreading();
  TestBleFilter();
  TestErrors();
  TestVirtualSpec();
  TestGoldens(argv[1], update);
  std::cout << checks << " checks, " << failures << " failures\n";
  return failures == 0 ? 0 : 1;
}
