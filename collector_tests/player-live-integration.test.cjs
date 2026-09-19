const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const { createContext, runInContext } = require('node:vm');

const flush = () => new Promise(resolve => setImmediate(resolve));

function element() {
  const listeners = new Map();
  const classes = new Set(['hidden']);
  return {
    style: {}, disabled: false, value: '', textContent: '',
    classList: {
      add: name => classes.add(name),
      remove: name => classes.delete(name),
      contains: name => classes.has(name),
      toggle: (name, enabled) => {
        if (enabled ?? !classes.has(name)) classes.add(name);
        else classes.delete(name);
      },
    },
    addEventListener: (name, fn) => {
      const handlers = listeners.get(name) || [];
      handlers.push(fn);
      listeners.set(name, handlers);
    },
    removeEventListener: (name, fn) => {
      listeners.set(name, (listeners.get(name) || []).filter(handler => handler !== fn));
    },
    async emit(name, value = {}) {
      for (const handler of listeners.get(name) || []) await handler(value);
    },
    setAttribute() {}, removeAttribute() {}, appendChild() {},
  };
}

async function player({ isVod = false, native = false, direct = false, programEnd = 0 } = {}) {
  const elements = new Map();
  const getElementById = id => {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  };
  const video = getElementById('video');
  const seekable = { length: 1, start: () => 0, end: () => 12 };
  Object.assign(video, {
    currentTime: 0, duration: isVod ? 3600 : Infinity,
    paused: true, ended: false, readyState: 4, muted: false, volume: 1,
    videoWidth: 1280, videoHeight: 720,
    buffered: { length: 1, start: () => 0, end: () => 12 },
    seekable,
    textTracks: Object.assign([], { addEventListener() {} }),
    play: async () => { video.paused = false; },
    pause: () => { video.paused = true; },
  });
  const timers = new Map();
  let timerId = 0;
  const setTimer = (fn, ms) => { timers.set(++timerId, { fn, ms }); return timerId; };
  const calls = [];
  const beacons = [];
  const errors = [];
  let sessionNumber = 0;
  let rendition = 'low';
  let windowStart = 0;
  const engines = [];
  class Hls {
    static Events = {
      MANIFEST_PARSED: 'manifest', ERROR: 'error', FRAG_LOADED: 'fragment',
      LEVEL_SWITCHED: 'level', SUBTITLE_TRACKS_UPDATED: 'subtitles',
    };
    static ErrorTypes = { NETWORK_ERROR: 'network', MEDIA_ERROR: 'media' };
    static isSupported() { return !native; }
    constructor(config) {
      this.config = config;
      this.handlers = new Map();
      this.subtitleTracks = [];
      this.levels = [];
      this.currentLevel = -1;
      this.loadLevel = -1;
      this.sources = [];
      engines.push(this);
    }
    on(event, handler) {
      const handlers = this.handlers.get(event) || [];
      handlers.push(handler);
      this.handlers.set(event, handlers);
    }
    off(event, handler) {
      this.handlers.set(event, (this.handlers.get(event) || []).filter(fn => fn !== handler));
    }
    emit(event, data = {}) {
      for (const handler of this.handlers.get(event) || []) handler(event, data);
    }
    loadSource(url) {
      this.sources.push(url);
      if (url.endsWith('/master.m3u8')) {
        this.levels = ['low', 'high'].map(name => ({
          uri: 'http://netv.test' + url.replace('master.m3u8', `${name}.m3u8`),
          details: { get fragments() { return [{ start: windowStart }]; } },
        }));
        this.currentLevel = 0;
        this.loadLevel = 0;
      }
    }
    attachMedia() { this.emit('manifest'); }
    destroy() { this.destroyed = true; this.handlers.clear(); }
  }
  const window = Object.assign(element(), {
    PLAYER_CONFIG: {
      rawUrl: 'https://provider.example/live.m3u8',
      streamType: isVod ? 'movie' : 'live', isVod,
      transcodeMode: direct ? 'never' : 'always',
      liveDvrMins: isVod ? 0 : 60,
      programEnd,
      ccStyle: {}, captionsEnabled: false, sourceId: 'provider', isHttps: false,
    },
    location: { href: 'http://netv.test/play/live/1', origin: 'http://netv.test' },
  });
  const document = Object.assign(element(), {
    getElementById, createElement: element, head: element(),
    querySelectorAll: () => [], visibilityState: 'visible',
  });
  const context = createContext({
    window, document, Hls, URL, Blob, AbortController, Date,
    navigator: { sendBeacon: url => { beacons.push(url); return true; } },
    performance: { now: () => 1000 },
    localStorage: { getItem: () => null, setItem() {} },
    setTimeout: setTimer, clearTimeout: id => timers.delete(id),
    setInterval: setTimer, clearInterval: id => timers.delete(id),
    console: { log() {}, warn: (...args) => errors.push(args), error: (...args) => errors.push(args) },
    fetch: async (url, options = {}) => {
      calls.push({ url, options });
      let data = {};
      if (url.startsWith('/transcode/start?')) {
        const id = `session${++sessionNumber}`;
        data = {
          session_id: id, duration: isVod ? 3600 : 0, subtitles: [],
          playlist: `/transcode/${id}/${isVod ? 'stream' : 'low'}.m3u8`,
          ...(!isVod ? { master_playlist: `/transcode/${id}/master.m3u8` } : {}),
        };
      } else if (url.endsWith('/health')) {
        data = { playlist: `/transcode/session${sessionNumber}/${rendition}.m3u8` };
      }
      return { ok: true, json: async () => data };
    },
  });
  for (const script of ['live-playback.js', 'player.js']) {
    runInContext(readFileSync(join(__dirname, '../static/js', script), 'utf8'), context);
  }
  await flush();
  return {
    video, window, elements, engines, calls, beacons, errors, timers,
    setRendition: value => { rendition = value; },
    setWindowStart: value => { windowStart = value; },
    async pollHealth() {
      const [id, timer] = [...timers].find(([, timer]) => timer.ms === 2000);
      timers.delete(id);
      await timer.fn();
    },
  };
}

