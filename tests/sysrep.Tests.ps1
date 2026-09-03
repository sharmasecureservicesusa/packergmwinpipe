BeforeAll {
    $Script:SysprepScript = (Resolve-Path "$PSScriptRoot/../scripts/sysrep.ps1").Path
}

Describe 'Sysprep Script Syntax' {
    It 'parses without syntax errors' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:SysprepScript,
            [ref]$null,
            [ref]$errors
        ) | Out-Null
        $errors.Count | Should -Be 0
    }

    It 'accepts only quit, shutdown, and reboot actions' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:SysprepScript,
            [ref]$null,
            [ref]$null
        )
        $paramBlock = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Action' }
        $validateSetAttr = $paramBlock.Attributes | Where-Object { $_.TypeName.FullName -eq 'ValidateSet' }
        $validValues = $validateSetAttr.PositionalArguments | ForEach-Object { $_.Value }
        $validValues | Should -Contain 'quit'
        $validValues | Should -Contain 'shutdown'
        $validValues | Should -Contain 'reboot'
    }
}

Describe 'Sysprep Script Execution' {
    BeforeEach {
        Mock -CommandName Test-Path -MockWith {
            param($Path, $LiteralPath)
            $target = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($target -like '*Unattend.xml') { return $true }
            return $true
        }
        Mock -CommandName Remove-Item -MockWith { return $null }
        Mock -CommandName Get-ChildItem -MockWith { return @() }
        Mock -CommandName Set-ExecutionPolicy -MockWith { return $null }
        Mock -CommandName Enable-LocalUser -MockWith { return $null }
        Mock -CommandName Get-ItemProperty -MockWith {
            [PSCustomObject]@{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
        }
        Mock -CommandName Start-Process -MockWith {
            [PSCustomObject]@{ ExitCode = 0; HasExited = $true }
        }
    }

    Context 'when prerequisites are present' {
        It 'executes without throwing' {
            { & $Script:SysprepScript -Action 'quit' } | Should -Not -Throw
        }

        It 'purges previous Cloudbase-Init state' {
            & $Script:SysprepScript -Action 'quit'
            Should -Invoke -CommandName Remove-Item -ParameterFilter {
                $Path -like '*HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init*'
            }
        }

        It 'enables the built-in Administrator account' {
            & $Script:SysprepScript -Action 'quit'
            Should -Invoke -CommandName Enable-LocalUser -Times 1 -ParameterFilter {
                $Name -eq 'Administrator'
            }
        }

        It 'invokes Sysprep with generalize, OOBE, and the answer file' {
            & $Script:SysprepScript -Action 'quit'
            Should -Invoke -CommandName Start-Process -Times 1 -ParameterFilter {
                $FilePath -like '*sysprep.exe' -and
                $ArgumentList -contains '/generalize' -and
                $ArgumentList -contains '/oobe' -and
                $ArgumentList -contains '/quit' -and
                ($ArgumentList | Where-Object { $_ -like '*/unattend:*Unattend.xml*' })
            }
        }
    }

    Context 'when Unattend.xml is missing' {
        BeforeEach {
            Mock -CommandName Test-Path -MockWith {
                param($Path, $LiteralPath)
                $target = if ($LiteralPath) { $LiteralPath } else { $Path }
                if ($target -like '*Unattend.xml') { return $false }
                return $true
            }
        }

        It 'stops before running Sysprep' {
            { & $Script:SysprepScript -Action 'quit' } | Should -Throw '*Unattend.xml not found*'
            Should -Invoke -CommandName Start-Process -Times 0
        }
    }

    Context 'when Sysprep returns a non-zero exit code' {
        BeforeEach {
            Mock -CommandName Start-Process -MockWith {
                [PSCustomObject]@{ ExitCode = 1; HasExited = $true }
            }
        }

        It 'reports the Sysprep exit code' {
            { & $Script:SysprepScript -Action 'quit' } | Should -Throw '*Sysprep failed with exit code 1*'
        }
    }
}
