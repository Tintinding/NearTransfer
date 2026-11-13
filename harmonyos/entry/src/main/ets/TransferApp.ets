import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { HttpClient } from './core/Http';
import {
  active, FileSpec, FileState, isDigest, Item, MAX_FILES, Peer, SavedFile,
  SessionState, TransferError, withTimeout
} from './core/Protocol';
import { Incoming, Receiver, ReceiverOptions } from './core/Receiver';
import { Outgoing, Sender, SenderOptions } from './core/Sender';
import { Files, PickedFile } from './platform/Files';
import { deviceCrypto, Identity, utf8 } from './platform/Identity';
import { Lan, Link, localLink, networkError } from './platform/Lan';

export interface Nearby {
  id: string;
  name: string;
  platform: string;
  familiar: boolean;
}

export interface FileView {
  id: string;
  name: string;
  size: number;
  state: FileState;
  error: string;
  savedName: string;
  saved?: SavedFile;
}

export class TaskView {
  id = '';
  peer = '';
  state = SessionState.Waiting;
  files: FileView[] = [];
  bytes = 0;
  total = 0;
  committed = 0;
  pending = false;
  error = '';
  preparing = '';
  unknown = false;
}

export class AppView {
  localName = '鸿蒙手机';
  ready = false;
  networkIssue = '';
  notice = '';
  receive = false;
  picking = false;
  busy = false;
  checking = false;
  downloadAuthorized = false;
  peers: Nearby[] = [];
  selectedId = '';
  selectedName = '';
  draft: FileSpec[] = [];
  outgoing?: TaskView;
  incoming?: TaskView;
}

function taskView(id: string, name: string, state: SessionState, items: Item[]): TaskView {
  const task = new TaskView();
  task.id = id;
  task.peer = name;
  task.state = state;
  task.files = items.map(item => {
    const file: FileView = {
      id: item.spec.id, name: item.spec.name, size: item.spec.size, state: item.state,
      error: item.error ?? '', savedName: item.savedName ?? '', saved: item.saved
    };
    return file;
  });
  for (const item of items) {
    task.total += item.spec.size;
    task.bytes += item.bytes;
    if (item.state === FileState.Committed) task.committed++;
  }
  return task;
}

