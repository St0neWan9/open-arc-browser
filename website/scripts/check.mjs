import {readFile,access} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const root=fileURLToPath(new URL('../',import.meta.url));
const en=JSON.parse(await readFile(path.join(root,'locales/en.json'),'utf8'));
const zh=JSON.parse(await readFile(path.join(root,'locales/zh-CN.json'),'utf8'));
assert.deepEqual(Object.keys(en).sort(),Object.keys(zh).sort(),'Locale key parity');
for(const [route,locale] of [['','en'],['zh','zh-CN']]){
 const html=await readFile(path.join(root,'dist',route,'index.html'),'utf8');
 assert(html.includes(`lang="${locale}"`));assert(!html.includes('{{'));
 const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]);assert.equal(ids.length,new Set(ids).size,'Unique element IDs');
 for(const match of html.matchAll(/href="#([^"]+)"/g))assert(ids.includes(match[1]),`Missing anchor ${match[1]}`);
 for(const match of html.matchAll(/(?:src|href)="(\/(?:assets\/[^"?]+|style\.css|script\.js))"/g))await access(path.join(root,'dist',match[1]));
 const data=JSON.parse(html.match(/<script id="locale-data" type="application\/json">(.*?)<\/script>/s)[1]);
 for(const space of ['work','life','ideas'])for(const suffix of ['name','folder','pinned','selected','kicker','title.first','title.last','description.first','description.last'])assert(data.strings[`demo.${space}.${suffix}`],`Missing demo string: ${locale}/${space}/${suffix}`);
 assert(!html.includes('releases/latest'),'No unavailable release links');
 assert(!html.includes('brand-dot'),'No unsupported trademark symbol');
}
console.log('PASS: locale parity, dynamic strings, anchors, unique IDs, assets, and release links.');
