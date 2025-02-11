# Parameters for source tenant
$sourceTenantId = "<source-tenant-id>"
$sourceClientId = "<source-spn-client-id>"
$sourceClientSecret = "<source-spn-client-secret>"
$sourceGroupId = "<source-group-id>"

# Load destination tenants configuration
$configPath = Join-Path $PSScriptRoot "config\destinations.json"
$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

# Install required modules if not present
$requiredModules = @("Microsoft.Graph.Authentication", "Microsoft.Graph.Groups", "Microsoft.Graph.Users")
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Install-Module -Name $module -Force -AllowClobber
    }
}

# Function to connect to Microsoft Graph with SPN
function Connect-ToGraph {
    param (
        [string]$tenantId,
        [string]$clientId,
        [string]$clientSecret
    )
    
    $body = @{
        Grant_Type    = "client_credentials"
        Scope         = "https://graph.microsoft.com/.default"
        Client_Id     = $clientId
        Client_Secret = $clientSecret
    }
    
    $connectUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $token = Invoke-RestMethod -Uri $connectUri -Method Post -Body $body
    
    Connect-MgGraph -AccessToken $token.access_token
}

try {
    # Connect to source tenant
    Write-Host "Connecting to source tenant..."
    Connect-ToGraph -tenantId $sourceTenantId -clientId $sourceClientId -clientSecret $sourceClientSecret
    
    # Get members from source group
    $sourceMembers = Get-MgGroupMember -GroupId $sourceGroupId
    Write-Host "Found $($sourceMembers.Count) members in source group"
    
    # Loop through each destination tenant
    foreach ($destTenant in $config.destinationTenants) {
        try {
            Write-Host "`nProcessing destination tenant: $($destTenant.tenantId)"
            
            # Connect to destination tenant
            Write-Host "Connecting to destination tenant..."
            Connect-ToGraph -tenantId $destTenant.tenantId -clientId $destTenant.clientId -clientSecret $destTenant.clientSecret
            
            # Get existing members in destination group
            $destMembers = Get-MgGroupMember -GroupId $destTenant.groupId
            
            foreach ($member in $sourceMembers) {
                $userPrincipalName = $member.AdditionalProperties.userPrincipalName
                
                if ($userPrincipalName) {
                    # Check if user exists in destination tenant
                    $destUser = Get-MgUser -Filter "userPrincipalName eq '$userPrincipalName'" -ErrorAction SilentlyContinue
                    
                    if (-not $destUser) {
                        # Create user in destination tenant
                        $sourceUser = Get-MgUser -UserId $member.Id
                        $newUserParams = @{
                            UserPrincipalName = $userPrincipalName
                            DisplayName       = $sourceUser.DisplayName
                            MailNickname     = $sourceUser.MailNickname
                            AccountEnabled   = $true
                            PasswordProfile  = @{
                                Password = [System.Web.Security.Membership]::GeneratePassword(16, 3)
                                ForceChangePasswordNextSignIn = $true
                            }
                        }
                        
                        $destUser = New-MgUser @newUserParams
                        Write-Host "Created user: $userPrincipalName"
                    }
                    
                    # Add user to destination group if not already a member
                    if ($destUser -and $destUser.Id -notin $destMembers.Id) {
                        New-MgGroupMember -GroupId $destTenant.groupId -DirectoryObjectId $destUser.Id
                        Write-Host "Added user to destination group: $userPrincipalName"
                    }
                }
            }
            
            Write-Host "Sync completed successfully for tenant: $($destTenant.tenantId)"
        }
        catch {
            Write-Error "An error occurred processing tenant $($destTenant.tenantId): $_"
            continue
        }
        finally {
            Disconnect-MgGraph
        }
    }
}
catch {
    Write-Error "An error occurred: $_"
}
finally {
    Disconnect-MgGraph
}