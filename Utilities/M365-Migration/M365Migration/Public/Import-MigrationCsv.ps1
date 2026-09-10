function Import-MigrationCsv {
    <#
    .SYNOPSIS
        Imports a CSV, normalising its headers to the toolkit's canonical column names.

    .DESCRIPTION
        Input CSVs arrive from every direction - an Exchange export, a Graph report, a
        spreadsheet a client filled in - and each names the same field differently. This
        resolves the alias vocabulary once, so no downstream script has to guess whether
        the address column is called UPN, UserName or Login.

        Headers are trimmed and matched case-insensitively. An exact match on a canonical
        name always wins; an alias is applied only when its canonical name is not already
        claimed by another column, so a file carrying both DisplayName and Name keeps
        both instead of silently losing one. Headers outside the vocabulary pass through
        unchanged.

        Alias vocabulary (canonical from aliases):
          UserPrincipalName       UPN, User Principal Name, UserName, User, CurrentUPN, Login
          PrimarySmtpAddress      PrimaryEmail, Email, Mail, EmailAddress, PrimarySMTP, WindowsEmailAddress
          FirstName               GivenName, First Name, First
          LastName                Surname, Last Name, Last, FamilyName
          MiddleName              Middle, MiddleInitial
          DisplayName             Display Name, Name
          JobTitle                Title
          Office                  OfficeLocation
          MobilePhone             Mobile
          UsageLocation           Country Code
          Licenses                SkuPartNumbers, AssignedLicenses
          ManagerUpn              Manager
          TargetUserPrincipalName TargetUPN, NewUPN, Target
          TargetPrimarySmtp       TargetEmail, NewPrimaryEmail
          Department, Wave        (no aliases)
          ObjectType              RecipientType
          PhoneNumber             LineUri, Number
          PhoneNumberType         NumberType
          LocationId              EmergencyLocationId
          OnlineVoiceRoutingPolicy VoiceRoutingPolicy
          Extension               (no aliases)

        A bare 'Type' header is deliberately NOT an ObjectType alias. It collides with the
        Teams Phone 'PhoneNumberType' and the Viva 'ActivityType' columns, and a header
        that means three different things is worse than one that means nothing: an
        unrecognised header passes through under its own name, where a script can ask for
        it explicitly. Use RecipientType, or the canonical ObjectType, to name a recipient
        class.

    .PARAMETER Path
        The CSV file to read. Read as UTF-8.

    .PARAMETER RequiredColumns
        Canonical column names that must be present after alias resolution. All missing
        columns are listed in one error, so an operator fixes the file once.

    .EXAMPLE
        $rows = Import-MigrationCsv -Path .\users.csv -RequiredColumns 'UserPrincipalName'

        Reads the file and guarantees a UserPrincipalName property on every row.

    .EXAMPLE
        $rows = Import-MigrationCsv -Path .\phones.csv -RequiredColumns @('UserPrincipalName', 'PhoneNumber')

        Reads a Teams Phone assignment file, accepting LineUri or Number as the number column.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$RequiredColumns
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CSV file not found: $Path"
    }

    $aliasMap = [ordered]@{
        'UserPrincipalName'       = @('UPN', 'User Principal Name', 'UserName', 'User', 'CurrentUPN', 'Login')
        'PrimarySmtpAddress'      = @('PrimaryEmail', 'Email', 'Mail', 'EmailAddress', 'PrimarySMTP', 'WindowsEmailAddress')
        'FirstName'               = @('GivenName', 'First Name', 'First')
        'LastName'                = @('Surname', 'Last Name', 'Last', 'FamilyName')
        'MiddleName'              = @('Middle', 'MiddleInitial')
        'DisplayName'             = @('Display Name', 'Name')
        'JobTitle'                = @('Title')
        'Department'              = @()
        'Office'                  = @('OfficeLocation')
        'MobilePhone'             = @('Mobile')
        'UsageLocation'           = @('Country Code')
        'Licenses'                = @('SkuPartNumbers', 'AssignedLicenses')
        'ManagerUpn'              = @('Manager')
        'TargetUserPrincipalName' = @('TargetUPN', 'NewUPN', 'Target')
        'TargetPrimarySmtp'       = @('TargetEmail', 'NewPrimaryEmail')
        'Wave'                    = @()
        'ObjectType'              = @('RecipientType')
        'PhoneNumber'             = @('LineUri', 'Number')
        'PhoneNumberType'         = @('NumberType')
        'LocationId'              = @('EmergencyLocationId')
        'OnlineVoiceRoutingPolicy' = @('VoiceRoutingPolicy')
        'Extension'               = @()
    }

    try {
        $raw = @(Import-Csv -LiteralPath $Path -Encoding utf8 -ErrorAction Stop)
    }
    catch {
        throw "Could not read the CSV '$Path': $($_.Exception.Message)"
    }

    if ($raw.Count -eq 0) {
        throw "The CSV '$Path' contains no data rows."
    }

    $headers = @($raw[0].PSObject.Properties.Name)

    # Pass one claims the canonical names that appear verbatim; pass two maps the aliases
    # into whatever is left. Doing it in that order is what stops an alias from evicting
    # a real column.
    $headerToCanonical = [ordered]@{}
    $claimed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($header in $headers) {
        $trimmed = $header.Trim()
        $canonical = @($aliasMap.Keys) | Where-Object { $_ -ieq $trimmed } | Select-Object -First 1
        if ($canonical) {
            $headerToCanonical[$header] = $canonical
            [void]$claimed.Add($canonical)
        }
    }

    foreach ($header in $headers) {
        if ($headerToCanonical.Contains($header)) { continue }
        $trimmed = $header.Trim()
        $canonical = $null
        foreach ($key in $aliasMap.Keys) {
            if ($claimed.Contains($key)) { continue }
            if (@($aliasMap[$key]) | Where-Object { $_ -ieq $trimmed }) {
                $canonical = $key
                break
            }
        }
        if ($canonical) {
            $headerToCanonical[$header] = $canonical
            [void]$claimed.Add($canonical)
        }
        else {
            $headerToCanonical[$header] = $trimmed
        }
    }

    if ($RequiredColumns) {
        $missing = @($RequiredColumns | Where-Object { -not $claimed.Contains($_) -and @($headerToCanonical.Values) -notcontains $_ })
        if ($missing.Count -gt 0) {
            throw ("The CSV '$Path' is missing required column(s): " + ($missing -join ', ') +
                '. Column aliases are resolved automatically - see Get-Help Import-MigrationCsv for the accepted names.')
        }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $raw) {
        $row = [ordered]@{}
        foreach ($header in $headers) {
            $row[[string]$headerToCanonical[$header]] = $record.PSObject.Properties[$header].Value
        }
        $rows.Add([pscustomobject]$row)
    }

    Write-MigrationLog -Message "Imported $($rows.Count) row(s) from $Path" -Level INFO
    return $rows.ToArray()
}
