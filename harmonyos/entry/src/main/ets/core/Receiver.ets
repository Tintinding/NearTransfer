import { contentLength, controlBody, readRequest, sendResponse } from './Http';
import type { Channel, HttpClient, Request } from './Http';
import {
  ACCEPTED_IDLE, active, Cancellation, CHUNK_SIZE, FileState, IO_TIMEOUT,
  isDigest, isId, isPort, Item, resultState, SessionState, TransferError, validateManifest, WAIT_TIME
} from './Protocol';
import type { Codec, Crypto, Offer, Peer, Proof, Receipt, Snapshot, Storage, Target, Verification } from './Protocol';

const SESSION_LIMIT = 128;
const RESULT_RETENTION = 20 * 60 * 1000;

export class Incoming {
  readonly id: string;
  readonly requestId: string;
  readonly peer: Peer;
  readonly files: Item[];
  readonly token: string;
  readonly stop = new Cancellation();
  state = SessionState.Waiting;
  deadline = Date.now() + WAIT_TIME;
  upload?: Promise<Receipt>;

  constructor(offer: Offer, peer: Peer, crypto: Crypto) {
    this.id = crypto.randomId();
    this.requestId = offer.requestId;
    this.peer = peer;
    this.files = offer.files.map(spec => new Item(spec));
    this.token = crypto.randomId();
  }

  snapshot(): Snapshot {
    const status: Snapshot = { id: this.id, state: this.state, files: this.files.map(file => file.receipt()) };
    if (this.state === SessionState.Accepted) status.token = this.token;
    return status;
  }
}

export interface ReceiverOptions {
  id: string;
  codec: Codec;
  crypto: Crypto;
  client: HttpClient;
  storage: Storage;
  findPeer: (id: string) => Peer | undefined;
  canReceive: () => boolean;
  verifyOutgoing: (proof: Proof, address: string) => boolean;
  changed: (session: Incoming) => void;
  remember: (peer: Peer) => void;
}

interface ErrorBody {
  error: string;
}

export class Receiver {
  current?: Incoming;
  private options: ReceiverOptions;
  private sessions = new Map<string, Incoming>();
  private verifying = new Set<string>();
  private network = new Cancellation();
  private online = false;

  constructor(options: ReceiverOptions) {
    this.options = options;
  }

  get busy(): boolean {
    const session = this.current;
    return session !== undefined && (active(session.state) || session.upload !== undefined);
  }

  start(): void {
    this.network = new Cancellation();
    this.online = true;
  }

  async stop(): Promise<void> {
    this.online = false;
    this.network.cancel('interrupted');
    const session = this.current;
    if (!session) return;
    if (active(session.state)) this.finish(session, resultState(session.files), 'interrupted');
    await session.upload?.catch(() => {});
  }

  decide(session: Incoming, accept: boolean): void {
    this.expire();
    if (!this.online || session !== this.current || session.state !== SessionState.Waiting) return;
    if (!accept) {
      this.finish(session, SessionState.Declined, 'declined');
      return;
    }
    session.state = SessionState.Accepted;
    session.deadline = Date.now() + ACCEPTED_IDLE;
    this.options.changed(session);
  }

  async cancel(session: Incoming): Promise<void> {
    if (active(session.state)) this.finish(session, SessionState.Canceled, 'canceled');
    await session.upload?.catch(() => {});
  }

  expire(now: number = Date.now()): void {
    for (const session of this.sessions.values()) {
      if (session.upload || now <= session.deadline) continue;
      if (active(session.state)) this.finish(session, SessionState.Expired, 'expired');
      else if (now - session.deadline > RESULT_RETENTION) this.sessions.delete(session.id);
    }
  }

  async serve(channel: Channel, address: string): Promise<void> {
    try {
      const request = await readRequest(channel.input);
      this.expire();
      const output = await this.route(request, address);
      await sendResponse(channel, 200, output, this.options.codec);
    } catch (error) {
      const failure = error instanceof TransferError ? error : new TransferError('peer_error', 500);
      const body: ErrorBody = { error: failure.code };
      await sendResponse(channel, failure.status, JSON.stringify(body), this.options.codec).catch(() => {});
    } finally {
      channel.close();
    }
  }

  private finish(session: Incoming, state: SessionState, code: string): void {
    session.state = state;
    session.deadline = Date.now();
    if (code) session.stop.cancel(code);
    for (const file of session.files) {
      if (file.state !== FileState.Pending) continue;
      file.state = FileState.Failed;
      file.error = code;
    }
    this.options.changed(session);
  }

  private async route(request: Request, address: string): Promise<string> {
    if (!this.online) throw new TransferError('offline', 503);
    if (request.method === 'POST' && request.path === '/v1/offers') {
      return JSON.stringify(await this.offer(request, address));
    }
    if (request.method === 'POST' && request.path === '/v1/verify-offer') {
      const proof = await this.parse<Proof>(request);
      const result: Verification = {
        verified: !!proof && isId(proof.requestId) && isDigest(proof.receiverId) &&
          this.options.verifyOutgoing(proof, address)
      };
      return JSON.stringify(result);
    }
    const path = /^\/v1\/transfers\/([a-f0-9]{32})(\/cancel|\/files\/([a-f0-9]{32}))?$/.exec(request.path);
    if (!path) throw new TransferError('not_found', 404);
    const session = this.sessions.get(path[1]);
    if (!session) throw new TransferError('session_unknown', 404);
    if (!path[2] && request.method === 'GET') {
      if (!active(session.state)) await session.upload?.catch(() => {});
      return JSON.stringify(session.snapshot());
    }
    if (path[2] === '/cancel' && request.method === 'POST') {
      await this.cancel(session);
      return JSON.stringify(session.snapshot());
    }
    if (path[3] && request.method === 'PUT') return JSON.stringify(await this.upload(request, session, path[3]));
    throw new TransferError('not_found', 404);
  }

