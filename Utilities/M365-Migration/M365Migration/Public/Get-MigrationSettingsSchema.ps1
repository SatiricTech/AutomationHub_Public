function Get-MigrationSettingsSchema {
    <#
    .SYNOPSIS
        Returns the migration settings document's key layout, types and defaults.

    .DESCRIPTION
        The settings file (M365Migration.settings.json, see Docs/Workbench-Design.md, section 4) is
        the single JSON document that holds a migration's tenant, domain, plan and
        default-behaviour choices. Its shape is defined exactly once, here:
        New-MigrationSettings, Resolve-MigrationSettings and Save-MigrationSettings all
        derive their keys, types and defaults from this list rather than repeating the
        document's shape in three places, which is how a schema and its validator drift
        apart in practice.

        Each entry names one leaf value in the document, with nested object keys flattened
        with a dot ('Source.TenantId'). Two things are not flattened further: 'SchemaVersion',
        'Label' and 'Scenario' have no dot because they sit at the document's top level, not
        under a section; and 'Plan.AliasDomainMap' is a single entry of Type 'Map' even
        though its JSON value is an object - its keys are operator-supplied domain names, not
        part of this schema, so they are never validated against it.

        Type is one of: String, Guid, Bool, Int, Domain, Path, Map, Choice. A Domain value is
        normalised - trimmed, a leading '@' stripped, lower-cased - before it is validated
        against the pattern ('^@?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$') and before it is
        stored, on both a load and a save, so '@Contoso.COM' is accepted and is thereafter
        always 'contoso.com'. Choice values are validated against the entry's own Choices
        list.

        Required documents which keys the settings form (a later task) should treat as
        mandatory input; Resolve-MigrationSettings does not itself enforce it beyond the
        SchemaVersion, Label and Scenario rules that are already spelled out explicitly.

    .EXAMPLE
        Get-MigrationSettingsSchema | Where-Object Key -eq 'Defaults.Verbosity'

        Returns the schema entry for the default console/log verbosity, including its
        Low/Medium/High choice list.

    .EXAMPLE
        (Get-MigrationSettingsSchema).Key

        Lists every settings key in the document's canonical order - the order
        New-MigrationSettings builds and Save-MigrationSettings writes.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return @(
        [pscustomobject]@{
            Key = 'SchemaVersion'; Type = 'Int'; Default = 1; Required = $true; Choices = @()
            Description = 'Settings file format version. Always 1 today.'
        }
        [pscustomobject]@{
            Key = 'Label'; Type = 'String'; Default = ''; Required = $true; Choices = @()
            Description = 'Names the migration; feeds the workspace folder and every output filename.'
        }
        [pscustomobject]@{
            Key = 'Scenario'; Type = 'Choice'; Default = 'TenantToTenant'; Required = $true
            Choices = @('TenantToTenant', 'InPlaceRedesign')
            Description = 'TenantToTenant migrates between two tenants; InPlaceRedesign restructures one.'
        }

        [pscustomobject]@{
            Key = 'Source.TenantId'; Type = 'Guid'; Default = ''; Required = $false; Choices = @()
            Description = 'Source tenant GUID; every connector asserts it reached this tenant.'
        }
        [pscustomobject]@{
            Key = 'Source.DisplayName'; Type = 'String'; Default = ''; Required = $false; Choices = @()
            Description = 'Friendly name for the source tenant, shown in the workbench banner.'
        }
        [pscustomobject]@{
            Key = 'Source.OnMicrosoftDomain'; Type = 'Domain'; Default = ''; Required = $false; Choices = @()
            Description = 'Source tenant''s *.onmicrosoft.com domain.'
        }
        [pscustomobject]@{
            Key = 'Source.DelegatedOrganization'; Type = 'Domain'; Default = ''; Required = $false; Choices = @()
            Description = 'Domain passed to Connect-MigrationExchange -DelegatedOrganization for GDAP sign-in.'
        }

        [pscustomobject]@{
            Key = 'Destination.TenantId'; Type = 'Guid'; Default = ''; Required = $false; Choices = @()
            Description = 'Destination tenant GUID; every connector asserts it reached this tenant.'
        }
        [pscustomobject]@{
            Key = 'Destination.DisplayName'; Type = 'String'; Default = ''; Required = $false; Choices = @()
            Description = 'Friendly name for the destination tenant, shown in the workbench banner.'
        }
        [pscustomobject]@{
            Key = 'Destination.OnMicrosoftDomain'; Type = 'Domain'; Default = ''; Required = $false; Choices = @()
            Description = 'Destination tenant''s *.onmicrosoft.com domain.'
        }
        [pscustomobject]@{
            Key = 'Destination.DelegatedOrganization'; Type = 'Domain'; Default = ''; Required = $false; Choices = @()
            Description = 'Domain passed to Connect-MigrationExchange -DelegatedOrganization for GDAP sign-in.'
        }

        [pscustomobject]@{
            Key = 'Domains.Target'; Type = 'Domain'; Default = ''; Required = $false; Choices = @()
            Description = 'Vanity domain the identities land on; feeds -TargetDomain and -Domain.'
        }
        [pscustomobject]@{
            Key = 'Domains.Smtp'; Type = 'Domain'; Default = ''; Required = $false; Choices = @()
            Description = 'SMTP domain when it differs from Domains.Target; blank means "same as Target".'
        }
        [pscustomobject]@{
            Key = 'Domains.Interim'; Type = 'Domain'; Default = ''; Required = $false; Choices = @()
            Description = 'Interim domain used before Domains.Target verifies; blank means not needed.'
        }

        [pscustomobject]@{
            Key = 'Plan.UpnFormat'; Type = 'String'; Default = 'First.Last'; Required = $false; Choices = @()
            Description = 'UPN local-part format the identity planner builds, e.g. First.Last.'
        }
        [pscustomobject]@{
            Key = 'Plan.SmtpFormat'; Type = 'String'; Default = ''; Required = $false; Choices = @()
            Description = 'Primary SMTP local-part format; blank means "same as UpnFormat".'
        }
        [pscustomobject]@{
            Key = 'Plan.MailNicknameFormat'; Type = 'String'; Default = ''; Required = $false; Choices = @()
            Description = 'MailNickname format; blank means "same as UpnFormat".'
        }
        [pscustomobject]@{
            Key = 'Plan.DefaultWave'; Type = 'String'; Default = '1'; Required = $false; Choices = @()
            Description = 'Wave assigned to a planned row when the operator does not choose one.'
        }
        [pscustomobject]@{
            Key = 'Plan.DefaultUsageLocation'; Type = 'String'; Default = 'US'; Required = $false; Choices = @()
            Description = 'Two-letter usage location assigned to provisioned users, e.g. US.'
        }
        [pscustomobject]@{
            Key = 'Plan.SkuMapPath'; Type = 'Path'; Default = ''; Required = $false; Choices = @()
            Description = 'Path to the SKU map CSV, relative to the workspace or absolute.'
        }
        [pscustomobject]@{
            Key = 'Plan.ExclusionRulesPath'; Type = 'Path'; Default = ''; Required = $false; Choices = @()
            Description = 'Path to the exclusion rules CSV, relative to the workspace or absolute.'
        }
        [pscustomobject]@{
            Key = 'Plan.WaveMapPath'; Type = 'Path'; Default = ''; Required = $false; Choices = @()
            Description = 'Path to the wave map CSV, relative to the workspace or absolute.'
        }
        [pscustomobject]@{
            Key = 'Plan.PreserveAliases'; Type = 'Bool'; Default = $false; Required = $false; Choices = @()
            Description = 'Carries source proxy addresses forward as destination aliases.'
        }
        [pscustomobject]@{
            Key = 'Plan.AliasDomainMap'; Type = 'Map'; Default = [ordered]@{}; Required = $false; Choices = @()
            Description = 'Old alias domain -> new alias domain rewrites; keys are operator-supplied.'
        }
        [pscustomobject]@{
            Key = 'Plan.IncludeDisabled'; Type = 'Bool'; Default = $false; Required = $false; Choices = @()
            Description = 'Includes disabled source accounts in the plan.'
        }
        [pscustomobject]@{
            Key = 'Plan.IncludeGuests'; Type = 'Bool'; Default = $false; Required = $false; Choices = @()
            Description = 'Includes guest accounts in the plan.'
        }
        [pscustomobject]@{
            Key = 'Plan.IncludeSynced'; Type = 'Bool'; Default = $false; Required = $false; Choices = @()
            Description = 'Includes directory-synced accounts in the plan.'
        }

        [pscustomobject]@{
            Key = 'Defaults.Verbosity'; Type = 'Choice'; Default = 'Medium'; Required = $false
            Choices = @('Low', 'Medium', 'High')
            Description = 'Default -Verbosity passed to every step unless overridden.'
        }
        [pscustomobject]@{
            Key = 'Defaults.IncludeCollisions'; Type = 'Bool'; Default = $false; Required = $false; Choices = @()
            Description = 'Default -IncludeCollisions passed to steps that accept it.'
        }
        [pscustomobject]@{
            Key = 'Defaults.UseInterim'; Type = 'Bool'; Default = $false; Required = $false; Choices = @()
            Description = 'Default -UseInterim passed to steps that accept it.'
        }
        [pscustomobject]@{
            Key = 'Defaults.Tool'; Type = 'Choice'; Default = 'AvePoint'; Required = $false; Choices = @('AvePoint')
            Description = 'Third-party migration tool the plan and reports are shaped for.'
        }
        [pscustomobject]@{
            Key = 'Defaults.PasswordLength'; Type = 'Int'; Default = 16; Required = $false; Choices = @()
            Description = 'Default generated-password length for newly provisioned accounts.'
        }
        [pscustomobject]@{
            Key = 'Defaults.WordCount'; Type = 'Int'; Default = 3; Required = $false; Choices = @()
            Description = 'Default generated-passphrase word count for newly provisioned accounts.'
        }

        [pscustomobject]@{
            Key = 'Pinned.PlanPath'; Type = 'Path'; Default = ''; Required = $false; Choices = @()
            Description = 'Pinned identity plan path; blank means "newest <Label>_IdentityPlan_*.csv".'
        }

        [pscustomobject]@{
            Key = 'VivaLearning.ClientId'; Type = 'Guid'; Default = ''; Required = $false; Choices = @()
            Description = 'App registration (client) ID used for the Viva Learning app-only phase.'
        }
        [pscustomobject]@{
            Key = 'VivaLearning.CertificateThumbprint'; Type = 'String'; Default = ''; Required = $false
            Choices = @()
            Description = 'Thumbprint of the sign-in certificate - a locator, not a secret.'
        }
        [pscustomobject]@{
            Key = 'VivaLearning.LearningProviderId'; Type = 'Guid'; Default = ''; Required = $false; Choices = @()
            Description = 'Registration ID of an existing Viva Learning provider, when reusing one.'
        }
    )
}
