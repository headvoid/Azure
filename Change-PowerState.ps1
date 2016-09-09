<#
    .SYNOPSIS
        This Azure Automation runbook automates the scheduled shutdown and startup of virtual machines in an Azure subscription. 

    .DESCRIPTION
        The runbook implements a solution for scheduled power management of Azure virtual machines in combination with tags
        on virtual machines or resource groups which define a shutdown schedule. Each time it runs, the runbook looks for all
        virtual machines or resource groups with a tag named "AutoShutdownSchedule" having a value defining the schedule, 
        e.g. "10PM -> 6AM". It then checks the current time against each schedule entry, ensuring that VMs with tags or in tagged groups 
        are shut down or started to conform to the defined schedule.

        This is a PowerShell runbook, as opposed to a PowerShell Workflow runbook.

        This runbook requires the "Azure" and "AzureRM.Resources" modules which are present by default in Azure Automation accounts.
        For detailed documentation and instructions, see: 
        
        https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure

    .PARAMETER AzureCredentialName
        The name of the PowerShell credential asset in the Automation account that contains username and password
        for the account used to connect to target Azure subscription. This user must be configured as co-administrator and owner
        of the subscription for best functionality. 

        By default, the runbook will use the credential with name "Default Automation Credential"

        For for details on credential configuration, see:
        http://azure.microsoft.com/blog/2014/08/27/azure-automation-authenticating-to-azure-using-azure-active-directory/
    
    .PARAMETER AzureSubscriptionName
        The name or ID of Azure subscription in which the resources will be created. By default, the runbook will use 
        the value defined in the Variable setting named "Default Azure Subscription"
    
    .PARAMETER Simulate
        If $true, the runbook will not perform any power actions and will only simulate evaluating the tagged schedules. Use this
        to test your runbook to see what it will do when run normally (Simulate = $false).

    .EXAMPLE
        For testing examples, see the documentation at:

        https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure
    
    .INPUTS
        None.

    .OUTPUTS
        Human-readable informational and error messages produced during the job. Not intended to be consumed by another runbook.
#>

param(
    [parameter(Mandatory=$false)]
	[String] $AzureCredentialName = "justin",
    [parameter(Mandatory=$false)]
	[String] $AzureSubscriptionName = "Visual Studio Enterprise: BizSpark",
    [parameter(Mandatory=$false)]
    [string]$PowerState = "off"
)

$VERSION = "0.1"



