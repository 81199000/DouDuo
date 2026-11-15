import SwiftUI
import WebKit

/// Updates the existing document in place: changing appearance must not reload
/// a conversation, discard its draft, or restart media.
enum DDWebAppearance {
    static func isChatURL(_ url: URL) -> Bool { url.path == "/chat" || url.path == "/chat/" }

    static func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    static func apply(to web: WKWebView, scheme: ColorScheme, chat: Bool = false) {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let changed = web.overrideUserInterfaceStyle != style
        web.overrideUserInterfaceStyle = style
        let backgroundName = chat ? "MessageChatBackground" : "AppBackground"
        let background = chat || scheme == .light
            ? UIColor(named: backgroundName)?.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            : nil
        web.isOpaque = false
        web.backgroundColor = background ?? .clear
        web.scrollView.backgroundColor = background ?? .clear
        web.underPageBackgroundColor = background
        if changed { synchronize(web) }
    }

    static func synchronize(_ web: WKWebView) {
        let mode = web.overrideUserInterfaceStyle == .dark ? "dark" : "light"
        web.evaluateJavaScript("window.__ddSetAppearance && window.__ddSetAppearance('\(mode)');")
    }

    static let bootstrap = #"""
    (() => {
      if (!/(^|\.)douyin\.com$/i.test(location.hostname)) return;
      if (window.__ddSetAppearance) return;
      const media = matchMedia('(prefers-color-scheme: dark)');
      let mode = media.matches ? 'dark' : 'light';
      const css = `
        :root[data-dd-appearance="light"] {
          color-scheme: light;
          --dd-page-bg:#fcfcfc; --dd-page-panel:#f2f2f7; --dd-page-text:#161616;
          --dd-page-secondary:#60636b; --dd-page-separator:rgba(0,0,0,.12);
        }
        :root[data-dd-appearance="light"], :root[data-dd-appearance="light"] #dark,
        :root[data-dd-appearance="light"] #light {
          --color-bg-base-b0:var(--dd-page-bg)!important;
          --color-bg-base-b1:var(--dd-page-panel)!important;
          --color-page-bg:var(--dd-page-bg)!important;
          --color-navigation-bg:var(--dd-page-bg)!important;
          --color-bg-nav:var(--dd-page-bg)!important;
          --color-bg-side:var(--dd-page-bg)!important;
          --color-bg-0:var(--dd-page-bg)!important;
          --color-bg-1:var(--dd-page-panel)!important;
          --color-bg-2:var(--dd-page-panel)!important;
          --color-bg-b1-white:var(--dd-page-panel)!important;
          --color-bg-b2-white:var(--dd-page-panel)!important;
          --color-text-t0:var(--dd-page-text)!important;
          --color-text-0:var(--dd-page-text)!important;
          --color-text-1:var(--dd-page-secondary)!important;
          --color-text-2:var(--dd-page-secondary)!important;
          --im-color-BGSecondary3:var(--dd-page-bg)!important;
          --color-bg-b0:var(--dd-page-bg)!important;
          --color-bg-b1:var(--dd-page-panel)!important;
          --color-bg-b2:var(--dd-page-panel)!important;
          --color-bg-b3:var(--dd-page-panel)!important;
          --color-text-t1:var(--dd-page-text)!important;
          --color-text-t2:var(--dd-page-secondary)!important;
          --color-text-t3:var(--dd-page-secondary)!important;
          --color-line-l1:var(--dd-page-separator)!important;
          --semi-color-bg-0:var(--dd-page-bg)!important;
          --semi-color-bg-1:var(--dd-page-panel)!important;
          --semi-color-text-0:var(--dd-page-text)!important;
          --semi-color-text-1:var(--dd-page-secondary)!important;
        }
        html[data-dd-appearance="light"], html[data-dd-appearance="light"] body,
        html[data-dd-appearance="light"] #root {
          background-color:var(--dd-page-bg)!important;
          color:var(--dd-page-text)!important;
        }
        html[data-dd-appearance="light"] [contenteditable="true"],
        html[data-dd-appearance="light"] textarea {
          color:var(--dd-page-text)!important; caret-color:var(--dd-page-text)!important;
        }
      `;
      const isChat = () => /^\/chat\/?$/.test(location.pathname);
      // The host theme event updates the page shell. The standalone IM
      // exposes a separate API for the theme used by the mounted conversation.
      let sdkThemePending = false;
      const syncChatSDK = runtime => {
        if (!isChat() || !runtime?.m?.[230095] || sdkThemePending) return;
        const contextReady = runtime(230095).a5;
        if (typeof contextReady !== 'function') return;
        const pending = contextReady();
        if (!pending?.then) return;
        sdkThemePending = true;
        Promise.resolve(pending).then(context => {
          // A parked WebView may finish loading after the latest theme change.
          // Read mode now, when the remote IM context is actually available.
          if (isChat() && typeof context?.saasApi?.changeTheme === 'function')
            context.saasApi.changeTheme(mode === 'dark');
        }).catch(() => {}).finally(() => { sdkThemePending = false; });
      };
      let themeRetry, themeChunk = 0;
      const syncOfficialTheme = (attempt = 0) => {
        clearTimeout(themeRetry);
        try { document.cookie = `theme=${mode}; path=/; domain=.douyin.com; SameSite=Lax`; } catch (_) {}
        let runtime;
        const chunks = window.webpackChunkdouyin_web;
        if (chunks?.push) {
          const id = 'dd-appearance-' + Date.now() + '-' + (++themeChunk);
          chunks.push([[id], {}, require => { runtime = require; }]);
          // The synthetic chunk contains no modules or application code.
          if (chunks[chunks.length - 1]?.[0]?.[0] === id) chunks.pop();
        }
        if (runtime?.m?.[708926]) {
          try {
            const events = runtime(708926);
            if (typeof events.emit === 'function' && events.EVENT?.changeTheme === 'changeTheme') {
              events.emit(events.EVENT.changeTheme, {theme: mode});
            }
          } catch (_) { /* The cookie and document theme still apply. */ }
        }
        try { syncChatSDK(runtime); } catch (_) { /* The host theme remains available. */ }
        // React and the IM SDK mount asynchronously; initialize late listeners too.
        if (attempt < 5) themeRetry = setTimeout(() => syncOfficialTheme(attempt + 1), [250, 1000, 3000, 5000, 10000][attempt]);
      };
      let bodyObserved, appObserved;
      // Some light pages keep a #dark shell set by the server. Limit the
      // inheritance workaround to light mode so the site's dark palette wins.
      const lightShellPalette = root => {
        const palette = getComputedStyle(root);
        const properties = [...palette]
          .filter(key => /^--(?:color-|im-color-)/.test(key) && palette.getPropertyValue(key).trim());
        return properties.length
          ? `:where(html[data-dd-appearance="light"]) :is(#dark,#light) {
               ${properties.map(key => key + ':inherit!important;').join('')}
             }`
          : '';
      };
      const mountObserver = new MutationObserver(records => {
        const shells = '#dark,#light,.chatDark,.chatLight,[class*="componentsEntrywrapper"]';
        if (records.some(record => [...record.addedNodes].some(node => node.nodeType === 1 &&
            (node.matches(shells) || node.querySelector(shells))))) {
          apply();
          syncOfficialTheme();
        }
      });
      const set = (node, key, value) => {
        if (node.getAttribute(key) !== value) node.setAttribute(key, value);
      };
      const apply = () => {
        const root = document.documentElement;
        if (!root) return;
        for (const shell of document.querySelectorAll('.chatLight,.chatDark')) {
          // The route shell can retain its initial server theme until React updates.
          shell.classList.toggle('chatLight', mode === 'light');
          shell.classList.toggle('chatDark', mode === 'dark');
          observer.observe(shell, {attributes:true, attributeFilter:['class']});
        }
        set(root, 'data-dd-appearance', mode);
        set(root, 'data-theme', mode);
        if (root.hasAttribute('dark') !== (mode === 'dark')) root.toggleAttribute('dark', mode === 'dark');
        if (root.style.colorScheme !== mode) root.style.colorScheme = mode;
        if (document.body) {
          set(document.body, 'data-theme', mode);
          if (bodyObserved !== document.body) {
            bodyObserved = document.body;
            observer.observe(bodyObserved, {attributes:true, childList:true, attributeFilter:['data-theme']});
          }
        }
        const app = document.getElementById('root');
        if (app && appObserved !== app) {
          appObserved = app; mountObserver.observe(app, {childList:true, subtree:true});
        }
        let sheet = document.getElementById('dd-appearance');
        if (mode === 'dark' || isChat()) {
          sheet?.remove();
        } else {
          if (!sheet) {
            sheet = document.createElement('style');
            sheet.id = 'dd-appearance';
            (document.head || root).appendChild(sheet);
          }
          const lightCSS = css + lightShellPalette(root);
          if (sheet.textContent !== lightCSS) sheet.textContent = lightCSS;
        }
      };
      const observer = new MutationObserver(apply);
      window.__ddSetAppearance = value => {
        mode = value === 'dark' ? 'dark' : 'light'; apply(); syncOfficialTheme();
      };
      media.addEventListener('change', event => window.__ddSetAppearance(event.matches ? 'dark' : 'light'));
      if (document.documentElement) {
        observer.observe(document.documentElement, {attributes:true, childList:true, attributeFilter:['data-theme','style','dark']});
      }
      document.addEventListener('DOMContentLoaded', apply, {once:true});
      apply();
      syncOfficialTheme();
    })();
    """#
}
