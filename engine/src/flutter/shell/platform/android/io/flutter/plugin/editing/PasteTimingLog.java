// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugin.editing;

import android.os.SystemClock;
import android.util.Log;
import androidx.annotation.NonNull;

/**
 * EXPERIMENT ONLY (https://github.com/flutter/flutter/issues/184902): writes to the device log how
 * long it took from a tap on Paste in Android's toolbar to the clipboard read that follows.
 *
 * <p>Android 17 trusts that read for 1000 ms after the tap. The log lines let a script compare the
 * three ways of pasting (see {@link SystemContextMenuPlugin.PasteStrategy}):
 *
 * <pre>
 *   I/SystemContextMenu: PASTE_TAP strategy=flutterReadsAndInserts
 *   I/SystemContextMenu: PASTE_READ strategy=flutterReadsAndInserts msAfterTap=7.250 reader=PlatformPlugin
 * </pre>
 *
 * <p>All calls happen on the Android main thread, so plain static fields are enough.
 */
public final class PasteTimingLog {
  private static final String TAG = "SystemContextMenu";

  /** A read later than this after the tap is not counted as belonging to it. */
  private static final long MAX_AGE_MILLIS = 10_000;

  /** {@link SystemClock#elapsedRealtimeNanos()} at the last tap, or -1 once a read was logged. */
  private static long lastTapNanos = -1;

  @NonNull private static String lastStrategy = "";

  /** The tap time again, kept after the read so that a later answer can be timed too. */
  private static long lastTapNanosForAnswer = -1;

  private PasteTimingLog() {}

  /**
   * Call when the Paste item of Android's toolbar is tapped.
   *
   * @param tapNanos {@link SystemClock#elapsedRealtimeNanos()} taken on the first line of {@code
   *     onActionItemClicked}.
   */
  static void onPasteTapped(long tapNanos, @NonNull String strategy) {
    lastTapNanos = tapNanos;
    lastTapNanosForAnswer = tapNanos;
    lastStrategy = strategy;
    Log.i(TAG, "PASTE_TAP strategy=" + strategy);
  }

  /** Call on the line before {@code ClipboardManager.getPrimaryClip()}. */
  public static void beforeClipboardRead(@NonNull String reader) {
    if (lastTapNanos < 0) {
      return;
    }
    final long nanosAfterTap = SystemClock.elapsedRealtimeNanos() - lastTapNanos;
    lastTapNanos = -1;
    if (nanosAfterTap > MAX_AGE_MILLIS * 1_000_000) {
      return;
    }
    Log.i(
        TAG,
        "PASTE_READ strategy="
            + lastStrategy
            + " msAfterTap="
            + millis(nanosAfterTap)
            + " reader="
            + reader);
  }

  /**
   * Call when the framework's "Clipboard.getData" is answered from the text that was read at the
   * tap. Logs how long the framework took to ask: the round trip Android -> Dart -> Android.
   */
  public static void servedFromKeptText() {
    if (lastTapNanosForAnswer < 0) {
      return;
    }
    final long nanosAfterTap = SystemClock.elapsedRealtimeNanos() - lastTapNanosForAnswer;
    lastTapNanosForAnswer = -1;
    Log.i(
        TAG,
        "PASTE_ANSWERED_FROM_KEPT_TEXT strategy="
            + lastStrategy
            + " msAfterTap="
            + millis(nanosAfterTap));
  }

  /** Milliseconds with three decimals, e.g. "0.412". */
  @NonNull
  private static String millis(long nanos) {
    return (nanos / 1_000_000) + "." + String.format("%03d", (nanos / 1_000) % 1_000);
  }
}
