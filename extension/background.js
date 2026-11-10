importScripts('strings.js', 'i18n.js', 'page-capture.js');
const HOST = 'local.checker.capture';
const JOB_PREFIX = 'checker:page:';
const POLL_ALARM = 'checker:analysis';
const isPending = value => ['preparing', 'analyzing', 'queued'].includes(value?.status);

function native(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST, message, response => {
      const error = chrome.runtime.lastError;
      if (response?.language && setCheckerLanguage(response.language)) updateContextMenu();
      if (error) reject(new Error(tr('로컬 연결을 찾지 못했어요. Checker 연결 설치를 확인해 주세요.')));
      else if (!response || (response.status === 'error' && !response.jobID)) reject(new Error(response?.message || tr('요청을 처리하지 못했어요.')));
      else resolve(response);
    });
  });
}

async function badge(result) {
  await chrome.action.setBadgeBackgroundColor({color: result.status === 'error' ? '#a3503c' : '#537148'});
  await chrome.action.setBadgeText({text: result.status === 'added' ? '✓' : result.status === 'error' ? '!' : '…'});
  await chrome.action.setTitle({title: result.status === 'added' ? tr('AI가 정리해 Checker에 추가했어요') : result.status === 'error' ? tr(result.message) : tr('AI가 현재 화면을 정리하고 있어요')});
}

async function currentJob(tabId, sourceURL) {
  const key = JOB_PREFIX + tabId;
  let entry = (await chrome.storage.local.get(key))[key];
  if (!entry || entry.sourceURL !== sourceURL) return {status: 'idle'};
  if (isPending(entry) && entry.status !== 'preparing') {
    const result = await native({action: 'analysis_status', jobID: entry.jobID});
    entry = {...entry, ...result};
    await chrome.storage.local.set({[key]: entry});
    await badge(entry);
  }
  if (entry.status === 'preparing' && Date.now() - entry.startedAt > 15000) {
    entry = {...entry, status: 'error', message: tr('화면을 읽는 중 연결이 끊겼어요. 다시 시도해 주세요.')};
    await chrome.storage.local.set({[key]: entry});
  }
  return entry;
}

async function analyzeTab(tabId, selectedText = '') {
  await native({action: 'preferences'});
  const tab = await chrome.tabs.get(tabId);
  if (!tab?.active || !/^https?:\/\//.test(tab.url || '')) throw new Error(tr('분석할 웹페이지에서 추가해 주세요.'));
  const previous = await currentJob(tabId, tab.url);
  if (isPending(previous)) return previous;
  const key = JOB_PREFIX + tabId;
  const requestID = crypto.randomUUID();
  const preparing = {status: 'preparing', jobID: requestID, sourceURL: tab.url, startedAt: Date.now()};
  await chrome.storage.local.set({[key]: preparing});
  await badge(preparing);
  try {
    let page = {sourceURL: tab.url, title: tab.title || '', text: '', visibleText: '', selectionText: selectedText};
    try {
      const captured = await chrome.scripting.executeScript({target: {tabId}, func: collectCheckerPage});
      if (captured[0]?.result) page = captured[0].result;
    } catch { /* A visible PDF or protected renderer may still be captured as an image. */ }
    if (selectedText) page.selectionText = selectedText.slice(0, 6000);
    const beforeImage = await chrome.tabs.get(tabId);
    if (!beforeImage.active || beforeImage.url !== tab.url || page.sourceURL !== tab.url) throw new Error(tr('페이지가 바뀌었어요. 원하는 화면에서 다시 눌러 주세요.'));
    let screenshot;
    try {
      screenshot = await chrome.tabs.captureVisibleTab(tab.windowId, {format: 'jpeg', quality: 60});
      if (screenshot.length > 5600000) throw new Error(tr('현재 화면 이미지가 너무 커요. 창 크기를 줄이고 다시 눌러 주세요.'));
    } catch (error) {
      if (!page.text && !page.visibleText && !page.selectionText) throw new Error(tr('현재 화면을 읽지 못했어요. 페이지가 열린 뒤 다시 눌러 주세요.'));
      screenshot = undefined;
    }
    const active = await chrome.tabs.query({active: true, windowId: tab.windowId});
    if (active[0]?.id !== tabId || active[0]?.url !== tab.url) throw new Error(tr('페이지가 바뀌었어요. 원하는 화면에서 다시 눌러 주세요.'));
    const result = await native({action: 'start_analysis', requestID, page, screenshot});
    const entry = {...preparing, ...result};
    await chrome.storage.local.set({[key]: entry});
    await badge(entry);
    await chrome.alarms.create(POLL_ALARM, {delayInMinutes: 0.5, periodInMinutes: 0.5});
    return entry;
  } catch (error) {
    // A lost reply must not turn an accepted job into a duplicate on retry.
    try {
      const accepted = await native({action: 'analysis_status', jobID: requestID});
      const entry = {...preparing, ...accepted};
      await chrome.storage.local.set({[key]: entry});
      return entry;
    } catch { /* No accepted job exists. A new click can safely retry. */ }
    const result = {...preparing, status: 'error', message: error.message};
    await chrome.storage.local.set({[key]: result});
    await badge(result);
    return result;
  }
}

async function pollJobs() {
  const values = await chrome.storage.local.get(null);
  let pending = false;
  for (const [key, entry] of Object.entries(values)) {
    if (!key.startsWith(JOB_PREFIX) || !isPending(entry)) continue;
    try {
      const result = await currentJob(Number(key.slice(JOB_PREFIX.length)), entry.sourceURL);
      if (isPending(result)) pending = true;
    } catch { pending = true; }
  }
  if (!pending) await chrome.alarms.clear(POLL_ALARM);
}

function updateContextMenu() {
  chrome.contextMenus.update('checker-add', {title: tr('이 화면을 AI로 정리해 Checker에 추가')}, () => { void chrome.runtime.lastError; });
}
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => chrome.contextMenus.create({id: 'checker-add', title: tr('이 화면을 AI로 정리해 Checker에 추가'), contexts: ['page', 'selection']}));
  native({action: 'preferences'}).then(updateContextMenu).catch(() => {});
});
chrome.runtime.onStartup.addListener(() => {
  native({action: 'preferences'}).then(updateContextMenu).catch(() => {});
  pollJobs().catch(() => {});
});
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === POLL_ALARM) pollJobs().catch(() => {}); });
chrome.tabs.onRemoved.addListener(tabId => chrome.storage.local.remove(JOB_PREFIX + tabId));
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === 'checker-add' && tab?.id) analyzeTab(tab.id, info.selectionText || '').catch(error => badge({status: 'error', message: error.message}));
});
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id) return;
  const operation = message.type === 'set_language' ? native({action: 'set_language', language: message.language}) :
    message.type === 'analysis_info' ? native({action: 'analysis_info'}) :
    message.type === 'analyze_tab' ? analyzeTab(message.tabId) :
    message.type === 'analysis_status' ? currentJob(message.tabId, message.sourceURL) : Promise.reject(new Error(tr('알 수 없는 요청입니다.')));
  operation.then(value => respond({...value, language: checkerLanguage})).catch(error => respond({status: 'error', message: tr(error.message), language: checkerLanguage}));
  return true;
});
