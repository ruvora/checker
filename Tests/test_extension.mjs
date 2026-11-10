import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
function backgroundHarness({changedTab = false, failAI = false} = {}) {
  const stored = {};
  const requests = [];
  const accepted = new Set();
  let language = 'ko';
  let messageListener;
  const tab = {id: 17, windowId: 4, active: true, url: 'https://example.com/pull/128', title: 'Review requested'};
  const chrome = {
    i18n: {getUILanguage() { return 'ko'; }},
    runtime: {id: 'checker-test', lastError: null,
      sendNativeMessage(host, request, callback) {
        requests.push(request);
        const reply = value => callback({...value, language});
        if (request.action === 'set_language') language = request.language;
        if (request.action === 'start_analysis') { accepted.add(request.requestID); reply({status: 'analyzing', jobID: request.requestID, sourceURL: tab.url}); }
        else if (request.action === 'analysis_status') reply(!accepted.has(request.jobID) ? {status: 'error', message: 'Job not found'} : failAI ? {status: 'error', jobID: request.jobID, message: 'AI failed'} : {status: 'added', jobID: request.jobID, title: '로그인 변경 검토', categoryName: language === 'ko' ? '리뷰' : 'Review'});
        else reply({status: 'ok', provider: 'Codex'});
      },
      onMessage: {addListener(fn) { messageListener = fn; }}, onInstalled: {addListener() {}}, onStartup: {addListener() {}}
    },
    storage: {local: {
      async get(key) { return key === null ? {...stored} : {[key]: stored[key]}; },
      async set(value) { Object.assign(stored, value); }, async remove(key) { delete stored[key]; }
    }},
    tabs: {async get() { return {...tab}; }, async query() { return [{...tab, id: changedTab ? 99 : tab.id}]; },
      async captureVisibleTab() { return 'data:image/jpeg;base64,/9j/AA=='; }, onRemoved: {addListener() {}}},
    scripting: {async executeScript() { return [{result: {sourceURL: tab.url, title: tab.title, text: 'A login regression needs review.', visibleText: 'Check retry behavior.'}}]; }},
    action: {async setBadgeBackgroundColor() {}, async setBadgeText() {}, async setTitle() {}},
    alarms: {async create() {}, async clear() {}, onAlarm: {addListener() {}}},
    contextMenus: {removeAll(callback) { callback(); }, create() {}, update(id, options, callback) { callback?.(); }, onClicked: {addListener() {}}}
  };
  const context = vm.createContext({chrome, crypto: {randomUUID: () => '11111111-1111-4111-8111-111111111111'}, URL, console,
    importScripts(...files) { for (const file of files) vm.runInContext(fs.readFileSync(path.join(root, 'extension', file), 'utf8'), context); }});
  vm.runInContext(fs.readFileSync(path.join(root, 'extension/background.js'), 'utf8'), context);
  return {stored, requests, send(message) { return new Promise(resolve => messageListener(message, {id: chrome.runtime.id}, resolve)); }};
}
{
  const app = backgroundHarness();
  assert.equal((await app.send({type: 'set_language', language: 'en'})).language, 'en');
  assert.equal((await app.send({type: 'analysis_info'})).language, 'en');
  assert.equal(app.requests.some(value => value.action === 'set_language' && value.language === 'en'), true);
  assert.equal(app.requests.some(value => value.action === 'start_analysis'), false);
  console.log('PASS changing language updates the shared native setting without starting an analysis');
}

{
  const nodes = new Map();
  function element(id) {
    if (!nodes.has(id)) nodes.set(id, {hidden: false, disabled: false, value: '', textContent: '', className: '', listeners: {},
      addEventListener(event, listener) { this.listeners[event] = listener; }});
    return nodes.get(id);
  }
  let language = 'ko';
  const document = {documentElement: {}, title: '', getElementById: element, querySelectorAll: () => []};
  const chrome = {i18n: {getUILanguage: () => 'ko'}, tabs: {query: async () => [{id: 17, url: 'https://example.com/pr', title: 'Test page'}]},
    runtime: {async sendMessage(request) {
      if (request.type === 'set_language') language = request.language;
      return {status: request.type === 'analysis_status' ? 'idle' : 'ok', language};
    }}};
  const context = vm.createContext({chrome, document, URL, setTimeout() {}, clearTimeout() {}});
  for (const file of ['strings.js', 'i18n.js', 'popup.js']) vm.runInContext(fs.readFileSync(path.join(root, 'extension', file), 'utf8'), context);
  await vm.runInContext('initialize()', context);
  assert.equal(element('button-label').textContent, '추가하기');
  element('language').value = 'en';
  await element('language').listeners.change();
  assert.equal(document.documentElement.lang, 'en');
  assert.equal(element('button-label').textContent, 'Add to Checker');
  assert.equal(element('save').disabled, false);
  vm.runInContext("showStatus({status: 'added', title: '기존 사용자 제목', note: '기존 메모', categoryID: 'review', categoryName: '리뷰'})", context);
  assert.equal(element('result-title').textContent, '기존 사용자 제목');
  assert.equal(element('result-note').textContent, '기존 메모');
  assert.equal(element('result-category').textContent, 'Review');
  vm.runInContext("showStatus({status: 'added', title: '기존 사용자 제목', categoryID: 'custom-review', categoryName: '리뷰'})", context);
  assert.equal(element('result-category').textContent, '리뷰');
  console.log('PASS popup switches to English immediately and preserves existing task text');
}

{
  const app = backgroundHarness();
  const started = await app.send({type: 'analyze_tab', tabId: 17});
  assert.equal(started.status, 'analyzing');
  const capture = app.requests.find(value => value.action === 'start_analysis');
  assert.equal(capture.page.sourceURL, 'https://example.com/pull/128');
  assert.equal(capture.page.visibleText, 'Check retry behavior.');
  assert.ok(capture.screenshot.startsWith('data:image/jpeg;'));
  assert.equal(app.requests.some(value => value.action === 'capture'), false);
  const saved = await app.send({type: 'analysis_status', tabId: 17, sourceURL: capture.page.sourceURL});
  assert.equal(saved.status, 'added');
  assert.equal(saved.title, '로그인 변경 검토');
  console.log('PASS one click forwards real page content and screenshot to AI, then reports saved result');
}
{
  const app = backgroundHarness({changedTab: true});
  const result = await app.send({type: 'analyze_tab', tabId: 17});
  assert.equal(result.status, 'error');
  assert.equal(app.requests.some(value => value.action === 'start_analysis'), false);
  console.log('PASS switching tabs during capture cannot analyze the wrong screen');
}
{
  const app = backgroundHarness({failAI: true});
  await app.send({type: 'analyze_tab', tabId: 17});
  const result = await app.send({type: 'analysis_status', tabId: 17, sourceURL: 'https://example.com/pull/128'});
  assert.equal(result.status, 'error');
  assert.equal(app.requests.some(value => value.action === 'capture'), false);
  console.log('PASS failed AI analysis never falls back to a raw bookmark');
}
