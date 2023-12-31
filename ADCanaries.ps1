param([switch]$Populate,[switch]$Deploy,[switch]$Revert,[switch]$AuditSACLs,[switch]$GetObjectPropertiesGuids,[string]$Config,[string]$Output,[string]$Owner,[string]$CanaryContainer,[string]$ParentOU)


################################################################################
####                         Generic Functions                              ####
################################################################################
Import-Module ActiveDirectory
$ErrorActionPreference = "Inquire"

function DisplayHelpAndExit {
  Write-Host "
Usage : ./ADCanaries.ps1  -Populate -Config <Path> -ParentOU <OU> \
                                                   -Owner <Principal|Group Name> \
                                                   -CanaryContainer <Name>          : Populate default ADCanaries deployment; overwrites json config file provided.
                          -Deploy -Config <Path> -Output <Path>                     : Deploy ADCanaries using json configuration file and outputs lookup CSV with CanaryName,CanaryGUID
                          -Revert -Config <Path>                                    : Destroy ADCanaries using json configuration file
                          -AuditSACLs                                               : Display the list of existing AD objects with (ReadProperty|GenericAll) audit enabled to help measure DS Access audit failure activation impact
                          -GetObjectPropertiesGuids -Output <Path>                  : Retreives the schemaIDGuid for attributes of Canaries objectClass and outputs as csv
"
  exit $true
}

function DisplayCanaryBanner {
  Write-Host "

                       (
                      `-`-.
                      '(   >
                       _) (
                      /    )
                     /_,'  / 
 ADCanaries - v0.2     \  / 
=======================m""m===

  "
  Write-Host "[*] Deployment of ADCanaries require DS Access audit to be enabled on Failure on all your Domain Controllers :"
  Write-Host "
                  Computer Configuration
                    > Policies
                      > Windows Settings
                        > Security Settings
                          > Advanced Auditing Policy Configuration
                            > System Audit Policies
                              > DS Access
                                  Directory Service Access : Failure
  "
  Write-Host "[*] All failed read access to audit-enabled AD objects will generate Windows Security Events."
  Write-Host "[*] Please ensure you have estimated the amount of events this deployment will generate in your log managing system."
}


################################################################################
####                             MISC Functions                             ####
################################################################################

function ADObjectExists {
  param($Path)
  try{
    Get-ADObject -Identity "$Path" -ErrorAction Stop
    return $True
   }catch{
    #Write-Host $Error[0]
    #Write-Error $_
    return $False
   }
}

function ValidateAction {
  $Confirmation = ""
  while($Confirmation -ne "y" -and $Confirmation -ne "n"){
    $Confirmation = Read-Host "[?] Are you sure you want to deploy / remove ADCanaries on your domain ? (y/n)"
  }
  Write-Host ""

  if($Confirmation -eq "n"){exit $true}
}

function CheckSACLs {
  $ErrorActionPreference = "SilentlyContinue"
  Write-Host "`n[*] Listing AD objects with ReadAudit enabled (SACL) :"
  Get-ADObject -Filter * | ForEach-Object {
    $DN = $_.DistinguishedName
    (Get-Acl -Path "AD:/$DN" -Audit).Audit | ForEach-Object {
      $Rights = $_.ActiveDirectoryRights
      $Trustee = $_.IdentityReference
      if($Rights -match "ReadProperty" -or $Rights -match "GenericAll"){
        Write-Host "    - $DN : `t`t$Rights ($Trustee)"
      }
    }
  }
  $ErrorActionPreference = "Inquire"
}


