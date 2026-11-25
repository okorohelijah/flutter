// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugin.editing;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Rect;
import android.os.SystemClock;
import android.view.ActionMode;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import io.flutter.Log;
import io.flutter.embedding.engine.systemchannels.PlatformChannel;
import io.flutter.embedding.engine.systemchannels.PlatformChannel.SystemContextMenuItem;
import io.flutter.embedding.engine.systemchannels.PlatformChannel.SystemContextMenuRequest;
import java.util.ArrayList;
import java.util.List;

/**
 * Shows Android's own floating text toolbar (the bar with Cut, Copy, Paste) when the Flutter
 * framework asks for the "system context menu".
 *
 * <p>EXPERIMENT for https://github.com/flutter/flutter/issues/184902. Not reviewed, not tested
 * beyond the manual runs described with the prototype.
 *
 * <p>Why: from Android 17 the toolbar is drawn by the system, not by the app. When the user taps
 * its Paste item, Android lets the app read the clipboard for one second without showing the
 * "pasted from your clipboard" message. A Paste button that Flutter draws itself never gets that.
 *
 * <p>How it fits together:
 *
 * <ol>
 *   <li>The framework sends "ContextMenu.showSystemContextMenu" with a rectangle and a list of
 *       items. {@link PlatformChannel} decodes it and calls {@link #showSystemContextMenu}.
 *   <li>This class calls {@link View#startActionMode(ActionMode.Callback, int)} on the Flutter
 *       view. Android then asks {@link #callback} which items to show and where.
 *   <li>When the user taps an item, Android calls {@link ActionMode.Callback#onActionItemClicked}.
 *       Android does not do the work: this class passes the tap on to the framework (or, for Paste,
 *       reads the clipboard first; see {@link PasteStrategy}).
 *   <li>The framework sends "ContextMenu.hideSystemContextMenu" when it wants the bar gone. If the
 *       bar goes away for any other reason, this class tells the framework.
 * </ol>
 */
public class SystemContextMenuPlugin implements PlatformChannel.SystemContextMenuHandler {
  private static final String TAG = "SystemContextMenu";

  /**
   * Experiment switch: who reads the clipboard after a tap on Paste, and who puts the text into the
   * field. The framework picks one with every show request, so one build can try all three.
   */
  enum PasteStrategy {
    /**
     * "A": read here, inside the tap handler, and insert with the code that already serves a
     * keyboard's paste request ({@link InputConnectionAdaptor#performContextMenuAction}). The
     * framework learns the new text as if it had been typed.
     */
    PLATFORM_READS_AND_INSERTS("platformReadsAndInserts"),

    /**
     * "A-prime": read here, inside the tap handler, and hand the text to the framework, which
     * inserts it with its normal paste code.
     */
    PLATFORM_READS_FLUTTER_INSERTS("platformReadsFlutterInserts"),

    /**
     * "A-kept": read here, inside the tap handler, and keep the text. Tell the framework only that
     * Paste was tapped. The framework pastes as it does today; when it asks for the clipboard with
     * "Clipboard.getData", {@link PlatformChannel} answers with the kept text instead of reading a
     * second time.
     */
    PLATFORM_READS_AND_KEEPS("platformReadsAndKeeps"),

    /**
     * "B": only tell the framework that Paste was tapped. The framework then asks for the clipboard
     * with "Clipboard.getData", as it does today for its own Paste button.
     */
    FLUTTER_READS_AND_INSERTS("flutterReadsAndInserts");

    @NonNull final String encodedName;

    PasteStrategy(@NonNull String encodedName) {
      this.encodedName = encodedName;
    }

    @NonNull
    static PasteStrategy fromValue(@NonNull String encodedName) {
      for (PasteStrategy strategy : values()) {
        if (strategy.encodedName.equals(encodedName)) {
          return strategy;
        }
      }
      return PLATFORM_READS_FLUTTER_INSERTS;
    }
  }

  // Android has standard ids for these four items. The id of Paste matters: on Android 17 the
  // system looks for android.R.id.paste to decide whether the following clipboard read is trusted.
  // Every other item gets FIRST_OTHER_ITEM_ID + its position in the list.
  private static final int FIRST_OTHER_ITEM_ID = Menu.FIRST + 100;

  // "A-kept" only: how long the text read at the tap waits for the framework to ask for it.
  private static final long KEPT_PASTE_TEXT_VALID_MILLIS = 5000;

  @NonNull private final View view;
  @NonNull private final PlatformChannel platformChannel;
  @NonNull private final TextInputPlugin textInputPlugin;