  private async parse<T>(request: Request): Promise<T> {
    const body = await controlBody(request, this.options.codec);
    try {
      return JSON.parse(body) as T;
    } catch (_) {
      throw new TransferError('invalid_json');
    }
  }

  private async offer(request: Request, address: string): Promise<Snapshot> {
    const offer = await this.parse<Offer>(request);
    if (!offer || !isId(offer.requestId) || !isDigest(offer.senderId) || !isPort(offer.senderPort)) {
      throw new TransferError('invalid_manifest');
    }
    validateManifest(offer.files, this.options.codec);
    const peer = this.options.findPeer(offer.senderId);
    if (!peer || peer.address !== address || peer.port !== offer.senderPort) {
      throw new TransferError('sender_not_discovered', 403);
    }
    const key = offer.senderId + ':' + offer.requestId;
    if (this.verifying.has(key) || this.verifying.size >= 4) throw new TransferError('busy', 503);
    for (const session of this.sessions.values()) {
      if (session.peer.id === offer.senderId && session.requestId === offer.requestId) return session.snapshot();
    }
    if (this.busy || !this.options.canReceive() || this.sessions.size >= SESSION_LIMIT) {
      throw new TransferError('busy', 503);
    }
    this.verifying.add(key);
    const network = this.network;
    try {
      const proof: Proof = { requestId: offer.requestId, receiverId: this.options.id };
      let verified: Verification;
      try {
        const reply = await this.options.client.control(peer, 'POST', '/v1/verify-offer',
          JSON.stringify(proof), network);
        verified = JSON.parse(reply) as Verification;
      } catch (error) {
        if (error instanceof TransferError && error.code === 'certificate_changed') throw error;
        throw new TransferError('unverified_sender', 403);
      }
      if (!verified || verified.verified !== true) throw new TransferError('unverified_sender', 403);
      if (network.canceled || !this.online || this.busy || !this.options.canReceive()) {
        throw new TransferError('busy', 503);
      }
      const session = new Incoming(offer, peer, this.options.crypto);
      this.sessions.set(session.id, session);
      this.current = session;
      this.options.changed(session);
      return session.snapshot();
    } finally {
      this.verifying.delete(key);
    }
  }

  private async upload(request: Request, session: Incoming, id: string): Promise<Receipt> {
    if (request.headers.get('authorization') !== 'Bearer ' + session.token) {
      throw new TransferError('invalid_token', 403);
    }
    const file = session.files.find(item => item.spec.id === id);
    if (!file) throw new TransferError('file_unknown', 404);
    if (file.state === FileState.Committed) return file.receipt();
    if (session.state !== SessionState.Accepted || session.upload || file.state !== FileState.Pending) {
      throw new TransferError('upload_not_allowed', 409);
    }
    const digest = request.headers.get('x-content-sha256');
    if (contentLength(request.headers) !== file.spec.size || digest === undefined || !isDigest(digest)) {
      throw new TransferError('invalid_file_headers');
    }
    request.input.allowFile();
    file.state = FileState.Uploading;
    const upload = this.write(request, session, file, digest);
    session.upload = upload;
    this.options.changed(session);
    try {
      return await upload;
    } finally {
      session.upload = undefined;
      session.deadline = Date.now() + ACCEPTED_IDLE;
      if (session.state === SessionState.Accepted && file.error === 'interrupted') {
        this.finish(session, resultState(session.files), 'interrupted');
      } else if (session.state === SessionState.Accepted &&
        session.files.every(item => item.state === FileState.Committed || item.state === FileState.Failed)) {
        this.finish(session, resultState(session.files), '');
      } else {
        this.options.changed(session);
      }
    }
  }

  private async write(request: Request, session: Incoming, file: Item, expected: string): Promise<Receipt> {
    let target: Target | undefined;
    const stop = session.stop;
    const unwatch = stop.watch(() => request.input.abort(new TransferError(stop.code, 409)));
    try {
      stop.check();
      target = await this.options.storage.create(file.spec);
      const hash = this.options.crypto.sha256();
      while (file.bytes < file.spec.size) {
        stop.check();
        const size = Math.min(CHUNK_SIZE, file.spec.size - file.bytes);
        const bytes = await request.input.exact(size, Date.now() + IO_TIMEOUT);
        await target.write(bytes);
        hash.update(bytes);
        file.bytes += bytes.length;
        this.options.changed(session);
      }
      if (request.input.buffered > 0) throw new TransferError('length_mismatch', 422);
      if (hash.finish() !== expected) throw new TransferError('digest_mismatch', 422);
      stop.check();
      // Once commit starts, cancellation waits for its result.
      file.saved = await target.commit();
      file.savedName = file.saved.name;
      file.state = FileState.Committed;
      target = undefined;
      this.options.remember(session.peer);
      return file.receipt();
    } catch (error) {
      const code = stop.canceled ? stop.code : error instanceof TransferError ? error.code : 'storage_failed';
      file.state = FileState.Failed;
      file.error = code === 'timeout' ? 'interrupted' : code;
      throw new TransferError(file.error, file.error === 'interrupted' ? 408 : 422);
    } finally {
      unwatch();
      await target?.rollback().catch(() => {});
    }
  }
}