function ListObjectAttributes {
    param($ClassName)
    # Not mine - code from easy365manager.com
    # Ref : https://www.easy365manager.com/how-to-get-all-active-directory-user-object-attributes/
    $Loop = $True
    $ClassArray = [System.Collections.ArrayList]@()
    $UserAttributes = [System.Collections.ArrayList]@()
    # Retrieve the User class and any parent classes
    While ($Loop) {
      $Class = Get-ADObject -SearchBase (Get-ADRootDSE).SchemaNamingContext -Filter { ldapDisplayName -Like $ClassName } -Properties AuxiliaryClass, SystemAuxiliaryClass, mayContain, mustContain, systemMayContain, systemMustContain, subClassOf, ldapDisplayName
      If ($Class.ldapDisplayName -eq $Class.subClassOf) {
        $Loop = $False
      }
      $ClassArray.Add($Class)
      $ClassName = $Class.subClassOf
    }
    # Loop through all the classes and get all auxiliary class attributes and direct attributes
    $ClassArray | ForEach-Object {
      # Get Auxiliary class attributes
      # '%' is an alias of 'ForEach-Object'. Alias can introduce possible problems and make scripts hard to maintain. Please consider changing alias to its full content.PSScriptAnalyzer(PSAvoidUsingCmdletAliases)
      $Aux = $_.AuxiliaryClass | ForEach-Object { Get-ADObject -SearchBase (Get-ADRootDSE).SchemaNamingContext -Filter { ldapDisplayName -like $_ } -Properties mayContain, mustContain, systemMayContain, systemMustContain } |
      Select-Object @{n = "Attributes"; e = { $_.mayContain + $_.mustContain + $_.systemMaycontain + $_.systemMustContain } } |
      Select-Object -ExpandProperty Attributes
      # Get SystemAuxiliary class attributes
      $SysAux = $_.SystemAuxiliaryClass | ForEach-Object { Get-ADObject -SearchBase (Get-ADRootDSE).SchemaNamingContext -Filter { ldapDisplayName -like $_ } -Properties MayContain, SystemMayContain, systemMustContain } |
      Select-Object @{n = "Attributes"; e = { $_.maycontain + $_.systemmaycontain + $_.systemMustContain } } |
      Select-Object -ExpandProperty Attributes
      # Get direct attributes
      $UserAttributes += $Aux + $SysAux + $_.mayContain + $_.mustContain + $_.systemMayContain + $_.systemMustContain
    }
    return $UserAttributes | Sort-Object | Get-Unique
}


function GetObjectPropertiesGuids {
    $ErrorActionPreference = "SilentlyContinue"
    param($Output)
    $AttributesList = New-Object System.Collections.ArrayList
    Foreach($Class in ("User", "Computer", "Group")){
        $Attributes = ListObjectAttributes -ClassName $Class
        Write-Host "[*] Attributes retreived for objectClass : $Class"
        Foreach($Attribute in $Attributes){
            $exp = "Get-ADObject -SearchBase (Get-ADRootDSE).schemaNamingContext -Filter "+ '"ldapDisplayName -eq '+ "'$attribute'"+' -and objectClass -eq '+ "'attributeSchema'"+ '" -Properties * | Select ldapDisplayName, schemaIDGuid'
            $a = (Invoke-Expression $exp)
            if(-not ($null -eq $a.schemaIDGuid)){
                $a.schemaIDGuid = $a.schemaIDGuid -as [guid]
                if(-not $AttributesList.Contains($a)){$AttributesList.Add($a)>$null}
            }
        }
        Write-Host "[*] Attribute's Guids retreived for objectClass : $Class"
    }
    Remove-Item -Path $Output -ErrorAction SilentlyContinue
    Add-Content -Path $Output ($AttributesList | ConvertTo-Csv)
    $Total = $AttributesList.Count
    Write-Host "[*] Total attributes retreived : $Total"
    Write-Host "[*] You can grab $Output to lookup these attributes when accessed is denied on the canaries"
    $ErrorActionPreference = "Inquire"
}

