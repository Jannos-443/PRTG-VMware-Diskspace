<#   
    .SYNOPSIS
    VMWare VM disk space monitoring

    .DESCRIPTION
    Using VMware PowerCLI this Script checks VMware disk space
    Exceptions can be made within this script by changing the variable $IgnoreScript. This way, the change applies to all PRTG sensors 
    based on this script. If exceptions have to be made on a per sensor level, the script parameter $IgnorePattern can be used.

    Copy this script to the PRTG probe EXEXML scripts folder (${env:ProgramFiles(x86)}\PRTG Network Monitor\Custom Sensors\EXEXML)
    and create a "EXE/Script Advanced. Choose this script from the dropdown and set at least:

    + Parameters: VCenter, User, Password
    + Scanning Interval: minimum 5 minutes

    .PARAMETER ViServer
    The Hostname of the VCenter Server

    .PARAMETER User
    Provide the VCenter Username

    .PARAMETER Password
    Provide the VCenter Password

    .PARAMETER IgnorePattern
    Regular expression to describe a disk to exclude.

    Example1:
    exclude "C:\" from the VM "FileSVR1"
    -IgnorePattern '^(FileSVR1:C:\\)$'

    Example2:
    exclude "C:\" from the VM "FileSVR1" and "/" (root) from a linux VM "LinuxVM"
    -IgnorePattern '^(FileSVR1:C:\\|LinuxVM:/)$'

    Example3:
    example2 and exlude all disk from VM "TestSVR23"
    -IgnorePattern '^(FileSVR1:C:\\|LinuxVM:/|TestSVR23.*)$'

    #https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_regular_expressions?view=powershell-7.1
    
    .PARAMETER WarningLimit
    Disk Space in Percent for a Warning
    
    .PARAMETER ErrorLimit
    Disk Space in Percent for an Error
    
    .EXAMPLE
    Sample call from PRTG EXE/Script Advanced
    PRTG-VMware-DiskSpace.ps1 -ViServer '%VCenter%' -User '%Username%' -Password '%PW%' -IgnorePattern '^(TestVM:E:\\)$'

    .NOTES
    This script is based on the sample by Paessler (https://kb.paessler.com/en/topic/67869-auto-starting-services) and debold (https://github.com/debold/PRTG-WindowsServices)

    Author:  Jannos-443
    https://github.com/Jannos-443/PRTG-VMware-DiskSpace

#>
param(
    [string]$ViServer = '',
    [string]$User = '',
    [string]$Password = '',
    [string]$IgnorePattern = '', #Example: '^(Mailstore2:E:\\)$' double Backslash for to excape it.
    [int]$WarningLimit = 10, #percent Free
    [int]$ErrorLimit = 5 #percent free
)

#Catch all unhandled Errors
trap{
    if($connected)
        {
        $null = Disconnect-VIServer -Server $ViServer -Confirm:$false -ErrorAction SilentlyContinue
        }
    $Output = "line:$($_.InvocationInfo.ScriptLineNumber.ToString()) char:$($_.InvocationInfo.OffsetInLine.ToString()) --- message: $($_.Exception.Message.ToString()) --- line: $($_.InvocationInfo.Line.ToString()) "
    $Output = $Output.Replace("<","")
    $Output = $Output.Replace(">","")
    Write-Output "<prtg>"
    Write-Output "<error>1</error>"
    Write-Output "<text>$Output</text>"
    Write-Output "</prtg>"
    Exit
}

#https://stackoverflow.com/questions/19055924/how-to-launch-64-bit-powershell-from-32-bit-cmd-exe
#############################################################################
#If Powershell is running the 32-bit version on a 64-bit machine, we 
#need to force powershell to run in 64-bit mode .
#############################################################################
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    #Write-warning  "Y'arg Matey, we're off to 64-bit land....."
    if ($myInvocation.Line) {
        &"$env:WINDIR\sysnative\windowspowershell\v1.0\powershell.exe" -NonInteractive -NoProfile $myInvocation.Line
    }else{
        &"$env:WINDIR\sysnative\windowspowershell\v1.0\powershell.exe" -NonInteractive -NoProfile -file "$($myInvocation.InvocationName)" $args
    }
exit $lastexitcode
}