test('web live startup and upgrades use one shared adaptive session', async () => {
  const p = await player();
  const start = p.calls.find(call => call.url.startsWith('/transcode/start?'));
  assert.equal(new URL(start.url, 'http://netv.test').searchParams.get('fast_start'), 'true');
  assert.equal(p.engines.length, 1);
  const hls = p.engines[0];
  assert.deepEqual(hls.sources, ['/transcode/session1/master.m3u8']);
  assert.equal(hls.config.startPosition, -1);
  assert.equal(hls.config.liveSyncDuration, 12);
  assert.equal(hls.nextLevel, 0);
  p.setRendition('high');
  await p.pollHealth();
  assert.equal(hls.nextLevel, 1);
  assert.equal(p.engines.length, 1);
  assert.equal(p.calls.filter(call => call.url.startsWith('/transcode/start?')).length, 1);
  assert.equal(p.calls.some(call => call.url.includes('/progress/')), false);
  await p.window.emit('pagehide');
  assert.deepEqual(p.beacons, ['/transcode/session1/stop?force=true']);
  assert.deepEqual(p.errors, []);
});

test('web restart stops the live session before starting a replacement', async () => {
  const p = await player();
  await p.elements.get('menu-restart').emit('click');
  await flush();
  const stop = p.calls.findIndex(call => call.url === '/transcode/session1?force=true');
  const starts = p.calls.flatMap((call, index) => call.url.startsWith('/transcode/start?') ? [index] : []);
  assert.equal(starts.length, 2);
  assert.ok(stop > starts[0] && stop < starts[1]);
  assert.equal(p.engines[0].destroyed, true);
  assert.deepEqual(p.engines[1].sources, ['/transcode/session2/master.m3u8']);
  assert.deepEqual(p.errors, []);
});