################################################################################
####                 Populate Configuration Functions                       ####
################################################################################
function DefaultCanaries {
    param($ConfigJsonObject, $ParentOU)

    $NewCanary = @{}
    $NewCanary.Name = "CanaryUser"
    $NewCanary.Type = "user"
    $NewCanary.Path = "$ParentOU"
    $NewCanary.Description = "[ADCanaries] Default Canary user -- change it"
    $NewCanary.OtherAttributes = @{}
    $NewCanary.ProtectedFromAccidentalDeletion = 1
    $ConfigJsonObject.Canaries.Add($NewCanary) > $null

    $NewCanary = @{}
    $NewCanary.Name = "CanaryComputer"
    $NewCanary.Type = "computer"
    $NewCanary.Path = "$ParentOU"
    $NewCanary.Description = "[ADCanaries] Default Canary computer -- change it"
    $NewCanary.OtherAttributes = @{}
    $NewCanary.ProtectedFromAccidentalDeletion = 1
    $ConfigJsonObject.Canaries.Add($NewCanary) > $null

    $NewCanary = @{}
    $NewCanary.Name = "CanaryGroup"
    $NewCanary.Type = "group"
    $NewCanary.Path = "$ParentOU"
    $NewCanary.Description = "[ADCanaries] Default Canary group -- change it"
    $NewCanary.OtherAttributes = @{}
    $NewCanary.ProtectedFromAccidentalDeletion = 1
    $ConfigJsonObject.Canaries.Add($NewCanary) > $null

    $NewCanary = @{}
    $NewCanary.Name = "CanaryOU"
    $NewCanary.Type = "organizationalUnit"
    $NewCanary.Path = "$ParentOU"
    $NewCanary.Description = "[ADCanaries] Default Canary OU -- change it"
    $NewCanary.OtherAttributes = @{}
    $NewCanary.ProtectedFromAccidentalDeletion = 1
    $ConfigJsonObject.Canaries.Add($NewCanary) > $null

    $NewCanary = @{}
    $NewCanary.Name = "CanaryPolicy"
    $NewCanary.Type = "domainPolicy"
    $NewCanary.Path = "$ParentOU"
    $NewCanary.Description = "[ADCanaries] Default Canary policy -- change it"
    $NewCanary.OtherAttributes = @{}
    $NewCanary.ProtectedFromAccidentalDeletion = 1
    $ConfigJsonObject.Canaries.Add($NewCanary) > $null

    $NewCanary = @{}
    $NewCanary.Name = "CanaryTemplate"
    $NewCanary.Type = "pKICertificateTemplate"
    $NewCanary.Path = "$ParentOU"
    $NewCanary.Description = "[ADCanaries] Default Canary certificate template -- change it"
    $NewCanary.OtherAttributes = @{}
    $NewCanary.ProtectedFromAccidentalDeletion = 1
    $ConfigJsonObject.Canaries.Add($NewCanary) > $null
}

function PopulateConf {
  param($Config, $ParentOU, $CanaryGroupName, $Owner, $ADGroups)
  ValidateAction

  $ConfigJsonObject                = @{}
  $ConfigJsonObject.Configuration  = @{}

  # Check if owner exists
  if( (Get-ADObject -Filter *).Name -contains $Owner) {
    $ConfigJsonObject.Configuration.CanaryOwner = $Owner
  }else{
    Write-Host "[!] $Owner not found in AD Objects please provide a valid Owner"
    exit $false
  }

  # Check if ParentOU exists
  if( -not((Get-ADObject -Filter *).DistinguishedName -contains $ParentOU)) {
    Write-Host "[!] $ParentOU not found in AD Objects please provide a valid Parent OU"
    exit $false
  }


  #### Overwrite output file
  Remove-Item -Path $Config -ErrorAction SilentlyContinue

  $ConfigJsonObject.Configuration.CanaryContainer                                  = @{}
  $ConfigJsonObject.Configuration.CanaryContainer.Name                             = "$CanaryGroupName"
  $ConfigJsonObject.Configuration.CanaryContainer.Type                             = "container"
  $ConfigJsonObject.Configuration.CanaryContainer.Path                             = "$ParentOU"
  $ConfigJsonObject.Configuration.CanaryContainer.OtherAttributes                  = @{}
  $ConfigJsonObject.Configuration.CanaryContainer.Description                      = "[ADCanaries] Default Container -- [VISIBLE TO ATTACKERS] change it"
  $ConfigJsonObject.Configuration.CanaryContainer.ProtectedFromAccidentalDeletion  = 1

  $CanariesPath = "CN=$CanaryGroupName,$ParentOU"

  $ConfigJsonObject.Configuration.CanaryGroup  = @{}
  $ConfigJsonObject.Configuration.CanaryGroup.Name                            = "$CanaryGroupName"
  $ConfigJsonObject.Configuration.CanaryGroup.Type                            = "group"
  $ConfigJsonObject.Configuration.CanaryGroup.Path                            = "$CanariesPath"
  $ConfigJsonObject.Configuration.CanaryGroup.OtherAttributes                 = @{}
  $ConfigJsonObject.Configuration.CanaryGroup.Description                     = "[ADCanaries] Default group -- [VISIBLE TO ATTACKERS] change it"
  $ConfigJsonObject.Configuration.CanaryGroup.ProtectedFromAccidentalDeletion = 1

  $ConfigJsonObject.Canaries = New-Object System.Collections.ArrayList

  DefaultCanaries -ConfigJsonObject $ConfigJsonObject -ParentOU $CanariesPath
  $ConfigJsonObject | ConvertTo-Json -Depth 20
  Add-Content -Path $Config  ($ConfigJsonObject | ConvertTo-Json -Depth 20)

}


