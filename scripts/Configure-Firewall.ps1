#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [switch] $Remove
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator permission is required to configure Windows Firewall.'
}

$ruleGroup = 'MirrorSpeaker'
$ruleDescription = 'Allows only the local inbound ports used by the MirrorSpeaker receiver on Private networks.'

# Keep the original internal rule names so an update replaces the existing
# rules instead of leaving duplicate entries behind after the product rename.
$rules = @(
    [pscustomobject]@{
        Name = 'AirMirror-mDNS-UDP-In'
        DisplayName = 'MirrorSpeaker - mDNS discovery (UDP-In)'
        Protocol = 'UDP'
        LocalPort = '5353'
    },
    [pscustomobject]@{
        Name = 'AirMirror-Receiver-TCP-In'
        DisplayName = 'MirrorSpeaker - receiver streams (TCP-In)'
        Protocol = 'TCP'
        LocalPort = '35000-35002'
    },
    [pscustomobject]@{
        Name = 'AirMirror-Receiver-UDP-In'
        DisplayName = 'MirrorSpeaker - receiver streams (UDP-In)'
        Protocol = 'UDP'
        LocalPort = '35000-35002'
    }
)

foreach ($rule in $rules) {
    $existing = @(Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue)

    if ($Remove) {
        if ($existing.Count -gt 0 -and $PSCmdlet.ShouldProcess($rule.DisplayName, 'Remove private-profile inbound firewall rule')) {
            $existing | Remove-NetFirewallRule
            Write-Output "Removed: $($rule.DisplayName)"
        }
        continue
    }

    $mustReplace = $existing.Count -ne 1
    if (-not $mustReplace) {
        $portFilter = @($existing[0] | Get-NetFirewallPortFilter)
        $mustReplace = (
            [string] $existing[0].Enabled -ne 'True' -or
            [string] $existing[0].Direction -ne 'Inbound' -or
            [string] $existing[0].Action -ne 'Allow' -or
            [string] $existing[0].Profile -ne 'Private' -or
            [string] $existing[0].DisplayName -ne $rule.DisplayName -or
            [string] $existing[0].Group -ne $ruleGroup -or
            [string] $existing[0].Description -ne $ruleDescription -or
            $portFilter.Count -ne 1 -or
            [string] $portFilter[0].Protocol -ne $rule.Protocol -or
            [string] $portFilter[0].LocalPort -ne $rule.LocalPort
        )
    }

    if ($mustReplace -and $PSCmdlet.ShouldProcess($rule.DisplayName, 'Create private-profile inbound firewall rule')) {
        if ($existing.Count -gt 0) {
            $existing | Remove-NetFirewallRule
        }

        New-NetFirewallRule `
            -Name $rule.Name `
            -DisplayName $rule.DisplayName `
            -Group $ruleGroup `
            -Description $ruleDescription `
            -Enabled True `
            -Profile Private `
            -Direction Inbound `
            -Action Allow `
            -Protocol $rule.Protocol `
            -LocalPort $rule.LocalPort `
            -EdgeTraversalPolicy Block | Out-Null

        Write-Output "Configured: $($rule.DisplayName)"
    }
    elseif (-not $mustReplace) {
        Write-Output "Already configured: $($rule.DisplayName)"
    }
}

if ($Remove) {
    Write-Output 'MirrorSpeaker firewall rules were removed. Windows Firewall remains enabled.'
}
else {
    Write-Output 'MirrorSpeaker firewall rules allow UDP 5353 and TCP/UDP 35000-35002 on Private networks only.'
}
