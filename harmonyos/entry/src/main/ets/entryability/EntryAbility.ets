import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { registerApp, TransferApp } from '../TransferApp';

export default class EntryAbility extends UIAbility {
  private app?: TransferApp;

  onCreate(): void {
    this.app = new TransferApp(this.context);
    registerApp(this.app);
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index').catch(() => {
      hilog.error(0, 'NearTransfer', 'Could not load main page');
    });
  }

  onForeground(): void {
    this.app?.setForeground(true);
  }

  onBackground(): void {
    this.app?.setForeground(false);
  }

  onDestroy(): void {
    this.app?.setForeground(false);
    registerApp();
  }
}
