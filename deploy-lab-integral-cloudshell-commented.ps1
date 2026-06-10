param(
    # ------------------------------------------------------------
    # Nombre del Resource Group donde quedará todo el laboratorio.
    # Este parámetro permite reutilizar el mismo script en distintos
    # ejercicios o demostraciones.
    # ------------------------------------------------------------
    [string]$ResourceGroupName = 'FCM-RG',

    # Región del Resource Group.
    # Ojo: el Resource Group puede estar en una región distinta a la
    # de algunos recursos. En este laboratorio se usa eastus como base.
    [string]$ResourceGroupLocation = 'eastus',

    # Nombres de despliegue ARM para diferenciar red y cómputo.
    [string]$NetworkDeploymentName = 'Deploy-Network-Foundation',
    [string]$VmDeploymentName = 'Deploy-Compute-Foundation',

    # Archivos de red.
    [string]$NetworkTemplateFile = './lab-network-template.json',
    [string]$NetworkParameterFile = './lab-network-parameters.json',

    # Archivos de cómputo.
    [string]$VmTemplateFile = './lab-vm-template.json',
    [string]$VmParameterFile = './lab-vm-parameters.json'
)

# ================================================================
# CONFIGURACIÓN GLOBAL DEL SCRIPT
# ================================================================
# Detiene la ejecución ante el primer error no controlado.
# Esto evita que el laboratorio continúe en un estado inconsistente.
$ErrorActionPreference = 'Stop'

# ================================================================
# FUNCIÓN: Write-Step
# ================================================================
# Imprime títulos de sección para que la ejecución sea más legible.
# Muy útil durante la grabación de clase y para troubleshooting.
function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

# ================================================================
# FUNCIÓN: Assert-FileExists
# ================================================================
# Verifica que un archivo exista antes de continuar.
# Esto evita que el script falle más adelante con errores confusos.
function Assert-FileExists {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No se encontró el archivo requerido: $Path"
    }
}

# ================================================================
# FUNCIÓN: Get-ParameterValue
# ================================================================
# Lee el valor de un parámetro dentro de un archivo de parámetros JSON
# ya cargado en memoria como objeto PowerShell.
#
# Esta función se usa para validar que la plantilla de red y la de
# cómputo estén alineadas entre sí.
function Get-ParameterValue {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Json,
        [Parameter(Mandatory = $true)] [string]$ParameterName
    )

    $parameter = $Json.parameters.$ParameterName
    if ($null -eq $parameter) {
        throw "No se encontró el parámetro '$ParameterName' en el archivo JSON."
    }

    return $parameter.value
}

# ================================================================
# 1. VALIDAR SESIÓN DE AZURE
# ================================================================
Write-Step 'Validando sesión de Azure'
$context = Get-AzContext
if ($null -eq $context) {
    throw 'No hay sesión activa en Azure. Ejecute Connect-AzAccount antes de continuar.'
}
Write-Host "Suscripción activa: $($context.Subscription.Name) [$($context.Subscription.Id)]" -ForegroundColor Green

# ================================================================
# 2. VALIDAR EXISTENCIA DE LOS 4 ARCHIVOS DEL LABORATORIO
# ================================================================
Write-Step 'Validando archivos requeridos'
@($NetworkTemplateFile, $NetworkParameterFile, $VmTemplateFile, $VmParameterFile) | ForEach-Object {
    Assert-FileExists -Path $_
    Write-Host "OK -> $_" -ForegroundColor Green
}

# ================================================================
# 3. LEER LOS DOS ARCHIVOS DE PARÁMETROS
# ================================================================
# Se cargan ambos JSON a memoria para comparar sus valores y asegurar
# que todo el laboratorio esté alineado.
Write-Step 'Leyendo archivos de parámetros'
$networkParams = Get-Content -LiteralPath $NetworkParameterFile -Raw | ConvertFrom-Json -Depth 50
$vmParams = Get-Content -LiteralPath $VmParameterFile -Raw | ConvertFrom-Json -Depth 50

# Extraemos los valores clave de la red.
$coreVnetName = Get-ParameterValue -Json $networkParams -ParameterName 'coreVnetName'
$coreDatabaseSubnetName = Get-ParameterValue -Json $networkParams -ParameterName 'coreDatabaseSubnetName'
$coreLocation = Get-ParameterValue -Json $networkParams -ParameterName 'coreLocation'

# Extraemos los valores equivalentes del despliegue de cómputo.
$vmExistingVnetName = Get-ParameterValue -Json $vmParams -ParameterName 'existingVirtualNetworkName'
$vmExistingSubnetName = Get-ParameterValue -Json $vmParams -ParameterName 'existingSubnetName'
$vmLocation = Get-ParameterValue -Json $vmParams -ParameterName 'location'

# ================================================================
# 4. VALIDAR ALINEACIÓN ENTRE RED Y CÓMPUTO
# ================================================================
# Aquí está uno de los puntos más importantes del laboratorio.
# El script asegura que:
# - la VNet usada por las VMs sí sea la VNet creada por la plantilla de red,
# - la subnet usada por las VMs sí exista en la plantilla de red,
# - la región de cómputo coincida con la región de la red principal.
Write-Step 'Validando alineación entre red y cómputo'
if ($coreVnetName -ne $vmExistingVnetName) {
    throw "Desalineación detectada: existingVirtualNetworkName en VM parameters ('$vmExistingVnetName') no coincide con coreVnetName en Network parameters ('$coreVnetName')."
}

