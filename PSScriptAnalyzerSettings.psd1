@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The script deliberately holds generated passwords as plaintext strings:
        # they are written to a credential report the operator hands out, and a
        # SecureString would have to be unwrapped for that anyway. The handling is
        # documented in the README's security notes.
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSUsePSCredentialType'

        # New-RandomPassword returns a [string] by design, for the same reason.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )

    Rules = @{
        PSPlaceOpenBrace = @{
            Enable     = $true
            OnSameLine = $true
        }
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }
    }
}
