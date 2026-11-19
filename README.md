\# Deploy and Configure VCF Installer



This PowerShell script deploys the VMware Cloud Foundation (VCF) Installer 9.1.1 OVA to a vCenter-managed ESXi host. It can also configure the appliance's binary repository, download depot files over HTTP(S), and upload the binaries using the VCF Download Tool. The script will side-load the binaries directly from a local webserver to the VCF installer as an optional part of the deplyment.



\## Requirements



\- Windows with PowerShell 5.1 or later and VMware OVF Tool.

\- The VCF Installer 9.1.1 OVA, available locally or on an accessible SMB share.

\- A vCenter account with permission to deploy the appliance, plus a target ESXi host, datastore, and VM network.

\- For optional configuration, install VMware PowerCLI (`VMware.VimAutomation.Core`) and have the appliance credentials and a reachable VCF Download Tool URL. If depot copying is enabled, the appliance also needs access to a browsable HTTP(S) depot.



\## How to use



1\. Open `Deploy-and-Configure-VCFInstaller.ps1` and edit the `USER SETTINGS` section. Set the OVA path, vCenter inventory, datastore, VM network, and appliance network settings. Replace the built-in lab passwords with credentials appropriate for your environment.

2\. Set `$ConfigureAfterDeployment` to `$false` for deployment only or `$true` to also configure the binary repository. If the depot files are already in place, set `$CopyVCFDepotFiles` to `$false`.

3\. From the repository folder, run the script.



&#x20;  ```powershell

&#x20;  .\\Deploy-and-Configure-VCFInstaller.ps1

&#x20;  ```



&#x20;  The script prompts for vCenter credentials by default and writes logs to `.\\logs`.