################################################################################
####                    Deploy Canaries Functions                           ####
################################################################################
function SetAuditSACL {
    param($DistinguishedName)
    $Everyone       = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $GenericAll     = [System.DirectoryServices.ActiveDirectoryRights]::"ReadProperty"
    $SuccessFailure = [System.Security.AccessControl.AuditFlags]::"Success","Failure"
    $AccessRule     = New-Object System.DirectoryServices.ActiveDirectoryAuditRule($Everyone,$GenericAll,$SuccessFailure)
    $ACL            = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.SetAuditRule($AccessRule)
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    Write-Host "[*] SACL deployed on : $DistinguishedName"
}

function DenyAllOnCanariesAndChangeOwner {
    param($DistinguishedName, $Owner)
    $Everyone       = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $GenericAll     = [System.DirectoryServices.ActiveDirectoryRights]::"GenericAll"
    $Deny           = [System.Security.AccessControl.AccessControlType]::"Deny"
    $AccessRule     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Everyone,$GenericAll,$Deny)
    $NewOwner       = New-Object System.Security.Principal.SecurityIdentifier((Get-ADGroup "$Owner" -Properties *).ObjectSid)
    $ACL            = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.SetAccessRuleProtection($true, $false)
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    $ACL = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.SetAccessRule($AccessRule)
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    $ACL = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.SetOwner($NewOwner)
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    Write-Host "[*] Deny All DACL deployed on : $DistinguishedName"
}

function CreateCanary {
  param($Canary, $Output, $CanaryGroup, $Owner)

  $CanaryGroupDN = $CanaryGroup.distinguishedName
  $CanaryGroupToken = (Get-ADGroup $CanaryGroupDN -Properties @("primaryGroupToken")).primaryGroupToken
  $DistinguishedName = "CN="+$Canary.Name+","+$Canary.Path

  if (ADObjectExists -Path $DistinguishedName){
    Write-Host "[-] Canary User already existed : $DistinguishedName"
  }
  else {
    New-ADObject -Name $Canary.Name -Path $Canary.Path -Type $Canary.Type
    $CanaryObject = (Get-ADObject $DistinguishedName -Properties *)

    # Add users / computer / group Canary to CanaryGroup and set primary group
    if ($Canary.Type -eq "user"){
        Add-ADGroupMember -Identity $CanaryGroupDN -Members $DistinguishedName
        Set-ADObject $DistinguishedName -replace @{primaryGroupID=$CanaryGroupToken}
    }
    if ($Canary.Type -eq "computer"){
        Add-ADGroupMember -Identity $CanaryGroupDN -Members $DistinguishedName
        Set-ADObject $DistinguishedName -replace @{primaryGroupID=$CanaryGroupToken}
    }
    if ($Canary.Type -eq "group"){
        Add-ADGroupMember -Identity $CanaryGroupDN -Members $DistinguishedName
    }


    foreach($G in $CanaryObject.MemberOf){
        Remove-ADGroupMember -Identity $G -Members $DistinguishedName
    }
    Write-Host "[*] Canary created : $DistinguishedName"
    SetAuditSACL -DistinguishedName $DistinguishedName
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    DenyAllOnCanariesAndChangeOwner -DistinguishedName $DistinguishedName -Owner $Owner
    $SamAccountName = $CanaryObject.SamAccountName
    $Name = $CanaryObject.Name
    $Guid = $CanaryObject.ObjectGUID
    Add-Content -Path $Output "$SamAccountName,$Guid,$Name"
  }
}


