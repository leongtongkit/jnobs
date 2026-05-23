// Jnobs Stream Deck plugin — webview-based.
//
// Stream Deck loads plugin.html in a webview at launch; this script connects
// back to the Stream Deck app over the WebSocket Stream Deck opens for us,
// and to the local Jnobs HTTP server (127.0.0.1:49152) for state + commands.
//
// Live state sync uses Server-Sent Events from Jnobs (/events) so a button's
// active-state highlight updates the instant the active profile changes —
// whether driven from this plugin, the Jnobs Console, or another button.

const JNOBS_URL = 'http://127.0.0.1:49152';

let websocket = null;
let pluginUUID = '';

// All currently-mounted Switch Profile buttons, by per-button context.
const switchProfileButtons = new Map();   // context -> profileName
// Latest active profile reported by Jnobs.
let lastActiveProfile = null;

// Stream Deck calls this once after the plugin webview loads. The signature
// is fixed by the SDK contract — don't rename.
function connectElgatoStreamDeckSocket(inPort, inUUID, inRegisterEvent, inInfo) {
    pluginUUID = inUUID;
    websocket = new WebSocket('ws://127.0.0.1:' + inPort);

    websocket.onopen = () => {
        websocket.send(JSON.stringify({ event: inRegisterEvent, uuid: inUUID }));
        startJnobsEventStream();
    };

    websocket.onmessage = (evt) => {
        try {
            handleStreamDeckEvent(JSON.parse(evt.data));
        } catch (e) {
            console.error('event parse error', e, evt.data);
        }
    };

    websocket.onclose = () => {
        // Stream Deck closed our socket — usually means the app is shutting
        // down. We don't reconnect; Stream Deck will relaunch us.
    };
}

function debug(message) {
    try {
        fetch(JNOBS_URL + '/log?msg=' + encodeURIComponent(message), { method: 'GET' });
    } catch (e) {}
}

function handleStreamDeckEvent(msg) {
    const ev = msg.event;
    const ctx = msg.context;
    const payload = msg.payload || {};

    debug(`event=${ev} action=${msg.action} ctx=${(ctx||'').slice(0,8)} settings=${JSON.stringify(payload.settings || {})}`);

    // Stream Deck normalizes UUIDs to lowercase — match defensively.
    switch ((msg.action || '').toLowerCase()) {
    case 'net.jfound.jnobs.switchprofile':
        handleSwitchProfile(ev, ctx, payload);
        break;
    case 'net.jfound.jnobs.cycleprofile':
        handleCycleProfile(ev, ctx, payload);
        break;
    case 'net.jfound.jnobs.togglemicmute':
        handleToggleMicMute(ev, ctx, payload);
        break;
    case 'net.jfound.jnobs.firebutton':
        handleFireButton(ev, ctx, payload);
        break;
    }

    // PI ↔ plugin messages aren't tied to an action UUID at the top level.
    if (ev === 'sendToPlugin') {
        handleSendToPlugin(msg);
    }
}

// ---- Switch Profile -------------------------------------------------------

function handleSwitchProfile(ev, ctx, payload) {
    if (ev === 'willAppear' || ev === 'didReceiveSettings') {
        const profileName = (payload.settings && payload.settings.profileName) || '';
        switchProfileButtons.set(ctx, profileName);
        updateSwitchProfileButton(ctx, profileName);
    } else if (ev === 'willDisappear') {
        switchProfileButtons.delete(ctx);
    } else if (ev === 'keyDown') {
        const profileName = switchProfileButtons.get(ctx);
        if (profileName) {
            fetch(JNOBS_URL + '/profile/load', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: profileName })
            }).catch(e => showAlert(ctx));
        }
    } else if (ev === 'propertyInspectorDidAppear') {
        // PI just opened — push the current profile list to it.
        pushProfilesToPI(ctx);
    }
}

function updateSwitchProfileButton(ctx, profileName) {
    const isActive = !!(profileName && profileName === lastActiveProfile);
    renderSwitchProfileIcon(ctx, profileName, isActive);
    setState(ctx, isActive ? 1 : 0);
    // We draw the label inside the icon ourselves, so clear the default title.
    setTitle(ctx, '');
}

/// Generate a per-button SVG icon and push it via setImage. Active = mint
/// glow on near-black, inactive = dim outline on charcoal. Saves us from
/// maintaining static action.png variants and keeps the visual aligned with
/// the Jnobs studio-panel palette.
function renderSwitchProfileIcon(context, profileName, isActive) {
    const label = profileName || '—';
    const truncated = label.length > 9 ? label.slice(0, 8) + '…' : label;
    const labelFontSize = truncated.length > 7 ? 26 : truncated.length > 5 ? 32 : 38;
    const ringColor   = isActive ? '#00DC5A' : '#3A3A3A';
    const ringWidth   = isActive ? 4 : 2;
    const bgFill      = isActive ? '#0A1E13' : '#161616';
    const labelColor  = isActive ? '#FFFFFF' : '#9A9A9A';
    const captionFill = isActive ? '#00DC5A' : '#6A6A6A';
    const glowOpacity = isActive ? 0.5 : 0;

    const svg = `<?xml version="1.0" encoding="UTF-8"?>` +
`<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">` +
    `<defs>` +
        `<filter id="glow" x="-20%" y="-20%" width="140%" height="140%">` +
            `<feGaussianBlur in="SourceGraphic" stdDeviation="3"/>` +
        `</filter>` +
    `</defs>` +
    `<rect width="144" height="144" fill="#000"/>` +
    `<rect x="8" y="8" width="128" height="128" rx="16" fill="${bgFill}" stroke="${ringColor}" stroke-width="${ringWidth}"/>` +
    (isActive ? `<rect x="8" y="8" width="128" height="128" rx="16" fill="none" stroke="${ringColor}" stroke-width="${ringWidth}" filter="url(#glow)" opacity="${glowOpacity}"/>` : '') +
    `<text x="72" y="50" font-family="-apple-system,Helvetica,sans-serif" font-size="16" font-weight="900" letter-spacing="2.4" text-anchor="middle" fill="${captionFill}">PROFILE</text>` +
    `<text x="72" y="100" font-family="-apple-system,Helvetica,sans-serif" font-size="${labelFontSize}" font-weight="800" text-anchor="middle" fill="${labelColor}">${escapeXml(truncated)}</text>` +
`</svg>`;
    const encoded = 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(svg)));
    websocket.send(JSON.stringify({
        event: 'setImage',
        context: context,
        payload: { image: encoded, target: 0 }
    }));
}

