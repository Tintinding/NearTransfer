import { common, wantConstant, Want } from '@kit.AbilityKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import {
  Crypto, FileSpec, isSize, MAX_FILES, numberedName, Reader, safeName, SavedFile,
  Source, Storage, Target, TransferError
} from '../core/Protocol';
import { utf8 } from './Identity';

const NOT_FOUND = 13900002;
const FILE_EXISTS = 13900015;
const NO_SPACE = 13900025;
const ACCESS_DENIED = 13900012;
const NOT_PERMITTED = 13900001;

export class PickedFile implements Source {
  readonly uri: string;
  readonly spec: FileSpec;

  constructor(uri: string, spec: FileSpec) {
    this.uri = uri;
    this.spec = spec;
  }

  async open(): Promise<Reader> {
    let file: fs.File | undefined;
    try {
      file = await fs.open(this.uri, fs.OpenMode.READ_ONLY);
      const stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size !== this.spec.size) throw new TransferError('source_changed');
      return new FileReader(file);
    } catch (error) {
      if (file) await fs.close(file).catch(() => {});
      throw error instanceof TransferError ? error : new TransferError('source_unreadable');
    }
  }
}

class FileReader implements Reader {
  private file: fs.File;

  constructor(file: fs.File) {
    this.file = file;
  }

  async read(max: number): Promise<Uint8Array> {
    try {
      const buffer = new ArrayBuffer(max);
      const count = await fs.read(this.file.fd, buffer);
      return new Uint8Array(buffer, 0, count);
    } catch (_) {
      throw new TransferError('source_unreadable');
    }
  }

  async close(): Promise<void> {
    await fs.close(this.file);
  }
}

function storageError(error: BusinessError): TransferError {
  if (error.code === NO_SPACE) return new TransferError('no_space', 422);
  if (error.code === ACCESS_DENIED || error.code === NOT_PERMITTED) {
    return new TransferError('download_permission', 422);
  }
  return new TransferError('storage_failed', 422);
}

class DownloadTarget implements Target {
  private file?: fs.File;
  private staging: string;
  private directory: string;
  private name: string;

  constructor(file: fs.File, staging: string, directory: string, name: string) {
    this.file = file;
    this.staging = staging;
    this.directory = directory;
    this.name = name;
  }

  async write(bytes: Uint8Array): Promise<void> {
    const file = this.file;
    if (!file) throw new TransferError('storage_failed');
    try {
      let remaining = bytes;
      while (remaining.length) {
        const buffer = remaining.byteOffset === 0 && remaining.byteLength === remaining.buffer.byteLength ?
          remaining.buffer : remaining.slice().buffer;
        const count = await fs.write(file.fd, buffer);
        if (count <= 0 || count > remaining.length) throw new TransferError('storage_failed');
        remaining = remaining.subarray(count);
      }
    } catch (error) {
      throw error instanceof TransferError ? error : storageError(error as BusinessError);
    }
  }

  async commit(): Promise<SavedFile> {
    const file = this.file;
    if (!file) throw new TransferError('storage_failed');
    try {
      await fs.fsync(file.fd);
      await fs.close(file);
      this.file = undefined;
      for (let i = 0; i < 10000; i++) {
        const name = numberedName(this.name, i);
        const path = this.directory + '/' + name;
        if (await fs.access(path)) continue;
        try {
          await fs.moveFile(this.staging, path, 1);
          return { name: name, path: path };
        } catch (error) {
          if ((error as BusinessError).code !== FILE_EXISTS) throw storageError(error as BusinessError);
        }
      }
      throw new TransferError('storage_failed');
    } catch (error) {
      throw error instanceof TransferError ? error : storageError(error as BusinessError);
    }
  }

  async rollback(): Promise<void> {
    if (this.file) {
      await fs.close(this.file).catch(() => {});
      this.file = undefined;
    }
    await fs.unlink(this.staging);
  }
}

export interface Selection {
  files: PickedFile[];
  skipped: number;
}