function DeployCanaries {
  param($Config, $Output)
  ValidateAction
  #### Retreive Configuration from JSON file
  $ADCanariesJson  = Get-Content -Path $Config | ConvertFrom-Json
  $Configuration   = $ADCanariesJson.Configuration
  $CanaryGroup     = $Configuration.CanaryGroup
  $CanaryOwner     = $Configuration.CanaryOwner
  $CanaryContainer = $Configuration.CanaryContainer
  $Canaries        = $ADCanariesJson.Canaries

  #### Overwrite output file
  Remove-Item -Path $Output -ErrorAction SilentlyContinue
  Add-Content -Path $Output "CanarySamName,CanaryGUID,CanaryName"

  # Ensure Parent container exists
  $Path = $CanaryContainer.Path
  if(-not (ADObjectExists -Path $Path)){
    Write-Host "[-] Parent OU for default Canary OU not found : $Path -- aborting deployment"
    exit $false
  }

  # Create Container for Canaries
  $DistinguishedName = "CN="+$CanaryContainer.Name+","+$CanaryContainer.Path
  if (ADObjectExists -Path $DistinguishedName){
    Write-Host "[-] Canary OU already existed : $DistinguishedName"
  }
  else {
    New-ADObject -Name $CanaryContainer.Name -Path $CanaryContainer.Path -Type $CanaryContainer.Type -Description $CanaryContainer.Description
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    $ACL = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.SetAccessRuleProtection($true, $false)
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    Write-Host "[*] Canary OU created and inheritance disabled : $DistinguishedName"
  }

  # Create Primary Group for Canaries
  $DistinguishedName = "CN="+$CanaryGroup.Name+","+$CanaryGroup.Path
  if (ADObjectExists -Path $DistinguishedName){
    Write-Host "[-] Canary Primary Group already existed : $DistinguishedName"
  }
  else {
    New-ADGroup -Name $CanaryGroup.Name -GroupCategory Security -GroupScope Global -DisplayName $CanaryGroup.Name -Path $CanaryGroup.Path -Description $CanaryGroup.Description
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    $ACL = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.SetAccessRuleProtection($true, $false)
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    Write-Host "[*] Canary Group created and inheritance disabled : $DistinguishedName"
  }
  $CanaryGroup = (Get-ADGroup -Identity "$DistinguishedName" -Properties *)

  #### Create Canaries
  foreach ($Canary in $Canaries) {
    CreateCanary -Canary $Canary -Output $Output -CanaryGroup $CanaryGroup -Owner $CanaryOwner
  }

  # Deny all canary OU no audit
  $DN = "CN="+$CanaryContainer.Name+","+$CanaryContainer.Path
  DenyAllOnCanariesAndChangeOwner -DistinguishedName $DN -Owner $CanaryOwner

  Write-Host "`n[*] Done. Lookup Name:Guid for created objects :`n"
  Get-Content -Path $Output

}

################################################################################
####                   Destroy Canaries Functions                           ####
################################################################################

