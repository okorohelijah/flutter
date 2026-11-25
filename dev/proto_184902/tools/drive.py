#!/usr/bin/env python3
# Copyright 2014 The Flutter Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Drives the ToolbarDemo app (../app) on one Android device over adb and saves what happened.

    ./drive.py --serial <adb serial> paste  --strategy "A'" --rep 1     # one filmed paste, toast or not
    ./drive.py --serial <adb serial> timing --strategy B --taps 20      # tap-to-read times
    ./drive.py --serial <adb serial> show   --field filled              # show the bar, save a picture

Everything is written under --out (default ./runs): logcat.txt, rec.mp4, *.png, windows.json,
result.json. The script does not judge by eye: "toast" means Android's own log line
"ClipboardService: ToolbarDemo pasted from your clipboard", and the film is checked separately.

The paste case needs a second app that copies text, so that the read is a cross-app read:
dev.securepaste.copier (it copies the word hello every time its screen opens).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

APP = 'dev.securepaste.toolbardemo'
COPIER = 'dev.securepaste.copier'
TOAST_TEXT = 'ToolbarDemo pasted from your clipboard'
ADB = os.environ.get('ADB', os.path.expanduser('~/Android/Sdk/platform-tools/adb'))

args = None


# ---------------------------------------------------------------- talking to the device

def adb(*a, timeout=120, binary=False):
    out = subprocess.run([ADB, '-s', args.serial, *a], capture_output=True, timeout=timeout).stdout
    return out if binary else out.decode('utf-8', 'replace')


def sh(cmd, timeout=120):
    return adb('shell', cmd, timeout=timeout)


def tap(x, y):
    sh(f'input tap {x} {y}')


def long_press(x, y, ms=800):
    sh(f'input swipe {x} {y} {x} {y} {ms}')  # a swipe that does not move is a long press


def screencap(path):
    with open(path, 'wb') as f:
        f.write(adb('exec-out', 'screencap', '-p', binary=True))


def logcat():
    return adb('logcat', '-d', '-v', 'threadtime')


def app_log():
    """The demo's own lines ('PROTO ...') and the embedding's ('SystemContextMenu')."""
    return [l for l in logcat().splitlines()
            if ' PROTO ' in l or 'SystemContextMenu' in l or 'ClipboardService: ' in l]


def wall_seconds(line):
    """'11-25 12:02:07.735 ...' -> seconds since midnight on the device clock."""
    m = re.match(r'\d\d-\d\d (\d\d):(\d\d):(\d\d)\.(\d\d\d)', line)
    h, mi, s, ms = (int(g) for g in m.groups())
    return h * 3600 + mi * 60 + s + ms / 1000.0


def wait_for(pattern, timeout=8.0, after=0):
    """Waits until a log line matches; returns (line, index) or (None, None)."""
    deadline = time.time() + timeout
    rx = re.compile(pattern)
    while time.time() < deadline:
        lines = app_log()
        for i, line in enumerate(lines):
            if i >= after and rx.search(line):
                return line, i
        time.sleep(0.2)
    return None, None


def layout():
    """Where the demo says its fields are: {'plain': (x, y), ...} in screen pixels."""
    for line in reversed(app_log()):
        if 'PROTO LAYOUT' in line:
            return {k: (int(x), int(y)) for k, x, y in re.findall(r'(\w+)=(-?\d+),(-?\d+)', line)}
    raise SystemExit('no LAYOUT line in the log: did the app start?')


def popup_windows():
    """Touchable popup windows, front-most first, from `dumpsys input`.

    Android's toolbar is either a PopupWindow of the app (Android 16 and older) or a window that
    another process embeds into one (Android 17: name starts with 'Embedded{').
    """
    out = []
    for line in sh('dumpsys input').splitlines():
        m = re.search(r'name=(Embedded\{[^}]*\}|[^,]*PopupWindow[^,]*),.*?'
                      r'touchableRegion=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\],'
                      r' ownerPid=(\d+), ownerUid=(\d+)', line)
        if not m:
            continue
        w = {'name': m.group(1), 'touchable': [int(g) for g in m.groups()[1:5]],
             'ownerPid': int(m.group(6)), 'ownerUid': int(m.group(7))}
        if w not in out:
            out.append(w)
    for w in out:
        names = re.findall(r'package:(\S+)', sh(f"cmd package list packages --uid {w['ownerUid']}"))
        w['ownerPackage'] = ','.join(names) or '?'
        w['ownerProcess'] = sh(f"cat /proc/{w['ownerPid']}/cmdline").replace('\x00', ' ').strip()
    return out


def device_info():
    return {
        'release': sh('getprop ro.build.version.release').strip(),
        'sdk': sh('getprop ro.build.version.sdk').strip(),
        'fingerprint': sh('getprop ro.build.fingerprint').strip(),
    }


def start_app(strategy, extra=''):
    sh(f'am force-stop {APP}')
    sh(f'am start -n {APP}/.MainActivity --es strategy "{strategy}" {extra}')


