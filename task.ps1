$location = "uksouth"
$resourceGroupName = "mate-azure-task-18"

$virtualNetworkName = "todoapp"
$vnetAddressPrefix = "10.20.30.0/24"
$webSubnetName = "webservers"
$webSubnetIpRange = "10.20.30.0/26"
$mngSubnetName = "management"
$mngSubnetIpRange = "10.20.30.128/26"

$sshKeyName = "linuxboxsshkey"
$sshKeyPublicKey = Get-Content "~/.ssh/id_rsa.pub"

$vmImage = "Ubuntu2204"
$vmSize = "Standard_B1s"
$webVmName = "webserver"
$jumpboxVmName = "jumpbox"
$dnsLabel = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName = "or.nottodo"

$lbName = "loadbalancer"
$lbIpAddress = "10.20.30.62"


Write-Host "Creating a resource group $resourceGroupName ..."
New-AzResourceGroup -Name $resourceGroupName -Location $location

Write-Host "Creating web network security group..."
$webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443
$webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $webSubnetName -SecurityRules $webHttpRule

Write-Host "Creating mngSubnet network security group..."
$mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $mngSubnetName -SecurityRules $mngSshRule

Write-Host "Creating a virtual network ..."
$webSubnet = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
$mngSubnet = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
$virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $webSubnet,$mngSubnet

Write-Host "Creating a SSH key resource ..."
New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey

Write-Host "Creating a web server VM ..."

for (($zone = 1); ($zone -le 2); ($zone++) ) {
   $vmName = "$webVmName-$zone"
   New-AzVm `
   -ResourceGroupName $resourceGroupName `
   -Name $vmName `
   -Location $location `
   -image $vmImage `
   -size $vmSize `
   -SubnetName $webSubnetName `
   -VirtualNetworkName $virtualNetworkName `
   -SshKeyName $sshKeyName 
   $Params = @{
      ResourceGroupName  = $resourceGroupName
      VMName             = $vmName
      Name               = 'CustomScript'
      Publisher          = 'Microsoft.Azure.Extensions'
      ExtensionType      = 'CustomScript'
      TypeHandlerVersion = '2.1'
      Settings          = @{fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_18_configure_load_balancing/main/install-app.sh'); commandToExecute = './install-app.sh'}
   }
   Set-AzVMExtension @Params
}

Write-Host "Creating a public IP ..."
$publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -Location $location -Sku Basic -AllocationMethod Dynamic -DomainNameLabel $dnsLabel
Write-Host "Creating a management VM ..."
New-AzVm `
-ResourceGroupName $resourceGroupName `
-Name $jumpboxVmName `
-Location $location `
-image $vmImage `
-size $vmSize `
-SubnetName $mngSubnetName `
-VirtualNetworkName $virtualNetworkName `
-SshKeyName $sshKeyName `
-PublicIpAddressName $jumpboxVmName


Write-Host "Creating a private DNS zone ..."
$Zone = New-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName 
$Link = New-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $Zone.Name -VirtualNetworkId $virtualNetwork.Id -EnableRegistration


Write-Host "Creating an A DNS record ..."
$Records = @()
$Records += New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress
New-AzPrivateDnsRecordSet -Name "todo" -RecordType A -ResourceGroupName $resourceGroupName -TTL 1800 -ZoneName $privateDnsZoneName -PrivateDnsRecords $Records

# Prepare variables, required for creation and configuration of load balancer - 
# you will need them to setup a load balancer 
$webSubnetId = (Get-AzVirtualNetworkSubnetConfig -Name $webSubnetName -VirtualNetwork $virtualNetwork).Id

# Write your code here -> 
Write-Host "Creating a load balancer ..."
# Step 1: Create Load Balancer frontend IP configuration
$frontendIpConfig = New-AzLoadBalancerFrontendIpConfig -Name "FrontendConfig" `
    -SubnetId $webSubnetId `
    -PrivateIpAddress $lbIpAddress

# Step 2: Create Load Balancer backend pool
$backendPool = New-AzLoadBalancerBackendAddressPoolConfig -Name "BackendPool"

# Step 3: Create Load Balancer health probe
$healthProbe = New-AzLoadBalancerProbeConfig -Name "HealthProbe" `
    -Protocol Tcp `
    -Port 8080 `
    -IntervalInSeconds 15 `
    -ProbeCount 4

# Step 4: Create Load Balancing rule
$lbRule = New-AzLoadBalancerRuleConfig -Name "HttpRule" `
    -FrontendIpConfiguration $frontendIpConfig `
    -BackendAddressPool $backendPool `
    -Probe $healthProbe `
    -Protocol Tcp `
    -FrontendPort 80 `
    -BackendPort 8080

# Step 5: Create the Load Balancer
$loadBalancer = New-AzLoadBalancer -ResourceGroupName $resourceGroupName `
    -Name $lbName `
    -Location $location `
    -FrontendIpConfiguration $frontendIpConfig `
    -BackendAddressPool $backendPool `
    -Probe $healthProbe `
    -LoadBalancingRule $lbRule

Write-Host "Adding VMs to the backend pool"
$vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object {$_.Name.StartsWith($webVmName)}
foreach ($vm in $vms) {
    $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object {$_.Id -eq $vm.NetworkProfile.NetworkInterfaces.Id}    
    $ipCfg = $nic.IpConfigurations | Where-Object {$_.Primary}
    
    if ($ipCfg) {
        # Create a new backend address pool reference if it doesn't already exist
        $backendPoolConfig = New-Object Microsoft.Azure.Commands.Network.Models.PSBackendAddressPool
        $backendPoolConfig.Id = $backendPool.Id
        
        # If the NIC has existing backend pools, add the new one; otherwise, create a new list with this pool
        if ($ipCfg.LoadBalancerBackendAddressPools) {
            $ipCfg.LoadBalancerBackendAddressPools.Add($backendPoolConfig)
        } else {
            $ipCfg.LoadBalancerBackendAddressPools = [System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSBackendAddressPool]]::new()
            $ipCfg.LoadBalancerBackendAddressPools.Add($backendPoolConfig)
        }
        
        Set-AzNetworkInterface -NetworkInterface $nic
        Write-Host "NIC $($nic.Name) successfully added to backend pool"
    } else {
        Write-Host "Error: Could not find primary IP configuration for NIC $($nic.Name)"
    }
}
# Write-Host "Adding VMs to the backend pool"
# $vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object {$_.Name.StartsWith($webVmName)}
# foreach ($vm in $vms) {
#    $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object {$_.Id -eq $vm.NetworkProfile.NetworkInterfaces.Id}    
#    $ipCfg = $nic.IpConfigurations | Where-Object {$_.Primary} 
#    $ipCfg.LoadBalancerBackendAddressPools.Add($bepool)
#    Set-AzNetworkInterface -NetworkInterface $nic
# }