function escapeXml(s) {
    return s.replace(/[<>&'"]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;',"'":'&apos;','"':'&quot;'}[c]));
}

function refreshAllSwitchProfileButtons() {
    for (const [ctx, name] of switchProfileButtons.entries()) {
        updateSwitchProfileButton(ctx, name);
    }
}

// ---- Cycle Profile --------------------------------------------------------

function handleCycleProfile(ev, ctx, payload) {
    if (ev === 'willAppear' || ev === 'didReceiveSettings') {
        const dir = (payload.settings && payload.settings.direction) === 'previous' ? 'previous' : 'next';
        setTitle(ctx, dir === 'previous' ? '◀ Prev' : 'Next ▶');
    } else if (ev === 'keyDown') {
        const dir = (payload.settings && payload.settings.direction) === 'previous' ? 'previous' : 'next';
        fetch(JNOBS_URL + '/profile/' + dir, { method: 'POST' }).catch(e => showAlert(ctx));
    }
}

// ---- Toggle Mic Mute ------------------------------------------------------

function handleToggleMicMute(ev, ctx, payload) {
    if (ev === 'keyDown') {
        fetch(JNOBS_URL + '/mute/mic', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: '{}'
        }).catch(e => showAlert(ctx));
    }
}

// ---- Fire Button ----------------------------------------------------------

function handleFireButton(ev, ctx, payload) {
    if (ev === 'willAppear' || ev === 'didReceiveSettings') {
        const idx = (payload.settings && payload.settings.buttonIndex);
        if (idx !== undefined) setTitle(ctx, 'BTN ' + (parseInt(idx, 10) + 1));
    } else if (ev === 'keyDown') {
        const idx = (payload.settings && payload.settings.buttonIndex);
        if (idx === undefined || idx === '') { showAlert(ctx); return; }
        fetch(JNOBS_URL + '/button/' + parseInt(idx, 10), { method: 'POST' })
            .catch(e => showAlert(ctx));
    }
}

// ---- PI messaging ---------------------------------------------------------

function handleSendToPlugin(msg) {
    const payload = msg.payload || {};
    if (payload.event === 'requestProfiles') {
        pushProfilesToPI(msg.context);
    }
}

function pushProfilesToPI(context) {
    fetch(JNOBS_URL + '/state')
        .then(r => r.json())
        .then(state => {
            websocket.send(JSON.stringify({
                event: 'sendToPropertyInspector',
                context: context,
                action: 'net.jfound.jnobs.switchprofile',
                payload: {
                    profiles: state.profiles,
                    activeProfile: state.activeProfile
                }
            }));
        })
        .catch(e => {
            websocket.send(JSON.stringify({
                event: 'sendToPropertyInspector',
                context: context,
                action: 'net.jfound.jnobs.switchprofile',
                payload: { error: 'Jnobs not running' }
            }));
        });
}

// ---- Stream Deck command helpers ------------------------------------------

function setTitle(context, title) {
    if (!websocket || websocket.readyState !== 1) return;
    websocket.send(JSON.stringify({
        event: 'setTitle',
        context: context,
        payload: { title: title || '', target: 0 }
    }));
}

function setState(context, state) {
    if (!websocket || websocket.readyState !== 1) return;
    websocket.send(JSON.stringify({
        event: 'setState',
        context: context,
        payload: { state: state }
    }));
}

function showAlert(context) {
    if (!websocket || websocket.readyState !== 1) return;
    websocket.send(JSON.stringify({
        event: 'showAlert',
        context: context
    }));
}

// ---- Jnobs SSE ------------------------------------------------------------

let eventSource = null;
let reconnectTimer = null;

function startJnobsEventStream() {
    if (eventSource) eventSource.close();
    eventSource = new EventSource(JNOBS_URL + '/events');

    eventSource.addEventListener('state', (e) => {
        try {
            const state = JSON.parse(e.data);
            lastActiveProfile = state.activeProfile || null;
            refreshAllSwitchProfileButtons();
        } catch (err) {
            console.error('state parse', err);
        }
    });

    eventSource.onerror = () => {
        eventSource.close();
        eventSource = null;
        if (reconnectTimer) return;
        reconnectTimer = setTimeout(() => {
            reconnectTimer = null;
            startJnobsEventStream();
        }, 3000);
    };
}
