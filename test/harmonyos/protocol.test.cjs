const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const tls = require('node:tls');
const { once } = require('node:events');
const { ByteQueue, protocol, codec, crypto, host, source, filesAt, hashFile, sha256, waitFor, identity } =
  require('./host.cjs');

const { SessionState, FileState, validateManifest, safeName, numberedName, onSubnet, CHUNK_SIZE } = protocol;

async function folders(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'neartransfer-protocol-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return [path.join(root, 'a'), path.join(root, 'b')];
}

test('manifest, Unicode names, IPv4 scope and exact sizes above 2 GiB', () => {
  const first = source('照片 📷.jpg', 2 ** 31 + 1).spec;
  const second = source('空文件.txt', 0).spec;
  assert.doesNotThrow(() => validateManifest([first, second], codec));
  assert.throws(() => validateManifest([first, first], codec), { code: 'invalid_manifest' });
  assert.throws(() => validateManifest([{ ...first, size: Number.MAX_SAFE_INTEGER }, second,
    source('third', 1).spec], codec), { code: 'invalid_manifest' });
  assert.throws(() => validateManifest([{ ...first, size: 2 ** 53 }], codec), { code: 'invalid_manifest' });
  assert.equal(safeName('../照片\u202E.png', codec), '.._照片_.png');
  assert.equal(safeName('CON.txt', codec), '_CON.txt');
  const long = safeName('📷'.repeat(150) + '.jpg', codec);
  assert.ok(codec.encode(long).length <= 220 && long.endsWith('.jpg'));
  assert.equal(numberedName('照片.jpg', 2), '照片 (2).jpg');
  assert.equal(onSubnet('192.168.4.121', '192.168.4.22', 24), true);
  assert.equal(onSubnet('192.168.5.121', '192.168.4.22', 24), false);
  assert.equal(onSubnet('224.0.0.251', '224.0.0.251', 32), false);
});

test('stream queue preserves fragments, reports EOF and caps unread bytes', async () => {
  const queue = new ByteQueue();
  queue.push(codec.encode('GET /v1/'));
  const line = queue.line(100, Date.now() + 1000);
  queue.push(codec.encode('offers HTTP/1.1\r\nxyz'));
  assert.equal(await line, 'GET /v1/offers HTTP/1.1');
  queue.end();
  assert.equal(codec.decode(await queue.exact(3, Date.now() + 1000)), 'xyz');
  await assert.rejects(queue.exact(1, Date.now() + 1000), { code: 'interrupted' });
  const bounded = new ByteQueue();
  assert.equal(bounded.push(new Uint8Array(512 * 1024 + 1)), false);
  assert.equal(bounded.buffered, 0);
  const upload = new ByteQueue();
  upload.allowFile();
  assert.equal(upload.push(new Uint8Array(CHUNK_SIZE)), true);
  assert.equal((await upload.exact(CHUNK_SIZE, Date.now() + 1000)).length, CHUNK_SIZE);
});

test('wrong leaf fingerprint sends no HTTP bytes on the TLS connection', async t => {
  const [directory] = await folders(t);
  const peer = await host(t, directory);
  const id = identity();
  let messages = 0;
  const server = tls.createServer(id, socket => socket.on('data', () => { messages++; }));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  await assert.rejects(peer.client.control({
    ...peer.peer, port: server.address().port
  }, 'POST', '/v1/offers', '{}'), { code: 'certificate_changed' });
  assert.equal(messages, 0);
});

