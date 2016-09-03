Param(
    [string]$migrationDirection="P2S",
	[string]$subscriptionId = "78e81c91-258c-4ed5-9ada-04e785752331",
	[string]$destStorageAcc="ocsr2storage",
	[string]$destCloudService = "ocsr2citrixv2",
	[string]$machineList = "machinelist.txt",
	[string]$destinationStorageAccountName = "ocsr2storage"
)

Add-AzureAccount

Set-AzureSubscription -SubscriptionId $subscriptionId -CurrentStorageAccountName $destStorageAcc

try 
{
	$machines = Get-Content $machineList -ErrorAction Stop
}
catch 
{
	Write-Host "Unable to open" $machineList
}

foreach($machineName in $machines)
{
       $attachedDrives = Get-AzureDisk |where {$_.AttachedTo -like "*$machineName*" } |Sort-Object -Descending OS
       
       $vm = Get-AzureVM |where {$_.Name -eq "$machineName"}
       $vmSize = $vm.InstanceSize
       $vmCS = $vm.ServiceName
       $vmIP = $vm.IpAddress
		$vnet = $vm.VirtualNetworkName
		$subnet = $vm | Get-AzureSubnet
       
       #check for S in instance Size
       if($vmSize -like "*DS*")
       {
        $vmSize = $vmSize.Replace("DS","D")
        Write-Host "Line Replaced"
       }

       $attachedDrives |select DiskName
       $vmSize
       $vmCS
       $vmIP

       #power down the Existing VM
       Write-Host "Power down VM"       
        Stop-AzureVM -Name $machineName -serviceName $vmCS -Force
 
       # move the drives
       $count = 0
       ForEach($drives in $attachedDrives)
       {
            
            $destStorageAccSrc = $drives.MediaLink
            $DriveStorageAcc = $destStorageAccSrc.DnsSafeHost.Split(".")
            Write-Host "Storage name" $DriveStorageAcc[0]
            $StorageKey = (Get-AzureStorageKey -StorageAccountName $DriveStorageAcc[0]).Primary

            $blobName = $destStorageAccSrc.Segments[2]

            $activityLabel = "Copy disk "+$blobName+" from "+$DriveStorageAcc[0]
		    Write-Host $activityLabel

            # Source Storage Account Information #
            $sourceStorageAccountName = $DriveStorageAcc[0]
            $sourceKey = $StorageKey
            $sourceContext = New-AzureStorageContext –StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceKey  
            $sourceContainer = "vhds"

            # Destination Storage Account Information #
            $destinationKey = "7vW1smiPne3ba+6UfvlsFptHgXbyPsyZT2jG8fipYvo9a4JKEAB7GRVDol6MlwT9la1fyJTWzX+2a6lqmoGeYQ=="
            $destinationContext = New-AzureStorageContext –StorageAccountName $destinationStorageAccountName -StorageAccountKey (Get-AzureStorageKey -StorageAccountName $destinationStorageAccountName).Primary  

            # Create the destination container #
            $destinationContainerName = "copiedvhds"
            New-AzureStorageContainer -Name $destinationContainerName -Context $destinationContext 

			# Wait 1 minute
			#Start-Sleep -s 60
			
			# break the lease if it exists
			#.\BreakBlobLease.ps1 -StorageAccountName $DriveStorageAcc[0] -ContainerName "vhds" -BlobName $blobName
			
            # Copy the blob # 
		   try
		   {
			   Write-Host "source" $destStorageAccSrc
				$blobCopy = Start-AzureStorageBlobCopy -DestContainer $destinationContainerName `
										-DestContext $destinationContext `
										-SrcBlob $blobName `
										-Context $sourceContext `
										-SrcContainer $sourceContainer `
										-ErrorAction Stop 
			   Write-Progress -Activity $activityLabel -status "Copying" -percentComplete 0
			}
		   catch
		   {
			   Write-Host "Something went wrong with the file copy"
			   exit
		   }

            while(($blobCopy | Get-AzureStorageBlobCopyState).Status -eq "Pending")
            {
                Start-Sleep -s 3
			<#	if($blobCopy.BytesCopied -eq 0)
				{
					$percentageComplete = 0
				}
				else
				{
					$blobCopy | Get-AzureStorageBlobCopyState
					$totalBytes = $blobCopy.TotalBytes
					$copiedBytes = $blobCopy.BytesCopied
					$percentageComplete = $copiedBytes / $totalBytes * 100
				}
				Write-Progress -Activity $activityLabel -status "Copying" -percentComplete $percentageComplete
				#>
            }

			if(($blobCopy | Get-AzureStorageBlobCopyState).Status -eq "Failed")
			{
				$blobCopy
				Write-Progress -Activity $activityLabel -status "failed" -percentComplete $percentageComplete
				exit
			}
			
            $newDiskName = "https://"+$destinationStorageAccountName+".blob.core.windows.net/copiedvhds/"+$blobName

            If($count -eq 0)
            {
                $diskName = $machineName+"-Drive-"+$count
                Add-AzureDisk -DiskName $diskName -OS Windows -MediaLocation $newDiskName -Verbose
            }
            else
            {
                 $diskName = $machineName+"-Drive-"+$count
                 Add-AzureDisk -DiskName $diskName -MediaLocation $newDiskName -Verbose
           }
           $count++
       }

       $OSDrive = $machineName+"-Drive-0"
       $vmc = New-AzureVMConfig -Name $machineName -InstanceSize $vmSize -DiskName $OSDrive
       Add-AzureEndpoint -Protocol tcp -LocalPort 3389 -Name 'RDP' -VM $vmc
       Set-AzureSubnet $subnet -VM $vmc
       
       # remove disk 0 as this is part of the config command. Any remaining ones we add as dataDisks
       
       $dataDisks = $attachedDrives[1..($attachedDrives.Length-1)]
       
       $lun = 1
       foreach($diskName in $dataDisks.DiskName)
       {
              $diskName = $machineName+"-Drive-"+$lun
              Add-AzureDataDisk -Import $diskName -LUN $lun -VM $vmc
              $lun++
       }
       
       #remove the existing VM
       #Remove-AzureVM -Name $machineName -serviceName $vmCS
       
       # found moving on immediately just upsets things, so we'll wait 2 minutes...
       Start-Sleep -s 120
       
       #create it again, and wait for it to powerup
       New-AzureVM -ServiceName $destCloudService -VMs $vmc -VNetName $vnet
       $vmState = Get-AzureVM -Name $machineName -serviceName $destCloudService
       while($vmState.Status -ne "ReadyRole")
       {
              Start-Sleep -s 10
              $vmState = Get-AzureVM -Name $machineName -serviceName $destCloudService
       }

       # re-ip the server, then move on
       Get-AzureVM -Name $machineName -serviceName $destCloudService | Set-AzureStaticVNetIP -IPAddress $vmIP
}
