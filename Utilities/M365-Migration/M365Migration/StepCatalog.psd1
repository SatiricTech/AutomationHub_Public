<#
    Step catalogue overlay - see Docs/Workbench-Design.md, section 5.

    Keyed by script basename, one entry per toolkit script. The overlay holds only what a
    script cannot say about itself: which runbook phase it belongs to, which tenant it talks
    to, which settings feed which parameter, which artefacts it writes, and what its exit
    codes mean. Everything the script does say - parameter names, types, sets, defaults,
    ValidateSet values, help - is read off the script at run time by
    Get-MigrationScriptParameter, never copied here. Tests/StepCatalog.Tests.ps1 refuses any
    key below that does not name a real parameter, and any non-common parameter that no entry
    accounts for.

    Keys:

      Title      Shown in the phase view and the all-tools list.
      Phase      Discover | Plan | Prepare | Cutover.
      Order      The runbook step number; fractions slot a step between two numbered ones.
      Side       Source | Destination | Offline - which tenant the step acts on.
      Scenario   Which migration scenarios show the step. Default: both.
      Connects   Graph | Exchange | Teams - the sign-ins the step costs.
      Impact     Read | Write | Destructive - drives the dry-run and typed-confirmation gates.
      ResultId   The -Name token in <Label>_<ResultId>-Results_<ts>.csv.
      ResultIds  Both tokens, for a script that names its results by mode.
      Confirm    $true means "pass -Confirm:$false" because the script's ConfirmImpact is High.
      Requires   Step ids, or artefact kinds, that must be in hand first.
      Produces   Results | Report:<name> | Inventory | Plan | Mapping | Log.
      ExitCodes  exit code -> meaning. The shared vocabulary is 0 completed, 1 failed,
                 2 some rows failed, 3 work remains.
      Bind       settings key -> parameter name.
      Resolve    parameter name -> resolver name (section 5.3).
      Fixed      parameter name -> the value this step always passes.
      Ignore     Parameters the workbench deliberately leaves to the operator's step form.
      Notes      One line of operator-facing context.
      Instances  The phase-view steps this script backs. A script whose Instances list is
                 empty is one instance whose id is its name with 'Migration' removed.

    Bind, Resolve, Fixed, Ignore and Instances are stated on every entry even when empty: the
    drift guard reads them directly, and under Set-StrictMode an absent key is an error rather
    than an empty answer.

    One binding has a fallback the map cannot express. Domains.Release is the vanity domain
    released from the SOURCE tenant and Domains.Target is the one identities land on in the
    destination; they coincide only when the domain moves with the users. Release is therefore
    allowed to be blank, meaning "same as Target" - and because a blank settings value is
    skipped rather than passed, Resolve-MigrationStepArguments carries that fallback as a named
    rule rather than leaving -Domain unset. See Docs/Workbench-Design.md, section 4.

    An instance may override any key above. Bind, Resolve and Fixed are merged with the
    script's, the instance winning - Bind by target parameter, so an instance that binds the
    destination tenant to -TenantId replaces the script's source-tenant binding rather than
    leaving both in place. A parameter has exactly one source: where every instance of a
    script fixes a parameter, the script's entry does not also bind it.

    Shared artefacts. When two instances of one script write results under the same token -
    the domain-release report and remediation both write Remove-DomainReferences results - a
    results file belongs to the instance named in that run's ledger entry. With no ledger
    entry (a file copied in, or a run made from the command line) it is attributed to the
    lowest-ordered instance of that script. Where the two instances write to different
    -Prefix folders instead, the folder alone tells them apart and no attribution is needed.

    That is why the two source-side exports fix -Prefix to 'Source' rather than binding Label:
    the Export:<StepId> resolver looks for another step's results in the producing instance's
    own prefix folder, so the Teams Phone export in Source/ can never be confused with the
    destination-side unassigned-number listing that the same toolkit writes to <Label>/.

    Author: AutomationHub
    Written with assistance from Claude (Anthropic).
#>

