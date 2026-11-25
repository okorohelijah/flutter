// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Demo app for the prototype of https://github.com/flutter/flutter/issues/184902:
// ordinary Flutter text fields whose Cut / Copy / Paste bar is Android's own
// floating toolbar instead of the one Flutter draws.
//
// The screen is a list of text fields, one per case worth checking, plus three
// switches at the top. Everything the fields do is also written to the device
// log with the prefix "PROTO", so a script (or you, with `adb logcat -s flutter`)
// can see what happened without looking at the screen.

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoTextField;
import 'package:flutter/services.dart';
// `flutter create` now generates apps that import Material from this pub
// package rather than from package:flutter/material.dart.
import 'package:material_ui/material_ui.dart';

/// Lets a script choose the switches when it starts the app:
///
///     adb shell am start -n dev.securepaste.toolbardemo/.MainActivity \
///         --es strategy B --es theme dark --es locale fr --ez system_toolbar false
///
/// The Android side (MainActivity.kt) answers with the extras of that command.
const MethodChannel _launchConfigChannel = MethodChannel('proto/launch_config');

void log(String message) {
  // ignore: avoid_print
  print('PROTO $message');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Map<Object?, Object?> launchConfig = <Object?, Object?>{};
  try {
    launchConfig =
        await _launchConfigChannel.invokeMethod<Map<Object?, Object?>>('get') ??
        <Object?, Object?>{};
  } on MissingPluginException {
    // Not started through MainActivity.kt (for example in a widget test).
  }
  runApp(DemoApp(launchConfig: launchConfig));
}

/// The ways a tap on Paste can become text, with the short names used in the
/// write-up.
const Map<String, AndroidSystemContextMenuPasteStrategy> strategies =
    <String, AndroidSystemContextMenuPasteStrategy>{
      // Android reads the clipboard and inserts the text itself.
      'A': AndroidSystemContextMenuPasteStrategy.platformReadsAndInserts,
      // Android reads the clipboard, Flutter inserts the text.
      "A'": AndroidSystemContextMenuPasteStrategy.platformReadsFlutterInserts,
      // Android reads the clipboard and keeps the text; Flutter pastes as
      // today and its Clipboard.getData is answered with the kept text.
      'AK': AndroidSystemContextMenuPasteStrategy.platformReadsAndKeeps,
      // Android only reports the tap; Flutter reads and inserts.
      'B': AndroidSystemContextMenuPasteStrategy.flutterReadsAndInserts,
    };

class DemoApp extends StatefulWidget {
  const DemoApp({super.key, required this.launchConfig});

  final Map<Object?, Object?> launchConfig;

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  late String _strategy;
  late ThemeMode _themeMode;
  late Locale? _locale; // null = follow the system.
  late bool _useSystemToolbar;
  late bool _allowPasteInOverflow;

  @override
  void initState() {
    super.initState();
    final Map<Object?, Object?> config = widget.launchConfig;
    _strategy = strategies.containsKey(config['strategy'])
        ? config['strategy']! as String
        : "A'";
    _themeMode = switch (config['theme']) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    final Object? locale = config['locale'];
    _locale = locale is String && locale.isNotEmpty ? Locale(locale) : null;
    _useSystemToolbar = config['system_toolbar'] != false;
    _allowPasteInOverflow = config['allow_paste_overflow'] == true;
    _applyStrategy();
    log(
      'CONFIG strategy=$_strategy theme=${_themeMode.name} '
      'locale=${_locale ?? 'system'} systemToolbar=$_useSystemToolbar '
      'allowOverflow=$_allowPasteInOverflow',
    );
  }

