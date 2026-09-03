<#
.SYNOPSIS
    Pester unit and integration tests for scripts/sysprep.ps1.
.DESCRIPTION
    Validates syntax, parameter sets, registry cleanup calls, and ensures
    Sysprep invocation passes the required Cloudbase-Init Unattend arguments.
#>

BeforeAll {
    $Script:SysprepScript = (Resolve-Path "$PSScriptRoot/../scripts/sysprep.ps1").Path

    # Define wrapper stubs for external Win32 commands so Pester can intercept them
    function net { }
    function wevtutil { }
}

Describe "Sysprep Script - Syntax & Static Analysis" {
    It "Parses cleanly without any PowerShell AST syntax errors" {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:SysprepScript,
            [ref]$null,
            [ref]$errors
        ) | Out-Null

        $errors.Count | Should -Be 0
    }

    It "Requires valid action parameters (quit, shutdown, reboot)" {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:SysprepScript,
            [ref]$null,
            [ref]$null
        )
        $paramBlock = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Action' }
        $validateSetAttr = $paramBlock.Attributes | Where-Object { $_.TypeName.FullName -eq 'ValidateSet' }

        $validValues = $validateSetAttr.PositionalArguments | ForEach-Object { $_.Value }
        $validValues | Should -Contain "quit"
        $validValues | Should -Contain "shutdown"
        $validValues | Should -Contain "reboot"
    }
}

Describe "Sysprep Script - Execution Logic & Mocking" {
    BeforeEach {
        # 1. Mock file system operations to avoid deleting local files
        Mock -CommandName Test-Path -MockWith {
            param($Path)
            # Simulate that Cloudbase-Init and Unattend.xml exist
            if ($Path -like "*Unattend.xml") { return $true }
            if ($Path -like "*Cloudbase Solutions*") { return $true }
            return $true
        }

        Mock -CommandName Remove-Item -MockWith { return $null }
        Mock -CommandName Get-ChildItem -MockWith { return @() }
        Mock -CommandName Set-ExecutionPolicy -MockWith { return $null }

        # 2. Mock external binaries
        Mock -CommandName net -MockWith { return "The command completed successfully." }
        Mock -CommandName wevtutil -MockWith { return $null }

        # 3. Mock Start-Process returning a successful Process object for sysprep.exe
        Mock -CommandName Start-Process -MockWith {
            return [PSCustomObject]@{
                ExitCode  = 0
                HasExited = $true
            }
        }
    }

    Context "When prerequisites are present" {
        It "Executes without throwing an exception" {
            { & $Script:SysprepScript -Action 'quit' } | Should -Not -Throw
        }

        It "Purges previous Cloudbase-Init registry and history keys" {
            & $Script:SysprepScript -Action 'quit'

            # Verify that Remove-Item was directed at the Cloudbase-Init registry key
            Should -Invoke -CommandName Remove-Item -ParameterFilter {
                $Path -like "*HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init*"
            }
        }

        It "Ensures the built-in Administrator account is re-enabled" {
            & $Script:SysprepScript -Action 'quit'

            # Verify net user Administrator /active:yes was invoked
            Should -Invoke -CommandName net -Times 1 -ParameterFilter {
                $args[0] -eq "user" -and
                $args -eq "Administrator" -and
                $args -eq "/active:yes"
            }
        }

        It "Invokes sysprep.exe with /generalize, /oobe, and the Unattend.xml flag" {
            & $Script:SysprepScript -Action 'quit'

            # Verify Start-Process was called with correct Sysprep arguments
            Should -Invoke -CommandName Start-Process -Times 1 -ParameterFilter {
                $FilePath -like "*sysprep.exe" -and
                $ArgumentList -contains "/generalize" -and
                $ArgumentList -contains "/oobe" -and
                $ArgumentList -contains "/quit" -and
                ($ArgumentList | Where-Object { $_ -like '*/unattend:*Unattend.xml*' })
            }
        }
    }

    Context "When Unattend.xml is missing" {
        BeforeEach {
            # Simulate missing Unattend.xml
            Mock -CommandName Test-Path -MockWith {
                param($Path)
                if ($Path -like "*Unattend.xml") { return $false }
                return $true
            }
        }

        It "Throws a terminating error and halts before running Sysprep" {
            { & $Script:SysprepScript -Action 'quit' } | Should -Throw "*Unattend.xml not found*"

            # Ensure Sysprep was NEVER executed
            Should -Invoke -CommandName Start-Process -Times 0
        }
    }

    Context "When sysprep.exe returns a non-zero exit code" {
        BeforeEach {
            # Simulate Sysprep crash (e.g. exit code 1 or 0x80070005)
            Mock -CommandName Start-Process -MockWith {
                return [PSCustomObject]@{
                    ExitCode  = 1
                    HasExited = $true
                }
            }
        }

        It "Raises an error stating Sysprep failed" {
            { & $Script:SysprepScript -Action 'quit' } | Should -Throw "*Sysprep failed with exit code 1*"
        }
    }
}
