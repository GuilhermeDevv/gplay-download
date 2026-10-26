<#
.SYNOPSIS
  Instalador do GPLAY TV para LG webOS (Windows).

.DESCRIPTION
  Baixa a ultima versao do GPLAY TV (.ipk) e instala na TV usando o Modo
  Desenvolvedor da LG. Na primeira execucao instala o Node.js portatil (se
  necessario) e o webOS CLI no perfil do usuario, sem precisar de admin.

.EXAMPLE
  irm https://gplayiptv.me/install.ps1 | iex

.EXAMPLE
  .\install.ps1 -TvIp 192.168.1.50 -Passphrase ABC123
#>
[CmdletBinding()]
param(
  [string]$TvIp,
  [string]$Passphrase,
  [string]$DeviceName = "gplay-tv",
  [string]$IpkUrl = "https://github.com/GuilhermeDevv/gplay-download/releases/download/tv-latest/gplay-webos.ipk",
  [string]$IpkPath,
  [switch]$SkipLaunch
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$AppId = "com.gplay.webos"
$Root = Join-Path $env:LOCALAPPDATA "gplay-tv"
$NodeRoot = Join-Path $Root "node"
$NpmPrefix = Join-Path $Root "npm"
$WorkDir = Join-Path $env:TEMP "gplay-tv-install"
New-Item -ItemType Directory -Force -Path $Root, $WorkDir | Out-Null

function Write-Step([string]$Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail([string]$Message) {
  Write-Host ""
  Write-Host "[ERRO] $Message" -ForegroundColor Red
  throw $Message
}

Write-Host "==============================================" -ForegroundColor Red
Write-Host "  GPLAY TV - Instalador para LG webOS" -ForegroundColor White
Write-Host "==============================================" -ForegroundColor Red

# ---------------------------------------------------------------------------
# 1) Node.js (usa o instalado; se faltar, baixa uma copia portatil)
# ---------------------------------------------------------------------------
Write-Step "Verificando Node.js"
$nodeOk = $false
if (Get-Command node -ErrorAction SilentlyContinue) {
  try {
    $major = [int]((& node -v).TrimStart("v").Split(".")[0])
    if ($major -ge 18) { $nodeOk = $true }
  } catch {}
}

if (-not $nodeOk) {
  Write-Host "Node.js nao encontrado (ou antigo). Baixando versao portatil..."
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win-arm64" } else { "win-x64" }
  try {
    $index = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -UseBasicParsing -ErrorAction Stop
    $lts = $index | Where-Object { $_.lts -and ($_.files -contains $arch) } | Select-Object -First 1
    if (-not $lts) { throw "Nao foi possivel localizar o Node.js LTS para $arch." }

    $zipName = "node-$($lts.version)-$arch.zip"
    $zipPath = Join-Path $WorkDir $zipName
    Write-Host "Baixando $zipName ..."
    Invoke-WebRequest -Uri "https://nodejs.org/dist/$($lts.version)/$zipName" -OutFile $zipPath -UseBasicParsing -ErrorAction Stop

    if (Test-Path $NodeRoot) { Remove-Item $NodeRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $NodeRoot | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $NodeRoot -Force

    $nodeExe = Get-ChildItem $NodeRoot -Filter "node.exe" -Recurse | Select-Object -First 1
    if (-not $nodeExe) { throw "Falha ao extrair o Node.js." }
    $env:Path = "$($nodeExe.DirectoryName);$env:Path"
  } catch {
    Fail "Falha ao baixar o Node.js: $($_.Exception.Message)"
  }
}
Write-Host ("Node.js: " + (& node -v)) -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2) webOS CLI (ares-install / ares-launch)
# ---------------------------------------------------------------------------
Write-Step "Preparando o webOS CLI"
$aresCmd = Join-Path $NpmPrefix "ares-install.cmd"
if (-not (Test-Path $aresCmd)) {
  New-Item -ItemType Directory -Force -Path $NpmPrefix | Out-Null
  Write-Host "Baixando as ferramentas da LG (somente na primeira vez)..."
  & npm install -g "@webosose/ares-cli" --prefix "$NpmPrefix" --no-fund --no-audit
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $aresCmd)) {
    Fail "Nao foi possivel instalar o webOS CLI."
  }
}
$env:Path = "$NpmPrefix;$env:Path"

