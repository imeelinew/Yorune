#!/usr/bin/env python3
"""Local, bounded AVPlayer regression tests; no downloads or package installation.
Requires installed Xcode, Python 3 and ffmpeg. --ios uses an already booted simulator.
The harness compiles the production PlaybackController and stores directly, omitting
only AppModel (UI composition) and artwork fetching. No production defaults are used.
"""
import argparse
import http.server
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
                    result = json.dumps(stats[track]).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(result)))
                self.end_headers()
                self.wfile.write(result)
                return
            extension = 'm4a' if track.startswith('m4a') else ('flac' if track.startswith('flac') else 'mp3')
            data = media[extension]
            start, end = 0, len(data) - 1
            if match := re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range', '')):
                start = int(match[1])
                end = min(int(match[2]) if match[2] else end, end)
            self.send_response(206 if self.headers.get('Range') else 200)
            self.send_header('Content-Type', {'m4a': 'audio/mp4', 'mp3': 'audio/mpeg', 'flac': 'audio/flac'}[extension])
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            if self.headers.get('Range'):
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
            self.end_headers()
            with lock:
                stats.setdefault(track, dict(sent=0, size=len(data)))
            try:
                for offset in range(start, end + 1, 4096):
                    if track.startswith('stall') and offset >= 65536 and offset < 69632:
                        time.sleep(8)
                    chunk = data[offset:min(offset + 4096, end + 1)]
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    with lock:
                        stats[track]['sent'] += len(chunk)
                    if 'download' not in parsed.path:
                        # ALAC/FLAC metadata at the end forces byte-range requests.
                        time.sleep(len(chunk) / (8192 if extension == 'm4a' else 24576))
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    source = ROOT / 'Yorune/App/AppModel.swift'
    text = subprocess.check_output(['git', 'show', 'HEAD:Yorune/App/AppModel.swift'], cwd=ROOT, text=True) if args.baseline else source.read_text()
    start = text.index('@MainActor\nfinal class AppModel:')
    end = text.index('@MainActor\nfinal class PlaybackController:')
    text = (text[:start] + text[end:]).replace('UserDefaults.standard', 'playbackTestDefaults')
    controller = work / 'PlaybackController.swift'
    controller.write_text(text)
    sources = [controller, ROOT / 'scripts/streaming/PlaybackSmoke.swift',
               ROOT / 'Yorune/Models/Album.swift', ROOT / 'Yorune/Models/ServerConfiguration.swift',
               ROOT / 'Yorune/Stores/ServerConfigurationStore.swift', ROOT / 'Yorune/Stores/AlbumLibraryStore.swift',
               ROOT / 'Yorune/Services/NavidromeClient.swift']
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
        subprocess.run(run + [str(executable), str(server.server_port), '35' if args.baseline else '12'], check=True, timeout=150)
    finally:
        server.shutdown()
