import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const html = fs.readFileSync(path.join(root, 'SelBrowser/Resources/Shell.html'), 'utf8');
const inline = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)]
  .filter(match => !/\bsrc\s*=/.test(match[1])).map(match => match[2]);
inline.forEach((source, index) => new vm.Script(source, {filename: `ios-shell-inline-${index}.js`}));
for (const name of ['tailwind.js', 'lucide.js']) {
  new vm.Script(fs.readFileSync(path.join(root, 'SelBrowser/Resources', name), 'utf8'), {filename: name});
}

const main = inline.find(source => source.includes('const nativeHandler'));
assert.ok(main, 'iOS bridge adapter must be present');
const start = main.indexOf('const nativeHandler');
const end = main.indexOf('function applySettings()', start);
assert.ok(end > start);
const messages = [];
const context = vm.createContext({window: {webkit: {messageHandlers: {sel: {postMessage: message => messages.push(JSON.parse(JSON.stringify(message)))}}}}});
vm.runInContext(main.slice(start, end), context);
vm.runInContext("send('closeTab','middle-stable-id');send('settings','RestoreSession',false);send('navigate','https://example.com');", context);
assert.deepEqual(messages, [
  {action: 'closeTab', value: 'middle-stable-id', extra: ''},
  {action: 'settings', value: 'RestoreSession', extra: false},
  {action: 'navigate', value: 'https://example.com', extra: ''},
]);
assert.ok(html.includes('data-close-tab') || html.includes('close.dataset.closeTab'));
assert.ok(html.includes('Память на iPhone'));
assert.ok(html.includes('window.selApplyState'));
console.log('PASS: local JavaScript syntax and actual iOS bridge message contract');