# ---------------------------------------------------------------------------
# 3) TV: usa um dispositivo ja cadastrado ou cadastra um novo
# ---------------------------------------------------------------------------
Write-Step "Conectando na TV"
$deviceList = & ares-setup-device -l 2>$null | Out-String
$deviceExists = $deviceList -match ("(?m)^" + [regex]::Escape($DeviceName) + "\s")

if ($deviceExists -and -not $TvIp) {
  Write-Host "Usando o dispositivo ja cadastrado: $DeviceName" -ForegroundColor Green
} else {
  if (-not $TvIp) {
    Write-Host "Informe o IP da TV (Configuracoes > Rede > Wi-Fi > Detalhes)."
    $TvIp = Read-Host "IP da TV"
  }
  if (-not $TvIp) { Fail "IP nao informado." }

  if (-not (Test-NetConnection -ComputerName $TvIp -Port 9922 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Fail "A TV nao respondeu na porta 9922. Confira o Modo Desenvolvedor e se o PC esta na mesma rede."
  }

  if (-not $Passphrase) {
    Write-Host "Digite a senha de 6 caracteres do Modo Desenvolvedor (mostrada no app Developer Mode da TV)."
    $Passphrase = Read-Host "Senha"
  }
  if (-not $Passphrase) { Fail "Senha nao informada." }

  if ($deviceExists) {
    Write-Host "Atualizando o IP do dispositivo $DeviceName ..."
    & ares-setup-device --modify $DeviceName -i "description=GPLAY TV" -i "host=$TvIp" -i "port=9922" -i "username=prisoner" -i "password=$Passphrase"
  } else {
    Write-Host "Cadastrando a TV..."
    & ares-setup-device --add $DeviceName -i "description=GPLAY TV" -i "host=$TvIp" -i "port=9922" -i "username=prisoner" -i "password=$Passphrase"
  }
  if ($LASTEXITCODE -ne 0) {
    Fail "Nao foi possivel cadastrar a TV. Confira o IP e a senha."
  }
  Write-Host "Se a TV pedir autorizacao, aceite a conexao." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 4) Download do .ipk
# ---------------------------------------------------------------------------
Write-Step "Baixando o GPLAY TV"
if ($IpkPath) {
  if (-not (Test-Path $IpkPath)) { Fail "Arquivo .ipk nao encontrado: $IpkPath" }
  $ipk = (Resolve-Path $IpkPath).Path
} else {
  $ipk = Join-Path $WorkDir "gplay-webos.ipk"
  try {
    Invoke-WebRequest -Uri $IpkUrl -OutFile $ipk -UseBasicParsing -ErrorAction Stop
  } catch {
    Fail "Falha ao baixar o .ipk: $($_.Exception.Message)"
  }
}
$sizeMb = [math]::Round((Get-Item $ipk).Length / 1MB, 2)
Write-Host "Pacote: $ipk ($sizeMb MB)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5) Instalacao e abertura
# ---------------------------------------------------------------------------
Write-Step "Instalando na TV (pode levar alguns segundos)"
& ares-install -d $DeviceName $ipk
if ($LASTEXITCODE -ne 0) {
  Fail "A instalacao falhou. Confira o Modo Desenvolvedor, a senha e se a TV esta na mesma rede."
}

if (-not $SkipLaunch) {
  Write-Step "Abrindo o GPLAY TV"
  & ares-launch -d $DeviceName $AppId | Out-Host
}

Write-Host ""
Write-Host "GPLAY TV instalado com sucesso!" -ForegroundColor Green
Write-Host "Para atualizar depois, rode o mesmo comando novamente." -ForegroundColor Gray
