#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy VMware VCF Installer 9.1.1 and optionally configure its binary repository.
.DESCRIPTION
    Deploys the VCF Installer OVA with OVF Tool to a vCenter-managed ESXi host.
    If ConfigureAfterDeployment is enabled, waits for guest operations, prepares
    the VCF download tool and repository, optionally transfers depot content,
    and uploads binaries using the VCF download tool.

    Prerequisites: VMware OVF Tool; VMware PowerCLI (only for configuration);
    Posh-SSH (only when copying depot files); network/DNS access to the appliance.
    A configurable lab-only default password is used for all four accounts unless overridden.
    Do not use the embedded default in production. Run in a trusted session.

    IMPORTANT: OVF Tool requires a vCenter password in its destination URI here.
    That password can be exposed to local process inspection while OVF Tool runs.
    Use a restricted deployment workstation and a least-privilege account.
    Guest configuration transmits a temporary password file via VMware Tools;
    the temporary files are deleted in a finally block where possible.

    Test with the specific VCF Installer OVA and vcf-download-tool release.
    Defaults retain the original scripts' lab inventory and appliance properties.
.EXAMPLE
    .\Deploy-VCFInstaller-Combined.ps1
.NOTES
    Author: Adapted from scripts by Niclas Borgstrom.
    No implicit module installation. HTTP depot download does not require SSH.
#>