  void _applyStrategy() {
    SystemContextMenuController.debugAndroidPasteStrategy =
        strategies[_strategy]!;
    SystemContextMenuController.debugAndroidAllowPasteInOverflow =
        _allowPasteInOverflow;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ToolbarDemo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      themeMode: _themeMode,
      locale: _locale,
      supportedLocales: const <Locale>[
        Locale('en'),
        Locale('fr'),
        Locale('ar'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (BuildContext context, Widget? child) {
        if (_useSystemToolbar) {
          return child!;
        }
        // "Off" pretends Android said it cannot show its toolbar. The default
        // context menu builders then fall back to the bar Flutter draws: this
        // is what every Flutter app does today.
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(supportsShowingSystemContextMenu: false),
          child: child!,
        );
      },
      home: DemoPage(
        strategy: _strategy,
        onStrategyChanged: (String value) => setState(() {
          _strategy = value;
          _applyStrategy();
          log('CONFIG strategy=$_strategy');
        }),
        themeMode: _themeMode,
        onThemeModeChanged: (ThemeMode value) =>
            setState(() => _themeMode = value),
        locale: _locale,
        onLocaleChanged: (Locale? value) => setState(() => _locale = value),
        useSystemToolbar: _useSystemToolbar,
        onUseSystemToolbarChanged: (bool value) =>
            setState(() => _useSystemToolbar = value),
        allowPasteInOverflow: _allowPasteInOverflow,
        onAllowPasteInOverflowChanged: (bool value) => setState(() {
          _allowPasteInOverflow = value;
          _applyStrategy();
          log('CONFIG allowOverflow=$_allowPasteInOverflow');
        }),
      ),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({
    super.key,
    required this.strategy,
    required this.onStrategyChanged,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.locale,
    required this.onLocaleChanged,
    required this.useSystemToolbar,
    required this.onUseSystemToolbarChanged,
    required this.allowPasteInOverflow,
    required this.onAllowPasteInOverflowChanged,
  });

  final String strategy;
  final ValueChanged<String> onStrategyChanged;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final Locale? locale;
  final ValueChanged<Locale?> onLocaleChanged;
  final bool useSystemToolbar;
  final ValueChanged<bool> onUseSystemToolbarChanged;
  final bool allowPasteInOverflow;
  final ValueChanged<bool> onAllowPasteInOverflowChanged;

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  // One controller and one key per field, by name. The key is only used to
  // find where the field is on screen (see _logLayout).
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  String _lastEvent = 'nothing yet';
  String _lastLayout = '';

  TextEditingController _controller(String name, [String text = '']) {
    return _controllers.putIfAbsent(
      name,
      () => TextEditingController(text: text),
    );
  }

  GlobalKey _key(String name) => _keys.putIfAbsent(name, GlobalKey.new);

  void _event(String message) {
    log(message);
    setState(() => _lastEvent = message);
  }

  @override
  void initState() {
    super.initState();
    // After every frame, write where each field is, if anything moved.
    WidgetsBinding.instance.addPersistentFrameCallback((_) => _logLayout());
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Writes the centre of every field to the log, in physical pixels, e.g.
  /// `PROTO LAYOUT plain=504,612 filled=504,790 ...`, so that a script knows
  /// where to long-press.
  void _logLayout() {
    if (!mounted) {
      return;
    }
    final double pixelRatio = View.of(context).devicePixelRatio;
    final buffer = StringBuffer();
    for (final MapEntry<String, GlobalKey> entry in _keys.entries) {
      final RenderObject? renderObject = entry.value.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        continue;
      }
      final Offset center = renderObject.localToGlobal(
        renderObject.size.center(Offset.zero),
      );
      buffer.write(
        ' ${entry.key}=${(center.dx * pixelRatio).round()},${(center.dy * pixelRatio).round()}',
      );
    }
    final layout = buffer.toString();
    if (layout != _lastLayout) {
      _lastLayout = layout;
      log('LAYOUT$layout');
    }
  }

  /// A labelled text field that reports every change.
  Widget _field(
    String name,
    String label, {
    String text = '',
    bool readOnly = false,
    bool obscureText = false,
    int maxLines = 1,
    List<TextInputFormatter>? inputFormatters,
    EditableTextContextMenuBuilder? contextMenuBuilder,
  }) {
    final TextEditingController controller = _controller(name, text);
    void onChanged(String value) => _event('CHANGED field=$name text="$value"');
    final decoration = InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      // The default contextMenuBuilder is a private static of TextField, so
      // "leave it at the default" has to be a separate constructor call.
      child: contextMenuBuilder == null
          ? TextField(
              key: _key(name),
              controller: controller,
              readOnly: readOnly,
              obscureText: obscureText,
              maxLines: maxLines,
              inputFormatters: inputFormatters,
              onChanged: onChanged,
              decoration: decoration,
            )
          : TextField(
              key: _key(name),
              controller: controller,
              readOnly: readOnly,
              obscureText: obscureText,
              maxLines: maxLines,
              inputFormatters: inputFormatters,
              onChanged: onChanged,
              decoration: decoration,
              contextMenuBuilder: contextMenuBuilder,
            ),
    );
  }

  /// The system toolbar with the default items plus extra items of the app.
  ///
  /// `extraFirst` puts the app's items before the default ones, to see what
  /// Android does with Paste when the bar is full.
  EditableTextContextMenuBuilder _systemToolbarWith(
    List<String> extraTitles, {
    bool extraFirst = false,
  }) {
    return (BuildContext context, EditableTextState editableTextState) {
      if (!SystemContextMenu.isSupportedByField(editableTextState)) {
        return AdaptiveTextSelectionToolbar.editableText(
          editableTextState: editableTextState,
        );
      }
      final List<IOSSystemContextMenuItem> extra = <IOSSystemContextMenuItem>[
        for (final String title in extraTitles)
          IOSSystemContextMenuItemCustom(
            title: title,
            onPressed: () {
              _event('CUSTOM_ITEM title="$title"');
              editableTextState.hideToolbar();
            },
          ),
      ];
      final List<IOSSystemContextMenuItem> defaults =
          SystemContextMenu.getDefaultItems(editableTextState);
      return SystemContextMenu.editableText(
        editableTextState: editableTextState,
        items: extraFirst
            ? <IOSSystemContextMenuItem>[...extra, ...defaults]
            : <IOSSystemContextMenuItem>[...defaults, ...extra],
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ToolbarDemo'),
        actions: const <Widget>[_Clock()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          // ---- The switches -------------------------------------------------
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              const Text('Paste:'),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: <ButtonSegment<String>>[
                  for (final String name in strategies.keys)
                    ButtonSegment<String>(value: name, label: Text(name)),
                ],
                selected: <String>{widget.strategy},
                onSelectionChanged: (Set<String> value) =>
                    widget.onStrategyChanged(value.first),
              ),
              FilterChip(
                label: const Text('System toolbar'),
                selected: widget.useSystemToolbar,
                onSelected: widget.onUseSystemToolbarChanged,
              ),
              FilterChip(
                label: const Text('Dark'),
                selected: Theme.of(context).brightness == Brightness.dark,
                onSelected: (bool dark) => widget.onThemeModeChanged(
                  dark ? ThemeMode.dark : ThemeMode.light,
                ),
              ),
              FilterChip(
                label: const Text('French'),
                selected: widget.locale?.languageCode == 'fr',
                onSelected: (bool french) =>
                    widget.onLocaleChanged(french ? const Locale('fr') : null),
              ),
              FilterChip(
                label: const Text('Overflow Paste'),
                selected: widget.allowPasteInOverflow,
                onSelected: widget.onAllowPasteInOverflowChanged,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Last: $_lastEvent',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // ---- The fields ---------------------------------------------------
          _field('plain', '1  Ordinary TextField, empty'),
          _field(
            'filled',
            '2  Ordinary TextField with text',
            text: 'one two three four',
          ),
          _field(
            'upper',
            '3  With an input formatter (upper case)',
            inputFormatters: <TextInputFormatter>[_UpperCaseFormatter()],
          ),
          _field(
            'readonly',
            '4  Read-only',
            text: 'cannot be edited',
            readOnly: true,
          ),
          _field(
            'custom_builder',
            '5  Own contextMenuBuilder (Flutter-drawn bar)',
            text: 'app draws this bar',
            contextMenuBuilder:
                (BuildContext context, EditableTextState editableTextState) {
                  return AdaptiveTextSelectionToolbar.editableText(
                    editableTextState: editableTextState,
                  );
                },
          ),
          _field(
            'custom_item',
            '6  System toolbar + one app item',
            text: 'has a Shout item',
            contextMenuBuilder: _systemToolbarWith(<String>['Shout']),
          ),
          _field(
            'many_last',
            '7  System toolbar + 6 app items after the defaults',
            text: 'many items',
            contextMenuBuilder: _systemToolbarWith(<String>[
              for (int i = 1; i <= 6; i++) 'Extra $i',
            ]),
          ),
          _field(
            'many_first',
            '8  System toolbar + 6 app items before the defaults',
            text: 'many items',
            contextMenuBuilder: _systemToolbarWith(<String>[
              for (int i = 1; i <= 6; i++) 'Extra $i',
            ], extraFirst: true),
          ),
          _field('password', '9  Password', text: 'secret', obscureText: true),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: CupertinoTextField(
              key: _key('cupertino'),
              controller: _controller('cupertino'),
              placeholder: '9b  CupertinoTextField',
              onChanged: (String value) =>
                  _event('CHANGED field=cupertino text="$value"'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SelectableText(
              '10  SelectableText: can be copied, never pasted into.',
              key: _key('selectable'),
            ),
          ),
          // Tall filler so that the last field can be scrolled, and sits under
          // the keyboard until it is.
          const SizedBox(height: 500),
          _field(
            'bottom',
            '11  Multi-line field at the bottom',
            text: 'line one\nline two',
            maxLines: 3,
          ),
          const SizedBox(height: 300),
        ],
      ),
    );
  }
}

/// Upper-cases everything, and says so in the log: proof that a paste went
/// through Flutter's input formatters.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    log('FORMATTER old="${oldValue.text}" new="${newValue.text}"');
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

/// A clock that repaints ten times a second.
///
/// Android's screen recorder only stores a frame when the screen changes.
/// Without something moving, a recording of "nothing happened" would be empty.
class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late final Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    final tenths = _now.millisecond ~/ 100;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Text(
        '${two(_now.hour)}:${two(_now.minute)}:${two(_now.second)}.$tenths',
      ),
    );
  }
}