test('web VOD keeps its existing media playlist, seek configuration, and progress polls', async () => {
  const p = await player({ isVod: true });
  assert.equal(p.calls[0].url.includes('fast_start'), false);
  assert.deepEqual(p.engines[0].sources, ['/transcode/session1/stream.m3u8']);
  assert.equal(p.engines[0].config.startPosition, 0);
  assert.equal(p.calls.some(call => call.url.includes('/progress/')), true);
  assert.equal(p.calls.some(call => call.url.endsWith('/health')), false);
  await p.window.emit('pagehide');
  assert.deepEqual(p.beacons, ['/transcode/session1/stop?force=false']);
  assert.deepEqual(p.errors, []);
});

test('native HLS stays on low while maintaining the shared live session', async () => {
  const p = await player({ native: true });
  assert.equal(p.engines.length, 0);
  assert.equal(p.video.src, '/transcode/session1/low.m3u8');
  assert.equal(p.calls.some(call => call.url.endsWith('/health')), true);
  assert.deepEqual(p.errors, []);
});

test('direct playback does not opt into server transcoding or adaptive health', async () => {
  const p = await player({ direct: true });
  assert.deepEqual(p.engines[0].sources, ['https://provider.example/live.m3u8']);
  assert.equal(p.engines[0].config.liveSyncDurationCount, 3);
  assert.deepEqual(p.calls, []);
  assert.deepEqual(p.errors, []);
});

test('returning from the browser back-forward cache can restart playback', async () => {
  const p = await player();
  await p.window.emit('pagehide');
  await p.window.emit('pageshow', { persisted: true });
  await flush();
  assert.equal(p.engines.length, 2);
  assert.deepEqual(p.engines[1].sources, ['/transcode/session2/master.m3u8']);
  assert.equal(p.engines[0].destroyed, true);
  assert.deepEqual(p.errors, []);
});

test('live DVR resumes at the oldest available position when the pause expired', async () => {
  const p = await player();
  await p.video.emit('pause');
  p.video.currentTime = 120;
  p.setWindowStart(300);
  await p.video.emit('play');
  assert.equal(p.video.currentTime, 300.1);
  assert.deepEqual(p.errors, []);
});

test('live DVR keeps the paused position when still within the window', async () => {
  const p = await player();
  await p.video.emit('pause');
  p.video.currentTime = 350;
  p.setWindowStart(300);
  await p.video.emit('play');
  assert.equal(p.video.currentTime, 350);
  assert.deepEqual(p.errors, []);
});

test('live playback before any pause does not seek to the window start', async () => {
  const p = await player();
  p.video.currentTime = 0;
  p.setWindowStart(300);
  await p.video.emit('play');
  assert.equal(p.video.currentTime, 0);
  assert.deepEqual(p.errors, []);
});

test('native HLS DVR resumes at the oldest available position when the pause expired', async () => {
  const p = await player({ native: true });
  await p.video.emit('pause');
  p.video.currentTime = 120;
  p.video.seekable.start = () => 300;
  await p.video.emit('play');
  assert.equal(p.video.currentTime, 300.1);
  assert.deepEqual(p.errors, []);
});

test('live player shows EPG program time remaining', async () => {
  const p = await player({ programEnd: Date.now() / 1000 + 125.5 });
  const remaining = p.elements.get('program-remaining');
  assert.equal(remaining.classList.contains('hidden'), false);
  assert.equal(remaining.textContent, '2:05 left');
  assert.deepEqual(p.errors, []);
});

test('live player hides program remaining after the program ends', async () => {
  const p = await player({ programEnd: Date.now() / 1000 - 1 });
  const remaining = p.elements.get('program-remaining');
  assert.equal(remaining.classList.contains('hidden'), true);
  assert.deepEqual(p.errors, []);
});
