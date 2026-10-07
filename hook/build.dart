// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds the C++/WinRT shim `src/aud_midi_windows.cpp` into the code asset
/// `package:aud_midi_windows/aud_midi_windows_shim` when the target is
/// Windows, and nothing for other targets, so that the aud_midi umbrella
/// builds everywhere.
///
/// MSVC (`cl.exe`, found by native_toolchain_c through vswhere) compiles it
/// as C++20 with exceptions and links `WindowsApp.lib`. The C++/WinRT
/// headers of the Windows SDK (`Include/<version>/cppwinrt`) are on the
/// include path of the MSVC environment.
///
/// Windows MIDI Services is opt-in through user-defines in the
/// `pubspec.yaml` of the app (`hooks: user_defines: aud_midi_windows:`):
///
/// - `midi2: true` compiles the Windows.Devices.Midi2 path
///   (`AUD_MIDI_WITH_MIDI2`).
/// - `midi2_include: <folder>` the C++/WinRT projection that cppwinrt
///   generated from the Windows.Devices.Midi2 winmd, searched before the
///   Windows SDK; see the README.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS != OS.windows) return;
    final midi2 = input.userDefines['midi2'] == true;
    final midi2Include = input.userDefines.path('midi2_include');
    await CBuilder.library(
      name: 'aud_midi_windows',
      assetName: 'aud_midi_windows_shim',
      sources: const ['src/aud_midi_windows.cpp'],
      includes: [if (midi2Include != null) midi2Include.toFilePath(), 'src'],
      language: Language.cpp,
      std: 'c++20',
      flags: const ['/EHsc', '/permissive-', '/bigobj', '/utf-8'],
      defines: {
        'NOMINMAX': null,
        'UNICODE': null,
        '_UNICODE': null,
        if (midi2) 'AUD_MIDI_WITH_MIDI2': '1',
      },
      libraries: const ['WindowsApp', 'ole32'],
    ).run(input: input, output: output);
  });
}
