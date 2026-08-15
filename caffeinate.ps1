# little helper for caffeinate.bat since batch can't call the winapi itself
param(
    [switch]$Display,
    [switch]$Idle,
    [switch]$UserPresent,
    [switch]$Reset
)

Add-Type -Name Kernel32 -Namespace Native -MemberDefinition '[DllImport("kernel32.dll")]public static extern uint SetThreadExecutionState(uint esFlags);'

$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1
$ES_DISPLAY_REQUIRED = [uint32]2
$ES_USER_PRESENT = [uint32]4

if ($Reset) {
    [Native.Kernel32]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    exit
}

$flags = $ES_CONTINUOUS
if ($Display) { $flags = $flags -bor $ES_DISPLAY_REQUIRED }
if ($Idle) { $flags = $flags -bor $ES_SYSTEM_REQUIRED }
if ($UserPresent) { $flags = $flags -bor $ES_USER_PRESENT }

[Native.Kernel32]::SetThreadExecutionState($flags) | Out-Null