export class Files implements Storage {
  private context: common.UIAbilityContext;
  private crypto: Crypto;
  private stagingName: string;
  private directory = '';
  private downloadUri = '';

  constructor(context: common.UIAbilityContext, crypto: Crypto, id: string) {
    this.context = context;
    this.crypto = crypto;
    this.stagingName = '.neartransfer-' + id.slice(0, 16);
  }

  get canSave(): boolean {
    return this.directory !== '';
  }

  async pick(limit: number): Promise<Selection> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = Math.min(limit, MAX_FILES);
    const uris = await new picker.DocumentViewPicker(this.context).select(options);
    const result: Selection = { files: [], skipped: 0 };
    for (const uri of uris.slice(0, limit)) {
      let file: fs.File | undefined;
      try {
        file = await fs.open(uri, fs.OpenMode.READ_ONLY);
        const stat = await fs.stat(file.fd);
        const name = new fileUri.FileUri(uri).name;
        if (!stat.isFile() || !isSize(stat.size) || !name.trim() || utf8.encode(name).length > 1024) {
          throw new TransferError('source_unreadable');
        }
        const spec: FileSpec = { id: this.crypto.randomId(), name: name, size: stat.size };
        result.files.push(new PickedFile(uri, spec));
      } catch (_) {
        result.skipped++;
      } finally {
        if (file) await fs.close(file).catch(() => {});
      }
    }
    return result;
  }

  async authorize(): Promise<boolean> {
    if (this.canSave) {
      try {
        if (await fs.access(this.directory, fs.AccessModeType.WRITE)) return true;
      } catch (_) {}
      this.directory = '';
      this.downloadUri = '';
    }
    const options = new picker.DocumentSaveOptions();
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const uris = await new picker.DocumentViewPicker(this.context).save(options);
    if (uris.length === 0) return false;
    const uri = uris[0].replace(/\/$/, '');
    const directory = new fileUri.FileUri(uri).path.replace(/\/$/, '');
    if (!directory.startsWith('/')) throw new TransferError('download_permission');
    try {
      const staging = directory + '/' + this.stagingName;
      if (!await fs.access(staging)) await fs.mkdir(staging);
      await this.clean(staging);
      this.downloadUri = uri;
      this.directory = directory;
      return true;
    } catch (error) {
      throw error instanceof TransferError ? error : storageError(error as BusinessError);
    }
  }

  private async clean(staging: string): Promise<void> {
    const stat = await fs.lstat(staging);
    if (!stat.isDirectory()) throw new TransferError('storage_failed');
    for (const name of await fs.listFile(staging)) {
      if (/^[a-f0-9]{32}\.part$/.test(name)) await fs.unlink(staging + '/' + name).catch(() => {});
    }
  }

  async create(spec: FileSpec): Promise<Target> {
    if (!this.canSave) throw new TransferError('download_permission');
    const path = this.directory + '/' + this.stagingName + '/' + this.crypto.randomId() + '.part';
    try {
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      return new DownloadTarget(file, path, this.directory, safeName(spec.name, utf8));
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code === ACCESS_DENIED || code === NOT_PERMITTED || code === NOT_FOUND) this.directory = '';
      throw storageError(error as BusinessError);
    }
  }

  async open(file: SavedFile): Promise<void> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: this.uri(file),
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    await this.context.startAbility(want);
  }

  async share(file: SavedFile): Promise<void> {
    let type: string = utd.UniformDataType.FILE;
    const dot = file.name.lastIndexOf('.');
    if (dot > 0) type = utd.getUniformDataTypeByFilenameExtension(file.name.slice(dot)) || type;
    const data = new systemShare.SharedData({ utd: type, uri: this.uri(file), title: file.name });
    await new systemShare.ShareController(data).show(this.context, {
      previewMode: systemShare.SharePreviewMode.DETAIL,
      selectionMode: systemShare.SelectionMode.SINGLE
    });
  }

  private uri(file: SavedFile): string {
    if (this.downloadUri) return this.downloadUri + '/' + encodeURIComponent(file.name);
    return fileUri.getUriFromPath(file.path);
  }
}