test('discovered source and reverse proof gate consent, with no file reads on decline or timeout', async t => {
  const [a, b] = await folders(t);
  const sender = await host(t, a);
  const receiver = await host(t, b);
  const file = source('拒收.txt', 3);
  sender.add(receiver.peer);
  await sender.sender.send(receiver.peer, [file]);
  assert.equal(sender.sender.current.error, 'sender_not_discovered');
  assert.equal(receiver.receiver.current, undefined);
  assert.equal(file.opened, 0);

  receiver.add(sender.peer);
  const unknown = { requestId: crypto.randomId(), senderId: sender.peer.id,
    senderPort: sender.peer.port, files: [file.spec] };
  await assert.rejects(sender.client.control(receiver.peer, 'POST', '/v1/offers', JSON.stringify(unknown)),
    { code: 'unverified_sender' });
  assert.equal(receiver.receiver.current, undefined);

  const denied = sender.sender.send(receiver.peer, [file]);
  const pending = await waitFor(() => receiver.receiver.current);
  assert.equal(pending.state, SessionState.Waiting);
  assert.equal(pending.snapshot().token, undefined);
  assert.equal(file.opened, 0);
  receiver.receiver.decide(pending, false);
  await denied;
  assert.equal(sender.sender.current.state, SessionState.Declined);
  const timed = sender.sender.send(receiver.peer, [file]);
  const later = await waitFor(() => receiver.receiver.current?.id !== pending.id && receiver.receiver.current);
  receiver.receiver.expire(later.deadline + 1);
  await timed;
  assert.equal(sender.sender.current.state, SessionState.Expired);
  assert.equal(file.opened, 0);
  assert.deepEqual(await filesAt(b), []);
});

test('the sender can cancel a waiting offer without opening a file', async t => {
  const [a, b] = await folders(t);
  const sender = await host(t, a);
  const receiver = await host(t, b);
  sender.add(receiver.peer);
  receiver.add(sender.peer);
  const file = source('取消.txt', 4096);
  const sending = sender.sender.send(receiver.peer, [file]);
  await waitFor(() => receiver.receiver.current);
  sender.sender.cancel();
  await sending;
  assert.equal(sender.sender.current.state, SessionState.Canceled);
  assert.equal(receiver.receiver.current.state, SessionState.Canceled);
  assert.equal(file.opened, 0);
  assert.deepEqual(await filesAt(b), []);
});

test('wire rejects early uploads, rolls back SHA-256 mismatch and replays a committed receipt', async t => {
  const [a, b] = await folders(t);
  const sender = await host(t, a, { verify: () => true });
  const receiver = await host(t, b);
  receiver.add(sender.peer);
  const good = source('空文件.txt', 0);
  const bad = source('损坏.txt', 4);
  const body = JSON.stringify({ requestId: crypto.randomId(), senderId: sender.peer.id,
    senderPort: sender.peer.port, files: [bad.spec, good.spec] });
  const ask = async () => JSON.parse(await sender.client.control(receiver.peer, 'POST', '/v1/offers', body));
  const pending = await ask();
  assert.equal((await ask()).id, pending.id);
  const incoming = receiver.receiver.current;
  const upload = (file, digest) => sender.client.upload(receiver.peer, {
    path: '/v1/transfers/' + pending.id + '/files/' + file.spec.id,
    source: file, token: incoming.token, digest, started() {}, progress() {}
  }, new protocol.Cancellation());
  await assert.rejects(upload(good, sha256('')), { code: 'upload_not_allowed' });
  assert.deepEqual(await filesAt(b), []);
  receiver.receiver.decide(incoming, true);
  await assert.rejects(upload(bad, 'f'.repeat(64)), { code: 'digest_mismatch' });
  const saved = JSON.parse(await upload(good, sha256('')));
  assert.equal(saved.state, FileState.Committed);
  assert.equal(saved.name, '空文件.txt');
  assert.deepEqual(JSON.parse(await upload(good, sha256(''))), saved);
  assert.equal(incoming.state, SessionState.Partial);
  assert.deepEqual(await filesAt(b), ['空文件.txt']);
});

