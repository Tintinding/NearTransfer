import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cert } from '@kit.DeviceCertificateKit';
import { connection, mdns, socket } from '@kit.NetworkKit';
import { ByteQueue, Channel } from '../core/Http';
import {
  Cancellation, checkPin, isDigest, isPort, onSubnet, Peer, SERVICE_TYPE, TransferError, withTimeout
} from '../core/Protocol';
import { certificateDer, fingerprint, Identity, utf8 } from './Identity';

const PROTOCOLS = [socket.Protocol.TLSv12, socket.Protocol.TLSv13];
const CONNECTION_LIMIT = 16;

export interface Link {
  netId: number;
  address: string;
  prefix: number;
}

export async function localLink(): Promise<Link | undefined> {
  let ethernet: Link | undefined;
  for (const net of await connection.getAllNets()) {
    try {
      const caps = await connection.getNetCapabilities(net);
      const wifi = caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI);
      if (!wifi && !caps.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) continue;
      const properties = await connection.getConnectionProperties(net);
      for (const link of properties.linkAddresses) {
        const address = link.address.address;
        if (!onSubnet(address, address, link.prefixLength)) continue;
        const local: Link = { netId: net.netId, address: address, prefix: link.prefixLength };
        if (wifi) return local;
        ethernet = local;
      }
    } catch (error) {
      // A handle can disappear while switching networks.
      if (networkError(error as BusinessError) === 'network_permission') {
        throw new TransferError('network_permission', 403);
      }
    }
  }
  return ethernet;
}

export function networkError(error: BusinessError): string {
  if (error instanceof TransferError && error.code === 'network_permission') return error.code;
  return [201, 2300003, 2301001, 2301013].includes(error.code) ? 'network_permission' : 'network_failed';
}

class TlsChannel implements Channel {
  readonly input = new ByteQueue();
  private sendData: (bytes: ArrayBuffer) => Promise<void>;
  private dispose: () => void;
  private closed = false;

  constructor(sendData: (bytes: ArrayBuffer) => Promise<void>, dispose: () => void) {
    this.sendData = sendData;
    this.dispose = dispose;
  }

  receive(info: socket.SocketMessageInfo): void {
    if (!this.input.push(new Uint8Array(info.message))) this.close();
  }

  end(): void {
    this.input.end();
  }

  async send(bytes: Uint8Array): Promise<void> {
    if (this.closed) throw new TransferError('interrupted', 408);
    const data = bytes.byteOffset === 0 && bytes.length === bytes.buffer.byteLength ?
      bytes.buffer : bytes.slice().buffer;
    try {
      await this.sendData(data);
    } catch (error) {
      const code = networkError(error as BusinessError) === 'network_permission' ? 'network_permission' : 'interrupted';
      throw new TransferError(code, 408);
    }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.input.abort(new TransferError('interrupted', 408));
    try { this.dispose(); } catch (_) {}
  }
}

export class Lan {
  port = 0;
  peers: Peer[] = [];
  private link?: Link;
  private server?: socket.TLSSocketServer;
  private discovery?: mdns.DiscoveryService;
  private published?: mdns.LocalServiceInfo;
  private incoming = new Set<TlsChannel>();
  private outgoing = new Set<TlsChannel>();
  private found = new Map<string, number>();
  private resolved = new Map<string, Peer>();
  private ticket = 0;
  private context: common.UIAbilityContext;
  private identity: Identity;
  private name: string;
  private changed: () => void;
  private failed: (code: string) => void;

  constructor(context: common.UIAbilityContext, identity: Identity, name: string,
    changed: () => void, failed: (code: string) => void) {
    this.context = context;
    this.identity = identity;
    this.name = name;
    this.changed = changed;
    this.failed = failed;
  }