#############################################################################
#End
#############################################################################    

$connected = $false

# Error if there's anything going on
$ErrorActionPreference = "Stop"


# Import VMware PowerCLI module
try {
    Import-Module "VMware.VimAutomation.Core" -ErrorAction Stop
} catch {
    Write-Output "<prtg>"
    Write-Output " <error>1</error>"
    Write-Output " <text>Error Loading VMware Powershell Module ($($_.Exception.Message))</text>"
    Write-Output "</prtg>"
    Exit
}


# Ignore certificate warnings
Set-PowerCLIConfiguration -InvalidCertificateAction ignore -Scope User -Confirm:$false | Out-Null

# Disable CEIP
Set-PowerCLIConfiguration -ParticipateInCeip $false -Scope User -Confirm:$false | Out-Null


# Connect to vCenter
try {
    Connect-VIServer -Server $ViServer -User $User -Password $Password
            
    $connected = $true
    }
 
catch
    {
    Write-Output "<prtg>"
    Write-Output " <error>1</error>"
    Write-Output " <text>Could not connect to vCenter server $ViServer. Error: $($_.Exception.Message)</text>"
    Write-Output "</prtg>"
    Exit
    }

# Get a list of all VMs
$VMs = Get-VM


# Get Snapshots from every VM
$WarningCount = 0
$WarningText = "Warning: "
$ErrorCount = 0
$ErrorText = "Error: "

# hardcoded list that applies to all hosts
$IgnoreScript = '^(TestExclude:C:\\)$' 
# \ has to be Escaped with another \

ForEach ($VM in $VMs)
    {
    Foreach ($disk in $VM.Extensiondata.Guest.Disk)
        {
        $space = ($disk.FreeSpace/$disk.Capacity) * 100
        $percentfree = [math]::Round($space,0)
        
        #Excludes
        $Text = "$($vm.name):$($disk.diskpath)"
        if($IgnorePattern -ne "")
            {  
            if($Text -match $IgnorePattern)
                {
                break
                }
            }

        if($IgnoreScript -ne "")
            {
            if($Text -match $IgnoreScript)
                {
                break
                }
            }

        #Check Free Space
        if($percentfree -le $ErrorLimit)
            {
            $ErrorCount += 1
            $ErrorText += "$($Text) $($percentfree)% free; "
            }

        elseif($percentfree -le $WarningLimit)
            {
            $WarningCount += 1
            $WarningText += "$($Text) $($percentfree)% free; "
            }       
        }
    }


# Disconnect from vCenter
Disconnect-VIServer -Server $ViServer -Confirm:$false

$connected = $false

# Results
$xmlOutput = '<prtg>'
if (($ErrorCount -ge 1) -and ($WarningCount -eq 0)) {
    $xmlOutput = $xmlOutput + "<text>$($ErrorText)</text>"
    }

elseif (($WarningCount -ge 1) -and ($ErrorCount -eq 0)){
    $xmlOutput = $xmlOutput + "<text>$($WarningText)</text>"
    } 

elseif(($WarningCount -eq 0) -and ($ErrorCount -eq 0)) {
    $xmlOutput = $xmlOutput + "<text>No Disks with under $($ErrorLimit) or $($WarningLimit)% free space</text>"
}

elseif(($WarningCount -ge 1) -and ($ErrorCount -ge 1))
    {
    $xmlOutput = $xmlOutput + "<text>$($ErrorText) $($WarningText)</text>"
    }


$xmlOutput = $xmlOutput + "<result>
        <channel>Disk Space Error</channel>
        <value>$ErrorCount</value>
        <unit>Count</unit>
        <limitmode>1</limitmode>
        <LimitMaxError>0</LimitMaxError>
        </result>

        <result>
        <channel>Disk Space Warning</channel>
        <value>$WarningCount</value>
        <unit>Count</unit>
        <limitmode>1</limitmode>
        <LimitMaxWarning>0</LimitMaxWarning>
        </result>"   
        



$xmlOutput = $xmlOutput + "</prtg>"

$xmlOutput
