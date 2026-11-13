import type { HttpClient, Upload } from './Http';
import {
  active, Cancellation, consume, FileState, isId, Item, resultState, SessionState, TransferError,
  validateManifest, validReceipt, validState
} from './Protocol';
import type { Codec, Crypto, Offer, Peer, Proof, Receipt, Snapshot, Source } from './Protocol';

const WAIT_FOR_DECISION = 100000;
const FILE_FAILURES = ['digest_mismatch', 'length_mismatch', 'storage_failed', 'no_space', 'download_permission'];

export class Outgoing {
  readonly peer: Peer;
  readonly sources: Source[];
  readonly requestId: string;
  readonly files: Item[];
  readonly stop = new Cancellation();
  readonly unconfirmed = new Set<string>();
  state = SessionState.Waiting;
  running = true;
  error = '';
  sessionId = '';
  preparing = '';

  constructor(peer: Peer, sources: Source[], requestId: string) {
    this.peer = peer;
    this.sources = sources;
    this.requestId = requestId;
    this.files = sources.map(source => new Item(source.spec));
  }

  get remaining(): Source[] {
    return this.sources.filter((_, index) => this.files[index].state !== FileState.Committed);
  }
}

export interface SenderOptions {
  id: string;
  port: () => number;
  codec: Codec;
  crypto: Crypto;
  client: HttpClient;
  changed: (job: Outgoing) => void;
  remember: (peer: Peer) => void;
}

export class Sender {
  current?: Outgoing;
  private options: SenderOptions;

  constructor(options: SenderOptions) {
    this.options = options;
  }

  verify(proof: Proof, address: string): boolean {
    const job = this.current;
    return !!job && job.running && !job.stop.canceled && job.requestId === proof.requestId &&
      job.peer.id === proof.receiverId && job.peer.address === address;
  }

  cancel(reason: string = 'canceled'): void {
    if (this.current?.running) this.current.stop.cancel(reason);
  }

  async send(peer: Peer, sources: Source[]): Promise<void> {
    if (this.current?.running) throw new TransferError('busy', 503);
    validateManifest(sources.map(source => source.spec), this.options.codec);
    const job = new Outgoing(peer, sources, this.options.crypto.randomId());
    const offer: Offer = {
      requestId: job.requestId,
      senderId: this.options.id,
      senderPort: this.options.port(),
      files: sources.map(source => source.spec)
    };
    const body = JSON.stringify(offer);
    this.current = job;
    this.options.changed(job);
    try {
      const snapshot = await this.sendOffer(job, body);
      if (!snapshot || !isId(snapshot.id)) throw new TransferError('invalid_status');
      job.sessionId = snapshot.id;
      const status = await this.waitForDecision(job, snapshot);
      if (job.state !== SessionState.Accepted || status.token === undefined) return;
      for (let i = 0; i < job.sources.length; i++) {
        job.stop.check();
        await this.sendFile(job, job.sources[i], job.files[i], status.token);
      }
      job.stop.check();
      if (!await this.reconcile(job, peer)) throw new TransferError('interrupted');
    } catch (error) {
      job.error = job.stop.canceled ? job.stop.code : error instanceof TransferError ? error.code : 'interrupted';
      if (!job.sessionId && job.error === 'canceled') {
        // The same request ID recovers a waiting offer if its reply was lost.
        try {
          const text = await this.options.client.control(job.peer, 'POST', '/v1/offers', body);
          const status = JSON.parse(text) as Snapshot;
          if (status && isId(status.id)) job.sessionId = status.id;
        } catch (_) {}
      }
      if (job.sessionId) await this.reconcile(job, peer);
      if (active(job.state)) {
        job.state = job.error === 'canceled' ? SessionState.Canceled : resultState(job.files);
      }
    } finally {
      job.preparing = '';
      job.running = false;
      for (const file of job.files) {
        if (file.state === FileState.Committed) continue;
        file.state = FileState.Failed;
        file.error = file.error ?? (job.error || job.state);
      }
      this.options.changed(job);
    }
  }

  private async sendOffer(job: Outgoing, body: string): Promise<Snapshot> {
    let text: string;
    try {
      text = await this.options.client.control(job.peer, 'POST', '/v1/offers', body, job.stop);
    } catch (error) {
      job.stop.check();
      if (error instanceof TransferError && error.code !== 'interrupted' && error.code !== 'timeout') throw error;
      text = await this.options.client.control(job.peer, 'POST', '/v1/offers', body, job.stop);
    }
    return JSON.parse(text) as Snapshot;
  }

