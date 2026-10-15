#!/usr/bin/env python3
"""Local, bounded AVPlayer regression tests; no downloads or package installation.
Requires installed Xcode, Python 3 and ffmpeg. --ios uses an already booted simulator.
The harness compiles the production PlaybackController and stores directly, omitting
AppModel (UI composition), artwork fetching and system media controls.
System media controls are tested in the app; a standalone CLI must not compete
with running apps for Now Playing ownership. No production defaults are used.
"""
import argparse
import os
import http.server
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ios', action='store_true')
parser.add_argument('--serve-app', action='store_true', help='Serve the same fixtures to the simulator app for manual UI verification')
parser.add_argument('--port-file', type=pathlib.Path)
parser.add_argument('--recovery-only', action='store_true', help='Test interruption and cancelled-seek recovery')
parser.add_argument('--completion-only', action='store_true', help='Only test audio completion before HTTP completion')
parser.add_argument('--baseline', action='store_true', help='Use HEAD playback implementation for comparison')
args = parser.parse_args()
if not shutil.which('ffmpeg'):
    raise SystemExit('ffmpeg is not installed; no tools will be downloaded.')

with tempfile.TemporaryDirectory(prefix='yorune-streaming-') as directory:
    work = pathlib.Path(directory)
    for extension, codec in [('mp3', ['-c:a', 'libmp3lame', '-b:a', '192k']), ('m4a', ['-c:a', 'alac']), ('flac', ['-c:a', 'flac'])]:
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'sine=frequency=523:duration=120', '-metadata', f'title={uuid.uuid4()}',
                        *codec, str(work / ('audio.' + extension))], check=True)
    media = {extension: (work / ('audio.' + extension)).read_bytes() for extension in ['mp3', 'm4a', 'flac']}
    stats = {}
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *values):
            pass

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            track = urllib.parse.parse_qs(parsed.query).get('id', [''])[0]
            if parsed.path == '/stats':
                with lock:
                    result = json.dumps(stats.get(track, dict(sent=0, size=1))).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(result)))
                self.end_headers()
                self.wfile.write(result)
                return
            action = parsed.path.rsplit('/', 1)[-1]
            if action in ['getAlbumList2.view', 'getAlbum.view']:
                album = dict(id='playback-fixtures', name='Playback tests', artist='Yorune')
                if action == 'getAlbumList2.view':
                    offset = int(urllib.parse.parse_qs(parsed.query).get('offset', ['0'])[0])
                    payload = dict(albumList2=dict(album=[album] if offset == 0 else []))
                else:
                    album['song'] = [dict(id='complete-' + fmt + '-ui', title=fmt.upper() + ' test',
                                          artist='Yorune', album='Playback tests', duration=120, track=i + 1)
                                     for i, fmt in enumerate(['mp3', 'm4a', 'flac'])]
                    payload = dict(album=album)
                body = json.dumps({'subsonic-response': dict(status='ok', version='1.16.1', **payload)}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            extension = 'm4a' if 'm4a' in track else ('flac' if 'flac' in track else 'mp3')
            data = media[extension]
            start, end = 0, len(data) - 1
            if not track.startswith(('norange', 'chunked')) and (match := re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))):
                start = int(match[1])
                end = min(int(match[2]) if match[2] else end, end)
            ranged = bool(self.headers.get('Range')) and not track.startswith(('norange', 'chunked'))
            self.send_response(206 if ranged else 200)
            self.send_header('Content-Type', {'m4a': 'audio/mp4', 'mp3': 'audio/mpeg', 'flac': 'audio/flac'}[extension])
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Accept-Ranges', 'bytes')
            if track.startswith(('chunked', 'delayed')):
                if track.startswith('delayed'):
                    self.send_header('Transfer-Encoding', 'chunked')
                self.send_header('Connection', 'close')
                self.close_connection = True
            else:
                self.send_header('Content-Length', str(end - start + 1))
            if ranged:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
            self.end_headers()
            with lock:
                stats.setdefault(track, dict(sent=0, size=len(data), requests=0, downloads=0, sha256=hashlib.sha256(data).hexdigest()))
                stats[track]['requests'] += 1
                stats[track]['downloads'] += int('download' in parsed.path)
            try:
                for offset in range(start, end + 1, 4096):
                    if track.startswith('stall') and offset >= 65536 and offset < 69632:
                        time.sleep(8)
                    chunk = data[offset:min(offset + 4096, end + 1)]
                    if track.startswith('truncated') and offset >= start + 4096:
                        self.close_connection = True
                        return
                    if track.startswith('delayed'):
                        self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
                    else:
                        self.wfile.write(chunk)
                    self.wfile.flush()
                    with lock:
                        stats[track]['sent'] += len(chunk)
                    if 'download' not in parsed.path and not track.startswith(('complete', 'norange', 'chunked', 'delayed')):
                        # ALAC/FLAC metadata at the end forces byte-range requests.
                        time.sleep(len(chunk) / (262144 if ('pinned' in track or track.startswith(('seek', 'cancel-save'))) else (8192 if extension == 'm4a' else 24576)))
                if track.startswith('delayed'):
                    if end == len(data) - 1:
                        time.sleep(6)
                    self.wfile.write(b'0\r\n\r\n')
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if args.serve_app:
        if args.port_file:
            args.port_file.write_text(str(server.server_port))
        print(f'UI fixture server ready: {server.server_port}. Launch the app with YORUNE_UI_TEST_MUTED=1.', flush=True)
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            pass
        finally:
            server.shutdown()
        raise SystemExit(0)
    source = ROOT / 'Yorune/App/AppModel.swift'
    text = subprocess.check_output(['git', 'show', 'HEAD:Yorune/App/AppModel.swift'], cwd=ROOT, text=True) if args.baseline else source.read_text()
    start = text.index('@MainActor\nfinal class AppModel:')
    end = text.index('@MainActor\nfinal class PlaybackController:')
    text = (text[:start] + text[end:]).replace('UserDefaults.standard', 'playbackTestDefaults')
    # Keep the production audio state machine and AVPlayer intact, while isolating
    # process-global Now Playing/remote commands from the user's running apps.
    for method in ['configureRemoteCommands', 'updateRemoteCommandAvailability',
                   'updateRemoteCommandModes', 'updateNowPlayingInfo']:
        declaration = text.index('    private func ' + method + '(')
        opening = text.index('{', declaration)
        depth, closing = 1, opening + 1
        while depth:
            depth += (text[closing] == '{') - (text[closing] == '}')
            closing += 1
        text = text[:opening] + '{ /* System media controls are isolated in this CLI test. */ }' + text[closing:]
    controller = work / 'PlaybackController.swift'
    controller.write_text(text)
    sources = [controller, ROOT / 'scripts/streaming/PlaybackSmoke.swift',
               ROOT / 'Yorune/Models/Album.swift', ROOT / 'Yorune/Models/ServerConfiguration.swift',
               ROOT / 'Yorune/Stores/ServerConfigurationStore.swift', ROOT / 'Yorune/Stores/AlbumLibraryStore.swift',
               ROOT / 'Yorune/Services/NavidromeClient.swift', ROOT / 'Yorune/Services/StreamingAudioCache.swift']
    executable = work / 'streaming-smoke'
    command = ['xcrun']
    if args.ios:
        command += ['--sdk', 'iphonesimulator']
    command += ['swiftc', '-parse-as-library']
    if args.ios:
        command += ['-target', 'arm64-apple-ios18.0-simulator']
    subprocess.run(command + [str(s) for s in sources] + ['-o', str(executable)], check=True)
    run = ['xcrun', 'simctl', 'spawn', 'booted'] if args.ios else []
    print(f'Testing {"iOS Simulator" if args.ios else "macOS"} {"baseline" if args.baseline else "current"}', flush=True)
    try:
        subprocess.run(run + [str(executable), str(server.server_port), '35' if args.baseline else '12', 'baseline' if args.baseline else 'current', 'recovery' if args.recovery_only else ('completion' if args.completion_only else 'all')], check=True, timeout=150, env=os.environ | {'YORUNE_UI_TEST_MUTED': '1', 'SIMCTL_CHILD_YORUNE_UI_TEST_MUTED': '1'})
    finally:
        server.shutdown()