  /** The toolbar that is showing now, or null. */
  @Nullable private ActionMode actionMode;

  /** What the toolbar points at, in physical pixels inside {@link #view}. */
  @NonNull private final Rect contentRect = new Rect();

  /** The items of the last show request. */
  @NonNull private List<SystemContextMenuItem> items = new ArrayList<>();

  @NonNull private PasteStrategy pasteStrategy = PasteStrategy.PLATFORM_READS_FLUTTER_INSERTS;
  private boolean allowPasteInOverflow = false;

  public SystemContextMenuPlugin(
      @NonNull View view,
      @NonNull PlatformChannel platformChannel,
      @NonNull TextInputPlugin textInputPlugin) {
    this.view = view;
    this.platformChannel = platformChannel;
    this.textInputPlugin = textInputPlugin;
    platformChannel.setSystemContextMenuHandler(this);
  }

  /** Takes the toolbar down and stops listening. Call when the view leaves its FlutterEngine. */
  public void destroy() {
    platformChannel.setSystemContextMenuHandler(null);
    hideSystemContextMenu();
  }

  // -------- Start: requests from the framework -------

  @Override
  public void showSystemContextMenu(@NonNull SystemContextMenuRequest request) {
    // The framework measures in logical pixels, Android views in physical pixels.
    final float density = view.getResources().getDisplayMetrics().density;
    contentRect.set(
        (int) Math.floor(request.x * density),
        (int) Math.floor(request.y * density),
        (int) Math.ceil((request.x + request.width) * density),
        (int) Math.ceil((request.y + request.height) * density));
    pasteStrategy = PasteStrategy.fromValue(request.pasteStrategy);
    allowPasteInOverflow = request.allowPasteInOverflow;

    final boolean itemsChanged = !request.items.equals(items);
    items = request.items;

    if (actionMode != null) {
      // Already showing (the selection moved, or its items changed): update the toolbar in place.
      // Finishing it and starting a new one would make it flicker.
      if (itemsChanged) {
        actionMode.invalidate(); // Android calls onPrepareActionMode again.
      }
      actionMode.invalidateContentRect(); // Android calls onGetContentRect again.
      return;
    }

    // Null when the view is not attached to a window, or when no item could be shown.
    actionMode = view.startActionMode(callback, ActionMode.TYPE_FLOATING);
    Log.i(TAG, "SHOW rect=" + contentRect.toShortString() + " items=" + describeItems());
  }

  @Override
  public void hideSystemContextMenu() {
    final ActionMode mode = actionMode;
    if (mode == null) {
      return;
    }
    // Forget the toolbar BEFORE finishing it. finish() makes Android call onDestroyActionMode,
    // which reports a dismissal to the framework only for the toolbar that is still remembered.
    // The framework has already forgotten this menu and asserts if a dismissal arrives for it.
    actionMode = null;
    mode.finish();
    Log.i(TAG, "HIDE asked by framework");
  }

  // -------- End: requests from the framework -------

  /** Android calls these methods; this class never does. */
  @VisibleForTesting
  final ActionMode.Callback2 callback =
      new ActionMode.Callback2() {
        /** "Which items do you want?" Returning false means "do not show the toolbar". */
        @Override
        public boolean onCreateActionMode(ActionMode mode, Menu menu) {
          addItemsTo(menu);
          return menu.size() > 0;
        }

        /** Asked again after invalidate(). Returning true means "the items changed". */
        @Override
        public boolean onPrepareActionMode(ActionMode mode, Menu menu) {
          menu.clear();
          addItemsTo(menu);
          return true;
        }

        /** "Which rectangle is the toolbar about?" Android places it just above or below. */
        @Override
        public void onGetContentRect(ActionMode mode, View view, Rect outRect) {
          outRect.set(contentRect);
        }

        /** The user tapped an item. Android only reports it; the work is ours. */
        @Override
        public boolean onActionItemClicked(ActionMode mode, MenuItem menuItem) {
          final long tapNanos = SystemClock.elapsedRealtimeNanos();
          final SystemContextMenuItem item = itemForMenuId(menuItem.getItemId());
          if (item == null) {
            return false;
          }
          Log.i(TAG, "TAP type=" + item.type);
          if (item.type.equals("paste")) {
            onPasteTapped(tapNanos);
          } else if (item.type.equals("custom")) {
            platformChannel.systemContextMenuCustomActionPerformed(item.callbackId);
          } else {
            // Cut, Copy, Select all, Share: the framework does these as it does for its own bar.
            platformChannel.systemContextMenuActionPerformed(item.type, null);
          }
          // The toolbar is not closed here. The framework decides, as it does for the bar it
          // draws itself: it hides after Paste, Cut and Copy and keeps it after Select all.
          return true;
        }

        /** The toolbar is gone: after finish(), or because Android took it down. */
        @Override
        public void onDestroyActionMode(ActionMode mode) {
          if (mode != actionMode) {
            // hideSystemContextMenu() finished it on the framework's request. Nothing to report.
            return;
          }
          actionMode = null;
          Log.i(TAG, "DISMISSED by Android");
          platformChannel.systemContextMenuDismissed();
        }
      };

