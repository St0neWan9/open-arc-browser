import { mkdir, readFile, writeFile, cp } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
const out = path.join(root, 'dist');
const template = await readFile(path.join(root, 'template.html'), 'utf8');
const escape = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const locales = ['en', 'zh-CN'];
let expected;
await mkdir(out, { recursive: true });
for (const locale of locales) {
  const strings = JSON.parse(await readFile(path.join(root, 'locales', `${locale}.json`), 'utf8'));
  const keys = Object.keys(strings).sort().join('\n');
  if (expected && keys !== expected) throw new Error(`Translation keys differ: ${locale}`);
  expected = keys;
  const runtimeData = JSON.stringify({locale, strings}).replace(/</g, '\\u003c');
  const html = template.replace(/\{\{([\w.]+)\}\}/g, (_, key) => {
    if (key === 'runtimeData') return runtimeData;
    if (key === 'locale') return locale;
    if (!(key in strings)) throw new Error(`Missing translation: ${locale}/${key}`);
    return escape(strings[key]);
  });
  const directory = locale === 'en' ? out : path.join(out, 'zh');
  await mkdir(directory, {recursive:true});
  await writeFile(path.join(directory, 'index.html'), html);
}
for (const file of ['style.css', 'script.js', '_headers', 'robots.txt', '404.html']) await cp(path.join(root,file), path.join(out,file));
await cp(path.join(root,'assets'), path.join(out,'assets'), {recursive:true});
console.log('Built English and Simplified Chinese pages in website/dist.');
