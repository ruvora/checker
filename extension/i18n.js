let checkerLanguage = (chrome.i18n?.getUILanguage?.() || 'en').toLowerCase().startsWith('ko') ? 'ko' : 'en';
const CHECKER_REVERSE_STRINGS = Object.fromEntries(Object.entries(CHECKER_STRINGS).map(([ko, en]) => [en, ko]));
function setCheckerLanguage(language) {
  if (!['en', 'ko'].includes(language)) return false;
  const changed = language !== checkerLanguage;
  checkerLanguage = language;
  return changed;
}
function tr(message) {
  const key = Object.hasOwn(CHECKER_STRINGS, message) ? message : CHECKER_REVERSE_STRINGS[message] || message;
  return checkerLanguage === 'en' ? CHECKER_STRINGS[key] || message : key;
}