test('receiver cancel during second file preserves first and retries only unfinished items', async t => {
  const [a, b] = await folders(t);
  const sender = await host(t, a);
  const file1 = source('照片.jpg', 11, 1);
  const file2 = source('照片.jpg', 16 * CHUNK_SIZE, 2, 8);
  let canceled = false;
  let receiver;
  receiver = await host(t, b, { received(session) {
    if (canceled || session.files[1]?.bytes < CHUNK_SIZE || session.files.length < 2) return;
    canceled = true;
    receiver.receiver.cancel(session);
  } });
  sender.add(receiver.peer);
  receiver.add(sender.peer);
  const sending = sender.sender.send(receiver.peer, [file1, file2]);
  const incoming = await waitFor(() => receiver.receiver.current);
  receiver.receiver.decide(incoming, true);
  await sending;
  assert.equal(sender.sender.current.state, SessionState.Canceled);
  assert.equal(sender.sender.current.unconfirmed.size, 0);
  assert.deepEqual(sender.sender.current.remaining, [file2]);
  assert.deepEqual(await filesAt(b), ['照片.jpg']);

  const retry = sender.sender.send(receiver.peer, sender.sender.current.remaining);
  const next = await waitFor(() => receiver.receiver.current?.id !== incoming.id && receiver.receiver.current);
  assert.equal(next.state, SessionState.Waiting);
  receiver.receiver.decide(next, true);
  await retry;
  assert.equal(sender.sender.current.state, SessionState.Completed);
  assert.deepEqual(await filesAt(b), ['照片 (1).jpg', '照片.jpg']);
  assert.equal(await hashFile(path.join(b, '照片 (1).jpg')), sha256(Buffer.alloc(file2.spec.size, 2)));
  assert.equal(file1.opened, 2);
});

test('a disk-full failure rolls back its temporary file and keeps subsequent commits', async t => {
  const [a, b] = await folders(t);
  const sender = await host(t, a);
  const receiver = await host(t, b, { noSpace: spec => spec.name === '空间不足.bin' });
  sender.add(receiver.peer);
  receiver.add(sender.peer);
  const sending = sender.sender.send(receiver.peer, [source('空间不足.bin', 100), source('完好.txt', 5)]);
  const incoming = await waitFor(() => receiver.receiver.current);
  receiver.receiver.decide(incoming, true);
  await sending;
  assert.equal(incoming.state, SessionState.Partial);
  assert.equal(sender.sender.current.state, SessionState.Partial);
  assert.equal(sender.sender.current.files[0].error, 'no_space');
  assert.deepEqual(await filesAt(b), ['完好.txt']);
});

test('a broken upload connection rolls back the current file and keeps the last commit', async t => {
  const [a, b] = await folders(t);
  const sender = await host(t, a);
  let socket;
  let interrupted = false;
  const receiver = await host(t, b, {
    connected(connection) { socket = connection; },
    received(session) {
      if (!interrupted && session.files[1].bytes > 0) {
        interrupted = true;
        socket.destroy();
      }
    }
  });
  sender.add(receiver.peer);
  receiver.add(sender.peer);
  const first = source('第一项.bin', 123);
  const second = source('中断.bin', 12 * CHUNK_SIZE, 8, 10);
  const sending = sender.sender.send(receiver.peer, [first, second]);
  const incoming = await waitFor(() => receiver.receiver.current);
  receiver.receiver.decide(incoming, true);
  await sending;
  assert.equal(interrupted, true);
  assert.equal(incoming.state, SessionState.Partial);
  assert.equal(sender.sender.current.state, SessionState.Partial);
  assert.deepEqual(sender.sender.current.remaining, [second]);
  assert.deepEqual(await filesAt(b), ['第一项.bin']);
});

test('a dropped PUT receipt is recovered through GET without another upload', async t => {
  const [a, b] = await folders(t);
  const sender = await host(t, a);
  let dropped = false;
  const receiver = await host(t, b, { dropReply(bytes) {
    const wire = codec.decode(bytes);
    if (!dropped && wire.includes('"state":"committed"') && !wire.includes('"files":')) {
      dropped = true;
      return true;
    }
    return false;
  } });
  sender.add(receiver.peer);
  receiver.add(sender.peer);
  const file = source('回执.txt', 1700);
  const sending = sender.sender.send(receiver.peer, [file]);
  const incoming = await waitFor(() => receiver.receiver.current);
  receiver.receiver.decide(incoming, true);
  await sending;
  assert.equal(dropped, true);
  assert.equal(sender.sender.current.state, SessionState.Completed);
  assert.equal(sender.sender.current.unconfirmed.size, 0);
  assert.equal(sender.sender.current.error, '');
  assert.deepEqual(await filesAt(b), ['回执.txt']);
  assert.equal(file.opened, 2);
});
