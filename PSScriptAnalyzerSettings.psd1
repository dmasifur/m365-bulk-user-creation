@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # --- Plaintext passwords -------------------------------------------
        # The script deliberately holds generated passwords as plaintext strings:
        # they are written to a credential report the operator hands out, and a
        # SecureString would have to be unwrapped for that anyway. The handling is
        # documented in the README's security notes.
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSUsePSCredentialType'
        'PSAvoidUsingConvertToSecureStringWithPlainText'

        # --- False positives on internal helpers ---------------------------
        # Fires on New-RandomPassword and the test helpers, which are pure and
        # change nothing. The script itself, which does change tenant state,
        # declares SupportsShouldProcess and honours -WhatIf.
        'PSUseShouldProcessForStateChangingFunctions'

        # Reads 'Exists' in Test-UserExists as a plural noun. It is a verb, and
        # Test-UserExist would be worse.
        'PSUseSingularNouns'

        # Disagrees with the continuation indent used for the ValidateScript
        # block and the pipeline-style hashtable literals. This is a formatting
        # opinion, not a defect, and the file is internally consistent.
        'PSUseConsistentIndentation'
    )

    Rules = @{
        PSPlaceOpenBrace = @{
            Enable     = $true
            OnSameLine = $true
        }
    }
}
