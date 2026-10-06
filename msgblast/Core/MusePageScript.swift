import Foundation

// DOM contract observed in Muse's shipped frontend. No private RPCs or session tokens.
enum MusePageScript {
    static let helpers = #"""
    const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
    const unique = selector => { const es = [...document.querySelectorAll(selector)].filter(visible); return es.length === 1 ? es[0] : null; };
    const editor = () => unique('textarea[aria-label="Message"]');
    const buttons = label => [...document.querySelectorAll('button')].filter(e => visible(e) && e.getAttribute('aria-label') === label);
    const normalized = s => s.replace(/\s+/g, ' ').trim();
    const messages = () => [...document.querySelectorAll('[data-message-item][data-message-id][data-message-role]')].map(e => {
        const copy = e.cloneNode(true);
        copy.querySelectorAll('button,[role="button"],time').forEach(n => n.remove());
        return {id:e.getAttribute('data-message-id'),role:e.getAttribute('data-message-role'),text:normalized(copy.textContent || '').replace(/^You:\s*/, '')};
    });
    const observation = globalThis.__msgblastMuseObservation ??= {interrupted:false};
    if (!observation.listening) {
        observation.listening=true;
        for (const event of ['pointerdown','keydown','input','popstate'])
            window.addEventListener(event,e=>{if(e.isTrusted) observation.interrupted=true;},true);
    }
    const pathAllowed = () => location.protocol === 'https:' && location.hostname === 'muse.ai' &&
        !location.search && !location.hash && /^\/thread\/(new|[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})$/.test(location.pathname);
    const status = () => {
        let reason = '';
        const input = editor();
        if (!pathAllowed()) reason = 'Open this comparison’s Muse side chat before sending.';
        else if (![...document.querySelectorAll('[aria-label="Chat messages"],#hatch-chat-scroll')].some(visible)) reason = 'Sign in to Muse and open a side chat.';
        else if (document.querySelector('[role="dialog"],[aria-modal="true"]')) reason = 'Finish the open Muse dialog first.';
        else if (!input || input.disabled || input.readOnly) reason = 'Waiting for Muse’s message field.';
        return {url:location.href,ready:reason === '',reason:reason || 'Muse side chat ready',draft:input?.value || ''};
    };
    const inspect = () => ({...status(),messages:pathAllowed() ? messages() : [],submissionInterrupted:observation.interrupted});
    """#

    static let inspect = helpers + "\nreturn inspect();"
    // Read only the displayed side-chat avatar, including a still of animated media.
    // Drawing already-loaded media avoids extracting cookies, tokens, or private API state.
    static let avatar = helpers + #"""
    if (!status().ready) return {};
    const host = unique('[data-hatch-avatar-host][data-hatch-avatar-display-stage="chat-nav"]');
    if (!host || host.getAttribute('data-hatch-avatar-host-hidden') === 'true' || getComputedStyle(host).opacity === '0') return {};
    const candidates = [...host.querySelectorAll('img[data-hatch-avatar-layer="ready"][data-hatch-avatar-slot="current"],video[data-hatch-avatar-layer="ready"][data-hatch-avatar-slot="current"]')]
      .filter(e => visible(e) && Number(getComputedStyle(e).opacity) >= 0.95);
    if (candidates.length !== 1) return {};
    const media = candidates[0], video = media instanceof HTMLVideoElement;
    const width = video ? media.videoWidth : media.naturalWidth, height = video ? media.videoHeight : media.naturalHeight;
    if (!width || !height || (video && media.readyState < 2)) return {};
    const src = media.currentSrc || media.src;
    let cached = globalThis.__msgblastAvatarSource;
    if (!cached || cached.node !== media || cached.src !== src) {
      cached = {node:media,src,key:crypto.randomUUID()};
      globalThis.__msgblastAvatarSource = cached;
    }
    if (cached.key === previousKey) return {key:cached.key};
    try {
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 256;
      const side = Math.min(width, height);
      // This canvas is read back as PNG; CPU backing also works without GPU surfaces.
      canvas.getContext('2d', {willReadFrequently: true}).drawImage(media, (width-side)/2, (height-side)/2, side, side, 0, 0, 256, 256);
      return {key:cached.key,png:canvas.toDataURL('image/png')};
    } catch { return {}; }
    """#
    static let prepare = helpers + #"""
    const before = status();
    if (!before.ready) return {ok:false,reason:before.reason};
    if (before.draft.trim()) return {ok:false,reason:'Muse already has a draft. Send or clear it in the page first.'};
    const baseline = messages();
    const existingConversationPaths = [...document.querySelectorAll('a[href]')].map(a=>new URL(a.href,location.href)).filter(u=>u.origin===location.origin).map(u=>u.pathname);
    const input = editor();
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(input, text);
    input.dispatchEvent(new Event('input', {bubbles:true}));
    input.dispatchEvent(new Event('change', {bubbles:true}));
    return {ok:true,messageIDs:baseline.map(m=>m.id),messages:baseline,existingConversationPaths};
    """#
    static let clickSend = helpers + #"""
    const current = status();
    if (!current.ready || current.url !== expectedURL || current.draft !== text)
        return {clicked:false,reason:'Muse changed during preparation. Nothing was clicked; review its draft.'};
    const send = buttons('Send');
    if (send.length !== 1 || send[0].disabled || send[0].getAttribute('aria-disabled') === 'true')
        return {clicked:false,reason:'Muse’s Send control is unavailable. Review the prepared draft in Muse.'};
    observation.interrupted=false;
    send[0].click();
    return {clicked:true};
    """#

    // This local HTML exercises the same WKWebView and DOM adapter as live mode.
    // It is only loaded for the app's existing demo environment; it makes no network requests.
    static let fixture = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    :root { color-scheme:light dark; font:15px -apple-system,sans-serif; } body{margin:0;padding:24px; background:Canvas;color:CanvasText}
    header{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #8884;padding-bottom:16px}
    small{color:#888} #hatch-chat-scroll{min-height:180px;padding:24px 0} article{padding:14px 16px;margin:12px 0;background:#8882;border-radius:16px}
    [data-message-role=user]{background:#1684ff;color:white;margin-left:45px} textarea{box-sizing:border-box;width:100%;min-height:65px;font:inherit;padding:12px;border:1px solid #8885;border-radius:14px}
    button{font:inherit;padding:8px 14px;margin:8px 0;border-radius:10px;border:1px solid #8885;cursor:pointer} [hidden]{display:none!important}
    </style></head><body><header><div data-hatch-avatar-host data-hatch-avatar-display-stage="chat-nav"><img hidden data-hatch-avatar-layer="ready" data-hatch-avatar-slot="current" alt="Synthetic personalized avatar" style="width:48px;height:48px;border-radius:50%"></div><strong id="thread-title">New Muse side chat</strong><small>Local fixture · no real sends</small></header>
    <div id="login" hidden><p>Sign in to continue.</p><button onclick="login.hidden=true;chat.hidden=false">Sign in to fixture</button></div>
    <div id="chat"><div id="hatch-chat-scroll" aria-label="Chat messages"><article data-message-item data-message-id="welcome" data-message-role="assistant">Ready to compare an idea? Send a message from MsgBlast’s shared composer.</article></div>
    <textarea aria-label="Message" placeholder="Message"></textarea><button aria-label="Send" disabled>Send</button>
    <button onclick="chat.hidden=true;login.hidden=false">Sign out of fixture</button>
    <button onclick="changeFixtureAvatar()">Change fixture avatar</button></div>
    <script>
    const fixtureThreads = {};
    function navigateFixtureThread(url) {
      fixtureThreads[location.pathname] = document.getElementById('hatch-chat-scroll').innerHTML;
      history.replaceState({},'',url);
      document.getElementById('hatch-chat-scroll').innerHTML = location.pathname === '/thread/new' ? '' : (fixtureThreads[location.pathname] || '');
      document.getElementById('thread-title').textContent = location.pathname === '/thread/new' ? 'New Muse side chat' : 'Muse side chat · '+location.pathname.slice(-6);
    }
    let avatarVersion=0;
    // Fixed PNGs avoid canvas-generated image decoder transitions on virtual Macs.
    function changeFixtureAvatar(){const image=document.querySelector('[data-hatch-avatar-layer]');image.src=++avatarVersion%2?'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAIAAADTED8xAAACwElEQVR4nO3TMQ0AMAzAsMIcgXEenMHoEUsGkCdz7oOsWS+ARQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQNoHbecXvGefijUAAAAASUVORK5CYII=':'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAIAAADTED8xAAACwElEQVR4nO3TMQ0AMAzAsHIY2YEY6MHoEUsGkCdz3oWsWS+ARQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQJoBSDMAaQYgzQCkGYA0A5BmANIMQNoHGCMQWim1OTQAAAAASUVORK5CYII=';image.hidden=false;}
    const input=document.querySelector('textarea'),send=document.querySelector('[aria-label=Send]');
    input.addEventListener('input',()=>{send.disabled=!input.value.trim()});
    send.addEventListener('click',()=>{
      const text=input.value;if(!text.trim())return;
      function add(role,text){const a=document.createElement('article');a.dataset.messageItem='true';a.dataset.messageId=crypto.randomUUID();a.dataset.messageRole=role;a.textContent=text;document.getElementById('hatch-chat-scroll').append(a);a.scrollIntoView({block:'nearest'});}
      if(location.pathname === '/thread/new') {
        history.replaceState({},'', '/thread/'+crypto.randomUUID());
        document.getElementById('thread-title').textContent='Muse side chat · '+location.pathname.slice(-6);
      }
      add('user',text);input.value='';send.disabled=true;
      setTimeout(()=>add('assistant','Fixture reply: '+text),350);
    });
    </script></body></html>
    """#
}