class Recording:
    """adb screenrecord, stopped with Ctrl-C so that the file is closed properly."""

    def __init__(self, out_mp4):
        self.out_mp4 = out_mp4
        sh('rm -f /sdcard/proto_rec.mp4')
        self.proc = subprocess.Popen(
            [ADB, '-s', args.serial, 'shell', 'screenrecord', '--bugreport', '--bit-rate', '6000000',
             '--time-limit', '120', '/sdcard/proto_rec.mp4'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)

    def stop(self):
        sh('pkill -2 screenrecord')
        self.proc.wait(timeout=30)
        time.sleep(0.5)
        adb('pull', '/sdcard/proto_rec.mp4', self.out_mp4)


def out_dir(*parts):
    info = device_info()
    path = os.path.join(args.out, f"android{info['release']}", *parts)
    os.makedirs(path, exist_ok=True)
    return path, info


def show_toolbar(field, shot=None, wait_window=True, timeout=6.0):
    """Long-presses a field and returns the toolbar's window, or None if no window appeared."""
    pos = layout()
    if field not in pos:
        raise SystemExit(f'field {field} is not on screen; known: {sorted(pos)}')
    long_press(*pos[field])
    wins = []
    if wait_window:
        deadline = time.time() + timeout
        while time.time() < deadline:
            wins = popup_windows()
            if wins:
                time.sleep(0.35)  # let the fade-in finish before capturing the screen
                wins = popup_windows()
                break
            time.sleep(0.2)
    else:
        time.sleep(2.2)
        wins = popup_windows()
    if shot:
        screencap(shot)
    return wins[0] if wins else None, wins


def first_item_point(window):
    """The middle of the first item of the toolbar (Paste, when the framework lists it first)."""
    left, top, right, bottom = window['touchable']
    return left + min(78, (right - left) // 2), (top + bottom) // 2


# ---------------------------------------------------------------- the three commands

def cmd_paste():
    """One paste from start to finish, filmed, starting from a clip another app made."""
    name = f"paste_{args.label or args.strategy.replace(chr(39), 'prime')}"
    if not args.system_toolbar:
        name = 'paste_flutter_drawn'
    out, info = out_dir(args.mode, name, f'rep{args.rep}')
    print(f"== Android {info['release']} (API {info['sdk']}) {name} rep={args.rep} -> {out}")

    sh('input keyevent KEYCODE_WAKEUP')
    adb('logcat', '-c')
    sh(f'am force-stop {APP}')
    sh(f'am force-stop {COPIER}')
    sh(f'am start -n {COPIER}/.CopierActivity')  # a new clip "hello" owned by Copier
    time.sleep(1.5)
    extra_parts = []
    if not args.system_toolbar:
        extra_parts.append('--ez system_toolbar false')
    if getattr(args, 'allow_overflow', False):
        extra_parts.append('--ez allow_paste_overflow true')
    start_app(args.strategy, ' '.join(extra_parts))
    time.sleep(6.5)  # Android's "copied" preview in the corner must be gone before filming

    rec = Recording(os.path.join(out, 'rec.mp4'))
    result = dict(info, case=name, rep=args.rep, mode=args.mode, strategy=args.strategy,
                  system_toolbar=args.system_toolbar)
    try:
        window, wins = show_toolbar('plain', os.path.join(out, 'toolbar.png'),
                                    wait_window=args.system_toolbar)
        result['popup_windows'] = wins
        if args.system_toolbar:
            if window is None:
                raise SystemExit('no toolbar window appeared')
            tap(*first_item_point(window))
        else:
            # The bar Flutter draws is not a window; on the 1008x2244 screen the
            # Paste pill sits above the left end of the field (~[35,y-145]..[175,y-55]).
            x, y = layout()['plain']
            tap(105, y - 100)

        line, _ = wait_for(r'PROTO CHANGED field=plain text="hello"')
        result['pasted'] = line is not None
        time.sleep(1.3)
        screencap(os.path.join(out, 'after.png'))
        time.sleep(3.2)
    finally:
        rec.stop()

    full = logcat()
    open(os.path.join(out, 'logcat_full.txt'), 'w').write(full)
    kept = [l for l in full.splitlines()
            if re.search(r' PROTO |SystemContextMenu|ClipboardService: |SecurePasteSpike', l)]
    open(os.path.join(out, 'logcat.txt'), 'w').write('\n'.join(kept) + '\n')
    toast_lines = [l for l in kept if 'ClipboardService: ' + TOAST_TEXT in l]
    read_lines = [l for l in kept if 'PASTE_READ' in l]
    result['toast_in_log'] = bool(toast_lines)
    result['toast_log_lines'] = toast_lines
    result['paste_read_lines'] = read_lines
    result['changed_line'] = line
    json.dump(result, open(os.path.join(out, 'result.json'), 'w'), indent=1)
    print(f"   pasted={result['pasted']}  toast_in_log={result['toast_in_log']}  "
          f"toolbar_owner={window['ownerPackage'] if window else '-'}")
    for l in read_lines:
        print('   ' + l.split('SystemContextMenu: ')[-1])


def cmd_timing():
    """Many taps on Paste in a row; prints the time from the tap to the clipboard read."""
    out, info = out_dir(args.mode, f"timing_{args.strategy.replace(chr(39), 'prime')}")
    print(f"== Android {info['release']} (API {info['sdk']}) timing {args.strategy} x{args.taps} -> {out}")
    adb('logcat', '-c')
    sh(f'am start -n {COPIER}/.CopierActivity')
    time.sleep(1.0)
    start_app(args.strategy)
    deadline = time.time() + 10.0
    while time.time() < deadline:
        try:
            pos = layout()
            if 'plain' in pos:
                break
        except SystemExit:
            pass
        time.sleep(0.3)
    time.sleep(4.5)
    x, y = layout()['plain']
    # Focus the field first so the IME is already up before the timed taps start.
    tap(x - 180, y)
    time.sleep(0.8)
    attempts = 0
    reads_seen = 0
    max_attempts = args.taps + 10
    while reads_seen < args.taps and attempts < max_attempts:
        attempts += 1
        before = len(app_log())
        long_press(x - 180, y)
        wins = []
        deadline = time.time() + 5.0
        while time.time() < deadline:
            wins = popup_windows()
            if wins:
                time.sleep(0.45)
                wins = popup_windows()
                break
            time.sleep(0.15)
        if not wins:
            print(f'   attempt {attempts}: no toolbar, retrying')
            continue
        tap(*first_item_point(wins[0]))
        line, _ = wait_for(r'PASTE_READ', timeout=5, after=before)
        if line:
            reads_seen += 1
        print(f"   tap {reads_seen}/{args.taps} (attempt {attempts}): "
              f"{line.split('SystemContextMenu: ')[-1] if line else 'NO READ'}")
        time.sleep(0.3)
        # Move to end and backspace away "hello" so every tap starts from an empty field.
        sh('input keyevent 123 67 67 67 67 67 67 67 67')
        time.sleep(0.35)
    full = logcat()
    open(os.path.join(out, 'logcat_full.txt'), 'w').write(full)
    reads = [float(m.group(1)) for m in re.finditer(r'PASTE_READ strategy=\S+ msAfterTap=([\d.]+)', full)]
    kept_answers = [
        float(m.group(1))
        for m in re.finditer(r'PASTE_ANSWERED_FROM_KEPT_TEXT strategy=\S+ msAfterTap=([\d.]+)', full)
    ]
    toasts = full.count('ClipboardService: ' + TOAST_TEXT)
    reads.sort()
    kept_answers.sort()
    summary = dict(info, mode=args.mode, strategy=args.strategy, taps=args.taps, attempts=attempts,
                   n=len(reads), ms=reads, kept_answer_ms=kept_answers, toast_lines=toasts)
    if reads:
        summary.update(min=reads[0], median=reads[len(reads) // 2], max=reads[-1])
        print(f"   n={len(reads)} min={reads[0]} median={summary['median']} max={reads[-1]} ms; "
              f"toast lines in log: {toasts}")
    if kept_answers:
        summary.update(
            kept_answer_min=kept_answers[0],
            kept_answer_median=kept_answers[len(kept_answers) // 2],
            kept_answer_max=kept_answers[-1],
        )
        print(f"   kept_answer n={len(kept_answers)} min={summary['kept_answer_min']} "
              f"median={summary['kept_answer_median']} max={summary['kept_answer_max']} ms")
    json.dump(summary, open(os.path.join(out, 'timing.json'), 'w'), indent=1)


def cmd_show():
    """Shows the bar for one field and saves a picture and the list of popup windows."""
    out, info = out_dir(args.mode, 'show')
    window, wins = show_toolbar(args.field, os.path.join(out, f'{args.label or args.field}.png'))
    json.dump(wins, open(os.path.join(out, f'{args.label or args.field}.windows.json'), 'w'), indent=1)
    print(json.dumps(wins, indent=1))


def main():
    global args
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument('--serial', required=True, help='adb serial, e.g. localhost:27068 or emulator-5554')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'runs'))
    ap.add_argument('--mode', default='debug', help='only a folder name: debug, profile or release')
    sub = ap.add_subparsers(dest='command', required=True)
    p = sub.add_parser('paste')
    p.add_argument('--strategy', default="A'", choices=['A', "A'", 'AK', 'B'])
    p.add_argument('--rep', type=int, default=1)
    p.add_argument('--label', default='')
    p.add_argument('--flutter-drawn', dest='system_toolbar', action='store_false',
                   help="use the bar Flutter draws itself (today's behaviour) instead")
    p.add_argument('--allow-overflow', action='store_true',
                   help='do not force Paste onto the main bar (for testing overflow)')
    t = sub.add_parser('timing')
    t.add_argument('--strategy', default="A'", choices=['A', "A'", 'AK', 'B'])
    t.add_argument('--taps', type=int, default=20)
    s = sub.add_parser('show')
    s.add_argument('--field', default='plain')
    s.add_argument('--label', default='')
    args = ap.parse_args()
    {'paste': cmd_paste, 'timing': cmd_timing, 'show': cmd_show}[args.command]()


if __name__ == '__main__':
    main()