  async start(link: Link, serve: (channel: Channel, address: string) => Promise<void>): Promise<void> {
    this.link = link;
    const server = socket.constructTLSSocketServerInstance();
    this.server = server;
    server.on('connect', (client: socket.TLSSocketConnection) => {
      this.accept(server, client, link, serve);
    });
    server.on('error', (error: BusinessError) => {
      if (this.server !== server || this.port === 0) return;
      const code = networkError(error);
      if (code === 'network_permission') {
        this.failed(code);
        return;
      }
      // The server also reports individual client send and close failures.
      server.getState().then(state => {
        if (this.server === server && (!state.isBound || state.isClose)) this.failed(code);
      }).catch(() => {});
    });
    await withTimeout(server.listen({
      address: { address: link.address, port: 0, family: 1 },
      secureOptions: {
        cert: this.identity.cert,
        key: this.identity.key,
        protocols: PROTOCOLS,
        isBidirectionalAuthentication: false
      }
    }));
    const address = await withTimeout(server.getLocalAddress());
    if (!isPort(address.port) || address.port === undefined) throw new TransferError('network_failed');
    this.port = address.port;
    await this.advertise(link);
    await this.search(link);
  }

  private accept(server: socket.TLSSocketServer, client: socket.TLSSocketConnection, link: Link,
    serve: (channel: Channel, address: string) => Promise<void>): void {
    if (server !== this.server || this.incoming.size >= CONNECTION_LIMIT) {
      client.close().catch(() => {});
      return;
    }
    const channel = new TlsChannel(data => client.send(data), () => {
      this.incoming.delete(channel);
      client.close().catch(() => {});
      client.off('message');
      client.off('close');
      client.off('error');
    });
    this.incoming.add(channel);
    client.on('message', info => channel.receive(info));
    client.on('close', () => channel.end());
    client.on('error', () => channel.end());
    withTimeout(client.getRemoteAddress()).then(async (address: socket.NetAddress) => {
      if (server !== this.server || !onSubnet(address.address, link.address, link.prefix)) return;
      await serve(channel, address.address);
    }).catch(() => {}).finally(() => channel.close());
  }

  async dial(peer: Peer, stop: Cancellation): Promise<Channel> {
    const link = this.link;
    if (!link || !isPort(peer.port) || !onSubnet(peer.address, link.address, link.prefix)) {
      throw new TransferError('offline', 503);
    }
    stop.check();
    const tls = socket.constructTLSSocketInstance();
    const channel = new TlsChannel(data => tls.send(data), () => {
      this.outgoing.delete(channel);
      tls.close().catch(() => {});
      tls.off('message');
      tls.off('close');
      tls.off('error');
    });
    this.outgoing.add(channel);
    tls.on('message', info => channel.receive(info));
    tls.on('close', () => channel.end());
    tls.on('error', () => channel.end());
    const unwatch = stop.watch(() => channel.close());
    try {
      await withTimeout(tls.bind({ address: link.address, port: 0, family: 1 }), 5000);
      stop.check();
      // v1 peers have self-signed certificates. Check the actual leaf on this
      // socket before returning it to any HTTP code.
      await withTimeout(tls.connect({
        address: { address: peer.address, port: peer.port, family: 1 },
        secureOptions: { protocols: PROTOCOLS },
        skipRemoteValidation: true
      }), 5000);
      const remote = await withTimeout(tls.getRemoteCertificate(), 5000);
      let der: Uint8Array;
      if (remote.encodingFormat === cert.EncodingFormat.FORMAT_DER) der = remote.data;
      else if (remote.encodingFormat === cert.EncodingFormat.FORMAT_PEM) der = certificateDer(utf8.decode(remote.data));
      else throw new TransferError('tls_failed');
      checkPin(peer.id, fingerprint(der));
      stop.check();
      if (this.link !== link) throw new TransferError('interrupted');
      return channel;
    } catch (error) {
      channel.close();
      if (error instanceof TransferError) throw error;
      const code = networkError(error as BusinessError) === 'network_permission' ? 'network_permission' : 'tls_failed';
      throw new TransferError(code);
    } finally {
      unwatch();
    }
  }

