// Executes the hidden SDK page's real injected script, not a copied implementation.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync('DouDuo/DouyinFeedView.swift', 'utf8');
const script = source.split('private static let noMediaJS = """')[1].split('"""')[0];
(async () => {
  for (const initialRoot of [null, {}]) {
    let nativeFullscreen = 0, observed = 0;
    class Element {
      constructor() { this.attrs = {autoplay: ''}; }
      removeAttribute(k) { delete this.attrs[k]; }
      setAttribute(k, v) { this.attrs[k] = v; }
      requestFullscreen() { nativeFullscreen++; }
    }
    class HTMLMediaElement extends Element {
      pause() { this.paused = true; }
      play() { this.paused = false; }
    }
    class HTMLVideoElement extends HTMLMediaElement {
      webkitEnterFullscreen() { nativeFullscreen++; }
      webkitEnterFullScreen() { nativeFullscreen++; }
    }
    const video = new HTMLVideoElement(), handlers = {};
    const document = {
      documentElement: initialRoot,
      querySelectorAll: () => [video],
      addEventListener: (name, fn) => { handlers[name] = fn; },
    };
    class MutationObserver {
      observe(root) { assert.ok(root); observed++; }
    }
    vm.runInNewContext(script, {Element, HTMLMediaElement, HTMLVideoElement, MutationObserver, document, Promise});
    if (!initialRoot) assert.equal(observed, 0);
    document.documentElement = {};
    handlers.DOMContentLoaded();
    assert.ok(observed > 0);
    assert.equal(video.playsInline, true);
    assert.equal(video.attrs.autoplay, undefined);
    await video.play();
    assert.equal(video.paused, true);
    assert.equal(video.muted, true);
    video.webkitEnterFullscreen(); video.webkitEnterFullScreen();
    await video.requestFullscreen();
    assert.equal(nativeFullscreen, 0);
  }
  console.log('PASS hidden SDK media guard: early DOM, inline media, playback and fullscreen suppression');
})().catch(error => { console.error(error); process.exitCode = 1; });