export class TransferApp {
  private context: common.UIAbilityContext;
  private name = '鸿蒙手机';
  private prefs?: preferences.Preferences;
  private history = new Set<string>();
  private files?: Files;
  private lan?: Lan;
  private receiver?: Receiver;
  private sender?: Sender;
  private foreground = false;
  private networkGeneration = 0;
  private nextCheck: Promise<void> = Promise.resolve();
  private checkQueued = false;
  private forceCheck = false;
  private networkKey = '';
  private monitor = -1;
  private notifyTimer = -1;
  private networkIssue = '';
  private notice = '';
  private ready = false;
  private receiving = false;
  private picking = false;
  private checking = false;
  private showOutgoing = false;
  private shownIncoming = '';
  private selectedId = '';
  private draft: PickedFile[] = [];
  private observer?: (view: AppView) => void;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    const model = deviceInfo.marketName?.trim();
    if (model && utf8.encode(model).length <= 120) this.name = model;
  }

  observe(observer?: (view: AppView) => void): void {
    this.observer = observer;
    if (observer) observer(this.view());
  }

  setForeground(foreground: boolean): void {
    if (this.foreground === foreground) return;
    this.foreground = foreground;
    this.networkGeneration++;
    clearInterval(this.monitor);
    if (foreground) {
      this.monitor = setInterval(() => {
        this.receiver?.expire();
        this.queueCheck();
      }, 2500);
    } else {
      this.ready = false;
      this.sender?.cancel('interrupted');
      this.receiver?.stop().catch(() => {});
      this.changed();
    }
    this.queueCheck(true);
  }

  refresh(): void {
    if (!this.busy()) this.queueCheck(true);
  }

  private queueCheck(force: boolean = false): void {
    this.forceCheck = this.forceCheck || force;
    if (this.checkQueued) return;
    this.checkQueued = true;
    this.nextCheck = this.nextCheck.then(async () => {
      this.checkQueued = false;
      const forced = this.forceCheck;
      this.forceCheck = false;
      await this.checkNetwork(forced);
    }).catch(() => {
      this.networkIssue = 'network_failed';
      this.changed();
    });
  }

  private async initialize(): Promise<void> {
    if (this.lan) return;
    const identity = await Identity.load(this.context.filesDir);
    const prefs = await preferences.getPreferences(this.context, 'neartransfer-peers');
    this.prefs = prefs;
    const stored = prefs.getSync('fingerprints', '[]');
    if (typeof stored === 'string') {
      try {
        const list = JSON.parse(stored) as string[];
        if (Array.isArray(list)) this.history = new Set(list.filter(id => isDigest(id)).slice(-256));
      } catch (_) {}
    }
    const files = new Files(this.context, deviceCrypto, identity.id);
    this.files = files;
    const lan = new Lan(this.context, identity, this.name, () => this.changed(), code => {
      this.ready = false;
      this.networkIssue = code;
      this.changed();
      this.nextCheck = this.nextCheck.then(() => this.stopNetwork()).catch(() => {});
    });
    const client = new HttpClient(utf8, (peer, stop) => lan.dial(peer, stop));
    const senderOptions: SenderOptions = {
      id: identity.id, port: () => lan.port, codec: utf8, crypto: deviceCrypto, client: client,
      changed: () => this.changed(), remember: peer => this.remember(peer)
    };
    const sender = new Sender(senderOptions);
    this.sender = sender;
    const receiverOptions: ReceiverOptions = {
      id: identity.id, codec: utf8, crypto: deviceCrypto, client: client, storage: files,
      findPeer: id => lan.peers.find(peer => peer.id === id),
      canReceive: () => !sender.current?.running,
      verifyOutgoing: (proof, address) => sender.verify(proof, address),
      changed: session => this.incomingChanged(session),
      remember: peer => this.remember(peer)
    };
    this.receiver = new Receiver(receiverOptions);
    this.lan = lan;
  }

  private async checkNetwork(force: boolean): Promise<void> {
    if (!this.foreground) {
      await this.stopNetwork();
      this.networkKey = '';
      return;
    }
    const generation = this.networkGeneration;
    if (!this.lan) {
      try {
        await this.initialize();
      } catch (_) {
        this.networkIssue = 'identity_failed';
        this.changed();
        return;
      }
    }
    let link: Link | undefined;
    try {
      link = await withTimeout(localLink(), 5000);
    } catch (error) {
      await this.stopNetwork();
      this.networkKey = '';
      this.networkIssue = networkError(error as BusinessError);
      this.changed();
      return;
    }
    if (!this.foreground || this.networkGeneration !== generation) return;
    const key = link ? link.netId + ':' + link.address + '/' + link.prefix : '';
    if (!force && key === this.networkKey) return;
    this.networkKey = key;
    await this.stopNetwork();
    if (!this.foreground || this.networkGeneration !== generation) return;
    if (!link) {
      this.networkIssue = 'no_network';
      this.changed();
      return;
    }
    const lan = this.lan;
    const receiver = this.receiver;
    if (!lan || !receiver) return;
    try {
      this.networkIssue = '';
      this.changed();
      await lan.start(link, (channel, address) => receiver.serve(channel, address));
      if (!this.foreground || generation !== this.networkGeneration || this.networkIssue) {
        await this.stopNetwork();
        return;
      }
      receiver.start();
      this.ready = true;
    } catch (error) {
      await this.stopNetwork();
      this.networkIssue = networkError(error as BusinessError);
    }
    this.changed();
  }

  private async stopNetwork(): Promise<void> {
    this.ready = false;
    this.selectedId = '';
    this.sender?.cancel('interrupted');
    this.changed();
    await Promise.all([this.receiver?.stop(), this.lan?.stop()]);
  }

  private remember(peer: Peer): void {
    if (this.history.has(peer.id)) return;
    this.history.add(peer.id);
    const ids = Array.from(this.history);
    if (ids.length > 256) this.history.delete(ids[0]);
    try {
      this.prefs?.putSync('fingerprints', JSON.stringify(Array.from(this.history)));
      this.prefs?.flush().catch(() => {});
    } catch (_) {}
    this.changed();
  }

  private incomingChanged(session: Incoming): void {
    if (session.state === SessionState.Waiting && this.shownIncoming !== session.id) {
      this.shownIncoming = session.id;
      this.receiving = true;
      this.notice = '';
    }
    this.changed();
  }

  private changed(): void {
    if (this.notifyTimer !== -1) return;
    this.notifyTimer = setTimeout(() => {
      this.notifyTimer = -1;
      this.observer?.(this.view());
    }, 70);
  }

  private busy(): boolean {
    return this.receiver?.busy === true || this.sender?.current?.running === true;
  }

  private view(): AppView {
    const view = new AppView();
    view.localName = this.name;
    view.ready = this.ready;
    view.networkIssue = this.networkIssue;
    view.notice = this.notice;
    view.receive = this.receiving;
    view.picking = this.picking;
    view.busy = this.busy();
    view.checking = this.checking;
    view.downloadAuthorized = this.files?.canSave === true;
    view.draft = this.draft.map(file => file.spec);
    view.peers = (this.lan?.peers ?? []).map(peer => {
      const nearby: Nearby = { id: peer.id, name: peer.name, platform: peer.platform, familiar: this.history.has(peer.id) };
      return nearby;
    });
    const selected = this.lan?.peers.find(peer => peer.id === this.selectedId);
    view.selectedId = selected?.id ?? '';
    view.selectedName = selected?.name ?? '';
    const outgoing = this.sender?.current;
    if (this.showOutgoing && outgoing) view.outgoing = this.outgoingView(outgoing);
    const incoming = this.receiver?.current;
    if (incoming) {
      view.incoming = taskView(incoming.id, incoming.peer.name, incoming.state, incoming.files);
      view.incoming.pending = active(incoming.state) || incoming.upload !== undefined;
    }
    return view;
  }

  private outgoingView(job: Outgoing): TaskView {
    const task = taskView(job.requestId, job.peer.name, job.state, job.files);
    task.pending = job.running;
    task.preparing = job.preparing;
    task.unknown = job.unconfirmed.size > 0;
    task.error = job.error;
    return task;
  }

  tab(receive: boolean): void {
    this.receiving = receive;
    this.notice = '';
    this.changed();
  }

  choose(id: string): void {
    if (!this.ready || this.busy()) return;
    this.selectedId = id;
    this.changed();
  }

  async pick(): Promise<void> {
    if (!this.files || this.picking || this.busy() || this.draft.length >= MAX_FILES) return;
    this.picking = true;
    this.notice = '';
    this.changed();
    try {
      const picked = await this.files.pick(MAX_FILES - this.draft.length);
      const uris = new Set(this.draft.map(file => file.uri));
      for (const file of picked.files) {
        if (uris.has(file.uri)) continue;
        this.draft.push(file);
        uris.add(file.uri);
      }
      if (picked.skipped) this.notice = 'source_unreadable';
    } catch (_) {
      this.notice = 'source_unreadable';
    } finally {
      this.picking = false;
      this.changed();
    }
  }

  remove(id: string): void {
    if (this.busy()) return;
    this.draft = this.draft.filter(file => file.spec.id !== id);
    this.changed();
  }

  newDraft(): void {
    if (this.busy() || this.checking) return;
    this.showOutgoing = false;
    this.draft = [];
    this.selectedId = '';
    this.notice = '';
    this.changed();
  }

  async send(): Promise<void> {
    const peer = this.lan?.peers.find(item => item.id === this.selectedId);
    if (!peer || this.draft.length === 0) return;
    await this.startSend(peer, this.draft.slice());
  }

  private async startSend(peer: Peer, files: PickedFile[]): Promise<void> {
    if (!this.ready || !this.sender || this.picking || this.busy()) return;
    this.notice = '';
    this.showOutgoing = true;
    try {
      await this.sender.send(peer, files);
    } catch (error) {
      this.notice = error instanceof TransferError ? error.code : 'interrupted';
    } finally {
      this.changed();
    }
  }

  cancelOutgoing(): void {
    this.sender?.cancel();
  }

  async authorize(): Promise<boolean> {
    if (!this.files || this.picking) return false;
    this.picking = true;
    this.notice = '';
    this.changed();
    try {
      const allowed = await this.files.authorize();
      if (!allowed) this.notice = 'download_permission';
      return allowed;
    } catch (error) {
      this.notice = error instanceof TransferError ? error.code : 'download_permission';
      return false;
    } finally {
      this.picking = false;
      this.changed();
    }
  }

  async decide(accept: boolean): Promise<void> {
    const session = this.receiver?.current;
    if (!session || session.state !== SessionState.Waiting || this.picking) return;
    if (accept && !await this.authorize()) return;
    this.receiver?.decide(session, accept);
  }

  cancelIncoming(): void {
    const session = this.receiver?.current;
    if (session) this.receiver?.cancel(session).catch(() => {});
  }

  async checkResult(): Promise<boolean> {
    const job = this.sender?.current;
    if (!job || job.running || this.checking || this.busy() || !this.ready) return false;
    const peer = this.lan?.peers.find(item => item.id === job.peer.id);
    if (!peer) {
      this.notice = 'offline';
      this.changed();
      return false;
    }
    this.checking = true;
    this.notice = '';
    this.changed();
    try {
      const resolved = await this.sender?.reconcile(job, peer);
      if (!resolved) this.notice = 'unknown_result';
      return resolved === true;
    } finally {
      this.checking = false;
      this.changed();
    }
  }

  async retry(checked: boolean = false): Promise<void> {
    const job = this.sender?.current;
    if (!job || job.running || this.checking || this.busy() || !this.ready) return;
    if (job.unconfirmed.size > 0 && !checked && !await this.checkResult()) return;
    const peer = this.lan?.peers.find(item => item.id === job.peer.id);
    if (!peer) {
      this.notice = 'offline';
      this.changed();
      return;
    }
    const files = job.remaining.map(source => source as PickedFile);
    if (files.length) await this.startSend(peer, files);
  }

  async open(file: SavedFile): Promise<void> {
    try {
      await this.files?.open(file);
    } catch (_) {
      this.notice = 'open_failed';
      this.changed();
    }
  }

  async share(file: SavedFile): Promise<void> {
    try {
      await this.files?.share(file);
    } catch (_) {
      this.notice = 'share_failed';
      this.changed();
    }
  }
}

let app: TransferApp | undefined;

export function registerApp(value?: TransferApp): void {
  app = value;
}

export function currentApp(): TransferApp | undefined {
  return app;
}