$deploymentTimer = [System.Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ============================================================================
# USER SETTINGS - EDIT THIS SECTION
# ============================================================================
$ConfigureAfterDeployment = $true       # $false = deploy only; $true = deploy + configure
$CopyVCFDepotFiles       = $true       # Only used when configuration is enabled
$SkipDeploymentIfExists  = $true       # $true = configure existing VM (or deploy-only no-op)
$AllowInsecureOvfTLS     = $false      # Set $true only for a lab with untrusted vCenter certs
$SkipOvfManifestCheck    = $false      # Set $true only when explicitly necessary
$AcceptVcfUploadConsent  = $true       # Maps to --ignoreConsent; confirm applicable license/consent

$OvfToolPath       = 'C:\Program Files\VMware\VMware OVF Tool\ovftool.exe'
$VcfInstallerOva   = 'I:\VCF-SDDC-Manager-Appliance-9.1.1.0200.25801071.ova'
$OvaDriveLetter    = 'I:'
$OvaNetworkShare   = '\\192.168.0.76\Stuff\VMware\Nested VMware appliances'
# Uses the current Windows identity for SMB authentication. Never embed SMB passwords here.

$VCenterServer     = '192.168.0.90'
$VCenterUser       = 'administrator@vsphere.local'
$VCenterDatacenter = 'Datacenter'
$VCenterCluster    = 'ProdCluster'    # Empty string for standalone host
$TargetEsxiHost    = '192.168.0.53'
$EsxiUser          = 'root'           # Reserved for optional direct-host administration; not used for deployment
# LAB ONLY: separate defaults for infrastructure and VCF Installer accounts.
# WARNING: Plaintext passwords are visible to anyone who can read this script.
# For production, use a secrets vault and remove these lab defaults.
$DefaultPassword          = 'VMware1!'
$VCFInstallerPassword     = 'VMware1!VMware1!'
# Optional per-account SecureString overrides; $null uses the appropriate default (or prompts if unset).
$VCenterPassword   = $null
# Prompt for vCenter credentials rather than assuming the appliance lab password.
# Set to $false to use $VCenterPassword (or $DefaultPassword when unset).
$PromptForVCenterCredentials = $true
$EsxiPassword      = $null
$InstallerRootPassword  = $null
$InstallerAdminPassword = $null

$VmName            = 'vcfinstaller'   # Must be identical in deployment and configuration
$VmNetwork         = 'vGhetto_Net_30'
$VmDatastore       = 'VMFS-ESXi53-nvme'
$ApplianceFqdn     = 'vcfinstaller.vcf.lab'
$ApplianceIp       = '172.30.0.250'
$ApplianceNetmask  = '255.255.255.0'
$ApplianceGateway  = '172.30.0.1'
$ApplianceDns      = '192.168.0.2'
$ApplianceDomain   = 'vcf.lab'
$ApplianceSearch   = 'vcf.lab'
$ApplianceNtp      = '192.121.108.99'

$DownloadFile      = 'vcf-download-tool-9.1.1.0200.25801073.tar.gz'
$DownloadBaseUrl   = 'http://192.168.0.76/PROD/COMP/VCFDT' # Prefer HTTPS when available
$DownloadDirectory = '/opt/vmware/vcf/lcm/vcf-download'
$RepositoryPath    = '/nfs/vmware/vcf/nfs-mount/VCF911'
$DepotWebUrl      = 'http://192.168.0.76/vcf911/' # Must return a browsable directory listing (HTTP 200)
$DownloadDepotFromWeb = $true # $true = HTTP download on appliance; $false = skip depot transfer
$InstallerAdminUser = 'admin@local'

$DepotPollSeconds = 30
$DepotTimeoutHours = 24
$UploadPollSeconds = 30
$UploadTimeoutHours = 24
$ReuseSuccessfulUpload = $true
$GuestReadyTimeoutMinutes = 25
$GuestRetrySeconds        = 20
$GuestOperationAttempts   = 3
$LogDirectory             = Join-Path $PSScriptRoot 'logs'

# ============================================================================
# FUNCTIONS
# ============================================================================
function Write-Log {
    param([Parameter(Mandatory)][string]$Message,
          [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $(switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} default {'Cyan'} })
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}
function Ensure-OvaNetworkDrive {
    param([Parameter(Mandatory)][string]$DriveLetter,
          [Parameter(Mandatory)][string]$SharePath)

    if ($DriveLetter -notmatch '^[A-Za-z]:$') { throw "Invalid drive letter: $DriveLetter" }
    if ($SharePath -notmatch '^\\\\[^\\]+\\[^\\]+') { throw "Invalid UNC share path: $SharePath" }

    # A drive that exists but points elsewhere must never be silently remapped.
    $drive = Get-PSDrive -Name $DriveLetter.Substring(0, 1) -ErrorAction SilentlyContinue
    if ($drive) {
        $existingRoot = $drive.DisplayRoot
        if (-not $existingRoot) { $existingRoot = $drive.Root }
        if ($existingRoot -and $existingRoot.TrimEnd('\') -ieq $SharePath.TrimEnd('\')) {
            Write-Log "Drive $DriveLetter is already mapped to the expected share."
        }
        elseif ($existingRoot -eq ($DriveLetter + '\')) {
            # A local drive (or a drive mapping not exposed via DisplayRoot).
            # Check Windows SMB mappings before deciding whether it is safe.
            $mapping = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $DriveLetter) -ErrorAction Stop
            if (-not $mapping -or $mapping.ProviderName -ine $SharePath) {
                throw "Drive $DriveLetter already exists but is not mapped to $SharePath. Existing root: $existingRoot"
            }
            Write-Log "Drive $DriveLetter is already mapped to the expected share."
        }
        else {
            throw "Drive $DriveLetter is already in use by '$existingRoot'; expected '$SharePath'."
        }
    }
    else {
        Write-Log "Mapping $DriveLetter to $SharePath using the current Windows credentials."
        # net use creates a Windows drive mapping visible to native executables such as OVF Tool.
        $output = & net.exe use $DriveLetter $SharePath /persistent:no 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Failed to map $DriveLetter to $SharePath (net use exit code $exitCode): $($output -join ' ')"
        }
        Write-Log "Network drive $DriveLetter mapped successfully."
    }
    if (-not (Test-Path -LiteralPath ($DriveLetter + '\') -PathType Container)) {
        throw "Drive $DriveLetter is mapped but cannot be accessed. Verify share permissions and network connectivity."
    }
}
function Assert-File { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file missing: $Path" }
}
function Assert-GuestPath {
    param([string]$Path)
    if ($Path -notmatch '^/[A-Za-z0-9_./-]+$' -or $Path.Contains('..')) {
        throw "Unsafe Linux path: $Path"
    }
}
function Quote-Bash { param([string]$Value)
    # Bash single-quote escaping: a literal apostrophe becomes: single-quote, double-quote, apostrophe, double-quote, single-quote.
    $apostrophe = [string][char]39
    $replacement = $apostrophe + [char]34 + $apostrophe + [char]34 + $apostrophe
    return $apostrophe + $Value.Replace($apostrophe, $replacement) + $apostrophe
}
function Get-PlainText {
    param([Security.SecureString]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Get-ConnectionCredential {
    <#
    .SYNOPSIS
        Create a PSCredential from an optional SecureString, lab default, or prompt.
    .NOTES
        The lab default is plaintext. Prefer SecureString overrides from a vault
        in production and disable the default.
    #>
    param(
        [Parameter(Mandatory)][string]$UserName,
        [AllowNull()][Security.SecureString]$Password,
        [Parameter(Mandatory)][string]$Prompt,
        [AllowNull()][string]$FallbackPassword = $DefaultPassword
    )
    if ($null -ne $Password) {
        if ($Password.Length -eq 0) { throw "Empty password supplied for $UserName." }
        return [pscredential]::new($UserName, $Password)
    }
    if (-not [string]::IsNullOrEmpty($FallbackPassword)) {
        $secureDefault = ConvertTo-SecureString -String $FallbackPassword -AsPlainText -Force
        return [pscredential]::new($UserName, $secureDefault)
    }
    $credential = Get-Credential -UserName $UserName -Message $Prompt
    if ($null -eq $credential -or $credential.Password.Length -eq 0) {
        throw "Credentials were not supplied for $UserName."
    }
    return $credential
}
function Assert-OvfPassword {
    <#
    .SYNOPSIS
        Fail before OVF Tool if a required OVA password is empty.
    .NOTES
        Never log or echo password contents. OVA-specific complexity rules are
        still enforced by OVF Tool and the appliance.
    #>
    param(
        [Parameter(Mandatory)][string]$PropertyName,
        [AllowNull()][AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "OVA property '$PropertyName' has an empty password. Re-run and enter a non-empty password at the credential prompt."
    }
}
function ConvertTo-LinuxLineEndings {
    <#
    .SYNOPSIS
        Normalize PowerShell-generated Bash scripts to Unix LF line endings.
    .DESCRIPTION
        PowerShell here-strings on Windows can contain CRLF. Base64 encoding
        preserves those bytes, and Bash then fails on tokens such as "in\r".
        Normalize BEFORE encoding or passing script text to VMware Tools.
    #>
    param([AllowEmptyString()][string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}
function ConvertTo-GuestBashCommand {
    <# Encode LF-normalized Bash so VMware Tools receives a one-line command. #>
    param([Parameter(Mandatory)][string]$Script)
    $linuxScript = ConvertTo-LinuxLineEndings -Text $Script
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($linuxScript))
    return "printf '%s' '$encoded' | base64 -d | /bin/bash"
}
function Invoke-Guest {
    param([string]$Text, [string]$Description, [int]$Attempts = $GuestOperationAttempts)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Write-Log "$Description (attempt $attempt/$Attempts)"
            $r = Invoke-VMScript -Server $script:ViConnection -VM $script:Vm `
                -GuestCredential $script:GuestCredential -ScriptType Bash `
                -ScriptText (ConvertTo-LinuxLineEndings -Text $Text) -ErrorAction Stop
            if ($r.ExitCode -ne 0) {
                throw "$Description exited with code $($r.ExitCode): $($r.ScriptOutput)"
            }
            if ($r.ScriptOutput) { Write-Log ($r.ScriptOutput.Trim()) }
            return $r.ScriptOutput
        }
        catch {
            if ($attempt -eq $Attempts) { throw "${Description}: $($_.Exception.Message)" }
            Write-Log "$Description failed; retrying in $GuestRetrySeconds seconds." 'WARN'
            Start-Sleep -Seconds $GuestRetrySeconds
        }
    }
}
function Wait-GuestOperations {
    <#
    .SYNOPSIS
        Wait for the powered-on guest to finish basic boot initialization.
    .DESCRIPTION
        VMware Tools running is not proof that the guest is ready. This check
        requires a successful guest command, a unique output marker, systemd
        no longer being in its initial 'starting' state, and writable /tmp.
        It deliberately does not require network access to the download URL;
        that is diagnosed separately by the preparation step.
    #>
    $deadline = (Get-Date).AddMinutes($GuestReadyTimeoutMinutes)
    $probe = @'
#!/bin/bash
set -e
[ "$(id -u)" -eq 0 ]
[ -d /tmp ] && [ -w /tmp ]
if command -v systemctl >/dev/null 2>&1; then
    state=$(systemctl is-system-running 2>/dev/null || true)
    case "$state" in
        running|degraded) ;;
        *) echo "Boot state: $state"; exit 3 ;;
    esac
fi
printf '%s\n' 'VCF_GUEST_READY=true'
'@
    # Base64 avoids nested Bash quoting and ensures multiline commands survive
    # VMware Tools/PowerCLI guest script transport unchanged.
    $command = ConvertTo-GuestBashCommand -Script $probe
    while ((Get-Date) -lt $deadline) {
        try {
            $script:Vm = Get-VM -Server $script:ViConnection -Name $VmName -ErrorAction Stop
            if ($script:Vm.PowerState -ne 'PoweredOn') { throw 'VM is not powered on yet.' }
            $toolsState = $script:Vm.ExtensionData.Guest.ToolsRunningStatus
            if ($toolsState -ne 'guestToolsRunning') { throw "VMware Tools status: $toolsState" }
            $result = Invoke-VMScript -Server $script:ViConnection -VM $script:Vm `
                -GuestCredential $script:GuestCredential -ScriptType Bash `
                -ScriptText $command -ErrorAction Stop
            if ($result.ExitCode -ne 0) {
                throw "Boot probe exit code $($result.ExitCode); output: $($result.ScriptOutput)"
            }
            if ($result.ScriptOutput -notmatch 'VCF_GUEST_READY=true') {
                throw "Boot probe did not return readiness marker; output: $($result.ScriptOutput)"
            }
            Write-Log 'VMware Tools and Linux guest initialization are ready.'
            return
        }
        catch {
            Write-Log "Waiting for VCF Installer boot readiness: $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds $GuestRetrySeconds
        }
    }
    throw "VCF Installer guest did not become ready within $GuestReadyTimeoutMinutes minutes. Check VM console, VMware Tools, systemd and guest credentials."
}
function New-GuestScript {
    param([string]$Template, [hashtable]$Values)
    foreach ($key in $Values.Keys) {
        $Template = $Template.Replace("__$key`__", (Quote-Bash ([string]$Values[$key])))
    }
    if ($Template -match '__[A-Z_]+__') { throw 'Unresolved guest script placeholder.' }
    return $Template
}

# ============================================================================
# EXECUTION
# ============================================================================
$ViConnection = $null
$Vm = $null
$GuestCredential = $null
$script:LogFile = $null
$deployed = $false
$stage = 'initialization'
$remotePasswordFile = '/var/lib/vcf-binary-upload/password'
$uploadLaunchAttempted = $false
$remoteScriptFile = '/tmp/vcf-installer-prepare.sh'
$localTempScript = $null

try {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $script:LogFile = Join-Path $LogDirectory ('VCFInstaller-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Log "Starting VCF Installer workflow; ConfigureAfterDeployment=$ConfigureAfterDeployment"

    $stage = 'preflight'
    Assert-File $OvfToolPath
    Ensure-OvaNetworkDrive -DriveLetter $OvaDriveLetter -SharePath $OvaNetworkShare
    Assert-File $VcfInstallerOva
    Assert-GuestPath $DownloadDirectory
    Assert-GuestPath $RepositoryPath
    if ($DownloadFile -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Unsafe download filename.' }
    if ($VmName -match '[\r\n]') { throw 'Invalid VM name.' }
    if ($ConfigureAfterDeployment) {
        if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
            throw 'VMware PowerCLI (VMware.VimAutomation.Core) must be installed for configuration.'
        }
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
        if ($CopyVCFDepotFiles -and -not $DownloadDepotFromWeb) {
            throw 'Depot copy is enabled but web download is disabled. Enable DownloadDepotFromWeb or disable CopyVCFDepotFiles.'
        }
        if ($CopyVCFDepotFiles) {
            $depotUri = [Uri]$DepotWebUrl
            if ($depotUri.Scheme -notin @('http', 'https') -or -not $depotUri.AbsolutePath.EndsWith('/')) {
                throw 'DepotWebUrl must be an HTTP(S) directory URL ending in /.'
            }
        }
    }

    # Use per-account overrides when provided; otherwise the lab default (or prompt).
    if ($PromptForVCenterCredentials -and $null -eq $VCenterPassword) {
        $vcCredential = Get-Credential -UserName $VCenterUser -Message 'Enter vCenter credentials for deployment'
        if ($null -eq $vcCredential -or $vcCredential.Password.Length -eq 0) {
            throw 'vCenter credentials were not provided.'
        }
    } else {
        $vcCredential = Get-ConnectionCredential -UserName $VCenterUser -Password $VCenterPassword -Prompt 'vCenter credentials for OVF deployment'
    }
    $vcPassword = Get-PlainText $vcCredential.Password

    $GuestCredential = Get-ConnectionCredential -UserName 'root' -Password $InstallerRootPassword -Prompt 'VCF Installer root password for OVA deployment' -FallbackPassword $VCFInstallerPassword
    $adminCredential = Get-ConnectionCredential -UserName $InstallerAdminUser -Password $InstallerAdminPassword -Prompt 'VCF Installer admin password for OVA deployment' -FallbackPassword $VCFInstallerPassword
    $rootPassword = Get-PlainText $GuestCredential.Password
    $adminPassword = Get-PlainText $adminCredential.Password
    # OVF Tool reports "Invalid value ''" when an OVA password is empty.
    # Check both mandatory password properties before invoking the external tool.
    Assert-OvfPassword -PropertyName 'ROOT_PASSWORD' -Value $rootPassword
    Assert-OvfPassword -PropertyName 'LOCAL_USER_PASSWORD' -Value $adminPassword
    Write-Log 'Required OVA password properties are populated (values not logged).'

    $stage = 'deployment'
    # Check for an existing VM using PowerCLI if available, avoiding accidental duplicate deployments.
    # In deploy-only mode without PowerCLI, OVF Tool will reject a duplicate VM name.
    if ($ConfigureAfterDeployment) {
        # All inventory queries and guest operations go through vCenter, not a direct ESXi login.
        Write-Log "Connecting to vCenter $VCenterServer"
        $ViConnection = Connect-VIServer -Server $VCenterServer -Credential $vcCredential -ErrorAction Stop
        $targetHost = Get-VMHost -Server $ViConnection -Name $TargetEsxiHost -ErrorAction Stop
        if ($targetHost.ConnectionState -ne 'Connected') {
            throw "Target ESXi host '$TargetEsxiHost' is not connected in vCenter (state: $($targetHost.ConnectionState))."
        }
        $existing = @(Get-VM -Server $ViConnection -Name $VmName -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 1) { throw "Multiple VMs named '$VmName' found." }
        if ($existing.Count -eq 1) {
            if (-not $SkipDeploymentIfExists) { throw "VM '$VmName' already exists. Set SkipDeploymentIfExists to true to configure it." }
            Write-Log "Existing VM '$VmName' found; skipping deployment." 'WARN'
            $Vm = $existing[0]
            if ($Vm.VMHost.Id -ne $targetHost.Id) {
                throw "Existing VM '$VmName' is on host '$($Vm.VMHost.Name)', not target '$TargetEsxiHost'."
            }
        }
    }
    if (-not $Vm) {
        $inventory = if ([string]::IsNullOrWhiteSpace($VCenterCluster)) {
            "$VCenterDatacenter/host/$TargetEsxiHost"
        } else { "$VCenterDatacenter/host/$VCenterCluster/$TargetEsxiHost" }
        $u = [uri]::EscapeDataString($vcCredential.UserName)
        $p = [uri]::EscapeDataString($vcPassword)
        $destination = "vi://${u}:${p}@$VCenterServer/$inventory"
        $ovfArgs = @('--acceptAllEulas','--X:injectOvfEnv','--allowExtraConfig',
            '--sourceType=OVA','--powerOn',"--net:Network 1=$VmNetwork",
            "--datastore=$VmDatastore",'--diskMode=thin',"--name=$VmName",
            "--prop:vami.hostname=$ApplianceFqdn",
            "--prop:vami.ip0.SDDC-Manager=$ApplianceIp",
            "--prop:vami.netmask0.SDDC-Manager=$ApplianceNetmask",
            "--prop:vami.gateway.SDDC-Manager=$ApplianceGateway",
            "--prop:vami.domain.SDDC-Manager=$ApplianceDomain",
            "--prop:vami.searchpath.SDDC-Manager=$ApplianceSearch",
            "--prop:vami.DNS.SDDC-Manager=$ApplianceDns",
            "--prop:ROOT_PASSWORD=$rootPassword",
            "--prop:LOCAL_USER_PASSWORD=$adminPassword",
            "--prop:guestinfo.ntp=$ApplianceNtp")
        if ($AllowInsecureOvfTLS) { $ovfArgs += '--noSSLVerify' }
        if ($SkipOvfManifestCheck) { $ovfArgs += '--skipManifestCheck' }
        $ovfArgs += @($VcfInstallerOva, $destination)
        Write-Log "Deploying VM '$VmName' to $VCenterServer ($inventory), datastore $VmDatastore"
        # Never log OVF Tool arguments or destination URI: they contain passwords.
        & $OvfToolPath @ovfArgs
        $ovfExit = $LASTEXITCODE
        $ovfArgs = $null; $destination = $null; $p = $null
        if ($ovfExit -ne 0) { throw "OVF Tool deployment failed with exit code $ovfExit" }
        $deployed = $true
        Write-Log 'OVA deployment and power-on command completed successfully.'
        if ($ConfigureAfterDeployment) {
            $Vm = Get-VM -Server $ViConnection -Name $VmName -ErrorAction Stop
            if ($Vm.VMHost.Id -ne $targetHost.Id) {
                throw "Deployed VM is on '$($Vm.VMHost.Name)', expected '$TargetEsxiHost'."
            }
            Write-Log "Verified VM '$VmName' is placed on ESXi host '$TargetEsxiHost' through vCenter."
        }
    }
    $vcPassword = $null; $rootPassword = $null
    if (-not $ConfigureAfterDeployment) {
        Write-Log 'Deploy-only mode selected; configuration skipped.'
        return
    }

    $stage = 'guest readiness'
    Wait-GuestOperations

    $stage = 'repository and download tool preparation'
    # No SSH daemon changes: VMware Tools is used for remote execution and transfer.
    $prepareTemplate = @'
#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "VCF_PREPARE_ERROR line=$LINENO exit=$rc command=$BASH_COMMAND" >&2' ERR
repo=__REPO__
dir=__DIR__
file=__FILE__
url=__URL__
mkdir -p "$repo" "$dir"
chown -R vcf_lcm:vcf "$repo"
if [ -z "$(ls -A "$repo")" ]; then
  echo 'VCF_REPOSITORY_EMPTY=true'
else
  echo 'VCF_REPOSITORY_EMPTY=false'
fi
cd "$dir"
if [ ! -s "$file" ]; then
  curl --fail --location --retry 3 --connect-timeout 20 --output "$file" "$url"
fi
tar -tzf "$file" >/dev/null
tar -xzf "$file"
chown -R vcf_lcm:vcf "$dir"
chmod -R u+rwX,go-rwx "$dir"
test -x "$dir/bin/vcf-download-tool" || command -v "$dir/bin/vcf-download-tool" >/dev/null
printf '%s\n' 'VCF_PREPARE_OK=true'
'@
    $prepareScript = New-GuestScript $prepareTemplate @{
        REPO=$RepositoryPath; DIR=$DownloadDirectory; FILE=$DownloadFile
        URL=($DownloadBaseUrl.TrimEnd('/') + '/' + $DownloadFile)
    }
    # Execute the entire multiline payload as one Bash program. Passing raw
    # multiline text can be interpreted inconsistently by guest shell wrappers.
    # Base64 transport preserves newlines and quotes without nested shell parsing.
    $prepareCommand = ConvertTo-GuestBashCommand -Script $prepareScript
    $prepareOutput = Invoke-Guest -Text $prepareCommand -Description 'Prepare repository and download tool'
    if ($prepareOutput -notmatch '(?m)^VCF_PREPARE_OK=true\s*$') {
        $outputExcerpt = if ([string]::IsNullOrWhiteSpace($prepareOutput)) {
            '<no guest stdout returned>'
        } else {
            if ($prepareOutput.Length -gt 3000) { $prepareOutput.Substring(0, 3000) + ' ... [truncated]' }
            else { $prepareOutput.Trim() }
        }
        throw "Preparation did not return its success marker. Guest output: $outputExcerpt"
    }
    $status = [regex]::Matches($prepareOutput, 'VCF_REPOSITORY_EMPTY=(true|false)')
    if ($status.Count -eq 0) { throw 'Repository status marker missing.' }
    $repositoryEmpty = $status[$status.Count-1].Groups[1].Value -eq 'true'

    if ($CopyVCFDepotFiles) {
        $stage = 'HTTP depot download'
        # Download directly from the web server to the appliance. This avoids
        # Windows -> SSH/SCP transfers and does not require enabling root SSH.
        # wget recursion requires browsable directory indexes with links to
        # each subdirectory. A server without directory listings must instead
        # provide a tarball or an explicit manifest of downloadable files.
        Write-Log "Synchronizing depot from $DepotWebUrl to $RepositoryPath (existing files retained)"
        # A transient systemd service survives VMware Tools and vCenter disconnects.
        $httpDepotTemplate = @'
#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "VCF_HTTP_DEPOT_ERROR line=$LINENO exit=$rc command=$BASH_COMMAND" >&2' ERR
url=__URL__
repo=__REPO__
command -v wget >/dev/null || { echo 'wget is required for recursive HTTP depot download' >&2; exit 10; }
mkdir -p -- "$repo"
# The HTTP server must publish a browsable directory index at the base URL
# and at each subdirectory. wget cannot discover unlinked files.
# --cut-dirs=1 strips /vcf911/ from saved paths, preserving PROD/ etc.
# --no-verbose reports failures without flooding VMware Tools output.
# --reject discards downloaded index pages, while -np stays under the base URL.
# --execute robots=off avoids a missing /robots.txt producing a spurious HTTP error.
# Other HTTP failures (403/404 on actual depot files) still fail the transfer.
wget --execute robots=off --recursive --level=inf --no-parent --no-host-directories --cut-dirs=1 \
     --continue --tries=5 --timeout=120 --waitretry=10 \
     --no-verbose --reject 'index.html*' --directory-prefix="$repo" "$url"
count=$(find "$repo" -type f | wc -l)
if [ "$count" -eq 0 ]; then
  echo 'HTTP download finished without any depot files; check server directory listings.' >&2
  exit 12
fi
chown -R vcf_lcm:vcf "$repo"
echo "VCF_HTTP_DEPOT_FILE_COUNT=$count"
echo 'VCF_HTTP_DEPOT_OK=true'
'@
        $httpDepotScript = New-GuestScript $httpDepotTemplate @{ URL=$DepotWebUrl; REPO=$RepositoryPath }
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-LinuxLineEndings -Text $httpDepotScript)))
        $launchTemplate = @'
set -eu
umask 077
state=/var/lib/vcf-depot-sync
mkdir -p "$state"
exec 9>"$state/launch.lock"
flock -x 9
unit=vcf-depot-sync.service
if systemctl is-active --quiet "$unit"; then
    echo VCF_JOB_RUNNING
    exit 0
fi
# Avoid starting a second job if a previous synchronous wget is still running.
if pgrep -x wget >/dev/null; then
    echo 'An existing wget process is running; inspect it before starting another transfer.' >&2
    exit 19
fi
printf '%s' __PAYLOAD__ | base64 -d > "$state/worker.sh"
cat > "$state/run.sh" <<'EOF'
#!/bin/bash
state=/var/lib/vcf-depot-sync
/bin/bash "$state/worker.sh" > "$state/download.log" 2>&1
rc=$?
printf '%s\n' "$rc" > "$state/exit.tmp"
mv -f "$state/exit.tmp" "$state/exit"
exit "$rc"
EOF
rm -f "$state/exit"
systemctl reset-failed "$unit" 2>/dev/null || true
systemd-run --unit=vcf-depot-sync -- /bin/bash "$state/run.sh"
echo VCF_JOB_STARTED
'@
        $launch = New-GuestScript $launchTemplate @{ PAYLOAD=$payload }
        $null = Invoke-Guest -Text (ConvertTo-GuestBashCommand -Script $launch) -Description 'Start or attach to detached depot download' -Attempts 1
        $poll = @'
set -eu
state=/var/lib/vcf-depot-sync
if [ -f "$state/exit" ]; then
    echo "VCF_JOB_EXIT=$(cat "$state/exit")"
elif systemctl is-active --quiet vcf-depot-sync.service; then
    echo VCF_JOB_RUNNING
else
    echo VCF_JOB_LOST
fi
if [ -f "$state/download.log" ]; then tail -n 8 "$state/download.log"; fi
'@
        $deadline = (Get-Date).AddHours($DepotTimeoutHours)
        $vmId = $Vm.Id
        while ($true) {
            if ((Get-Date) -ge $deadline) { throw 'Depot polling timed out; detached job may still be running. Rerun to attach.' }
            try {
                $output = Invoke-Guest -Text (ConvertTo-GuestBashCommand -Script $poll) -Description 'Poll depot download' -Attempts 1
            } catch {
                Write-Log "Guest polling failed; reconnecting to vCenter: $($_.Exception.Message)" 'WARN'
                try {
                    Disconnect-VIServer -Server $ViConnection -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    $ViConnection = Connect-VIServer -Server $VCenterServer -Credential $vcCredential -ErrorAction Stop
                    $Vm = Get-VM -Server $ViConnection -Id $vmId -ErrorAction Stop
                } catch { Write-Log "Reconnect failed: $($_.Exception.Message)" 'WARN' }
                Start-Sleep -Seconds $DepotPollSeconds
                continue
            }
            if ($output -match '(?m)^VCF_JOB_EXIT=(\d+)\s*$') {
                if ([int]$Matches[1] -ne 0) { throw "Depot worker failed: $output. See /var/lib/vcf-depot-sync/download.log" }
                break
            }
            if ($output -match 'VCF_JOB_LOST') { throw 'Detached depot job stopped without recording an exit code.' }
            Start-Sleep -Seconds $DepotPollSeconds
        }
        Write-Log 'HTTP depot download completed; verify contents against the web server before production use.'
    }
    elseif (-not $repositoryEmpty) { Write-Log 'Repository contains files; depot download disabled.' }
    else { Write-Log 'Depot download disabled; repository is empty.' 'WARN' }

    $stage = 'binary upload'
    $uploadTemplate = @'
#!/bin/bash
set -Eeuo pipefail
cd __DIR__
export PATH="$PATH":__DIR_BIN__
vcf-download-tool binaries upload \
  -d __REPO__ \
  -f __FQDN__ \
  -u __ADMIN__ \
  --sddc-manager-user-password-file __PASS__ __CONSENT__
'@
    $uploadScript = New-GuestScript $uploadTemplate @{
        DIR=$DownloadDirectory; DIR_BIN=($DownloadDirectory + '/bin')
        REPO=($RepositoryPath + '/'); FQDN=$ApplianceFqdn
        ADMIN=$InstallerAdminUser; PASS=$remotePasswordFile
        CONSENT= $(if ($AcceptVcfUploadConsent) { '--ignoreConsent' } else { '' })
    }
    # The consent flag must be an argument, not a quoted string.
    $uploadScript = $uploadScript.Replace("'--ignoreConsent'", '--ignoreConsent').Replace(" __CONSENT__", "")
    $uploadScript = $uploadScript.Replace(" ''", "")
    # Inspect before writing credentials or launching another upload.
    $uploadProbe = @'
set -eu
state=/var/lib/vcf-binary-upload
if systemctl is-active --quiet vcf-binary-upload.service; then
    echo VCF_UPLOAD_RUNNING
elif pgrep -f '[v]cf-download-tool binaries upload' >/dev/null; then
    echo VCF_UPLOAD_EXTERNAL
elif [ -f "$state/exit" ]; then
    echo "VCF_UPLOAD_EXIT=$(cat "$state/exit")"
else
    echo VCF_UPLOAD_NEW
fi
'@
    $probeResult = Invoke-Guest -Text (ConvertTo-GuestBashCommand -Script $uploadProbe) -Description 'Inspect existing binary upload' -Attempts 1
    if ($probeResult -match 'VCF_UPLOAD_EXTERNAL') { throw 'Previous upload still running outside managed service; inspect it before restarting.' }
    if ($probeResult -notmatch 'VCF_UPLOAD_RUNNING|VCF_UPLOAD_NEW|VCF_UPLOAD_EXIT=\d+') { throw 'Upload inspection returned no status.' }
    $uploadAlreadyComplete = $ReuseSuccessfulUpload -and ($probeResult -match '(?m)^VCF_UPLOAD_EXIT=0\s*$')
    if (-not $uploadAlreadyComplete -and $probeResult -notmatch 'VCF_UPLOAD_RUNNING') {
        $null = Invoke-Guest -Text 'umask 077; install -d -m 700 /var/lib/vcf-binary-upload' -Description 'Prepare private upload state'
    # Password is delivered to the guest via VMware Tools, not interpolated into a shell command.
    # The generated file is temporary and restricted to the root account.
    $localTempScript = Join-Path ([IO.Path]::GetTempPath()) ("vcf-pass-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($localTempScript, ($adminPassword + "`n"), (New-Object Text.UTF8Encoding($false)))
    $adminPassword = $null
    Invoke-Guest -Text ('umask 077; touch ' + (Quote-Bash $remotePasswordFile) + '; chmod 600 ' + (Quote-Bash $remotePasswordFile)) `
        -Description 'Prepare restricted admin password file' | Out-Null
    Copy-VMGuestFile -Server $ViConnection -VM $Vm -GuestCredential $GuestCredential `
        -LocalToGuest -Source $localTempScript -Destination $remotePasswordFile `
        -Force -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $localTempScript -Force -ErrorAction Stop
    $localTempScript = $null


        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-LinuxLineEndings -Text $uploadScript)))
        $launchTemplate = @'
set -eu
umask 077
state=/var/lib/vcf-binary-upload
exec 9>"$state/launch.lock"
flock -x 9
unit=vcf-binary-upload.service
if systemctl is-active --quiet "$unit"; then echo VCF_UPLOAD_RUNNING; exit 0; fi
if pgrep -f '[v]cf-download-tool binaries upload' >/dev/null; then exit 19; fi
printf '%s' __PAYLOAD__ | base64 -d > "$state/worker.sh"
cat > "$state/run.sh" <<'EOF'
#!/bin/bash
umask 077
state=/var/lib/vcf-binary-upload
trap 'rm -f -- "$state/password"' EXIT
/bin/bash "$state/worker.sh" > "$state/upload.log" 2>&1
rc=$?
printf '%s\n' "$rc" > "$state/exit.tmp"
mv -f "$state/exit.tmp" "$state/exit"
exit "$rc"
EOF
rm -f "$state/exit"
systemctl reset-failed "$unit" 2>/dev/null || true
systemd-run --unit=vcf-binary-upload -- /bin/bash "$state/run.sh"
echo VCF_UPLOAD_STARTED
'@
        $launch = New-GuestScript $launchTemplate @{ PAYLOAD=$payload }
        # Once launch is attempted the service owns its credential, even if the RPC fails.
        $uploadLaunchAttempted = $true
        $null = Invoke-Guest -Text (ConvertTo-GuestBashCommand -Script $launch) -Description 'Start detached binary upload' -Attempts 1
    }
    if (-not $uploadAlreadyComplete) {
        $uploadLaunchAttempted = $true
        $poll = @'
set -eu
state=/var/lib/vcf-binary-upload
if systemctl is-active --quiet vcf-binary-upload.service; then
    echo VCF_UPLOAD_RUNNING
elif [ -f "$state/exit" ]; then
    echo "VCF_UPLOAD_EXIT=$(cat "$state/exit")"
else
    echo VCF_UPLOAD_LOST
fi
if [ -f "$state/upload.log" ]; then wc -c < "$state/upload.log" | sed 's/^/Upload log bytes: /'; fi
'@
        $deadline = (Get-Date).AddHours($UploadTimeoutHours)
        $vmId = $Vm.Id
        while ($true) {
            if ((Get-Date) -ge $deadline) { throw 'Upload polling timed out; job may still be running. Rerun to attach.' }
            try {
                $output = Invoke-Guest -Text (ConvertTo-GuestBashCommand -Script $poll) -Description 'Poll binary upload' -Attempts 1
            } catch {
                Write-Log "Upload polling failed; reconnecting: $($_.Exception.Message)" 'WARN'
                try {
                    Disconnect-VIServer -Server $ViConnection -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    $ViConnection = Connect-VIServer -Server $VCenterServer -Credential $vcCredential -ErrorAction Stop
                    $Vm = Get-VM -Server $ViConnection -Id $vmId -ErrorAction Stop
                } catch { Write-Log "Reconnect failed: $($_.Exception.Message)" 'WARN' }
                Start-Sleep -Seconds $UploadPollSeconds
                continue
            }
            if ($output -match '(?m)^VCF_UPLOAD_EXIT=(\d+)\s*$') {
                if ([int]$Matches[1] -ne 0) { throw "Binary upload failed with exit $($Matches[1]); inspect /var/lib/vcf-binary-upload/upload.log" }
                break
            }
            if ($output -notmatch 'VCF_UPLOAD_RUNNING') { throw 'Upload service stopped without recording completion.' }
            Start-Sleep -Seconds $UploadPollSeconds
        }
    } else { Write-Log 'Reusing previous successful managed upload; set ReuseSuccessfulUpload to false for a fresh upload.' }
    Write-Log 'VCF Installer configuration and binary upload completed successfully.'
}
catch {
    if ($script:LogFile) { Write-Log "FAILED at stage '$stage': $($_.Exception.Message)" 'ERROR' }
    else { Write-Error $_ }
    throw
}
finally {
    if (-not $uploadLaunchAttempted -and $ViConnection -and $Vm -and $GuestCredential) {
        try {
            $cleanup = 'rm -f -- ' + (Quote-Bash $remotePasswordFile)
            $null = Invoke-VMScript -Server $ViConnection -VM $Vm -GuestCredential $GuestCredential `
                -ScriptType Bash -ScriptText $cleanup -ErrorAction Stop
        } catch { if ($script:LogFile) { Write-Log 'Could not verify removal of temporary guest password file.' 'WARN' } }
    }
    if ($localTempScript -and (Test-Path -LiteralPath $localTempScript)) {
        Remove-Item -LiteralPath $localTempScript -Force -ErrorAction SilentlyContinue
    }
    if ($ViConnection) {
        Disconnect-VIServer -Server $ViConnection -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    if ($script:LogFile) { Write-Log "Finished. Log: $script:LogFile" }
    $deploymentTimer.Stop()
    $durationMessage = 'The deployment took {0}' -f $deploymentTimer.Elapsed.ToString('d\d\ hh\h\ mm\m\ ss\s')
    if ($script:LogFile) {
        Write-Log $durationMessage
    } else {
        Write-Host $durationMessage
    }
}