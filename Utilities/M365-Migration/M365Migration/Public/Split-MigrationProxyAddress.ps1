function Split-MigrationProxyAddress {
    <#
    .SYNOPSIS
        Splits a proxy address into its prefix and value, and classifies it.

    .DESCRIPTION
        Exchange stores every address of a recipient in one multi-valued attribute using a
        prefix convention: 'SMTP:' (uppercase) is the primary, 'smtp:' an alias, 'X500:' a
        legacy distinguished name, and 'SIP:'/'SPO:'/'EUM:' belong to Teams, SharePoint and
        Unified Messaging. Case matters for exactly one decision - which SMTP entry is the
        primary - so the prefix is compared case-sensitively there and case-insensitively
        everywhere else.

        An entry with no prefix is treated as a plain SMTP alias, which is how operators
        type them into a spreadsheet. X500 values are left alone beyond the prefix split:
        a legacy DN contains '=' and '/' and must survive untouched or the cached Outlook
        entries it exists to fix will not resolve.

    .PARAMETER Entry
        A single proxy address, for example 'SMTP:john.smith@contoso.com' or
        'X500:/o=ExchangeLabs/ou=.../cn=Recipients/cn=abc'. Accepts pipeline input so a
        whole EmailAddresses collection can be classified in one pass.

    .EXAMPLE
        Split-MigrationProxyAddress -Entry 'SMTP:john.smith@contoso.com'

        Returns Prefix 'SMTP', Address 'john.smith@contoso.com', Kind 'Smtp', IsPrimary true.

    .EXAMPLE
        $mailbox.EmailAddresses | Split-MigrationProxyAddress | Where-Object Kind -eq 'X500'

        Lists the mailbox's X500 entries.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Entry
    )

    process {
        $text = ([string]$Entry).Trim()
        $prefix = ''
        $address = $text

        # Only the first colon is a separator - an X500 DN and a SIP address both contain
        # more of them further along.
        $separator = $text.IndexOf(':')
        if ($separator -gt 0) {
            $prefix = $text.Substring(0, $separator)
            $address = $text.Substring($separator + 1)
        }

        $kind = switch -Regex ($prefix) {
            '^$'     { 'Smtp' }
            '^smtp$' { 'Smtp' }
            '^sip$'  { 'Sip' }
            '^x500$' { 'X500' }
            '^spo$'  { 'Spo' }
            default  { 'Other' }
        }

        [pscustomobject]@{
            Entry     = $text
            Prefix    = $prefix
            Address   = $address
            Kind      = $kind
            IsPrimary = ($kind -eq 'Smtp' -and $prefix -ceq 'SMTP')
        }
    }
}