  private void onPasteTapped(long tapNanos) {
    PasteTimingLog.onPasteTapped(tapNanos, pasteStrategy.encodedName);
    switch (pasteStrategy) {
      case PLATFORM_READS_AND_INSERTS:
        if (textInputPlugin.performContextMenuAction(android.R.id.paste)) {
          break;
        }
        // No keyboard connection to borrow the paste code from: fall through to A-prime.
        Log.w(TAG, "No input connection; pasting through the framework instead.");
      case PLATFORM_READS_FLUTTER_INSERTS:
        final CharSequence text = readClipboardText();
        if (text != null) {
          platformChannel.systemContextMenuActionPerformed("paste", text);
        }
        break;
      case PLATFORM_READS_AND_KEEPS:
        final CharSequence keptText = readClipboardText();
        if (keptText != null) {
          platformChannel.keepPasteTextForNextRead(keptText, KEPT_PASTE_TEXT_VALID_MILLIS);
          platformChannel.systemContextMenuActionPerformed("paste", null);
        }
        break;
      case FLUTTER_READS_AND_INSERTS:
        platformChannel.systemContextMenuActionPerformed("paste", null);
        break;
    }
  }

  /** Reads the clipboard now. This is the read that Android judges. */
  @Nullable
  private CharSequence readClipboardText() {
    final Context context = view.getContext();
    final ClipboardManager clipboard =
        (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
    PasteTimingLog.beforeClipboardRead("SystemContextMenuPlugin");
    final ClipData clip = clipboard.getPrimaryClip();
    if (clip == null || clip.getItemCount() == 0) {
      return null;
    }
    return clip.getItemAt(0).coerceToText(context);
  }

  private void addItemsTo(@NonNull Menu menu) {
    for (int i = 0; i < items.size(); i++) {
      final SystemContextMenuItem item = items.get(i);
      final int id = menuIdFor(item, i);
      final CharSequence title = titleFor(item);
      if (title == null) {
        // A type this embedding does not know and that came without a label (iOS-only items).
        continue;
      }
      // The order is the list position: Android fills the bar in this order and moves what does
      // not fit into the overflow list. A Paste tapped in the overflow list is not trusted on
      // Android 17, so the framework should list Paste early.
      final MenuItem menuItem = menu.add(Menu.NONE, id, i, title);
      menuItem.setShowAsAction(
          item.type.equals("paste") && !allowPasteInOverflow
              ? MenuItem.SHOW_AS_ACTION_ALWAYS
              : MenuItem.SHOW_AS_ACTION_IF_ROOM);
    }
  }

  private int menuIdFor(@NonNull SystemContextMenuItem item, int position) {
    switch (item.type) {
      case "paste":
        return android.R.id.paste;
      case "cut":
        return android.R.id.cut;
      case "copy":
        return android.R.id.copy;
      case "selectAll":
        return android.R.id.selectAll;
      default:
        return FIRST_OTHER_ITEM_ID + position;
    }
  }

  @Nullable
  private SystemContextMenuItem itemForMenuId(int id) {
    for (int i = 0; i < items.size(); i++) {
      if (menuIdFor(items.get(i), i) == id) {
        return items.get(i);
      }
    }
    return null;
  }

  @Nullable
  private CharSequence titleFor(@NonNull SystemContextMenuItem item) {
    if (item.title != null) {
      return item.title;
    }
    final Context context = view.getContext();
    switch (item.type) {
      case "paste":
        return context.getString(android.R.string.paste);
      case "cut":
        return context.getString(android.R.string.cut);
      case "copy":
        return context.getString(android.R.string.copy);
      case "selectAll":
        return context.getString(android.R.string.selectAll);
      default:
        return null;
    }
  }

  @NonNull
  private String describeItems() {
    final StringBuilder description = new StringBuilder("[");
    for (SystemContextMenuItem item : items) {
      description.append(item.type).append(' ');
    }
    return description.append(']').toString();
  }
}
