using module "../scripts/modules/DeploymentLogger.psm1"

BeforeAll {
    $Script:DeployScriptPath = (Resolve-Path "$PSScriptRoot/../scripts/cloudbase-single-deploy.ps1").Path
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Script:DeployScriptPath,
        [ref]$null,
        [ref]$null
    )
    $definitions = $ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.TypeDefinitionAst] -or
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }
    if ($definitions) {
        . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"))
    }
}

Describe 'Deployment Script Syntax' {
    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:DeployScriptPath,
            [ref]$null,
            [ref]$errors
        ) | Out-Null
        $errors.Count | Should -Be 0
    }

    It 'contains no broken nested interpolation quotes' {
        $content = Get-Content -Path $Script:DeployScriptPath -Raw
        [regex]::Matches($content, '(?m)"[^"\r\n]*"\$[a-zA-Z0-9_:]+"[^"\r\n]*"').Count | Should -Be 0
    }
}

Describe 'DeploymentLogger Overloads' {
    BeforeEach {
        $Script:Logger = [DeploymentLogger]::new('', 'test-api-key', 'dep-test-101')
    }

    It 'uses INFO for the one-argument overload' {
        { $Script:Logger.Log('Starting provisioning sequence') } | Should -Not -Throw
        $Script:Logger.Buffer.Count | Should -Be 1
        $Script:Logger.Buffer[0].message | Should -Be 'Starting provisioning sequence'
        $Script:Logger.Buffer[0].level | Should -Be 'INFO'
        $Script:Logger.Buffer[0].data | Should -BeOfType [hashtable]
        $Script:Logger.Buffer[0].data.Count | Should -Be 0
    }

    It 'uses the supplied level for the two-argument overload' {
        $Script:Logger.Log('Enabling Remote Desktop...', 'INFO')
        $Script:Logger.Log('Configuration warning encountered', 'WARN')
        $Script:Logger.Buffer.Count | Should -Be 2
        $Script:Logger.Buffer[0].level | Should -Be 'INFO'
        $Script:Logger.Buffer[1].level | Should -Be 'WARN'
    }

    It 'stores metadata for the three-argument overload' {
        $metadata = @{ App = 'Git.Git'; ExitCode = 0; Duration = '12s' }
        { $Script:Logger.Log('Package installed', 'NOTICE', $metadata) } | Should -Not -Throw
        $Script:Logger.Buffer[0].level | Should -Be 'NOTICE'
        $Script:Logger.Buffer[0].data.App | Should -Be 'Git.Git'
        $Script:Logger.Buffer[0].data.ExitCode | Should -Be 0
    }

    It 'logs exceptions with both overloads' {
        try {
            Get-Item 'C:\NonExistent_Directory_Test_Path\dummy.file' -ErrorAction Stop
        } catch {
            { $Script:Logger.LogException($_) } | Should -Not -Throw
            { $Script:Logger.LogException($_, 'Custom failure context') } | Should -Not -Throw
        }
        $Script:Logger.Buffer.Count | Should -Be 2
        $Script:Logger.Buffer[0].level | Should -Be 'ERROR'
        $Script:Logger.Buffer[0].data.ExceptionMessage | Should -Not -BeNullOrEmpty
        $Script:Logger.Buffer[1].message | Should -Match 'Custom failure context'
    }
}

Describe 'DeploymentLogger Remote Flush' {
    BeforeEach {
        $Script:Logger = [DeploymentLogger]::new('https://test.ingest.cloudflare.com', 'dummy-token-xyz', 'dep-batch-01')
        Mock Invoke-RestMethod -ModuleName DeploymentLogger { @{ status = 'ok' } }
    }

    It 'posts buffered entries and clears the buffer' {
        $Script:Logger.Log('Event 1', 'INFO')
        $Script:Logger.Log('Event 2', 'WARN')
        $Script:Logger.Flush()
        $Script:Logger.Buffer.Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -ModuleName DeploymentLogger -Times 1 -ParameterFilter {
            $Uri -eq 'https://test.ingest.cloudflare.com' -and
            $Method -eq 'Post' -and
            $Headers['Authorization'] -eq 'Bearer dummy-token-xyz' -and
            $Headers['Content-Type'] -eq 'application/json'
        }
    }

    It 'retains buffered entries after a network failure' {
        Mock Invoke-RestMethod -ModuleName DeploymentLogger {
            throw [System.Net.WebException]::new('The operation has timed out.')
        }
        $Script:Logger.Log('Failed network attempt test')
        { $Script:Logger.Flush() } | Should -Not -Throw
        $Script:Logger.Buffer.Count | Should -Be 1
    }
}

Describe 'WinGet Automation' {
    It 'uses unattended agreement flags' {
        $content = Get-Content -Path $Script:DeployScriptPath -Raw
        $content | Should -Match '(?m)^\s*winget source update[^\r\n]+--accept-source-agreements'
        $content | Should -Match '(?m)^\s*\$arguments = "install[^\r\n]+--accept-source-agreements[^\r\n]+--accept-package-agreements"'
    }
}