  private async waitForDecision(job: Outgoing, snapshot: Snapshot): Promise<Snapshot> {
    let status = snapshot;
    this.apply(job, status);
    const deadline = Date.now() + WAIT_FOR_DECISION;
    while (job.state === SessionState.Waiting) {
      if (Date.now() >= deadline) throw new TransferError('timeout', 408);
      await new Promise<void>(resolve => { setTimeout(resolve, 700); });
      job.stop.check();
      const text = await this.options.client.control(job.peer, 'GET',
        '/v1/transfers/' + job.sessionId, '', job.stop);
      status = JSON.parse(text) as Snapshot;
      this.apply(job, status);
    }
    return status;
  }

  private async sendFile(job: Outgoing, source: Source, file: Item, token: string): Promise<void> {
    job.preparing = source.spec.name;
    this.options.changed(job);
    const hash = this.options.crypto.sha256();
    let digest: string;
    try {
      await consume(source, job.stop, async (bytes: Uint8Array) => { hash.update(bytes); });
      digest = hash.finish();
    } catch (error) {
      job.stop.check();
      file.state = FileState.Failed;
      file.error = error instanceof TransferError ? error.code : 'source_unreadable';
      return;
    } finally {
      job.preparing = '';
    }
    file.state = FileState.Uploading;
    this.options.changed(job);
    try {
      const upload: Upload = {
        path: '/v1/transfers/' + job.sessionId + '/files/' + source.spec.id,
        token: token,
        source: source,
        digest: digest,
        started: () => { job.unconfirmed.add(source.spec.id); },
        progress: (count: number) => {
          file.bytes = count;
          this.options.changed(job);
        }
      };
      const text = await this.options.client.upload(job.peer, upload, job.stop);
      const receipt = JSON.parse(text) as Receipt;
      if (!validReceipt(receipt, source.spec) || receipt.state !== FileState.Committed) {
        throw new TransferError('invalid_status');
      }
      this.commit(job, file, receipt);
    } catch (error) {
      if (!(error instanceof TransferError)) {
        throw new TransferError('interrupted');
      }
      if (!FILE_FAILURES.includes(error.code)) throw error;
      job.unconfirmed.delete(source.spec.id);
      file.state = FileState.Failed;
      file.error = error.code;
      this.options.changed(job);
    }
  }

  async reconcile(job: Outgoing, peer: Peer): Promise<boolean> {
    if (!job.sessionId || peer.id !== job.peer.id) return false;
    const path = '/v1/transfers/' + job.sessionId;
    try {
      const status = await this.options.client.control(peer, 'GET', path);
      this.apply(job, JSON.parse(status) as Snapshot);
      if (active(job.state)) {
        const canceled = await this.options.client.control(peer, 'POST', path + '/cancel');
        this.apply(job, JSON.parse(canceled) as Snapshot);
        if (job.error !== 'canceled') job.state = resultState(job.files);
      }
      return !active(job.state);
    } catch (_) {
      return false;
    } finally {
      this.options.changed(job);
    }
  }

  private apply(job: Outgoing, status: Snapshot): void {
    if (!status || status.id !== job.sessionId || !validState(status.state) ||
      !Array.isArray(status.files) || status.files.length !== job.files.length ||
      (status.state === SessionState.Accepted && !isId(status.token))) {
      throw new TransferError('invalid_status');
    }
    const receipts = new Map<string, Receipt>();
    for (const receipt of status.files) {
      const file = job.files.find(item => !!receipt && item.spec.id === receipt.id);
      if (!file || receipts.has(receipt.id) || !validReceipt(receipt, file.spec)) {
        throw new TransferError('invalid_status');
      }
      receipts.set(receipt.id, receipt);
    }
    for (const file of job.files) {
      const receipt = receipts.get(file.spec.id);
      if (!receipt) throw new TransferError('invalid_status');
      if (receipt.state === FileState.Committed) {
        this.commit(job, file, receipt);
      } else if (file.state !== FileState.Committed) {
        if (receipt.state === FileState.Failed || !active(status.state)) job.unconfirmed.delete(file.spec.id);
        if (file.error === undefined) {
          file.state = receipt.state;
          file.bytes = receipt.bytes;
          file.error = receipt.error;
        }
      }
    }
    job.state = status.state;
    if (job.state === SessionState.Completed) job.error = '';
    this.options.changed(job);
  }

  private commit(job: Outgoing, file: Item, receipt: Receipt): void {
    file.state = FileState.Committed;
    file.bytes = file.spec.size;
    file.savedName = receipt.name;
    file.error = undefined;
    job.unconfirmed.delete(file.spec.id);
    this.options.remember(job.peer);
    this.options.changed(job);
  }
}