  private async advertise(link: Link): Promise<void> {
    const info: mdns.LocalServiceInfo = {
      serviceType: SERVICE_TYPE,
      serviceName: 'NearTransfer-' + this.identity.id.slice(0, 16),
      port: this.port,
      host: { address: link.address, family: 1 },
      serviceAttribute: [
        { key: 'v', value: [49] },
        { key: 'id', value: Array.from(utf8.encode(this.identity.id)) },
        { key: 'name', value: Array.from(utf8.encode(this.name)) },
        { key: 'platform', value: Array.from(utf8.encode('harmonyos')) }
      ]
    };
    await withTimeout(mdns.addLocalService(this.context, info).then(async published => {
      if (this.link === link) this.published = published;
      else await mdns.removeLocalService(this.context, published).catch(() => {});
    }));
  }

  private async search(link: Link): Promise<void> {
    const discovery = mdns.createDiscoveryService(this.context, SERVICE_TYPE);
    this.discovery = discovery;
    discovery.on('serviceFound', info => { this.resolve(discovery, link, info); });
    discovery.on('serviceLost', info => {
      this.found.delete(info.serviceName);
      this.resolved.delete(info.serviceName);
      this.updatePeers();
    });
    discovery.on('discoveryStop', () => {
      if (discovery === this.discovery) this.failed('network_failed');
    });
    try {
      await withTimeout(new Promise<void>((resolve, reject) => {
        discovery.on('discoveryStart', info => {
          if (info.errorCode === undefined) resolve();
          else reject(new TransferError('network_failed'));
        });
        discovery.startSearchingMDNS();
      }));
    } finally {
      discovery.off('discoveryStart');
    }
  }

  private resolve(discovery: mdns.DiscoveryService, link: Link, info: mdns.LocalServiceInfo): void {
    if (discovery !== this.discovery ||
      (this.found.size >= 256 && !this.found.has(info.serviceName))) return;
    const ticket = ++this.ticket;
    this.found.set(info.serviceName, ticket);
    withTimeout(mdns.resolveLocalService(this.context, info)).then(service => {
      if (discovery !== this.discovery || this.found.get(info.serviceName) !== ticket) return;
      const address = service.host?.address ?? '';
      const port = service.port;
      const txt = new Map<string, string>();
      for (const item of service.serviceAttribute ?? []) {
        txt.set(item.key.toLowerCase(), utf8.decode(new Uint8Array(item.value)));
      }
      const id = txt.get('id') ?? '';
      const name = txt.get('name') ?? '';
      if (txt.get('v') === '1' && isDigest(id) && id !== this.identity.id &&
        name.trim() && utf8.encode(name).length <= 120 && port !== undefined && isPort(port) &&
        onSubnet(address, link.address, link.prefix)) {
        const peer: Peer = { id: id, name: name, address: address, port: port, platform: txt.get('platform') ?? '' };
        this.resolved.set(info.serviceName, peer);
      } else {
        this.resolved.delete(info.serviceName);
      }
      this.updatePeers();
    }).catch(() => {});
  }

  private updatePeers(): void {
    const unique = new Map<string, Peer>();
    for (const peer of this.resolved.values()) unique.set(peer.id, peer);
    this.peers = Array.from(unique.values()).sort((a, b) => a.name.localeCompare(b.name));
    this.changed();
  }

  async stop(): Promise<void> {
    this.link = undefined;
    this.port = 0;
    const discovery = this.discovery;
    this.discovery = undefined;
    if (discovery) {
      discovery.off('serviceFound');
      discovery.off('serviceLost');
      discovery.off('discoveryStop');
      try { discovery.stopSearchingMDNS(); } catch (_) {}
    }
    this.found.clear();
    this.resolved.clear();
    this.updatePeers();
    const server = this.server;
    this.server = undefined;
    for (const channel of Array.from(this.incoming)) channel.close();
    for (const channel of Array.from(this.outgoing)) channel.close();
    const published = this.published;
    this.published = undefined;
    if (published) await withTimeout(mdns.removeLocalService(this.context, published), 3000).catch(() => {});
    if (server) {
      server.off('connect');
      server.off('error');
      await withTimeout(server.close(), 3000).catch(() => {});
    }
  }
}