# Main runbook content
try
{
    $currentTime = (Get-Date).ToUniversalTime().AddHours(12)
    Write-Output "Runbook started at $currentTime. Version: $VERSION"
	
    # Retrieve subscription name from variable asset if not specified
    if($AzureSubscriptionName -eq "Use *Default Azure Subscription* Variable Value")
    {
        $AzureSubscriptionName = Get-AutomationVariable -Name "Default Azure Subscription"
        if($AzureSubscriptionName.length -gt 0)
        {
            Write-Output "Specified subscription name/ID: [$AzureSubscriptionName]"
        }
        else
        {
            throw "No subscription name was specified, and no variable asset with name 'Default Azure Subscription' was found. Either specify an Azure subscription name or define the default using a variable setting"
        }
    }

    # Retrieve credential
    write-output "Specified credential asset name: [$AzureCredentialName]"
    if($AzureCredentialName -eq "Use *Default Automation Credential* asset")
    {
        # By default, look for "Default Automation Credential" asset
        $azureCredential = Get-AutomationPSCredential -Name "Default Automation Credential"
        if($azureCredential -ne $null)
        {
		    Write-Output "Attempting to authenticate as: [$($azureCredential.UserName)]"
        }
        else
        {
            throw "No automation credential name was specified, and no credential asset with name 'Default Automation Credential' was found. Either specify a stored credential name or define the default using a credential asset"
        }
    }
    else
    {
        # A different credential name was specified, attempt to load it
        $azureCredential = Get-AutomationPSCredential -Name $AzureCredentialName
        if($azureCredential -eq $null)
        {
            throw "Failed to get credential with name [$AzureCredentialName]"
        }
    }

    # Connect to Azure using credential asset (classic API)
    $account = Add-AzureAccount -Credential $azureCredential
	
    # Check for returned userID, indicating successful authentication
    if(Get-AzureAccount -Name $azureCredential.UserName)
    {
        Write-Output "Successfully authenticated as user: [$($azureCredential.UserName)]"
    }
    else
    {
        throw "Authentication failed for credential [$($azureCredential.UserName)]. Ensure a valid Azure Active Directory user account is specified which is configured as a co-administrator (using classic portal) and subscription owner (modern portal) on the target subscription. Verify you can log into the Azure portal using these credentials."
    }

    # Validate subscription
    $subscriptions = @(Get-AzureSubscription | where {$_.SubscriptionName -eq $AzureSubscriptionName -or $_.SubscriptionId -eq $AzureSubscriptionName})
    if($subscriptions.Count -eq 1)
    {
        # Set working subscription
        $targetSubscription = $subscriptions | select -First 1
        $targetSubscription | Select-AzureSubscription

        # Connect via Azure Resource Manager 
        $resourceManagerContext = Add-AzureRmAccount -Credential $azureCredential -SubscriptionId $targetSubscription.SubscriptionId 

        $currentSubscription = Get-AzureSubscription -Current
        Write-Output "Working against subscription: $($currentSubscription.SubscriptionName) ($($currentSubscription.SubscriptionId))"
    }
    else
    {
        if($subscription.Count -eq 0)
        {
            throw "No accessible subscription found with name or ID [$AzureSubscriptionName]. Check the runbook parameters and ensure user is a co-administrator on the target subscription."
        }
        elseif($subscriptions.Count -gt 1)
        {
            throw "More than one accessible subscription found with name or ID [$AzureSubscriptionName]. Please ensure your subscription names are unique, or specify the ID instead"
        }
    }

    # Get a list of all virtual machines in subscription
    $resourceManagerVMList = @(Get-AzureRmResource | where {$_.ResourceType -like "Microsoft.*/virtualMachines"} | sort Name)
    $classicVMList = Get-AzureVM

    # For each VM, determine
    #  - Is it directly tagged for shutdown or member of a tagged resource group
    #  - Is the current time within the tagged schedule 
    # Then assert its correct power state based on the assigned schedule (if present)
	
	$vmArray = @()
			
    foreach($vm in $resourceManagerVMList)
    {
		$machineStatus = Get-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
		$currentStatus = $machineStatus.Statuses | where Code -like "PowerState*" 
    	$currentStatus = $currentStatus.Code -replace "PowerState/",""
			
		$object = New-Object -TypeName PSObject
		$object | Add-Member -Name 'vmName' -MemberType Noteproperty -Value $vm.Name
		$object | Add-Member -Name 'tagEntry' -MemberType Noteproperty -Value ($vm.Tags | where Name -eq "ChangePowerState")["Value"]
		$object | Add-Member -Name 'resourceGroup' -MemberType Noteproperty -Value $vm.ResourceGroupName
		$object | Add-Member -Name 'currentStatus' -MemberType Noteproperty -Value $currentStatus
		$vmArray += $object	
		
	}
	
	<#
	 # If the machine is running then we need to shut them down 1, 2, 3,...
	 # If not, then we power them up 3, 2, 1,...
	 #>
	if($vmArray[0].currentStatus -eq "running")
	{
		$vmArray = $vmArray |Sort-Object tagEntry
	}
	else
	{
		$vmArray = $vmArray |Sort-Object tagEntry -desc
	}
	
	foreach($vm in $vmArray)
	{	
		if($vm.currentStatus -eq "running")
		{
			Get-AzureRmVM -ResourceGroupName $vm.resourceGroup -Name $vm.vmName | Stop-AzureRmVM -Force
		}
		else
		{
			Get-AzureRmVM -ResourceGroupName $vm.resourceGroup -Name $vm.vmName | Start-AzureRmVM
		}
    }
    Write-Output "Finished processing virtual machine schedules"
}
catch
{
    $errorMessage = $_.Exception.Message
    throw "Unexpected exception: $errorMessage"
}
finally
{
    Write-Output "Runbook finished (Duration: $(("{0:hh\:mm\:ss}" -f ((Get-Date).ToUniversalTime() - $currentTime))))"
}