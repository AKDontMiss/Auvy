// Extract guardPublicHost from the Worker and exercise it directly, so the guard
// is proven BEFORE a deploy rather than by probing production afterwards.
import fs from 'fs';

const src = fs.readFileSync(new URL('../worker.js', import.meta.url), 'utf8');
const start = src.indexOf('function guardPublicHost(target) {');
if (start < 0) { console.error('guardPublicHost not found'); process.exit(1); }
// Take to the first line that is exactly "}" at column 0 after the start.
const after = src.slice(start);
const end = after.indexOf('\n}\n');
if (end < 0) { console.error('could not bound the function'); process.exit(1); }
const fn = after.slice(0, end + 3);

// eslint-disable-next-line no-new-func
const guardPublicHost = new Function(fn + '\nreturn guardPublicHost;')();

const mustBlock = [
  'http://127.0.0.1/x',
  'http://127.1.2.3/x',
  'http://localhost/x',
  'http://0.0.0.0/x',
  'http://2130706433/x',        // decimal 127.0.0.1
  'http://0x7f000001/x',        // hex 127.0.0.1
  'http://[::1]/x',
  'http://[::]/x',
  'http://[::ffff:127.0.0.1]/x', // normalises to [::ffff:7f00:1]
  'http://[::ffff:7f00:1]/x',
  'http://[::ffff:10.0.0.1]/x',
  'http://10.1.2.3/x',
  'http://192.168.1.1/x',
  'http://169.254.169.254/x',   // link-local / metadata style
  'http://172.16.0.1/x',
  'http://172.31.255.255/x',
  'http://100.64.0.1/x',        // CGNAT
  'http://[fc00::1]/x',
  'http://[fd12:3456::1]/x',
  'http://[fe80::1]/x',
  'file:///etc/passwd',
  'ftp://example.com/x',
  'gopher://example.com/x',
  // Named internal endpoints. Every other rule here is an IP rule, and a
  // hostname needs no IP to name an internal service — confirmed on the live
  // Worker, where metadata.google.internal passed the guard and the fetch was
  // attempted, blocked only by Cloudflare failing to resolve it.
  'http://metadata.google.internal/computeMetadata/v1/',
  'http://metadata/computeMetadata/v1/',
  'http://instance-data/latest/meta-data/',
  'http://nas.local/feed.xml',
  'http://router.lan/feed.xml',
  'http://fileserver.intranet/feed.xml',
  'http://box.internal/feed.xml',
  'http://printer.home/feed.xml',
  'http://host.localdomain/feed.xml',
  'http://wiki.corp/feed.xml',
];

const mustAllow = [
  'https://feeds.megaphone.fm/vergecast',
  // The internal-hostname rules are suffix-anchored, AND these prove it.
  // A feed host is allowed to CONTAIN these words; only the final label counts.
  'https://internal.example.com/rss',
  'https://local.feeds.fm/rss',
  'https://mycorp.com/rss',
  'https://lan-party-podcast.com/rss',
  'https://metadata-podcast.com/rss',
  'http://feeds.example.com/rss',
  'https://anchor.fm/s/abc/podcast/rss',
  'https://172.32.0.1/x',       // just outside RFC1918
  'https://100.128.0.1/x',      // just outside CGNAT
  'https://11.0.0.1/x',         // not 10.x
];

let fail = 0;
for (const u of mustBlock) {
  let allowed;
  try { allowed = guardPublicHost(new URL(u)); } catch { allowed = false; }
  if (allowed) { console.log('SHOULD BLOCK but allowed: ' + u); fail++; }
}
for (const u of mustAllow) {
  let allowed;
  try { allowed = guardPublicHost(new URL(u)); } catch { allowed = 'parse-error'; }
  if (allowed !== true) { console.log('SHOULD ALLOW but got ' + allowed + ': ' + u); fail++; }
}
console.log(fail === 0
  ? '  all ' + (mustBlock.length + mustAllow.length) + ' cases correct'
  : '  ' + fail + ' FAILURE(S)');
process.exit(fail === 0 ? 0 : 1);