if ($coreDatabaseSubnetName -ne $vmExistingSubnetName) {
    throw "Desalineación detectada: existingSubnetName en VM parameters ('$vmExistingSubnetName') no coincide con coreDatabaseSubnetName en Network parameters ('$coreDatabaseSubnetName')."
}

if ($coreLocation -ne $vmLocation) {
    throw "Desalineación detectada: location en VM parameters ('$vmLocation') no coincide con coreLocation en Network parameters ('$coreLocation')."
}

Write-Host 'Alineación validada correctamente entre los 4 archivos.' -ForegroundColor Green

# ================================================================
# 5. SOLICITAR CONTRASEÑA SEGURA PARA LAS VMS
# ================================================================
# La contraseña no se guarda en el archivo de parámetros por seguridad.
# Se solicita en tiempo real usando Read-Host -AsSecureString.
Write-Step 'Validando contraseña segura para despliegue de VMs'
$adminPassword = Read-Host 'Ingrese la contraseña de administrador para las VMs' -AsSecureString

# ================================================================
# 6. CREAR RESOURCE GROUP SI NO EXISTE
# ================================================================
Write-Step 'Creando Resource Group si no existe'
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($null -eq $rg) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation | Out-Null
    Write-Host "Resource Group creado: $ResourceGroupName" -ForegroundColor Green
} else {
    Write-Host "Resource Group ya existe: $ResourceGroupName" -ForegroundColor Yellow
}

# ================================================================
# 7. VALIDAR DESPLIEGUE DE RED
# ================================================================
# Test-AzResourceGroupDeployment no crea recursos.
# Solo valida que la plantilla y los parámetros sean correctos.
Write-Step 'Validando despliegue de red'
Test-AzResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $NetworkTemplateFile `
    -TemplateParameterFile $NetworkParameterFile | Out-Null
Write-Host 'Validación de red completada.' -ForegroundColor Green

# ================================================================
# 8. DESPLEGAR RED Y SUBREDES
# ================================================================
Write-Step 'Desplegando red y subredes'
$networkDeployment = New-AzResourceGroupDeployment `
    -Name $NetworkDeploymentName `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $NetworkTemplateFile `
    -TemplateParameterFile $NetworkParameterFile `
    -Verbose

if ($networkDeployment.ProvisioningState -ne 'Succeeded') {
    throw "El despliegue de red no finalizó correctamente. Estado: $($networkDeployment.ProvisioningState)"
}
Write-Host 'Despliegue de red finalizado correctamente.' -ForegroundColor Green

# ================================================================
# 9. VERIFICAR QUE LA VNET Y LA SUBNET EXISTAN REALMENTE
# ================================================================
# No basta con confiar en el despliegue. Aquí se valida en Azure
# que la VNet y la subnet requeridas efectivamente estén creadas.
Write-Step 'Verificando existencia de VNet y subnet requeridas'
$vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $coreVnetName -ErrorAction Stop
$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $coreDatabaseSubnetName }
if ($null -eq $subnet) {
    throw "No se encontró la subnet '$coreDatabaseSubnetName' dentro de la VNet '$coreVnetName'."
}
Write-Host "VNet encontrada: $($vnet.Name)" -ForegroundColor Green
Write-Host "Subnet encontrada: $($subnet.Name)" -ForegroundColor Green

# ================================================================
# 10. VALIDAR DESPLIEGUE DE MÁQUINAS VIRTUALES
# ================================================================
Write-Step 'Validando despliegue de máquinas virtuales'
Test-AzResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $VmTemplateFile `
    -TemplateParameterFile $VmParameterFile `
    -adminPassword $adminPassword | Out-Null
Write-Host 'Validación de cómputo completada.' -ForegroundColor Green

# ================================================================
# 11. DESPLEGAR MÁQUINAS VIRTUALES
# ================================================================
Write-Step 'Desplegando máquinas virtuales'
$vmDeployment = New-AzResourceGroupDeployment `
    -Name $VmDeploymentName `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile $VmTemplateFile `
    -TemplateParameterFile $VmParameterFile `
    -adminPassword $adminPassword `
    -Verbose

if ($vmDeployment.ProvisioningState -ne 'Succeeded') {
    throw "El despliegue de VMs no finalizó correctamente. Estado: $($vmDeployment.ProvisioningState)"
}
Write-Host 'Despliegue de máquinas virtuales finalizado correctamente.' -ForegroundColor Green

# ================================================================
# 12. RESUMEN FINAL Y OUTPUTS
# ================================================================
# ConvertTo-Json se usa aquí para imprimir de forma clara las salidas
# devueltas por ambos despliegues.
Write-Step 'Resumen final'
Write-Host 'Outputs red:' -ForegroundColor Yellow
$networkDeployment.Outputs | ConvertTo-Json -Depth 20
Write-Host 'Outputs cómputo:' -ForegroundColor Yellow
$vmDeployment.Outputs | ConvertTo-Json -Depth 20

Write-Host "`nLaboratorio integral completado correctamente." -ForegroundColor Cyan