@{

    # --- Phase 1: Discover ------------------------------------------------------------

    'Get-MigrationInventory'                = @{
        Title     = 'Inventory a tenant'
        Phase     = 'Discover'
        Order     = 1
        Side      = 'Source'
        Connects  = @('Graph', 'Exchange')
        Impact    = 'Read'
        Requires  = @()
        Produces  = @('Inventory', 'Log')
        Bind      = @{
            'Source.TenantId'              = 'TenantId'
            'Source.DelegatedOrganization' = 'DelegatedOrganization'
            'Defaults.Verbosity'           = 'Verbosity'
        }
        Resolve   = @{}
        Fixed     = @{}
        # Scope and performance switches: an operator picks them per run against the tenant in
        # front of them (a large estate skips mailbox stats), and no settings key describes them.
        Ignore    = @(
            'DomainFilter'
            'IncludeGuests'
            'IncludeDisabled'
            'IncludeOneDrive'
            'IncludeAuthMethods'
            'SkipMailboxPermissions'
            'SkipMailboxStats'
            'SkipExcel'
        )
        Notes     = 'Writes nine tab CSVs plus a workbook into the folder -Prefix names.'
        Instances = @(
            @{
                Id    = 'Inventory-Source'
                Title = 'Inventory - source tenant'
                Order = 1
                Side  = 'Source'
                Fixed = @{ Prefix = 'Source' }
            }
            @{
                Id       = 'Inventory-Destination'
                Title    = 'Inventory - destination tenant'
                Order    = 2
                Side     = 'Destination'
                Scenario = @('TenantToTenant')
                Fixed    = @{ Prefix = 'Destination' }
                Bind     = @{
                    'Destination.TenantId'              = 'TenantId'
                    'Destination.DelegatedOrganization' = 'DelegatedOrganization'
                }
            }
            @{
                Id       = 'Inventory-Post'
                Title    = 'Inventory - post-cutover'
                Phase    = 'Cutover'
                Order    = 18
                Side     = 'Destination'
                Requires = @('Plan')
                Fixed    = @{ Prefix = 'Post' }
                Bind     = @{
                    'Destination.TenantId'              = 'TenantId'
                    'Destination.DelegatedOrganization' = 'DelegatedOrganization'
                }
            }
        )
    }

    # --- Phase 2: Plan ----------------------------------------------------------------

    'New-MigrationIdentityPlan'             = @{
        Title     = 'Build the identity plan'
        Phase     = 'Plan'
        Order     = 3
        Side      = 'Offline'
        Connects  = @()
        Impact    = 'Read'
        Requires  = @('Inventory-Source')
        Produces  = @('Plan', 'Log')
        Bind      = @{
            'Label'                     = 'Prefix'
            'Defaults.Verbosity'        = 'Verbosity'
            'Domains.Target'            = 'TargetDomain'
            'Domains.Smtp'              = 'SmtpDomain'
            'Domains.Interim'           = 'InterimDomain'
            'Plan.UpnFormat'            = 'UpnFormat'
            'Plan.SmtpFormat'           = 'SmtpFormat'
            'Plan.MailNicknameFormat'   = 'MailNicknameFormat'
            'Plan.SkuMapPath'           = 'SkuMapPath'
            'Plan.ExclusionRulesPath'   = 'ExclusionRulesPath'
            'Plan.WaveMapPath'          = 'WaveMapPath'
            'Plan.DefaultWave'          = 'DefaultWave'
            'Plan.DefaultUsageLocation' = 'DefaultUsageLocation'
            'Plan.PreserveAliases'      = 'PreserveAliases'
            'Plan.AliasDomainMap'       = 'AliasDomainMap'
            'Plan.IncludeDisabled'      = 'IncludeDisabled'
            'Plan.IncludeGuests'        = 'IncludeGuests'
            'Plan.IncludeSynced'        = 'IncludeSynced'
        }
        Resolve   = @{
            UsersCsv              = 'Inventory:Source:Users'
            UserMailboxesCsv      = 'Inventory:Source:UserMailboxes'
            SharedMailboxesCsv    = 'Inventory:Source:SharedMailboxes'
            GroupsCsv             = 'Inventory:Source:Groups'
            ContactsCsv           = 'Inventory:Source:Contacts'
            ReservedAddressesPath = 'Inventory:Destination:Users'
            ExistingPlanPath      = 'ExistingPlan'
        }
        Fixed     = @{}
        Ignore    = @()
        Notes     = 'Offline. Re-running against the pinned plan keeps the operator''s edits.'
        Instances = @()
    }

    'Export-MigrationMappingFile'           = @{
        Title     = 'Export the mover mapping file'
        Phase     = 'Plan'
        Order     = 4
        Side      = 'Offline'
        Scenario  = @('TenantToTenant')
        Connects  = @()
        Impact    = 'Read'
        ResultId  = 'Export-MappingFile'
        Requires  = @('Plan')
        # The mapping workbook's own filename is the mover's contract, not the toolkit's, so
        # the scanner tracks this step by its results file instead.
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                      = 'Prefix'
            'Defaults.Verbosity'         = 'Verbosity'
            'Defaults.Tool'              = 'Tool'
            'Defaults.UseInterim'        = 'UseInterim'
            'Defaults.IncludeCollisions' = 'IncludeCollisions'
        }
        Resolve   = @{ PlanPath = 'Plan' }
        Fixed     = @{}
        Ignore    = @('Wave', 'ObjectType', 'SkipExcel')
        Notes     = 'Maps planned rows only; everything else is reported Skipped, never dropped.'
        Instances = @()
    }

    # --- Phase 3: Prepare the destination ---------------------------------------------

    'Test-MigrationReadiness'               = @{
        Title     = 'Readiness checks'
        Phase     = 'Prepare'
        Order     = 5
        Side      = 'Destination'
        Connects  = @('Graph', 'Exchange')
        Impact    = 'Read'
        ResultId  = 'Test-Readiness'
        Requires  = @('Plan')
        Produces  = @('Results', 'Log')
        ExitCodes = @{ 0 = 'Completed'; 1 = 'Failed'; 2 = 'Checks failed' }
        Bind      = @{
            'Label'                             = 'Prefix'
            'Defaults.Verbosity'                = 'Verbosity'
            'Destination.TenantId'              = 'TenantId'
            'Destination.DelegatedOrganization' = 'DelegatedOrganization'
        }
        Resolve   = @{ PlanPath = 'Plan' }
        Fixed     = @{}
        Ignore    = @('Wave')
        Notes     = 'Exit 2 means a check failed. Pre must be clean before anything is provisioned.'
        Instances = @(
            @{
                Id    = 'Readiness-Pre'
                Title = 'Readiness - pre-provisioning'
                Order = 5
                Fixed = @{ Stage = 'Pre' }
            }
            @{
                Id      = 'Readiness-Provisioned'
                Title   = 'Readiness - provisioned'
                Order   = 9
                Impact  = 'Write'
                Fixed   = @{ Stage = 'Provisioned' }
                Resolve = @{ SourceMailboxesCsv = 'Inventory:Source:UserMailboxes' }
                Notes   = 'Writes MailboxProvisioned/OneDriveProvisioned to the plan; a drive read can provision one.'
            }
            @{
                Id    = 'Readiness-Post'
                Title = 'Readiness - post-cutover'
                Phase = 'Cutover'
                Order = 17
                Fixed = @{ Stage = 'Post' }
            }
        )
    }

    'New-MigrationUsers'                    = @{
        Title     = 'Provision users'
        Phase     = 'Prepare'
        Order     = 6
        Side      = 'Destination'
        Scenario  = @('TenantToTenant')
        Connects  = @('Graph')
        Impact    = 'Write'
        ResultId  = 'New-Users'
        Requires  = @('Plan', 'Readiness-Pre')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                      = 'Prefix'
            'Defaults.Verbosity'         = 'Verbosity'
            'Destination.TenantId'       = 'TenantId'
            'Plan.DefaultUsageLocation'  = 'DefaultUsageLocation'
            'Defaults.IncludeCollisions' = 'IncludeCollisions'
            'Defaults.UseInterim'        = 'UseInterim'
            'Defaults.PasswordLength'    = 'PasswordLength'
        }
        Resolve   = @{ PlanPath = 'Plan' }
        Fixed     = @{}
        Ignore    = @('Wave', 'HideFromAddressLists', 'AssignLicenses', 'SetManagers', 'ForceChangePassword')
        Notes     = 'Generated passwords are written only to the results file.'
        Instances = @()
    }

    'Set-MigrationLicenses'                 = @{
        Title     = 'Assign licences'
        Phase     = 'Prepare'
        Order     = 7
        Side      = 'Destination'
        Scenario  = @('TenantToTenant')
        Connects  = @('Graph')
        Impact    = 'Write'
        ResultId  = 'Set-Licenses'
        Confirm   = $true
        Requires  = @('Plan', 'New-Users')
        Produces  = @('Results', 'Log')
        ExitCodes = @{ 0 = 'Completed'; 1 = 'Failed or seat shortfall'; 2 = 'Some rows failed' }
        Bind      = @{
            'Label'                      = 'Prefix'
            'Defaults.Verbosity'         = 'Verbosity'
            'Destination.TenantId'       = 'TenantId'
            'Plan.SkuMapPath'            = 'SkuMapPath'
            'Plan.DefaultUsageLocation'  = 'DefaultUsageLocation'
            'Defaults.IncludeCollisions' = 'IncludeCollisions'
        }
        Resolve   = @{ PlanPath = 'Plan' }
        Fixed     = @{}
        Ignore    = @('Wave', 'RemoveUnplanned', 'AcknowledgeLicenseRemoval', 'Force')
        Notes     = '-RemoveUnplanned starts the 30-day mailbox-deletion clock and has its own gate.'
        Instances = @()
    }

    'New-MigrationRecipients'               = @{
        Title     = 'Create mail recipients'
        Phase     = 'Prepare'
        Order     = 8
        Side      = 'Destination'
        Scenario  = @('TenantToTenant')
        Connects  = @('Exchange')
        Impact    = 'Write'
        ResultId  = 'New-Recipients'
        Requires  = @('Plan', 'New-Users')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                             = 'Prefix'
            'Defaults.Verbosity'                = 'Verbosity'
            'Destination.TenantId'              = 'TenantId'
            'Destination.DelegatedOrganization' = 'DelegatedOrganization'
            'Defaults.UseInterim'               = 'UseInterim'
            'Defaults.IncludeCollisions'        = 'IncludeCollisions'
        }
        Resolve   = @{
            PlanPath              = 'Plan'
            GroupsCsv             = 'Inventory:Source:Groups'
            ContactsCsv           = 'Inventory:Source:Contacts'
            SharedMailboxesCsv    = 'Inventory:Source:SharedMailboxes'
            MailboxPermissionsCsv = 'Inventory:Source:MailboxPermissions'
        }
        Fixed     = @{}
        Ignore    = @('Wave', 'Type', 'Mode')
        Notes     = 'Use -Mode UpdateSettings alone to patch groups the mover already created.'
        Instances = @()
    }

    # --- Phase 4: Cutover -------------------------------------------------------------

    'Remove-MigrationDomainReferences'      = @{
        Title     = 'Release the source domain'
        Phase     = 'Cutover'
        Order     = 11
        Side      = 'Source'
        Scenario  = @('TenantToTenant')
        Connects  = @('Graph', 'Exchange')
        Impact    = 'Destructive'
        ResultId  = 'Remove-DomainReferences'
        Confirm   = $true
        Requires  = @('Readiness-Provisioned')
        Produces  = @(
            'Results'
            'Report:DomainReferences'
            'Report:DomainBlockers'
            'Report:DomainBlockers-Recheck'
            'Log'
        )
        ExitCodes = @{ 0 = 'Completed'; 1 = 'Failed'; 2 = 'Some rows failed'; 3 = 'References remain' }
        Bind      = @{
            'Label'                        = 'Prefix'
            'Defaults.Verbosity'           = 'Verbosity'
            'Domains.Release'              = 'Domain'
            'Source.OnMicrosoftDomain'     = 'FallbackDomain'
            'Source.TenantId'              = 'TenantId'
            'Source.DelegatedOrganization' = 'DelegatedOrganization'
        }
        Resolve   = @{}
        Fixed     = @{}
        # -Scope narrows the scan to object types; the operator picks it while working through
        # a blockers report, so it stays on the form.
        Ignore    = @('Scope')
        Notes     = 'Always report first. This acts on the SOURCE tenant.'
        Instances = @(
            @{
                Id     = 'DomainReferences-Report'
                Title  = 'Domain release - report'
                Order  = 11
                Impact = 'Read'
                Fixed  = @{ ReportOnly = $true }
                Notes  = 'Reads the source tenant and lists every reference; changes nothing.'
            }
            @{
                Id       = 'DomainReferences-Remediate'
                Title    = 'Domain release - remediate'
                Order    = 11.5
                Impact   = 'Destructive'
                Requires = @('DomainReferences-Report')
                Fixed    = @{ AcknowledgeSourceTenant = $true }
                Notes    = 'Rewrites source addresses to the fallback domain. Exit 3 means references remain.'
            }
        )
    }

    'Set-MigrationIdentity'                 = @{
        Title     = 'Identity cutover'
        Phase     = 'Cutover'
        Order     = 12
        Side      = 'Destination'
        Connects  = @('Graph', 'Exchange')
        Impact    = 'Write'
        ResultId  = 'Set-Identity'
        Confirm   = $true
        Requires  = @('Plan')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                             = 'Prefix'
            'Defaults.Verbosity'                = 'Verbosity'
            'Destination.TenantId'              = 'TenantId'
            'Destination.DelegatedOrganization' = 'DelegatedOrganization'
            'Defaults.IncludeCollisions'        = 'IncludeCollisions'
        }
        Resolve   = @{ PlanPath = 'Plan' }
        Fixed     = @{}
        Ignore    = @('Wave', 'Apply', 'RemoveOldPrimaryAlias', 'Unhide')
        Notes     = 'Additive: never removes the routing address, a SIP address or an existing X500.'
        Instances = @(
            @{
                Id       = 'Set-Identity'
                Title    = 'Identity cutover - tenant to tenant'
                Order    = 12
                Scenario = @('TenantToTenant')
                Requires = @('Plan', 'DomainReferences-Remediate')
                Fixed    = @{ MatchOn = 'TargetObjectId' }
                Notes    = 'Matches the objects New-MigrationUsers created, by TargetObjectId.'
            }
            @{
                Id       = 'Set-Identity-InPlace'
                Title    = 'Identity cutover - in-place redesign'
                Order    = 12
                Scenario = @('InPlaceRedesign')
                Requires = @('Plan')
                Fixed    = @{ MatchOn = 'Source' }
                Notes    = 'The objects already exist, so the plan''s Source columns describe today.'
            }
        )
    }

    'Set-MigrationMailboxPermissions'       = @{
        Title     = 'Re-apply mailbox delegation'
        Phase     = 'Cutover'
        Order     = 13
        Side      = 'Destination'
        Connects  = @('Exchange')
        Impact    = 'Write'
        ResultId  = 'Set-MailboxPermissions'
        Confirm   = $true
        Requires  = @('Plan', 'Inventory-Source')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                             = 'Prefix'
            'Defaults.Verbosity'                = 'Verbosity'
            'Destination.TenantId'              = 'TenantId'
            'Destination.DelegatedOrganization' = 'DelegatedOrganization'
            'Defaults.IncludeCollisions'        = 'IncludeCollisions'
        }
        Resolve   = @{
            PlanPath              = 'Plan'
            MailboxPermissionsCsv = 'Inventory:Source:MailboxPermissions'
            UserMailboxesCsv      = 'Inventory:Source:UserMailboxes'
            SharedMailboxesCsv    = 'Inventory:Source:SharedMailboxes'
        }
        Fixed     = @{}
        Ignore    = @('Wave', 'Apply', 'AutoMapping')
        Notes     = 'Idempotent - safe to re-run all weekend.'
        Instances = @()
    }

    'Reset-MigrationCutoverPasswords'       = @{
        Title     = 'Reset cutover passwords'
        Phase     = 'Cutover'
        Order     = 14
        Side      = 'Destination'
        Scenario  = @('TenantToTenant')
        Connects  = @('Graph')
        Impact    = 'Write'
        ResultId  = 'Reset-CutoverPasswords'
        Confirm   = $true
        Requires  = @('New-Users')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                      = 'Prefix'
            'Defaults.Verbosity'         = 'Verbosity'
            'Destination.TenantId'       = 'TenantId'
            'Defaults.WordCount'         = 'WordCount'
            'Defaults.IncludeCollisions' = 'IncludeCollisions'
        }
        Resolve   = @{ PlanPath = 'Plan' }
        Fixed     = @{}
        # -CsvPath, -Group and -TestUser are the plan's three alternatives: each selects a
        # different parameter set, so only the operator can say which run this is.
        Ignore    = @('Wave', 'CsvPath', 'Group', 'TestUser', 'ForceChangePassword')
        Notes     = 'Credentials go to the results file only. Distribute them out of band.'
        Instances = @()
    }

    'Get-MigrationTeamsPhoneAssignments'    = @{
        Title     = 'Export Teams phone assignments'
        Phase     = 'Cutover'
        Order     = 15.1
        Side      = 'Source'
        Scenario  = @('TenantToTenant')
        Connects  = @('Teams')
        Impact    = 'Read'
        ResultId  = 'Get-TeamsPhoneAssignments'
        Requires  = @()
        Produces  = @(
            'Results'
            'Report:TeamsPhoneAssignments'
            'Report:TeamsPhoneNumbers-Unassigned'
            'Log'
        )
        # Every instance fixes -Prefix, so the entry does not also bind Label to it.
        Bind      = @{
            'Defaults.Verbosity' = 'Verbosity'
            'Source.TenantId'    = 'TenantId'
        }
        Resolve   = @{}
        Fixed     = @{}
        Ignore    = @('OnlyUsersWithNumbers', 'IncludeUnassignedNumbers')
        Notes     = 'The results file is the reassignment input for the destination tenant.'
        Instances = @(
            @{
                Id    = 'TeamsPhone-Export'
                Title = 'Teams Phone - export the source assignments'
                Order = 15.1
                Fixed = @{ Prefix = 'Source' }
                Notes = 'Run before anything releases a number. Files land in Source/, where Export: looks.'
            }
        )
    }

    'Remove-MigrationTeamsPhoneAssignments' = @{
        Title     = 'Release Teams phone numbers'
        Phase     = 'Cutover'
        Order     = 15.2
        Side      = 'Source'
        Scenario  = @('TenantToTenant')
        Connects  = @('Teams')
        Impact    = 'Destructive'
        ResultId  = 'Remove-TeamsPhoneAssignments'
        Confirm   = $true
        Requires  = @('TeamsPhone-Export')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'              = 'Prefix'
            'Defaults.Verbosity' = 'Verbosity'
            'Source.TenantId'    = 'TenantId'
        }
        Resolve   = @{}
        Fixed     = @{}
        # -All releases every number in the tenant and -AcknowledgeSourceTenant is its gate:
        # both are deliberate operator choices, never something settings should turn on.
        Ignore    = @('User', 'All', 'AcknowledgeSourceTenant')
        Notes     = 'Nothing puts these numbers back automatically.'
        Instances = @(
            @{
                Id      = 'TeamsPhone-Remove'
                Title   = 'Teams Phone - release the source numbers'
                Order   = 15.2
                Resolve = @{ CsvPath = 'Export:Get-TeamsPhoneAssignments' }
            }
        )
    }

    'Set-MigrationTeamsPhoneAssignments'    = @{
        Title     = 'Assign Teams phone numbers'
        Phase     = 'Cutover'
        Order     = 15.4
        Side      = 'Destination'
        Scenario  = @('TenantToTenant')
        Connects  = @('Teams')
        Impact    = 'Write'
        ResultId  = 'Set-TeamsPhoneAssignments'
        Confirm   = $true
        Requires  = @('TeamsPhone-Export')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                = 'Prefix'
            'Defaults.Verbosity'   = 'Verbosity'
            'Destination.TenantId' = 'TenantId'
        }
        Resolve   = @{}
        Fixed     = @{}
        Ignore    = @('User', 'PhoneNumber', 'PhoneNumberType', 'LocationId', 'VoiceRoutingPolicy')
        Notes     = 'A number already on a different user fails rather than being stolen.'
        Instances = @(
            @{
                Id       = 'TeamsPhone-ListUnassigned'
                Title    = 'Teams Phone - list unassigned destination numbers'
                Order    = 15.3
                Impact   = 'Read'
                Requires = @()
                Produces = @('Results', 'Report:TeamsPhoneNumbers-Unassigned', 'Log')
                Fixed    = @{ ListUnassigned = $true }
                Notes    = 'Changes nothing; confirms the numbers have ported before assignment.'
            }
            @{
                Id       = 'TeamsPhone-Assign'
                Title    = 'Teams Phone - assign the ported numbers'
                Order    = 15.4
                Impact   = 'Write'
                Requires = @('TeamsPhone-Export', 'TeamsPhone-Remove')
                Resolve  = @{ CsvPath = 'Export:Get-TeamsPhoneAssignments' }
            }
        )
    }

    'Get-MigrationVivaLearningHistory'      = @{
        Title     = 'Export Viva Learning history'
        Phase     = 'Cutover'
        Order     = 16.1
        Side      = 'Source'
        Scenario  = @('TenantToTenant')
        Connects  = @('Graph')
        Impact    = 'Read'
        ResultId  = 'Get-VivaLearningHistory'
        Requires  = @()
        Produces  = @('Results', 'Report:VivaLearningHistory', 'Log')
        # Every instance fixes -Prefix, so the entry does not also bind Label to it.
        Bind      = @{
            'Defaults.Verbosity' = 'Verbosity'
            'Source.TenantId'    = 'TenantId'
        }
        Resolve   = @{}
        Fixed     = @{}
        Ignore    = @('User', 'IncludeGuests', 'SkipCourseMetadata')
        Notes     = 'Delegated sign-in only. Also writes a raw-JSON fidelity backup.'
        Instances = @(
            @{
                Id    = 'VivaLearning-Export'
                Title = 'Viva Learning - export the source history'
                Order = 16.1
                Fixed = @{ Prefix = 'Source' }
                Notes = 'Files land in Source/, where Export: looks when the import resolves -CsvPath.'
            }
        )
    }

    'Import-MigrationVivaLearningHistory'   = @{
        Title     = 'Import Viva Learning history'
        Phase     = 'Cutover'
        Order     = 16.2
        Side      = 'Destination'
        Scenario  = @('TenantToTenant')
        Connects  = @('Graph')
        Impact    = 'Write'
        ResultId  = 'Import-VivaLearningHistory'
        Confirm   = $true
        Requires  = @('VivaLearning-Export', 'Plan')
        Produces  = @('Results', 'Log')
        Bind      = @{
            'Label'                              = 'Prefix'
            'Defaults.Verbosity'                 = 'Verbosity'
            'Destination.TenantId'               = 'TenantId'
            'Domains.Target'                     = 'TargetDomain'
            'VivaLearning.ClientId'              = 'ClientId'
            'VivaLearning.CertificateThumbprint' = 'CertificateThumbprint'
            'VivaLearning.LearningProviderId'    = 'LearningProviderId'
        }
        Resolve   = @{
            CsvPath  = 'Export:Get-VivaLearningHistory'
            PlanPath = 'Plan'
        }
        Fixed     = @{}
        # -ClientSecret is prompted at run time as a SecureString and passed to the child in a
        # process-scoped environment variable: it never reaches the settings file or a driver.
        # The provider's display name, logos and language are branding an operator sets once.
        Ignore    = @(
            'ClientSecret'
            'ProviderDisplayName'
            'LogoUrl'
            'SquareLogoUrl'
            'SquareLogoDarkUrl'
            'LongLogoUrl'
            'LongLogoDarkUrl'
            'DefaultLanguageTag'
            'KeepCsvDomains'
        )
        Notes     = 'Split auth: delegated to register the provider, app-only to write content.'
        Instances = @(
            @{
                Id    = 'VivaLearning-Import'
                Title = 'Viva Learning - replay the history'
                Order = 16.2
            }
        )
    }

    'Compare-MigrationUserData'             = @{
        Title     = 'Compare the destination against the plan'
        Phase     = 'Cutover'
        Order     = 18.5
        Side      = 'Offline'
        Connects  = @()
        Impact    = 'Read'
        ResultId  = 'Compare-UserData'
        ResultIds = @('Compare-UserData', 'Compare-UserData-Plan')
        Requires  = @('Plan', 'Inventory-Post')
        Produces  = @('Results', 'Log')
        ExitCodes = @{ 0 = 'Completed'; 1 = 'Failed'; 2 = 'Differences found' }
        Bind      = @{
            'Label'              = 'Prefix'
            'Defaults.Verbosity' = 'Verbosity'
        }
        Resolve   = @{}
        Fixed     = @{}
        # -ReferenceCsv and the column overrides belong to the fuzzy CSV-to-CSV mode, which is
        # an ad-hoc comparison of two files the workbench knows nothing about.
        Ignore    = @(
            'ReferenceCsv'
            'SimilarityThreshold'
            'Wave'
            'ObjectType'
            'UpnColumn'
            'EmailColumn'
            'FirstNameColumn'
            'LastNameColumn'
            'DisplayNameColumn'
        )
        Notes     = 'Offline either way. Exit 2 means the destination and the plan disagree.'
        Instances = @(
            @{
                Id       = 'Compare-Plan'
                Title    = 'Compare - plan against the post-cutover inventory'
                Order    = 18.5
                ResultId = 'Compare-UserData-Plan'
                Resolve  = @{
                    PlanPath      = 'Plan'
                    DifferenceCsv = 'Inventory:Post:Users'
                }
            }
        )
    }
}
