// kiosk-chrome.js — hide ALL HA chrome when URL has ?kiosk=1 + enable 1-click hold-to-record voice.
// Registered via frontend.extra_module_url in configuration.yaml.
// Pure vanilla JS injected into Home Assistant shadow DOMs.

(() => {
  if (!location.search.includes('kiosk')) return;

  const CSS = `
    /* Top bar (dashboard title, edit pencil, kebab, hamburger) */
    app-header,
    app-toolbar,
    ha-top-app-bar-fixed,
    mwc-top-app-bar-fixed,
    ha-menu-button,
    .toolbar,
    .header,
    #header { display: none !important; height: 0 !important; min-height: 0 !important; }

    /* View tabs (shown when a dashboard has multiple views) */
    paper-tabs,
    ha-tabs,
    sl-tab-group { display: none !important; }

    /* Sidebar + the shoulder it reserves */
    ha-sidebar,
    partial-panel-resolver > ha-sidebar { display: none !important; width: 0 !important; }
    ha-drawer,
    .mdc-drawer,
    .mdc-drawer-app-content,
    mwc-drawer { margin-left: 0 !important; padding-left: 0 !important; }
    .mdc-drawer--open,
    .mdc-drawer--dismissible { transform: translateX(-100%) !important; }

    /* Edit-mode UI */
    ha-icon-button-edit,
    ha-fab[icon="hass:pencil"],
    .edit-mode,
    hui-edit-dialog { display: none !important; }

    /* Lovelace view — kill the top padding that assumed a header */
    hui-root,
    hui-view,
    #view,
    .view { padding-top: 0 !important; margin-top: 0 !important; }

    /* Full-bleed background so hidden-chrome doesn't leave a strip */
    html, body { background: #000 !important; overscroll-behavior: none; }

    /* Voice recording card animations */
    .voice-recording {
      animation: voice-pulse 1.2s infinite alternate !important;
      outline: 3px solid #ff3b30 !important;
      transform: scale(0.98) !important;
      transition: transform 0.1s ease !important;
    }
    .voice-cancelling {
      outline: 3px solid #ffd60a !important;
      opacity: 0.6 !important;
    }
    .voice-sent {
      outline: 3px solid #30d158 !important;
      transition: outline 0.2s ease !important;
    }
    @keyframes voice-pulse {
      0% { box-shadow: 0 0 0 0 rgba(255, 59, 48, 0.7); }
      100% { box-shadow: 0 0 20px 6px rgba(255, 59, 48, 0.9); }
    }
  `;

  const STYLE_ID = 'kiosk-chrome-style';

  const inject = (root) => {
    if (!root) return;
    const has = root.querySelector ? root.querySelector(`#${STYLE_ID}`) : null;
    if (has) return;
    const s = document.createElement('style');
    s.id = STYLE_ID;
    s.textContent = CSS;
    (root.appendChild ? root : document.head).appendChild(s);
  };

  inject(document.head);

  // --- Voice-From-Home Hold-To-Record Module ---
  const WABOT_URL = 'https://sirajju.tail7dc29c.ts.net:8766/voice-from-home';
  let mediaStream = null, rec = null, chunks = [];
  let isRecording = false, isCancelled = false, isSending = false;
  let startTime = 0, startX = 0, startY = 0, pointerId = null;

  function pickMime() {
    const prefs = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/ogg', 'audio/mp4'];
    for (const m of prefs) {
      if (window.MediaRecorder && MediaRecorder.isTypeSupported(m)) return m;
    }
    return '';
  }

  async function initMic() {
    if (mediaStream && mediaStream.active) return mediaStream;
    try {
      mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true }
      });
      return mediaStream;
    } catch (e) {
      console.error('mic init failed', e);
      return null;
    }
  }

  function bindVoiceButton(card) {
    if (card._voiceBound) return;
    card._voiceBound = true;

    // Prevent HA default click navigation when held
    card.addEventListener('click', (e) => {
      if (card._didRecord) {
        e.preventDefault();
        e.stopPropagation();
        card._didRecord = false;
      }
    }, true);

    card.addEventListener('pointerdown', async (e) => {
      if (isSending) return;
      card._didRecord = false;
      pointerId = e.pointerId;
      startX = e.clientX;
      startY = e.clientY;

      const stream = await initMic();
      if (!stream) return;

      const mime = pickMime();
      rec = new MediaRecorder(stream, mime ? { mimeType: mime } : {});
      chunks = [];
      isCancelled = false;
      isRecording = true;
      startTime = Date.now();

      rec.ondataavailable = evt => {
        if (evt.data && evt.data.size > 0) chunks.push(evt.data);
      };

      rec.onstop = async () => {
        card.classList.remove('voice-recording', 'voice-cancelling');
        if (isCancelled) return;

        const duration = Date.now() - startTime;
        if (duration < 500) {
          // Quick tap - let HA default navigation handle it
          return;
        }

        // Send recorded audio!
        isSending = true;
        card.classList.add('voice-sent');
        try {
          const blob = new Blob(chunks, { type: rec.mimeType || 'audio/webm' });
          const res = await fetch(WABOT_URL, {
            method: 'POST',
            headers: { 'Content-Type': blob.type || 'audio/webm' },
            body: blob
          });
          if (res.ok) {
            if (navigator.vibrate) navigator.vibrate([40, 60, 40]);
          }
        } catch (err) {
          console.error('voice send error', err);
        } finally {
          isSending = false;
          setTimeout(() => card.classList.remove('voice-sent'), 1200);
        }
      };

      rec.start(100);
      card.classList.add('voice-recording');
      if (navigator.vibrate) navigator.vibrate(40);
      card._didRecord = true;
    });

    card.addEventListener('pointermove', (e) => {
      if (!isRecording) return;
      const dist = Math.hypot(e.clientX - startX, e.clientY - startY);
      if (dist > 60) {
        if (!isCancelled) {
          isCancelled = true;
          card.classList.remove('voice-recording');
          card.classList.add('voice-cancelling');
        }
      } else {
        if (isCancelled) {
          isCancelled = false;
          card.classList.remove('voice-cancelling');
          card.classList.add('voice-recording');
        }
      }
    });

    const stopRec = () => {
      if (!isRecording) return;
      isRecording = false;
      if (rec && rec.state !== 'inactive') rec.stop();
    };

    card.addEventListener('pointerup', stopRec);
    card.addEventListener('pointercancel', () => {
      isCancelled = true;
      stopRec();
    });
  }

  // HA renders inside nested shadow DOMs. Walk them all.
  const walk = (node, seen = new Set()) => {
    if (!node || seen.has(node)) return;
    seen.add(node);
    if (node.shadowRoot) {
      inject(node.shadowRoot);
      for (const c of node.shadowRoot.querySelectorAll('*')) {
        // Find the "Voice to Sirajju" card
        if (c.tagName === 'HA-CARD' || c.classList?.contains('card')) {
          const text = c.textContent || '';
          if (text.includes('Voice') || text.includes('Sirajju')) {
            bindVoiceButton(c);
          }
        }
        walk(c, seen);
      }
    }
    for (const c of node.children || []) walk(c, seen);
  };

  const sweep = () => walk(document.body);
  sweep();

  const mo = new MutationObserver(sweep);
  mo.observe(document.body, { childList: true, subtree: true });

  try {
    window.dispatchEvent(new CustomEvent('hass-dock-sidebar', { detail: { dock: 'always_hidden' } }));
  } catch {}
})();
