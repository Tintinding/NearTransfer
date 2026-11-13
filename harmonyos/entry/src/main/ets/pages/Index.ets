import { AppView, currentApp, FileView, Nearby, TaskView, TransferApp } from '../TransferApp';
import { FileSpec, FileState, MAX_FILES, SessionState } from '../core/Protocol';

const INK = '#142C25';
const MUTED = '#50665E';
const GREEN = '#176045';
const LINE = '#DCE7E0';
const SOFT = '#E6F2EB';
const PAGE = '#F3F7F5';

function sizeLabel(bytes: number): string {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

function message(code: string): string {
  switch (code) {
    case 'no_network': return '请连接与另一台设备相同的 Wi-Fi。';
    case 'network_permission': return '近传无法访问局域网。请在系统设置检查近传的 WLAN 联网权限，再重新检查。';
    case 'network_failed': return '局域网服务未能启动。请检查 WLAN 权限、Wi-Fi 和路由器的设备隔离设置。';
    case 'offline': return '设备当前不可连接。请让对方打开近传并连接同一个 Wi-Fi。';
    case 'identity_failed': return '设备身份无法初始化。请重新打开近传。';
    case 'sender_not_discovered': return '接收方还没发现此设备。请在接收端等到设备出现后重试。';
    case 'certificate_changed': return '设备证书与发现信息不符，连接已中止。请在两端重新打开近传。';
    case 'tls_failed':
    case 'unverified_sender': return '未能建立已核验的加密连接。请检查两端是否在线。';
    case 'busy': return '对方正在处理另一笔传输，请稍后重试。';
    case 'declined': return '接收请求已拒绝。';
    case 'canceled': return '传输已取消。';
    case 'expired': return '接收请求或会话已过期。';
    case 'timeout': return '等待超时。请确认另一台设备在线。';
    case 'download_permission': return '请允许近传保存到系统「下载」后再接收。';
    case 'source_unreadable':
    case 'source_changed': return '文件无法读取或大小已变化，请重新选择本地文件。';
    case 'no_space': return '接收设备存储空间不足，请清理空间后重试未完成的文件。';
    case 'storage_failed': return '接收端无法保存文件，请检查下载目录。';
    case 'digest_mismatch':
    case 'length_mismatch': return '文件完整性校验失败。';
    case 'unknown_result': return '暂时无法核对结果。请在接收端查看已保存的文件。';
    case 'open_failed': return '系统未能打开该文件，可在「文件管理」的下载目录查看。';
    case 'share_failed': return '系统未能分享该文件，可在「文件管理」的下载目录查看。';
    case 'invalid_manifest':
    case 'control_too_large': return '文件清单超出可发送范围，请减少选中的文件。';
    default: return '传输中断。请检查两台设备的网络连接后重试。';
  }
}

function title(task: TaskView, receiving: boolean): string {
  if (task.preparing) return '正在校验源文件';
  switch (task.state) {
    case SessionState.Waiting: return receiving ? '确认接收' : '等待对方确认';
    case SessionState.Accepted: return receiving ? '正在接收' : '正在发送';
    case SessionState.Completed: return receiving ? '接收完成' : '发送完成';
    case SessionState.Partial: return '部分文件已完成';
    case SessionState.Declined: return '请求已拒绝';
    case SessionState.Canceled: return '传输已取消';
    case SessionState.Expired: return '请求已超时';
    default: return '传输未完成';
  }
}

function fileStatus(file: FileView): string {
  if (file.state === FileState.Committed) return file.savedName ? '已保存为 ' + file.savedName : '已完成';
  if (file.state === FileState.Uploading) return '传输中';
  if (file.error) return message(file.error);
  return sizeLabel(file.size);
}

function platformLabel(platform: string): string {
  if (platform === 'harmonyos') return 'HarmonyOS';
  if (platform === 'android') return 'Android';
  if (platform === 'windows') return 'Windows';
  if (platform === 'macos') return 'macOS';
  if (platform === 'ios') return 'iOS / iPadOS';
  return platform;
}

interface Label {
  text: string;
}

interface TaskParameters {
  task: TaskView;
  receiving: boolean;
}

@Entry
@Component
struct Index {
  @State view: AppView = new AppView();
  private app?: TransferApp;

  aboutToAppear(): void {
    this.app = currentApp();
    this.app?.observe(view => { this.view = view; });
  }

  aboutToDisappear(): void {
    this.app?.observe();
  }

  private confirmRetry(): void {
    if (!this.view.outgoing?.unknown) {
      this.app?.retry();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '核对接收结果',
      message: '部分文件的回执未确认。请在接收设备查看文件，确认确实缺少待重试的文件后再发送。',
      primaryButton: { value: '返回', action: () => {} },
      secondaryButton: { value: '已核对，继续重试', action: () => { this.app?.retry(true); } }
    });
  }

  @Builder
  tab(label: string, receive: boolean) {
    Button(label)
      .layoutWeight(1)
      .height(44)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.view.receive === receive ? Color.White : GREEN)
      .backgroundColor(this.view.receive === receive ? GREEN : SOFT)
      .borderRadius(10)
      .onClick(() => { this.app?.tab(receive); })
  }

  @Builder
  hint(label: Label) {
    Text(label.text)
      .fontSize(14)
      .fontColor(MUTED)
      .lineHeight(21)
      .width('100%')
  }

  @Builder
  heading(label: Label) {
    Text(label.text)
      .fontSize(22)
      .fontWeight(FontWeight.Bold)
      .fontColor(INK)
      .width('100%')
  }

  @Builder
  draftFiles() {
    Column({ space: 10 }) {
      Row() {
        Text('选择文件')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .layoutWeight(1)
        Button('添加文件')
          .height(44)
          .fontColor(GREEN)
          .backgroundColor(SOFT)
          .enabled(!this.view.picking && !this.view.busy && this.view.draft.length < MAX_FILES)
          .onClick(() => { this.app?.pick(); })
      }.width('100%')
      if (this.view.draft.length === 0) {
        this.hint({ text: '从系统文件选择器添加一个或多个文件。' })
      } else {
        this.hint({ text: this.view.draft.length + ' 个文件 · ' +
          sizeLabel(this.view.draft.reduce((sum: number, file: FileSpec) => sum + file.size, 0)) })
        ForEach(this.view.draft, (file: FileSpec) => {
          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text(file.name).fontColor(INK).fontSize(16).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(sizeLabel(file.size)).fontColor(MUTED).fontSize(13)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button('移除')
              .height(44)
              .fontSize(14)
              .fontColor(GREEN)
              .backgroundColor(SOFT)
              .enabled(!this.view.busy)
              .onClick(() => { this.app?.remove(file.id); })
          }.width('100%')
        }, (file: FileSpec) => file.id)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Color.White)
    .border({ width: 1, color: LINE })
    .borderRadius(14)
  }

  @Builder
  peers() {
    Column({ space: 10 }) {
      Text('附近设备')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
      if (!this.view.ready || this.view.peers.length === 0) {
        this.hint({ text: '请确认两台设备都已打开近传，并连接同一个局域网。' })
      } else {
        ForEach(this.view.peers, (peer: Nearby) => {
          Button() {
            Row({ space: 8 }) {
              Column({ space: 4 }) {
                Text(peer.name)
                  .fontColor(INK)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(platformLabel(peer.platform) + (peer.familiar ? ' · 传过文件' : ''))
                  .fontSize(13)
                  .fontColor(MUTED)
                  .maxLines(1)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              if (this.view.selectedId === peer.id) {
                Text('已选中').fontColor(GREEN).fontSize(14)
              }
            }.padding({ left: 14, right: 14 }).width('100%')
          }
          .width('100%')
          .height(60)
          .borderRadius(10)
          .backgroundColor(this.view.selectedId === peer.id ? '#D7EDDF' : PAGE)
          .border({ width: 1, color: this.view.selectedId === peer.id ? GREEN : LINE })
          .enabled(!this.view.busy)
          .onClick(() => { this.app?.choose(peer.id); })
        }, (peer: Nearby) => peer.id + ':' + peer.name + ':' + peer.familiar)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Color.White)
    .border({ width: 1, color: LINE })
    .borderRadius(14)
  }

  @Builder
  task(params: TaskParameters) {
    Column({ space: 12 }) {
      this.heading({ text: title(params.task, params.receiving) })
      this.hint({ text: (params.receiving ? '来自 ' : '发送给 ') + params.task.peer + ' · ' +
        params.task.files.length + ' 个文件 · ' + sizeLabel(params.task.total) })
      if (params.task.preparing) {
        this.hint({ text: params.task.preparing })
      }
      if (params.task.state === SessionState.Accepted || !params.task.pending) {
        Progress({
          value: params.task.total === 0 ? params.task.committed * 100 / params.task.files.length :
            params.task.bytes * 100 / params.task.total,
          total: 100,
          type: ProgressType.Linear
        }).color(GREEN).backgroundColor(LINE).width('100%')
        this.hint({ text: sizeLabel(params.task.bytes) + ' / ' + sizeLabel(params.task.total) +
          ' · 已完成 ' + params.task.committed + ' 个' })
      }
      if (params.task.error) {
        this.hint({ text: message(params.task.error) })
      }
      if (!params.task.pending && params.task.unknown) {
        this.hint({ text: '部分文件结果待核对。' })
      }
      ForEach(params.task.files, (file: FileView) => {
        Column({ space: 6 }) {
          Text(file.name).fontSize(16).fontColor(INK).maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          this.hint({ text: fileStatus(file) })
          if (file.saved) {
            Row({ space: 10 }) {
              Button('打开').height(44).fontColor(GREEN).backgroundColor(SOFT)
                .onClick(() => { if (file.saved) this.app?.open(file.saved); })
              Button('分享').height(44).fontColor(GREEN).backgroundColor(SOFT)
                .onClick(() => { if (file.saved) this.app?.share(file.saved); })
            }.width('100%')
          }
        }.padding(12).borderRadius(10).backgroundColor(PAGE).width('100%')
      }, (file: FileView) => file.id + ':' + file.state + ':' + file.error + ':' + file.savedName)
      if (params.receiving && params.task.committed > 0) {
        this.hint({ text: '位置：文件管理 → 下载 → 近传的应用目录' })
      }
      if (params.receiving && params.task.state === SessionState.Waiting) {
        if (!this.view.downloadAuthorized) {
          this.hint({ text: '首次接收时，系统会询问是否允许近传使用下载目录。' })
        }
        Row({ space: 10 }) {
          Button('拒绝').layoutWeight(1).height(48).fontColor(GREEN).backgroundColor(SOFT)
            .enabled(!this.view.picking)
            .onClick(() => { this.app?.decide(false); })
          Button('接受').layoutWeight(1).height(48).backgroundColor(GREEN)
            .enabled(!this.view.picking && this.view.ready)
            .onClick(() => { this.app?.decide(true); })
        }.width('100%')
      } else if (params.task.pending) {
        Button('取消传输').height(48).width('100%').fontColor(GREEN).backgroundColor(SOFT)
          .onClick(() => {
            if (params.receiving) this.app?.cancelIncoming();
            else this.app?.cancelOutgoing();
          })
      } else if (!params.receiving) {
        if (params.task.committed < params.task.files.length) {
          if (params.task.unknown) {
            Button('核对接收结果').height(48).width('100%').fontColor(GREEN).backgroundColor(SOFT)
              .enabled(this.view.ready && !this.view.busy && !this.view.checking)
              .onClick(() => { this.app?.checkResult(); })
          }
          Button('重试未完成的文件').height(48).width('100%').backgroundColor(GREEN)
            .enabled(this.view.ready && !this.view.busy && !this.view.checking)
            .onClick(() => { this.confirmRetry(); })
        }
        Button('新传输').height(48).width('100%').fontColor(GREEN).backgroundColor(SOFT)
          .enabled(!this.view.busy && !this.view.checking)
          .onClick(() => { this.app?.newDraft(); })
      }
    }
    .padding(16)
    .width('100%')
    .backgroundColor(Color.White)
    .border({ width: 1, color: LINE })
    .borderRadius(14)
  }

  @Builder
  receive() {
    if (this.view.incoming) {
      this.task({ task: this.view.incoming, receiving: true })
    } else {
      this.heading({ text: '等待接收' })
      this.hint({ text: '保持近传在前台。收到请求时，可先查看设备和文件清单。' })
    }
    if (!this.view.downloadAuthorized && this.view.incoming?.pending !== true) {
      Button('授权保存到下载')
        .height(48)
        .fontColor(GREEN)
        .backgroundColor(SOFT)
        .enabled(!this.view.picking && !this.view.busy)
        .onClick(() => { this.app?.authorize(); })
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('↔')
          .fontSize(23)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width(44)
          .height(44)
          .backgroundColor(GREEN)
          .borderRadius(12)
        Text('近传')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .layoutWeight(1)
        Column({ space: 2 }) {
          Text(this.view.localName)
            .fontSize(14).fontColor(INK).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.view.ready ? '局域网已连接' : '局域网未就绪').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.End).constraintSize({ maxWidth: 190 })
      }.width('100%')
      Row({ space: 6 }) {
        this.tab('发送', false)
        this.tab('接收', true)
      }.width('100%').padding(4).backgroundColor(SOFT).borderRadius(12)
      Scroll() {
        Column({ space: 12 }) {
          this.hint({ text: '近传使用局域网发现附近设备，并在两台设备间直接传输文件。' })
          if (this.view.networkIssue) {
            Column({ space: 8 }) {
              this.hint({ text: message(this.view.networkIssue) })
              Button('重新检查')
                .height(44).fontColor(GREEN).backgroundColor(SOFT)
                .enabled(!this.view.busy)
                .onClick(() => { this.app?.refresh(); })
            }.width('100%').padding(12).backgroundColor(Color.White).borderRadius(10)
          }
          if (this.view.notice) {
            this.hint({ text: message(this.view.notice) })
          }
          if (this.view.receive) {
            this.receive()
          } else if (this.view.outgoing) {
            this.task({ task: this.view.outgoing, receiving: false })
          } else {
            this.draftFiles()
            this.peers()
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 8 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      if (!this.view.receive && !this.view.outgoing) {
        Button(this.view.selectedName ? '发送给 ' + this.view.selectedName : '发送')
          .width('100%').height(50).backgroundColor(GREEN).fontSize(17)
          .enabled(this.view.ready && !this.view.busy && !this.view.picking &&
            this.view.draft.length > 0 && this.view.selectedId !== '')
          .onClick(() => { this.app?.send(); })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(PAGE)
  }
}
