const { locale, strings } = JSON.parse(document.querySelector('#locale-data').textContent);
const t = key => strings[key];
const languageLink = document.querySelector('.language-switch');
try {
  const preferred = localStorage.getItem('openarc.locale');
  if (locale === 'en' && preferred === 'zh-CN') location.replace('/zh/' + location.hash);
} catch { /* Browsing remains available when storage is disabled. */ }
languageLink.addEventListener('click', () => {
  try { localStorage.setItem('openarc.locale', locale === 'en' ? 'zh-CN' : 'en'); } catch { /* The locale URL still works without storage. */ }
  languageLink.hash = location.hash;
});
const demo = document.querySelector('#browser-demo');
const symbols = { work: '▦', life: '☀' };
const ideasSymbol = document.querySelector('button[data-space="ideas"] svg');
function setLines(element, first, last) {
  element.replaceChildren(document.createTextNode(first), document.createElement('br'), document.createTextNode(last));
}
document.querySelectorAll('button[data-space]').forEach(button => {
  button.addEventListener('click', () => {
    const key = button.dataset.space;
    demo.dataset.space = key;
    document.querySelectorAll('button[data-space]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.getElementById('space-symbol').replaceChildren(key === 'ideas' ? ideasSymbol.cloneNode(true) : document.createTextNode(symbols[key]));
    for (const [id, suffix] of Object.entries({ 'space-name':'name', 'folder-name':'folder', 'pinned-name':'pinned', 'selected-name':'selected', 'editor-kicker':'kicker' })) {
      document.getElementById(id).textContent = t(`demo.${key}.${suffix}`);
    }
    setLines(document.getElementById('editor-title'), t(`demo.${key}.title.first`), t(`demo.${key}.title.last`));
    setLines(document.getElementById('editor-description'), t(`demo.${key}.description.first`), t(`demo.${key}.description.last`));
  });
});
const splitDemo = document.querySelector('#split-demo');
document.querySelectorAll('button[data-theme]').forEach(button => button.addEventListener('click', () => {
  splitDemo.dataset.theme = button.dataset.theme;
  document.querySelectorAll('button[data-theme]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
}));
document.querySelector('#split-toggle').addEventListener('click', event => {
  const single = splitDemo.classList.toggle('single');
  event.currentTarget.setAttribute('aria-pressed', String(!single));
  event.currentTarget.querySelector('span').textContent = t(single ? 'setup.splitOff' : 'setup.splitOn');
});
const dialog = document.querySelector('#migration-dialog');
const dialogTrigger = document.querySelector('#migration-open');
dialogTrigger.addEventListener('click', () => { dialog.showModal(); document.body.classList.add('dialog-open'); });
document.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => { document.body.classList.remove('dialog-open'); dialogTrigger.focus({preventScroll:true}); });
dialog.addEventListener('click', event => {
  const bounds = dialog.getBoundingClientRect();
  if (event.target === dialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) dialog.close();
});
const menu = document.querySelector('.menu-button');
const navigation = document.querySelector('#navigation');
function closeMenu() { menu.setAttribute('aria-expanded', 'false'); menu.setAttribute('aria-label', t('nav.open')); navigation.classList.remove('is-open'); }
menu.addEventListener('click', () => {
  const open = menu.getAttribute('aria-expanded') !== 'true';
  menu.setAttribute('aria-expanded', String(open)); menu.setAttribute('aria-label', t(open ? 'nav.close' : 'nav.open')); navigation.classList.toggle('is-open', open);
});
navigation.querySelectorAll('a').forEach(link => link.addEventListener('click', closeMenu));
document.addEventListener('keydown', event => { if (event.key === 'Escape' && menu.getAttribute('aria-expanded') === 'true') { closeMenu(); menu.focus(); } });