function RemoveDenyAllOnCanary {
    param($DistinguishedName)

    $Everyone       = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $GenericAll     = [System.DirectoryServices.ActiveDirectoryRights]::"GenericAll"
    $Deny           = [System.Security.AccessControl.AccessControlType]::"Deny"
    $AccessRule     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Everyone,$GenericAll,$Deny)
    $NewOwner       = New-Object System.Security.Principal.SecurityIdentifier($Everyone)
    $ACL            = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.SetOwner($NewOwner)
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    Write-Host "[*] Changed Owner to $Owner for : $DistinguishedName"
    $ACL            = Get-Acl -Path "AD:/$DistinguishedName"
    $ACL.RemoveAccessRule($AccessRule)>$null
    $ACL | Set-Acl -Path "AD:/$DistinguishedName"
    Write-Host "[*] Removed Deny All DACL deployed on : $DistinguishedName"
}

function DestroyCanary {
  param($DistinguishedName)
  if(Get-ADObject -Filter * | Where-Object {$_.DistinguishedName -eq $DistinguishedName}){
    RemoveDenyAllOnCanary -DistinguishedName $DistinguishedName
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    Remove-ADObject -Identity $DistinguishedName -Confirm:$false
    Write-Host "[*] ADCanary object removed : $DistinguishedName"
  }
  else {
    Write-Host "[-] ADCanary object not found : $DistinguishedName"
  }
}

function DestroyCanaries {
  param($Config)
  ValidateAction
  #### Retreive Configuration from JSON file
  $ADCanariesJson   = Get-Content -Path $Config | ConvertFrom-Json
  $Configuration    = $ADCanariesJson.Configuration
  $CanaryGroup      = $Configuration.CanaryGroup
  $CanaryContainer  = $Configuration.CanaryContainer
  $Canaries         = $ADCanariesJson.Canaries

  #### Remove DACL on Canary OU
  $DistinguishedName = "CN="+$CanaryContainer.Name+","+$CanaryContainer.Path
  if (ADObjectExists -Path $DistinguishedName){
    RemoveDenyAllOnCanary -DistinguishedName $DistinguishedName
  }else{
    Write-Host "[!] Canary OU not found : $DistinguishedName"
    Write-Host "[!] Aborting, please ensure provided OU exists and ADCanaries are located under this OU.`n"
    exit $false
  }
  #### Destroy Canary Users
  foreach ($Canary in $Canaries) {
    Write-Host ""
    $DistinguishedName = "CN="+$Canary.Name+","+$Canary.Path
    DestroyCanary -DistinguishedName $DistinguishedName
  }
  # Delete Primary Group for Canaries
  $DistinguishedName = "CN="+$CanaryGroup.Name+","+$CanaryGroup.Path
  Write-Host ""
  DestroyCanary -DistinguishedName $DistinguishedName
  # Delete OU for Canaries
  $DistinguishedName = "CN="+$CanaryContainer.Name+","+$CanaryContainer.Path
  Write-Host ""
  DestroyCanary -DistinguishedName $DistinguishedName
}

function CheckParameter($Param) {
  if ($nul -eq $Param) {
      DisplayHelpAndExit
  }
}

################################################################################
####                            MAIN()                                      ####
################################################################################
DisplayCanaryBanner

#### Validate arguments & execute functions
if($Populate.IsPresent){
  CheckParameter $Config
  CheckParameter $ParentOU
  CheckParameter $Owner
  CheckParameter $CanaryContainer
  PopulateConf -Config $Config -ParentOU $ParentOU -Owner $Owner -CanaryGroupName $CanaryContainer
} elseif($Deploy.IsPresent){
  CheckParameter $Config
  CheckParameter $Output
  DeployCanaries -Config $Config -Output $Output
} elseif($Revert.IsPresent){
  CheckParameter $Config
  DestroyCanaries -Config $Config
} elseif($AuditSACLs.IsPresent){
  CheckSACLs
} elseif($GetObjectPropertiesGuids.IsPresent){
  CheckParameter $Output
  GetObjectPropertiesGuids -Output $Output
}else{
  DisplayHelpAndExit
}
Write-Host "`n"
