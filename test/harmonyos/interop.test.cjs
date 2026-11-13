const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const { test } = require('node:test');
const { setTimeout: delay } = require('node:timers/promises');
const { protocol, host, source, filesAt, hashFile, sha256, waitFor } = require('./host.cjs');

function dartPeer(t, directory, peer) {
  const root = path.resolve(__dirname, '../..');
  const executable = process.env.NEAR_TRANSFER_DART ?? (process.platform === 'win32' ? 'dart.exe' : 'dart');
  const child = spawn(executable, ['run', path.join(__dirname, 'dart_peer.dart'), directory, peer.id, String(peer.port)],
    { cwd: root, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  const events = [];
  let failure;
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', text => { stderr = (stderr + text).slice(-4000); });
  child.on('error', error => { failure = error; });
  child.stdin.on('error', error => { failure = error; });
  const stopped = new Promise(resolve => child.once('close', resolve));
  const lines = readline.createInterface({ input: child.stdout });
  lines.on('line', line => {
    if (line.startsWith('{')) events.push(JSON.parse(line));
  });
  const send = (action, paths) => child.stdin.write(JSON.stringify({ action, paths }) + '\n');
  t.after(async () => {
    if (child.exitCode === null && !failure) {
      send('quit');
      child.stdin.end();
    }
    await Promise.race([stopped, delay(1000)]);
    if (child.exitCode === null) child.kill();
    await stopped;
  });
  return {
    send,
    async event(type, predicate = () => true) {
      try {
        return await waitFor(() => {
          if (failure) throw failure;
          if (child.exitCode !== null) throw new Error('Dart peer exited with ' + child.exitCode);
          const index = events.findIndex(event => event.event === type && predicate(event));
          return index === -1 ? undefined : events.splice(index, 1)[0];
        }, 25000);
      } catch (error) {
        throw new Error(error.message + '\nSet NEAR_TRANSFER_DART to dart.exe on Windows and run flutter pub get.\n' +
          stderr, { cause: error });
      }
    }
  };
}

test('production Dart and HarmonyOS protocol source interoperate over TLS in both directions', { timeout: 60000 },
  async t => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'neartransfer-dart-'));
    t.after(() => fs.rm(root, { recursive: true, force: true }));
    const dartDownloads = path.join(root, 'dart');
    const harmonyDownloads = path.join(root, 'harmony');
    const harmony = await host(t, harmonyDownloads);
    const dart = dartPeer(t, dartDownloads, harmony.peer);
    const ready = await dart.event('ready');
    const peer = { id: ready.id, address: '127.0.0.1', port: ready.port, name: 'Dart peer', platform: 'windows' };
    harmony.add(peer);

    const rejected = source('拒绝.txt', 80);
    const declined = harmony.sender.send(peer, [rejected]);
    const denied = await dart.event('incoming', event => event.state === 'waiting');
    assert.deepEqual(await filesAt(dartDownloads), []);
    dart.send('decline');
    await declined;
    assert.equal(harmony.sender.current.state, protocol.SessionState.Declined);
    assert.equal(rejected.opened, 0);

    const videoSize = 9 * 1024 * 1024 + 13;
    const sources = [source('照片.jpg', 2301, 3), source('照片.jpg', 0), source('长视频.bin', videoSize, 7)];
    const outgoing = harmony.sender.send(peer, sources);
    await dart.event('incoming', event => event.state === 'waiting' && event.id !== denied.id);
    assert.deepEqual(await filesAt(dartDownloads), []);
    dart.send('accept');
    await outgoing;
    await dart.event('incoming', event => event.state === 'completed');
    assert.equal(harmony.sender.current.state, protocol.SessionState.Completed, harmony.sender.current.error);
    assert.deepEqual(await filesAt(dartDownloads), ['照片 (1).jpg', '照片.jpg', '长视频.bin']);
    assert.equal((await fs.stat(path.join(dartDownloads, '照片 (1).jpg'))).size, 0);
    assert.equal(await hashFile(path.join(dartDownloads, '长视频.bin')), sha256(Buffer.alloc(videoSize, 7)));
    assert.equal(await hashFile(path.join(dartDownloads, '照片.jpg')), sha256(Buffer.alloc(2301, 3)));
    assert.equal(harmony.history.has(peer.id), true);

    const sendSize = 9 * 1024 * 1024 + 9;
    const large = path.join(root, '传入大文件.bin');
    const empty = path.join(root, '空文件.txt');
    const same = path.join(root, '重复');
    await fs.mkdir(same);
    const duplicate = path.join(same, '空文件.txt');
    await Promise.all([fs.writeFile(large, Buffer.alloc(sendSize, 5)), fs.writeFile(empty, ''),
      fs.writeFile(duplicate, '重名数据')]);
    dart.send('send', [large, empty, duplicate]);
    const incoming = await waitFor(() => harmony.receiver.current);
    assert.equal(incoming.state, protocol.SessionState.Waiting);
    assert.deepEqual(await filesAt(harmonyDownloads), []);
    harmony.receiver.decide(incoming, true);
    const finished = await dart.event('sent');
    assert.equal(finished.state, 'completed', JSON.stringify(finished));
    assert.deepEqual(await filesAt(harmonyDownloads), ['传入大文件.bin', '空文件 (1).txt', '空文件.txt']);
    assert.equal(await hashFile(path.join(harmonyDownloads, '传入大文件.bin')), await hashFile(large));
    assert.equal(await hashFile(path.join(harmonyDownloads, '空文件 (1).txt')), await hashFile(duplicate));
    assert.equal((await fs.stat(path.join(harmonyDownloads, '空文件.txt'))).size, 0);
  });
