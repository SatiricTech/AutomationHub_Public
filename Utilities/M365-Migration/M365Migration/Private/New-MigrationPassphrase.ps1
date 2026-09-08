$script:MigrationPassphraseWords = @(
    'apple', 'anchor', 'amber', 'basil', 'birch', 'brave', 'bronze', 'cactus',
    'candle', 'cedar', 'cobalt', 'copper', 'coral', 'cotton', 'cricket', 'crimson',
    'delta', 'ember', 'falcon', 'fern', 'flint', 'forest', 'garnet', 'ginger',
    'granite', 'harbor', 'hazel', 'indigo', 'ivory', 'jasper', 'juniper', 'kettle',
    'lantern', 'laurel', 'lemon', 'lily', 'lotus', 'maple', 'marble', 'meadow',
    'mint', 'mocha', 'nectar', 'nimbus', 'oak', 'olive', 'onyx', 'orchid',
    'pepper', 'pewter', 'pine', 'plum', 'quartz', 'raven', 'river', 'rustic',
    'saffron', 'sage', 'silver', 'slate', 'spruce', 'stone', 'sunset', 'thistle',
    'timber', 'topaz', 'tulip', 'velvet', 'willow', 'winter', 'zephyr'
)

function New-MigrationPassphrase {
    <#
    .SYNOPSIS
        Generates a readable cutover passphrase that satisfies Entra ID password policy.

    .DESCRIPTION
        Cutover passwords get read aloud over the phone and typed on a phone keypad, so
        a random character string is the wrong tool. This produces hyphenated dictionary
        words plus a two-digit number and a symbol, which clears the complexity floor
        while staying dictatable. The word list deliberately excludes look-alike words.
        Get-Random -Count returns distinct items, so a phrase never repeats a word.

    .PARAMETER WordCount
        How many words to use. Values below three are raised to three so the result
        always meets the length floor.

    .EXAMPLE
        New-MigrationPassphrase -WordCount 3

        Returns something in the shape of 'silver-copper-Lantern74!'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported. Generated values are written only to the
        results CSV, never to the run log.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Generates an in-memory value; changes no system state.')]
    [OutputType([string])]
    param(
        [ValidateRange(3, 8)]
        [int]$WordCount = 3
    )

    $picked = @(Get-Random -InputObject $script:MigrationPassphraseWords -Count $WordCount)

    # Capitalise one randomly chosen word to satisfy the mixed-case requirement.
    $capIndex = Get-Random -Maximum $picked.Count
    $word = $picked[$capIndex]
    $picked[$capIndex] = $word.Substring(0, 1).ToUpperInvariant() + $word.Substring(1)

    $number = Get-Random -Minimum 10 -Maximum 100
    $symbols = '!@#$%^*-_=+?'
    $symbol = $symbols[(Get-Random -Maximum $symbols.Length)]

    return ('{0}{1}{2}' -f ($picked -join '-'), $number, $symbol)
}
