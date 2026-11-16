import Foundation

/// JavaScript injected into the page. Both scripts are defensive: they call through to
/// the original browser implementation, they never read or alter site data, and any
/// failure leaves the page working exactly as it does in Safari.
enum WebShellScripts {

    /// Reports whether the student is capturing audio right now.
    ///
    /// The shell uses this only to decide whether it may reload the page for a new web
    /// build. Reloading in the middle of a recording would throw the take away, so a
    /// capture in progress always wins over a newer build.
    static let captureTracker = #"""
    (() => {
      if (window.__orunCaptureTracker) { return; }
      window.__orunCaptureTracker = true;
      const handlers = window.webkit && window.webkit.messageHandlers;
      const bridge = handlers && handlers.orunShell;
      const devices = navigator.mediaDevices;
      if (!bridge || !devices || typeof devices.getUserMedia !== 'function') { return; }
      const original = devices.getUserMedia.bind(devices);
      let live = 0;
      const notify = (active) => { try { bridge.postMessage({ op: 'capture', active: active }); } catch (_) { /* page keeps working */ } };
      devices.getUserMedia = function (constraints) {
        return original(constraints).then((stream) => {
          let tracks = [];
          try { tracks = stream.getAudioTracks(); } catch (_) { tracks = []; }
          if (!tracks.length) { return stream; }
          live += 1;
          notify(true);
          let settled = false;
          const done = () => {
            if (settled) { return; }
            settled = true;
            live = Math.max(0, live - 1);
            if (live === 0) { notify(false); }
          };
          tracks.forEach((track) => { try { track.addEventListener('ended', done); } catch (_) {} });
          return stream;
        });
      };
    })();
    """#

    /// Reports the asset references of the document that is actually loaded, so the
    /// shell can tell which web build the user is looking at without a second request.
    static let currentBuild = #"""
    (() => {
      try {
        return Array.from(document.querySelectorAll('script[src], link[rel="stylesheet"]'))
          .map((el) => el.getAttribute('src') || el.getAttribute('href') || '')
          .filter((value) => value.indexOf('/assets/') === 0)
          .sort()
          .join(' ');
      } catch (_) { return ''; }
    })();
    """#

    /// Turns `blob:`/`data:` downloads into files the app can hand to the share sheet.
    ///
    /// WKWebView cannot save a blob URL on its own, and the teacher report screens build
    /// their files in the page (docx / html2canvas / file-saver). Each transfer is
    /// user-initiated, single-file, size-capped and origin-checked again in Swift.
    static let fileBridge = #"""
    (() => {
      if (window.__orunFileBridge) { return; }
      window.__orunFileBridge = true;
      const handlers = window.webkit && window.webkit.messageHandlers;
      const bridge = handlers && handlers.orunFile;
      if (!bridge || !window.URL) { return; }
      const MAX = 40 * 1024 * 1024;
      const CHUNK = 262144;
      const known = new Map();
      const createObjectURL = URL.createObjectURL.bind(URL);
      const revokeObjectURL = URL.revokeObjectURL.bind(URL);
      URL.createObjectURL = function (value) {
        const url = createObjectURL(value);
        try { if (value instanceof Blob) { known.set(url, value); } } catch (_) {}
        return url;
      };
      URL.revokeObjectURL = function (url) {
        try { known.delete(url); } catch (_) {}
        return revokeObjectURL(url);
      };
      let busy = false;
      const report = () => { Promise.resolve(bridge.postMessage({ op: 'error' })).catch(() => {}); };
      async function transfer(blob, name) {
        if (busy) { report(); return; }
        if (!(blob instanceof Blob) || !blob.size || blob.size > MAX) { report(); return; }
        busy = true;
        const label = String(name || 'download').slice(0, 200);
        try {
          await bridge.postMessage({ op: 'begin', name: label, mime: String(blob.type || '').slice(0, 120), size: blob.size });
          for (let offset = 0; offset < blob.size; offset += CHUNK) {
            const bytes = new Uint8Array(await blob.slice(offset, offset + CHUNK).arrayBuffer());
            let binary = '';
            for (let i = 0; i < bytes.length; i += 8192) {
              binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
            }
            await bridge.postMessage({ op: 'chunk', data: btoa(binary) });
          }
          await bridge.postMessage({ op: 'end' });
        } catch (_) { report(); } finally { busy = false; }
      }
      // file-saver asks for window.saveAs before it creates its own anchor.
      window.saveAs = function (blob, name) {
        if (blob instanceof Blob) { void transfer(blob, name); return; }
        if (typeof blob === 'string') {
          const anchor = document.createElement('a');
          anchor.href = blob;
          anchor.download = name || 'download';
          anchor.click();
        }
      };
      function intercept(anchor) {
        if (!(anchor instanceof HTMLAnchorElement) || !anchor.hasAttribute('download')) { return false; }
        const href = anchor.href || '';
        let blob = null;
        if (href.indexOf('blob:') === 0) { blob = known.get(href) || null; }
        else if (href.indexOf('data:') !== 0) { return false; }
        void transfer(blob, anchor.download);
        return true;
      }
      const click = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () { if (!intercept(this)) { return click.call(this); } };
      document.addEventListener('click', (event) => {
        const anchor = event.target instanceof Element ? event.target.closest('a[download]') : null;
        if (anchor && intercept(anchor)) { event.preventDefault(); event.stopImmediatePropagation(); }
      }, true);
    })();
    """#
}
