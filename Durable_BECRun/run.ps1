param($Context)
#$Context does not allow itself to be cast to a pscustomobject for some reason, so we convert
$context = $Context | ConvertTo-Json | ConvertFrom-Json
$APIName = $TriggerMetadata.FunctionName
Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME  -message "Accessed this API" -Sev "Debug"
Write-Host "PowerShell HTTP trigger function processed a request."
Write-Host ($Context | ConvertTo-Json)
$TenantFilter = $Context.input.tenantfilter
$SuspectUser = $Context.input.userid
$GUID = $context.input.GUID



try {
  $startDate = (Get-Date).AddDays(-7)
  $endDate = (Get-Date)
  $upn = "notRequired@required.com"
  $tokenvalue = ConvertTo-SecureString (Get-GraphToken -AppID 'a0c73c16-a7e3-4564-9a95-2bdf47383716' -RefreshToken $ENV:ExchangeRefreshToken -Scope 'https://outlook.office365.com/.default' -Tenantid $TenantFilter).Authorization -AsPlainText -Force
  $credential = New-Object System.Management.Automation.PSCredential($upn, $tokenValue)
  $session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "https://ps.outlook.com/powershell-liveid?DelegatedOrg=$($TenantFilter)&BasicAuthToOAuthConversion=true" -Credential $credential -Authentication Basic -AllowRedirection -ErrorAction Continue
  $s = Import-PSSession $session -ea Silentlycontinue -AllowClobber -CommandName "Search-unifiedAuditLog", "Get-AdminAuditLogConfig"
  $7dayslog = if ((Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled -eq $false) {
    "AuditLog is disabled. Cannot perform full analysis"
  }
  else {
    $sessionid = Get-Random -Minimum 10000 -Maximum 99999
    $operations = @(
      'Add OAuth2PermissionGrant.',
      'Consent to application.',
      "New-InboxRule",
      "Set-InboxRule",
      "UpdateInboxRules",
      "Remove-MailboxPermission",
      "Add-MailboxPermission",
      "UpdateCalendarDelegation",
      "AddFolderPermissions",
      "MailboxLogin",
      "Add user.",
      "Change user password.",
      "Reset user password."
    )
    do {
      $logsTenant = Search-unifiedAuditLog -SessionCommand ReturnLargeSet -ResultSize 5000 -StartDate $startDate -EndDate $endDate -sessionid $sessionid -Operations $operations
      Write-Host "Retrieved $($logsTenant.count) logs" -ForegroundColor Yellow
      $logsTenant
    } while ($LogsTenant.count % 5000 -eq 0 -and $LogsTenant.count -ne 0)
  }
  Get-PSSession | Remove-PSSession
  #Get user last logon
  $uri = "https://login.microsoftonline.com/$($TenantFilter)/oauth2/token"
  $body = "resource=https://admin.microsoft.com&grant_type=refresh_token&refresh_token=$($ENV:ExchangeRefreshToken)"
  Write-Host "getting token"
  $token = Invoke-RestMethod $uri -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction SilentlyContinue -Method post
  Write-Host "got token"
  $LastSignIn = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri "https://admin.microsoft.com/admin/api/users/$($SuspectUser)/lastSignInInfo" -Method GET -Headers @{
    Authorization            = "Bearer $($token.access_token)";
    "x-ms-client-request-id" = [guid]::NewGuid().ToString();
    "x-ms-client-session-id" = [guid]::NewGuid().ToString()
    'x-ms-correlation-id'    = [guid]::NewGuid()
    'X-Requested-With'       = 'XMLHttpRequest' 
  }
  #List all users devices
  Write-Host "Last Sign in is: $LastSignIn"
  $Bytes = [System.Text.Encoding]::UTF8.GetBytes($SuspectUser)
  $base64IdentityParam = [Convert]::ToBase64String($Bytes)
  Try {
    $Devices = New-GraphGetRequest -uri "https://outlook.office365.com:443/adminapi/beta/$($TenantFilter)/mailbox('$($base64IdentityParam)')/MobileDevice/Exchange.GetMobileDeviceStatistics()/?IsEncoded=True" -Tenantid $tenantfilter -scope ExchangeOnline
  }
  catch {
    $Devices = $null
  }
  $PermissionsLog = ($7dayslog | Where-Object -Property Operations -In "Remove-MailboxPermission", "Add-MailboxPermission", "UpdateCalendarDelegation", "AddFolderPermissions" ).AuditData | ConvertFrom-Json -Depth 100 | ForEach-Object {
    $perms = if ($_.Parameters) {
      $_.Parameters | ForEach-Object { if ($_.Name -eq "AccessRights") { $_.Value } }
    }
    else
    { $_.item.ParentFolder.MemberRights }
    $objectID = if ($_.ObjectID) { $_.ObjectID } else { $($_.MailboxOwnerUPN) + $_.item.ParentFolder.Path }
    [pscustomobject]@{
      Operation   = $_.Operation
      UserKey     = $_.UserKey
      ObjectId    = $objectId
      Permissions = $perms
    }
  }

  $RulesLog = @(($7dayslog | Where-Object -Property Operations -In "New-InboxRule", "Set-InboxRule", "UpdateInboxRules").AuditData | ConvertFrom-Json) | ForEach-Object {
    Write-Host ($_ | ConvertTo-Json)
    [pscustomobject]@{
      ClientIP      = $_.ClientIP
      CreationTime  = $_.CreationTime
      UserId        = $_.UserId
      RuleName      = ($_.OperationProperties | ForEach-Object { if ($_.Name -eq "RuleName") { $_.Value } })
      RuleCondition = ($_.OperationProperties | ForEach-Object { if ($_.Name -eq "RuleCondition") { $_.Value } })
    }
  }
  
  $Results = [PSCustomObject]@{
    AddedApps                = @(($7dayslog | Where-Object -Property Operations -In 'Add OAuth2PermissionGrant.', 'Consent to application.').AuditData | ConvertFrom-Json)
    SuspectUserMailboxLogons = @(($7dayslog | Where-Object -Property Operations -In  "MailboxLogin" ).AuditData | ConvertFrom-Json)
    LastSuspectUserLogon     = @($LastSignIn)
    SuspectUserDevices       = @($Devices)
    NewRules                 = @($RulesLog)
    MailboxPermissionChanges = @($PermissionsLog)
    NewUsers                 = @(($7dayslog | Where-Object -Property Operations -In "Add user.").AuditData | ConvertFrom-Json)
    ChangedPasswords         = @(($7dayslog | Where-Object -Property Operations -In "Change user password.", "Reset user password.").AuditData | ConvertFrom-Json)
  }
    
  #Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME -tenant $($tenantfilter) -message "Assigned $($appFilter) to $assignTo" -Sev "Info"

}
catch {
  #Log-Request -user $request.headers.'x-ms-client-principal' -API $APINAME -tenant $($tenantfilter) -message "Failed to assign app $($appFilter): $($_.Exception.Message)" -Sev "Error"
  $errMessage = Get-NormalizedError -message $_.Exception.Message
  $results = [pscustomobject]@{"Results" = "$errMessage" }
}
New-Item "Cache_BECCheck" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$results | ConvertTo-Json | Out-File "Cache_BECCheck\$GUID.json"