class DeploymentLogger {
    [string]$Endpoint
    [string]$ApiKey
    [string]$DeploymentId
    [string]$Hostname
    [System.Collections.Generic.List[hashtable]]$Buffer

    DeploymentLogger([string]$endpoint, [string]$apiKey, [string]$deploymentId) {
        $this.Endpoint = $endpoint
        $this.ApiKey = $apiKey
        $this.DeploymentId = $deploymentId
        $this.Hostname = $env:COMPUTERNAME
        $this.Buffer = [System.Collections.Generic.List[hashtable]]::new()
    }

    [void] Log([string]$message) {
        $this.Log($message, 'INFO', @{})
    }

    [void] Log([string]$message, [string]$level) {
        $this.Log($message, $level, @{})
    }

    [void] Log([string]$message, [string]$level, [hashtable]$customData) {
        $timestamp = (Get-Date).ToUniversalTime().ToString('o')
        $color = switch ($level) {
            ERROR { [ConsoleColor]::Red }
            WARN { [ConsoleColor]::Yellow }
            NOTICE { [ConsoleColor]::Cyan }
            default { [ConsoleColor]::Gray }
        }
        Write-Host "[$timestamp] [$level] $message" -ForegroundColor $color
        $this.Buffer.Add(@{
            timestamp = $timestamp
            deploymentId = $this.DeploymentId
            hostname = $this.Hostname
            level = $level
            message = $message
            data = $customData
        })
        if ($this.Buffer.Count -ge 25) {
            $this.Flush()
        }
    }

    [void] LogException([System.Management.Automation.ErrorRecord]$errorRecord) {
        $this.LogException($errorRecord, 'An unhandled exception occurred')
    }

    [void] LogException([System.Management.Automation.ErrorRecord]$errorRecord, [string]$contextMessage) {
        $metadata = @{
            ExceptionMessage = $errorRecord.Exception.Message
            InvocationInfo = $errorRecord.InvocationInfo.PositionMessage
            ScriptStackTrace = $errorRecord.ScriptStackTrace
        }
        $this.Log("$contextMessage - Error: $($errorRecord.Exception.Message)", 'ERROR', $metadata)
    }

    [void] Flush() {
        if ($this.Buffer.Count -eq 0 -or [string]::IsNullOrWhiteSpace($this.Endpoint)) {
            return
        }
        $payload = $this.Buffer | ConvertTo-Json -Depth 5 -Compress
        $headers = @{
            Authorization = "Bearer $($this.ApiKey)"
            'Content-Type' = 'application/json'
        }
        try {
            Invoke-RestMethod -Uri $this.Endpoint -Method Post -Headers $headers -Body $payload -TimeoutSec 5 -ErrorAction Stop | Out-Null
            $this.Buffer.Clear()
        } catch {
            Write-Warning "Failed to flush logs to remote endpoint: $($_.Exception.Message)"
        }
    }
}

function Get-DeploymentLogger {
    [CmdletBinding()]
    param(
        [string]$IngestUrl = $env:LOG_INGEST_URL,
        [string]$ApiKey = $env:LOG_API_KEY,
        [string]$DeploymentId = $env:DEPLOYMENT_ID
    )

    if ([string]::IsNullOrWhiteSpace($DeploymentId)) {
        $DeploymentId = "packer-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    return [DeploymentLogger]::new($IngestUrl, $ApiKey, $DeploymentId)
}
