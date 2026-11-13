param(
    [string] $Executable = (Join-Path $PSScriptRoot '../release/NearTransfer-Windows-x64.exe'),
    [switch] $Portable
)

$ErrorActionPreference = 'Stop'
if (Get-Process near_transfer -ErrorAction SilentlyContinue) {
    throw 'Exit the running copy of NearTransfer before running this test.'
}
$app = Get-Item -LiteralPath $Executable
$portableLaunch = $Portable -or -not $PSBoundParameters.ContainsKey('Executable')

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class NearTransferTrayTest {
    [StructLayout(LayoutKind.Sequential)]
    private struct IconIdentifier {
        public uint Size;
        public IntPtr Window;
        public uint Id;
        public Guid Guid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo {
        public uint Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public Rect CaretBounds;
    }

    [DllImport("shell32.dll")]
    private static extern int Shell_NotifyIconGetRect(ref IconIdentifier id, out Rect bounds);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
    [DllImport("user32.dll")]
    private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern IntPtr GetLastActivePopup(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

    public static bool HasIcon(IntPtr window) {
        var id = new IconIdentifier {
            Size = (uint)Marshal.SizeOf<IconIdentifier>(), Window = window, Id = 1
        };
        return Shell_NotifyIconGetRect(ref id, out _) == 0;
    }

    public static bool HasPopupMenu(IntPtr window) {
        var info = new GuiThreadInfo { Size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
        return GetGUIThreadInfo(GetWindowThreadProcessId(window, IntPtr.Zero), ref info)
            && info.MenuOwner == window && (info.Flags & 0x10) != 0;
    }
}
'@

function Wait-For([scriptblock] $Condition, [string] $Failure) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Failure
}

function Post-WindowMessage([uint32] $Message, [int] $WParam = 0, [int] $LParam = 0) {
    if (-not [NearTransferTrayTest]::PostMessage($window, $Message, $WParam, $LParam)) {
        throw "Unable to post message $Message to the test window."
    }
}

function Test-HideToTray {
    Post-WindowMessage 0x0010 # WM_CLOSE
    Wait-For {
        -not $process.HasExited -and -not [NearTransferTrayTest]::IsWindowVisible($window) -and
            [NearTransferTrayTest]::HasIcon($window)
    } 'Close did not keep the process alive with a notification area icon.'
}

$process = $null
$launcher = $null
$testDirectory = $null
try {
    if ($portableLaunch) {
        $testDirectory = Join-Path $env:TEMP "近传 独立启动 $([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $testDirectory | Out-Null
        $copy = Join-Path $testDirectory '近传.exe'
        Copy-Item -LiteralPath $app.FullName -Destination $copy
        $launcher = Start-Process -FilePath $copy -WorkingDirectory $testDirectory -PassThru
        if (-not $launcher.WaitForExit(15000) -or $launcher.ExitCode -ne 0) {
            throw 'The standalone launcher did not finish successfully.'
        }
        $child = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($launcher.Id) AND Name = 'near_transfer.exe'"
        if (-not $child) { throw 'The launcher did not start the embedded app.' }
        $process = Get-Process -Id $child.ProcessId
        # Retain a process handle so ExitCode stays available after the child exits.
        [void]$process.Handle
        $local = [Environment]::GetFolderPath('LocalApplicationData')
        $runtime = Join-Path $local 'NearTransfer/runtime'
        $actual = [IO.Path]::GetRelativePath($runtime, $process.Path)
        if ($actual -notmatch '^[a-f0-9]{64}\\near_transfer\.exe$') {
            throw "Unexpected runtime path: $($process.Path)"
        }
    } else {
        $process = Start-Process -FilePath $app.FullName -WorkingDirectory $app.DirectoryName -PassThru
    }
    Wait-For {
        $process.Refresh()
        $process.MainWindowHandle -ne [IntPtr]::Zero
    } 'The Release App window did not appear.'
    if ($portableLaunch) {
        Wait-For {
            Get-NetTCPConnection -OwningProcess $process.Id -State Listen -ErrorAction SilentlyContinue |
                Where-Object LocalAddress -eq '0.0.0.0' | Select-Object -First 1
        } 'The standalone App did not start its IPv4 listener.'
        if (@(Get-ChildItem -LiteralPath $testDirectory -Force).Count -ne 1) {
            throw 'The launcher created files beside the standalone EXE.'
        }
        "Standalone EXE started from an otherwise empty folder: $($process.Path)"
    }
    $window = $process.MainWindowHandle
    $listener = Get-NetTCPConnection -OwningProcess $process.Id -State Listen -ErrorAction SilentlyContinue |
        Where-Object LocalAddress -eq '0.0.0.0' | Select-Object -First 1
    Test-HideToTray
    if ($listener) {
        $stillListening = Get-NetTCPConnection -OwningProcess $process.Id -State Listen -ErrorAction SilentlyContinue |
            Where-Object LocalPort -eq $listener.LocalPort
        if (-not $stillListening) { throw 'Hiding the window stopped the transfer listener.' }
        'The same transfer listener remained active in the tray.'
    } else {
        'Listener check skipped because the App had no IPv4 listener at startup.'
    }

    Post-WindowMessage 0x8001 0 0x10400 # Icon 1, NIN_SELECT
    Wait-For {
        [NearTransferTrayTest]::IsWindowVisible($window) -and -not [NearTransferTrayTest]::HasIcon($window)
    } 'Activating the notification area icon did not restore the window.'
    Test-HideToTray

    Post-WindowMessage 0x8001 0 0x1007b # Icon 1, WM_CONTEXTMENU
    Wait-For { [NearTransferTrayTest]::HasPopupMenu($window) } 'The tray context menu did not open.'
    Post-WindowMessage 0x001f # WM_CANCELMODE
    Wait-For { -not [NearTransferTrayTest]::HasPopupMenu($window) } 'The tray context menu did not dismiss.'
    Post-WindowMessage 0x0111 40001 # WM_COMMAND, Open
    Wait-For { [NearTransferTrayTest]::IsWindowVisible($window) } 'The Open menu command did not restore the window.'
    Test-HideToTray

    Post-WindowMessage 0x0111 40004 # WM_COMMAND, Receive
    Wait-For { [NearTransferTrayTest]::IsWindowVisible($window) } 'The Receive menu command did not restore the window.'
    Test-HideToTray

    Post-WindowMessage 0x0111 40003 # WM_COMMAND, Pick files
    Wait-For {
        $dialog = [NearTransferTrayTest]::GetLastActivePopup($window)
        $dialog -ne $window -and [NearTransferTrayTest]::IsWindowVisible($dialog)
    } 'The Pick files menu command did not open the system file picker.'
    $dialog = [NearTransferTrayTest]::GetLastActivePopup($window)
    [void][NearTransferTrayTest]::PostMessage($dialog, 0x0010, 0, 0)
    Wait-For { -not [NearTransferTrayTest]::IsWindowVisible($dialog) } 'The file picker did not close.'
    Test-HideToTray

    Post-WindowMessage 0x0111 40002 # WM_COMMAND, Exit
    if (-not $process.WaitForExit(20000)) {
        throw 'The tray Exit command did not close the App.'
    }
    if ($process.ExitCode -ne 0) {
        throw "The App exited with code $($process.ExitCode)."
    }
    Wait-For { -not [NearTransferTrayTest]::HasIcon($window) } 'The App left a notification area icon behind.'
    'Passed: hide, restore, context menu, receive shortcut, file picker shortcut, exit and icon cleanup.'
} finally {
    foreach ($item in $process, $launcher) {
        if ($item) {
            if (-not $item.HasExited) {
                $item.Kill()
                $item.WaitForExit()
            }
            $item.Dispose()
        }
    }
    if ($testDirectory) {
        if (Test-Path -LiteralPath $copy -PathType Leaf) { Remove-Item -LiteralPath $copy }
        if (-not (Get-ChildItem -LiteralPath $testDirectory -Force)) {
            Remove-Item -LiteralPath $testDirectory
        }
    }
}
