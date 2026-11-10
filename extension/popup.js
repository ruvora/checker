let currentTab;
let polling;
let lastState = {status: 'connecting'};
let connectionReady = false;
const result = document.getElementById('result');
const saveButton = document.getElementById('save');
const buttonLabel = document.getElementById('button-label');
const spinner = document.getElementById('spinner');
const preview = document.getElementById('preview');
const languagePicker = document.getElementById('language');
function renderLanguage(language = checkerLanguage) {
  setCheckerLanguage(language);
  document.documentElement.lang = checkerLanguage;
  document.title = tr('Checker에 추가');
  languagePicker.value = checkerLanguage;
  document.querySelectorAll('[data-i18n]').forEach(element => { element.textContent = tr(element.dataset.i18n); });
}
function showStatus(state) {
  if (state.language && state.language !== checkerLanguage) renderLanguage(state.language);
  lastState = state;
  const pending = ['preparing', 'analyzing'].includes(state.status);
  spinner.hidden = !pending;
  saveButton.disabled = pending || ['added', 'queued'].includes(state.status);
  result.className = state.status === 'error' ? 'error' : '';
  if (state.status === 'preparing') { buttonLabel.textContent = tr('화면 읽는 중'); result.textContent = tr('지금 보이는 화면을 읽고 있어요.'); }
  else if (state.status === 'analyzing') { buttonLabel.textContent = tr('AI가 정리하는 중'); result.textContent = tr('팝업을 닫아도 끝나면 Checker에 추가돼요.'); }
  else if (state.status === 'added' || state.status === 'queued') {
    buttonLabel.textContent = state.status === 'added' ? tr('추가했어요') : tr('로컬에 저장했어요');
    result.textContent = state.status === 'added' ? tr('원래 페이지 링크와 함께 저장했어요.') : tr('Checker가 열리면 목록에 반영됩니다.');
    if (state.title) {
      preview.hidden = false;
      document.getElementById('result-title').textContent = state.title;
      const defaultCategory = ['development', 'review', 'documents', 'uncategorized'].includes(state.categoryID);
      document.getElementById('result-category').textContent = state.categoryName ? (defaultCategory ? tr(state.categoryName) : state.categoryName) : tr('미분류');
      document.getElementById('result-note').textContent = state.note || '';
    }
  } else if (state.status === 'error') { buttonLabel.textContent = tr('다시 시도'); result.textContent = tr(state.message || '요청을 처리하지 못했어요.'); }
  else if (state.status === 'connecting') { buttonLabel.textContent = tr('연결 확인 중'); result.textContent = ''; saveButton.disabled = true; }
  else { buttonLabel.textContent = tr('추가하기'); result.textContent = ''; }
  if (!connectionReady && !pending) saveButton.disabled = true;
  if (pending || state.status === 'queued') schedulePoll();
}
languagePicker.addEventListener('change', async () => {
  languagePicker.disabled = true;
  const response = await chrome.runtime.sendMessage({type: 'set_language', language: languagePicker.value}).catch(() => ({status: 'error', message: tr('연결을 확인한 뒤 다시 시도해 주세요.')}));
  if (response.status === 'error') {
    languagePicker.value = checkerLanguage;
    showStatus({...response, language: checkerLanguage});
  } else {
    renderLanguage(response.language);
    showStatus({...lastState, language: response.language});
    if (currentTab) {
      try { showStatus(await chrome.runtime.sendMessage({type: 'analysis_status', tabId: currentTab.id, sourceURL: currentTab.url})); } catch { /* Existing result remains visible. */ }
    }
  }
  languagePicker.disabled = false;
});
function schedulePoll() {
  clearTimeout(polling);
  polling = setTimeout(async () => {
    try {
      showStatus(await chrome.runtime.sendMessage({type: 'analysis_status', tabId: currentTab.id, sourceURL: currentTab.url}));
    } catch {
      result.className = 'error'; result.textContent = tr('연결 확인이 늦어지고 있어요. 잠시 후 다시 열어 주세요.');
    }
  }, 1200);
}
saveButton.addEventListener('click', async () => {
  preview.hidden = true;
  showStatus({status: 'preparing'});
  try { showStatus(await chrome.runtime.sendMessage({type: 'analyze_tab', tabId: currentTab.id})); }
  catch (error) { showStatus({status: 'error', message: error.message || tr('연결을 확인한 뒤 다시 시도해 주세요.')}); }
});
async function initialize() {
  [currentTab] = await chrome.tabs.query({active: true, currentWindow: true});
  const connection = await chrome.runtime.sendMessage({type: 'analysis_info'});
  renderLanguage(connection.language || checkerLanguage);
  if (connection.status === 'error') throw new Error(connection.message);
  if (!/^https?:\/\//.test(currentTab?.url || '')) throw new Error(tr('분석할 웹페이지에서 Checker를 열어 주세요.'));
  document.getElementById('page').textContent = currentTab.title || new URL(currentTab.url).hostname;
  connectionReady = true;
  showStatus(await chrome.runtime.sendMessage({type: 'analysis_status', tabId: currentTab.id, sourceURL: currentTab.url}));
}
renderLanguage();
showStatus(lastState);
initialize().catch(error => { showStatus({status: 'error', message: tr(error.message)}); saveButton.disabled = true; });
