(function() {
  'use strict';

  window.NetvCast = {
    setup({ serverAddress, getMedia, onStarted }) {
      const el = id => document.getElementById('cast-' + id);
      const dialog = el('dialog');
      let active = false;
      let busy = false;
      let timer = null;
      let closed = false;
      let discovering = false;
      let generation = 0;
      el('btn').disabled = true;
      el('server').value = serverAddress || window.location.origin;

      function showError(error) {
        console.warn('[CAST]', error);
        el('error').textContent = error.message;
        el('error').classList.remove('hidden');
      }

      async function api(path, body) {
        const response = await fetch('/api/cast/' + path, {
          method: body ? 'POST' : 'GET',
          headers: { 'Accept': 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) },
          ...(body ? { body: JSON.stringify(body) } : {}),
          signal: AbortSignal.timeout(path === 'start' ? 45000 : 15000),
        });
        if (response.redirected) throw new Error('Sign in again to control Chromecast devices.');
        const data = await response.json();
        if (!response.ok) {
          throw new Error(typeof data.detail === 'string' ? data.detail : `Cast request failed (${response.status}).`);
        }
        return data;
      }

      async function render(status) {
        const wasActive = active;
        active = status.active;
        el('btn').classList.toggle('active', active);
        el('picker').classList.toggle('hidden', active);
        el('remote').classList.toggle('hidden', !active);
        if (active) {
          const text = `Casting to ${status.name} (${status.state.toLowerCase()})`;
          el('now').textContent = text;
          el('state').textContent = text;
          el('volume').value = status.volume;
          el('local').textContent = 'Stop casting and play here';
          el('overlay').classList.remove('hidden');
          if (!wasActive) await onStarted(status);
        } else if (wasActive) {
          el('state').textContent = 'Casting has ended.';
          el('local').textContent = 'Play here';
        }
      }

      async function poll() {
        const pollGeneration = generation;
        try {
          if (!busy) {
            const status = await api('status');
            if (!busy && generation === pollGeneration && !closed) await render(status);
          }
        } catch (error) {
          showError(error);
          if (active) el('state').textContent = 'Cannot reach neTV. The TV may still be playing.';
        } finally {
          if (!closed) timer = setTimeout(poll, 3000);
        }
      }

      async function discover() {
        if (discovering) return;
        discovering = true;
        el('refresh').disabled = true;
        el('discovery').textContent = 'Searching the local network...';
        el('devices').replaceChildren();
        try {
          const data = await api('devices');
          el('discovery').textContent = data.devices.length
            ? 'Select a TV, or enter its IP below.'
            : 'No devices found. Enter the TV IP below; Docker or guest Wi-Fi may block discovery.';
          for (const device of data.devices) {
            const button = document.createElement('button');
            button.className = 'px-3 py-2 bg-gray-700 rounded text-left';
            button.textContent = `${device.name} (${device.host})`;
            button.addEventListener('click', () => {
              el('ip').value = device.host;
              start();
            });
            el('devices').appendChild(button);
          }
        } catch (error) {
          el('discovery').textContent = 'Discovery unavailable. Try entering the TV IP manually.';
          showError(error);
        } finally {
          discovering = false;
          el('refresh').disabled = false;
        }
      }

      async function operation(action) {
        if (busy) return false;
        busy = true;
        generation++;
        el('error').classList.add('hidden');
        const controls = ['start', 'play', 'pause', 'stop', 'volume', 'local'];
        controls.forEach(id => { el(id).disabled = true; });
        try {
          await action();
          return true;
        } catch (error) {
          showError(error);
          if (!dialog.open) dialog.showModal();
          return false;
        } finally {
          busy = false;
          controls.forEach(id => { el(id).disabled = false; });
        }
      }

      async function start() {
        await operation(async () => {
          el('discovery').textContent = 'Preparing stream and connecting to the TV...';
          const media = await getMedia();
          const status = await api('start', {
            ...media, host: el('ip').value.trim(), server_url: el('server').value.trim(),
          });
          await render(status);
        });
      }

      async function open() {
        if (!dialog.open) dialog.showModal();
        if (!active) await discover();
      }

      el('btn').addEventListener('click', event => { event.stopPropagation(); open(); });
      el('manage').addEventListener('click', open);
      el('close').addEventListener('click', () => dialog.close());
      el('refresh').addEventListener('click', discover);
      el('form').addEventListener('submit', event => { event.preventDefault(); start(); });
      for (const action of ['play', 'pause', 'stop']) {
        el(action).addEventListener('click', () => operation(async () => {
          await render(await api('control', { action }));
        }));
      }
      el('volume').addEventListener('change', () => operation(async () => {
        await render(await api('control', { action: 'volume', volume: Number(el('volume').value) }));
      }));
      el('local').addEventListener('click', async () => {
        const stopped = await operation(async () => {
          if (active) await render(await api('control', { action: 'stop' }));
        });
        if (stopped) window.location.reload();
      });
      window.addEventListener('pagehide', () => { closed = true; clearTimeout(timer); });
      window.addEventListener('pageshow', event => {
        if (event.persisted) { closed = false; poll(); }
      });
      const ready = poll().finally(() => { el('btn').disabled = false; });
      return { ready, get active() { return active; }, get busy() { return busy; }, open };
    },
  };
})();
