$location = "westeurope"
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
$vmSize = "Standard_B2s"
$webVmName = "webserver"
$jumpboxVmName = "jumpbox"
$dnsLabel = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName = "or.nottodo"

$lbName = "loadbalancer"
$lbIpAddress = "10.20.30.62"

$adminUsername = "azureuser"
$adminPassword = ConvertTo-SecureString ("P@" + (New-Guid).Guid) -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($adminUsername, $adminPassword)


Write-Host "Creating a resource group $resourceGroupName ..."
New-AzResourceGroup -Name $resourceGroupName -Location $location

Write-Host "Creating web network security group..."
$webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP/HTTPS and app port" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 `
   -SourceAddressPrefix * -SourcePortRange * `
   -DestinationAddressPrefix * -DestinationPortRanges @("80","443","8080")

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
   -SshKeyName $sshKeyName `
   -Credential $cred 
   $Params = @{
      ResourceGroupName  = $resourceGroupName
      VMName             = $vmName
      Name               = 'CustomScript'
      Publisher          = 'Microsoft.Azure.Extensions'
      ExtensionType      = 'CustomScript'
      TypeHandlerVersion = '2.1'
      Settings          = @{fileUris = @('https://raw.githubusercontent.com/KyryloKilin/azure_task_18_configure_load_balancing/main/install-app.sh'); commandToExecute = './install-app.sh'}
   }
   Set-AzVMExtension @Params
}

Write-Host "Creating a public IP ..."
$publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -Location $location -Sku Standard -AllocationMethod Static -DomainNameLabel $dnsLabel
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
-PublicIpAddressName $jumpboxVmName `
-Credential $cred


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

# 1) Собираем private IP двух web VM (webserver-1 и webserver-2)
$webVms = Get-AzVM -ResourceGroupName $resourceGroupName |
  Where-Object { $_.Name -like "$webVmName-*" } |
  Sort-Object Name

if ($webVms.Count -ne 2) {
  throw "Expected 2 web VMs, found $($webVms.Count). Check web VM creation."
}

$backendAddresses = @()
$idx = 1
foreach ($vm in $webVms) {
  $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
  $nicName = ($nicId -split "/")[-1]
  $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName -Name $nicName
  $privateIp = $nic.IpConfigurations[0].PrivateIpAddress

  $backendAddresses += New-AzLoadBalancerBackendAddressConfig `
    -Name "web$idx" `
    -IpAddress $privateIp `
    -VirtualNetworkId $virtualNetwork.Id

  $idx++
}

# 2) Frontend IP конфигурация (PRIVATE, STATIC) в web subnet
$lbFrontend = New-AzLoadBalancerFrontendIpConfig `
  -Name "$lbName-fe" `
  -SubnetId $webSubnetId `
  -PrivateIpAddress $lbIPAddress `
  -PrivateIpAllocationMethod Static

# 3) Backend pool с 2 backend addresses
$backendPool = New-AzLoadBalancerBackendAddressPoolConfig `
  -Name "$lbName-be" `
  -BackendAddress $backendAddresses

# 4) Health probe на 8080 (TCP)
$probe = New-AzLoadBalancerProbeConfig `
  -Name "$lbName-probe" `
  -Protocol Tcp `
  -Port 8080 `
  -IntervalInSeconds 15 `
  -ProbeCount 2

# 5) Load balancing rule: frontend 80 -> backend 8080
$rule = New-AzLoadBalancerRuleConfig `
  -Name "$lbName-rule" `
  -Protocol Tcp `
  -FrontendIpConfiguration $lbFrontend `
  -BackendAddressPool $backendPool `
  -Probe $probe `
  -FrontendPort 80 `
  -BackendPort 8080

# 6) Создаём internal Standard Load Balancer
$lb = New-AzLoadBalancer `
  -ResourceGroupName $resourceGroupName `
  -Name $lbName `
  -Location $location `
  -Sku Standard `
  -FrontendIpConfiguration $lbFrontend `
  -BackendAddressPool $backendPool `
  -Probe $probe `
  -LoadBalancingRule $rule

Write-Host "Attaching web VMs NICs to the backend pool..."


$bepool = $lb.BackendAddressPools[0]

foreach ($vm in $webVms) {
  $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
  $nicName = ($nicId -split "/")[-1]

  $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName -Name $nicName

  $nic.IpConfigurations[0].LoadBalancerBackendAddressPools = @($bepool)

  Set-AzNetworkInterface -NetworkInterface $nic | Out-Null

  Write-Host "Attached NIC $nicName to backend pool"
}


# Write-Host "Adding VMs to the backend pool"
# $vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object {$_.Name.StartsWith($webVmName)}
# foreach ($vm in $vms) {
#    $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object {$_.Id -eq $vm.NetworkProfile.NetworkInterfaces.Id}    
#    $ipCfg = $nic.IpConfigurations | Where-Object {$_.Primary} 
#    $ipCfg.LoadBalancerBackendAddressPools.Add($bepool)
#    Set-AzNetworkInterface -NetworkInterface $nic
# }
