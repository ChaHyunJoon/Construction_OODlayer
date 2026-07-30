# run_real_llm_demo.ps1 -- one-command REAL-LLM ForbidZone demo.
# Starts the Python /propose service, waits for /health, runs the MeshCat visual demo
# through the live Claude classifier, then stops the service. Requires ANTHROPIC_API_KEY
# in THIS PowerShell session. Run from the ConstructionBots.jl repo root:
#     .\tools\run_real_llm_demo.ps1
param(
    [int]$Port = 8000,
    [string]$Py = "C:\Users\chahj\PythonCodes\venv\hjcrl\Scripts\python.exe"  # venv with anthropic/fastapi/uvicorn
)

if (-not $env:ANTHROPIC_API_KEY) {
    Write-Error "ANTHROPIC_API_KEY is not set in this session. `$env:ANTHROPIC_API_KEY='sk-...' first."
    exit 1
}
if (-not (Test-Path $Py)) { Write-Error "Python not found at $Py (the venv with the deps)."; exit 1 }

$svcDir = Join-Path $PSScriptRoot "..\src\respec\llm_service"
Write-Host ">>> starting LLM service (uvicorn) on port $Port ..."
$svc = Start-Process -PassThru -NoNewWindow -FilePath $Py `
    -ArgumentList @("-m", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", "$Port") `
    -WorkingDirectory $svcDir

try {
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) {
        try {
            if ((Invoke-WebRequest "http://127.0.0.1:$Port/health" -TimeoutSec 2 -UseBasicParsing).StatusCode -eq 200) { $ok = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 750
    }
    if (-not $ok) { Write-Error "service /health never came up on port $Port"; exit 1 }
    Write-Host ">>> service healthy. running REAL-LLM visual demo ..."

    $env:USE_MOCK = "0"
    $env:RESPEC_SERVICE_URL = "http://127.0.0.1:$Port"
    julia +lts --project=. tools/demo_respec_forbidzone_anim.jl
}
finally {
    Write-Host ">>> stopping LLM service (pid $($svc.Id)) ..."
    Stop-Process -Id $svc.Id -Force -ErrorAction SilentlyContinue
}
