<#
    K53SC — bring the discrete GeForce GT 520MX up under Windows.

    The NVIDIA driver fails its *initial* start at boot with Code 43
    (CM_PROB_FAILED_POST_START) and ProblemStatus STATUS_SUCCESS -- it starts,
    runs its own validation, and declines, with no OS-level error. Restarting
    the device once the system is up succeeds every time.

    This is a timing/ordering problem in the driver's first start, not a
    firmware fault: the firmware already programs the GPU's PCI subsystem ID
    and exposes the full Optimus ACPI surface, the card matches nvami.inf
    natively, and the same firmware drives it correctly under Linux including
    with NVIDIA's proprietary driver. Re-stamping the subsystem ID earlier
    (from _STA and _INI as well as _PS0) does not help, and Windows continues
    to enumerate the card with the correct SUBSYS throughout -- so the ID is
    not what the driver is unhappy about.

    Install (elevated PowerShell):

        $a = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Windows\nvfix.ps1"
        $t = New-ScheduledTaskTrigger -AtStartup; $t.Delay = "PT45S"
        $p = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName "NvidiaDgpuFix" -Action $a -Trigger $t `
             -Principal $p -Settings $s -Force

    AllowStartIfOnBatteries matters: schtasks defaults to refusing to start on
    battery, and the task silently sits in "Queued" forever without it.

    Remove with:  Unregister-ScheduledTask -TaskName NvidiaDgpuFix -Confirm:$false
#>

$nv  = "PCI\VEN_10DE&DEV_1051&SUBSYS_17621043&REV_A1\4&39913636&0&0008"
$log = "C:\Windows\Temp\nvfix.log"

"$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') start; status=$((Get-PnpDevice -InstanceId $nv -EA SilentlyContinue).Status)" | Add-Content $log

for ($i = 0; $i -lt 6; $i++) {
    $d = Get-PnpDevice -InstanceId $nv -EA SilentlyContinue
    if ($d -and $d.Status -eq "OK") { "  already OK, nothing to do" | Add-Content $log; break }
    try {
        Disable-PnpDevice -InstanceId $nv -Confirm:$false -EA Stop
        Start-Sleep -Seconds 3
        Enable-PnpDevice -InstanceId $nv -Confirm:$false -EA Stop
        Start-Sleep -Seconds 6
        $d = Get-PnpDevice -InstanceId $nv -EA SilentlyContinue
        "  attempt $($i+1): status=$($d.Status) problem=$($d.Problem)" | Add-Content $log
        if ($d.Status -eq "OK") { break }
    } catch {
        "  attempt $($i+1) failed: $($_.Exception.Message)" | Add-Content $log
    }
    Start-Sleep -Seconds 10
}
