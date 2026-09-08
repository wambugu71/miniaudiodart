// =============================================================================
// test/verify_64bit_oversampling.dart
//
// Verification of Dart/FFI bindings for:
//   1. 64-bit float DSP processing mode (set64BitProcessingEnabled)
//   2. Native DSP oversampling factor (setDspOversampling / getDspOversampling)
// =============================================================================

import 'dart:io';
import '../lib/audio_engine_ffi.dart';

void main() {
  print('=== Testing 64-bit Processing & Oversampling FFI Bindings ===');

  final engine = AudioEngineFFI(libraryPath: 'audio_engine.dll');
  final created = engine.create(sampleRate: 48000, channels: 2);
  if (!created) {
    throw Exception('Failed to create AudioEngine');
  }
  print('AudioEngine created successfully.');

  // 1. Test 64-bit processing mode
  final initial64 = engine.get64BitProcessingEnabled();
  print('1. Initial 64-bit processing: $initial64 (expected false by default)');

  engine.set64BitProcessingEnabled(true);
  final enabled64 = engine.get64BitProcessingEnabled();
  print('   Enabled 64-bit processing: $enabled64 (expected true)');
  if (!enabled64) {
    throw Exception('Failed to enable 64-bit processing!');
  }

  engine.set64BitProcessingEnabled(false);
  final disabled64 = engine.get64BitProcessingEnabled();
  print('   Disabled 64-bit processing: $disabled64 (expected false)');
  if (disabled64) {
    throw Exception('Failed to disable 64-bit processing!');
  }

  // Re-enable 64-bit processing
  engine.set64BitProcessingEnabled(true);

  // 2. Test DSP Oversampling
  final initialOS = engine.getDspOversampling();
  print('2. Initial dspOversampling: ${initialOS}x (expected 1x)');
  if (initialOS != 1) {
    throw Exception('Expected default oversampling factor 1x, got ${initialOS}x');
  }

  engine.setDspOversampling(2);
  final os2 = engine.getDspOversampling();
  print('   Set to 2x: ${os2}x (expected 2x)');
  if (os2 != 2) {
    throw Exception('Failed to set oversampling to 2x, got ${os2}x');
  }

  engine.setDspOversampling(4);
  final os4 = engine.getDspOversampling();
  print('   Set to 4x: ${os4}x (expected 4x)');
  if (os4 != 4) {
    throw Exception('Failed to set oversampling to 4x, got ${os4}x');
  }

  // Clamping test: factor 3 should clamp to 4x
  engine.setDspOversampling(3);
  final os3Clamped = engine.getDspOversampling();
  print('   Set to 3 (clamped): ${os3Clamped}x (expected 4x)');
  if (os3Clamped != 4) {
    throw Exception('Expected 3 to clamp to 4x, got ${os3Clamped}x');
  }

  // Clamping test: factor 0 should clamp to 1x
  engine.setDspOversampling(0);
  final os0Clamped = engine.getDspOversampling();
  print('   Set to 0 (clamped): ${os0Clamped}x (expected 1x)');
  if (os0Clamped != 1) {
    throw Exception('Expected 0 to clamp to 1x, got ${os0Clamped}x');
  }

  engine.dispose();
  print('Engine destroyed cleanly.');
  print('=== All 64-bit Processing & Oversampling FFI Tests Passed! ===');
  exit(0);
}
