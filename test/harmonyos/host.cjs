const { createHash, generateKeyPairSync, randomBytes, sign, X509Certificate } = require('node:crypto');
const { once } = require('node:events');
const { createReadStream, existsSync, readFileSync } = require('node:fs');
const fs = require('node:fs/promises');
const { registerHooks, stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const tls = require('node:tls');
const { pathToFileURL } = require('node:url');
const { setTimeout: delay } = require('node:timers/promises');

const coreDirectory = path.resolve(__dirname, '../../harmonyos/entry/src/main/ets/core');
const core = pathToFileURL(coreDirectory + path.sep);
registerHooks({
  resolve(specifier, context, next) {
    if (context.parentURL?.startsWith(core.href) && specifier.startsWith('.')) {
      return { url: new URL(specifier + '.ets', context.parentURL).href, shortCircuit: true };
    }
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url.startsWith(core.href) && url.endsWith('.ets')) {
      const source = readFileSync(new URL(url), 'utf8');
      return { format: 'module', source: stripTypeScriptTypes(source, { mode: 'transform' }), shortCircuit: true };
    }
    return next(url, context);
  }
});

const load = name => require(path.join(coreDirectory, name + '.ets'));
const protocol = load('Protocol');
const { certificateBody, signedCertificate } = load('Certificate');
const { ByteQueue, HttpClient } = load('Http');
const { Receiver } = load('Receiver');
const { Sender } = load('Sender');

const codec = {
  encode: text => new TextEncoder().encode(text),
  decode: bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes)
};
const crypto = {
  randomId: () => randomBytes(16).toString('hex'),
  sha256: () => {
    const hash = createHash('sha256');
    return { update: bytes => hash.update(bytes), finish: () => hash.digest('hex') };
  }
};
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

function identity() {
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const body = certificateBody(spki, randomBytes(16), new Date(Date.now() - 60000), new Date(Date.now() + 86400000));
  const der = signedCertificate(body, sign('sha256', body, privateKey));
  const x509 = new X509Certificate(Buffer.from(der));
  if (!x509.verify(publicKey)) throw new Error('Certificate signature did not verify');
  return {
    id: sha256(der), cert: x509.toString(), key: privateKey.export({ type: 'pkcs8', format: 'pem' })
  };
}

function channel(socket, server, onReply) {
  const input = new ByteQueue();
  socket.on('data', bytes => { if (!input.push(bytes)) socket.destroy(); });
  socket.on('close', () => input.end());
  socket.on('end', () => input.end());
  socket.on('error', () => input.end());
  return {
    input,
    async send(bytes) {
      if (onReply?.(bytes)) {
        socket.destroy();
        throw new protocol.TransferError('interrupted');
      }
      await new Promise((resolve, reject) => socket.write(bytes, error => error ? reject(error) : resolve()));
    },
    close() {
      if (server) socket.end();
      else socket.destroy();
    }
  };
}

async function dial(peer, stop) {
  stop.check();
  const socket = tls.connect({ host: peer.address, port: peer.port, rejectUnauthorized: false, minVersion: 'TLSv1.2' });
  const wire = channel(socket, false);
  const unwatch = stop.watch(() => socket.destroy(new Error('canceled')));
  try {
    await protocol.withTimeout(once(socket, 'secureConnect'), 5000);
    protocol.checkPin(peer.id, sha256(socket.getPeerCertificate().raw));
    stop.check();
    return wire;
  } catch (error) {
    socket.destroy();
    throw error;
  } finally {
    unwatch();
  }
}

function disk(directory, options) {
  return {
    async create(spec) {
      await fs.mkdir(directory, { recursive: true });
      const temporary = path.join(directory, '.' + crypto.randomId() + '.part');
      let output = await fs.open(temporary, 'wx');
      const close = async () => {
        if (!output) return;
        await output.close();
        output = undefined;
      };
      return {
        async write(bytes) {
          if (options.noSpace?.(spec)) throw new protocol.TransferError('no_space', 422);
          await output.write(bytes);
        },
        async commit() {
          await close();
          for (let i = 0; ; i++) {
            const name = protocol.numberedName(protocol.safeName(spec.name, codec), i);
            const finalPath = path.join(directory, name);
            try {
              await fs.link(temporary, finalPath);
              await fs.unlink(temporary);
              return { name, path: finalPath };
            } catch (error) {
              if (error.code !== 'EEXIST') throw error;
            }
          }
        },
        async rollback() {
          await close();
          await fs.unlink(temporary);
        }
      };
    }
  };
}

async function host(t, directory, options = {}) {
  const device = identity();
  const client = new HttpClient(codec, dial);
  const peers = new Map();
  const history = new Set();
  const sockets = new Set();
  const server = tls.createServer({ ...device, minVersion: 'TLSv1.2' }, socket => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
    const wire = channel(socket, true, options.dropReply);
    options.connected?.(socket);
    receiver.serve(wire, socket.remoteAddress);
  });
  const remember = peer => history.add(peer.id);
  const sender = new Sender({ id: device.id, port: () => server.address().port, codec, crypto, client,
    remember, changed: options.sent ?? (() => {}) });
  const receiver = new Receiver({ id: device.id, codec, crypto, client, remember, storage: disk(directory, options),
    findPeer: id => peers.get(id), canReceive: () => !sender.current?.running,
    verifyOutgoing: (proof, address) => options.verify?.(proof, address) ?? sender.verify(proof, address),
    changed: options.received ?? (() => {})
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  receiver.start();
  t.after(async () => {
    await receiver.stop();
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  });
  return {
    peer: { id: device.id, port: server.address().port, name: '测试端', address: '127.0.0.1', platform: 'test' },
    client, sender, receiver, peers, history,
    add(peer) { peers.set(peer.id, peer); }
  };
}

function source(name, size, fill = 4, pace = 0) {
  const spec = { id: crypto.randomId(), name, size };
  let opened = 0;
  return {
    spec,
    get opened() { return opened; },
    async open() {
      const upload = ++opened % 2 === 0;
      let remaining = size;
      return {
        async read(max) {
          if (upload && pace) await delay(pace);
          const count = Math.min(max, remaining);
          remaining -= count;
          return new Uint8Array(count).fill(fill);
        },
        async close() {}
      };
    }
  };
}

async function filesAt(directory) {
  return existsSync(directory) ? (await fs.readdir(directory)).sort() : [];
}

async function hashFile(file) {
  const hash = createHash('sha256');
  for await (const bytes of createReadStream(file)) hash.update(bytes);
  return hash.digest('hex');
}

async function waitFor(fn, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const result = fn();
    if (result) return result;
    await delay(10);
  }
  throw new Error('Timed out waiting for test event');
}

module.exports = { ByteQueue, protocol, codec, crypto, sha256, host, source, filesAt, hashFile, waitFor, identity };
