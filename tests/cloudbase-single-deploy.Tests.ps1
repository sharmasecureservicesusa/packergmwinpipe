<#
.SYNOPSIS
    Pester unit test suite for scripts/cloudbase-single-deploy.ps1.
.DESCRIPTION
    Validates PowerShell AST syntax, DeploymentLogger class overloads,
    remote telemetry flushing, and WinGet unattended invocation compliance.
#>

BeforeAll {
    $Script:DeployScriptPath = (Resolve-Path "$PSScriptRoot/../scripts/cloudbase-single-deploy.ps1").Path

    # Parse script into AST and extract only classes and functions
    # This imports DeploymentLogger and any helper functions into memory
    # without executing the main script body.
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

Describe "Deployment Script - Syntax & AST Integrity" {
    It "Parses cleanly with zero PowerShell syntax or token errors" {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:DeployScriptPath,
            [ref]$null,
            [ref]$errors
        ) | Out-Null

        $errors.Count | Should -Be 0
    }

    It "Contains no unescaped nested double quotes in string interpolation" {
        $content = Get-Content -Path $Script:DeployScriptPath -Raw
        # Pattern matches broken quote syntax like: "Text "$Variable" Text"
        $invalidQuotes = [regex]::Matches($content, '(?m)"[^"\r\n]*"\$[a-zA-Z0-9_:]+"[^"\r\n]*"')
        $invalidQuotes.Count | Should -Be 0
    }
}

Describe "DeploymentLogger Class - Method Overloads" {
    BeforeEach {
        # Initialize test logger with blank endpoint to isolate buffer logic
        $Script:Logger = [DeploymentLogger]::new("", "test-api-key", "dep-test-101")
    }

    It "Successfully invokes 1-argument Log overload (defaults to INFO)" {
        { $Script:Logger.Log("Starting provisioning sequence") } | Should -Not -Throw

        $Script:Logger.Buffer.Count | Should -Be 1
        $Script:Logger.Buffer[0].message | Should -Be "Starting provisioning sequence"
        $Script:Logger.Buffer[0].level   | Should -Be "INFO"
        $Script:Logger.Buffer[0].data    | Should -Not -BeNullOrEmpty
    }

    It "Successfully invokes 2-argument Log overload" {
        { $Script:Logger.Log("Enabling Remote Desktop...", "INFO") } | Should -Not -Throw
        { $Script:Logger.Log("Configuration warning encountered", "WARN") } | Should -Not -Throw

        $Script:Logger.Buffer.Count | Should -Be 2
        $Script:Logger.Buffer[0].level | Should -Be "INFO"
        $Script:Logger.Buffer.level | Should -Be "WARN"
    }

    It "Successfully invokes 3-argument Log overload with metadata hashtable" {
        $customMeta = @{
            App      = "Git.Git"
            ExitCode = 0
            Duration = "12s"
        }

        { $Script:Logger.Log("Package installed", "NOTICE", $customMeta) } | Should -Not -Throw

        $Script:Logger.Buffer.Count | Should -Be 1
        $entry = $Script:Logger.Buffer[0]
        $entry.level | Should -Be "NOTICE"
        $entry.data.App | Should -Be "Git.Git"
        $entry.data.ExitCode | Should -Be 0
    }

    It "Successfully invokes LogException without throwing overload errors" {
        try {
            # Generate a real System.Management.Automation.ErrorRecord
            Get-Item "C:\NonExistent_Directory_Test_Path\dummy.file" -ErrorAction Stop
        } catch {
            { $Script:Logger.LogException($_) } | Should -Not -Throw
            { $Script:Logger.LogException($_, "Custom failure context") } | Should -Not -Throw
        }

        $Script:Logger.Buffer.Count | Should -Be 2
        $Script:Logger.Buffer[0].level | Should -Be "ERROR"
        $Script:Logger.Buffer[0].data.ExceptionMessage | Should -Not -BeNullOrEmpty
        $Script:Logger.Buffer.message | Should -Match "Custom failure context"
    }
}

Describe "DeploymentLogger Class - Remote Flush & Buffering" {
    BeforeEach {
        $Script:Endpoint = "https://test.ingest.cloudflare.com"
        $Script:ApiKey   = "dummy-token-xyz"
        $Script:Logger   = [DeploymentLogger]::new($Script:Endpoint, $Script:ApiKey, "dep-batch-01")

        # Mock network call to simulate successful HTTP 200 response
        Mock -CommandName Invoke-RestMethod -MockWith {
            return @{ status = "ok" }
        }
    }

    It "Sends buffered entries via POST with Bearer authentication and clears the buffer" {
        $Script:Logger.Log("Event 1", "INFO")
        $Script:Logger.Log("Event 2", "WARN")
        $Script:Logger.Buffer.Count | Should -Be 2

        $Script:Logger.Flush()

        # Assert buffer was cleared upon successful push
        $Script:Logger.Buffer.Count | Should -Be 0

        # Assert Invoke-RestMethod was called with correct parameters
        Should -Invoke -CommandName Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq "https://test.ingest.cloudflare.com" -and
            $Method -eq "Post" -and
            $Headers["Authorization"] -eq "Bearer dummy-token-xyz" -and
            $Headers["Content-Type"] -eq "application/json"
        }
    }

    It "Silently catches network timeouts during Flush without terminating execution" {
        Mock -CommandName Invoke-RestMethod -MockWith {
            throw [System.Net.WebException]::new("The operation has timed out.")
        }

        $Script:Logger.Log("Failed network attempt test")
        { $Script:Logger.Flush() } | Should -Not -Throw
    }
}

Describe "WinGet Automation - Unattended Agreement Flags" {
    It "Verifies all winget invocations include source and package agreement flags" {
        $content = Get-Content -Path $Script:DeployScriptPath

        # Find lines invoking winget
        $wingetLines = $content | Where-Object { $_ -match '\bwinget\b' }

        foreach ($line in $wingetLines) {
            # Skip comments
            if ($line.Trim().StartsWith("#")) { continue }

            if ($line -match '\bwinget\s+install\b') {
                $line | Should -Match '--accept-source-agreements'
                $line | Should -Match '--accept-package-agreements'
            }

            if ($line -match '\bwinget\s+source\s+update\b') {
                $line | Should -Match '--accept-source-agreements'
            }
        }
    }
}
