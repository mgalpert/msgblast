import Foundation

// Each adapter operates on the rendered page, using normal input events and one Send click.
// Unknown layouts stay usable as embedded pages but cannot receive shared submissions.
struct WebPageScript {
    let provider: WebProvider
    private var helpers: String {
        let selectors: (editor: String, send: String, messages: String, account: String)
        switch provider {
        case .codexCLI, .claudeCode, .grokbot: preconditionFailure("Native agents do not use page scripts")
        case .muse: return MusePageScript.helpers
        case .chatgpt:
            selectors = (#"textarea[aria-label="Chat with ChatGPT"],#prompt-textarea[contenteditable="true"],[contenteditable="true"][role="textbox"][aria-label="Ask ChatGPT"]"#,
                         #"button[data-testid="send-button"],button[aria-label="Send message"],button[aria-label="Send prompt"],button[aria-label="Send"]"#,
                         #"[data-message-author-role][data-message-id],[data-chatgpt-search-unit-key][data-chatgpt-search-message-ids]"#,
                         #"button[data-testid="accounts-profile-button"],button[aria-label="Open profile menu"]"#)
        case .dots:
            selectors = (#"[contenteditable="true"][role="textbox"][aria-label="Message"][data-composer-markdown]"#,
                         #"button[aria-label="Send"]"#,
                         #"article.message-row[data-message-id]"#,
                         #"button[aria-label="Your dot actions"],button[data-orbit-profile-trigger][aria-label^="Open "][aria-label$="profile"]"#)
        case .claude:
            selectors = (#"[contenteditable="true"][data-testid="chat-input"],div[contenteditable="true"].ProseMirror"#,
                         #"button[aria-label="Send message"],button[data-testid="send-button"]"#,
                         #"[data-testid="user-message"],[data-testid="assistant-message"],.font-claude-message"#,
                         #"button[data-testid="user-menu-button"],button[aria-label="User menu"],button[aria-label="Open user menu"]"#)
        case .grok:
            selectors = (#"textarea[aria-label="Ask Grok anything"],textarea[placeholder="What do you want to know?"],[contenteditable="true"][role="textbox"][aria-label="Ask Grok anything"]"#,
                         #"button[data-testid="chat-submit"],button[aria-label="Submit"]"#,
                         #"[data-message-id][data-message-role],.message-bubble"#,
                         #"button[data-testid="user-menu-button"],button[aria-label="User menu"],button[aria-label="Open user menu"],button[aria-label="Account menu"],button[aria-haspopup="menu"]:has(img[alt="pfp"])"#)
        case .os3:
            selectors = (#"textarea[aria-label="message input"]"#,
                         #"button[aria-label="send message"]"#,
                         #"[role="log"][aria-label="conversation"] > .dial-msg[data-render-id^="msg-"]"#,
                         #"button[aria-label="Settings"]"#)
        }
        let config: [String: String] = ["name":provider.name,"provider":provider.rawValue,"host":provider.homeURL.host!,"editor":selectors.editor,"send":selectors.send,"messages":selectors.messages,"account":selectors.account]
        let json = String(data: try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), encoding: .utf8)!
        return "const config = \(json);\n" + #"""
        const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
        const all = selector => [...document.querySelectorAll(selector)].filter(visible);
        const unique = selector => { const es=all(selector); return es.length===1 ? es[0] : null; };
        const editor = () => unique(config.editor);
        const draft = input => input ? (input instanceof HTMLTextAreaElement ? input.value : input.innerText).replace(/\r\n/g,'\n') : '';
        const normalized = s => s.replace(/\s+/g,' ').trim();
        // Kept in WebKit's isolated world, never in page storage. Node identities survive
        // visibility and history-order changes; replacing old nodes invalidates continuity.
        const observation = globalThis.__msgblastObservation ??= {ids:new WeakMap(),nextID:0,interrupted:false};
        if (!observation.listening) {
            observation.listening=true;
            for (const event of ['pointerdown','keydown','input','popstate'])
                window.addEventListener(event,e=>{if(e.isTrusted) observation.interrupted=true;},true);
        }
        const pathAllowed = () => location.protocol==='https:' && location.hostname===config.host &&
            (config.provider==='dots' ? (location.pathname==='/dots/home' || /^\/dots\/[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(location.pathname)) : config.provider==='claude' ? /^\/(new|chat\/[a-zA-Z0-9-]+)\/?$/.test(location.pathname) : /^(\/|\/c\/[a-zA-Z0-9-]+\/?)$/.test(location.pathname));
        const messages = () => [...document.querySelectorAll(config.messages)].filter(e => !e.parentElement?.closest(config.messages)).map(e => {
            let role=e.getAttribute('data-message-author-role') || e.getAttribute('data-message-role');
            let id=e.getAttribute('data-message-id') || e.closest('[data-message-id]')?.getAttribute('data-message-id');
            if (!role && config.provider==='chatgpt') {
                const roleMatch=e.getAttribute('data-chatgpt-search-unit-key')?.match(/:(user|assistant)$/);
                const ids=[...new Set((e.getAttribute('data-chatgpt-search-message-ids')||'').split(/\s+/).filter(Boolean))];
                if (roleMatch && ids.length===1) { role=roleMatch[1]; id=ids[0]; }
            }
            if (config.provider==='dots') role=e.classList.contains('self') ? 'user' : 'assistant';
            if (!role && config.provider==='claude') role=e.getAttribute('data-testid')==='user-message' ? 'user' : 'assistant';
            if (!role && config.provider==='grok') role=e.classList.contains('items-end') || e.closest('[data-role="user"],.items-end') ? 'user' : 'assistant';
            if (config.provider==='os3') { role=e.classList.contains('dial-user') ? 'user' : 'assistant'; id=e.dataset.renderId; }
            const copy=(config.provider==='dots' ? e.querySelector('.message-text') || document.createElement('span') : e).cloneNode(true); copy.querySelectorAll('button,[role="button"],time').forEach(n=>n.remove());
            if (config.provider==='chatgpt') copy.querySelectorAll('h4[data-conversation-role]').forEach(n=>n.remove());
            if (config.provider==='os3') copy.querySelectorAll('.dial-meta,.dial-reaction').forEach(n=>n.remove());
            copy.querySelectorAll('br,p,div,li,pre,blockquote').forEach(n=>n.append(document.createTextNode(' ')));
            if (!observation.ids.has(e)) observation.ids.set(e,`node-${++observation.nextID}`);
            return {id:id||observation.ids.get(e),role:role||'unknown',text:normalized(copy.textContent||'')};
        });
        const conversationLocation = () => {
            const url=new URL(location.href),params=[...url.searchParams];
            // Grok appends a response ID while staying in the same conversation.
            if (config.provider==='grok' && /^\/c\/[a-zA-Z0-9-]+\/?$/.test(url.pathname) && !url.hash &&
                params.length===1 && params[0][0]==='rid' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(params[0][1])) url.search='';
            return url.href;
        };
        const status = () => {
            const input=editor(); let reason='';
            const login=all('button[data-testid="login-button"]').length>0 || all('button,a').some(e=>/^(log in|sign in|sign up|sign up for free)$/i.test(normalized(e.innerText||e.getAttribute('aria-label')||'')) || (config.provider==='dots' && /^(log in|sign in)$/i.test(e.getAttribute('aria-label')||'')));
            const account=document.querySelector(config.account);
            const signedIn=login ? false : account ? true : null;
            // Closed panels can stay rendered, marked aria-hidden or moved off-screen.
            const modal=all('[role="dialog"],[aria-modal="true"]').some(e=>{const r=e.getBoundingClientRect();
                const offScreen=r.width>0 && r.height>0 && (r.right<=0 || r.bottom<=0 || r.left>=innerWidth || r.top>=innerHeight);
                return e.getAttribute('aria-hidden')!=='true' && !offScreen;});
            const generating=all('button[data-testid="stop-button"],button[aria-label="Stop generating"],button[aria-label="Stop response"],button[aria-label="Stop"],.dial-msg.writing,[data-render-id="thinking"]').length>0;
            if (!pathAllowed()) reason=`Open a ${config.name} chat to send from MsgBlast.`;
            else if (login) reason=`Sign in to ${config.name} to send this request.`;
            // Responsive sidebars hide their account control without ending the session.
            // Still require known account markup and a visible, unique editor below.
            else if (!account) reason=`${config.name}’s page layout is not recognized yet. Reload the page and try again.`;
            else if (modal) reason=`Finish the open dialog in ${config.name} first.`;
            else if (generating) reason=`Wait for ${config.name} to finish its current reply.`;
            else if (!input || input.disabled || input.readOnly || input.getAttribute('aria-disabled')==='true') reason=`Waiting for ${config.name}’s message field.`;
            return {url:conversationLocation(),ready:!reason,signedIn,reason:reason||`${config.name} chat ready`,draft:draft(input),draftAvailable:!!input,...(config.provider==='dots'?{signedOut:login && !all(config.account).length}:{})};
        };
        const submissionStatus = () => {
            const current=status();
            if (!current.ready || current.url!==expectedURL || current.draft!==preparedDraft || observation.interrupted)
                return {ready:false,retryable:false,reason:`${config.name} changed during preparation. Review its draft; nothing was clicked.`};
            const candidates=all(config.send),send=candidates.length===1?candidates[0]:null;
            const ready=!!send && !send.disabled && send.getAttribute('aria-disabled')!=='true';
            return {ready,retryable:candidates.length<2,reason:`${config.name}’s Send control is unavailable. Review the prepared draft.`};
        };
        const inspect = () => ({...status(),messages:pathAllowed()?messages():[],submissionInterrupted:observation.interrupted});
        """#
    }
    var signInStatus: String { helpers + "\nreturn {...status(),messages:[]};" }
    var inspect: String { provider == .muse ? MusePageScript.inspect : helpers + "\nreturn inspect();" }
    // Apply the initial pane layout once per document. A user's later choice wins.
    var configureInitialLayout: String {
        guard provider == .chatgpt || provider == .dots else { return "return;" }
        return helpers + #"""
        if (observation.layoutConfigured) return;
        if (observation.interrupted) { observation.layoutConfigured=true; return; }
        if (!pathAllowed() || !editor() || !document.querySelector(config.account)) return;
        const close=all('button[aria-label="Close sidebar"][aria-expanded="true"]');
        const expanded=close.length ? close : all('button[aria-label="Toggle sidebar"][aria-expanded="true"],button[aria-label="Hide sidebar"][aria-expanded="true"]');
        if (!expanded.length) {
            if (all('button[aria-label="Show sidebar"],button[aria-label="Toggle sidebar"][aria-expanded="false"]').length) observation.layoutConfigured=true;
            return;
        }
        if (expanded.length!==1) return;
        const toggle=expanded[0];
        // In narrow panes the sidebar itself is a dialog. Leave other dialogs alone.
        if (all('[role="dialog"],[aria-modal="true"]').some(d=>!d.contains(toggle))) return;
        if (toggle.disabled || toggle.getAttribute('aria-disabled')==='true') return;
        observation.layoutConfigured=true;
        toggle.click();
        """#
    }
    // Crop the rendered profile avatar: pets use CSS sprite sheets, while other
    // dot characters can use SVG/canvas. Never mistake a chat attachment for it.
    var avatar: String {
        if provider == .muse { return MusePageScript.avatar }
        guard provider == .dots else { return "return {};" }
        return helpers + #"""
        if (!pathAllowed() || !document.querySelector(config.account)) return {};
        const triggers=all('button[data-orbit-profile-trigger]').filter(e=>/^Open .+['’]s profile$/.test(e.getAttribute('aria-label')||''));
        if (triggers.length!==1) return {};
        const host=triggers[0].parentElement;
        const avatars=[...host.querySelectorAll('span[role="presentation"]')].filter(visible);
        if (avatars.length!==1) return {};
        const avatar=avatars[0];
        const describe=()=>{
            const rect=avatar.getBoundingClientRect(),pet=avatar.querySelector('[data-codex-pet-id]');
            if (!visible(avatar) || rect.width<=0 || rect.height<=0 || rect.top<0 || rect.left<0 || rect.right>innerWidth || rect.bottom>innerHeight) return null;
            return {url:location.href,viewport:{width:innerWidth,height:innerHeight},rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
                identity:location.pathname+'|'+(pet ? pet.getAttribute('data-codex-pet-id')+'|'+getComputedStyle(pet).backgroundImage : avatar.innerHTML)};
        };
        const before=describe();
        if (!before) return {};
        const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(before.identity));
        const key=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
        if (key!==(typeof previousKey==='string'?previousKey:'')) {
            // A CSS sprite URL can be present before its pixels are decoded.
            // Keep the old saved image until the new artwork can be painted.
            const pet=avatar.querySelector('[data-codex-pet-id]');
            if (pet) {
                const source=getComputedStyle(pet).backgroundImage.match(/^url\((?:"([^"]*)"|'([^']*)'|([^)]*))\)$/);
                if (!source) return {};
                const image=new Image();image.src=source[1]??source[2]??source[3];
                try { await image.decode(); } catch { return {}; }
            }
            try { await Promise.all([...avatar.querySelectorAll('img')].map(image=>image.decode())); }
            catch { return {}; }
        }
        if (JSON.stringify(before)!==JSON.stringify(describe())) return {};
        return {key,url:before.url,viewport:before.viewport,rect:before.rect};
        """#
    }

    var prepare: String {
        if provider == .muse { return MusePageScript.prepare }
        return helpers + #"""
        const before=status();
        if (!before.ready) return {ok:false,reason:before.reason};
        if (before.draft.trim()) return {ok:false,reason:`${config.name} already has a draft. Send or clear it in the page first.`};
        const baseline=messages(),input=editor();
        const existingConversationPaths=[...document.querySelectorAll('a[href]')].map(a=>new URL(a.href,location.href)).filter(u=>u.origin===location.origin).map(u=>u.pathname);
        if (input instanceof HTMLTextAreaElement) {
            Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,text);
            input.dispatchEvent(new Event('input',{bubbles:true}));
            input.dispatchEvent(new Event('change',{bubbles:true}));
        } else {
            // Let contenteditable/ProseMirror process a browser editing operation.
            input.focus();
            // Cocoa's shared composer can clear WebKit's selection while the DOM
            // still reports this editor as focused. Restore its empty insertion point.
            const selection=window.getSelection(),range=document.createRange();
            range.selectNodeContents(input);range.collapse(false);
            selection.removeAllRanges();selection.addRange(range);
            if (!document.execCommand('insertText',false,text)) return {ok:false,reason:'The page did not accept text. Use its composer directly.'};
        }
        observation.interrupted=false;
        // innerText can collapse repeated spaces even though the editing operation
        // accepted them. Check the accepted rendering, then guard that exact draft.
        const preparedDraft=draft(input);
        if (normalized(preparedDraft)!==normalized(text)) return {ok:false,reason:'The page changed the inserted text. Review its draft.'};
        return {ok:true,preparedDraft,messageIDs:baseline.map(m=>m.id),messages:baseline,existingConversationPaths};
        """#
    }
    var sendReadiness: String { helpers + "\nreturn submissionStatus();" }
    var clickSend: String {
        if provider == .muse { return MusePageScript.clickSend }
        return helpers + #"""
        const check=submissionStatus();
        if (!check.ready) return {clicked:false,reason:check.reason};
        observation.interrupted=false;
        unique(config.send).click(); return {clicked:true};
        """#
    }

    var fixture: String {
        if provider == .muse { return MusePageScript.fixture }
        let input: String = switch provider {
        case .dots: #"<div contenteditable="true" role="textbox" aria-label="Message" data-composer-markdown></div>"#
        case .claude: #"<div class="ProseMirror" role="textbox" aria-label="Message Claude" contenteditable="true"></div>"#
        case .chatgpt: #"<textarea aria-label="Chat with ChatGPT"></textarea>"#
        case .os3: #"<textarea aria-label="message input"></textarea>"#
        default: #"<textarea aria-label="Ask Grok anything"></textarea>"#
        }
        let send = provider == .dots ? #"aria-label="Send""# : provider == .os3 ? #"aria-label="send message""# : provider == .grok ? #"data-testid="chat-submit" aria-label="Submit""# : #"aria-label="Send message""#
        let account = provider == .dots ? #"aria-label="Your dot actions""# : provider == .os3 ? #"aria-label="Settings""# : provider == .chatgpt ? #"data-testid="accounts-profile-button""# : #"data-testid="user-menu-button""#
        let login = provider == .dots ? #"aria-label="Sign in""# : ""
        let avatar = provider == .dots ? ##"<div id="fixture-dot-avatar"><button data-orbit-profile-trigger aria-label="Open Fixture’s profile"></button><span role="presentation" style="display:block;width:64px;height:64px"><svg width="64" height="64" viewBox="0 0 64 64"><rect x="4" y="4" width="56" height="56" rx="22" fill="#23b88d"/><circle cx="24" cy="27" r="4" fill="white"/><circle cx="40" cy="27" r="4" fill="white"/><path d="M22 40 Q32 48 42 40" fill="none" stroke="white" stroke-width="3"/></svg></span></div>"## : ""
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        :root{color-scheme:light dark;font:15px -apple-system,sans-serif}body{margin:0;padding:22px;background:Canvas;color:CanvasText}header{display:flex;gap:12px;align-items:center;border-bottom:1px solid #8884;padding-bottom:16px}small{color:#888}#transcript{min-height:150px;padding:20px 0}article{background:#8882;border-radius:16px;margin:12px 0;padding:14px}textarea,[contenteditable]{box-sizing:border-box;width:100%;min-height:70px;padding:12px;font:inherit;border:1px solid #8885;border-radius:14px}button{font:inherit;margin:8px 0;padding:8px 14px;border-radius:10px;border:1px solid #8885}[hidden]{display:none!important}
        </style></head><body><header><strong id="thread-title">New \(provider.name) chat</strong><small>Local fixture · no real sends</small></header>
        <main id="chat">\(avatar)<button \(account)>Fixture account</button><div id="transcript" role="log" aria-label="conversation"></div>\(input)<button id="fixture-send" \(send) disabled>Send</button><button onclick="chat.hidden=true;login.hidden=false">Sign out of fixture</button>\(provider == .dots ? "<button onclick=\"changeFixtureAvatar()\">Change fixture avatar</button>" : "")</main>
        <div id="login" hidden><p>Sign in to continue.</p><button data-testid="login-button" \(login) onclick="chat.hidden=false;login.hidden=true">Sign in to fixture</button></div>
        <script>
        const provider='\(provider.rawValue)',input=document.querySelector('textarea,[contenteditable]'),send=document.getElementById('fixture-send');
        const fixtureThreads = JSON.parse(localStorage.getItem('msgblastFixtureThreads')||'{}'),newPath='\(provider.newChatURL.path)';
        function saveFixtureThread(){if(location.pathname!==newPath){fixtureThreads[location.pathname]=document.getElementById('transcript').innerHTML;localStorage.setItem('msgblastFixtureThreads',JSON.stringify(fixtureThreads));}}
        function updateFixtureTitle(){document.getElementById('thread-title').textContent=location.pathname===newPath?'New \(provider.name) chat':'\(provider.name) chat · '+location.pathname.slice(-6);}
        function navigateFixtureThread(url){
          fixtureThreads[location.pathname]=document.getElementById('transcript').innerHTML;
          history.replaceState({},'',url);
          document.getElementById('transcript').innerHTML=location.pathname===newPath?'':(fixtureThreads[location.pathname]||'');
          updateFixtureTitle();
        }
        if(provider==='dots' && location.pathname===newPath)history.replaceState({},'', '/dots/'+crypto.randomUUID());
        document.getElementById('transcript').innerHTML=fixtureThreads[location.pathname]||'';
        updateFixtureTitle();
        function changeFixtureAvatar(){document.querySelector('#fixture-dot-avatar rect').setAttribute('fill','#8667df');}
        const value=()=>input.tagName==='TEXTAREA'?input.value:input.innerText;
        input.addEventListener('input',()=>send.disabled=!value().trim());
        send.addEventListener('click',()=>{const text=value();if(!text.trim())return;
        function add(role,text){const a=document.createElement('article');
        if(provider==='dots'){a.className='message-row'+(role==='user'?' self':'');a.dataset.messageId=crypto.randomUUID();const body=document.createElement('div');body.className='message-text';body.textContent=text;a.append(body);document.getElementById('transcript').append(a);return;}
        if(provider==='chatgpt'){a.dataset.messageAuthorRole=role;a.dataset.messageId=crypto.randomUUID();}
        if(provider==='claude'){a.dataset.testid=role==='user'?'user-message':'assistant-message';}
        if(provider==='grok'){a.dataset.messageRole=role;a.dataset.messageId=crypto.randomUUID();a.className='message-bubble';}
        if(provider==='os3'){a.dataset.renderId='msg-'+crypto.randomUUID();a.className='dial-msg '+(role==='user'?'dial-user':'dial-system');}
        a.textContent=text;document.getElementById('transcript').append(a);a.scrollIntoView({block:'nearest'});saveFixtureThread();}
        add('user',text);if(input.tagName==='TEXTAREA')input.value='';else input.textContent='';send.disabled=true;
        if(provider!=='os3'&&location.pathname===newPath){history.replaceState(null,'',(provider==='claude'?'/chat/':'/c/')+crypto.randomUUID());updateFixtureTitle();saveFixtureThread();}
        setTimeout(()=>add('assistant','\(provider.name) fixture reply: '+text),350);});
        </script></body></html>
        """
    }
}
