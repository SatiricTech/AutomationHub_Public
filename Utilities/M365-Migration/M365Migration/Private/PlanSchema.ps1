<#
    The identity plan is the single contract between the planning phase and every writer,
    so its column set lives in exactly one place. Save-MigrationPlan always writes these
    columns in this order, which keeps the file diffable across runs and keeps Excel from
    reordering it out from under the next script.

    The writeback columns are the ones the provisioning scripts fill in. Import-MigrationPlan
    adds them silently when absent, so a plan hand-built in a spreadsheet does not have to
    carry empty columns the operator has no business filling in.

    Author: AutomationHub
#>

$script:MigrationPlanColumns = @(
    'ObjectType'
    'Wave'
    'SourceObjectId'
    'SourceUserPrincipalName'
    'SourcePrimarySmtp'
    'SourceAliases'
    'LegacyExchangeDN'
    'SourceX500'
    'DisplayName'
    'FirstName'
    'MiddleName'
    'LastName'
    'JobTitle'
    'Department'
    'Office'
    'MobilePhone'
    'UsageLocation'
    'ManagerUpn'
    'MailboxType'
    'AccountEnabled'
    'IsSynced'
    'SourceLicenses'
    'InterimUserPrincipalName'
    'InterimPrimarySmtp'
    'TargetUserPrincipalName'
    'TargetPrimarySmtp'
    'TargetAliases'
    'TargetMailNickname'
    'TargetLicenses'
    'PlanStatus'
    'PlanDetail'
    'ExcludeReason'
    'TargetObjectId'
    'MailboxProvisioned'
    'OneDriveProvisioned'
    'ProvisionStatus'
    'ProvisionDetail'
)

$script:MigrationPlanWritebackColumns = @(
    'TargetObjectId'
    'MailboxProvisioned'
    'OneDriveProvisioned'
    'ProvisionStatus'
    'ProvisionDetail'
)

$script:MigrationObjectTypes = @(
    'User', 'Guest', 'Shared', 'Room', 'Equipment', 'Distribution',
    'MailEnabledSecurity', 'Contact', 'DynamicDistribution', 'M365Group'
)

$script:MigrationPlanStatuses = @(
    'Planned', 'Collision', 'NeedsReview', 'Invalid', 'ManualOverride',
    'Excluded', 'ExistsInDestination', 'UpnSmtpDiverge'
)
